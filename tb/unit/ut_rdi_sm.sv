// Unit test: rdi_state_machine. Walks RESET -> ACTIVE -> L1 -> ACTIVE ->
// LINKRESET -> ACTIVE -> RETRAIN -> ACTIVE -> LINKERROR -> LINKRESET ->
// DISABLED, and checks the 8.1.6 active-entry gating.
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_rdi_sm;
  logic        lclk, lreset_n;
  logic [3:0]  rdi_lp_state_req;
  logic        rdi_lp_stallack;
  logic [3:0]  rdi_pl_state_sts;
  logic        rdi_pl_inband_pres;
  logic        rdi_pl_linkerror;
  logic        rdi_pl_phyinrecenter;
  logic        rdi_pl_cerror;
  logic        rdi_pl_nferror;
  logic        rdi_pl_trainerror;
  logic        phy_link_trained;
  logic        phy_link_reset;
  logic        phy_retrain_req;
  logic        phy_train_error;
  logic        phy_inband_pres;
  logic        cerror, nferror;
  logic        stall_req, stall_ack;
  logic        adapter_active_req;
  logic        local_active_req;
  int          errors;

  rdi_state_machine u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack(rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror(rdi_pl_cerror),
    .rdi_pl_nferror(rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .phy_link_trained(phy_link_trained),
    .phy_link_reset(phy_link_reset),
    .phy_retrain_req(phy_retrain_req),
    .phy_train_error(phy_train_error),
    .phy_inband_pres(phy_inband_pres),
    .cerror(cerror), .nferror(nferror),
    .stall_req(stall_req), .stall_ack(stall_ack),
    .adapter_active_req(adapter_active_req),
    .local_active_req(local_active_req)
  );

  initial lclk = 1'b0;
  always #1.0 lclk = ~lclk;

  task chk;
    input [64*8-1:0] label;
    input [3:0]     exp;
    begin
      if (rdi_pl_state_sts !== exp) begin
        $display("FAIL ut_rdi_sm: %s: got %01h want %01h", label,
                 rdi_pl_state_sts, exp);
        errors = errors + 1;
      end
    end
  endtask

  // Step until the status matches, with a bounded deadline.
  task step_to;
    input [64*8-1:0] label;
    input [3:0]     exp;
    begin
      fork
        begin
          wait (rdi_pl_state_sts == exp);
          #0.1;
        end
        begin
          repeat (2000) @(posedge lclk);
        end
      join_any
      chk(label, exp);
    end
  endtask

  initial begin
    errors = 0;
    lreset_n        = 1'b0;
    rdi_lp_state_req= RDI_REQ_NOP;
    rdi_lp_stallack = 1'b0;
    phy_link_trained= 1'b0;
    phy_link_reset  = 1'b0;
    phy_retrain_req = 1'b0;
    phy_train_error = 1'b0;
    phy_inband_pres = 1'b0;
    cerror          = 1'b0;
    nferror         = 1'b0;
    stall_req       = 1'b0;
    adapter_active_req = 1'b0;

    #5 lreset_n = 1'b1;
    @(negedge lclk);
    chk("reset", RDI_STS_RESET);

    // RESET -> ACTIVE needs a trained link and the adapter request. The
    // partner-active gate (8.1.6) is on local_active_req, checked below.
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    repeat (4) @(posedge lclk);
    chk("no link, no active", RDI_STS_RESET);

    phy_link_trained  = 1'b1;
    adapter_active_req = 1'b1;
    step_to("active", RDI_STS_ACTIVE);
    // 8.1.6 gating: local_active_req needs state, partner and link.
    if (!local_active_req) begin
      $display("FAIL ut_rdi_sm: local_active_req low in ACTIVE");
      errors = errors + 1;
    end
    adapter_active_req = 1'b0;
    @(posedge lclk); #0.1;
    if (local_active_req) begin
      $display("FAIL ut_rdi_sm: local_active_req high without partner ACTIVE");
      errors = errors + 1;
    end
    adapter_active_req = 1'b1;
    @(posedge lclk); #0.1;
    if (!local_active_req) begin
      $display("FAIL ut_rdi_sm: local_active_req low again");
      errors = errors + 1;
    end

    // ACTIVE -> L1 -> ACTIVE
    rdi_lp_state_req = RDI_REQ_L1;
    step_to("l1", RDI_STS_L1);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    step_to("active2", RDI_STS_ACTIVE);

    // ACTIVE -> LINKRESET -> ACTIVE
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    step_to("linkreset", RDI_STS_LINKRESET);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    step_to("active3", RDI_STS_ACTIVE);

    // ACTIVE -> RETRAIN. The machine holds RETRAIN until the link reports
    // trained again, then returns to ACTIVE on the adapter request.
    rdi_lp_state_req = RDI_REQ_RETRAIN;
    phy_link_trained = 1'b0;
    step_to("retrain", RDI_STS_RETRAIN);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    repeat (4) @(posedge lclk);
    chk("retrain holds without trained link", RDI_STS_RETRAIN);
    phy_link_trained = 1'b1;
    step_to("active4", RDI_STS_ACTIVE);

    // TRAINERROR preempts everything and forces LINKERROR.
    phy_train_error = 1'b1;
    @(posedge lclk); #0.1;
    chk("linkerror", RDI_STS_LINKERROR);
    if (!rdi_pl_trainerror) begin
      $display("FAIL ut_rdi_sm: trainerror not reported");
      errors = errors + 1;
    end
    phy_train_error = 1'b0;
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    step_to("recover", RDI_STS_LINKRESET);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    step_to("active5", RDI_STS_ACTIVE);

    // ACTIVE -> DISABLED
    rdi_lp_state_req = RDI_REQ_DISABLED;
    step_to("disabled", RDI_STS_DISABLED);

    // Physical reset forces RESET regardless of the request.
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    repeat (2) @(posedge lclk);
    phy_link_reset = 1'b1;
    @(posedge lclk); #0.1;
    chk("forced reset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    step_to("active6", RDI_STS_ACTIVE);

    // Stall handshake 8.3.1: ack tracks the request.
    stall_req = 1'b1;
    @(posedge lclk); #0.1;
    if (!stall_ack) begin
      $display("FAIL ut_rdi_sm: stall_ack did not follow stall_req");
      errors = errors + 1;
    end
    stall_req = 1'b0;
    @(posedge lclk); #0.1;
    if (stall_ack) begin
      $display("FAIL ut_rdi_sm: stall_ack stuck high");
      errors = errors + 1;
    end

    // Error flags forward to the RDI outputs.
    cerror = 1'b1; nferror = 1'b1;
    @(posedge lclk); #0.1;
    if (!rdi_pl_cerror || !rdi_pl_nferror) begin
      $display("FAIL ut_rdi_sm: error flags not forwarded");
      errors = errors + 1;
    end
    cerror = 1'b0; nferror = 1'b0;

    // In-band presence passes through.
    phy_inband_pres = 1'b1;
    @(posedge lclk); #0.1;
    if (!rdi_pl_inband_pres) begin
      $display("FAIL ut_rdi_sm: inband_pres not forwarded");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_rdi_sm");
    else             $display("FAIL ut_rdi_sm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_rdi_sm: watchdog, state %01h", rdi_pl_state_sts);
    $finish;
  end

endmodule

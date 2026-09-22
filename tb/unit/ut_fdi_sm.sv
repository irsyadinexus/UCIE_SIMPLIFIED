// Unit test: fdi_state_machine. Drives the FDI mirror of the RDI through
// RESET -> ACTIVE -> PMNAK -> ACTIVE -> L1 -> LINKRESET -> LINKERROR ->
// RESET, and checks the four-way active-entry handshake of 8.2.6.
`timescale 1ns/1ps
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ut_fdi_sm;
  logic        lclk, lreset_n;
  logic [3:0]  lp_state_req;
  logic [3:0]  pl_state_sts;
  logic        pl_inband_pres;
  logic        pl_error;
  logic        pl_cerror, pl_nferror, pl_trainerror, pl_phyinrecenter;
  logic [2:0]  pl_protocol;
  logic [3:0]  pl_protocol_flitfmt;
  logic        pl_rx_active_req;
  logic        lp_rx_active_sts;
  logic [7:0]  lp_stream;
  logic [7:0]  pl_stream;
  logic [3:0]  rdi_state_sts;
  logic        rdi_inband_pres;
  logic        rdi_trainerror;
  logic        rdi_phyinrecenter;
  logic        rdi_cerror;
  logic        rdi_nferror;
  logic        adapter_active_req;
  logic        adapter_state_req_vld;
  logic [3:0]  adapter_state_req;
  logic        fdi_active_req;
  logic [3:0]  fdi_state_req_out;
  logic        fdi_state_req_vld;
  int          errors;

  fdi_state_machine u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .lp_state_req(lp_state_req),
    .pl_state_sts(pl_state_sts),
    .pl_inband_pres(pl_inband_pres),
    .pl_error(pl_error),
    .pl_cerror(pl_cerror), .pl_nferror(pl_nferror),
    .pl_trainerror(pl_trainerror), .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol(pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_rx_active_sts(lp_rx_active_sts),
    .lp_stream(lp_stream), .pl_stream(pl_stream),
    .rdi_state_sts(rdi_state_sts),
    .rdi_inband_pres(rdi_inband_pres),
    .rdi_trainerror(rdi_trainerror),
    .rdi_phyinrecenter(rdi_phyinrecenter),
    .rdi_cerror(rdi_cerror), .rdi_nferror(rdi_nferror),
    .adapter_active_req(adapter_active_req),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .fdi_active_req(fdi_active_req),
    .fdi_state_req_out(fdi_state_req_out),
    .fdi_state_req_vld(fdi_state_req_vld)
  );

  initial lclk = 1'b0;
  always #0.5 lclk = ~lclk;

  task chk;
    input [64*8-1:0] label;
    input [3:0]      exp;
    begin
      if (pl_state_sts !== exp) begin
        $display("FAIL ut_fdi_sm: %s: got %01h want %01h", label,
                 pl_state_sts, exp);
        errors = errors + 1;
      end
    end
  endtask

  // Step the FDI by moving the RDI status, then waiting for FDI to follow.
  task step_to;
    input [64*8-1:0] label;
    input [3:0]      exp_rdi;
    input [3:0]      exp_fdi;
    begin
      rdi_state_sts = exp_rdi;
      fork
        begin
          wait (pl_state_sts == exp_fdi);
          #0.1;
        end
        begin
          repeat (2000) @(posedge lclk);
        end
      join_any
      chk(label, exp_fdi);
    end
  endtask

  initial begin
    errors = 0;
    lreset_n        = 1'b0;
    lp_state_req    = 4'h0;
    lp_rx_active_sts= 1'b0;
    lp_stream       = 8'h00;
    rdi_state_sts   = 4'h0;
    rdi_inband_pres = 1'b0;
    rdi_trainerror  = 1'b0;
    rdi_phyinrecenter = 1'b0;
    rdi_cerror      = 1'b0;
    rdi_nferror     = 1'b0;
    adapter_active_req = 1'b0;
    adapter_state_req_vld = 1'b0;
    adapter_state_req = 4'h0;

    #5 lreset_n = 1'b1;
    @(negedge lclk);
    chk("reset", 4'h0);

    // 8.2.6 four-way handshake: the Rx-active request follows the RDI into
    // Active before the FDI itself moves.
    step_to("rdi active alone", RDI_STS_ACTIVE, 4'h0);
    if (!pl_rx_active_req) begin
      $display("FAIL ut_fdi_sm: pl_rx_active_req low with RDI Active");
      errors = errors + 1;
    end
    lp_rx_active_sts = 1'b1;
    step_to("fdi active", RDI_STS_ACTIVE, 4'h1);

    // Streaming and Format 1 Raw are fixed for this PoC.
    if (pl_protocol !== PROTO_STREAMING) begin
      $display("FAIL ut_fdi_sm: protocol %01h", pl_protocol);
      errors = errors + 1;
    end
    if (pl_protocol_flitfmt !== FMT_RAW) begin
      $display("FAIL ut_fdi_sm: flitfmt %01h", pl_protocol_flitfmt);
      errors = errors + 1;
    end

    // PMNAK while the partner has not answered.
    step_to("pmnak", RDI_STS_PMNAK, 4'h3);
    step_to("active again", RDI_STS_ACTIVE, 4'h1);

    // L1 then back through LinkReset.
    step_to("l1", RDI_STS_L1, 4'h4);
    step_to("linkreset", RDI_STS_LINKRESET, 4'h9);
    step_to("reset", RDI_STS_RESET, 4'h0);

    // Re-enter Active for the error paths.
    step_to("active2", RDI_STS_ACTIVE, 4'h1);
    rdi_trainerror = 1'b1;
    step_to("linkerror", RDI_STS_LINKERROR, 4'hA);
    if (!pl_trainerror) begin
      $display("FAIL ut_fdi_sm: trainerror not forwarded");
      errors = errors + 1;
    end
    rdi_trainerror = 1'b0;
    step_to("linkreset2", RDI_STS_LINKRESET, 4'h9);
    step_to("reset2", RDI_STS_RESET, 4'h0);

    // Retrain path.
    step_to("active3", RDI_STS_ACTIVE, 4'h1);
    rdi_phyinrecenter = 1'b1;
    step_to("retrain", RDI_STS_RETRAIN, 4'hB);
    if (!pl_phyinrecenter) begin
      $display("FAIL ut_fdi_sm: phyinrecenter not forwarded");
      errors = errors + 1;
    end
    rdi_phyinrecenter = 1'b0;
    step_to("active4", RDI_STS_ACTIVE, 4'h1);

    // DISABLED only leaves through Reset or LinkReset.
    step_to("disabled", RDI_STS_DISABLED, 4'hC);
    step_to("reset3", RDI_STS_RESET, 4'h0);

    // Re-enter Active: in-band presence is sticky until a state clears it.
    step_to("active4", RDI_STS_ACTIVE, 4'h1);
    rdi_inband_pres = 1'b1;
    repeat (3) @(posedge lclk);
    if (!pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not asserted");
      errors = errors + 1;
    end
    rdi_inband_pres = 1'b0;
    repeat (3) @(posedge lclk);
    if (!pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not sticky in Active");
      errors = errors + 1;
    end
    // Leaving to Reset clears it.
    step_to("reset4", RDI_STS_RESET, 4'h0);
    repeat (3) @(posedge lclk);
    if (pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not cleared by Reset");
      errors = errors + 1;
    end

    // Correctable and non-fatal errors forward.
    rdi_cerror = 1'b1; rdi_nferror = 1'b1;
    @(posedge lclk); #0.1;
    if (!pl_cerror || !pl_nferror) begin
      $display("FAIL ut_fdi_sm: error flags not forwarded");
      errors = errors + 1;
    end
    rdi_cerror = 1'b0; rdi_nferror = 1'b0;

    // The stream id passes straight through.
    lp_stream = 8'hA5;
    @(posedge lclk); #0.1;
    if (pl_stream !== 8'hA5) begin
      $display("FAIL ut_fdi_sm: stream %02h", pl_stream);
      errors = errors + 1;
    end

    // An Active request from the Protocol Layer forwards to the RDI only when
    // the local side and the partner have both asked for Active (8.1.6).
    lp_state_req = FDI_REQ_ACTIVE;
    adapter_active_req = 1'b0;
    repeat (2) @(posedge lclk); #0.1;
    if (fdi_state_req_vld) begin
      $display("FAIL ut_fdi_sm: req forwarded without partner Active");
      errors = errors + 1;
    end
    adapter_active_req = 1'b1;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_ACTIVE) begin
      $display("FAIL ut_fdi_sm: Active request not forwarded");
      errors = errors + 1;
    end

    // Non-Active requests forward unconditionally.
    lp_state_req = FDI_REQ_LINKRESET;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_LINKRESET) begin
      $display("FAIL ut_fdi_sm: LinkReset request not forwarded");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_fdi_sm");
    else             $display("FAIL ut_fdi_sm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_fdi_sm: watchdog, state %01h", pl_state_sts);
    $finish;
  end

endmodule

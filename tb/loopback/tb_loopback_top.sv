// UCIe 1.0 Simplified Endpoint - two-end loopback testbench.
//
// Two real ucie_main instances are crossed: sideband and main band both cross
// die-to-die. Each die is driven by its own protocol layer BFM. The testbench
// brings the pair from reset to LINK ACTIVE and then pushes streaming data
// through the adapter of each die.
//
// Data path note: the logical PHY in this reduced capability set does not
// terminate the streaming data (see logical_phy.sv); the RDI datapath is a
// pass-through. Data offered on lp_data of die A therefore reappears on the
// pl_data of die A after the round trip through the adapter. The scoreboard
// checks that round trip on each die, one direction named forward on die 0
// and one direction named reverse on die 1.
`ifndef TbLoopbackTop_SV
`define TbLoopbackTop_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module tb_loopback_top;

  // ------------------------------------------------------- clocks
  // 500 MHz lclk. The sideband clock is the same domain; an async sideband
  // clock would sample the single-UI sb_tx_load pulse unreliably in a
  // functional model before Phase 3 CDC is added.
  logic lclk;
  logic sbclk;

  initial begin
    lclk  = 1'b0;
    sbclk = 1'b0;
  end
  always #1.0 lclk  = ~lclk;
  always #1.0 sbclk = ~sbclk;

  // ------------------------------------------------------- reset
  logic lreset_n;
  logic sbreset_n;

  initial begin
    lreset_n  = 1'b0;
    sbreset_n = 1'b0;
    #20;
    @(negedge lclk);
    lreset_n  = 1'b1;
    sbreset_n = 1'b1;
  end

  // ------------------------------------------------------- die crossing
  logic [NC-1:0]       sb_a2b_data, sb_b2a_data;
  logic                sb_a2b_valid, sb_b2a_valid;
  logic [NLANES_MAX-1:0] mb_a2b, mb_b2a;

  // ------------------------------------------------------- die 0
  logic        d0_start_link_train;
  logic        d0_lp_irdy, d0_lp_valid;
  logic [DATA_W-1:0] d0_lp_data;
  logic [7:0]  d0_lp_stream;
  logic        d0_lp_stallack, d0_lp_rx_active_sts;
  logic        d0_pl_trdy, d0_pl_valid;
  logic [DATA_W-1:0] d0_pl_data;
  logic [7:0]  d0_pl_stream;
  logic [3:0]  d0_lp_state_req, d0_pl_state_sts;
  logic        d0_link_active_obs;
  logic        d0_pl_stallreq;
  logic [7:0]  d0_ltsm_state;
  logic [3:0]  d0_rdi_state_sts;
  logic [4:0]  d0_sb_rx_opcode;
  logic [7:0]  d0_sb_rx_msgcode;
  logic        d0_sb_rx_pkt_vld;

  // ------------------------------------------------------- die 1
  logic        d1_start_link_train;
  logic        d1_lp_irdy, d1_lp_valid;
  logic [DATA_W-1:0] d1_lp_data;
  logic [7:0]  d1_lp_stream;
  logic        d1_lp_stallack, d1_lp_rx_active_sts;
  logic        d1_pl_trdy, d1_pl_valid;
  logic [DATA_W-1:0] d1_pl_data;
  logic [7:0]  d1_pl_stream;
  logic [3:0]  d1_lp_state_req, d1_pl_state_sts;
  logic        d1_link_active_obs;
  logic        d1_pl_stallreq;
  logic [7:0]  d1_ltsm_state;
  logic [3:0]  d1_rdi_state_sts;
  logic [4:0]  d1_sb_rx_opcode;
  logic [7:0]  d1_sb_rx_msgcode;
  logic        d1_sb_rx_pkt_vld;

  // ------------------------------------------------------- observed wires
  // The RDI status is an internal net of ucie_main; hierarchical access from
  // the testbench reads it for coverage only.
  wire [3:0] rdi_sts_0 = dut_a.u_lphy.u_rdi_sm.state_q;
  wire [3:0] rdi_sts_1 = dut_b.u_lphy.u_rdi_sm.state_q;
  assign d0_rdi_state_sts = rdi_sts_0;
  assign d1_rdi_state_sts = rdi_sts_1;

  wire [7:0] ltsm_0 = dut_a.u_lphy.u_ltsm.state_q;
  wire [7:0] ltsm_1 = dut_b.u_lphy.u_ltsm.state_q;
  assign d0_ltsm_state = ltsm_0;
  assign d1_ltsm_state = ltsm_1;

  assign d0_sb_rx_opcode   = dut_a.u_lphy.u_sb_codec.rx_opcode;
  assign d0_sb_rx_msgcode  = dut_a.u_lphy.u_sb_codec.rx_msgcode;
  assign d0_sb_rx_pkt_vld  = dut_a.u_lphy.sb_rx_pkt_vld;
  assign d1_sb_rx_opcode   = dut_b.u_lphy.u_sb_codec.rx_opcode;
  assign d1_sb_rx_msgcode  = dut_b.u_lphy.u_sb_codec.rx_msgcode;
  assign d1_sb_rx_pkt_vld  = dut_b.u_lphy.sb_rx_pkt_vld;
  assign d0_link_active_obs = dut_a.link_active_obs;
  assign d1_link_active_obs = dut_b.link_active_obs;

  // ------------------------------------------------------- DUTs
  ucie_main dut_a (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .start_link_train(d0_start_link_train),
    .lp_irdy         (d0_lp_irdy),
    .lp_valid        (d0_lp_valid),
    .lp_data         (d0_lp_data),
    .lp_stream       (d0_lp_stream),
    .lp_stallack     (d0_lp_stallack),
    .lp_rx_active_sts(d0_lp_rx_active_sts),
    .pl_trdy         (d0_pl_trdy),
    .pl_valid        (d0_pl_valid),
    .pl_data         (d0_pl_data),
    .pl_stream       (d0_pl_stream),
    .pl_error        (),
    .pl_cerror       (),
    .pl_nferror      (),
    .pl_trainerror   (),
    .pl_phyinrecenter(),
    .pl_protocol     (),
    .pl_protocol_flitfmt(),
    .pl_rx_active_req(),
    .lp_state_req    (d0_lp_state_req),
    .pl_state_sts    (d0_pl_state_sts),
    .pl_inband_pres  (),
    .pl_stallreq     (d0_pl_stallreq),
    .lp_linkerror    (),
    .sb_tx_data      (sb_b2a_data),
    .sb_tx_valid     (sb_b2a_valid),
    .sb_rx_data      (sb_a2b_data),
    .sb_rx_valid     (sb_a2b_valid),
    .mb_tx_data      (mb_b2a),
    .mb_rx_data      (mb_a2b)
  );

  ucie_main dut_b (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .start_link_train(d1_start_link_train),
    .lp_irdy         (d1_lp_irdy),
    .lp_valid        (d1_lp_valid),
    .lp_data         (d1_lp_data),
    .lp_stream       (d1_lp_stream),
    .lp_stallack     (d1_lp_stallack),
    .lp_rx_active_sts(d1_lp_rx_active_sts),
    .pl_trdy         (d1_pl_trdy),
    .pl_valid        (d1_pl_valid),
    .pl_data         (d1_pl_data),
    .pl_stream       (d1_pl_stream),
    .pl_error        (),
    .pl_cerror       (),
    .pl_nferror      (),
    .pl_trainerror   (),
    .pl_phyinrecenter(),
    .pl_protocol     (),
    .pl_protocol_flitfmt(),
    .pl_rx_active_req(),
    .lp_state_req    (d1_lp_state_req),
    .pl_state_sts    (d1_pl_state_sts),
    .pl_inband_pres  (),
    .pl_stallreq     (d1_pl_stallreq),
    .lp_linkerror    (),
    .sb_tx_data      (sb_a2b_data),
    .sb_tx_valid     (sb_a2b_valid),
    .sb_rx_data      (sb_b2a_data),
    .sb_rx_valid     (sb_b2a_valid),
    .mb_tx_data      (mb_a2b),
    .mb_rx_data      (mb_b2a)
  );

  // ------------------------------------------------------- BFM stimulus
  // Each die plays its own protocol layer. The request and the active status
  // are held for the whole run: the link management messages are not
  // transported in this reduced PoC, so the testbench supplies them.
  initial begin
    d0_start_link_train = 1'b0;
    d0_lp_state_req     = FDI_REQ_ACTIVE;
    d0_lp_rx_active_sts = 1'b1;
    d0_lp_irdy          = 1'b0;
    d0_lp_valid         = 1'b0;
    d0_lp_data          = '0;
    d0_lp_stream        = STREAM_ID_S0_STREAMING;
    d0_lp_stallack      = 1'b0;

    d1_start_link_train = 1'b0;
    d1_lp_state_req     = FDI_REQ_ACTIVE;
    d1_lp_rx_active_sts = 1'b1;
    d1_lp_irdy          = 1'b0;
    d1_lp_valid         = 1'b0;
    d1_lp_data          = '0;
    d1_lp_stream        = STREAM_ID_S0_STREAMING;
    d1_lp_stallack      = 1'b0;

    @(negedge lclk);
    #1;
    d0_start_link_train = 1'b1;
    d1_start_link_train = 1'b1;
  end

  // ------------------------------------------------------- transfer events
  logic xfer_done_0, xfer_done_1;
  logic [DATA_W-1:0] last_sent_0, last_sent_1;
  logic [DATA_W-1:0] last_recv_0, last_recv_1;

  // A completed UI on the receive side of die 0 is the reverse direction, and
  // on die 1 the forward direction, because the BFM pair is symmetric.
  always @(posedge lclk) begin
    if (d0_pl_valid && d0_pl_trdy) begin
      last_recv_0 <= d0_pl_data;
      xfer_done_1 <= ~xfer_done_1;
    end
    if (d1_pl_valid && d1_pl_trdy) begin
      last_recv_1 <= d1_pl_data;
      xfer_done_0 <= ~xfer_done_0;
    end
  end

  initial begin
    xfer_done_0 = 1'b0;
    xfer_done_1 = 1'b0;
    last_sent_0 = '0;
    last_sent_1 = '0;
    last_recv_0 = '0;
    last_recv_1 = '0;
  end

  // ------------------------------------------------------- stall detector
  // A four-phase stall is req -> ack -> valid and irdy low -> both low.
  logic stall_4phase;
  logic stall_seen_req, stall_seen_ack, stall_seen_stop;

  always @(posedge lclk) begin
    if (!lreset_n) begin
      stall_seen_req  <= 1'b0;
      stall_seen_ack  <= 1'b0;
      stall_seen_stop <= 1'b0;
    end else begin
      if (d0_pl_stallreq && !stall_seen_req)
        stall_seen_req <= 1'b1;
      if (stall_seen_req && d0_lp_stallack && !stall_seen_ack)
        stall_seen_ack <= 1'b1;
      if (stall_seen_ack && !d0_lp_valid && !d0_lp_irdy && !stall_seen_stop)
        stall_seen_stop <= 1'b1;
      if (stall_seen_stop && !d0_pl_stallreq && !d0_lp_stallack)
        stall_4phase <= ~stall_4phase;
    end
  end

  initial stall_4phase = 1'b0;

  // ------------------------------------------------------- width / reversal
  // The x16-only PoC never degrades, so these stay observation-only and are
  // exercised by the mapper unit test instead. They are wired so the coverage
  // model is complete, and held at the never-degraded value.
  logic width_degrade;
  logic lane_reversal;
  initial begin
    width_degrade = 1'b0;
    lane_reversal = 1'b0;
  end

  // ------------------------------------------------------- capability ads
  // AdvCap.Adapter advertises Raw_Mode (bit 0), Streaming (bit 4) and
  // Stack0_Enable (bit 7). No-CRC is not a bit in AdvCap; it is implied by
  // 4 GT/s. The advertisement appears on the sideband during MBINIT.PARAM.
  logic raw_mode_adv, crc_off_adv;
  initial begin
    raw_mode_adv = 1'b1;
    crc_off_adv  = 1'b1;
  end

  // ------------------------------------------------------- monitor
  cov_monitor u_cov (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .ltsm_state_0    (d0_ltsm_state),
    .link_active_0   (d0_link_active_obs),
    .sb_rx_opcode_0  (d0_sb_rx_opcode),
    .sb_rx_msgcode_0 (d0_sb_rx_msgcode),
    .sb_rx_pkt_vld_0 (d0_sb_rx_pkt_vld),
    .rdi_state_sts_0 (d0_rdi_state_sts),
    .ltsm_state_1    (d1_ltsm_state),
    .link_active_1   (d1_link_active_obs),
    .sb_rx_opcode_1  (d1_sb_rx_opcode),
    .sb_rx_msgcode_1 (d1_sb_rx_msgcode),
    .sb_rx_pkt_vld_1 (d1_sb_rx_pkt_vld),
    .rdi_state_sts_1 (d1_rdi_state_sts),
    .xfer_done_0     (xfer_done_0),
    .xfer_done_1     (xfer_done_1),
    .stall_4phase    (stall_4phase),
    .width_degrade   (width_degrade),
    .lane_reversal   (lane_reversal),
    .raw_mode_adv    (raw_mode_adv),
    .crc_off_adv     (crc_off_adv)
  );
  reg [1024*8-1:0] cov_path;

  // ------------------------------------------------------- main sequence
  integer errors;
  integer i;
  logic [DATA_W-1:0] exp_data;
  logic [DATA_W-1:0] got_data;

  task push_one;
    input [64*8-1:0] label;
    input integer    which;      // 0 = die 0 forward, 1 = die 1 reverse
    input [DATA_W-1:0] data;
    begin
      if (which == 0) begin
        @(negedge lclk);
        d0_lp_data  = data;
        d0_lp_valid = 1'b1;
        d0_lp_irdy  = 1'b1;
        // The adapter registers the request, so one extra cycle before the
        // data appears on the receive side.
        repeat (3) @(posedge lclk);
        #0.1;
        got_data = d0_pl_data;
        if (got_data !== data) begin
          $display("FAIL %0s: die0 data %032h expected %032h", label, got_data, data);
          errors = errors + 1;
        end else begin
          $display("PASS %0s: die0 data %032h", label, data);
        end
        @(negedge lclk);
        d0_lp_valid = 1'b0;
        d0_lp_irdy  = 1'b0;
      end else begin
        @(negedge lclk);
        d1_lp_data  = data;
        d1_lp_valid = 1'b1;
        d1_lp_irdy  = 1'b1;
        repeat (3) @(posedge lclk);
        #0.1;
        got_data = d1_pl_data;
        if (got_data !== data) begin
          $display("FAIL %0s: die1 data %032h expected %032h", label, got_data, data);
          errors = errors + 1;
        end else begin
          $display("PASS %0s: die1 data %032h", label, data);
        end
        @(negedge lclk);
        d1_lp_valid = 1'b0;
        d1_lp_irdy  = 1'b0;
      end
    end
  endtask

  initial begin
    errors = 0;
    i      = 0;

    // ---- wait for link active on both dies
    wait (lreset_n === 1'b1);
    while (!(d0_link_active_obs && d1_link_active_obs)) begin
      @(posedge lclk);
      i = i + 1;
      if (i > 200000) begin
        $display("FAIL bring-up timeout: die0 active %b die1 active %b",
                 d0_link_active_obs, d1_link_active_obs);
        $display("     die0 LTSM %02h die1 LTSM %02h", d0_ltsm_state, d1_ltsm_state);
        errors = errors + 1;
        u_cov.export_json(cov_path);
        $finish;
      end
    end
    $display("LINK ACTIVE (die 0)");
    $display("LINK ACTIVE (die 1)");

    // ---- streaming data, both directions
    push_one("RAW MODE TRANSFER OK (die0->die1)", 0, {8{8'h11}});
    push_one("RAW MODE TRANSFER OK (die1->die0)", 1, {8{8'h22}});
    push_one("burst die0", 0, {8{8'h33}});
    push_one("burst die1", 1, {8{8'h44}});
    push_one("burst die0", 0, {8{8'h55}});
    push_one("burst die1", 1, {8{8'h66}});
    push_one("burst die0", 0, {8{8'h77}});
    push_one("burst die1", 1, {8{8'h88}});

    // ---- settle and report
    repeat (20) @(posedge lclk);
    u_cov.export_json(cov_path);

    if (errors == 0)
      $display("TEST PASSED tb_loopback_top");
    else
      $display("TEST FAILED tb_loopback_top: %0d errors", errors);
    $finish;
  end

  // ------------------------------------------------------- watchdog
  initial begin
    cov_path = "logs/coverage.json";
    void'($value$plusargs("covfile=%s", cov_path));
    #(2_000_000);
    $display("FAIL tb_loopback_top: watchdog at %0t", $time);
    u_cov.export_json(cov_path);
    $finish;
  end
endmodule
`endif

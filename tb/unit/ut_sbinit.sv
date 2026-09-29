// ============================================================================
// File        : ut_sbinit.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Module      : Unit Test — SBINIT Raw Waveform and Atomic Events
// Description : Directly checks the private logical-PHY SBINIT primitive.
//               It verifies the exact 64-UI alternating waveform, the 32-UI
//               low boundary, one local-completion event, and ordered atomic
//               remote match/mismatch events. LTSM policy remains covered by
//               ut_ltsm and is not duplicated here.
//
// Revision history
// ----------------
//   v0.0.1  2026-09-24  Add direct SBINIT waveform and event-mailbox checks.
//   v0.0.2  2026-09-25  Connect the Phase D private Adapter Start input with
//                       a zero tie-off. Preserve this direct SBINIT proof.
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_sbinit;
  logic lclk;
  logic mbclk;
  logic sbclk;
  logic lreset_n;
  logic sbreset_n;

  logic        sb_tx_clk;
  logic        sb_tx_data;
  logic        sb_rx_clk;
  logic        sb_rx_data;

  integer errors;
  integer tx_event_count;
  integer rx_event_count;
  logic   rx_event_match [0:3];

  // The logical_phy module is instantiated with scalar physical sideband pins
  // (sb_tx_clk/data, sb_rx_clk/data) and adapter sideband ports. Hierarchical force
  // is limited to the two private LTSM control levels so this unit can exercise
  // the embedded raw primitive without waiting for the 4 ms RESET policy.
  logical_phy #(
    .NBYTES(NBYTES),
    .NLANES(NLANES_MAX)
  ) u_dut (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .mbclk(mbclk),
    .sbclk(sbclk),
    .sbreset_n(sbreset_n),
    .start_link_train(1'b0),
    .adapter_start_link_train(1'b0),
    .rdi_lp_state_req('0),
    .rdi_lp_stallack(1'b0),
    .rdi_lp_linkerror(1'b0),
    .rdi_pl_state_sts(),
    .rdi_pl_inband_pres(),
    .rdi_pl_linkerror(),
    .rdi_pl_phyinrecenter(),
    .rdi_pl_cerror(),
    .rdi_pl_nferror(),
    .rdi_pl_trainerror(),
    .rdi_lp_irdy(1'b0),
    .rdi_lp_valid(1'b0),
    .rdi_lp_data('0),
    .rdi_pl_trdy(),
    .rdi_pl_valid(),
    .rdi_pl_data(),
    .rdi_pl_lnk_cfg(),
    .rdi_pl_speedmode(),
    .rdi_pl_stallreq(),
    .adapter_active_req(1'b0),
    .sb_tx_clk(sb_tx_clk),
    .sb_tx_data(sb_tx_data),
    .sb_rx_clk(sb_rx_clk),
    .sb_rx_data(sb_rx_data),
    .adapter_sb_tx_valid(1'b0),
    .adapter_sb_tx_ready(),
    .adapter_sb_tx_packet('0),
    .adapter_sb_rx_valid(),
    .adapter_sb_rx_ready(1'b1),
    .adapter_sb_rx_packet(),
    .adapter_sb_rx_cp_error(),
    .adapter_sb_rx_dp_error(),
    .adapter_sb_rx_format_error(),
    .phy_csr_wr(1'b0),
    .phy_csr_rd(1'b0),
    .phy_csr_addr('0),
    .phy_csr_wdata('0),
    .phy_csr_be('0),
    .phy_csr_rdata(),
    .phy_csr_rdata_vld(),
    .mb_tx_data(),
    .mb_tx_valid(),
    .mb_rx_data('0),
    .mb_rx_valid(1'b0),
    .lp_cfg('0),
    .lp_cfg_vld(1'b0),
    .lp_cfg_crd(1'b0),
    .pl_cfg(),
    .pl_cfg_vld(),
    .pl_cfg_crd()
  );

  initial begin
    lclk  = 1'b0;
    mbclk = 1'b0;
    sbclk = 1'b0;
  end
  always #1.000 lclk  = ~lclk;
  always #0.250 mbclk = ~mbclk;
  initial begin
    #0.1875;
    forever #0.625 sbclk = ~sbclk;
  end

  // Capture each mailbox destination pulse and its 1-bit atomic event flag in the
  // same lclk sample. A duplicate pulse or a dropped flag changes the event counts.
  always @(posedge lclk) begin
    #0.01;
    if (!lreset_n) begin
      tx_event_count = 0;
      rx_event_count = 0;
    end else begin
      if (u_dut.sbinit_tx_iter_done)
        tx_event_count = tx_event_count + 1;
      if (u_dut.sbinit_rx_iter_vld) begin
        if (rx_event_count < 4)
          rx_event_match[rx_event_count] = u_dut.sbinit_rx_iter_match;
        rx_event_count = rx_event_count + 1;
      end
    end
  end

  // Check one complete transmitted iteration. The caller lowers the private
  // run level during the active burst. The primitive must still finish all
  // 64 active UIs and all 32 low UIs before it becomes idle.
  task check_tx_iteration;
    integer ui;
    logic expected_bit;
    begin
      @(posedge sb_tx_clk);
      #0.01;
      for (ui = 0; ui < SBINIT_PATTERN_UI; ui = ui + 1) begin
        expected_bit = (ui % 2 == 0) ? 1'b1 : 1'b0;
        if (sb_tx_data !== expected_bit) begin
          $display("FAIL ut_sbinit: TX active UI %0d got data=%b",
                   ui, sb_tx_data);
          errors = errors + 1;
        end
        if (ui != (SBINIT_PATTERN_UI - 1)) begin
          @(posedge sb_tx_clk);
          #0.01;
        end
      end

      @(posedge sbclk);
      #0.01;
      for (ui = 0; ui < SBINIT_LOW_UI; ui = ui + 1) begin
        if (sb_tx_data !== 1'b0) begin
          $display("FAIL ut_sbinit: TX low UI %0d was not idle-low", ui);
          errors = errors + 1;
        end
        if (ui != (SBINIT_LOW_UI - 1)) begin
          @(posedge sbclk);
          #0.01;
        end
      end

      @(posedge sbclk);
      #0.01;
      if ((sb_tx_clk !== 1'b0) ||
          (u_dut.u_sb_init_raw.raw_tx_state_q !== 2'd0)) begin
        $display("FAIL ut_sbinit: TX did not stop at the low boundary");
        errors = errors + 1;
      end
    end
  endtask

  // Drive one remote candidate at the physical sideband pins. flip_ui < 0
  // produces a match. A nonnegative index flips exactly one active UI and
  // must produce one atomic mismatch result after the complete low boundary.
  task drive_rx_iteration;
    input integer flip_ui;
    integer ui;
    logic value;
    begin
      @(negedge sbclk);
      for (ui = 0; ui < SBINIT_PATTERN_UI; ui = ui + 1) begin
        value = (ui % 2 == 0) ? 1'b1 : 1'b0;
        if (ui == flip_ui) value = ~value;
        sb_rx_data = value;
        sb_rx_clk  = 1'b1;
        @(posedge sbclk);
        sb_rx_clk  = 1'b0;
        if (ui != (SBINIT_PATTERN_UI - 1))
          @(negedge sbclk);
      end
      for (ui = 0; ui < SBINIT_LOW_UI; ui = ui + 1) begin
        @(negedge sbclk);
        sb_rx_clk  = 1'b0;
        sb_rx_data = 1'b0;
        @(posedge sbclk);
      end
    end
  endtask

  initial begin
    errors         = 0;
    tx_event_count = 0;
    rx_event_count = 0;
    rx_event_match[0] = 1'b0;
    rx_event_match[1] = 1'b0;
    rx_event_match[2] = 1'b0;
    rx_event_match[3] = 1'b0;
    lreset_n       = 1'b0;
    sbreset_n      = 1'b0;
    sb_rx_clk      = 1'b0;
    sb_rx_data     = 1'b0;

    force u_dut.pattern_run_enable = 1'b0;
    force u_dut.sbinit_raw_mode    = 1'b1;

    repeat (5) @(posedge lclk);
    @(negedge lclk);
    lreset_n  = 1'b1;
    sbreset_n = 1'b1;
    repeat (6) @(posedge sbclk);

    // Start one iteration, then lower the control during its active burst.
    force u_dut.pattern_run_enable = 1'b1;
    fork
      check_tx_iteration();
      begin
        @(posedge sb_tx_clk);
        repeat (4) @(posedge sbclk);
        force u_dut.pattern_run_enable = 1'b0;
      end
    join

    wait (tx_event_count >= 1);
    repeat (8) @(posedge lclk);
    if (tx_event_count !== 1) begin
      $display("FAIL ut_sbinit: local completion event count %0d", tx_event_count);
      errors = errors + 1;
    end

    // A complete waveform yields match=1. A single flipped active UI yields
    // match=0. Each complete candidate produces exactly one destination pulse.
    drive_rx_iteration(-1);
    wait (rx_event_count >= 1);
    drive_rx_iteration(17);
    wait (rx_event_count >= 2);
    repeat (8) @(posedge lclk);
    if ((rx_event_count !== 2) ||
        (rx_event_match[0] !== 1'b1) ||
        (rx_event_match[1] !== 1'b0)) begin
      $display("FAIL ut_sbinit: atomic RX events count=%0d values=%b,%b",
               rx_event_count, rx_event_match[0], rx_event_match[1]);
      errors = errors + 1;
    end

    release u_dut.pattern_run_enable;
    release u_dut.sbinit_raw_mode;

    if (errors == 0) $display("TEST PASSED ut_sbinit");
    else             $display("FAIL ut_sbinit: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL ut_sbinit: watchdog timeout");
    $finish;
  end
endmodule

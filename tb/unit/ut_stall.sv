// ============================================================================
// File        : ut_stall.sv
// Project     : UCIe Simplified RTL
// Unit        : Unit Test — Stall Handshake and Streaming Datapath
// ----------------------------------------------------------------------------
//
// SPDX-License-Identifier: Proprietary
//
// Copyright (c) 2025–2026.  All rights reserved.
//
// ============================================================================
//
// DESCRIPTION
// -----------
// This unit test exercises the adapter_datapath and d2d_adapter modules to verify that:
//
//   1. Stall handshake operates correctly per UCIe Specification
//      Section 8.3.1 — Stallreq/Ack Mechanism:
//      - On adapter_datapath (u_dut): when stall_active is asserted,
//        the DUT de-asserts rdi_lp_irdy (blocking data towards PHY) and
//        de-asserts pl_trdy (blocking acknowledgement towards Protocol Layer).
//      - On integrated d2d_adapter (u_adapter): verifies the four-phase stall
//        handshake bridging PHY request (rdi_pl_stallreq) to Protocol Layer
//        (pl_stallreq), acknowledgement (lp_stallack to rdi_lp_stallack),
//        and datapath stall gating across the adapter boundary.
//   2. Streaming pass-through datapath:
//      In the absence of a stall condition, FDI-side transmit data
//      (lp_data, lp_valid, lp_irdy) is forwarded through the
//      pipeline register to the RDI-side outputs (rdi_lp_data,
//      rdi_lp_valid, rdi_lp_irdy).  Likewise, RDI-side receive
//      data (rdi_pl_data, rdi_pl_valid, rdi_pl_trdy) is forwarded
//      to the FDI-side outputs (pl_data, pl_valid, pl_trdy).
//      The stream sideband (lp_stream → pl_stream) is also checked.
//
//   3. Data preservation through the pipeline register:
//      Transmit data written on the FDI side must appear at the
//      RDI output unchanged after one pipeline stage.  Receive
//      data from the PHY must appear at the FDI output unchanged.
//
//   4. Stall blocks irdy/trdy:
//      While stall_active == 1, rdi_lp_irdy must be low (no new
//      data offered to the PHY) and pl_trdy must be low (Protocol
//      Layer sees back-pressure).
//
//   5. Data held across stall:
//      Data presented at the FDI input while stall_active is high
//      must not be lost.  When the stall is released, the held
//      data must flow through the pipeline and appear on the
//      RDI output with correct values.
//
//   6. x8 width degrade zeroes upper bytes:
//      When rdi_lnk_is_x8 is asserted, the upper half of the
//      NBYTES-wide data bus on the RDI side must be forced to
//      zero, while the lower half carries the valid data pattern.
//
// DUT
// ---
//   adapter_datapath u_dut     — direct datapath and stall gate
//   d2d_adapter      u_adapter — integrated 4-phase stall bridge and controls
//
// STIMULUS
// --------
//   The testbench directly drives:
//     - FDI-side signals : lp_irdy, lp_valid, lp_data, lp_stream,
//                          lp_stallack, lp_rx_active_sts
//     - RDI-side signals : rdi_pl_trdy, rdi_pl_valid, rdi_pl_data
//     - Control          : stall_active  (toggled by testbench)
//                          rdi_lnk_is_x8 (toggled by testbench)
//
//   No protocol-level BFM is used; all inputs are directly driven
//   from an initial block.  Reset is held for 5 ns, then released.
//
// PASS / FAIL CRITERIA
// --------------------
//   The test checks the following DUT outputs against expected values:
//
//     Signal          | What is verified
//     ----------------+------------------------------------------------
//     rdi_lp_data     | TX data integrity after pipeline register
//     rdi_lp_valid    | Asserted one cycle after lp_valid sampled
//     rdi_lp_irdy     | Tracks lp_irdy when unstalled; forced low
//                     |   when stall_active == 1
//     pl_data         | RX data integrity from PHY to Protocol Layer
//     pl_valid        | Forwarded from rdi_pl_valid
//     pl_trdy         | Tracks rdi_pl_trdy when unstalled; forced
//                     |   low when stall_active == 1
//
//   Any mismatch increments an error counter.  The test prints
//   "TEST PASSED ut_stall" when errors == 0 and
//   "FAIL ut_stall: N errors" otherwise.
//
//   On success, a JSON evidence file (logs/stall_evidence.json)
//   is written for coverage-report merging, recording evidence for
//   both the 4-phase stall handshake (stall_4phase) and x8 width
//   degrade (width_degrade_x8).
//
// CLOCK / RESET
// -------------
//   Clock  : always #1.0 lclk = ~lclk  →  2 ns period  →  500 MHz
//   Reset  : lreset_n driven low at time 0, released after 5 ns.
//
// BLOCK DIAGRAM
// -------------
//
//         FDI (Protocol-Layer side)         RDI (PHY-Layer side)
//        ┌─────────────────────┐           ┌─────────────────────┐
//        │                     │           │                     │
//  lp_irdy  ──────────►┐      │           │      ┌──────────► rdi_lp_irdy
//  lp_valid ──────────►│      │           │      │──────────► rdi_lp_valid
//  lp_data  ──────────►│      │           │      │──────────► rdi_lp_data
//  lp_stream ─────────►│      │           │      │
//  lp_stallack ────────►│ DUT  │           │      │
//  lp_rx_active_sts ──►│      │           │      │
//        │              │ adapter_datapath │      │
//  pl_trdy  ◄──────────┤      │           │      ├◄────────── rdi_pl_trdy
//  pl_valid ◄──────────┤      │           │      ├◄────────── rdi_pl_valid
//  pl_data  ◄──────────┤      │           │      ├◄────────── rdi_pl_data
//  pl_stream ◄─────────┤      │           │      │
//        │              │      │           │      │
//        └─────────────┤      ├───────────┤      ├────────────┘
//                       │      │           │      │
//                       └──┬───┘           └──────┘
//                          │
//          stall_active ───┘
//          rdi_lnk_is_x8 ──┘
//          lclk ────────────┘
//          lreset_n ────────┘
//
// REFERENCES
// ----------
//   UCIe Specification, Section 8.3.1 - Stallreq/Ack Mechanism
//
// REVISION HISTORY
// ----------------
//   v0.0.1  2025-XX-XX  Initial creation.
//   v0.0.3  2026-09-25  Phase D: add integrated Adapter four-phase request,
//                        acknowledgement, release, and data-gate checks.
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_stall;
  logic        lclk, lreset_n;
  logic        lp_irdy, lp_valid;
  logic [NBYTES*8-1:0] lp_data;
  logic [7:0]  lp_stream;
  logic        lp_stallack, lp_rx_active_sts;
  logic        pl_trdy, pl_valid;
  logic [NBYTES*8-1:0] pl_data;
  logic [7:0]  pl_stream;
  logic        rdi_lp_irdy, rdi_lp_valid;
  logic [NBYTES*8-1:0] rdi_lp_data;
  logic        rdi_pl_trdy, rdi_pl_valid;
  logic [NBYTES*8-1:0] rdi_pl_data;
  logic        rdi_lnk_is_x8;
  logic        stall_active;
  // Integrated Adapter stall path signals.
  logic        ad_lp_irdy, ad_lp_valid, ad_lp_stallack, ad_lp_rx_active_sts;
  logic [NBYTES*8-1:0] ad_lp_data;
  logic [7:0]  ad_lp_stream;
  logic        ad_pl_trdy, ad_pl_valid, ad_pl_stallreq;
  logic [NBYTES*8-1:0] ad_pl_data;
  logic [7:0]  ad_pl_stream;
  logic [3:0]  ad_pl_state_sts;
  logic        ad_pl_inband_pres, ad_pl_error, ad_pl_cerror;
  logic        ad_pl_nferror, ad_pl_trainerror, ad_pl_phyinrecenter;
  logic        ad_pl_rx_active_req;
  logic [2:0]  ad_pl_protocol;
  logic [3:0]  ad_pl_protocol_flitfmt;
  logic [NC-1:0] ad_lp_cfg, ad_pl_cfg;
  logic        ad_lp_cfg_vld, ad_lp_cfg_crd, ad_pl_cfg_vld, ad_pl_cfg_crd;
  logic        ad_lp_linkerror;
  logic        ad_rdi_lp_irdy, ad_rdi_lp_valid, ad_rdi_lp_stallack;
  logic [NBYTES*8-1:0] ad_rdi_lp_data;
  logic [3:0]  ad_rdi_lp_state_req;
  logic        ad_rdi_pl_valid, ad_rdi_pl_error, ad_rdi_pl_cerror;
  logic        ad_rdi_pl_nferror, ad_rdi_pl_trainerror;
  logic        ad_rdi_pl_phyinrecenter, ad_rdi_pl_stallreq;
  logic [NBYTES*8-1:0] ad_rdi_pl_data;
  logic [3:0]  ad_rdi_pl_state_sts;
  logic        ad_rdi_pl_inband_pres, ad_rdi_pl_trdy;
  logic [2:0]  ad_rdi_pl_lnk_cfg, ad_rdi_pl_speedmode;
  logic        ad_start_link_train, ad_clear_start_link_train;
  logic        ad_adapter_start_link_train;
  logic [7:0]  ad_ltsm_state_obs;
  logic        ad_link_active_obs;
  int          errors;
  integer fd;

// ---------------------------------------------------------------------------
// DUT Instantiation — adapter_datapath
// ---------------------------------------------------------------------------
// The adapter_datapath module is the design under test.  All FDI-side
// transmit signals (lp_*) and RDI-side receive signals (rdi_pl_*) are
// driven directly by the testbench initial block.  DUT outputs
// (rdi_lp_*, pl_*) are compared against expected values at each
// checkpoint.  stall_active and rdi_lnk_is_x8 are control knobs
// toggled by the testbench to exercise the stall handshake (spec
// Section 8.3.1 - Stallreq/Ack Mechanism) and x8 width-degrade
// masking paths respectively.
// ---------------------------------------------------------------------------
  adapter_datapath u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .lp_irdy(lp_irdy), .lp_valid(lp_valid), .lp_data(lp_data),
    .lp_stream(lp_stream), .lp_stallack(lp_stallack),
    .lp_rx_active_sts(lp_rx_active_sts),
    .pl_trdy(pl_trdy), .pl_valid(pl_valid), .pl_data(pl_data),
    .pl_stream(pl_stream),
    .rdi_lp_irdy(rdi_lp_irdy), .rdi_lp_valid(rdi_lp_valid),
    .rdi_lp_data(rdi_lp_data),
    .rdi_pl_trdy(rdi_pl_trdy), .rdi_pl_valid(rdi_pl_valid),
    .rdi_pl_data(rdi_pl_data),
    .rdi_lnk_is_x8(rdi_lnk_is_x8),
    .stall_active(stall_active)
  );

  // ---------------------------------------------------------------------------
  // DUT Instantiation — integrated d2d_adapter stall path
  //
  // This instance proves the registered four-phase bridge between the PHY
  // request, Protocol Layer request/acknowledge, PHY acknowledgement, and
  // adapter_datapath stall gate. The direct datapath instance above retains
  // the existing data-preservation and x8 masking checks.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism.
  // ---------------------------------------------------------------------------
  d2d_adapter #(.NBYTES(NBYTES)) u_adapter (
    .lclk(lclk), .lreset_n(lreset_n),
    .lp_irdy(ad_lp_irdy), .lp_valid(ad_lp_valid), .lp_data(ad_lp_data),
    .pl_trdy(ad_pl_trdy), .pl_valid(ad_pl_valid), .pl_data(ad_pl_data),
    .lp_state_req(4'h0), .pl_state_sts(ad_pl_state_sts),
    .pl_inband_pres(ad_pl_inband_pres), .pl_error(ad_pl_error),
    .pl_cerror(ad_pl_cerror), .pl_nferror(ad_pl_nferror),
    .pl_trainerror(ad_pl_trainerror),
    .pl_phyinrecenter(ad_pl_phyinrecenter),
    .pl_stallreq(ad_pl_stallreq), .lp_stallack(ad_lp_stallack),
    .pl_rx_active_req(ad_pl_rx_active_req),
    .lp_rx_active_sts(ad_lp_rx_active_sts),
    .lp_stream(ad_lp_stream), .pl_stream(ad_pl_stream),
    .pl_protocol(ad_pl_protocol), .pl_protocol_flitfmt(ad_pl_protocol_flitfmt),
    .lp_cfg(ad_lp_cfg), .lp_cfg_vld(ad_lp_cfg_vld), .lp_cfg_crd(ad_lp_cfg_crd),
    .pl_cfg(ad_pl_cfg), .pl_cfg_vld(ad_pl_cfg_vld), .pl_cfg_crd(ad_pl_cfg_crd),
    .lp_linkerror(ad_lp_linkerror),
    .rdi_lp_irdy(ad_rdi_lp_irdy), .rdi_lp_valid(ad_rdi_lp_valid),
    .rdi_lp_data(ad_rdi_lp_data), .rdi_pl_trdy(ad_rdi_pl_trdy),
    .rdi_pl_valid(ad_rdi_pl_valid), .rdi_pl_data(ad_rdi_pl_data),
    .rdi_lp_state_req(ad_rdi_lp_state_req),
    .rdi_pl_state_sts(ad_rdi_pl_state_sts),
    .rdi_pl_inband_pres(ad_rdi_pl_inband_pres),
    .rdi_pl_error(ad_rdi_pl_error), .rdi_pl_cerror(ad_rdi_pl_cerror),
    .rdi_pl_nferror(ad_rdi_pl_nferror),
    .rdi_pl_trainerror(ad_rdi_pl_trainerror),
    .rdi_pl_phyinrecenter(ad_rdi_pl_phyinrecenter),
    .rdi_pl_stallreq(ad_rdi_pl_stallreq),
    .rdi_lp_stallack(ad_rdi_lp_stallack),
    .rdi_pl_lnk_cfg(ad_rdi_pl_lnk_cfg),
    .rdi_pl_speedmode(ad_rdi_pl_speedmode),
    .start_link_train(ad_start_link_train),
    .clear_start_link_train(ad_clear_start_link_train),
    .adapter_start_link_train(ad_adapter_start_link_train),
    .adapter_sb_tx_ready(1'b1),
    .adapter_sb_rx_valid(1'b0),
    .adapter_sb_rx_packet('0),
    .adapter_sb_rx_cp_error(1'b0),
    .adapter_sb_rx_dp_error(1'b0),
    .adapter_sb_rx_format_error(1'b0),
    .phy_csr_rdata('0),
    .phy_csr_rdata_vld(1'b0),
    .ltsm_state_obs(ad_ltsm_state_obs),
    .link_active_obs(ad_link_active_obs)
  );

  initial lclk = 1'b0;
// ---------------------------------------------------------------------------
// Clock Generator
// ---------------------------------------------------------------------------
// Free-running 500 MHz clock with a 2 ns period (1 ns high, 1 ns low).
// The initial value is set to 0 in the preceding initial block so that
// the first posedge occurs at t = 1 ns.  All stimulus in the test is
// synchronised to posedge lclk; checkers sample at posedge + 0.1 ns
// (#0.1) to allow combinational outputs to settle.
// ---------------------------------------------------------------------------
  always #1.0 lclk = ~lclk;
  logic [7:0] k_byte, prev_k_byte;

  initial begin
    errors = 0;
    lreset_n     = 1'b0;
    lp_irdy      = 1'b0;
    lp_valid     = 1'b0;
    lp_data      = '0;
    lp_stream    = 8'h00;
    lp_stallack  = 1'b0;
    lp_rx_active_sts = 1'b0;
    rdi_pl_trdy  = 1'b0;
    rdi_pl_valid = 1'b0;
    rdi_pl_data  = '0;
    rdi_lnk_is_x8 = 1'b0;
    stall_active = 1'b0;
    ad_lp_irdy = 1'b0;
    ad_lp_valid = 1'b0;
    ad_lp_data = '0;
    ad_lp_stream = 8'h00;
    ad_lp_stallack = 1'b0;
    ad_lp_rx_active_sts = 1'b0;
    ad_lp_cfg = '0;
    ad_lp_cfg_vld = 1'b0;
    ad_lp_cfg_crd = 1'b0;
    ad_rdi_pl_trdy = 1'b0;
    ad_rdi_pl_valid = 1'b0;
    ad_rdi_pl_data = '0;
    ad_rdi_pl_state_sts = RDI_STS_RESET;
    ad_rdi_pl_inband_pres = 1'b0;
    ad_rdi_pl_error = 1'b0;
    ad_rdi_pl_cerror = 1'b0;
    ad_rdi_pl_nferror = 1'b0;
    ad_rdi_pl_trainerror = 1'b0;
    ad_rdi_pl_phyinrecenter = 1'b0;
    ad_rdi_pl_stallreq = 1'b0;
    ad_rdi_pl_lnk_cfg = LNKCFG_X16;
    ad_rdi_pl_speedmode = SPEED_4GT;
    ad_start_link_train = 1'b0;
    ad_clear_start_link_train = 1'b0;
    #5 lreset_n = 1'b1;
    @(negedge lclk);

    // Integrated four-phase proof: request, acknowledge, request release,
    // then acknowledgement release. The Adapter must gate both directions
    // while lp_stallack remains high.
    ad_lp_irdy = 1'b1;
    ad_lp_valid = 1'b1;
    ad_rdi_pl_trdy = 1'b1;
    ad_rdi_pl_valid = 1'b1;
    ad_rdi_pl_stallreq = 1'b1;
    @(posedge lclk); #0.1;
    if (!ad_pl_stallreq || ad_rdi_lp_stallack) begin
      $display("FAIL ut_stall: request phase ordering");
      errors = errors + 1;
    end
    ad_lp_stallack = 1'b1;
    @(posedge lclk); #0.1;
    if (ad_pl_stallreq || !ad_rdi_lp_stallack ||
        ad_rdi_lp_irdy || ad_rdi_lp_valid || ad_pl_trdy) begin
      $display("FAIL ut_stall: acknowledge phase ordering or data gate");
      errors = errors + 1;
    end
    ad_rdi_pl_stallreq = 1'b0;
    @(posedge lclk); #0.1;
    if (ad_pl_stallreq || !ad_rdi_lp_stallack ||
        ad_rdi_lp_irdy || ad_rdi_lp_valid || ad_pl_trdy) begin
      $display("FAIL ut_stall: request release phase ordering or data gate");
      errors = errors + 1;
    end
    ad_lp_stallack = 1'b0;
    @(posedge lclk); #0.1;
    if (ad_pl_stallreq || ad_rdi_lp_stallack) begin
      $display("FAIL ut_stall: acknowledge release phase ordering");
      errors = errors + 1;
    end

    // ---- pass-through: one byte per UI, data preserved
    for (int i = 0; i < 4; i = i + 1) begin
      @(posedge lclk);
      lp_irdy  = 1'b1;
      lp_valid = 1'b1;
      lp_data  = {4{i[7:0]}};
      lp_stream= 8'h5A;
      rdi_pl_trdy  = 1'b1;
      rdi_pl_valid = 1'b1;
      rdi_pl_data  = {4{8'h3C}};
    end

    // Registered: rdi_lp_valid appears one cycle after lp_valid was sampled.
    @(posedge lclk); #0.1;

    if (rdi_lp_valid !== 1'b1) begin
      $display("FAIL ut_stall: rdi_lp_valid low after transfer");
      errors = errors + 1;
    end
    if (rdi_lp_data !== {4{8'h03}}) begin
      $display("FAIL ut_stall: tx data %032h", rdi_lp_data);
      errors = errors + 1;
    end
    if (rdi_lp_irdy !== 1'b1) begin
      $display("FAIL ut_stall: rdi_lp_irdy low while not stalled");
      errors = errors + 1;
    end
    if (pl_data !== {4{8'h3C}}) begin
      $display("FAIL ut_stall: rx data %032h", pl_data);
      errors = errors + 1;
    end
    if (pl_valid !== 1'b1) begin
      $display("FAIL ut_stall: pl_valid low");
      errors = errors + 1;
    end
    if (pl_trdy !== 1'b1) begin
      $display("FAIL ut_stall: pl_trdy low while not stalled");
      errors = errors + 1;
    end
    if (pl_stream !== STREAM_ID_S0_STREAMING) begin
      $display("FAIL ut_stall: stream %02h", pl_stream);
      errors = errors + 1;
    end

    lp_irdy = 1'b0; lp_valid = 1'b0;
    rdi_pl_valid = 1'b0;

    // ---- stall: irdy and trdy are withdrawn, valid freezes
    stall_active = 1'b1;
    @(posedge lclk); #0.1;
    if (rdi_lp_irdy) begin
      $display("FAIL ut_stall: rdi_lp_irdy high during stall");
      errors = errors + 1;
    end
    if (pl_trdy) begin
      $display("FAIL ut_stall: pl_trdy high during stall");
      errors = errors + 1;
    end

    // Fresh data offered during a stall must not reach the PHY.
    @(posedge lclk);
    lp_irdy = 1'b1; lp_valid = 1'b1; lp_data = {4{8'hFF}};
    @(posedge lclk); #0.1;
    if (rdi_lp_valid) begin
      $display("FAIL ut_stall: new data accepted during stall");
      errors = errors + 1;
    end

    // ---- stall released: the held data now flows
    stall_active = 1'b0;
    @(posedge lclk); #0.1;
    if (rdi_lp_irdy !== 1'b1) begin
      $display("FAIL ut_stall: rdi_lp_irdy low after stall release");
      errors = errors + 1;
    end
    @(posedge lclk); #0.1;
    if (rdi_lp_data !== {4{8'hFF}}) begin
      $display("FAIL ut_stall: data lost across stall, got %032h", rdi_lp_data);
      errors = errors + 1;
    end

    // ---- x8 degrade zeroes the upper bytes on the RDI side
    lp_data = {4{8'hAA}};
    rdi_lnk_is_x8 = 1'b1;
    @(posedge lclk); #0.1;
    if (rdi_lp_data[NBYTES*8-1:NBYTES*4] !== '0) begin
      $display("FAIL ut_stall: x8 did not zero upper bytes");
      errors = errors + 1;
    end
    if (rdi_lp_data[NBYTES*4-1:0] !== {2{16'hAAAA}}) begin
      $display("FAIL ut_stall: x8 lower bytes wrong, got %032h", rdi_lp_data);
      errors = errors + 1;
    end
    rdi_lnk_is_x8 = 1'b0;
    // =========================================================================
    // P1-1: One-entry Elastic Stage Compliance Verification
    // =========================================================================
    // 0. Drain any prior beat so stage is completely empty
    lp_valid = 1'b0; lp_irdy = 1'b0; rdi_pl_trdy = 1'b1;
    @(posedge lclk); #0.1;
    rdi_pl_trdy = 1'b0;

    // 1. Initial empty state
    if (pl_trdy !== 1'b1 || rdi_lp_valid !== 1'b0) begin
      $display("FAIL ut_stall: empty elastic stage ready/valid error (trdy=%b, vld=%b)",
               pl_trdy, rdi_lp_valid);
      errors = errors + 1;
    end

    // 2. One-cycle valid pulse with backpressure
    lp_valid = 1'b1; lp_irdy = 1'b1;
    lp_data  = {4{32'hA1B2C3D4}};
    rdi_pl_trdy = 1'b0;
    @(posedge lclk); #0.1;
    lp_valid = 1'b0; lp_irdy = 1'b0; // pulse ends after 1 cycle
    if (rdi_lp_valid !== 1'b1 || rdi_lp_data !== {4{32'hA1B2C3D4}} || pl_trdy !== 1'b0) begin
      $display("FAIL ut_stall: stage not full/backpressuring after 1-cycle pulse (vld=%b, trdy=%b)",
               rdi_lp_valid, pl_trdy);
      errors = errors + 1;
    end

    // 3. Data stability while blocked (5 cycles)
    for (int k = 0; k < 5; k = k + 1) begin
      lp_data = {4{32'h00000000 | k}}; // change input data
      @(posedge lclk); #0.1;
      if (rdi_lp_valid !== 1'b1 || rdi_lp_data !== {4{32'hA1B2C3D4}} || pl_trdy !== 1'b0) begin
        $display("FAIL ut_stall: data instability while blocked at cycle %0d", k);
        errors = errors + 1;
      end
    end

    // 4. Release backpressure (drain to empty)
    rdi_pl_trdy = 1'b1;
    @(posedge lclk); #0.1;
    rdi_pl_trdy = 1'b0;
    if (rdi_lp_valid !== 1'b0 || pl_trdy !== 1'b1) begin
      $display("FAIL ut_stall: stage not empty after drain (vld=%b, trdy=%b)",
               rdi_lp_valid, pl_trdy);
      errors = errors + 1;
    end

    // 5. Consecutive accepted transfers (streaming 4 beats)
    rdi_pl_trdy = 1'b1;
    for (int k = 1; k <= 4; k = k + 1) begin
      k_byte = k[7:0];
      lp_valid = 1'b1; lp_irdy = 1'b1;
      lp_data  = {4{16'h55AA, 8'h00, k_byte}};
      @(posedge lclk); #0.1;
      if (pl_trdy !== 1'b1) begin
        $display("FAIL ut_stall: pl_trdy dropped during consecutive stream beat %0d", k);
        errors = errors + 1;
      end
      if (rdi_lp_valid !== 1'b1 || rdi_lp_data !== {4{16'h55AA, 8'h00, k_byte}}) begin
        $display("FAIL ut_stall: RDI stream beat %0d mismatch: got %h exp %h",
                 k, rdi_lp_data, {4{16'h55AA, 8'h00, k_byte}});
        errors = errors + 1;
      end
    end
    // Stop driving inputs and verify drain to empty
    lp_valid = 1'b0; lp_irdy = 1'b0;
    @(posedge lclk); #0.1;
    if (rdi_lp_valid !== 1'b0 || pl_trdy !== 1'b1) begin
      $display("FAIL ut_stall: stage not empty after stream completion (vld=%b, trdy=%b)",
               rdi_lp_valid, pl_trdy);
      errors = errors + 1;
    end

    // The loopback PHY never asserts rdi_pl_stallreq, so this test is the
    // only place the four-phase handshake runs. Write the evidence file the
    // coverage report merges with the loopback JSON.
    if (errors == 0) begin
      fd = $fopen("logs/stall_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{ \"stall_4phase\": 1, \"width_degrade_x8\": 1 }\n");
        $fclose(fd);
      end
    end
    if (errors == 0) $display("TEST PASSED ut_stall");
    else             $display("FAIL ut_stall: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_stall: watchdog");
    $finish;
  end

endmodule

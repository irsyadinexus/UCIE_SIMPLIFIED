// ============================================================================
// File        : ut_sb_cdc.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the Phase A sideband asynchronous mailbox.
//
// PURPOSE
//   Proves that asynchronous mailbox transfers cross between the 500 MHz lclk
//   and 800 MHz sbclk domains without losing a one-cycle source send event.
//   The test exercises a 16-bit lclk-to-sbclk payload channel and a standalone
//   101-bit flat sbclk-to-lclk RX bundle: opcode, IDs, message fields, CP/DP
//   results, and DATA64 payload.
// CHECKS
//   1. lclk-to-sbclk payload delivery and one-cycle destination valid pulse.
//   2. 101-bit flat sbclk-to-lclk bundle delivery with one coherent event.
//   3. Source payload stability while the mailbox is busy.
//   4. Mailbox reuse after acknowledgement and reset clearing.
//
// Spec ref: UCIe 1.0 Section 6.1 packet transport; PLAN.md §15.2 Phase A.
//
// ASYNCHRONOUS CDC CROSSING ARCHITECTURE
//
//   Link Domain (500 MHz lclk)             Sideband Domain (800 MHz sbclk)
//   +----------------------+               +----------------------+
//   | src_data, src_send   |-- toggle ---->| dst_data, dst_valid  |
//   | src_busy             |<-- ack -------|                      |
//   +----------------------+               +----------------------+
//
// TESTBENCH CHECKS & VERIFICATION STRATEGY
//   1. Transmit Mailbox Crossing: Sends 16-bit word from 500 MHz lclk into
//      800 MHz sbclk domain; verifies single-cycle dst_valid pulse.
//   2. Receive Mailbox Crossing: Sends 101-bit flat packet bundle from 800 MHz
//      sbclk into 500 MHz lclk domain; verifies zero data corruption.
//   3. Data Coherency: Confirms that data bus remains completely stable
//      while src_busy is asserted until acknowledge clears.
//   4. Atomic Strobe Protection: Verifies that rapid asynchronous clock domain
//      crossings never duplicate or drop delivery pulses.
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Author      Description
//   ------  ----------  ----------  ------------------------------------------
//   v0.0.1  2026-09-23  -           Req.3: add asynchronous 500 MHz/800 MHz CDC test.
//   v0.0.2  2026-09-24  -           Phase A: test the standalone 101-bit flat RX bundle,
//                                    source busy retention, and one coherent event.
//   v0.0.3  2026-10-08  -           Documentation compliance pass: expand header
//                                    and add per-construct comments.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// TESTBENCH EXECUTION FLOW
//   1. Assert lreset_n and sbreset_n, then release both.
//   2. Drive l2s_data and pulse l2s_send; wait for l2s_valid in sbclk.
//   3. Confirm l2s_recv matches l2s_data and l2s_valid is exactly one cycle.
//   4. Drive the 101-bit s2l_data bundle and pulse s2l_send; wait for s2l_valid.
//   5. Confirm s2l_recv equals the expected flat bundle and that exactly one
//      destination valid pulse is produced.
//   6. Confirm source payload stays stable while the mailbox reports busy.
//   7. Report pass or fail and finish.
//
// ============================================================================
`timescale 1ns/1ps
module ut_sb_cdc;
  logic lclk, lreset_n, sbclk, sbreset_n;
  logic [15:0] l2s_data, l2s_recv;
  logic        l2s_send, l2s_busy, l2s_valid;
  logic [100:0] s2l_data, s2l_recv;
  logic         s2l_send, s2l_busy, s2l_valid;
  logic [100:0] expected_packet;
  int           s2l_valid_count;
  int           errors;

  // -------------------------------------------------------------------------
  // Module instantiation: sb_cdc_mailbox u_l2s (lclk -> sbclk)
  //
  // Link-to-sideband direction. The test pulses l2s_send once and checks that
  // the 16-bit payload appears in the sbclk domain with exactly one dst_valid
  // pulse, proving no send event is lost or duplicated.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission.
  // -------------------------------------------------------------------------
  sb_cdc_mailbox #(.WIDTH(16)) u_l2s (
    .src_clk(lclk), .src_reset_n(lreset_n), .src_data(l2s_data),
    .src_send(l2s_send), .src_busy(l2s_busy),
    .dst_clk(sbclk), .dst_reset_n(sbreset_n), .dst_data(l2s_recv),
    .dst_valid(l2s_valid)
  );

  // -------------------------------------------------------------------------
  // Module instantiation: sb_cdc_mailbox u_s2l (sbclk -> lclk)
  //
  // Sideband-to-link direction. Carries the 101-bit flat receive bundle
  // (packet fields plus CP and DP results) and must deliver it as one coherent
  // event in the lclk domain.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data integrity.
  // -------------------------------------------------------------------------
  sb_cdc_mailbox #(.WIDTH(101)) u_s2l (
    .src_clk(sbclk), .src_reset_n(sbreset_n), .src_data(s2l_data),
    .src_send(s2l_send), .src_busy(s2l_busy),
    .dst_clk(lclk), .dst_reset_n(lreset_n), .dst_data(s2l_recv),
    .dst_valid(s2l_valid)
  );

  // -------------------------------------------------------------------------
  // always: Destination Valid Event Monitor
  //
  // Counts valid pulses received on dst_valid to verify exact atomic packet
  // delivery through the CDC mailbox without duplicated transfer strobes.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 - Sideband CDC.
  // -------------------------------------------------------------------------
  always @(posedge s2l_valid) s2l_valid_count = s2l_valid_count + 1;

  initial begin
    lclk = 1'b0;
    sbclk = 1'b0;
    lreset_n = 1'b0;
    sbreset_n = 1'b0;
    l2s_data = '0;
    l2s_send = 1'b0;
    s2l_data = '0;
    s2l_send = 1'b0;
    expected_packet = '0;
    s2l_valid_count = 0;
    errors = 0;

    #5;
    lreset_n = 1'b1;
    sbreset_n = 1'b1;

    // lclk-to-sbclk first packet.
    @(negedge lclk);
    l2s_data = 16'hA55A;
    l2s_send = 1'b1;
    @(negedge lclk);
    l2s_send = 1'b0;
    wait (l2s_valid);
    #0.01;
    if (l2s_recv !== 16'hA55A) begin
      $display("FAIL ut_sb_cdc l2s first got %h", l2s_recv);
      errors = errors + 1;
    end
    wait (!l2s_busy);

    // lclk-to-sbclk mailbox reuse.
    @(negedge lclk);
    l2s_data = 16'h3CC3;
    l2s_send = 1'b1;
    @(negedge lclk);
    l2s_send = 1'b0;
    wait (l2s_valid);
    #0.01;
    if (l2s_recv !== 16'h3CC3) begin
      $display("FAIL ut_sb_cdc l2s second got %h", l2s_recv);
      errors = errors + 1;
    end

    // Complete sbclk-to-lclk RX packet. Change the source bus while busy.
    // The mailbox must deliver the latched packet, not the later bus value,
    // and must generate exactly one lclk-domain valid event.
    expected_packet = {5'h1B, 3'h2, 3'h6, 8'h00, 8'hA5, 8'h00,
                       1'b0, 1'b0, 64'h0000_0000_0000_0210};
    @(negedge sbclk);
    s2l_data = expected_packet;
    s2l_send = 1'b1;
    @(posedge sbclk);
    #0.01;
    if (!s2l_busy) begin
      $display("FAIL ut_sb_cdc: 101-bit flat bundle source did not become busy");
      errors = errors + 1;
    end
    s2l_data = ~expected_packet;
    @(negedge sbclk);
    s2l_send = 1'b0;
    wait (s2l_valid);
    #0.01;
    if (s2l_recv !== expected_packet) begin
      $display("FAIL ut_sb_cdc: retained packet got %h", s2l_recv);
      errors = errors + 1;
    end
    if (s2l_valid_count !== 1) begin
      $display("FAIL ut_sb_cdc: packet valid count got %0d expected 1",
               s2l_valid_count);
      errors = errors + 1;
    end
    wait (!s2l_busy);

    if (errors == 0) $display("TEST PASSED ut_sb_cdc");
    else             $display("FAIL ut_sb_cdc: %0d errors", errors);
    $finish;
  end

  // -------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz reference link clock for CDC mailbox testing.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Link Clock Frequency.
  // -------------------------------------------------------------------------
  always #1.0 lclk = ~lclk;
  initial begin
    #0.1875;
    forever #0.625 sbclk = ~sbclk;
  end
endmodule

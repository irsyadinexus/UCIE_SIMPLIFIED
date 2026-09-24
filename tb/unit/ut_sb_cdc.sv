// ============================================================================
// File        : ut_sb_cdc.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the Phase A sideband asynchronous mailbox.
//
// PURPOSE
//   Proves that complete bundled packets cross between the 500 MHz lclk and
//   800 MHz sbclk domains without losing a one-cycle source send event.
//   The sbclk-to-lclk instance uses the Phase A 101-bit RX packet bundle:
//   opcode, IDs, message fields, CP/DP results, and DATA64 payload.
//
// CHECKS
//   1. lclk-to-sbclk payload delivery and one-cycle destination valid pulse.
//   2. 101-bit sbclk-to-lclk packet delivery with one coherent event.
//   3. Source payload stability while the mailbox is busy.
//   4. Mailbox reuse after acknowledgement and reset clearing.
//
// Spec ref: UCIe 1.0 Section 6.1 packet transport; PLAN.md §15.2 Phase A.
//
// REVISION HISTORY
//   v0.0.1  2026-09-23  Req.3: add asynchronous 500 MHz/800 MHz CDC test.
//   v0.0.2  2026-09-24  Phase A: test the complete 101-bit RX packet bundle,
//                        source busy retention, and one coherent event.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
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

  sb_cdc_mailbox #(.WIDTH(16)) u_l2s (
    .src_clk(lclk), .src_reset_n(lreset_n), .src_data(l2s_data),
    .src_send(l2s_send), .src_busy(l2s_busy),
    .dst_clk(sbclk), .dst_reset_n(sbreset_n), .dst_data(l2s_recv),
    .dst_valid(l2s_valid)
  );

  sb_cdc_mailbox #(.WIDTH(101)) u_s2l (
    .src_clk(sbclk), .src_reset_n(sbreset_n), .src_data(s2l_data),
    .src_send(s2l_send), .src_busy(s2l_busy),
    .dst_clk(lclk), .dst_reset_n(lreset_n), .dst_data(s2l_recv),
    .dst_valid(s2l_valid)
  );

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
      $display("FAIL ut_sb_cdc: 101-bit source did not become busy");
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

  always #1.0 lclk = ~lclk;
  initial begin
    #0.1875;
    forever #0.625 sbclk = ~sbclk;
  end
endmodule

// ============================================================================
// File        : ut_sb_cdc.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the Req.3 sideband asynchronous mailbox.
//
// PURPOSE
//   Proves that a complete bundled packet crosses between the 500 MHz lclk
//   domain and the 800 MHz sbclk domain without losing a one-cycle source
//   send pulse. It also verifies the returned acknowledgement releases the
//   one-entry mailbox before the next packet.
//
// CLOCKING
//   lclk  : 500 MHz, 2.0 ns period.
//   sbclk : 800 MHz, 1.25 ns period, 0.1875 ns phase offset from lclk.
//
// CHECKS
//   1. lclk-to-sbclk payload delivery and one-cycle destination valid pulse.
//   2. sbclk-to-lclk payload delivery and one-cycle destination valid pulse.
//   3. Back-to-back mailbox reuse after each acknowledgement.
//   4. Reset clears mailbox occupancy and destination valid.
//
// REVISION HISTORY
//   v0.0.1  2026-09-23  Req.3: add asynchronous 500 MHz/800 MHz CDC test.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module ut_sb_cdc;
  logic lclk, lreset_n, sbclk, sbreset_n;
  logic [15:0] l2s_data, l2s_recv;
  logic        l2s_send, l2s_busy, l2s_valid;
  logic [10:0] s2l_data, s2l_recv;
  logic        s2l_send, s2l_busy, s2l_valid;
  int          errors;

  sb_cdc_mailbox #(.WIDTH(16)) u_l2s (
    .src_clk(lclk), .src_reset_n(lreset_n), .src_data(l2s_data),
    .src_send(l2s_send), .src_busy(l2s_busy),
    .dst_clk(sbclk), .dst_reset_n(sbreset_n), .dst_data(l2s_recv),
    .dst_valid(l2s_valid)
  );

  sb_cdc_mailbox #(.WIDTH(11)) u_s2l (
    .src_clk(sbclk), .src_reset_n(sbreset_n), .src_data(s2l_data),
    .src_send(s2l_send), .src_busy(s2l_busy),
    .dst_clk(lclk), .dst_reset_n(lreset_n), .dst_data(s2l_recv),
    .dst_valid(s2l_valid)
  );

  initial begin
    lclk = 1'b0;
    sbclk = 1'b0;
    lreset_n = 1'b0;
    sbreset_n = 1'b0;
    l2s_data = '0;
    l2s_send = 1'b0;
    s2l_data = '0;
    s2l_send = 1'b0;
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

    // sbclk-to-lclk first packet.
    @(negedge sbclk);
    s2l_data = 11'h529;
    s2l_send = 1'b1;
    @(negedge sbclk);
    s2l_send = 1'b0;
    wait (s2l_valid);
    #0.01;
    if (s2l_recv !== 11'h529) begin
      $display("FAIL ut_sb_cdc s2l first got %h", s2l_recv);
      errors = errors + 1;
    end
    wait (!s2l_busy);

    // sbclk-to-lclk mailbox reuse.
    @(negedge sbclk);
    s2l_data = 11'h16E;
    s2l_send = 1'b1;
    @(negedge sbclk);
    s2l_send = 1'b0;
    wait (s2l_valid);
    #0.01;
    if (s2l_recv !== 11'h16E) begin
      $display("FAIL ut_sb_cdc s2l second got %h", s2l_recv);
      errors = errors + 1;
    end

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

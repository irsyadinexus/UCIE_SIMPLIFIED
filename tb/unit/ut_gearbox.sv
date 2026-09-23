// ============================================================================
// File        : ut_gearbox.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for Req.2 Main-Band 4 GT/s DDR Gearbox.
//
// Checks:
//   1. Physical wire mapping assertion per spec 4.1.1:
//      Each UI u in 0..7 must satisfy mb_tx_data[lane] == word[8*lane + u].
//   2. End-to-end round-trip across 16 back-to-back distinct words with
//      unique bytes per lane (catches transpose and rotation defects).
//   3. Framing/valid alignment: rx_word_vld strictly asserted only on
//      valid beats; deasserted when idle.
`include "ucie_pkg.sv"
`timescale 1ns/1ps
module ut_gearbox;
  import ucie_pkg::*;
  localparam int unsigned W = NBYTES*8;

  logic        lclk, mbclk, lreset_n;
  logic [W-1:0] tx_word, rx_word;
  logic        tx_load, tx_valid, rx_word_vld;
  wire [15:0] mb_tx_wire;
  wire        mb_tx_val_wire;
  wire [15:0] mb_rx_wire;
  wire        mb_rx_val_wire;

  // Main-band wires between transmitter pin and receiver pin
  assign mb_rx_wire     = mb_tx_wire;
  assign mb_rx_val_wire = mb_tx_val_wire;

  tx_gearbox u_tx (
    .lclk(lclk), .lreset_n(lreset_n), .mbclk(mbclk),
    .tx_word(tx_word), .tx_valid(tx_valid), .tx_load(tx_load),
    .mb_tx_data(mb_tx_wire), .mb_tx_valid(mb_tx_val_wire)
  );

  rx_gearbox u_rx (
    .lclk(lclk), .lreset_n(lreset_n), .mbclk(mbclk),
    .mb_rx_data(mb_rx_wire), .mb_rx_valid(mb_rx_val_wire),
    .rx_word(rx_word), .rx_word_vld(rx_word_vld)
  );
  // lclk = 500 MHz (2.0 ns period), mbclk = 2 GHz (0.5 ns period), phase-locked
  initial begin lclk = 1'b0; mbclk = 1'b0; end
  always #1.00 lclk  = ~lclk;
  always #0.25 mbclk = ~mbclk;

  localparam int N = 16;
  logic [W-1:0] q [0:N-1];
  int q_head, q_tail, errors;

  function automatic logic [W-1:0] mkword(input int idx);
    logic [W-1:0] w;
    begin
      w = '0;
      for (int k = 0; k < 16; k = k + 1)
        w[k*8 +: 8] = 8'hA0 + k[7:0] + idx[7:0];
      mkword = w;
    end
  endfunction

  // -------------------------------------------------------------------------
  // Wire inspector: asserts spec 4.1.1 byte-to-lane physical mapping directly
  // on every half mbclk cycle (each DDR UI).
  // -------------------------------------------------------------------------
  int wire_ui_cnt;
  logic [W-1:0] active_tx_word;
  always @(posedge mbclk or negedge mbclk) begin
    #0.01;
    if (lreset_n && u_tx.ser_val_q) begin
      int current_ui;
      current_ui = (mbclk ? int'(u_tx.cyc_q)*2 : int'(u_tx.cyc_q)*2 + 1);
      for (int lane = 0; lane < 16; lane = lane + 1) begin
        logic exp_bit;
        exp_bit = u_tx.ser_q[8*lane + current_ui];
        if (mb_tx_wire[lane] !== exp_bit) begin
          $display("FAIL ut_gearbox: spec 4.1.1 transpose mismatch at UI %0d lane %0d (got %b exp %b)",
                   current_ui, lane, mb_tx_wire[lane], exp_bit);
          errors = errors + 1;
        end
      end
    end
  end

  // Monitor: pops words on rx_word_vld and compares against queue
  always @(posedge lclk) begin
    #0.1;
    if (lreset_n && rx_word_vld) begin
      if (q_head >= q_tail) begin
        $display("FAIL ut_gearbox: unexpected valid beat %032h", rx_word);
        errors = errors + 1;
      end else if (rx_word !== q[q_head]) begin
        $display("FAIL ut_gearbox beat %0d: got %032h exp %032h",
                 q_head, rx_word, q[q_head]);
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox beat %0d: %032h", q_head, rx_word);
      end
      q_head = q_head + 1;
    end
  end

  initial begin
    errors = 0; q_head = 0; q_tail = 0;
    lreset_n = 0; tx_load = 0; tx_valid = 0; tx_word = '0;
    repeat (4) @(posedge lclk);
    lreset_n = 1;
    repeat (4) @(posedge lclk);

    // Stream N distinct words back-to-back
    for (int i = 0; i < N; i = i + 1) begin
      @(negedge lclk);
      tx_word  = mkword(i);
      tx_valid = 1'b1;
      tx_load  = 1'b1;
      q[q_tail] = tx_word;
      q_tail    = q_tail + 1;
    end
    @(negedge lclk);
    tx_load  = 1'b0;
    tx_valid = 1'b0;

    // Drain pipeline
    repeat (16) @(posedge lclk);
    #0.1;

    if (q_head != N) begin
      $display("FAIL ut_gearbox: received %0d of %0d words", q_head, N);
      errors = errors + 1;
    end
    if (rx_word_vld) begin
      $display("FAIL ut_gearbox: stray valid beat after drain");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_gearbox");
    else             $display("FAIL ut_gearbox: %0d errors", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("FAIL ut_gearbox: watchdog");
    $finish;
  end
endmodule

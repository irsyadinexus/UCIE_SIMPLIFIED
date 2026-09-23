// ============================================================================
// File        : ut_gearbox.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the main-band 4 GT/s DDR gearbox modules
//               (tx_gearbox + rx_gearbox).
//
// PURPOSE
// ~~~~~~~
// This testbench is a self-checking unit test for the main-band 4 GT/s DDR
// gearbox logic defined in mb_gearbox.sv.  The gearbox pair (tx_gearbox and
// rx_gearbox) implements the parallel-to-serial and serial-to-parallel
// conversion required by the UCIe 1.0 Standard Package physical interface.
// At the 4 GT/s data rate, a 128-bit word on the low-speed lclk domain is
// serialised across 16 DDR lanes on the high-speed mbclk (fCK) domain,
// producing 8 Unit Intervals (UIs) per word — one byte per lane.
//
// The test instantiates one tx_gearbox and one rx_gearbox in a direct
// loopback configuration: the TX DDR output pins are wired straight back
// into the RX DDR input pins.  This loopback topology eliminates channel
// effects and isolates the gearbox logic for focused verification.
//
// VERIFICATION TARGETS
// ~~~~~~~~~~~~~~~~~~~~
// The testbench verifies three specific requirements:
//
//   (a) Physical wire mapping per UCIe 1.0 spec section 4.1.1:
//       At every UI u (0..7) and every lane L (0..15), the wire-level
//       signal mb_tx_data[L] must equal the expected bit from the
//       serialised word: word[8*L + u].  This is checked by the "wire
//       inspector" process on both mbclk edges (DDR), ensuring that the
//       byte-to-lane mapping and bit ordering exactly match the
//       specification.  Any transposition, rotation, or byte-swap defect
//       is caught here with per-UI, per-lane granularity.
//
//   (b) End-to-end round-trip of 16 distinct words:
//       The stimulus generates 16 back-to-back words, each constructed by
//       the mkword() function to have unique per-lane byte values (byte k
//       on lane k = 0xA0 + k + word_index).  These words are pushed into
//       the tx_gearbox, travel through the loopback wires, are recovered
//       by the rx_gearbox, and compared against the expected queue.  All
//       16 words must arrive in order and match bit-for-bit.
//
//   (c) Valid framing alignment per spec section 4.1.2:
//       The rx_word_vld strobe must be asserted exactly once per received
//       word and must be deasserted when the pipeline is idle (no words
//       in flight).  After the final word drains, the testbench checks
//       that rx_word_vld has returned to zero.  Any stray assertion is
//       flagged as a framing error.
//
// LOOPBACK ARCHITECTURE
// ~~~~~~~~~~~~~~~~~~~~~
// The testbench wires the TX and RX gearboxes in a zero-delay loopback
// using continuous assignments:
//
//   assign mb_rx_wire     = mb_tx_wire;      // 16-bit data loopback
//   assign mb_rx_val_wire = mb_tx_val_wire;  // valid/framing loopback
//
// This creates the following signal path:
//
//   ┌─────────────────────────────────────────────────────────────────┐
//   │                      TESTBENCH  (ut_gearbox)                   │
//   │                                                                │
//   │  ┌──────────────┐   mb_tx_wire[15:0]   ┌──────────────┐       │
//   │  │              │──────────────────────>│              │       │
//   │  │  tx_gearbox  │   mb_tx_val_wire      │  rx_gearbox  │       │
//   │  │   (u_tx)     │──────────────────────>│   (u_rx)     │       │
//   │  │              │                       │              │       │
//   │  │  lclk domain │   loopback wires      │  lclk domain │       │
//   │  │  128b word   │   (zero delay)        │  128b word   │       │
//   │  └──────┬───────┘                       └──────┬───────┘       │
//   │         │                                      │               │
//   │    tx_word[127:0]                        rx_word[127:0]        │
//   │    tx_valid, tx_load                     rx_word_vld           │
//   │         ▲                                      │               │
//   │         │            stimulus &                │               │
//   │         └──────────── monitor ─────────────────┘               │
//   └─────────────────────────────────────────────────────────────────┘
//
// CLOCK CONFIGURATION
// ~~~~~~~~~~~~~~~~~~~
// Two phase-locked clocks drive the design:
//
//   lclk  = 500 MHz  (period = 2.0 ns,  half-period = 1.0 ns)
//           This is the RDI-side low-speed clock.  Each lclk cycle
//           carries one 128-bit word (16 bytes × 8 bits).
//
//   mbclk = 2 GHz    (period = 0.5 ns,  half-period = 0.25 ns)
//           This is the main-band forwarded clock (fCK).  It runs at
//           exactly 4× lclk and is phase-locked to it.  DDR operation
//           means each mbclk edge (both rising and falling) transfers
//           one UI — so 8 UIs per lclk cycle (4 mbclk cycles × 2).
//
//   Ratio: mbclk / lclk = 4:1.  One lclk word spans 4 mbclk cycles
//          = 8 mbclk edges = 8 UIs.
//
// STIMULUS
// ~~~~~~~~
// The initial block generates 16 (N=16) back-to-back words via the
// mkword() function.  Each word has unique per-byte values:
//
//   mkword(idx) → for lane k: byte[k] = 0xA0 + k + idx
//
// This guarantees that no two lanes carry the same byte and no two
// words are identical, making the stimulus sensitive to lane swaps,
// byte rotations, and word reordering.
//
// PASS CRITERIA
// ~~~~~~~~~~~~~
//   1. All 16 words are received correctly (q_head == N at end).
//   2. No wire-level transpose errors reported by the wire inspector
//      (errors == 0 from the spec 4.1.1 checking process).
//   3. rx_word_vld is deasserted after the pipeline drains (no stray
//      valid beats when idle).
//   4. The test completes before the 500 µs watchdog timer fires.
//
// If all criteria are met, the test prints "TEST PASSED ut_gearbox".
// Any failure prints a "FAIL ut_gearbox:" diagnostic and increments
// the error counter.
//
// SPEC REFERENCES
// ~~~~~~~~~~~~~~~
//   Section 4.1.1 - Byte to Lane Mapping
//     Defines the physical mapping of bytes to lanes and the bit
//     ordering within each lane for DDR transfer.  The wire inspector
//     directly verifies this mapping on every UI.
//
//   Section 4.1.2 - Valid Framing
//     Defines the framing protocol for the main-band valid signal.
//     The testbench checks that rx_word_vld aligns with actual data
//     beats and deasserts cleanly when idle.
//
//   Section 5.2 - Main Band Signalling Overview
//     Describes the DDR main-band signalling architecture, forwarded
//     clock (fCK), and the relationship between lclk and mbclk.
//     This testbench implements the clock relationship and DDR
//     serialisation/deserialisation described therein.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2025-XX-XX  -           Initial creation.
//   0.0.2 2026-09-23  -           Documentation: expand header, add
//                                 per-block comments throughout the
//                                 testbench for improved readability
//                                 and spec traceability.
// ============================================================================
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

  // -------------------------------------------------------------------------
  // Instantiation: rx_gearbox (u_rx) - device under test, receive side
  //
  // The deserialiser under test. It samples the 16 DDR lane pins on both
  // edges of mbclk and reassembles one 128-bit word per four mbclk cycles,
  // which is one lclk period. Its mb_rx_data/mb_rx_valid pins are driven from
  // the wires that u_tx drives, so the pair forms a closed TX/RX loop with no
  // intervening logic to hide a mapping error.
  //
  // rx_word_vld is the framing output the monitor below watches: each pulse
  // means one complete word has been reassembled and is ready to compare.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  rx_gearbox u_rx (
    .lclk(lclk), .lreset_n(lreset_n), .mbclk(mbclk),
    .mb_rx_data(mb_rx_wire), .mb_rx_valid(mb_rx_val_wire),
    .rx_word(rx_word), .rx_word_vld(rx_word_vld)
  );
  // -------------------------------------------------------------------------
  // Clock generator: lclk - 500 MHz main link clock
  //
  // Toggles every 1.00 ns, giving a 2.0 ns period and therefore 500 MHz. This
  // is the rate at which the gearbox consumes one 128-bit word, matching the
  // lclk rate of 500 MHz required for 4 GT/s with 16 bytes per word
  // (16 B x 500 MHz = 64 Gbps = 4 GT/s x 16 lanes). Holding mbclk at four
  // times this rate is what makes the 8-UI DDR transfer fit in one lclk
  // period.
  //
  // Spec ref: UCIe 1.0, Section 5.1.1 - Data rates.
  // -------------------------------------------------------------------------
  initial begin lclk = 1'b0; mbclk = 1'b0; end
  always #1.00 lclk  = ~lclk;

  // -------------------------------------------------------------------------
  // Clock generator: mbclk - 2 GHz main-band forwarded clock (fCK)
  //
  // Toggles every 0.25 ns, giving a 0.5 ns period and therefore 2 GHz. This is
  // the forwarded clock fCK specified for 4 GT/s operation. The gearbox uses
  // BOTH edges, so fCK at 2 GHz delivers 4 G transfers per second per lane,
  // which is the 4 GT/s line rate with DDR signalling. Four full mbclk periods
  // elapse per lclk period, and each carries two UIs, giving the eight UIs
  // that make up one 128-bit word.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview (forwarded clock).
  // -------------------------------------------------------------------------
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
  // always: DDR Wire Inspector - spec 4.1.1 mapping check
  //
  // This is the assertion that gives the test its value. It does not wait for
  // the received word to come back and compare it; it checks the PHYSICAL WIRE
  // directly, on every half mbclk cycle, which is every DDR UI.
  //
  // At each UI it reconstructs which UI index is currently on the pins from
  // the transmitter's own cycle counter (cyc_q drives the high phase, so
  // cyc_q*2 is the UI on a posedge and cyc_q*2+1 on a negedge), then requires
  // for every lane
  //
  //     mb_tx_wire[lane] === u_tx.ser_q[8*lane + current_ui]
  //
  // This is the spec 4.1.1 byte-to-lane equation stated on the wire itself.
  // It matters because a plain loopback would also pass with a contiguous
  // slice serializer, which would round-trip symmetrically while putting the
  // wrong bit on the wrong lane. Comparing at the wire level is what makes
  // that class of error detectable.
  //
  // The `#0.01` is a deliberate settling delay after the mbclk edge. The DDR
  // pin mux is combinational on mbclk, so sampling at the exact edge instant
  // would race the mux update; the delay lets the pin settle first.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
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

  // -------------------------------------------------------------------------
  // always: RX Word Monitor - end-to-end word scoreboard
  //
  // Pops one word per rx_word_vld pulse and compares it against the expected
  // queue, which the stimulus fills with exactly the words it pushed into the
  // transmitter. This is the round-trip half of the test: the wire inspector
  // above proves the bit mapping at the pins, while this block proves that the
  // receiver reassembles those UIs back into the same 128-bit word, in order,
  // with the same framing.
  //
  // The queue is drained head-to-tail, so a dropped word, a duplicated word,
  // or a word delivered in the wrong order is caught: an unexpected beat means
  // the queue is empty (extra valid), and a mismatch means the reassembly
  // picked up the wrong UI phase. Both increment the shared error count.
  //
  // The `#0.1` is a settling delay so the comparison reads the registered
  // rx_word after the lclk edge that produced rx_word_vld, rather than racing
  // it.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping; Section 4.1.2 -
  // Valid Framing.
  // -------------------------------------------------------------------------
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

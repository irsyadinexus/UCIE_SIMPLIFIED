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
// The testbench verifies six specific requirements:
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
//   (c) TX framing pattern per spec section 4.1.2 and PLAN.md 6.2:
//       Valid is asserted for the first four UI of each eight-UI transfer.
//       One mbclk cycle carries two UIs, so the transmit qualifier must be
//       high in cycles 0 and 1 and low in cycles 2 and 3 of every transfer
//       window, and constant low while idle. The pattern inspector collects
//       the four samples of each window and requires 1100 for a word in
//       flight or 0000 for an idle window, and it counts the framed windows
//       so that count must equal the number of pushed words.
//
//   (d) RX word strobe per spec section 4.1.2:
//       The rx_word_vld strobe must pulse exactly once per word whose window
//       carried the legal 1100 pattern, never for an idle window, and never
//       for a window rejected by the framing monitor. After the final word
//       drains, the testbench checks that rx_word_vld has returned to zero.
//       Any stray assertion is flagged as a framing error.
//
//   (e) Private framing-fault detection and stickiness (PLAN.md 6.2 and
//       15.9 Phase E):
//       The rx_gearbox framing_fault output must stay low for all legal
//       loopback traffic and set for any window that is not 1100 or 0000:
//       an early qualifier transition, a late qualifier transition, or a
//       malformed pattern that changes and returns inside the window. The
//       flag must hold across later legal windows, clear only when lreset_n
//       is asserted, and stay clear after the reset is released. The framing
//       injector below drives the violations; the data path itself is left
//       untouched, and a rejected window must produce no word strobe.
//

//   (f) Evidence export (Phase F):
//       On clean zero-error completion, the test exports a minimal JSON
//       evidence fragment to logs/gearbox_evidence.json capturing proof of
//       mainband framing fault detection and stickiness across legal and
//       malformed framing patterns.
// LOOPBACK ARCHITECTURE
// ~~~~~~~~~~~~~~~~~~~~~
// The testbench wires the TX and RX gearboxes in a zero-delay loopback
// using continuous assignments:
//
//   assign mb_rx_wire     = mb_tx_wire;      // 16-bit data loopback
//   assign mb_rx_val_wire = injector(mb_tx_val_wire, pattern); // framing
//
// The framing-valid wire passes through a test-only framing injector. It
// selects the transmit framing bit unchanged except inside deliberately
// injected windows, where it drives a requested four-cycle pattern, so the
// framing monitor can be exercised with early, late, and malformed patterns
// without touching the data path or any other check.
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
//   4. The transmit framing wire carries 1100 for every word window and 0000
//      for every idle window, and the count of framed windows equals the
//      count of pushed words.
//   5. framing_fault stays low for the legal loopback stream, sets on every
//      injected early, late, or malformed pattern, stays sticky across later
//      legal windows, and clears only when lreset_n is asserted.
//   6. No injected window produces an rx_word_vld pulse.
//   7. The test completes before the 500 µs watchdog timer fires.
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
//   PLAN.md, Section 15.9 Phase F - Coverage and Verification Integration
//     Defines multi-source Phase F coverage aggregation and unit evidence
//     export requirements.
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
//   0.0.3 2026-09-25  -           Phase E: connect the private rx_gearbox
//                                 framing_fault output and add the
//                                 mid-word valid violation, stickiness, and
//                                 reset-clear checks. Add the test-only
//                                 framing-valid injection mux.
//   0.0.4 2026-09-25  -           Phase E: check the legal 1100 framing
//                                 pattern on the transmit wire (valid high
//                                 for the first four UI), replace the
//                                 mid-word inversion with a per-window
//                                 framing injector, and require early, late,
//                                 and malformed patterns to set the sticky
//                                 framing_fault while suppressing the word
//                                 strobe. Release lreset_n on a mbclk
//                                 negedge so the two window counters stay
//                                 phase aligned.
//   0.0.5 2026-09-25  -           Phase F: add minimal JSON evidence export
//                                 to logs/gearbox_evidence.json on error-free
//                                 completion covering mainband framing fault
//                                 detection.
//   0.0.6 2026-09-25  -           Restore comment markers on the Phase F plan
//                                 reference and evidence export history.
//   0.0.7 2026-09-25  Restore the closing initial-block delimiter after the
//                                 Phase F evidence writer.
//   0.0.8 2026-10-08  Documentation compliance pass: add 5-20 line
//                                 spec-referenced comment blocks above the
//                                 framing-injection mux assigns and the
//                                 mbclk sampling/monitor always blocks.
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
  // Framing patterns for one four-mbclk-cycle transfer window, MSB = cycle 0
  // (spec 4.1.2, PLAN.md 6.2). PAT_VALID and PAT_IDLE are the only legal
  // patterns; every other pattern is a framing violation.
  localparam logic [3:0] PAT_IDLE     = 4'b0000;  // no word in flight
  localparam logic [3:0] PAT_VALID    = 4'b1100;  // valid for the first 4 UI
  localparam logic [3:0] PAT_HELD     = 4'b1111;  // late: never falls
  localparam logic [3:0] PAT_EARLY    = 4'b1000;  // early: falls after 1 UI
  localparam logic [3:0] PAT_SHIFTED  = 4'b0110;  // window off by one cycle
  localparam logic [3:0] PAT_REASSERT = 4'b1101;  // re-rises inside window

  // Test-only framing injector and the private fault output. When armed, the
  // receiver framing input is driven from the requested pattern for exactly
  // one window instead of from the transmit framing bit.
  logic       inj_arm;     // request one injected window
  logic       inj_en;      // injection active (one window)
  logic [3:0] inj_pat;     // [3] = cycle 0, [0] = cycle 3
  logic       framing_fault;

  // Main-band wires between the transmitter pin and the receiver pin. The
  // data wire is a plain alias. The framing wire is selected through the
  // injector, whose enable and pattern register change in the NBA region of
  // the mbclk edge, so the wire never changes in the same time step in which
  // the receiver samples it.
  assign mb_rx_wire     = mb_tx_wire;

  // -------------------------------------------------------------------------
  // assign: mb_rx_val_wire - Receive Framing Valid Wire Multiplexer
  //
  // Selects between error injector pattern bits (inj_pat) or direct transmit
  // framing wire (mb_tx_val_wire) to test receiver framing fault detection.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  assign mb_rx_val_wire = inj_en ? inj_pat[3 - int'(u_rx.cyc_q)] : mb_tx_val_wire;

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
  // means one complete word whose window carried the legal 1100 pattern has
  // been reassembled and is ready to compare.
  //
  // framing_fault is the private sticky fault output added for PLAN.md
  // Sections 6.2 and 15.9 Phase E. It sets on any window that is not the
  // legal 1100 or idle 0000 pattern and holds until lreset_n. It is
  // unconnected in production, so the unit test is the only place that
  // observes it directly.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping; Section 4.1.2 -
  //           Valid Framing.
  // -------------------------------------------------------------------------
  rx_gearbox u_rx (
    .lclk(lclk), .lreset_n(lreset_n), .mbclk(mbclk),
    .mb_rx_data(mb_rx_wire), .mb_rx_valid(mb_rx_val_wire),
    .rx_word(rx_word), .rx_word_vld(rx_word_vld),
    .framing_fault(framing_fault)
  );
  // -------------------------------------------------------------------------
  // always: Framing Injector Sequencer - exactly one injected window
  //
  // One injected window per request. The request is consumed on the mbclk
  // edge that ends one window and starts the next (u_rx.cyc_q == 3 at the
  // edge), so the injected pattern always occupies one complete window and
  // never bleeds into a neighbouring cycle: the mux selects the pattern bit
  // for the cycle that is in progress, and the enable is released one
  // boundary later.
  //
  // Both registers change with non-blocking assignments, so they settle in
  // the NBA region of the edge, after the receiver has already sampled
  // mb_rx_val_wire for the cycle that just ended. Clearing the request at
  // the same boundary keeps a late clear by the stimulus from starting a
  // second window.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Section 6.2.
  // -------------------------------------------------------------------------
  always @(posedge mbclk) begin
    if (!lreset_n) begin
      inj_en  <= 1'b0;
      inj_arm <= 1'b0;
    end else if (u_rx.cyc_q == 2'd3) begin
      if (inj_en)       inj_en  <= 1'b0;   // injected window complete
      else if (inj_arm) inj_en  <= 1'b1;   // start the injected window
      inj_arm <= 1'b0;                     // request consumed
    end
  end

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
  initial begin lclk = 1'b0; mbclk = 1'b0; end

  // -------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz parallel clock for 128-bit gearbox word transfers.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Data Rates.
  // -------------------------------------------------------------------------
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
  // task: inject_window - present one complete framing pattern to the receiver
  //
  // Arms the injector with pat and waits until the pattern has been delivered
  // and judged. The injector aligns the pattern to the receiver window
  // boundary, so pat[3] is the level of cycle 0 (the window reference) and
  // pat[0] is the level of cycle 3. The wait covers the worst case: up to
  // four edges until the boundary that consumes the request, four edges for
  // the window itself, and two more edges so the framing fault flop has
  // settled before the caller reads it.
  //
  // Only the framing qualifier is disturbed. The data wire, the cycle
  // counters, and the assembled word are untouched, so the round-trip
  // scoreboard above stays valid.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Section 6.2.
  // -------------------------------------------------------------------------
  task inject_window(input logic [3:0] pat);
    begin
      @(posedge mbclk);               // leave the current time step first
      inj_pat = pat;
      inj_arm = 1'b1;
      repeat (10) @(posedge mbclk);   // boundary (<=4) + window (4) + settle
      #0.1;
    end
  endtask

  // -------------------------------------------------------------------------
  // task: check_malformed_framing - one illegal window must be rejected
  //
  // Presents pat to the receiver for one window and requires exactly one
  // verdict from the private framing monitor: the word of that window is
  // rejected - the word monitor above flags any rx_word_vld pulse as an
  // unexpected beat, because the expected queue is empty by now - and
  // framing_fault is set. The flag must then survive legal idle windows,
  // clear only on lreset_n, and stay clear after the reset is released, so
  // every pattern gets a clean verdict.
  //
  // lreset_n is released on a mbclk negedge so the two window counters leave
  // reset on the same edge and stay phase aligned, which is what makes the
  // 1100 pattern legal end to end.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Sections 6.2, 15.6 and 15.9 Phase E.
  // -------------------------------------------------------------------------
  task check_malformed_framing(input logic [3:0] pat);
    begin
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault set before injecting %b4",
                 pat);
        errors = errors + 1;
      end
      inject_window(pat);
      if (framing_fault !== 1'b1) begin
        $display("FAIL ut_gearbox: framing pattern %b4 did not set framing_fault",
                 pat);
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: pattern %b4 rejected", pat);
      end
      // Legal idle windows must not clear the sticky flag.
      repeat (16) @(posedge mbclk);
      if (framing_fault !== 1'b1) begin
        $display("FAIL ut_gearbox: framing_fault cleared by legal traffic");
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: flag stays sticky");
      end
      // Only the asynchronous reset clears it, and it must not return.
      lreset_n = 1'b0;
      #0.1;
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault survived lreset_n");
        errors = errors + 1;
      end
      @(negedge mbclk); #0.01;         // release away from a sampling edge
      lreset_n = 1'b1;
      repeat (8) @(posedge mbclk);
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault re-asserted after reset");
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: cleared by lreset_n");
      end
    end
  endtask

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

  // -------------------------------------------------------------------------
  // always: Double Data Rate (DDR) Pin Sampler & Bit Transpose Checker
  //
  // Samples pin wires on posedge and negedge mbclk (both DDR edges) with
  // small delta delay to verify byte-to-lane mapping per Section 4.1.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
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
  // always: TX Framing Pattern Inspector - spec 4.1.2 / PLAN.md 6.2
  //
  // Collects the transmit framing qualifier of one transfer window, one
  // sample per mbclk cycle, and requires the collected pattern to be one of
  // the two legal patterns:
  //
  //   mbclk cycle : 0    1    2    3
  //   UI          : 0,1  2,3  4,5  6,7
  //   PAT_VALID   : 1    1    0    0      valid for the first four UI
  //   PAT_IDLE    : 0    0    0    0      no word in flight
  //
  // The sample index comes from the transmitter cycle counter, so the check
  // is tied to the transfer window rather than to absolute time. After the
  // settling delay, cyc_q is the cycle that just started and the qualifier on
  // the wire is the level the receiver samples at the end of that cycle, so
  // the four samples of a window are its cycles 0, 1, 2 and 3 in order.
  //
  // tx_pat_cnt counts the samples of the window in progress. It is held at
  // zero while lreset_n is low and is judged only when it reaches four, so a
  // window that is only partly sampled after a reset release is never judged.
  // tx_valid_windows counts the windows that carried a word, which must equal
  // the number of words the stimulus pushed.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Section 6.2 - Valid framing.
  logic [3:0] tx_pat_q;          // window: [3] = cycle 0 ... [0] = cycle 3
  int         tx_pat_cnt;        // samples collected in the current window
  int         tx_valid_windows;  // windows that carried the PAT_VALID pattern

  // -------------------------------------------------------------------------
  // always: Transmit Framing Pattern Window Monitor
  //
  // Reconstructs the 4-phase framing pattern across mbclk cycles and verifies
  // that PAT_VALID (4'b1000) or PAT_IDLE (4'b0000) is transmitted per spec.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  always @(posedge mbclk) begin
    #0.01;                       // let the mbclk-cycle registers settle
    if (!lreset_n) begin
      tx_pat_cnt = 0;
    end else begin
      if (tx_pat_cnt < 4) tx_pat_cnt = tx_pat_cnt + 1;
      tx_pat_q[3 - int'(u_tx.cyc_q)] = mb_tx_val_wire;
      if (int'(u_tx.cyc_q) == 3) begin
        if (tx_pat_cnt == 4 && tx_pat_q !== PAT_VALID &&
            tx_pat_q !== PAT_IDLE) begin
          $display("FAIL ut_gearbox: illegal TX valid framing %b4 in cycles 0..3 (legal 1100 / 0000)",
                   tx_pat_q);
          errors = errors + 1;
        end
        if (tx_pat_cnt == 4 && tx_pat_q === PAT_VALID)
          tx_valid_windows = tx_valid_windows + 1;
        tx_pat_cnt = 0;
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
    inj_arm = 1'b0; inj_en = 1'b0; inj_pat = PAT_IDLE;
    tx_pat_cnt = 0; tx_valid_windows = 0;
    repeat (4) @(posedge lclk);
    // lreset_n is released on a mbclk negedge, never on a mbclk posedge, so
    // the transmitter and receiver window counters leave reset on the same
    // edge and stay phase aligned: the 1100 pattern is only legal when the
    // two counters agree on the window boundary.
    @(negedge mbclk); #0.01;
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

    // ---- Phase E: legal 1100 framing -------------------------------
    // Every word must leave the wire framed with the legal pattern, and the
    // whole stream must leave the private fault monitor clear.
    if (tx_valid_windows != N) begin
      $display("FAIL ut_gearbox: %0d legally framed windows for %0d words",
               tx_valid_windows, N);
      errors = errors + 1;
    end else begin
      $display("PASS ut_gearbox: %0d words framed with the legal 1100 pattern",
               tx_valid_windows);
    end
    if (framing_fault !== 1'b0) begin
      $display("FAIL ut_gearbox: legal framing set framing_fault");
      errors = errors + 1;
    end else begin
      $display("PASS ut_gearbox: legal framing left framing_fault clear");
    end

    // ---- Phase E: malformed framing is rejected --------------------
    // Early and late qualifier transitions plus malformed windows must each
    // set the sticky private fault and suppress the word strobe. Every case
    // ends with a reset so the next one starts from a clean monitor.
    check_malformed_framing(PAT_HELD);      // qualifier never falls
    check_malformed_framing(PAT_EARLY);     // qualifier falls after one UI
    check_malformed_framing(PAT_SHIFTED);   // window off by one cycle
    check_malformed_framing(PAT_REASSERT);  // qualifier re-rises in the window

    // Phase F: export unit evidence JSON upon clean zero-error completion.
    // Spec ref: UCIe 1.0 Section 4.1.2 and PLAN.md Section 15.9 Phase F.
    if (errors == 0) begin
      integer fd;
      fd = $fopen("logs/gearbox_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{\n");
        $fwrite(fd, "  \"framing_fault\": 1,\n");
        $fwrite(fd, "  \"mb_framing_fault\": 1\n");
        $fwrite(fd, "}\n");
        $fclose(fd);
      end
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

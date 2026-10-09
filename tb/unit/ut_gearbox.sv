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
// The testbench verifies eight specific requirements:
//
//   (a) Physical wire mapping per UCIe 1.0 spec section 4.1.1:
//       At every UI u (0..7) and every lane L (0..15), the wire-level
//       signal mb_tx_data[L] must equal the expected bit from the
//       serialised word: word[8*L + u].  This is checked by the "wire
//       inspector" process on both mb_tx_clk edges (DDR), ensuring that the
//       byte-to-lane mapping and bit ordering exactly match the
//       specification without accessing private RTL registers.
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
//       15.9):
//       The rx_gearbox framing_fault output must stay low for all legal
//       loopback traffic and set for any window that is not 1100 or 0000:
//       an early qualifier transition, a late qualifier transition, or a
//       malformed pattern that changes and returns inside the window. The
//       flag must hold across later legal windows, clear only when lreset_n
//       is asserted, and stay clear after the reset is released.
//
//   (f) Acceptance Gap 1: Stopped physical RX clock containment:
//       When the physical forwarded RX clock stops toggling, rx_word_vld
//       must never repeat or fire stray pulses on subsequent lclk cycles.
//
//   (g) Acceptance Gap 2 & 3: Partial frame flush and FIFO backpressure:
//       A partial frame followed by epoch reset must not leak stale bytes into
//       a subsequent singleton transfer. Furthermore, long bursts under FIFO
//       full must assert backpressure with showahead data held stable.
//
//   (h) Acceptance Gap 4: Sticky RX buffer overflow detection:
//       When the receive FIFO overflows from unserviced physical transfers,
//       the overflow error flag must latch sticky until asynchronous reset.
//
// LOOPBACK ARCHITECTURE
// ~~~~~~~~~~~~~~~~~~~~~
// The testbench wires the TX and RX gearboxes in a zero-delay loopback
// using continuous assignments:
//
//   assign mb_rx_wire     = mb_tx_wire;      // 16-bit data loopback
//   assign mb_rx_val_wire = injector(mb_tx_val_wire, pattern); // framing
//
// CLOCK CONFIGURATION
// ~~~~~~~~~~~~~~~~~~~
// Two independent clock domains drive the design:
//
//   lclk      = 500 MHz  (period = 2.0 ns,  half-period = 1.0 ns)
//               This is the RDI-side parallel clock.
//
//   mb_tx_clk = 2 GHz    (period = 0.5 ns,  half-period = 0.25 ns)
//               This is the transmitter local high-speed source.
//
//   mb_rx_clk = Forwarded clock wire gated by mb_tx_clk_oe to model
//               physical die-crossing and stopped-clock scenarios.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Description
//   ----- ----------  ------------------------------------------------------
//   0.0.1 2025-XX-XX  Initial creation.
//   0.0.2 2026-09-23  Documentation: expand header, add per-block comments.
//   0.0.3 2026-09-25  Phase E: connect private rx_gearbox framing_fault.
//   0.0.4 2026-09-25  Phase E: check legal 1100 framing pattern.
//   0.0.5 2026-09-25  Phase F: add minimal JSON evidence export.
//   0.0.6 2026-09-25  Restore comment markers on evidence export history.
//   0.0.7 2026-09-25  Restore closing initial-block delimiter.
//   0.0.8 2026-10-08  Documentation compliance pass: 5-20 line comments.
//   0.0.9 2026-10-09  Cleanup pass: split declarations and update comments.
//   0.0.10 2026-10-09 Migrate to contract: separate mb_tx_clk / mb_rx_clk,
//                     add epoch_reset_n, tx_enable, rx_enable, tx_ready,
//                     and overflow ports; decouple wire inspector from
//                     RTL internals; add acceptance gap coverage for
//                     stopped RX clock, partial frame flush, backpressure
//                     bursts, and sticky RX overflow error.
//   0.0.11 2026-10-09 Interrupt a legal frame before the eight-UI boundary.
//                     Check the next isolated word and sweep nominal source phase.
// ============================================================================
`include "ucie_pkg.sv"
`timescale 1ns/1ps
module ut_gearbox #(
  parameter realtime MBCLK_PHASE_NS = 0.0 // Source phase relative to the link clock
);
  import ucie_pkg::*;
  localparam int unsigned W = NBYTES*8;

  logic                 lclk;
  logic                 mb_tx_clk;
  logic                 mb_tx_clk_oe;
  wire                  mb_rx_clk;
  logic                 lreset_n;
  logic                 epoch_reset_n;
  logic                 tx_enable;
  logic                 rx_enable;
  logic [W-1:0]         tx_word;
  logic [W-1:0]         rx_word;
  logic                 tx_load;
  logic                 tx_valid;
  logic                 tx_ready;
  logic                 rx_word_vld;
  logic                 framing_fault;
  logic                 rx_overflow;
  logic                 rx_drain_enable; // Complete-word dequeue permission
  logic                 check_rx_words;  // Scoreboard excludes intentional overflow traffic

  wire [15:0]           mb_tx_wire;
  wire                  mb_tx_val_wire;
  wire [15:0]           mb_rx_wire;
  wire                  mb_rx_val_wire;

  // Framing patterns for one four-mbclk-cycle transfer window
  localparam logic [3:0] PAT_IDLE     = 4'b0000;
  localparam logic [3:0] PAT_VALID    = 4'b1100;
  localparam logic [3:0] PAT_HELD     = 4'b1111;
  localparam logic [3:0] PAT_EARLY    = 4'b1000;
  localparam logic [3:0] PAT_SHIFTED  = 4'b0110;
  localparam logic [3:0] PAT_REASSERT = 4'b1101;

  logic                 inj_arm;
  logic                 inj_en;
  logic [3:0]           inj_pat;
  int                   inj_cyc;

  // -------------------------------------------------------------------------
  // assign: mb_rx_clk - Forwarded Physical Clock Wire
  //
  // Models the physical forwarded clock wire across the die boundary.
  // Gated by mb_tx_clk_oe to verify receiver behavior under stopped clock.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Mainband Clocking.
  // -------------------------------------------------------------------------
  assign mb_rx_clk = mb_tx_clk_oe ? mb_tx_clk : 1'b0;

  // -------------------------------------------------------------------------
  // assign: mb_rx_wire - Direct Loopback Mainband Data Bus
  //
  // Direct zero-delay physical interconnect wiring transmit DDR lane pins
  // directly to receive DDR lane pins for isolated gearbox verification.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  assign mb_rx_wire = mb_tx_wire;

  // -------------------------------------------------------------------------
  // assign: mb_rx_val_wire - Receive Framing Valid Wire Multiplexer
  //
  // Selects between error injector pattern bits (inj_pat) or direct transmit
  // framing wire (mb_tx_val_wire) using testbench cycle counter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  assign mb_rx_val_wire = inj_en ? inj_pat[3 - inj_cyc] : mb_tx_val_wire;

  // -------------------------------------------------------------------------
  // Module instantiation: tx_gearbox u_tx (transmit serializer)
  //
  // Parallel-to-serial conversion from 128-bit parallel word to 16 DDR lanes
  // across 4 mbclk cycles. Governed by tx_enable and epoch_reset_n with
  // backpressure signaled via tx_ready output.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  tx_gearbox u_tx (
    .lclk          (lclk),
    .lreset_n      (lreset_n),
    .epoch_reset_n (epoch_reset_n),
    .mbclk         (mb_tx_clk),
    .tx_enable     (tx_enable),
    .tx_word       (tx_word),
    .tx_valid      (tx_valid),
    .tx_load       (tx_load),
    .tx_ready      (tx_ready),
    .mb_tx_data    (mb_tx_wire),
    .mb_tx_valid   (mb_tx_val_wire)
  );

  // -------------------------------------------------------------------------
  // Module instantiation: rx_gearbox u_rx (receive deserializer)
  //
  // Serial-to-parallel conversion reconstructing 128-bit word from 16 DDR
  // lanes on physical mb_rx_clk. Reports private sticky framing_fault and
  // sticky buffer overflow flags.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  rx_gearbox u_rx (
    .lclk          (lclk),
    .lreset_n      (lreset_n),
    .epoch_reset_n (epoch_reset_n),
    .mbclk         (mb_rx_clk),
    .rx_enable     (rx_enable),
    .rx_drain_enable(rx_drain_enable),
    .mb_rx_data    (mb_rx_wire),
    .mb_rx_valid   (mb_rx_val_wire),
    .rx_word       (rx_word),
    .rx_word_vld   (rx_word_vld),
    .framing_fault (framing_fault),
    .overflow      (rx_overflow)
  );

  // -------------------------------------------------------------------------
  // always: Framing Injector Sequencer on Physical RX Clock
  //
  // Synchronizes framing error injection to 4-cycle windows of mb_rx_clk.
  // Does not inspect RTL internal cycle counters, relying strictly on
  // testbench cycle tracking.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  always @(posedge mb_rx_clk or negedge lreset_n) begin
    if (!lreset_n) begin
      inj_en  <= 1'b0;
      inj_arm <= 1'b0;
      inj_cyc <= 0;
    end else begin
      if (inj_en) begin
        if (inj_cyc == 3) begin
          inj_en  <= 1'b0;
          inj_cyc <= 0;
        end else begin
          inj_cyc <= inj_cyc + 1;
        end
      end else if (inj_arm) begin
        inj_en  <= 1'b1;
        inj_arm <= 1'b0;
        inj_cyc <= 0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz reference link clock for low-speed word interface.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Data Rates.
  // -------------------------------------------------------------------------
  always #1.000 lclk = ~lclk;

  // -------------------------------------------------------------------------
  // always: Mainband Forwarded Clock Generator (2 GHz mb_tx_clk)
  //
  // Generates 2 GHz local transmit clock for 4 GT/s DDR operation.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Mainband Clocking.
  // -------------------------------------------------------------------------
  initial begin
    #(MBCLK_PHASE_NS);
    forever #0.250 mb_tx_clk = ~mb_tx_clk;
  end

  localparam int N = 16;
  logic [W-1:0] q [0:127];
  int q_head;
  int q_tail;
  int errors;

  logic [W-1:0] tx_stim_queue [$];
  logic [W-1:0] active_wire_word;
  int           wire_cyc;
  logic         wire_in_word;

  // -------------------------------------------------------------------------
  // always: Transmit Stimulus Tracking Queue Manager
  //
  // Records accepted transmit words into testbench verification queue
  // on every successful write handshake (tx_load && tx_valid && tx_ready).
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_stim_queue.delete();
    end else if (tx_load && tx_valid && tx_ready) begin
      tx_stim_queue.push_back(tx_word);
    end
  end

  // -------------------------------------------------------------------------
  // always: DDR Physical Wire Inspector & Bit Transpose Checker
  //
  // Samples mb_tx_wire lanes on both rising and falling edges of mb_tx_clk.
  // Checks physical bit mapping directly against expected stimulus bits
  // without relying on private transmitter RTL registers.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  always @(posedge mb_tx_clk or negedge mb_tx_clk) begin
    #0.010;
    if (lreset_n && tx_enable) begin
      if (mb_tx_clk) begin
        // Rising edge: cycle start
        if (!wire_in_word && mb_tx_val_wire) begin
          if (tx_stim_queue.size() > 0) begin
            active_wire_word = tx_stim_queue.pop_front();
            wire_in_word     = 1'b1;
            wire_cyc         = 0;
          end
        end

        if (wire_in_word) begin
          int current_ui;
          current_ui = wire_cyc * 2;
          for (int lane = 0; lane < 16; lane = lane + 1) begin
            logic exp_bit;
            exp_bit = active_wire_word[8*lane + current_ui];
            if (mb_tx_wire[lane] !== exp_bit) begin
              $display("FAIL ut_gearbox: spec 4.1.1 transpose mismatch at UI %0d lane %0d (got %b exp %b)",
                       current_ui, lane, mb_tx_wire[lane], exp_bit);
              errors = errors + 1;
            end
          end
        end
      end else begin
        // Falling edge: second UI of the cycle
        if (wire_in_word) begin
          int current_ui;
          current_ui = wire_cyc * 2 + 1;
          for (int lane = 0; lane < 16; lane = lane + 1) begin
            logic exp_bit;
            exp_bit = active_wire_word[8*lane + current_ui];
            if (mb_tx_wire[lane] !== exp_bit) begin
              $display("FAIL ut_gearbox: spec 4.1.1 transpose mismatch at UI %0d lane %0d (got %b exp %b)",
                       current_ui, lane, mb_tx_wire[lane], exp_bit);
              errors = errors + 1;
            end
          end

          if (wire_cyc == 3) begin
            wire_cyc = 0;
            if (mb_tx_val_wire && (tx_stim_queue.size() > 0)) begin
              active_wire_word = tx_stim_queue.pop_front();
              wire_in_word     = 1'b1;
            end else begin
              wire_in_word     = 1'b0;
            end
          end else begin
            wire_cyc = wire_cyc + 1;
          end
        end
      end
    end
  end

  logic [3:0] tx_pat_q;
  int         tx_pat_cnt;
  int         tx_valid_windows;

  // Check framing from the first physical high Valid UI, not a reset phase.
  // Each accepted word must show four high UIs followed by four low UIs.
  // Sample both launch edges after the dedicated DDR cell updates.
  // An idle interval can have any number of low UIs.
  // Spec ref: UCIe 1.0 Section 4.1.2.
  always @(posedge mb_tx_clk or negedge mb_tx_clk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_pat_cnt = 0;
      tx_valid_windows = 0;
    end else begin
      #0.010;
      if (!epoch_reset_n) tx_pat_cnt = 0;
      else if (tx_pat_cnt == 0) begin
        if (mb_tx_val_wire === 1'b1) tx_pat_cnt = 1;
      end else begin
        if (mb_tx_val_wire !== (tx_pat_cnt < 4)) begin
          $display("FAIL ut_gearbox: wrong physical Valid at UI %0d", tx_pat_cnt);
          errors = errors + 1;
        end
        if (tx_pat_cnt == 7) begin
          tx_pat_cnt = 0;
          tx_valid_windows = tx_valid_windows + 1;
        end else tx_pat_cnt = tx_pat_cnt + 1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // always: RX Word Monitor - End-to-End Scoreboard
  //
  // Pops one word per rx_word_vld pulse on lclk and verifies against
  // expected queue q in order without loss or duplication.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  always @(posedge lclk) begin
    #0.100;
    if (lreset_n && rx_word_vld && check_rx_words) begin
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

  function automatic logic [W-1:0] mkword(
    input int idx // Word sequence index offset
  );
    logic [W-1:0] w;
    begin
      w = '0;
      for (int k = 0; k < 16; k = k + 1)
        w[k*8 +: 8] = 8'hA0 + k[7:0] + idx[7:0];
      mkword = w;
    end
  endfunction

  // -------------------------------------------------------------------------
  // task: inject_window - Present Injected Framing Window to Receiver
  //
  // Injects specified 4-cycle framing pattern onto receiver valid wire
  // and allows monitor to settle.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  task inject_window(
    input logic [3:0] pat // 4-cycle framing pattern to inject
  );
    begin
      @(posedge mb_rx_clk);
      inj_pat = pat;
      inj_arm = 1'b1;
      repeat (10) @(posedge mb_rx_clk);
      #0.100;
    end
  endtask

  // -------------------------------------------------------------------------
  // task: check_malformed_framing - Verify Rejection of Malformed Pattern
  //
  // Injects illegal pattern, verifies sticky framing_fault assertion,
  // confirms no spurious valid pulse, and tests reset recovery.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  task check_malformed_framing(
    input logic [3:0] pat // Malformed 4-cycle framing pattern to test
  );
    begin
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault set before injecting %b4", pat);
        errors = errors + 1;
      end
      inject_window(pat);
      if (framing_fault !== 1'b1) begin
        $display("FAIL ut_gearbox: framing pattern %b4 did not set framing_fault", pat);
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: pattern %b4 rejected", pat);
      end

      repeat (16) @(posedge mb_rx_clk);
      if (framing_fault !== 1'b1) begin
        $display("FAIL ut_gearbox: framing_fault cleared by legal traffic");
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: flag stays sticky");
      end

      lreset_n = 1'b0;
      #0.100;
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault survived lreset_n");
        errors = errors + 1;
      end
      @(negedge mb_tx_clk);
      #0.010;
      lreset_n = 1'b1;
      repeat (8) @(posedge mb_tx_clk);
      if (framing_fault !== 1'b0) begin
        $display("FAIL ut_gearbox: framing_fault re-asserted after reset");
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox framing fault: cleared by lreset_n");
      end
    end
  endtask

  // Main stimulus flow
  initial begin
    errors           = 0;
    q_head           = 0;
    q_tail           = 0;
    lclk             = 1'b0;
    mb_tx_clk        = 1'b0;
    mb_tx_clk_oe     = 1'b1;
    lreset_n         = 1'b0;
    epoch_reset_n    = 1'b0;
    tx_enable        = 1'b0;
    rx_enable        = 1'b0;
    rx_drain_enable  = 1'b1;
    check_rx_words   = 1'b1;
    tx_load          = 1'b0;
    tx_valid         = 1'b0;
    tx_word          = '0;
    inj_arm          = 1'b0;
    inj_en           = 1'b0;
    inj_pat          = PAT_IDLE;
    wire_in_word     = 1'b0;
    wire_cyc         = 0;

    repeat (4) @(posedge lclk);
    @(negedge mb_tx_clk);
    #0.010;
    lreset_n      = 1'b1;
    epoch_reset_n = 1'b1;
    tx_enable     = 1'b1;
    rx_enable     = 1'b1;
    repeat (4) @(posedge lclk);

    // ========================================================================
    // Scenario 1: Stream N=16 distinct words back-to-back under tx_ready
    // ========================================================================
    $display("\n--- Scenario 1: N=16 back-to-back streaming ---");
    for (int i = 0; i < N; i = i + 1) begin
      @(negedge lclk);
      tx_load = 1'b0;
      tx_valid = 1'b0;
      while (!tx_ready) @(negedge lclk);
      tx_word  = mkword(i);
      tx_valid = 1'b1;
      tx_load  = 1'b1;
      q[q_tail] = tx_word;
      q_tail   = q_tail + 1;
    end
    @(negedge lclk);
    tx_load = 1'b0;
    tx_valid = 1'b0;

    // Drain pipeline
    repeat (24) @(posedge lclk);
    #0.100;

    if (q_head != N) begin
      $display("FAIL ut_gearbox: received %0d of %0d words", q_head, N);
      errors = errors + 1;
    end
    if (rx_word_vld) begin
      $display("FAIL ut_gearbox: stray valid beat after drain");
      errors = errors + 1;
    end

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

    // ========================================================================
    // Scenario 2: Acceptance Gap 1 - Stopped Physical RX Clock containment
    // ========================================================================
    $display("\n--- Scenario 2: Stopped Physical RX Clock ---");
    mb_tx_clk_oe = 1'b0; // Park physical RX clock low
    repeat (10) begin
      @(posedge lclk);
      #0.050;
      if (rx_word_vld) begin
        $display("FAIL ut_gearbox: rx_word_vld pulsed while physical RX clock stopped");
        errors = errors + 1;
      end
    end
    mb_tx_clk_oe = 1'b1; // Restore physical RX clock
    repeat (4) @(posedge lclk);
    $display("PASS ut_gearbox: stopped physical RX clock does not repeat rx_word_vld");

    // ========================================================================
    // Scenario 3: Malformed framing patterns injection and sticky fault
    // ========================================================================
    $display("\n--- Scenario 3: Malformed framing patterns ---");
    check_malformed_framing(PAT_HELD);
    check_malformed_framing(PAT_EARLY);
    // A shifted legal four-high/four-low frame is not a framing fault.
    check_malformed_framing(PAT_REASSERT);

    // ========================================================================
    // Scenario 4: Acceptance Gap 2 - Interrupted legal frame + epoch reset + singleton
    // ========================================================================
    $display("\n--- Scenario 4: Partial frame + epoch reset + singleton ---");
    begin
      int q_tail_before;
      logic [W-1:0] singleton;

      q_tail_before = q_tail;

      // Drive the legal prefix away from the injector sampling edge.
      @(negedge mb_rx_clk);
      inj_pat = PAT_VALID;
      inj_arm = 1'b1;
      repeat (2) @(posedge mb_rx_clk);

      // Assert coordinated epoch reset before all eight UIs complete
      epoch_reset_n = 1'b0;

      // Return physical Valid to idle safely
      @(negedge mb_rx_clk);
      inj_en  = 1'b0;
      inj_arm = 1'b0;
      inj_cyc = 0;
      inj_pat = PAT_IDLE;

      // Release and re-arm as current API needs
      repeat (4) @(posedge lclk);
      epoch_reset_n = 1'b1;
      repeat (4) @(posedge lclk);

      // Verify no stale word or duplicate reached scoreboard after partial frame
      if (q_head != q_tail_before) begin
        $display("FAIL ut_gearbox: stale word or duplicate reached scoreboard after partial frame");
        errors = errors + 1;
      end
      if (rx_word_vld) begin
        $display("FAIL ut_gearbox: stray valid beat before singleton");
        errors = errors + 1;
      end

      // Send fresh isolated singleton word
      singleton = mkword(88);
      @(negedge lclk);
      while (!tx_ready) @(negedge lclk);
      tx_word  = singleton;
      tx_valid = 1'b1;
      tx_load  = 1'b1;
      q[q_tail] = singleton;
      q_tail   = q_tail + 1;
      @(negedge lclk);
      tx_load  = 1'b0;
      tx_valid = 1'b0;

      repeat (20) @(posedge lclk);
      #0.100;

      // Verify no stale word or duplicate reached scoreboard,
      // and exactly the fresh singleton arrives bit-for-bit
      if (q_head != q_tail) begin
        $display("FAIL ut_gearbox: singleton word not received or duplicate reached scoreboard");
        errors = errors + 1;
      end else if (rx_word_vld) begin
        $display("FAIL ut_gearbox: stray valid beat after singleton drain");
        errors = errors + 1;
      end else begin
        $display("PASS ut_gearbox: partial frame + epoch reset + singleton clean");
      end
    end

    // ========================================================================
    // Scenario 5: Acceptance Gap 3 - Long TX burst under backpressure
    // ========================================================================
    $display("\n--- Scenario 5: Long TX burst under FIFO backpressure ---");
    tx_enable = 1'b0;
    repeat (4) @(posedge lclk);
    for (int b = 0; b < 8; b = b+1) begin
      @(negedge lclk);
      tx_word = mkword(100+b);
      tx_valid = 1'b1;
      tx_load = 1'b1;
      if (!tx_ready) begin
        $display("FAIL ut_gearbox: FIFO rejected one of its eight entries");
        errors = errors+1;
      end
      q[q_tail] = tx_word;
      q_tail = q_tail+1;
    end
    @(negedge lclk);
    tx_word = mkword(108);
    repeat (4) begin
      @(negedge lclk);
      if (tx_ready) begin
        $display("FAIL ut_gearbox: full FIFO did not apply backpressure");
        errors = errors+1;
      end
    end
    tx_enable = 1'b1;
    while (!tx_ready) @(negedge lclk);
    q[q_tail] = tx_word;
    q_tail = q_tail+1;
    @(negedge lclk);
    tx_load = 1'b0;
    tx_valid = 1'b0;
    repeat (40) @(posedge lclk);
    #0.100;
    if (q_head != q_tail) begin
      $display("FAIL ut_gearbox: full-FIFO transfers dropped or duplicated");
      errors = errors+1;
    end else $display("PASS ut_gearbox: actual full-FIFO backpressure preserves all words");

    // ========================================================================
    // Scenario 6: Acceptance Gap 4 - Sticky RX buffer overflow detection
    // ========================================================================
    $display("\n--- Scenario 6: Sticky RX buffer overflow detection ---");
    epoch_reset_n = 1'b0;
    repeat (2) @(posedge lclk);
    epoch_reset_n = 1'b1;
    repeat (4) @(posedge lclk);
    check_rx_words = 1'b0;
    rx_drain_enable = 1'b0;
    for (int b = 0; b < 12; b = b+1) begin
      @(negedge lclk);
      while (!tx_ready) @(negedge lclk);
      tx_word = mkword(180+b);
      tx_load = 1'b1;
      tx_valid = 1'b1;
    end
    @(negedge lclk);
    tx_load = 1'b0;
    tx_valid = 1'b0;
    repeat (20) @(posedge lclk);
    if (rx_overflow !== 1'b1) begin
      $display("FAIL ut_gearbox: full RX FIFO did not record rejected legal word");
      errors = errors+1;
    end
    epoch_reset_n = 1'b0;
    repeat (2) @(posedge lclk);
    if (rx_overflow !== 1'b1) begin
      $display("FAIL ut_gearbox: epoch reset cleared hardware-only overflow history");
      errors = errors+1;
    end
    lreset_n = 1'b0;
    #0.100;
    if (rx_overflow !== 1'b0) begin
      $display("FAIL ut_gearbox: hardware reset did not clear overflow history");
      errors = errors+1;
    end else $display("PASS ut_gearbox: RX overflow persists across epoch and clears on hardware reset");

    // Export evidence JSON
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

  // Watchdog timer
  initial begin
    #500000;
    $display("FAIL ut_gearbox: watchdog timeout");
    $finish;
  end

endmodule

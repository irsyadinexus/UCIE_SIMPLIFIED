// ============================================================================
// File        : tb/unit/ut_lfsr.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the scrambler (per-lane LFSR) and ucie_timer
//               modules.
// ============================================================================
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
//   UCIe 1.0 Specification, Section 4.4.1 — Scrambling and training pattern
//       generation.
//   UCIe 1.0 Specification, Section 4.5.3.1 — RESET state (minimum timer).
//   UCIe 1.0 Specification, Section 5.1.1 — Data rates.
//
// OVERVIEW
// ~~~~~~~~
//   This is a directed unit-level testbench that exercises two independent
//   DUTs — the scrambler and the ucie_timer — in isolation, without any
//   bus-level or protocol-level infrastructure.  Both DUTs are instantiated
//   in the same testbench module because they share the UCIe package
//   (ucie_pkg) constants and do not interact with each other.
//
//   The scrambler implements the 23-bit Fibonacci LFSR defined in UCIe 1.0
//   Section 4.4.1 with the polynomial:
//
//       G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
//
//   The polynomial is encoded as the tap mask LFSR_TAPS = 23'h210125 in
//   ucie_pkg.  The scrambler advances 8 LFSR steps per lclk cycle (one
//   per Unit Interval at 4 GT/s), producing an 8-bit data_out vector that
//   is the XOR of data_in with the LFSR output stream.  For this test,
//   data_in is tied to 8'h00 so that data_out directly reflects the raw
//   LFSR bit sequence.
//
//   The ucie_timer is a generic count-up interval timer used in the UCIe
//   link training state machine (LTSM).  It counts clock cycles while
//   `running` is asserted, and pulses `expired` for exactly one cycle
//   when the count reaches LIMIT_CYCLES.  The counter then saturates
//   (no wrap) and will not re-fire until a new `start` pulse is issued.
//
// DUTs (DEVICES UNDER TEST)
// ~~~~~~~~~~~~~~~~~~~~~~~~~
//   1. scrambler
//      - Instance  : u_dut
//      - Parameter : LANE_ID = 3
//      - Seed      : lfsr_seed(3) = 23'h18C0DB (per UCIe 1.0 Table 20)
//      - Clock     : lclk (500 MHz, 1 ns half-period)
//      - data_in   : tied to 8'h00 (raw LFSR output on data_out)
//
//   2. ucie_timer
//      - Instance  : u_timer
//      - Parameter : LIMIT_CYCLES = C_RESET_MIN = 2,000,000 cycles
//                    (4 ms at 500 MHz lclk, per spec 4.5.3.1)
//      - Clock     : tclk (500 MHz, 1 ns half-period)
//
// STIMULUS — 5 DIRECTED CHECKS
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   Check 1 — Seed Reload (LFSR)
//     After deasserting lfsr_reset, the observed LFSR state must match the
//     documented lane-3 seed (lfsr_seed(3) = 23'h18C0DB).  Verifies that
//     the synchronous re-seed path loads the correct initial value from
//     the lfsr_seed() function in ucie_pkg.
//
//   Check 2 — 20-Step Polynomial Match (LFSR)
//     With enable asserted, the DUT advances 8 LFSR steps per lclk cycle.
//     A software reference model (task step_ref) performs the same Fibonacci
//     recurrence using LFSR_TAPS.  After each posedge lclk, the testbench
//     compares state_obs and data_out against the reference.  Twenty
//     consecutive cycles (160 LFSR steps total) are checked.
//
//   Check 3 — Disabled State Hold (LFSR)
//     When enable is deasserted, the LFSR state must freeze.  Five
//     additional lclk cycles are observed; state_obs must remain unchanged.
//
//   Check 4 — Timer Expiry at Exactly C_RESET_MIN (Timer)
//     The timer is started and `running` held high.  After C_RESET_MIN − 1
//     posedge tclk edges, `expired` must still be 0.  On the very next
//     edge (edge #C_RESET_MIN = 2,000,000), `expired` must pulse high for
//     exactly one cycle and then return to 0.  This verifies:
//       (a) Correct cycle count (no off-by-one).
//       (b) Strict one-cycle pulse behaviour (done_q saturation logic).
//       (c) No spurious re-fire after expiry (checked over 3 more edges).
//
//   Check 5 — Restart Reload (Timer)
//     After deasserting `running` (which freezes the counter), a fresh
//     `start` pulse is issued and `running` re-asserted.  The full
//     C_RESET_MIN cycle countdown must repeat from zero; `expired` must
//     pulse at exactly the right cycle again, confirming that `start`
//     correctly clears the counter and done_q flag.
//
// PASS CRITERIA
// ~~~~~~~~~~~~~
//   - All state_obs comparisons (seed and 20-step) must match the SW
//     reference model exactly.
//   - All data_out comparisons must match the expected 8-bit byte
//     assembled from the reference LFSR bit sequence.
//   - The timer `expired` signal must pulse high at exactly cycle
//     C_RESET_MIN and remain low at all other sampled points.
//   - The error counter must be zero at end-of-test for "TEST PASSED".
//
// CLOCK CONFIGURATION
// ~~~~~~~~~~~~~~~~~~~
//   lclk : 500 MHz (half-period = 1 ns).  Drives the scrambler DUT.
//          Generated by `always #1 lclk = ~lclk;`  (period = 2 ns).
//   tclk : 500 MHz (half-period = 1 ns).  Drives the ucie_timer DUT.
//          Generated by `always #1.0 tclk = ~tclk;` (period = 2 ns).
//   Both clocks are free-running and phase-independent.  The two DUTs
//   are on separate clock domains with no interaction.
//
// ASCII BLOCK DIAGRAM
// ~~~~~~~~~~~~~~~~~~~
//
//                         ut_lfsr Testbench
//   ================================================================
//
//    lclk (500 MHz)              tclk (500 MHz)
//        |                           |
//        v                           v
//   +------------------+       +-------------------+
//   |   scrambler      |       |   ucie_timer      |
//   |   (u_dut)        |       |   (u_timer)       |
//   |                  |       |                   |
//   |  LANE_ID = 3     |       | LIMIT_CYCLES =    |
//   |  G(x) = x^23 +  |       |   C_RESET_MIN     |
//   |    x^21 + x^16 + |       |   (2,000,000)     |
//   |    x^8 + x^5 +  |       |                   |
//   |    x^2 + 1       |       |                   |
//   |                  |       |                   |
//   | Inputs:          |       | Inputs:           |
//   |  lreset_n        |       |  reset_n          |
//   |  lfsr_reset      |       |  start            |
//   |  enable          |       |  running          |
//   |  data_in = 8'h00 |       |                   |
//   |                  |       | Output:           |
//   | Outputs:         |       |  expired          |
//   |  data_out[7:0]   |       |                   |
//   |  state_obs[22:0] |       |                   |
//   +------------------+       +-------------------+
//        |                           |
//        v                           v
//   +--------------------------------------------------+
//   |          Directed Check Stimulus                  |
//   |          (initial begin ... end)                  |
//   |                                                   |
//   |  Check 1: Seed reload      -> state_obs compare  |
//   |  Check 2: 20-step poly     -> state + data cmp   |
//   |  Check 3: Disabled hold    -> state frozen cmp   |
//   |  Check 4: Timer expiry     -> expired pulse cmp  |
//   |  Check 5: Restart reload   -> expired pulse cmp  |
//   +--------------------------------------------------+
//
// Spec ref: UCIe 1.0, Section 4.4.1 — Scrambling and training pattern
//           generation; Section 4.5.3.1 — RESET state timer.
//
// REVISION HISTORY
// ~~~~~~~~~~~~~~~~
//   Rev    Date        Description
//   -----  ----------  ------------------------------------------------------
//   0.0.1  2025-XX-XX  Initial creation.
//   0.0.2  2026-09-23  Documentation: expand header, add
//                      per-block comments.
//   0.0.3  2026-09-23  Documentation: correct lane-3 LFSR seed
//                      citations from Table 47 to Table 20 and
//                      use the real Section 4.5 title.
//   0.0.4  2026-10-09  Cleanup pass: remove unused table column and split multi-signal
//                      declarations into individual declarations.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_lfsr;
  logic        lclk;
  logic        lreset_n;
  logic [7:0]  data_out;
  logic [22:0] state_obs;
  logic        lfsr_reset;
  logic        enable;

  logic        tclk;
  logic        treset_n;
  logic        tstart;
  logic        trun;
  logic        texpired;
  int          errors;
  logic [22:0] ref_state;
  logic        ref_bit;

  logic        exp_data_bit;

  // -------------------------------------------------------------------------
  // DUT Instantiation: scrambler (per-lane LFSR)
  //
  // Instantiates the scrambler module with LANE_ID = 3, selecting the
  // per-lane seed lfsr_seed(3) = 23'h18C0DB from ucie_pkg (per UCIe 1.0
  // Table 20).  The scrambler implements the 23-bit Fibonacci LFSR with
  // polynomial G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1.
  //
  // Connections:
  //   - lclk / lreset_n : testbench-generated 500 MHz clock and reset.
  //   - lfsr_reset      : synchronous re-seed strobe driven by stimulus.
  //   - enable          : LFSR advance enable driven by stimulus.
  //   - data_in = 8'h00 : held at zero so data_out = raw LFSR output.
  //   - data_out[7:0]   : 8-bit scrambled output (one bit per UI).
  //   - state_obs[22:0] : direct observation of the internal LFSR register
  //                       for comparison against the SW reference model.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 — Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  scrambler #(.LANE_ID(3)) u_dut (
    .lclk      (lclk),
    .lreset_n  (lreset_n),
    .lfsr_reset(lfsr_reset),
    .enable    (enable),
    .data_in   (8'h00),
    .data_out  (data_out),
    .state_obs (state_obs)
  );

  initial lclk = 1'b0;
  // -------------------------------------------------------------------------
  // Clock Generator: lclk — 500 MHz Link Clock
  //
  // Generates a free-running square-wave clock with a 1 ns half-period
  // (2 ns full period = 500 MHz).  This matches the 500 MHz lclk domain
  // defined in UCIe 1.0 Section 5.1.1 for 4 GT/s mainband operation
  // (8 DDR UIs per lclk cycle).
  //
  // The clock drives the scrambler DUT (u_dut).  It is initialised to
  // 1'b0 in a separate initial block (line above) and toggled here.
  //
  // Spec ref: UCIe 1.0, Section 5.1.1 — Data rates.
  // -------------------------------------------------------------------------
  always #1 lclk = ~lclk;

  // -------------------------------------------------------------------------
  // DUT Instantiation: ucie_timer (RESET minimum interval)
  //
  // Instantiates the ucie_timer module with LIMIT_CYCLES = C_RESET_MIN
  // (= 2,000,000 clock cycles = 4 ms at 500 MHz).  This parameterisation
  // corresponds to the RESET minimum residency time mandated by UCIe 1.0
  // Section 4.5.3.1: the link must remain in RESET for at least 4 ms
  // before beginning sideband initialisation.
  //
  // The timer is a count-up counter that pulses `expired` for exactly
  // one cycle when the count reaches LIMIT_CYCLES − 1, then saturates
  // (no wrap, no re-fire).  A `start` pulse clears the counter and the
  // done flag, beginning a new interval.  Deasserting `running` freezes
  // the counter and clears `expired`.
  //
  // Connections:
  //   - clk / reset_n : testbench-generated 500 MHz tclk and treset_n.
  //   - start         : synchronous (re)start strobe driven by stimulus.
  //   - running       : hold high while the interval is active.
  //   - expired       : one-shot pulse output checked by stimulus.
  //
  // True to spec: C_RESET_MIN = 2,000,000 cycles (no prescaling).
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.1 — RESET state; Section 4.5 —
  //           Link Initialization and Training (sub-state residency timeout).
  // -------------------------------------------------------------------------
  ucie_timer #(.LIMIT_CYCLES(C_RESET_MIN)) u_timer (
    .clk     (tclk),
    .reset_n (treset_n),
    .start   (tstart),
    .running (trun),
    .expired (texpired)
  );

  initial tclk = 1'b0;
  // -------------------------------------------------------------------------
  // Clock Generator: tclk — 500 MHz Timer Clock
  //
  // Generates a free-running square-wave clock with a 1.0 ns half-period
  // (2 ns full period = 500 MHz).  This is phase-independent from lclk
  // and drives only the ucie_timer DUT (u_timer).
  //
  // The real-literal `#1.0` is used (instead of integer `#1`) to
  // demonstrate that the timescale precision (1 ps) can resolve
  // sub-nanosecond jitter if needed in future tests, although both
  // clocks currently have identical periods.
  //
  // Spec ref: UCIe 1.0, Section 5.1.1 — Data rates.
  // -------------------------------------------------------------------------
  always #1.0 tclk = ~tclk;

  // Reference: G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1.
  task step_ref;
    begin
      ref_bit   = ^(ref_state & LFSR_TAPS);
      ref_state = {ref_bit, ref_state[22:1]};
    end
  endtask

  initial begin
    errors     = 0;
    lfsr_reset = 1'b1;
    enable     = 1'b0;
    treset_n   = 1'b0;
    tstart     = 1'b0;
    trun       = 1'b0;
    lreset_n   = 1'b0;
    #2;
    lreset_n   = 1'b1;
    treset_n   = 1'b1;

    // 1. Seed reload yields the documented lane-3 seed.
    @(negedge lclk);
    lfsr_reset = 1'b0;
    @(posedge lclk); #0.1;
    if (state_obs !== ucie_pkg::lfsr_seed(3)) begin
      $display("FAIL ut_lfsr: seed mismatch, got %h exp %h",
               state_obs, ucie_pkg::lfsr_seed(3));
      errors = errors + 1;
    end

    // 2. Twenty steps match the reference polynomial. The DUT advances on the
    // edge, so the reference steps after it and is then compared.
    ref_state = state_obs;
    enable    = 1'b1;
    repeat (20) begin
      logic [7:0] exp_data_byte;
      for (int b = 0; b < 8; b = b + 1) begin
        exp_data_byte[b] = ref_state[0];
        step_ref;
      end
      @(posedge lclk);
      #0.1;
      if (state_obs !== ref_state) begin
        $display("FAIL ut_lfsr: state step mismatch, got %h exp %h",
                 state_obs, ref_state);
        errors = errors + 1;
      end
      if (data_out !== exp_data_byte) begin
        $display("FAIL ut_lfsr: data_out mismatch, got %b exp %b",
                 data_out, exp_data_byte);
        errors = errors + 1;
      end
    end

    // 3. Disabled: the state holds.
    enable = 1'b0;
    @(negedge lclk);
    ref_state = state_obs;
    repeat (5) @(posedge lclk);
    #0.1;
    if (state_obs !== ref_state) begin
      $display("FAIL ut_lfsr: state moved while disabled");
      errors = errors + 1;
    end

    // 4. Timer: 8 ticks of 4 edges. Expired must stay 0 through 31 edges and
    // pulse on the 32nd.
    @(negedge tclk);
    tstart = 1'b1;
    trun   = 1'b1;
    @(posedge tclk);                 // edge 0: start is sampled
    @(negedge tclk);
    tstart = 1'b0;                   // deassert between edges: no race
    repeat (C_RESET_MIN - 1) @(posedge tclk);
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: timer expired early");
      errors = errors + 1;
    end
    @(posedge tclk);                 // edge 2,000,000
    #0.1;
    if (texpired !== 1'b1) begin
      $display("FAIL ut_lfsr: timer did not expire at LIMIT_CYCLES");
      errors = errors + 1;
    end
    // 4b. Verify expired is a strict one-cycle pulse while running remains high
    @(posedge tclk);                 // edge 33
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: timer expired held high (not a one-cycle pulse)");
      errors = errors + 1;
    end
    repeat (3) @(posedge tclk);      // edges 34..36
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: timer expired re-fired while holding count");
      errors = errors + 1;
    end

    // 5. Not running holds the count; a restart reloads it.
    @(negedge tclk);
    trun   = 1'b0;
    repeat (4) @(posedge tclk);
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: expired held while not running");
      errors = errors + 1;
    end
    @(negedge tclk);
    tstart = 1'b1;
    @(posedge tclk);
    @(negedge tclk);
    tstart = 1'b0;
    trun   = 1'b1;
    repeat (C_RESET_MIN - 1) @(posedge tclk);
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: restart did not reload the count");
      errors = errors + 1;
    end
    @(posedge tclk);
    #0.1;
    if (texpired !== 1'b1) begin
      $display("FAIL ut_lfsr: restart did not expire on time");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_lfsr");
    else             $display("FAIL ut_lfsr: %0d errors", errors);
    $finish;
  end

  initial begin
    #40000000;
    $display("FAIL ut_lfsr: watchdog timeout");
    $finish;
  end

endmodule

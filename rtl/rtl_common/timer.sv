// ============================================================================
// File        : timer.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Generic spec-compliant interval timer for UCIe link training.
//
// This module provides a configurable countdown/count-up timer used
// throughout the UCIe link training state machine (LTSM) to enforce the
// timing intervals mandated by the UCIe 1.0 specification.  A single
// parameterisation serves all three timer roles:
//
//   1. Residency Timer (8 ms)
//      Spec 4.2 – General training state requirements: each training
//      sub-state must be occupied for a minimum of 8 ms before the LTSM
//      may advance.  The timer is parameterised with LIMIT_CYCLES =
//      C_RESIDENCY (= 8 000 000 lclk cycles at 1 GHz).
//
//   2. RESET Minimum Timer (4 ms)
//      Spec 4.2.2.1 – RESET state: the link must remain in RESET for at
//      least 4 ms after power-on or a link-reset request before beginning
//      sideband initialisation.  Parameterised with LIMIT_CYCLES =
//      C_RESET_MIN (= 4 000 000 lclk cycles).
//
//   3. Sideband Message Timeout (8 ms)
//      Spec 4.2.1 – If a sideband handshake does not complete within
//      8 ms, the LTSM transitions to TRAINERROR.  Parameterised with
//      LIMIT_CYCLES = C_SB_MSG (= 8 000 000 lclk cycles).
//
//   4. Stall Interval Timer (4 ms)
//      Spec 4.5.3 – A training state that has been actively running for
//      4 ms must initiate a stall sequence to prevent livelock.
//      Parameterised with LIMIT_CYCLES = C_STALL (= 4 000 000 lclk
//      cycles).
//
// Timer Behaviour
// ~~~~~~~~~~~~~~~
//   - `start` pulse : clears the counter and the expired flag, beginning
//                     a new interval.
//   - `running` held high : the counter advances on each tick (see DIV).
//   - `running` deasserted : the counter freezes and expired is cleared.
//                     This implements the spec 4.5.3 stall behaviour:
//                     "Stall resets the requester timer".  The counter
//                     is not cleared (start handles reloading), so the
//                     residual count is meaningless once running drops.
//   - `expired` output : asserted for exactly one clock cycle when the
//                     counter reaches LIMIT_CYCLES − 1.  The counter then
//                     saturates (does not wrap), so expired is a one-shot.
//
// DIV Parameter (Testbench Only)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   The DIV parameter allows unit tests to scale down the effective clock
//   rate so that timeout paths can be exercised without simulating millions
//   of cycles.  RTL instantiations always use the default DIV = 1 (every
//   clock edge is a tick).  The README explicitly forbids faster simulation
//   timers at the RTL source level; DIV is the approved testbench-only
//   escape hatch.
//
// Port Description
// ~~~~~~~~~~~~~~~~
//   clk      : Timer clock (typically lclk at 1 GHz for 4 GT/s operation).
//   reset_n  : Asynchronous active-low reset; clears counter and expired.
//   start    : Synchronous (re)start; clears counter and expired to begin
//              a new interval.
//   running  : Hold high while the interval is active; deassert to freeze.
//   expired  : One-shot pulse asserted in the cycle LIMIT_CYCLES elapses.
//
// Parameters
// ~~~~~~~~~~
//   LIMIT_CYCLES : Number of ticks until expiry (default: C_RESIDENCY).
//   DIV          : Clock divider for testbench acceleration (default: 1).
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2026-09-22  -           First commit to git.
//
// ============================================================================
`ifndef UcieTimer_SV
`define UcieTimer_SV
`include "ucie_pkg.sv"

module ucie_timer #(
  parameter int unsigned LIMIT_CYCLES = ucie_pkg::C_RESIDENCY,  // 8 ms
  parameter int unsigned DIV          = 1                      // testbench-only
) (
  input  logic   clk,
  input  logic   reset_n,
  input  logic   start,      // (re)start the interval
  input  logic   running,    // 1 while the interval is active
  output logic   expired     // 1 in the cycle LIMIT_CYCLES elapses
);

  import ucie_pkg::*;

  localparam int unsigned DIV_W = 32;

  logic [DIV_W-1:0] div_q;
  logic [DIV_W-1:0] cnt_q;
  logic             tick;

  // -----------------------------------------------------------------------
  // Clock Divider Register (always_ff)
  // -----------------------------------------------------------------------
  // When DIV = 1 (the default for all RTL instantiations), every positive
  // clock edge is a tick and this register remains at zero.  For DIV > 1
  // (testbench only), the divider counts from 0 to DIV − 1, generating
  // one tick every DIV clock cycles.
  //
  // The divider is cleared on:
  //   - Asynchronous reset (reset_n = 0).
  //   - Synchronous start pulse (re-aligns divider phase to start).
  //   - Tick event (wraps back to 0 after reaching DIV − 1).
  //
  // Spec reference: N/A (DIV is a testbench convenience, not spec-defined).
  // The spec timer intervals are enforced by LIMIT_CYCLES alone.
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n)        div_q <= {DIV_W{1'b0}};
    else if (start)      div_q <= {DIV_W{1'b0}};
    else if (tick)       div_q <= {DIV_W{1'b0}};
    else if (DIV > 1)    div_q <= div_q + 1'b1;
  end

  // -----------------------------------------------------------------------
  // Tick Generation (assign)
  // -----------------------------------------------------------------------
  // Produces a single-cycle tick pulse every DIV clock cycles.  When
  // DIV ≤ 1, tick is permanently asserted (every cycle is a tick).
  // When DIV > 1, tick fires when the divider counter reaches DIV − 1.
  // This tick gates the main expiry counter so that the effective
  // interval is LIMIT_CYCLES × DIV clock cycles.
  assign tick = (DIV <= 1) || (div_q == (DIV - 1));

  // -----------------------------------------------------------------------
  // Main Expiry Counter and Expired Flag (always_ff)
  // -----------------------------------------------------------------------
  // Core timer logic. Counts 0 -> LIMIT_CYCLES-1 on each tick, then
  // saturates (no wrap) and pulses `expired` for exactly one cycle.
  //
  //   reset_n=0 -> clear counter and expired (power-on state).
  //   start=1   -> clear both; begins a new interval. Asserted by the LTSM
  //                on entry to each training sub-state.
  //   running=0 -> expired cleared, counter HOLDS. Per spec 4.5.3 "Stall
  //                resets the requester timer": the LTSM re-asserts start
  //                on the next entry to reload explicitly.
  //   running & tick, cnt_q == LIMIT-1 -> saturate, assert expired.
  //   running & tick, otherwise        -> increment, clear expired.
  //   running & no tick (DIV>1 only)   -> expired cleared, counter holds.
  //
  // Saturating makes `expired` a clean one-shot that cannot re-fire.
  // ref: spec 4.5.3 (timer reset on stall).
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      cnt_q    <= {DIV_W{1'b0}};
      expired  <= 1'b0;
    end else if (start) begin
      cnt_q    <= {DIV_W{1'b0}};
      expired  <= 1'b0;
    end else if (!running) begin
      // Spec 4.5.3: Stall resets the requester timer. Holding the count while
      // the interval is inactive implements that without clearing the count,
      // because start reloads it explicitly on every entry.
      expired  <= 1'b0;
    end else if (tick) begin
      if (cnt_q == (LIMIT_CYCLES - 1)) begin
        cnt_q   <= cnt_q;           // saturate
        expired <= 1'b1;            // pulse in the cycle of expiry
      end else begin
        cnt_q   <= cnt_q + 1'b1;
        expired <= 1'b0;
      end
    end else begin
      expired <= 1'b0;
    end
  end

endmodule

`endif

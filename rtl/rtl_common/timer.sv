// ============================================================================
// File        : timer.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Generic spec-compliant interval timer for UCIe link training.
//
// This module provides a modular, configurable interval timer instantiated
// locally by individual FSMs (such as LTSM and adapter LSM) to enforce the
// timing intervals mandated by the UCIe 1.0 specification. Local instances
// parameterise LIMIT_CYCLES for their specific roles:
//
//   1. Residency Timer (8 ms)
//      Spec 4.5 – Sub-state residency timeout: if a training sub-state
//      handshake does not complete within 8 ms, the LTSM escalates to
//      TRAINERROR.  The timer is parameterised with LIMIT_CYCLES =
//      C_RESIDENCY (= 4 000 000 lclk cycles at 500 MHz).
//
//   2. RESET Minimum Timer (4 ms)
//      Spec 4.5.3.1 – RESET state: the link must remain in RESET for at
//      least 4 ms after power-on or a link-reset request before beginning
//      sideband initialisation.  Parameterised with LIMIT_CYCLES =
//      C_RESET_MIN (= 2 000 000 lclk cycles at 500 MHz).
//
//   3. Sideband Message Timeout (8 ms)
//      Spec 6.1 – Sideband requests expecting a response time out after
//      8 ms. Instantiated locally in adapter sideband logic as a response
//      watchdog. Parameterised with LIMIT_CYCLES = C_SB_MSG (= 4 000 000
//      cycles at 500 MHz).
//
//   4. Stall Interval Timer (4 ms)
//      Spec 6.1 – When stalling to prevent timeout, a stall response
//      cadence of 4 ms is specified. Instantiated locally as a stall
//      keep-alive timer. Parameterised with LIMIT_CYCLES = C_STALL
//      (= 2 000 000 cycles at 500 MHz).
// ~~~~~~~~~~~~~~~
//   - `start` pulse : clears the counter and the expired flag, beginning
//                     a new interval.
//   - `running` held high : the counter advances on each clock cycle.
//   - `running` deasserted : the counter freezes and expired is cleared.
//                     This implements the spec 4.5.3 stall behaviour:
//                     "Stall resets the requester timer".  The counter
//                     is not cleared (start handles reloading), so the
//                     residual count is meaningless once running drops.
//   - `expired` output : asserted for exactly one clock cycle when the
//                     counter reaches LIMIT_CYCLES − 1.  The counter then
//                     saturates (does not wrap), so expired is a one-shot.
//
// Timing Model (True-to-Spec Timing)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   Every clock edge is an active cycle.  Fast-testing dividers are
//   prohibited; all timer intervals strictly enforce their physical
//   cycle counts without prescaling.
//
// Port Description
// ~~~~~~~~~~~~~~~~
//   clk      : Timer clock (typically lclk at 500 MHz for 4 GT/s operation).
//   reset_n  : Asynchronous active-low reset; clears counter and expired.
//   start    : Synchronous (re)start; clears counter and expired to begin
//              a new interval.
//   running  : Hold high while the interval is active; deassert to freeze.
//   expired  : One-shot pulse asserted in the cycle LIMIT_CYCLES elapses.
//
// Parameters
// ~~~~~~~~~~
//   LIMIT_CYCLES : Number of clock cycles until expiry (default: C_RESIDENCY).
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2026-09-22  -           First commit to git.
//   0.0.2 2026-09-22  -           Remove DIV; enforce pure unprescaled true-to-spec cycle counts.
//
// ============================================================================
`ifndef UcieTimer_SV
`define UcieTimer_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module ucie_timer #(
  parameter int unsigned LIMIT_CYCLES = ucie_pkg::C_RESIDENCY  // 8 ms
) (
  input  logic   clk,
  input  logic   reset_n,
  input  logic   start,      // (re)start the interval
  input  logic   running,    // 1 while the interval is active
  output logic   expired     // 1 in the cycle LIMIT_CYCLES elapses
);

  import ucie_pkg::*;

  localparam int unsigned CNT_W = 32;

  logic [CNT_W-1:0] cnt_q;
  logic             done_q;

  // -----------------------------------------------------------------------
  // Main Expiry Counter and Expired Flag (always_ff)
  // -----------------------------------------------------------------------
  // Core timer logic. Counts 0 -> LIMIT_CYCLES-1 on each cycle while running,
  // then saturates (no wrap) and pulses `expired` for exactly one cycle.
  //
  //   reset_n=0 -> clear counter, done_q, and expired (power-on state).
  //   start=1   -> clear all; begins a new interval. Asserted on entry
  //                to each training sub-state.
  //   running=0 -> expired cleared, counter and done_q HOLD. Per spec
  //                4.5.3 "Stall resets the requester timer".
  //   running, cnt_q == LIMIT-1 & !done_q -> saturate, pulse expired.
  //   running, otherwise                  -> increment, clear expired.
  //
  // done_q ensures `expired` is a strict one-shot pulse that cannot re-fire.
  // ref: spec 4.5.3 (timer reset on stall).
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      cnt_q    <= {CNT_W{1'b0}};
      done_q   <= 1'b0;
      expired  <= 1'b0;
    end else if (start) begin
      cnt_q    <= {CNT_W{1'b0}};
      done_q   <= 1'b0;
      expired  <= 1'b0;
    end else if (!running) begin
      expired  <= 1'b0;
    end else if (!done_q && (cnt_q == (LIMIT_CYCLES - 1))) begin
      cnt_q   <= cnt_q;           // saturate counter
      done_q  <= 1'b1;            // mark done so pulse fires only once
      expired <= 1'b1;            // strict one-cycle pulse
    end else if (!done_q) begin
      cnt_q   <= cnt_q + 1'b1;
      expired <= 1'b0;
    end else begin
      expired <= 1'b0;            // hold saturated; pulse already fired
    end
  end
endmodule

`endif

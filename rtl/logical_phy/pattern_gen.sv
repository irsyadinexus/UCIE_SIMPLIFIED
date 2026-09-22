// ============================================================================
// File        : pattern_gen.sv
// Module      : pattern_gen
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Main-band training pattern generator. Produces per-lane
//               training patterns on all active lanes during the MBTRAIN
//               and LINKINIT sub-states. Each pattern is generated on every
//               lane, then scrambled with the per-lane LFSR where the spec
//               enables scrambling.
//
// Spec refs   : UCIe 1.0 spec section 4.5.3.4 (MBTRAIN sub-states),
//               section 4.5.3.6 (LINKINIT, Figure 71), Table 71 (training
//               pattern sequence).
//
// --------------------------------------------------------------------------
// Supported patterns  (Table 71 sequence)
// --------------------------------------------------------------------------
//
//   Pattern         Code   Scrambled?   Description
//   -------         ----   ----------   -----------
//   PAT_PERLANEID   3'd0   No           Lane number on its own lane. The UI
//                                       counter cycles through the lane
//                                       numbers; lane l carries a 1 only
//                                       during the UI that names it.
//                                       Used in most MBTRAIN sub-states.
//
//   PAT_VALTRAIN    3'd1   No           Alternating 1010... checkerboard,
//                                       unscrambled. Lane parity is XOR'd
//                                       with the lane index LSB so even
//                                       lanes toggle in anti-phase to odd
//                                       lanes.
//                                       Used in VALVREF, DATAVREF.
//
//   PAT_CLKREPAIR   3'd2   No           Single UI toggle every 4 UI. The
//                                       bit is 1 when ui[1:0] == 2'b01,
//                                       else 0. Same pattern on all lanes.
//                                       Used in RXDESKEW.
//
//   PAT_LFSR        3'd3   Yes          Per-lane LFSR bit per UI for
//                                       4096 UI (LFSR_PATTERN_UI). Each
//                                       lane has its own scrambler instance
//                                       seeded with lane_id mod 8.
//                                       Used in LINKINIT (4.5.3.6).
//
// --------------------------------------------------------------------------
// UI counter
// --------------------------------------------------------------------------
//   A 16-bit counter (ui_q) increments every lclk cycle while `enable` is
//   asserted. It resets to zero when enable is de-asserted or on hardware
//   reset. The counter value selects the per-lane data for each pattern.
//
// --------------------------------------------------------------------------
// Run length and pat_done
// --------------------------------------------------------------------------
//   The LFSR pattern has a fixed 4096-UI length; the LTSM consumes pat_done
//   to know when LINKINIT is complete. The other patterns run indefinitely
//   until the LTSM de-asserts enable or selects a different pattern, so
//   they never signal pat_done.
//
// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
//   NLANES : Number of main-band lanes (default NLANES_MAX = 16).
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   Inputs  : lclk, lreset_n, enable, pattern (pat_t), lfsr_reset,
//             lfsr_enable.
//   Outputs : data[NLANES-1:0] (one bit per lane, bit 0 = lane 0),
//             pat_done (asserted with the final UI of the LFSR pattern).
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. Every bit select is a continuous assign. Icarus Verilog 12 does not
//      evaluate constant part-selects inside an always_* process, so the
//      per-lane comparisons are generated instead of written in a for-loop.
//   2. The LANE_BITS localparam is clog2(NLANES), clamped to 1 when
//      NLANES <= 1, to avoid zero-width bit selects.
//   3. Each lane has its own scrambler instance (g_lane[i].u_scram) seeded
//      with lfsr_seed(i). Only the PAT_LFSR pattern routes the scrambler
//      output to the data bus.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Four-pattern generator with
//                        per-lane LFSR bank and 4096-UI run-length signal.
// ============================================================================
`ifndef PatternGen_SV
`define PatternGen_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module pattern_gen #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        enable,        // pattern engine active
  input  pat_t        pattern,       // selected pattern
  input  logic        lfsr_reset,    // reload the per-lane seed
  input  logic        lfsr_enable,   // scrambling enabled
  output logic [NLANES-1:0] data,    // one bit per lane, bit 0 = lane 0
  output logic        pat_done       // asserted with the final UI of a pattern
);

  localparam int unsigned LANE_BITS = (NLANES <= 1) ? 1 : $clog2(NLANES);

  logic [15:0] ui_q;        // UI counter within a pattern run

  // =========================================================================
  // UI counter  (spec 4.5.3.4 – training pattern timing)
  // =========================================================================
  // 16-bit free-running counter incremented every lclk cycle while the
  // pattern engine is enabled. Cleared on reset or when enable is
  // de-asserted. The counter value indexes the per-lane pattern output:
  //   - PAT_PERLANEID: ui_q[LANE_BITS-1:0] selects the "named" lane.
  //   - PAT_VALTRAIN : ui_q[0] provides the alternating toggle.
  //   - PAT_CLKREPAIR: ui_q[1:0] provides the 4-UI repeat period.
  //   - PAT_LFSR     : ui_q counts up to LFSR_PATTERN_UI-1 (4095).
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ui_q <= 16'h0000;
    end else if (!enable) begin
      ui_q <= 16'h0000;
    end else begin
      ui_q <= ui_q + 1'b1;
    end
  end

  // =========================================================================
  // Per-lane LFSR bank  (spec 4.4.1, 4.5.3.6 – per-lane scrambler)
  // =========================================================================
  // Each lane keeps its own LFSR instance seeded with lfsr_seed(lane_id).
  // The LFSR polynomial is G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
  // (spec 4.4.1). Only the PAT_LFSR pattern routes the scrambler output to
  // the data bus; for all other patterns the LFSR output is unused.
  //
  // lfsr_reset reloads the per-lane seed (asserted by the LTSM on LINKINIT
  // entry). lfsr_enable gates the LFSR shift (asserted only during LINKINIT).
  // =========================================================================
  logic [NLANES-1:0] lfsr_out_all;

  genvar i;
  generate
    for (i = 0; i < NLANES; i++) begin : g_lane
      scrambler #(.LANE_ID(i)) u_scram (
        .lclk        (lclk),
        .lreset_n    (lreset_n),
        .lfsr_reset  (lfsr_reset),
        .enable      (lfsr_enable),
        .data_in     (1'b0),
        .data_out    (lfsr_out_all[i]),
        .state_obs   ()
      );
    end
  endgenerate

  // =========================================================================
  // Pattern data generation  (spec 4.5.3.4 – per-lane pattern output)
  // =========================================================================
  // Continuous assigns only (no always_* for bit selects due to Icarus
  // Verilog 12 limitation). ui_q is widened to 16 bits so the lane-index
  // comparison uses a full-width constant per lane.
  //
  // Per-Lane-ID (PAT_PERLANEID, spec 4.5.3.4):
  //   Lane l carries 1 only during the UI where ui[LANE_BITS-1:0] == l.
  //   This identifies each lane to the receiver.
  //
  // VALTRAIN (PAT_VALTRAIN, spec 4.5.3.4 VALVREF/DATAVREF):
  //   Alternating 1010 checkerboard. Even lanes toggle in phase with ui[0];
  //   odd lanes toggle in anti-phase (XOR with lane index bit 0).
  //
  // CLKREPAIR (PAT_CLKREPAIR, spec 4.5.3.4 RXDESKEW):
  //   Single UI pulse every 4 UI. The bit is 1 when ui[1:0] == 2'b01.
  //   Same pattern on all lanes.
  //
  // LFSR (PAT_LFSR, spec 4.5.3.6 LINKINIT):
  //   Per-lane LFSR output. Each lane produces a unique pseudo-random
  //   sequence seeded by lfsr_seed(lane_id).
  //
  // When enable is de-asserted, all lanes output 0 (idle).
  // =========================================================================
  wire [15:0] ui = ui_q;

  wire clkrepair_bit = (ui[1:0] == 2'b01);
  wire valtrain_ui0  = ui[0];

  generate
    for (i = 0; i < NLANES; i++) begin : g_pat
      wire id_match  = (ui[LANE_BITS-1:0] == LANE_BITS'(i));
      wire lane_parity = valtrain_ui0 ^ i[0];

      assign data[i] = !enable ? 1'b0 :
                       (pattern == PAT_PERLANEID) ? id_match  :
                       (pattern == PAT_VALTRAIN)  ? lane_parity :
                       (pattern == PAT_CLKREPAIR) ? clkrepair_bit :
                       (pattern == PAT_LFSR)      ? lfsr_out_all[i] :
                                                    1'b0;
    end
  endgenerate

  // =========================================================================
  // Run length / pat_done  (spec 4.5.3.6 – LFSR pattern 4096 UI)
  // =========================================================================
  // The LFSR pattern has a fixed 4096-UI length (LFSR_PATTERN_UI from
  // ucie_pkg). pat_done is asserted on the final UI (ui_q == 4095) so the
  // LTSM can transition from LINKINIT to ACTIVE. The other patterns run
  // indefinitely until the LTSM reselects, so they never assert pat_done.
  // =========================================================================
  assign pat_done = enable && (pattern == PAT_LFSR) &&
                    (ui_q == LFSR_PATTERN_UI-1);

endmodule

`endif

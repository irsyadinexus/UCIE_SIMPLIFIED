// ============================================================================
// Module    : pattern_gen
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/logical_phy/pattern_gen.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.4.1 - Scrambling and training pattern
//       generation
//   UCIe 1.0 Specification, Section 4.5.3.4 - MBTRAIN (sub-states:
//       VALVREF, DATAVREF, SPEEDIDLE, RXCLKCAL, RXDESKEW, LINKSPEED)
//   UCIe 1.0 Specification, Section 4.5.3.5 - LINKINIT
//   UCIe 1.0 Specification, Section 5.1.1 - Data rates
//
// DESCRIPTION
//   Training-pattern generator for the UCIe logical PHY.  The engine
//   produces 128 bits of pattern data per 500 MHz lclk cycle — 8 true
//   physical UIs per lane across all 16 lanes — so the training patterns
//   run at the 4 GT/s physical mainband rate (spec Section 5.1.1:
//   8 DDR UIs per 500 MHz lclk cycle = 4 GT/s).
//
//   Four pattern types are supported, selected by the `pattern` input
//   (type pat_t, defined in ucie_pkg):
//
//     PAT_PERLANEID (3'd0) — Per-lane identification pattern.  Each lane
//         outputs 1 only on the UI whose index matches the lane number.
//         Used during MBTRAIN sub-states for lane mapping (spec 4.5.3.4).
//
//     PAT_VALTRAIN  (3'd1) — Valid-training toggle pattern.  Bit value is
//         current_ui[0] XOR lane[0], producing a 0/1 toggle on every UI
//         with alternating phase per lane pair.  Used during VALVREF
//         and DATAVREF sub-states of MBTRAIN (spec 4.5.3.4.1, 4.5.3.4.2).
//
//     PAT_CLKREPAIR (3'd2) — Clock-repair pulse.  Outputs 1 only when
//         current_ui[1:0] == 2'b01 (every fourth UI).  Used during
//         MBINIT.REPAIRCLK (spec 4.5.3.3.3).
//
//     PAT_LFSR      (3'd3) — LFSR scrambled pseudo-random data.  Each
//         lane instantiates an independent scrambler with unique seed.
//         Used during LINKINIT (spec 4.5.3.5) and LFSR-based MBTRAIN
//         exchanges.  The pat_done flag fires when the UI counter reaches
//         or crosses LFSR_PATTERN_UI (4096), marking the end of one
//         training exchange.
//
// INTERNAL BLOCK DIAGRAM
//
//   lclk 500 MHz
//     |
//     v
//   +================================================================+
//   |  pattern_gen                                                   |
//   |                                                                |
//   |  +-----------+                                                 |
//   |  | UI Counter|  ui_q[15:0]  (advances by +8 each lclk)        |
//   |  | always_ff |------+-----------------------------------+      |
//   |  +-----------+      |                                   |      |
//   |                     v                                   v      |
//   |  +--------------------------------------------------+          |
//   |  | 16 Per-Lane Scrambler Instances  (g_lane_scram)  |          |
//   |  |                                                  |          |
//   |  |  lane 0: scrambler #(.LANE_ID(0)) u_scram        |          |
//   |  |    data_in=8'h00, data_out -> lfsr_out_lane[0]   |          |
//   |  |  lane 1: scrambler #(.LANE_ID(1)) u_scram        |          |
//   |  |    ...                                           |          |
//   |  |  lane 15: scrambler #(.LANE_ID(15)) u_scram      |          |
//   |  |    data_in=8'h00, data_out -> lfsr_out_lane[15]  |          |
//   |  +---------------------+----------------------------+          |
//   |                        |                                       |
//   |                        v                                       |
//   |  +--------------------------------------------------+          |
//   |  | 8-UI-per-Lane Data Assembly  (g_pat_lane/g_pat_ui)          |
//   |  |                                                  |          |
//   |  |  For each lane (0..15) and each UI (0..7):       |          |
//   |  |    current_ui = ui_q + u                         |          |
//   |  |    data[8*lane + u] = mux(pattern,               |          |
//   |  |        PAT_PERLANEID -> id_match,                |          |
//   |  |        PAT_VALTRAIN  -> valtrain_bit,            |          |
//   |  |        PAT_CLKREPAIR -> clkrepair_bit,           |          |
//   |  |        PAT_LFSR      -> lfsr_out_lane[lane][u])  |          |
//   |  +---------------------+----------------------------+          |
//   |                        |                                       |
//   |                        v                                       |
//   |               data[127:0]  (output, 8 UIs x 16 lanes)         |
//   |                                                                |
//   |  pat_done = enable && (pattern==PAT_LFSR)                      |
//   |             && (ui_q >= LFSR_PATTERN_UI - 8)                   |
//   +================================================================+
//
// PARAMETERS
//   NLANES  — Number of mainband lanes (default NLANES_MAX = 16).
//
// CLOCK / RESET
//   lclk      — 500 MHz link clock.  All registered state (ui_q and the
//               scramblers) is clocked on posedge lclk.
//   lreset_n  — Active-low asynchronous reset.  Zeros the UI counter
//               and resets all scrambler LFSRs to their lane seeds.
//
// DESIGN NOTES
//   1. The UI counter (ui_q) counts physical UIs and advances by 8 every
//      lclk cycle.  When enable is deasserted the counter resets to zero
//      so the next training exchange begins from UI 0.
//   2. Scrambler instances receive data_in = 8'h00 because the training
//      LFSR pattern is the raw LFSR output (XOR with zero = identity).
//   3. The data output is purely combinational (assign statements inside
//      a generate block), so it settles within the same lclk cycle.
//   4. pat_done is asserted during the lclk cycle whose ui_q reaches or
//      crosses LFSR_PATTERN_UI (4096) minus 8, signalling the LTSM that
//      the current LFSR training exchange is complete.
//
// REVISION HISTORY
//   Rev    Date        Author      Description
//   -----  ----------  ----------  -------------------------------------------
//   0.0.1  2026-09-22  -           First commit. Single-UI-per-cycle pattern
//                                  engine.
//   0.0.2  2026-09-23  -           Req.2: emit 8 true UIs (128 bits) per lclk
//                                  cycle so the training patterns run at the
//                                  4 GT/s physical rate (8 DDR UIs per
//                                  500 MHz lclk cycle).
//   0.0.3  2026-09-23  -           Documentation: expand header to full spec-
//                                  referenced block with ASCII diagram, add
//                                  per-construct comment blocks.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
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
  input  logic        enable,
  input  pat_t        pattern,
  input  logic        lfsr_reset,
  input  logic        lfsr_enable,
  output logic [NLANES*8-1:0] data,   // 8 UIs per lane = 128-bit word
  output logic        pat_done
);

  localparam int unsigned LANE_BITS = (NLANES <= 1) ? 1 : $clog2(NLANES);

  logic [15:0] ui_q;  // Tracks physical UIs (advances by 8 each lclk)

  // -------------------------------------------------------------------------
  // always_ff: UI Counter — Physical Unit-Interval Tracker
  //
  // Counts the current physical UI position within a training exchange.
  // The counter advances by 8 every lclk cycle because the pattern
  // generator emits 8 true UIs per clock (one byte per lane), matching
  // the 4 GT/s mainband rate.  The counter resets to zero on hardware
  // reset or whenever enable is deasserted, ensuring each training
  // exchange restarts from UI 0.
  //
  // The LTSM uses ui_q (via pat_done) to determine when a full LFSR
  // training exchange of LFSR_PATTERN_UI (4096) UIs has been emitted.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation;  Section 4.5.3.4 - MBTRAIN.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ui_q <= 16'h0000;
    end else if (!enable) begin
      ui_q <= 16'h0000;
    end else begin
      ui_q <= ui_q + 16'd8;
    end
  end

  // 16 lanes x 8-bit LFSR outputs
  logic [7:0] lfsr_out_lane [0:NLANES-1];

  // -------------------------------------------------------------------------
  // Instantiation: Per-Lane Scrambler Array (16 instances)
  //
  // One scrambler instance per mainband lane.  Each is parameterised with
  // LANE_ID = l so it loads the correct per-lane LFSR seed from
  // lfsr_seed(l) in ucie_pkg.  The scramblers share lclk, lreset_n,
  // lfsr_reset and lfsr_enable.
  //
  // data_in is tied to 8'h00 because the training LFSR pattern IS the
  // raw LFSR output stream (XOR with zero = identity).  The 8-bit
  // data_out of each scrambler provides one byte of pseudo-random data
  // per lclk cycle (8 consecutive LFSR bits = 8 physical UIs).
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation;  Section 4.5.3.5 - LINKINIT.
  // -------------------------------------------------------------------------
  genvar l;
  generate
    for (l = 0; l < NLANES; l = l + 1) begin : g_lane_scram
      scrambler #(.LANE_ID(l)) u_scram (
        .lclk        (lclk),
        .lreset_n    (lreset_n),
        .lfsr_reset  (lfsr_reset),
        .enable      (lfsr_enable),
        .data_in     (8'h00),
        .data_out    (lfsr_out_lane[l]),
        .state_obs   ()
      );
    end
  endgenerate

  // -------------------------------------------------------------------------
  // assign (generate loop): 8-UI-per-Lane Data Assembly Mux
  //
  // For each lane (0..15) and each UI offset u (0..7) within the lclk
  // word, this combinational mux selects the appropriate pattern bit:
  //
  //   current_ui    = ui_q + u   (absolute UI index for this position)
  //   id_match      — 1 when current_ui[LANE_BITS-1:0] == lane
  //   valtrain_bit  — current_ui[0] XOR lane[0]  (alternating toggle)
  //   clkrepair_bit — 1 when current_ui[1:0] == 2'b01  (1-in-4 pulse)
  //
  // The output mapping follows spec Section 4.1.1 byte-to-lane mapping:
  //   data[8*lane + u]  carries UI u of lane `lane`.
  // This means lane L's byte occupies data[8*L +: 8], one bit per UI,
  // LSB-first, exactly as consumed by the TX gearbox serialiser.
  //
  // When enable is low every output bit is driven to zero.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation;  Section 4.5.3.4 - MBTRAIN.
  // -------------------------------------------------------------------------
  // Generate 8 true physical UIs per lane
  genvar lane, u;
  generate
    for (lane = 0; lane < NLANES; lane = lane + 1) begin : g_pat_lane
      for (u = 0; u < 8; u = u + 1) begin : g_pat_ui
        wire [15:0] current_ui = ui_q + u;
        wire id_match      = (current_ui[LANE_BITS-1:0] == LANE_BITS'(lane));
        wire valtrain_bit  = current_ui[0] ^ lane[0];
        wire clkrepair_bit = (current_ui[1:0] == 2'b01);

        assign data[8*lane + u] = !enable ? 1'b0 :
                                  (pattern == PAT_PERLANEID) ? id_match      :
                                  (pattern == PAT_VALTRAIN)  ? valtrain_bit  :
                                  (pattern == PAT_CLKREPAIR) ? clkrepair_bit :
                                  (pattern == PAT_LFSR)      ? lfsr_out_lane[lane][u] :
                                                               1'b0;
      end
    end
  endgenerate

  // -------------------------------------------------------------------------
  // assign: Pattern-Done Flag — LFSR Exchange Completion Indicator
  //
  // Asserted during the lclk cycle whose ui_q value reaches or crosses
  // LFSR_PATTERN_UI (4096) minus 8.  Because ui_q advances by 8 per
  // cycle, the comparison (ui_q >= 4096 - 8) fires exactly once at the
  // end of the exchange window.  The flag is qualified by enable and
  // pattern == PAT_LFSR so it is inactive during other pattern types.
  //
  // The LTSM samples pat_done to know when the full LFSR training
  // exchange has been transmitted, then transitions to the next sub-
  // state (e.g. LINKINIT -> next MBTRAIN sub-state).
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
  // -------------------------------------------------------------------------
  // pat_done fires during the lclk cycle that reaches or crosses 4096 UI
  assign pat_done = enable && (pattern == PAT_LFSR) &&
                    (ui_q >= (LFSR_PATTERN_UI - 16'd8));

endmodule

`endif

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
//     PAT_PERLANEID (3'd0) — Per-lane identification pattern. Each lane
//         emits the 16-UI word `0101`, lane ID LSB first, `0101`.
//
//     PAT_VALTRAIN  (3'd1) — Valid-training pattern. Every lane emits four
//         one UIs followed by four zero UIs.
//
//     PAT_CLKREPAIR (3'd2) — Clock-repair pattern. It emits 16 high UIs
//         followed by 8 low UIs.
//
//     PAT_LFSR      (3'd3) — LFSR scrambled pseudo-random data.  Each
//         lane instantiates an independent scrambler with unique seed.
//         Used during LINKINIT (spec 4.5.3.5) and LFSR-based MBTRAIN
//         exchanges.  The pat_done flag fires when the UI counter reaches
//         or crosses LFSR_PATTERN_UI (4096) as a diagnostic indicator of
//         pattern completion (LTSM Active Entry is governed by LinkMgmt.RDI).
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
//   |  |        PAT_PERLANEID -> perlaneid_bit,           |          |
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
//      crosses LFSR_PATTERN_UI (4096) minus 8, indicating diagnostic completion
//      of the LFSR pattern (LTSM Active Entry is governed by LinkMgmt.RDI).
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
//   0.0.4  2026-09-24  -           Phase A: correct VALTRAIN,
//                                  Per-Lane-ID, and clock-repair equations.
//   0.0.5  2026-09-24  -           Hoist the clock-repair modulo from the
//                                  lane/UI generate array and preserve the
//                                  16-high-then-8-low period.
//   0.0.6  2026-09-24  -           Clarify the Phase A LINKINIT diagnostic
//                                  ownership boundary with Phase C.
//   0.0.7  2026-10-08  -           Documentation compliance pass: add detailed
//                                  spec-referenced comment above generate bit multiplexer.
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

  logic [15:0] ui_q;  // Tracks physical UIs (advances by 8 each lclk)

  // -------------------------------------------------------------------------
  // assign: Clock-repair period phase
  //
  // Reduces the 16-bit physical UI counter to the 24-UI clock-repair period
  // once per output word. Each lane/UI instance adds its local offset and
  // wraps the result locally. This avoids identical modulo hardware in every
  // lane/UI output equation while preserving Table 21 timing.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.3.3 - MBINIT.REPAIRCLK.
  // -------------------------------------------------------------------------
  wire [4:0] ui_mod24 = ui_q % 16'd24;

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
      // ---------------------------------------------------------------------
      // Module instantiation: Per-Lane Training Pattern Scrambler
      //
      // One scrambler per lane. LANE_ID = l seeds the LFSR from that lane's
      // specification value, so the trained pattern sequence on each lane is
      // unique and never correlated with its neighbours.
      //
      // Spec ref: UCIe 1.0 Specification, Section 4.4.1 - Scrambling and
      //           training pattern generation.
      // ---------------------------------------------------------------------
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
  // For each lane and UI offset, the mux selects a Table 21 or Table 23
  // primitive. Per-Lane-ID repeats every 16 UIs. VALTRAIN repeats every
  // eight UIs. Clock repair repeats every 24 UIs. LFSR data remains the
  // per-lane Section 4.4.1 output.
  //
  // The output maps data[8*lane + u] to UI u for lane `lane`, LSB first.
  // When enable is low, every output bit is zero for the simplified
  // immediate-success MBINIT and MBTRAIN model.
  //
  // Spec ref: UCIe 1.0, Table 21, Table 23, Section 4.4.1.
  // -------------------------------------------------------------------------
  // Generate 8 true physical UIs per lane.
  genvar lane, u;
  generate
    for (lane = 0; lane < NLANES; lane = lane + 1) begin : g_pat_lane
      localparam logic [7:0] lane_id_vec = lane[7:0];
      for (u = 0; u < 8; u = u + 1) begin : g_pat_ui
        wire [15:0] current_ui   = ui_q + u;
        wire [3:0]  plid_pos     = current_ui[3:0];
        wire [4:0]  clk_phase    = ui_mod24 + u;
        wire [4:0]  clk_pos      = (clk_phase >= 5'd24) ?
                                    (clk_phase - 5'd24) : clk_phase;
        wire perlaneid_bit = ((plid_pos >= 4'd4) && (plid_pos <= 4'd11)) ?
                             lane_id_vec[plid_pos - 4'd4] : plid_pos[0];
        wire valtrain_bit  = (current_ui[2] == 1'b0);
        wire clkrepair_bit = (clk_pos < 5'd16);

        // ---------------------------------------------------------------------
        // assign: data[8*lane + u] - Training Pattern Bit Multiplexer
        //
        // Drives the UI slice for this lane based on selected pattern type:
        //   - PAT_PERLANEID: lane ID vector or 1010 preamble (Section 4.4.2).
        //   - PAT_VALTRAIN: 11110000 8-UI square wave (Section 4.4.3).
        //   - PAT_CLKREPAIR: 16 UI high, 8 UI low clock repair waveform.
        //   - PAT_LFSR: 4096-UI pseudo-random LFSR scrambler sequence.
        // Gated low when enable == 0.
        //
        // Spec ref: UCIe 1.0 Specification, Section 4.4 - Training Patterns.
        // ---------------------------------------------------------------------
        assign data[8*lane + u] = !enable ? 1'b0 :
                                  (pattern == PAT_PERLANEID) ? perlaneid_bit :
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
  // The existing LTSM uses pat_done to complete its LINKINIT diagnostic
  // interval. Phase C replaces that state-exit condition with the required
  // LinkMgmt.RDI Active exchange.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
  // -------------------------------------------------------------------------
  assign pat_done = enable && (pattern == PAT_LFSR) &&
                    (ui_q >= (LFSR_PATTERN_UI - 16'd8));

endmodule

`endif

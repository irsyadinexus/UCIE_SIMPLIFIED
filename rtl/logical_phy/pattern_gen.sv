// UCIe 1.0 Simplified Endpoint - main-band training pattern generator
// Spec 4.5.3.6 / Figure 71.
//
// Per the PoC scope this is a functional model of the transmit training
// patterns, not an analog calibration engine. Each pattern is generated on
// all active lanes, then scrambled with the per-lane LFSR where the spec
// enables scrambling.
//
// Patterns (Table 71 sequence)
//   PAT_PERLANEID : lane number on its own lane, unscrambled.
//   PAT_VALTRAIN  : alternating 1010... checkerboard, unscrambled.
//   PAT_CLKREPAIR : single UI toggle every 4 UI, unscrambled.
//   PAT_LFSR      : per-lane LFSR bit per UI for 4096 UI, scrambled.
//
// Note on style: every bit select is a continuous assign. Icarus Verilog 12
// does not evaluate constant part-selects inside an always_* process, so the
// per-lane comparisons are generated instead of written in a for-loop.
`ifndef PatternGen_SV
`define PatternGen_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

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

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ui_q <= '0;
    end else if (!enable) begin
      ui_q <= '0;
    end else begin
      ui_q <= ui_q + 1'b1;
    end
  end

  // ------------------------------------------------- per-lane LFSR bank
  // Each lane keeps its own LFSR; only the selected pattern reaches data.
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

  // -------------------------------------------------------- pattern data
  // Continuous selects only. ui_q is widened so the lane index compares
  // against a full-width constant per lane.
  wire [15:0] ui = ui_q;

  // Per-Lane-ID: the UI counter cycles through the lane numbers, so lane l
  // carries a 1 only during the UI that names it.
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

  // ------------------------------------------------------- run length
  // The LFSR pattern has a fixed 4096-UI length; the LTSM consumes pat_done.
  // The other patterns run until the LTSM reselects, so they never signal.
  assign pat_done = enable && (pattern == PAT_LFSR) &&
                    (ui_q == LFSR_PATTERN_UI-1);

endmodule

`endif

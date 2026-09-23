// ============================================================================
// File        : pattern_gen.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Training pattern generator producing 8 UIs (128 bits) per
//               500 MHz lclk cycle for true 4 GT/s physical mainband transfer.
//
// Spec References:
//   4.5.3.4 (MBTRAIN sub-states), 4.5.3.6 (LINKINIT), 4.4.1 (scrambling).

// Revision History:
//   v0.0.1 2026-09-22  First commit. Single-UI-per-cycle pattern engine.
//   v0.0.2 2026-09-23  Req.2: emit 8 true UIs (128 bits) per lclk cycle so
//                      the training patterns run at the 4 GT/s physical
//                      rate (8 DDR UIs per 500 MHz lclk cycle).
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

  // pat_done fires during the lclk cycle that reaches or crosses 4096 UI
  assign pat_done = enable && (pattern == PAT_LFSR) &&
                    (ui_q >= (LFSR_PATTERN_UI - 16'd8));

endmodule

`endif

// ============================================================================
// File        : scrambler.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Multi-rate 8-UI per-lane LFSR scrambler / descrambler.
//
// Generates 8 consecutive pseudo-random bits per lclk cycle per lane to
// match the 4 GT/s physical mainband rate (8 DDR UIs per 500 MHz lclk cycle).
//
// Revision History:
//   v0.0.1 2026-09-22  First commit. Single-bit-per-cycle LFSR scrambler.
//   v0.0.2 2026-09-23  Req.2: 8-deep combinational LFSR step chain so each
//                      500 MHz lclk cycle advances the register by 8 bits,
//                      matching the 4 GT/s physical UI rate (spec 4.4.1).
// ============================================================================
`ifndef Scrambler_SV
`define Scrambler_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module scrambler #(
  parameter int unsigned LANE_ID = 0
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        lfsr_reset,
  input  logic        enable,
  input  logic [7:0]  data_in,      // 8 raw transmit bits (one per UI)
  output logic [7:0]  data_out,     // 8 scrambled bits (one per UI)
  output logic [22:0] state_obs
);

  import ucie_pkg::*;

  logic [LFSR_W-1:0] lfsr_q;
  logic [LFSR_W-1:0] lfsr_step [0:8];
  logic [7:0]        out_comb;

  // Compute 8 steps of Fibonacci recurrence combinational chain
  assign lfsr_step[0] = lfsr_q;
  genvar u;
  generate
    for (u = 0; u < 8; u = u + 1) begin : g_step
      wire fb = ^(lfsr_step[u] & LFSR_TAPS);
      assign lfsr_step[u+1] = {fb, lfsr_step[u][LFSR_W-1:1]};
      assign out_comb[u]    = data_in[u] ^ lfsr_step[u][0];
    end
  endgenerate

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      lfsr_q   <= lfsr_seed(LANE_ID);
      data_out <= 8'h00;
    end else if (lfsr_reset) begin
      lfsr_q   <= lfsr_seed(LANE_ID);
      data_out <= 8'h00;
    end else if (enable) begin
      lfsr_q   <= lfsr_step[8];
      data_out <= out_comb;
    end else begin
      data_out <= 8'h00;
    end
  end

  assign state_obs = lfsr_q;

endmodule

`endif

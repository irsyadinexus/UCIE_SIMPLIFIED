// UCIe 1.0 Simplified Endpoint - per-lane LFSR scrambler
// Spec 4.4.1: G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
// Per-lane seed = lane number mod 8. LFSR is reset on entry to LINKINIT.
`ifndef Scrambler_SV
`define Scrambler_SV
`include "ucie_pkg.sv"

module scrambler #(
  parameter int unsigned LANE_ID = 0
) (
  input  logic        lclk,
  input  logic        lreset_n,       // async, active low
  input  logic        lfsr_reset,     // spec: reset on entry to LINKINIT
  input  logic        enable,         // 0 for Per-Lane-ID / VALTRAIN / clock repair
  input  logic        data_in,        // raw transmit bit
  output logic        data_out,       // scrambled bit
  output logic [22:0] state_obs       // observable for coverage monitors
);

  import ucie_pkg::*;

  logic [LFSR_W-1:0] lfsr_q, lfsr_d;
  logic              data_scrambled_q;

  // Seed is loaded on power reset; the LFSR value is reloaded on LINKINIT entry.
  // LFSR reset has no effect in MBINIT.REPAIRMB and MBTRAIN.VALVREF because those
  // states do not assert lfsr_reset.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      lfsr_q <= lfsr_seed(LANE_ID);
    end else if (lfsr_reset) begin
      lfsr_q <= lfsr_seed(LANE_ID);
    end else if (enable) begin
      lfsr_q <= lfsr_d;
    end
  end

  // Fibonacci LFSR shifting right: feedback into bit 22, the rest shift down.
  // Expressed as a continuous assign because iverilog 12 cannot evaluate a
  // variable index inside an always_* process.
  wire fb = ^(lfsr_q & LFSR_TAPS);

  assign lfsr_d       = {fb, lfsr_q[LFSR_W-1:1]};
  assign data_scrambled_q = data_in ^ lfsr_q[0];

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      data_out <= 1'b0;
    end else begin
      data_out <= enable ? data_scrambled_q : data_in;
    end
  end

  assign state_obs = lfsr_q;

endmodule

`endif

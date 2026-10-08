// ============================================================================
// Module    : scrambler
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/rtl_common/scrambler.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.4.1 - Scrambling and training pattern
//       generation
//   UCIe 1.0 Specification, Section 5.1.1 - Data rates
//
// DESCRIPTION
//   Per-lane 23-bit Fibonacci LFSR scrambler / descrambler for UCIe mainband
//   data.  The module operates in the 500 MHz lclk domain and produces 8
//   scrambled output bits per clock cycle — one per Unit Interval (UI) — to
//   match the 4 GT/s physical mainband rate (8 DDR UIs per 500 MHz lclk
//   cycle, as defined by spec Section 5.1.1).
//
//   The LFSR implements the polynomial defined in Section 4.4.1:
//
//       G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
//
//   This polynomial is encoded in the tap mask constant LFSR_TAPS
//   (23'h210125), which is imported from ucie_pkg.  The mask selects
//   register bits {21, 16, 8, 5, 2, 0} for XOR-reduction feedback.  The
//   x^23 term is implicit in the one-bit right-shift and is NOT included in
//   the tap mask.  LFSR_TAPS is spec-correct and must not be changed.
//
//   Each lane is seeded with a unique initial value from the lfsr_seed()
//   function (also in ucie_pkg) based on the LANE_ID parameter.  Seeds are
//   per spec Section 4.4.1 so that adjacent lanes never produce correlated
//   sequences.
//
// INTERNAL BLOCK DIAGRAM
//
//   An 8-deep combinational step chain unfolds eight consecutive Fibonacci
//   LFSR iterations within a single combinational cone so that all 8 output
//   bits are available before the next lclk rising edge:
//
//     lfsr_q (23 bits, registered)
//       |
//       v
//   +-----------+   +-----------+         +-----------+   +-----------+
//   | step[0]   |-->| step[1]   |-->...-->| step[7]   |-->| step[8]   |
//   | fb=^taps  |   | fb=^taps  |         | fb=^taps  |   | (next_q)  |
//   | out[0]=   |   | out[1]=   |         | out[7]=   |   |           |
//   | din[0]^[0]|   | din[1]^[0]|         | din[7]^[0]|   |           |
//   +-----------+   +-----------+         +-----------+   +-----------+
//       step[0] = lfsr_q                (identity, no logic)
//       step[u+1] = {fb, step[u][22:1]} (right-shift, fb into MSB)
//       out[u]    = data_in[u] ^ step[u][0]
//
//   On enable the registered state advances to step[8] at the next posedge
//   lclk, covering 8 UIs in one cycle.  When the scrambler is disabled the
//   LFSR holds its state and the output is driven to zero.
//
// PARAMETERS
//   LANE_ID  — Physical lane index (0..15).  Selects the per-lane LFSR
//              seed via the lfsr_seed() function in ucie_pkg.
//
// CLOCK / RESET
//   lclk      — 500 MHz link clock.  All flops trigger on posedge lclk.
//   lreset_n  — Active-low asynchronous reset.  Reloads the LFSR seed and
//               zeros data_out.
//
// DESIGN NOTES
//   1. The combinational depth is 8 XOR-reductions of a 23-bit vector.
//      At 500 MHz (2 ns period) this is comfortable even in FPGA fabrics.
//   2. lfsr_reset is a synchronous re-seed strobe, used at the start of
//      each training exchange to reinitialise the LFSR to the lane seed.
//   3. When enable is deasserted the LFSR state is frozen (not reset), so
//      re-enabling continues from the same state.  data_out is zeroed.
//   4. data_in XOR with the LFSR output stream means the same module can
//      act as either scrambler (TX) or descrambler (RX) — the operation
//      is its own inverse.
//
// REVISION HISTORY
//   Rev    Date        Author      Description
//   -----  ----------  ----------  -------------------------------------------
//   0.0.1  2026-09-22  -           First commit. Single-bit-per-cycle LFSR
//                                  scrambler.
//   0.0.2  2026-09-23  -           Req.2: 8-deep combinational LFSR step
//                                  chain so each 500 MHz lclk cycle advances
//                                  the register by 8 bits, matching the
//                                  4 GT/s physical UI rate (spec 4.4.1).
//   0.0.3  2026-09-23  -           Documentation: expand header to full spec-
//                                  referenced block, add per-construct comment
//                                  blocks with spec citations.
//   0.0.4  2026-09-23  -           Documentation: the lane seeding reference
//                                  cited Table 47, which is the sideband
//                                  opcode table. Re-cite to Section 4.4.1
//                                  (Scrambling and training pattern
//                                  generation).
//   0.0.5  2026-10-08  -           Documentation compliance pass: add detailed
//                                  per-step feedback and XOR scramble comments.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
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

  // -------------------------------------------------------------------------
  // assign: LFSR Step Chain Root — Identity Assignment
  //
  // Seeds the combinational step chain with the current registered LFSR
  // state.  lfsr_step[0] is a wire alias for lfsr_q so that the generate
  // loop below can treat all 8 iterations uniformly (step u reads
  // step[u], produces step[u+1]).  No logic gates are inferred here.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  // Compute 8 steps of Fibonacci recurrence combinational chain
  assign lfsr_step[0] = lfsr_q;

  // -------------------------------------------------------------------------
  // assign (generate loop): 8-Deep Fibonacci LFSR Unrolled Steps
  //
  // Each iteration u (0..7) computes one Fibonacci LFSR step:
  //   1. fb = XOR-reduction of (step[u] & LFSR_TAPS), implementing the
  //      feedback polynomial G(x) = x^23 + x^21 + x^16 + x^8 + x^5 +
  //      x^2 + 1.  LFSR_TAPS = 23'h210125 selects register bits
  //      {21, 16, 8, 5, 2, 0}; x^23 is implicit in the shift.
  //   2. step[u+1] = {fb, step[u][22:1]}  — right-shift with feedback
  //      inserted at the MSB, standard Fibonacci topology.
  //   3. out_comb[u] = data_in[u] ^ step[u][0]  — XOR the input bit
  //      with the LFSR output (bit 0), so the same module serves as
  //      both scrambler and descrambler.
  //
  // The 8 steps are purely combinational; the final state step[8] is
  // captured by the always_ff block below on the next posedge lclk.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  genvar u;
  generate
    for (u = 0; u < 8; u = u + 1) begin : g_step
      wire fb = ^(lfsr_step[u] & LFSR_TAPS);

      // ---------------------------------------------------------------------
      // assign: lfsr_step[u+1] - Fibonacci LFSR Next State Step
      //
      // Shifts the 23-bit LFSR right by 1 bit and inserts the feedback bit
      // fb = ^(lfsr_step[u] & LFSR_TAPS) into the MSB per Section 4.4.1.
      //
      // Spec ref: UCIe 1.0 Specification, Section 4.4.1 - Scrambling Polynomial.
      // ---------------------------------------------------------------------
      assign lfsr_step[u+1] = {fb, lfsr_step[u][LFSR_W-1:1]};

      // ---------------------------------------------------------------------
      // assign: out_comb[u] - XOR Scramble/Descramble Bit
      //
      // XORs the input data bit with the current LFSR output bit (bit 0).
      // Self-inverting topology serves symmetrically as scrambler and descrambler.
      //
      // Spec ref: UCIe 1.0 Specification, Section 4.4.1 - Scrambler Operation.
      // ---------------------------------------------------------------------
      assign out_comb[u]    = data_in[u] ^ lfsr_step[u][0];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // always_ff: LFSR State Register and Output Register
  //
  // On every posedge lclk this block captures the next LFSR state
  // (lfsr_step[8]) and the 8-bit scrambled output vector (out_comb).
  //
  // Reset / re-seed behaviour:
  //   - Asynchronous lreset_n : reloads the per-lane seed from
  //     lfsr_seed(LANE_ID) and zeros data_out.
  //   - Synchronous lfsr_reset: same effect, used at the start of each
  //     training exchange to reinitialise the LFSR deterministically.
  //   - enable = 0 : LFSR state is FROZEN (not reset), data_out zeroed.
  //   - enable = 1 : advance LFSR by 8 UIs, output scrambled data.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // assign: LFSR State Observation Port
  //
  // Exposes the current registered LFSR state for debug, BIST, and
  // testbench comparison.  This is a direct wire alias to lfsr_q with
  // no additional logic.  The observability port is not part of the
  // normal data path and may be left unconnected in production.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  assign state_obs = lfsr_q;

endmodule

`endif

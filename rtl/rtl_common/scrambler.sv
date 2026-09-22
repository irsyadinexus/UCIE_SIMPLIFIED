// ============================================================================
// File        : scrambler.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Per-lane Fibonacci LFSR scrambler / descrambler.
//
// Implements the data scrambling function defined in UCIe 1.0 specification,
// section 4.4.1.  A single instance serves one data lane; the parent
// module instantiates one scrambler per active lane (up to NLANES_MAX = 16).
//
// Specification Reference
// ~~~~~~~~~~~~~~~~~~~~~~~
// UCIe 1.0, section 4.4.1 – "Data Scrambling"
//
//   - Polynomial   : G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
//   - Seed         : Lane-specific, repeating every 8 lanes (see lfsr_seed
//                    in ucie_pkg.sv).
//   - LFSR Reset   : The LFSR is re-seeded on entry to LINKINIT (and on
//                    power-on asynchronous reset).
//   - Scrambling   : Transmit data bit is XOR'd with LFSR output (bit 0).
//   - Bypass       : Scrambling is disabled (bypassed) during Per-Lane-ID,
//                    VALTRAIN, and Clock Repair pattern transmission.
//
// LFSR Architecture
// ~~~~~~~~~~~~~~~~~
// The LFSR is a 23-bit right-shifting Fibonacci configuration:
//
//   - The feedback bit (fb) is computed as the XOR-reduction of the
//     current register value AND'd with the tap mask (LFSR_TAPS).
//   - The feedback is inserted into the MSB position (bit 22).
//   - The output is taken from the LSB position (bit 0).
//   - On each enabled clock edge, the register shifts right by one bit.
//
// ASCII Diagram of the LFSR Shift Chain
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The LFSR is drawn with bit 22 (MSB, feedback entry) on the left and
// bit 0 (LSB, output) on the right.  Tap positions are marked with (T).
//
//   fb ─┐
//       ▼
//   ┌──────┬──────┬─────────────┬──────┬──────────────────┬──────┬──────
//   │ b[22]│ b[21]│ b[20]..b[17]│ b[16]│ b[15]..b[9]      │ b[8] │ b[7]
//   │      │  (T) │             │  (T) │                   │  (T) │
//   └──┬───┴──┬───┴─────────────┴──┬───┴───────────────────┴──┬───┴──────
//       │      │                    │                          │
//       │      └────── XOR ◄────────┘                          │
//       │               │                                      │
//       │               └────────────── XOR ◄──────────────────┘
//       │                                │
//   ────┴────────────────────────────────┘
//
//   ──────┬──────┬──────────────┬──────┬──────┐
//    b[6] │ b[5] │ b[4]..b[3]  │ b[2] │ b[1] │ b[0]  ──► output
//         │  (T) │             │  (T) │       │  (T)       (data_in XOR)
//   ──────┴──┬───┴─────────────┴──┬───┴──────┴──┬──┘
//            │                    │              │
//            └────── XOR ◄────────┘              │
//                     │                          │
//                     └──────────── XOR ◄────────┘
//                                    │
//                                    └────────────────── = fb
//
// Tap positions (T) within the 23-bit register: {21, 16, 8, 5, 2, 0}
//
// The tap mask is therefore: LFSR_TAPS = 23'h210125
//   bit 21 = 0x200000,  bit 16 = 0x010000,  bit 8 = 0x000100,
//   bit  5 = 0x000020,  bit  2 = 0x000004,  bit 0 = 0x000001
//
//   fb = lfsr_q[21] ^ lfsr_q[16] ^ lfsr_q[8] ^ lfsr_q[5]
//        ^ lfsr_q[2] ^ lfsr_q[0]
//      = ^(lfsr_q & 23'h210125)
//
// The x^23 term of the polynomial is the shift itself and is NOT
// represented in the tap mask (see ucie_pkg.sv header for full derivation).
//
// Port Description
// ~~~~~~~~~~~~~~~~
//   lclk        : Main-band link clock (500 MHz at 4 GT/s).
//   lreset_n    : Asynchronous active-low reset; re-seeds the LFSR and
//                 clears the output register.
//   lfsr_reset  : Synchronous re-seed on LINKINIT entry (spec 4.4.1).
//   enable      : When high, the LFSR advances and scrambled data is
//                 output.  When low (Per-Lane-ID, VALTRAIN, clock repair),
//                 the LFSR is frozen and data passes through unmodified.
//   data_in     : Raw transmit bit (pre-scrambling).
//   data_out    : Scrambled transmit bit (post-scrambling) when enable=1;
//                 passthrough of data_in when enable=0.
//   state_obs   : Full LFSR register value for coverage monitors and
//                 debug observability.
//
// Parameters
// ~~~~~~~~~~
//   LANE_ID     : Lane number (0..NLANES_MAX-1).  Used to select the
//                 per-lane seed via lfsr_seed(LANE_ID) from ucie_pkg.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2026-09-22  -           First commit to git.
//   0.0.2 2026-09-22  -           Update lclk documentation to 500 MHz.
//
// ============================================================================
`ifndef Scrambler_SV
`define Scrambler_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
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

  // -----------------------------------------------------------------------
  // LFSR State Register (always_ff)
  // -----------------------------------------------------------------------
  // UCIe 1.0 spec 4.4.1: The LFSR is seeded with a lane-specific value on
  // power-on reset (asynchronous) and re-seeded synchronously on entry to
  // the LINKINIT state.  When scrambling is enabled (`enable` = 1), the
  // register advances by one bit per lclk cycle.  When `enable` = 0 (i.e.,
  // during Per-Lane-ID, VALTRAIN, or Clock Repair pattern transmission),
  // the register holds its current value, preserving LFSR continuity for
  // the next LFSR-pattern phase.
  //
  // Note: lfsr_reset is NOT asserted during MBINIT.REPAIRMB or
  // MBTRAIN.VALVREF, so the LFSR value from prior phases is preserved
  // through those states, matching spec intent.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      lfsr_q <= lfsr_seed(LANE_ID);
    end else if (lfsr_reset) begin
      lfsr_q <= lfsr_seed(LANE_ID);
    end else if (enable) begin
      lfsr_q <= lfsr_d;
    end
  end

  // -----------------------------------------------------------------------
  // Feedback Computation (combinational wire)
  // -----------------------------------------------------------------------
  // UCIe 1.0 spec 4.4.1: The feedback bit is the XOR-reduction of the
  // LFSR register ANDed with the tap mask.  This computes:
  //     fb = lfsr_q[21] ^ lfsr_q[16] ^ lfsr_q[8]
  //          ^ lfsr_q[5] ^ lfsr_q[2] ^ lfsr_q[0]
  //
  // Expressed as a continuous-assign wire (not an always block) because
  // Icarus Verilog 12 cannot evaluate a variable index inside an always_*
  // process when the XOR-reduction operator is used with a parameterised
  // mask.  The semantics are identical to an always_comb assignment.
  wire fb = ^(lfsr_q & LFSR_TAPS);

  // -----------------------------------------------------------------------
  // Next-State and Scrambled-Data Assignments
  // -----------------------------------------------------------------------
  // lfsr_d: Right-shift the register by one bit, inserting the feedback
  //         bit (fb) into the MSB (bit 22).  This implements the Fibonacci
  //         LFSR recurrence:  lfsr_d = {fb, lfsr_q[22:1]}.
  //         (UCIe 1.0 spec 4.4.1, shift-right convention.)
  assign lfsr_d       = {fb, lfsr_q[LFSR_W-1:1]};

  // data_scrambled_q: core scrambling operation - the raw data bit XORed
  // with the LFSR output bit (bit 0).
  //
  // The identical XOR serves as both scrambler on TX and descrambler on RX,
  // because XOR is self-inverse: applying it twice returns the original
  // bit. One instance therefore covers both directions of a lane.
  // ref: spec 4.4.1 (data scrambling).
  assign data_scrambled_q = data_in ^ lfsr_q[0];

  // -----------------------------------------------------------------------
  // Output Register (always_ff)
  // -----------------------------------------------------------------------
  // UCIe 1.0 spec 4.4.1: The scrambled output is registered on the
  // positive edge of lclk before being driven to the serialiser.
  // On asynchronous reset, the output is cleared to 0.
  //
  // When `enable` = 1, the scrambled data (data_in XOR lfsr_q[0]) is
  // captured.  When `enable` = 0 (pattern modes that bypass scrambling),
  // the raw data_in passes through unmodified, ensuring that Per-Lane-ID,
  // VALTRAIN, and Clock Repair patterns are transmitted without scrambling.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      data_out <= 1'b0;
    end else begin
      data_out <= enable ? data_scrambled_q : data_in;
    end
  end

  // -----------------------------------------------------------------------
  // Debug Observability Assignment
  // -----------------------------------------------------------------------
  // Expose the full 23-bit LFSR register state for coverage monitors,
  // assertion checkers, and waveform debug.  This is a zero-cost wire
  // alias with no logic implications.
  assign state_obs = lfsr_q;

endmodule

`endif

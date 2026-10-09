// ============================================================================
// File        : byte_lane_mapper.sv
// Module      : byte_lane_mapper
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Byte-to-lane mapping block. Translates NBYTES parallel bytes
//               into NLANES lane-aligned bytes, handling both x16 full-width
//               and x8-degraded half-width modes. In degraded mode only the
//               surviving half (lanes 0-7 or lanes 8-15) carries data; the
//               inactive half is forced to zero so the partner observes a
//               clean, deterministic pattern.
//
// Spec refs   : UCIe 1.0 spec section 4.1.1 (Byte to Lane Mapping, lane and
//               width definitions), Figure 42 (Byte map for x16 interface),
//               Figure 43 (Byte to Lane mapping for Standard package x8
//               degraded), section 4.3.7 (Width Degrade in Standard Package
//               Interfaces).
//
// --------------------------------------------------------------------------
// Mapping table  (spec 4.1.1 / Figures 42-43)
// --------------------------------------------------------------------------
//
//   Mode            Lane l source          Active lanes
//   ----            ----------------       ------------
//   x16             byte l                 All 16 lanes
//   x8, lanes 0-7   byte l  (l < 8)        Lanes 0-7 only; lanes 8-15 = 0
//   x8, lanes 8-15  byte (l-8)  (l >= 8)   Lanes 8-15 only; lanes 0-7 = 0
//
//   With byte_reversal set, x16 sources byte NBYTES-1-l. In x8 mode, actual reversed
//   x8 selection uses bytes_in[NBYTES-1-index], which with NBYTES=16 selects bytes 15..8
//   in reverse order for either surviving lane half.
//   The table is symmetric, so the transmit and receive directions share
//   one mapper block.
//
// --------------------------------------------------------------------------
// Width-degrade mechanism  (spec 4.1.1)
// --------------------------------------------------------------------------
//   The LTSM negotiates the link width during MBTRAIN.REPAIR. If a repair
//   attempt fails, the link may degrade from x16 to x8. The degrade_lanes
//   field (2 bits) selects which half survives:
//     DEGRADE_LANES_0_7  (2'b01) : Lanes 0-7 carry data.
//     DEGRADE_LANES_8_15 (2'b10) : Lanes 8-15 carry data.
//   The inactive half is zeroed, preventing stale or random data from
//   reaching the partner.
//
// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
//   NLANES : Number of main-band lanes (default NLANES_MAX = 16).
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   Inputs  : lclk, lreset_n (unused in combinational path, kept for
//             consistency), enable, lnk_is_x8, degrade_lanes[1:0],
//             byte_reversal, bytes_in[NBYTES-1:0][7:0].
//   Outputs : data_out[NLANES-1:0][7:0].
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. Every bit select is a continuous assign because Icarus Verilog 12
//      does not evaluate a variable index inside an always_* process.
//   2. The x8/x16 choice is a runtime mux (not a generate branch) so the
//      mapper can respond to the negotiated link width after elaboration.
//   3. The generate loop splits at NLANES_X8 (= 8): the lower half
//      (g_lower) handles lanes 0..7, the upper half (g_upper) handles
//      lanes 8..15.
//   4. When enable is de-asserted, all lanes output zero regardless of
//      mode or byte_reversal.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Combinational byte-to-lane
//                        mapper with x16/x8 modes and byte reversal.
//   v0.0.2  2026-09-23  Documentation pass: per-construct comment blocks for
//                        the generate-loop lane mapping and the unused-signal
//                        suppression, citing UCIe 1.0 Section 4.1.1.
//   v0.0.3  2026-09-23  Documentation: cite the correct figures. The header
//                        referenced Figure 48, which is Data Lane remapping.
//                        Byte-to-lane mapping is Figure 42 (x16 byte map) and
//                        Figure 43 (Standard package x8 degraded).
//   v0.0.4  2026-10-08  Documentation compliance pass: expand comments on lower
//                        and upper lane generate assigns with spec subsection references.
//   v0.0.5  2026-10-09  Documentation compliance pass: add per-port inline comments.
// ============================================================================
`ifndef ByteLaneMapper_SV
`define ByteLaneMapper_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module byte_lane_mapper #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,               // Link clock (500 MHz)
  input  logic        lreset_n,           // Unused compatibility reset retained for interface consistency; only lint-referenced
  input  logic        enable,             // Module enable (gates all outputs to 0)
  input  logic        lnk_is_x8,          // 1 = x8-degraded, 0 = x16
  input  logic [1:0]  degrade_lanes,      // DEGRADE_LANES_0_7 / _8_15
  input  logic        byte_reversal,      // optional byte-order reversal
  input  logic [NBYTES-1:0][7:0] bytes_in, // Input parallel data bytes
  output logic [NLANES-1:0][7:0] data_out // Output lane-aligned bytes
);

  // =========================================================================
  // Per-lane source-byte mux  (spec 4.1.1 / 5.2 – byte-to-lane mapping)
  // =========================================================================
  // Each lane selects its source byte directly:
  //   x16              : lane l <- byte l (or NBYTES-1-l if reversed)
  //   x8, lanes 0-7    : lane l <- byte l (or NBYTES-1-l if reversed) for l < 8, 0 for l >= 8
  //   x8, lanes 8-15   : lane l <- byte (l-8) (or NBYTES-1-(l-8) if reversed) for l >= 8, 0 for l < 8
  //
  // In normal x8 mode, surviving lanes carry bytes 0..7. With byte_reversal set,
  // actual reversed x8 selection uses bytes_in[NBYTES-1-index], which with NBYTES=16
  // selects bytes 15..8 in reverse order for either surviving lane half. The inactive
  // half reads zero.
  //
  // The generate loop splits at NLANES_X8 (= 8):
  //   g_lower : Lanes 0 to NLANES_X8-1. In x8 mode with DEGRADE_LANES_0_7,
  //             these lanes carry data (bytes 0..7 normally, or bytes 15..8 in reverse
  //             order when byte_reversal is set); with DEGRADE_LANES_8_15 they are
  //             zeroed.
  //   g_upper : Lanes NLANES_X8 to NLANES-1. In x8 mode with
  //             DEGRADE_LANES_8_15, these lanes carry data from bytes
  //             0..(NLANES_X8-1) normally, or bytes 15..8 in reverse order when
  //             byte_reversal is set; with DEGRADE_LANES_0_7 they are zeroed.
  // When enable is de-asserted, all lanes output 8'b0 regardless of mode.
  // =========================================================================
  generate
    for (genvar l = 0; l < NLANES; l++) begin : g_lane
      // Default source for x16.
      wire [7:0] src_default = byte_reversal ? bytes_in[NBYTES-1-l] : bytes_in[l];

      if (l < NLANES_X8) begin : g_lower
        wire [7:0] src_x8_l = byte_reversal ? bytes_in[NBYTES-1-l] : bytes_in[l];

        // ---------------------------------------------------------------------
        // assign: data_out[l] - Lower Lane Data Multiplexer (Lanes 0..7)
        //
        // Drives lower half lanes. In x16 mode, routes byte l (or reversed byte).
        // In x8 degrade mode on lanes 0..7, routes byte l normally, or reversed
        // byte NBYTES-1-l (selecting bytes 15..8 in reverse order). If lanes 8..15 survive,
        // lower lanes are zeroed per Section 4.3.7. Gated by enable.
        //
        // Spec ref: UCIe 1.0 Section 4.1.1 (Figure 42) and Section 4.3.7.
        // ---------------------------------------------------------------------
        assign data_out[l] = !enable                   ? 8'b0 :
                             !lnk_is_x8               ? src_default :
                             (degrade_lanes == DEGRADE_LANES_0_7) ? src_x8_l :
                                                                   8'b0;
      end else begin : g_upper
        wire [7:0] src_x8_h = byte_reversal ? bytes_in[NBYTES-1-(l-NLANES_X8)]
                                            : bytes_in[l-NLANES_X8];

        // ---------------------------------------------------------------------
        // assign: data_out[l] - Upper Lane Data Multiplexer (Lanes 8..15)
        //
        // Drives upper half lanes. In x16 mode, routes byte l (or reversed byte).
        // In x8 degrade mode on lanes 8..15, routes byte l-8 normally, or reversed
        // byte NBYTES-1-(l-8) (selecting bytes 15..8 in reverse order). If lanes 0..7 survive,
        // upper lanes are zeroed per Section 4.3.7. Gated by enable.
        //
        // Spec ref: UCIe 1.0 Section 4.1.1 (Figure 43) and Section 4.3.7.
        // ---------------------------------------------------------------------
        assign data_out[l] = !enable                   ? 8'b0 :
                             !lnk_is_x8               ? src_default :
                             (degrade_lanes == DEGRADE_LANES_8_15) ? src_x8_h :
                                                                    8'b0;
      end
    end
  endgenerate

  // =========================================================================
  // always_comb: Unused Signal Suppression
  // =========================================================================
  // lclk and lreset_n are present in the port list for interface consistency
  // (all sub-modules of logical_phy share the same clock/reset ports) but are
  // not used in this purely combinational mapper.
  //
  // The mapper is deliberately combinational: spec 4.1.1 defines the byte-to-
  // lane relationship as a fixed wiring permutation, not a clocked operation.
  // There is no state to hold, so a clock would have nothing to do. Keeping
  // the ports anyway means the parent can instantiate every logical_phy child
  // the same way, rather than special-casing this one.
  //
  // An explicit always_comb reference keeps both inputs live for the
  // elaborator so the zero-warning compile gate passes. The assigned value is
  // never read, so synthesis discards the whole block.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
  // =========================================================================
  logic unused;

  // -------------------------------------------------------------------------
  // always_comb: Combinational Lint Suppression Block
  //
  // References lclk and lreset_n to suppress unused input warnings while
  // keeping purely combinational mapper semantics per Section 4.1.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

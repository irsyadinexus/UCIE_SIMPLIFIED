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
// Spec refs   : UCIe 1.0 spec section 4.1.1 (lane and width definitions,
//               byte-to-lane mapping), section 5.2 / Figure 48 (byte-to-
//               lane mapping table for Standard Package), width-degrade
//               mechanism.
//
// --------------------------------------------------------------------------
// Mapping table  (spec 4.1.1 / 5.2 / Figure 48)
// --------------------------------------------------------------------------
//
//   Mode            Lane l source          Active lanes
//   ----            ----------------       ------------
//   x16             byte l                 All 16 lanes
//   x8, lanes 0-7   byte l  (l < 8)        Lanes 0-7 only; lanes 8-15 = 0
//   x8, lanes 8-15  byte (l-8)  (l >= 8)   Lanes 8-15 only; lanes 0-7 = 0
//
//   With byte_reversal set, byte k is sourced from position NBYTES-1-k.
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
// ============================================================================
`ifndef ByteLaneMapper_SV
`define ByteLaneMapper_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module byte_lane_mapper #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        enable,
  input  logic        lnk_is_x8,          // 1 = x8-degraded, 0 = x16
  input  logic [1:0]  degrade_lanes,      // DEGRADE_LANES_0_7 / _8_15
  input  logic        byte_reversal,      // optional byte-order reversal
  input  logic [NBYTES-1:0][7:0] bytes_in,
  output logic [NLANES-1:0][7:0] data_out
);

  // =========================================================================
  // Per-lane source-byte mux  (spec 4.1.1 / 5.2 – byte-to-lane mapping)
  // =========================================================================
  // Each lane selects its source byte directly:
  //   x16              : lane l <- byte l        (or NBYTES-1-l if reversed)
  //   x8, lanes 0-7    : lane l <- byte l        for l <  8, 0 for l >= 8
  //   x8, lanes 8-15   : lane l <- byte (l-8)    for l >= 8, 0 for l <  8
  //
  // The x8 cases fold the x16 table onto the surviving half; the inactive
  // half reads zero. byte_reversal swaps the byte ordering within the
  // active half.
  //
  // The generate loop splits at NLANES_X8 (= 8):
  //   g_lower : Lanes 0 to NLANES_X8-1. In x8 mode with DEGRADE_LANES_0_7,
  //             these lanes carry data; with DEGRADE_LANES_8_15 they are
  //             zeroed.
  //   g_upper : Lanes NLANES_X8 to NLANES-1. In x8 mode with
  //             DEGRADE_LANES_8_15, these lanes carry data from bytes
  //             0..(NLANES_X8-1); with DEGRADE_LANES_0_7 they are zeroed.
  //
  // When enable is de-asserted, all lanes output 8'b0 regardless of mode.
  // =========================================================================
  generate
    for (genvar l = 0; l < NLANES; l++) begin : g_lane
      // Default source for x16.
      wire [7:0] src_default = byte_reversal ? bytes_in[NBYTES-1-l] : bytes_in[l];

      if (l < NLANES_X8) begin : g_lower
        // Lower lanes: x16 -> byte l; x8 lanes 0-7 -> byte l; else inactive.
        wire [7:0] src_x8_l = byte_reversal ? bytes_in[NBYTES-1-l] : bytes_in[l];
        assign data_out[l] = !enable                   ? 8'b0 :
                             !lnk_is_x8               ? src_default :
                             (degrade_lanes == DEGRADE_LANES_0_7) ? src_x8_l :
                                                                   8'b0;
      end else begin : g_upper
        // Upper lanes: x16 -> byte l; x8 lanes 8-15 -> byte l-8; else inactive.
        wire [7:0] src_x8_h = byte_reversal ? bytes_in[NBYTES-1-(l-NLANES_X8)]
                                            : bytes_in[l-NLANES_X8];
        assign data_out[l] = !enable                   ? 8'b0 :
                             !lnk_is_x8               ? src_default :
                             (degrade_lanes == DEGRADE_LANES_8_15) ? src_x8_h :
                                                                    8'b0;
      end
    end
  endgenerate

  // =========================================================================
  // Unused signal suppression
  // =========================================================================
  // lclk and lreset_n are present in the port list for interface consistency
  // (all sub-modules of logical_phy share the same clock/reset ports) but
  // are not used in this purely combinational mapper. An explicit always_comb
  // reference prevents lint warnings.
  // =========================================================================
  logic unused;
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

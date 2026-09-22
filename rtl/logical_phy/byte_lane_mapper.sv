// UCIe 1.0 Simplified Endpoint - byte to lane mapper
// Spec 5.2 / Figure 48: byte-to-lane mapping for x16 and x8-degrade.
//
// Byte k is carried on lane k, 8 bits per lane. In a x8-degraded link only
// lanes 0-7 or lanes 8-15 carry data; the inactive half is forced to zero so
// the partner observes a clean, deterministic pattern.
//
// With byte_reversal set, byte k is sourced from position NBYTES-1-k. The
// table is symmetric, so the transmit and receive directions share one block.
//
// Style note: every bit select is a continuous assign because Icarus Verilog
// 12 does not evaluate a variable index inside an always_* process. The
// x8/x16 choice is a runtime mux, not a generate branch, so the mapper can
// respond to the negotiated link width after elaboration.
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

  // ------------------------------------------------- per-lane mux
  // Each lane selects its source byte directly:
  //   x16              : lane l <- byte l
  //   x8, lanes 0-7    : lane l <- byte l     for l < 8, 0 for l >= 8
  //   x8, lanes 8-15   : lane l <- byte l-8   for l >= 8, 0 for l < 8
  // The x8 cases fold the x16 table onto the surviving half; the inactive
  // half reads zero.
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

  logic unused;
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

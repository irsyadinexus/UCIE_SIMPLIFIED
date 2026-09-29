// ============================================================================
// File        : sb_golden_vectors.sv
// Description : Independent literal scalar sideband vectors.
// ============================================================================
`ifndef SB_GOLDEN_VECTORS_SV
`define SB_GOLDEN_VECTORS_SV
`timescale 1ns/1ps
package sb_golden_vectors;
  localparam logic [4:0] MSG_NODATA_OPCODE = 5'b10010;
  localparam logic [4:0] MSG_DATA64_OPCODE = 5'b11011;
  localparam logic [2:0] PHY_SRC_ID        = 3'b010;
  localparam logic [2:0] REMOTE_PHY_DST_ID = 3'b110;
  localparam logic [15:0] MSG_NODATA_INFO  = 16'h1234;
  localparam logic [7:0] MSG_NODATA_CODE   = 8'h00;
  localparam logic [7:0] MSG_NODATA_SUBCODE = 8'h56;
  localparam logic [15:0] MSG_DATA64_INFO  = 16'habcd;
  localparam logic [7:0] MSG_DATA64_CODE   = 8'ha5;
  localparam logic [7:0] MSG_DATA64_SUBCODE = 8'h00;

  // Figure 102 message without data, encoded LSB-first on the wire.
  localparam logic [63:0] MSG_NODATA_HEADER = 64'h1234_0056_0000_0652;
  localparam logic [63:0] MSG_NODATA_DATA   = 64'h0000_0000_0000_0000;

  // Figure 103 message with 64-bit data, encoded LSB-first on the wire.
  localparam logic [63:0] MSG_DATA64_HEADER  = 64'habcd_a500_8000_065b;
  localparam logic [63:0] MSG_DATA64_PAYLOAD = 64'h0123_4567_89ab_cdef;
endpackage
`endif

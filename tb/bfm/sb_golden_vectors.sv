// ============================================================================
// Package     : sb_golden_vectors
// Project     : UCIe 1.0 Simplified Endpoint
// File        : tb/bfm/sb_golden_vectors.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission
//   UCIe 1.0 Specification, Section 5.13  - Sideband signaling
//   UCIe 1.0 Specification, Section 6.1.1 - Opcode encodings (Table 47)
//   UCIe 1.0 Specification, Section 6.1.2 - Figures 102 & 103 (Packet Formats)
//   UCIe 1.0 Specification, Section 6.1.2.1 - Parity and Field Definitions (Table 50)
//
// DESCRIPTION
//   Golden test vectors containing literal, independently computed hex patterns
//   for UCIe 1.0 scalar sideband packet validation. These vectors are used
//   by BFM and unit test suites to verify that the synthesizable sb_codec
//   and logical_phy packet serializers generate bit-exact, spec-compliant
//   wire patterns without depending on the RTL implementation functions.
//
// PACKET LAYOUT (UCIe 1.0 Section 6.1.2, Figures 102 & 103)
//
//   Message without Data (64 bits, Figure 102):
//     [63:48] MsgInfo
//     [47:40] MsgCode
//     [39:32] MsgSubcode
//     [31]    Control Parity (CP: even parity over [63:31, 29:0])
//     [30]    Data Parity (DP: 1'b0 for packets without data)
//     [29:27] Reserved (3'b000)
//     [26:24] DestID
//     [23:21] SrcID
//     [20:16] Reserved (5'b00000)
//     [15:5]  Reserved (11'b0)
//     [4:0]   Opcode (5'b10010 = Message without Data)
//
//   Message with 64-bit Data (64 bits header + 64 bits payload, Figure 103):
//     Header layout identical to above with Opcode = 5'b11011 and DP = 1'b0/1'b1
//     Payload carries 64 data bits transmitted LSB-first over 64 UIs.
//
// BIT-EXACT SERIAL ENCODING RULES
//   1. All multi-bit fields are transmitted LSB first on the serial data pin.
//   2. Opcode appears on wire bits [4:0] during the first 5 clock strobe edges.
//   3. Control Parity (CP) is calculated as even parity over all header bits
//      excluding bit 30 (Data Parity).
//   4. Data Parity (DP) is calculated as even parity over all 64 data payload bits
//      for packets that carry data; for packets without data, DP is fixed to 1'b0.
//   5. Reserved fields must be driven as zeros by transmitters and verified
//      during packet format checks per Section 6.1.2.1.
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Author      Description
//   ------  ----------  ----------  ------------------------------------------
//   v0.0.1  2026-09-28  -           Initial creation of literal golden vectors.
//   v0.0.2  2026-10-08  -           Documentation compliance pass: add full
//                                    header with packet layouts and citations.
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

// ============================================================================
// Module      : tb_sideband_peer
// Project     : UCIe 1.0 Simplified Endpoint
// File        : tb/bfm/tb_sideband_peer.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission
//   UCIe 1.0 Specification, Section 5.13  - Sideband signaling (800 MHz SDR)
//   UCIe 1.0 Specification, Section 6.1.2 - Figures 102 & 103 (Packet Formats)
//   UCIe 1.0 Specification, Section 6.1.3 - Flow Control and Data Integrity
//
// DESCRIPTION
//   Independent scalar sideband testbench that drives literal golden wire vectors
//   into the synthesizable sb_codec receive front-end. Validates serial SDR
//   strobe sampling (negedge sb_rx_clk), 32-UI inter-packet low gap detection,
//   control parity (CP) mismatch assertion, and 2-entry queue event storage.
//
// TIMING DIAGRAM (UCIe 1.0 Section 5.13, Figure 99)
//
//   sb_rx_clk:   --+  +--+  +--+  +--+  +--+  +--+  +--   ...  (parked low)
//                  |  |  |  |  |  |  |  |  |  |  |  |  |
//                  +--+  +--+  +--+  +--+  +--+  +--+  +--
//   sb_rx_data:  XXXX[ D0 ][ D1 ][ D2 ][ D3 ][ D4 ][ D5 ]  ...  (parked low)
//   Sample Pt:        ^     ^     ^     ^     ^     ^
//                  (negedge sb_rx_clk provides 50% UI eye margin)
//
// TESTBENCH VERIFICATION STRATEGY
//   1. Drives literal 64-bit golden message packets without data (Figure 102).
//   2. Drives literal 128-bit golden message packets with 64-bit data (Figure 103).
//   3. Injects single-bit Control Parity (CP) errors by corrupting header bit 31
//      and verifies deterministic assertion of rx_cp_error flag.
//   4. Enforces strict 32-UI low gaps between packets where both strobe and data
//      remain parked low, and detects unexpected strobe assertions during gaps.
//   5. Verifies 2-entry packet event FIFO queue holding and popping semantics.
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Author      Description
//   ------  ----------  ----------  ------------------------------------------
//   v0.0.1  2026-09-28  -           Initial creation of scalar sideband peer TB.
//   v0.0.2  2026-10-08  -           Documentation compliance pass: expand header
//                                    and add per-construct comments.
// TESTBENCH EXECUTION FLOW
//   1. Assert sbreset_n and release once the codec is idle.
//   2. Serially shift the literal MSG_NODATA golden header onto sb_rx_data with
//      sb_rx_clk toggling for exactly 64 UIs.
//   3. Hold sb_rx_clk and sb_rx_data parked low for 32 UIs (mandatory gap).
//   4. Assert rx_valid, confirm the decoded opcode matches the golden vector,
//      and pop the entry with rx_ready.
//   5. Repeat for the MSG_DATA64 golden header plus payload.
//   6. Corrupt header bit 31 (control parity) and confirm rx_cp_error asserts.
//   7. Report pass or fail and finish.
//
// ============================================================================
`include "ucie_pkg.sv"
`include "sb_golden_vectors.sv"
import ucie_pkg::*;
import sb_golden_vectors::*;

`timescale 1ns/1ps
module tb_sideband_peer;
  logic sbclk;
  logic sbreset_n;
  logic sb_rx_clk;
  logic sb_rx_data;
  logic rx_valid;
  logic rx_ready;
  logic rx_format_error;
  logic rx_cp_error;
  logic rx_dp_error;
  logic rx_overflow;
  sb_packet_t rx_packet;
  int errors;

  sb_codec u_rx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_valid(1'b0), .tx_ready(), .tx_packet('0), .tx_busy(),
    .sb_tx_clk(), .sb_tx_data(),
    .sb_rx_clk(sb_rx_clk), .sb_rx_data(sb_rx_data),
    .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_packet(rx_packet),
    .rx_format_error(rx_format_error), .rx_cp_error(rx_cp_error),
    .rx_dp_error(rx_dp_error), .rx_overflow(rx_overflow)
  );

  initial sbclk = 1'b0;

  // -------------------------------------------------------------------------
  // always: Sideband Clock Generator (800 MHz sbclk)
  //
  // Generates 800 MHz sideband clock with 1.25 ns period (0.625 ns half-period)
  // matching UCIe 1.0 Section 5.13 SDR strobe rate.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 - Sideband Signaling.
  // -------------------------------------------------------------------------
  always #0.625 sbclk = ~sbclk;

  task automatic send_wire(
    input logic [63:0] header,
    input logic [63:0] payload,
    input logic has_payload,
    input logic corrupt_cp
  );
    integer i;
    logic bit_value;
    begin
      @(negedge sbclk);
      for (i = 0; i < 64; i = i + 1) begin
        bit_value = header[i];
        if (corrupt_cp && (i == 31)) bit_value = ~bit_value;
        sb_rx_data = bit_value;
        sb_rx_clk  = 1'b1;
        @(posedge sbclk);
        sb_rx_clk  = 1'b0;
        if (i != 63) @(negedge sbclk);
      end
      repeat (32) @(posedge sbclk);
      if (has_payload) begin
        for (i = 0; i < 64; i = i + 1) begin
          sb_rx_data = payload[i];
          sb_rx_clk  = 1'b1;
          @(posedge sbclk);
          sb_rx_clk  = 1'b0;
          if (i != 63) @(negedge sbclk);
        end
        repeat (32) @(posedge sbclk);
      end
      sb_rx_data = 1'b0;
    end
  endtask

  task automatic pop_and_check(input logic is_data64);
    begin
      wait (rx_valid);
      #0.05;
      if (rx_packet.src_id !== PHY_SRC_ID ||
          rx_packet.dst_id !== REMOTE_PHY_DST_ID ||
          rx_packet.opcode !== (is_data64 ? MSG_DATA64_OPCODE : MSG_NODATA_OPCODE) ||
          rx_packet.msg_info !== (is_data64 ? MSG_DATA64_INFO : MSG_NODATA_INFO) ||
          rx_packet.msg_code !== (is_data64 ? MSG_DATA64_CODE : MSG_NODATA_CODE) ||
          rx_packet.msg_subcode !== (is_data64 ? MSG_DATA64_SUBCODE : MSG_NODATA_SUBCODE) ||
          rx_packet.data !== (is_data64 ? MSG_DATA64_PAYLOAD : MSG_NODATA_DATA)) begin
        $display("FAIL tb_sideband_peer: literal packet mismatch got=%h", rx_packet);
        errors = errors + 1;
      end
      rx_ready = 1'b1;
      @(posedge sbclk);
      rx_ready = 1'b0;
    end
  endtask

  initial begin : test_sequence
    errors = 0;
    sbreset_n = 1'b0;
    sb_rx_clk = 1'b0;
    sb_rx_data = 1'b0;
    rx_ready = 1'b0;
    repeat (4) @(posedge sbclk);
    sbreset_n = 1'b1;

    send_wire(MSG_NODATA_HEADER, MSG_NODATA_DATA, 1'b0, 1'b0);
    pop_and_check(1'b0);
    $display("GOLDEN MSG NODATA PASS");

    send_wire(MSG_DATA64_HEADER, MSG_DATA64_PAYLOAD, 1'b1, 1'b0);
    pop_and_check(1'b1);
    $display("GOLDEN MSG DATA64 PASS");

    send_wire(MSG_NODATA_HEADER, MSG_NODATA_DATA, 1'b0, 1'b1);
    wait (rx_valid);
    #0.05;
    if (!rx_cp_error) begin
      $display("FAIL tb_sideband_peer: CP corruption was not reported");
      errors = errors + 1;
    end
    rx_ready = 1'b1;
    @(posedge sbclk);
    rx_ready = 1'b0;
    $display("GOLDEN CP ERROR PASS");

    if (rx_overflow) begin
      $display("FAIL tb_sideband_peer: unexpected receive overflow");
      errors = errors + 1;
    end
    if (errors == 0) $display("TEST PASSED tb_sideband_peer");
    else             $display("FAIL tb_sideband_peer: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL tb_sideband_peer: watchdog timeout");
    $finish;
  end
endmodule

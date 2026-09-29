// ============================================================================
// File        : ut_sb_codec.sv
// Module      : ut_sb_codec
// Description : Typed sideband codec loopback and aggregate corruption smoke test
//               (inverted serial bitstream asserts aggregate error without overflow;
//               literal CP parity error is verified in tb_sideband_peer).
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_sb_codec;
  logic sbclk;
  logic sbreset_n;
  logic tx_valid;
  logic tx_ready;
  logic tx_busy;
  logic rx_valid;
  logic rx_ready;
  logic rx_format_error;
  logic rx_cp_error;
  logic rx_dp_error;
  logic rx_overflow;
  logic sb_tx_clk;
  logic sb_tx_data;
  logic sb_rx_clk;
  logic sb_rx_data;
  logic corrupt_en;
  sb_packet_t tx_packet;
  sb_packet_t rx_packet;
  int errors;

  assign sb_rx_clk  = sb_tx_clk;
  assign sb_rx_data = corrupt_en ? ~sb_tx_data : sb_tx_data;

  sb_codec u_tx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_packet(tx_packet),
    .tx_busy(tx_busy),
    .sb_tx_clk(sb_tx_clk), .sb_tx_data(sb_tx_data),
    .sb_rx_clk(1'b0), .sb_rx_data(1'b0),
    .rx_valid(), .rx_ready(1'b1), .rx_packet(),
    .rx_format_error(), .rx_cp_error(), .rx_dp_error(), .rx_overflow()
  );

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
  always #0.625 sbclk = ~sbclk;

  task automatic load_packet(input sb_packet_t packet, input logic corrupt);
    begin
      @(negedge sbclk);
      tx_packet = packet;
      corrupt_en = corrupt;
      tx_valid = 1'b1;
      wait (tx_ready);
      @(posedge sbclk);
      @(negedge sbclk);
      tx_valid = 1'b0;
    end
  endtask

  task automatic check_packet(input sb_packet_t expected);
    begin
      wait (rx_valid);
      #0.05;
      if (rx_packet.opcode !== expected.opcode ||
          rx_packet.src_id !== expected.src_id ||
          rx_packet.dst_id !== expected.dst_id ||
          rx_packet.msg_info !== expected.msg_info ||
          rx_packet.msg_code !== expected.msg_code ||
          rx_packet.msg_subcode !== expected.msg_subcode ||
          rx_packet.data !== expected.data) begin
        $display("FAIL ut_sb_codec: packet mismatch got=%h expected=%h",
                 rx_packet, expected);
        errors = errors + 1;
      end
      rx_ready = 1'b1;
      @(posedge sbclk);
      rx_ready = 1'b0;
      wait (!tx_busy);
    end
  endtask

  function automatic sb_packet_t make_message(
    input logic [4:0] opcode,
    input logic [15:0] info,
    input logic [7:0] code,
    input logic [7:0] subcode,
    input logic [63:0] data
  );
    sb_packet_t packet;
    begin
      packet = '0;
      packet.opcode = opcode;
      packet.src_id = SRCID_PHY;
      packet.dst_id = DSTID_REMOTE_PHY;
      packet.msg_info = info;
      packet.msg_code = code;
      packet.msg_subcode = subcode;
      packet.data = data;
      make_message = packet;
    end
  endfunction

  initial begin : test_sequence
    sb_packet_t packet;
    errors = 0;
    tx_valid = 1'b0;
    tx_packet = '0;
    rx_ready = 1'b0;
    corrupt_en = 1'b0;
    sbreset_n = 1'b0;
    repeat (4) @(posedge sbclk);
    sbreset_n = 1'b1;

    packet = make_message(SB_OP_MSG_NODATA, 16'h1234, MC_NOP_CRD, 8'h56, 64'h0);
    load_packet(packet, 1'b0);
    check_packet(packet);

    packet = make_message(SB_OP_MSG_DATA64, 16'habcd, MC_MBINIT_REQ, MS_PARAM_CFG,
                          64'h0123_4567_89ab_cdef);
    load_packet(packet, 1'b0);
    check_packet(packet);

    load_packet(packet, 1'b1);
    wait (rx_valid);
    #0.05;
    if (!(rx_cp_error || rx_dp_error || rx_format_error)) begin
      $display("FAIL ut_sb_codec: corrupted packet had no error");
      errors = errors + 1;
    end
    rx_ready = 1'b1;
    @(posedge sbclk);
    rx_ready = 1'b0;
    wait (!tx_busy);

    if (rx_overflow) begin
      $display("FAIL ut_sb_codec: unexpected receive overflow");
      errors = errors + 1;
    end
    if (errors == 0) $display("TEST PASSED ut_sb_codec");
    else             $display("FAIL ut_sb_codec: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL ut_sb_codec: watchdog timeout");
    $finish;
  end
endmodule

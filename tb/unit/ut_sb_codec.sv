// Unit test: sb_codec round-trip and parity error injection.
// One codec transmits; its serial output feeds a second codec's receive input.
`timescale 1ns/1ps
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ut_sb_codec;
  logic        sbclk, sbreset_n;
  logic        tx_load, tx_busy;
  logic [4:0]  tx_opcode;
  logic [2:0]  tx_srcid, tx_dstid;
  logic [7:0]  tx_msginfo, tx_msgcode, tx_msgsubcode;
  logic        tx_cr;
  logic [11:0] tx_addr;
  logic [7:0]  tx_be;
  logic [4:0]  tx_tag;
  logic        tx_ep;
  logic [63:0] tx_data_in;
  logic        tx_has_data;
  logic [NC-1:0] sb_wire;
  logic        sb_wire_valid;
  logic        corrupt_en = 1'b0;

  // Testbench override mux: flips the received bit for one UI. iverilog's
  // force/release on an instance port is unreliable, so the injection goes
  // through an explicit mux instead.
  wire [NC-1:0] sb_wire_rx = corrupt_en ? ~sb_wire : sb_wire;
  logic        rx_pkt_vld;
  logic [4:0]  rx_opcode;
  logic [2:0]  rx_srcid, rx_dstid;
  logic [7:0]  rx_msginfo, rx_msgcode, rx_msgsubcode;
  logic        rx_cr;
  logic [7:0]  rx_be;
  logic [4:0]  rx_tag;
  logic        rx_ep;
  logic [11:0] rx_addr;
  logic [63:0] rx_data;
  logic        rx_cp_err, rx_dp_err;
  int          errors;

  // rx_pkt_vld is a single-cycle pulse, so the received fields are snapshotted
  // while it is high and compared afterwards.
  logic        sn_vld;
  logic [4:0]  sn_opcode;
  logic [2:0]  sn_srcid, sn_dstid;
  logic [7:0]  sn_msginfo, sn_msgcode, sn_msgsubcode;
  logic        sn_cr;
  logic [7:0]  sn_be;
  logic [4:0]  sn_tag;
  logic        sn_ep;
  logic [11:0] sn_addr;
  logic [63:0] sn_data;
  logic        sn_cp_err, sn_dp_err;

  sb_codec u_tx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(tx_load), .tx_opcode(tx_opcode),
    .tx_srcid(tx_srcid), .tx_dstid(tx_dstid),
    .tx_msginfo(tx_msginfo), .tx_msgcode(tx_msgcode),
    .tx_msgsubcode(tx_msgsubcode), .tx_cr(tx_cr),
    .tx_addr(tx_addr), .tx_be(tx_be), .tx_tag(tx_tag), .tx_ep(tx_ep),
    .tx_data_in(tx_data_in), .tx_has_data(tx_has_data),
    .tx_busy(tx_busy),
    .sb_tx_data(sb_wire), .sb_tx_valid(sb_wire_valid),
    .sb_rx_data({NC{1'b0}}), .sb_rx_valid(1'b0),
    .rx_pkt_vld(), .rx_opcode(), .rx_srcid(), .rx_dstid(),
    .rx_msginfo(), .rx_msgcode(), .rx_msgsubcode(), .rx_cr(),
    .rx_be(), .rx_tag(), .rx_ep(),
    .rx_addr(), .rx_data(), .rx_cp_err(), .rx_dp_err()
  );

  sb_codec u_rx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(1'b0), .tx_opcode(5'b0),
    .tx_srcid(3'b0), .tx_dstid(3'b0),
    .tx_msginfo(8'b0), .tx_msgcode(8'b0),
    .tx_msgsubcode(8'b0), .tx_cr(1'b0),
    .tx_addr(12'b0), .tx_be(8'b0), .tx_tag(5'b0), .tx_ep(1'b0),
    .tx_data_in(64'b0), .tx_has_data(1'b0),
    .tx_busy(),
    .sb_tx_data(), .sb_tx_valid(),
    .sb_rx_data(sb_wire_rx), .sb_rx_valid(sb_wire_valid),
    .rx_pkt_vld(rx_pkt_vld), .rx_opcode(rx_opcode),
    .rx_srcid(rx_srcid), .rx_dstid(rx_dstid),
    .rx_msginfo(rx_msginfo), .rx_msgcode(rx_msgcode),
    .rx_msgsubcode(rx_msgsubcode), .rx_cr(rx_cr),
    .rx_be(rx_be), .rx_tag(rx_tag), .rx_ep(rx_ep),
    .rx_addr(rx_addr), .rx_data(rx_data),
    .rx_cp_err(rx_cp_err), .rx_dp_err(rx_dp_err)
  );

  initial sbclk = 1'b0;
  always #2 sbclk = ~sbclk;     // 250 MHz sideband

  // Latch the receiver outputs on the single-cycle valid pulse.
  always @(posedge rx_pkt_vld) begin
    #0.1;
    sn_vld       = rx_pkt_vld;
    sn_opcode    = rx_opcode;
    sn_srcid     = rx_srcid;
    sn_dstid     = rx_dstid;
    sn_msginfo   = rx_msginfo;
    sn_msgcode   = rx_msgcode;
    sn_msgsubcode= rx_msgsubcode;
    sn_cr        = rx_cr;
    sn_be        = rx_be;
    sn_tag       = rx_tag;
    sn_ep        = rx_ep;
    sn_addr      = rx_addr;
    sn_data      = rx_data;
    sn_cp_err    = rx_cp_err;
    sn_dp_err    = rx_dp_err;
  end

  // Load one packet and wait for the receiver to report it.
  task send_one;
    input [4:0]  op;
    input [2:0]  sid, did;
    input [7:0]  minfo, mcode, msub;
    input        cr;
    input [11:0] addr;
    input [7:0]  be;
    input [4:0]  tag;
    input        ep;
    input [63:0] data;
    input        has_data;
    begin
      @(negedge sbclk);
      tx_opcode    = op;
      tx_srcid     = sid;
      tx_dstid     = did;
      tx_msginfo   = minfo;
      tx_msgcode   = mcode;
      tx_msgsubcode= msub;
      tx_cr        = cr;
      tx_addr      = addr;
      tx_be        = be;
      tx_tag       = tag;
      tx_ep        = ep;
      tx_data_in   = data;
      tx_has_data  = has_data;
      tx_load      = 1'b1;
      @(posedge sbclk);
      @(negedge sbclk);
      tx_load      = 1'b0;
      @(posedge rx_pkt_vld);
      // Hold off until the gap completes so the next load is not dropped.
      wait (!tx_busy);
    end
  endtask

  // Cross-check the snapshotted received fields against what was sent.
  task check_fields;
    input [4:0]  op;
    input [2:0]  sid, did;
    input [7:0]  minfo, mcode, msub;
    input        cr;
    input [11:0] addr;
    input [7:0]  be;
    input [4:0]  tag;
    input        ep;
    input [63:0] data;
    input        has_data;
    begin
      if (!sn_vld) begin
        $display("FAIL ut_sb_codec: no packet received");
        errors = errors + 1;
      end
      if (sn_opcode !== op) begin
        $display("FAIL ut_sb_codec: opcode got %b exp %b", sn_opcode, op);
        errors = errors + 1;
      end
      if (sn_srcid !== sid) begin
        $display("FAIL ut_sb_codec: srcid got %b exp %b", sn_srcid, sid);
        errors = errors + 1;
      end
      if (sn_dstid !== did) begin
        $display("FAIL ut_sb_codec: dstid got %b exp %b", sn_dstid, did);
        errors = errors + 1;
      end
      if (sn_msginfo !== minfo) begin
        $display("FAIL ut_sb_codec: msginfo got %h exp %h", sn_msginfo, minfo);
        errors = errors + 1;
      end
      if (sn_msgcode !== mcode) begin
        $display("FAIL ut_sb_codec: msgcode got %h exp %h", sn_msgcode, mcode);
        errors = errors + 1;
      end
      if (sn_msgsubcode !== msub) begin
        $display("FAIL ut_sb_codec: msgsubcode got %h exp %h",
                 sn_msgsubcode, msub);
        errors = errors + 1;
      end
      if (sn_cr !== cr) begin
        $display("FAIL ut_sb_codec: cr got %b exp %b", sn_cr, cr);
        errors = errors + 1;
      end
      if (sn_addr !== addr) begin
        $display("FAIL ut_sb_codec: addr got %h exp %h", sn_addr, addr);
        errors = errors + 1;
      end
      if (sn_be !== be) begin
        $display("FAIL ut_sb_codec: be got %h exp %h", sn_be, be);
        errors = errors + 1;
      end
      if (sn_tag !== tag) begin
        $display("FAIL ut_sb_codec: tag got %b exp %b", sn_tag, tag);
        errors = errors + 1;
      end
      if (sn_ep !== ep) begin
        $display("FAIL ut_sb_codec: ep got %b exp %b", sn_ep, ep);
        errors = errors + 1;
      end
      if (has_data && sn_data !== data) begin
        $display("FAIL ut_sb_codec: data got %h exp %h", sn_data, data);
        errors = errors + 1;
      end
      if (sn_cp_err !== 1'b0) begin
        $display("FAIL ut_sb_codec: unexpected cp_err");
        errors = errors + 1;
      end
      if (sn_dp_err !== 1'b0) begin
        $display("FAIL ut_sb_codec: unexpected dp_err");
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    sbreset_n    = 1'b0;
    tx_load      = 1'b0;
    tx_opcode    = 5'b0;
    tx_srcid     = 3'b0;
    tx_dstid     = 3'b0;
    tx_msginfo   = 8'b0;
    tx_msgcode   = 8'b0;
    tx_msgsubcode= 8'b0;
    tx_cr        = 1'b0;
    tx_addr      = 12'b0;
    tx_be        = 8'b0;
    tx_tag       = 5'b0;
    tx_ep        = 1'b0;
    tx_data_in   = 64'b0;
    tx_has_data  = 1'b0;
    sn_vld       = 1'b0;
    sn_cp_err    = 1'b0;
    sn_dp_err    = 1'b0;
    #5;
    sbreset_n    = 1'b1;
    @(negedge sbclk);

    // 1. Header-only message: LinkMgmt request, no payload.
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBINIT_REQ, 8'h00, 1'b0,
             12'h123, 8'h0F, 5'h1A, 1'b0, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBINIT_REQ, 8'h00, 1'b0,
                 12'h123, 8'h0F, 5'h1A, 1'b0, 64'b0, 1'b0);

    // 2. Message with a 64-bit payload, odd-parity data.
    send_one(SB_OP_MSG_DATA64, SRCID_STACK0, SRCID_ADAPT,
             MS_LM_ACTIVE, MC_LM_RDI_REQ, RDI_REQ_ACTIVE, 1'b1,
             12'hABC, 8'hC3, 5'h07, 1'b1,
             64'hBEEF_DEAD_BEEF_DEAD, 1'b1);
    check_fields(SB_OP_MSG_DATA64, SRCID_STACK0, SRCID_ADAPT,
                 MS_LM_ACTIVE, MC_LM_RDI_REQ, RDI_REQ_ACTIVE, 1'b1,
                 12'hABC, 8'hC3, 5'h07, 1'b1,
                 64'hBEEF_DEAD_BEEF_DEAD, 1'b1);

    // 3. Back-to-back packets: the gap must not bleed into the next header.
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBTRAIN_REQ, 8'h05, 1'b0,
             12'h000, 8'h00, 5'h00, 1'b0, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBTRAIN_REQ, 8'h05, 1'b0,
                 12'h000, 8'h00, 5'h00, 1'b0, 64'b0, 1'b0);
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBTRAIN_RSP, 8'h06, 1'b1,
             12'h7FF, 8'hFF, 5'h1F, 1'b1, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBTRAIN_RSP, 8'h06, 1'b1,
                 12'h7FF, 8'hFF, 5'h1F, 1'b1, 64'b0, 1'b0);

    // 4. CP error injection: hold the serial line high for one header UI,
    // flipping exactly one received bit.
    @(negedge sbclk);
    tx_opcode    = SB_OP_MSG_NODATA;
    tx_srcid     = SRCID_ADAPT;
    tx_dstid     = SRCID_STACK0;
    tx_msginfo   = 8'h00;
    tx_msgcode   = MC_SB_DONE_REQ;
    tx_msgsubcode= 8'h00;
    tx_cr        = 1'b0;
    tx_addr      = 12'h000;
    tx_be        = 8'h00;
    tx_tag       = 5'h00;
    tx_ep        = 1'b0;
    tx_has_data  = 1'b0;
    tx_load      = 1'b1;
    @(posedge sbclk);
    @(negedge sbclk);
    tx_load      = 1'b0;
    // Corrupt UI 10: a header bit, not a parity bit.
    repeat (9) @(posedge sbclk);
    corrupt_en = 1'b1;
    @(posedge sbclk);
    corrupt_en = 1'b0;
    @(posedge rx_pkt_vld);
    #1;
    if (sn_vld !== 1'b1) begin
      $display("FAIL ut_sb_codec: corrupted packet not reported");
      errors = errors + 1;
    end
    if (sn_cp_err !== 1'b1) begin
      $display("FAIL ut_sb_codec: cp_err not flagged on corrupted header");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_sb_codec");
    else             $display("FAIL ut_sb_codec: %0d errors", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("FAIL ut_sb_codec: watchdog timeout");
    $finish;
  end

endmodule

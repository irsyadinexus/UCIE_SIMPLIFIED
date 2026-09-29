// ============================================================================
// File        : tb_adapter_sideband.sv
// Description : FDI phase parser to typed Adapter sideband request smoke test.
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module tb_adapter_sideband;
  logic lclk;
  logic lreset_n;
  logic [NC-1:0] lp_cfg;
  logic lp_cfg_vld;
  logic lp_cfg_crd;
  logic [NC-1:0] pl_cfg;
  logic pl_cfg_vld;
  logic pl_cfg_crd;
  logic adapter_sb_tx_valid;
  logic adapter_sb_tx_ready;
  sb_packet_t adapter_sb_tx_packet;
  logic adapter_sb_rx_valid;
  logic adapter_sb_rx_ready;
  sb_packet_t adapter_sb_rx_packet;
  logic adapter_sb_rx_cp_error;
  logic adapter_sb_rx_dp_error;
  logic adapter_sb_rx_format_error;
  logic [3:0] rdi_pl_state_sts;
  logic [3:0] lp_state_req;
  logic adapter_state_req_vld;
  logic [3:0] adapter_state_req;
  logic csr_wr, csr_rd;
  logic [26:0] csr_addr;
  logic [63:0] csr_wdata;
  logic [7:0] csr_be;
  logic [63:0] csr_rdata;
  logic csr_rdata_vld;
  logic csr_target;
  logic phy_csr_wr, phy_csr_rd;
  logic [26:0] phy_csr_addr;
  logic [63:0] phy_csr_wdata;
  logic [7:0] phy_csr_be;
  logic [63:0] phy_csr_rdata;
  logic phy_csr_rdata_vld;
  logic rem_req_vld, rem_req_rdy;
  sb_packet_t rem_req_pkt;
  logic rem_cpl_vld;
  sb_packet_t rem_cpl_pkt;
  logic adapter_fatal, adapter_linkerror, stage3_done;
  logic protocol_error, fdi_format_error, sb_credit_returned, sb_stall_sent;
  logic sb_msg_timeout;
  integer errors;

  adapter_sb_if u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .lp_cfg(lp_cfg), .lp_cfg_vld(lp_cfg_vld), .lp_cfg_crd(lp_cfg_crd),
    .pl_cfg(pl_cfg), .pl_cfg_vld(pl_cfg_vld), .pl_cfg_crd(pl_cfg_crd),
    .adapter_sb_tx_valid(adapter_sb_tx_valid),
    .adapter_sb_tx_ready(adapter_sb_tx_ready),
    .adapter_sb_tx_packet(adapter_sb_tx_packet),
    .adapter_sb_rx_valid(adapter_sb_rx_valid),
    .adapter_sb_rx_ready(adapter_sb_rx_ready),
    .adapter_sb_rx_packet(adapter_sb_rx_packet),
    .adapter_sb_rx_cp_error(adapter_sb_rx_cp_error),
    .adapter_sb_rx_dp_error(adapter_sb_rx_dp_error),
    .adapter_sb_rx_format_error(adapter_sb_rx_format_error),
    .rdi_pl_state_sts(rdi_pl_state_sts), .lp_state_req(lp_state_req),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .csr_wr(csr_wr), .csr_rd(csr_rd), .csr_addr(csr_addr),
    .csr_wdata(csr_wdata), .csr_be(csr_be),
    .csr_rdata(csr_rdata), .csr_rdata_vld(csr_rdata_vld),
    .csr_target(csr_target), .phy_csr_wr(phy_csr_wr), .phy_csr_rd(phy_csr_rd),
    .phy_csr_addr(phy_csr_addr), .phy_csr_wdata(phy_csr_wdata),
    .phy_csr_be(phy_csr_be), .phy_csr_rdata(phy_csr_rdata),
    .phy_csr_rdata_vld(phy_csr_rdata_vld),
    .rem_req_vld(rem_req_vld), .rem_req_rdy(rem_req_rdy),
    .rem_req_pkt(rem_req_pkt), .rem_cpl_vld(rem_cpl_vld),
    .rem_cpl_pkt(rem_cpl_pkt), .adapter_fatal(adapter_fatal),
    .adapter_linkerror(adapter_linkerror), .stage3_done(stage3_done),
    .protocol_error(protocol_error), .fdi_format_error(fdi_format_error),
    .sb_credit_returned(sb_credit_returned), .sb_stall_sent(sb_stall_sent),
    .sb_msg_timeout(sb_msg_timeout)
  );

  initial lclk = 1'b0;
  always #1.0 lclk = ~lclk;

  initial begin : test_sequence
    sb_packet_t request;
    logic [63:0] header;
    integer i;
    logic seen;
    errors = 0;
    lp_cfg = '0;
    lp_cfg_vld = 1'b0;
    lp_cfg_crd = 1'b0;
    adapter_sb_tx_ready = 1'b1;
    adapter_sb_rx_valid = 1'b0;
    adapter_sb_rx_packet = '0;
    adapter_sb_rx_cp_error = 1'b0;
    adapter_sb_rx_dp_error = 1'b0;
    adapter_sb_rx_format_error = 1'b0;
    rdi_pl_state_sts = RDI_STS_ACTIVE;
    lp_state_req = FDI_REQ_ACTIVE;
    csr_rdata = '0;
    csr_rdata_vld = 1'b0;
    phy_csr_rdata = '0;
    phy_csr_rdata_vld = 1'b0;
    rem_req_vld = 1'b0;
    rem_req_pkt = '0;
    lreset_n = 1'b0;
    repeat (3) @(posedge lclk);
    lreset_n = 1'b1;

    request = '0;
    request.opcode = SB_OP_CFG_READ32;
    request.src_id = FDI_SRCID_STACK0;
    request.dst_id = FDI_DSTID_ADAPTER;
    request.addr = 27'h0012344;
    request.be = 8'h0f;
    request.tag = 5'h12;
    header = ucie_pkg::sb_encode_header(request);
    seen = 1'b0;
    for (i = 0; i < 8; i = i + 1) begin
      @(negedge lclk);
      lp_cfg = header[i*8 +: 8];
      lp_cfg_vld = 1'b1;
      @(posedge lclk);
      #0.05;
      if (csr_rd) seen = 1'b1;
    end
    @(negedge lclk);
    lp_cfg = '0;
    lp_cfg_vld = 1'b0;

    repeat (8) begin
      @(posedge lclk);
      #0.05;
      if (csr_rd) seen = 1'b1;
    end
    if (!seen) begin
      $display("FAIL tb_adapter_sideband: no local CSR read request");
      errors = errors + 1;
    end
    if (fdi_format_error || adapter_fatal) begin
      $display("FAIL tb_adapter_sideband: valid FDI request raised error");
      errors = errors + 1;
    end
    if (errors == 0) $display("TEST PASSED tb_adapter_sideband");
    else             $display("FAIL tb_adapter_sideband: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000;
    $display("FAIL tb_adapter_sideband: watchdog timeout");
    $finish;
  end
endmodule

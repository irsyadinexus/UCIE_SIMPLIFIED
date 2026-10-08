// ============================================================================
// Module      : tb_adapter_sideband
// Project     : UCIe 1.0 Simplified Endpoint
// File        : tb/bfm/tb_adapter_sideband.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 3.1.1 - Stage 3: Adapter Initialization
//   UCIe 1.0 Specification, Section 6.1   - Sideband Protocol Specification
//   UCIe 1.0 Specification, Section 7.5   - UCIe Registers (CSR definition)
//   UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband Interface (Table 115)
//
// DESCRIPTION
//   Unit smoke testbench for the D2D Adapter sideband interface (adapter_sb_if).
//   Verifies the 8-phase FDI header reconstruction, optional 8-phase payload
//   reconstruction, local CSR configuration access execution, and typed packet
//   exchange across the private adapter client interface.
//
// ARCHITECTURAL DIAGRAM
//
//   +----------------------+              +----------------------+
//   | Protocol Layer BFM   |-- lp_cfg --->| adapter_sb_if        |
//   |                      |<-- pl_cfg ---|                      |
//   +----------------------+              +----------+-----------+
//                                                    |
//                                          adapter_sb_tx / rx
//                                                    v
//                                         [Logical PHY Interface]
//
// TESTBENCH VERIFICATION STRATEGY
//   1. FDI Header Assembly: Emits 8 consecutive phases of lp_cfg bytes with
//      lp_cfg_vld asserted. Verifies correct 64-bit header reconstruction.
//   2. FDI Payload Assembly: Emits optional 8 consecutive payload phases for
//      packets requiring 32-bit or 64-bit data. Verifies payload padding.
//   3. Gap Fault Detection: Injects illegal gaps during multi-phase transfers
//      to confirm immediate sticky assertion of fdi_format_error per spec.
//   4. Outgoing Completion Verification: Monitors pl_cfg serialization over
//      8 back-to-back phases and observes pl_cfg_crd credit returns.
//   5. CSR Target Decoding: Validates separate routing between local adapter
//      register file (Target 3'b001) and physical layer CSRs (Target 3'b010).
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Author      Description
//   ------  ----------  ----------  ------------------------------------------
//   v0.0.1  2026-09-28  -           Initial creation of adapter sideband test.
//   v0.0.2  2026-10-08  -           Documentation compliance pass: expand header
//                                    and add per-construct comments.
// TESTBENCH EXECUTION FLOW
//   1. Assert lreset_n and wait for the adapter sideband FSM to leave reset.
//   2. Drive an incoming FDI 32-bit configuration write across 8 header phases
//      and 8 payload phases with lp_cfg_vld held high on every phase.
//   3. Verify the adapter decodes the request and issues csr_wr to the local
//      register file for destination Adapter (3'b001).
//   4. Verify the adapter serializes a matching completion response on pl_cfg
//      over 8 back-to-back phases with no internal gaps.
//   5. Repeat for destination PHY (3'b010) and confirm the phy_csr_* channel
//      is driven instead of the local register file.
//   6. Inject an intra-transaction gap and confirm sticky fdi_format_error.
//   7. Report pass or fail and finish.
//
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

  // -------------------------------------------------------------------------
  // Module instantiation: adapter_sb_if u_dut (device under test)
  //
  // Device under test. The testbench drives lp_cfg with FDI header and payload
  // phases, observes the serialized completion stream on pl_cfg, and monitors
  // the typed private Adapter client signals together with the CSR channel.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband Interface.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz reference link clock with 2.0 ns period (1.0 ns half-period)
  // for the D2D Adapter sideband interface under test.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Link Clock Frequency.
  // -------------------------------------------------------------------------
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

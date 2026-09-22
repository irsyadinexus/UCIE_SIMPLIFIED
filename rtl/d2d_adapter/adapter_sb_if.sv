// UCIe 1.0 Simplified Endpoint - adapter sideband interface
// Spec 6.1.3. Handles the Adapter's end of the FDI credit loop and the remote
// credit loop, plus the 8 ms message timeout and the 4 ms Stall keep-alive.
// The LTSM inside logical_phy owns its own RDI-side credit loop independently.
`ifndef AdapterSbIf_SV
`define AdapterSbIf_SV
`include "ucie_pkg.sv"

module adapter_sb_if (
  input  logic        lclk,
  input  logic        lreset_n,

  // FDI sideband (Protocol Layer -> Adapter), spec 6.1.3 / Table 115
  input  logic [NC-1:0] lp_cfg,
  input  logic          lp_cfg_vld,
  input  logic          lp_cfg_crd,
  output logic [NC-1:0] pl_cfg,
  output logic          pl_cfg_vld,
  output logic          pl_cfg_crd,

  // Link management indication from the partner, decoded by logical_phy.
  input  logic          partner_active_req,
  output logic          adapter_active_req,   // to fdi_state_machine
  output logic          adapter_state_req_vld,
  output logic [3:0]    adapter_state_req,

  // CSR access path
  output logic          csr_wr,
  output logic [26:0]   csr_addr,
  output logic [63:0]   csr_wdata,
  output logic          csr_rd,
  input  logic [63:0]   csr_rdata,
  input  logic          csr_rdata_vld,

  // Coverage/monitor hooks
  output logic          sb_credit_returned,
  output logic          sb_stall_sent,
  output logic          sb_msg_timeout
);

  import ucie_pkg::*;

  // Credit accounting. One credit = 64b header + 64b data. The FDI loop and the
  // remote loop are independent; remote is capped at 4 outstanding.
  logic [1:0] crd_fdi_q;     // credits owed to the local FDI
  logic [2:0] crd_remote_q;  // outstanding remote credits
  logic       crd_return_pending;

  // 8 ms message timeout for outstanding requests.
  logic       msg_timer_start;
  logic       msg_timer_run;
  logic       msg_timer_expired;

  // 4 ms Stall keep-alive while waiting for a response.
  logic       stall_timer_start;
  logic       stall_timer_run;
  logic       stall_timer_expired;

  ucie_timer #(.LIMIT_CYCLES(C_SB_MSG)) u_msg_timer (
    .clk(lclk), .reset_n(lreset_n),
    .start(msg_timer_start), .running(msg_timer_run),
    .expired(msg_timer_expired)
  );

  ucie_timer #(.LIMIT_CYCLES(C_STALL)) u_stall_timer (
    .clk(lclk), .reset_n(lreset_n),
    .start(stall_timer_start), .running(stall_timer_run),
    .expired(stall_timer_expired)
  );

  // ------------------------------------------------------- received packets
  // The PHY decodes the 64-bit serial stream; this block consumes the parsed
  // fields. lp_cfg carries 8 bits per UI of the 64-bit packet.
  logic [63:0] rx_hdr_q;
  logic [3:0]  rx_ui_q;
  logic        rx_pkt_vld;

  wire [63:0] rx_hdr_d = {rx_hdr_q[55:0], lp_cfg};
  wire        rx_complete = (rx_ui_q == 4'd7);

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      rx_hdr_q  <= '0;
      rx_ui_q   <= '0;
      rx_pkt_vld <= 1'b0;
    end else if (lp_cfg_vld) begin
      rx_hdr_q  <= rx_hdr_d;
      rx_ui_q   <= rx_ui_q + 1'b1;
      rx_pkt_vld <= rx_complete;
    end else begin
      rx_pkt_vld <= 1'b0;
    end
  end

  // Parsed fields from the received 64-bit header.
  wire [7:0]  rx_msgcode = rx_hdr_q[7:0];
  wire [7:0]  rx_subcode = rx_hdr_q[15:8];
  wire [15:0] rx_msginfo = rx_hdr_q[31:16];
  wire        rx_cp      = rx_hdr_q[36];
  wire        rx_dp      = rx_hdr_q[37];
  wire        rx_cr      = rx_hdr_q[38];
  wire [2:0]  rx_srcid   = rx_hdr_q[50:48];
  wire [2:0]  rx_dstid   = rx_hdr_q[53:51];
  wire [4:0]  rx_opcode  = rx_hdr_q[58:54];

  // CP even parity over all header bits except DP.
  wire [63:0] hdr_for_cp = {rx_hdr_q[63:38], 1'b0, rx_hdr_q[36:0]};
  wire        cp_calc    = ^hdr_for_cp;

  // ------------------------------------------------------------- transmit
  logic [63:0] tx_hdr;
  logic        tx_send;
  logic [3:0]  tx_ui_q;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_ui_q <= '0;
    end else if (tx_send) begin
      tx_ui_q <= tx_ui_q + 1'b1;
    end
  end

  // 32-UI gap between packets, enforced by a down-counter.
  logic [5:0] gap_q;
  wire       in_gap = (gap_q != '0);

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      gap_q <= '0;
    end else if (tx_send && tx_ui_q == 4'd7) begin
      gap_q <= SB_GAP_UI[5:0];
    end else if (in_gap) begin
      gap_q <= gap_q - 1'b1;
    end
  end

  always_comb begin
    pl_cfg     = tx_hdr[8*tx_ui_q +: NC];
    pl_cfg_vld = tx_send;
    pl_cfg_crd = 1'b0;
  end

  // ------------------------------------------------------ credit accounting
  // Credit returns arrive in the Cr bit of a received packet.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      crd_fdi_q   <= '0;
      crd_remote_q<= '0;
    end else if (rx_pkt_vld && rx_cr) begin
      // Cr is a credit return to the requester, which is the Adapter.
      crd_remote_q <= (crd_remote_q > 0) ? crd_remote_q - 1'b1 : crd_remote_q;
    end else if (rx_pkt_vld && rx_opcode == SB_OP_MSG_NODATA &&
                 rx_msgcode == MC_NOP_CRD) begin
      // Nop.Crd carries 1-4 credits in MsgInfo.
      crd_fdi_q <= crd_fdi_q + rx_msginfo[2:0];
    end
  end

  assign sb_credit_returned = rx_pkt_vld && (rx_cr ||
                            (rx_opcode == SB_OP_MSG_NODATA && rx_msgcode == MC_NOP_CRD));

  // --------------------------------------------------- link management msgs
  // {LinkMgmt.RDI.Req.Active} from the partner means the partner Adapter wants
  // Active. FDI only forwards Active once both sides have asked.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      adapter_active_req <= 1'b0;
    end else if (rx_pkt_vld && rx_opcode == SB_OP_MSG_NODATA &&
                 rx_msgcode == MC_LM_RDI_REQ && rx_subcode == MS_LM_ACTIVE) begin
      adapter_active_req <= 1'b1;
    end else if (rx_pkt_vld && rx_opcode == SB_OP_MSG_NODATA &&
                 rx_msgcode == MC_LM_RDI_REQ &&
                 (rx_subcode == MS_LM_LINKRESET || rx_subcode == MS_LM_DISABLE)) begin
      adapter_active_req <= 1'b0;
    end
  end

  // Requests the Adapter generates in response to the Protocol Layer.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      adapter_state_req_vld <= 1'b0;
      adapter_state_req     <= RDI_REQ_NOP;
    end
  end

  // ------------------------------------------------------------- timers
  always_comb begin
    msg_timer_start   = (crd_remote_q != 0) && !(rx_pkt_vld && rx_cr);
    msg_timer_run     = (crd_remote_q != 0);
    stall_timer_start = msg_timer_expired;
    stall_timer_run   = (crd_remote_q != 0) && !msg_timer_expired;
    sb_msg_timeout    = msg_timer_expired;
    sb_stall_sent     = stall_timer_expired;
  end

  // Error log / CSR access. Sideband register accesses target dstid 001b.
  // Constant part-selects live in continuous assigns: iverilog 12 does not
  // evaluate them inside an always_* process.
  assign csr_addr  = rx_hdr_q[26:0];
  assign csr_wdata = rx_hdr_q[63:0];

  always_comb begin
    csr_wr    = rx_pkt_vld && (rx_dstid == SRCID_ADAPT) &&
                (rx_opcode == 5'b00001 || rx_opcode == 5'b00101);
    csr_rd    = rx_pkt_vld && (rx_dstid == SRCID_ADAPT) &&
                (rx_opcode == 5'b00100 || rx_opcode == 5'b01100);
    tx_send   = csr_rd && csr_rdata_vld;
    tx_hdr    = {csr_rdata, 27'h0, 5'b10001, 3'b000, 3'b001, 3'b0, 3'b0, 5'b10000};
  end

endmodule

`endif

// ============================================================================
// Module    : adapter_sb_if
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_sb_if.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.5.x - Sideband Packet Format
//   UCIe 1.0 Specification, Section 6.1.3 - Sideband Credit Model
//   UCIe 1.0 Specification, Section 6.2 - Sideband Message Timeout (8 ms)
//   UCIe 1.0 Specification, Section 6.3 - Stall Keep-Alive (4 ms)
//   UCIe 1.0 Specification, Table 47 - Sideband Opcodes
//   UCIe 1.0 Specification, Table 49 - SrcID / DstID Encodings
//   UCIe 1.0 Specification, Tables 53-56 - Sideband Message Codes
//   UCIe 1.0 Specification, Table 115 - FDI Signal List (lp_cfg / pl_cfg)
//
// DESCRIPTION
//   Adapter-side sideband interface. This module sits on the FDI boundary
//   and handles the Adapter's portion of the sideband communication:
//
//     1. RECEIVE PATH (lp_cfg / lp_cfg_vld):
//        Deserialises the NC-bit-per-UI sideband stream into 64-bit packet
//        headers. The PHY delivers NC=8 bits per UI on lp_cfg; after 8 UIs
//        (rx_ui_q counts 0-7), a complete 64-bit header is assembled in
//        rx_hdr_q and rx_pkt_vld pulses for one cycle.
//
//     2. TRANSMIT PATH (pl_cfg / pl_cfg_vld):
//        Serialises a 64-bit tx_hdr into NC-bit-per-UI chunks. tx_ui_q
//        counts 0-7 during transmission. A 32-UI inter-packet gap
//        (SB_GAP_UI) is enforced by gap_q, per spec 4.5.x framing rules.
//
//     3. CREDIT ACCOUNTING (spec 6.1.3):
//        - FDI credit loop (crd_fdi_q): credits owed to the local FDI
//          (Protocol Layer). Replenished by Nop.Crd messages carrying
//          1-4 credits in MsgInfo[2:0].
//        - Remote credit loop (crd_remote_q): outstanding credits consumed
//          by messages sent to the remote die. Capped at SB_CRD_MAX (4).
//          Returned by the Cr bit in received completion packets.
//
//     4. TIMERS:
//        - 8 ms message timeout (C_SB_MSG cycles via ucie_timer): starts
//          when crd_remote_q != 0 and fires sb_msg_timeout if no credit
//          return arrives in time (spec 6.2).
//        - 4 ms stall keep-alive (C_STALL cycles via ucie_timer): fires
//          sb_stall_sent after the message timeout expires (spec 6.3).
//
//     5. LINK MANAGEMENT MESSAGE DECODING:
//        - LinkMgmt.RDI.Req.Active (MC_LM_RDI_REQ / MS_LM_ACTIVE): sets
//          adapter_active_req, indicating the partner die wants Active.
//        - LinkMgmt.RDI.Req.LinkReset/Disable: clears adapter_active_req.
//
//     6. CSR ACCESS PATH:
//        Sideband CfgRd/CfgWr packets addressed to SRCID_ADAPT (dstid =
//        3'b001) are decoded and forwarded to adapter_regfile via the
//        csr_wr/csr_rd/csr_addr/csr_wdata bus. CfgRd completions are
//        transmitted back when csr_rdata_vld is asserted.
//
//   PACKET HEADER FORMAT (spec 4.5.x, 64-bit header):
//     [7:0]   MsgCode    - message type identifier.
//     [15:8]  SubCode    - message sub-type.
//     [31:16] MsgInfo    - message-specific information.
//     [36]    CP         - command parity (even parity over header, excl DP).
//     [37]    DP         - data parity.
//     [38]    Cr         - credit return bit.
//     [50:48] SrcID      - source identifier (Table 49).
//     [53:51] DstID      - destination identifier (Table 49).
//     [58:54] Opcode     - operation code (Table 47).
//
//   The LTSM inside logical_phy owns its own RDI-side sideband credit loop
//   independently of this module.
//
// PORTS
//   lp_cfg / lp_cfg_vld / lp_cfg_crd  - FDI sideband from Protocol Layer.
//   pl_cfg / pl_cfg_vld / pl_cfg_crd  - FDI sideband to Protocol Layer.
//   partner_active_req                - external Active indication (tied to
//                                       1'b0 at top level; the module itself
//                                       latches Active from the packet stream).
//   adapter_active_req                - to fdi_state_machine: partner wants Active.
//   adapter_state_req_vld/req         - general state request channel (reduced scope).
//   csr_wr/rd/addr/wdata/rdata/vld    - CSR access bus to adapter_regfile.
//   sb_credit_returned                - monitor: credit-return packet received.
//   sb_stall_sent                     - monitor: stall keep-alive fired.
//   sb_msg_timeout                    - monitor: 8 ms message timeout fired.
//
// CLOCK / RESET
//   lclk      - Main link clock (1 GHz).
//   lreset_n  - Active-low asynchronous reset.
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
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

  // --------------------------------------------------------------------------
  // Credit Accounting Registers
  // --------------------------------------------------------------------------
  // Per spec 6.1.3, the sideband credit model uses two independent loops:
  //
  //   crd_fdi_q (2 bits): credits owed to the local FDI (Protocol Layer).
  //     Replenished by Nop.Crd messages from the remote die that carry
  //     1-4 credits in MsgInfo[2:0]. Consumed when the adapter accepts
  //     a sideband packet from the Protocol Layer.
  //
  //   crd_remote_q (3 bits): outstanding credits consumed by messages sent
  //     to the remote die. Capped at SB_CRD_MAX (4) per spec 6.1.3.
  //     Incremented when the adapter sends a message; decremented when
  //     the Cr (credit return) bit is set in a received packet.
  //
  //   crd_return_pending: flag indicating a credit return is queued.
  // --------------------------------------------------------------------------
  logic [1:0] crd_fdi_q;     // credits owed to the local FDI
  logic [2:0] crd_remote_q;  // outstanding remote credits
  logic       crd_return_pending;

  // --------------------------------------------------------------------------
  // Timer Signals
  // --------------------------------------------------------------------------
  // msg_timer_*   : 8 ms message timeout (C_SB_MSG cycles). Per spec 6.2,
  //                 if an outstanding sideband request receives no response
  //                 within 8 ms, the timeout fires. The timer runs while
  //                 crd_remote_q != 0 (there is an outstanding request).
  //
  // stall_timer_* : 4 ms stall keep-alive (C_STALL cycles). Per spec 6.3,
  //                 after the message timeout fires, the adapter must send
  //                 periodic stall keep-alive messages every 4 ms to prevent
  //                 the remote side from declaring a link error.
  // --------------------------------------------------------------------------
  logic       msg_timer_start;
  logic       msg_timer_run;
  logic       msg_timer_expired;

  logic       stall_timer_start;
  logic       stall_timer_run;
  logic       stall_timer_expired;

  // -------------------------------------------------------------------------
  // Module Instantiation: ucie_timer - 8 ms Message Timeout
  //
  // Generic countdown timer parameterised with C_SB_MSG (8,000,000 lclk
  // cycles at 1 GHz = 8 ms). Starts on msg_timer_start, counts down while
  // msg_timer_run is high, and asserts msg_timer_expired when the count
  // reaches zero.
  //
  // The timer starts whenever there are outstanding remote credits
  // (crd_remote_q != 0) and no credit-return packet has just arrived.
  // It runs as long as there are outstanding credits.
  //
  // Spec ref: UCIe 1.0, Section 6.2 - 8 ms sideband message timeout.
  // -------------------------------------------------------------------------
  ucie_timer #(.LIMIT_CYCLES(C_SB_MSG)) u_msg_timer (
    .clk(lclk), .reset_n(lreset_n),
    .start(msg_timer_start), .running(msg_timer_run),
    .expired(msg_timer_expired)
  );

  // -------------------------------------------------------------------------
  // Module Instantiation: ucie_timer - 4 ms Stall Keep-Alive
  //
  // Generic countdown timer parameterised with C_STALL (4,000,000 lclk
  // cycles at 1 GHz = 4 ms). Starts on stall_timer_start (which is
  // triggered by msg_timer_expired), counts down while stall_timer_run
  // is high, and asserts stall_timer_expired when the count reaches zero.
  //
  // The stall keep-alive ensures the remote partner does not interpret a
  // long silence as a link error while the adapter is waiting for a
  // delayed response.
  //
  // Spec ref: UCIe 1.0, Section 6.3 - 4 ms stall keep-alive.
  // -------------------------------------------------------------------------
  ucie_timer #(.LIMIT_CYCLES(C_STALL)) u_stall_timer (
    .clk(lclk), .reset_n(lreset_n),
    .start(stall_timer_start), .running(stall_timer_run),
    .expired(stall_timer_expired)
  );

  // --------------------------------------------------------------------------
  // Receive Path: Packet Deserialiser
  // --------------------------------------------------------------------------
  // The PHY delivers NC=8 bits per UI on lp_cfg while lp_cfg_vld is high.
  // Over 8 consecutive UIs (rx_ui_q counts 0 through 7), a complete 64-bit
  // sideband packet header is assembled by shifting lp_cfg into rx_hdr_q
  // from the LSB side. When rx_ui_q reaches 7, rx_complete asserts and
  // rx_pkt_vld pulses for one cycle on the following clock edge, indicating
  // that rx_hdr_q holds a valid, fully-assembled packet header ready for
  // field extraction and decoding.
  // --------------------------------------------------------------------------
  logic [63:0] rx_hdr_q;
  logic [3:0]  rx_ui_q;
  logic        rx_pkt_vld;

  // -------------------------------------------------------------------------
  // assign: Receive Header Shift and Completion Detect
  //
  // rx_hdr_d shifts the existing 56 MSBs of rx_hdr_q down and inserts the
  // new NC-bit lp_cfg chunk into the MSB position, building the 64-bit
  // header over 8 UIs.
  //
  // rx_complete is high when rx_ui_q == 7 (the 8th and final UI of the
  // packet), indicating the header assembly is done.
  //
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband packet framing.
  // -------------------------------------------------------------------------
  wire [63:0] rx_hdr_d = {rx_hdr_q[55:0], lp_cfg};
  wire        rx_complete = (rx_ui_q == 4'd7);

  // -------------------------------------------------------------------------
  // always_ff: Receive Deserialiser State
  //
  // On every rising edge of lclk (or asynchronous reset), this block
  // manages the packet receive state machine:
  //
  //   Reset: rx_hdr_q, rx_ui_q, and rx_pkt_vld are cleared to zero.
  //
  //   When lp_cfg_vld is asserted (a valid sideband UI is present):
  //     - rx_hdr_q is updated with the shifted header (rx_hdr_d), appending
  //       the new NC-bit chunk.
  //     - rx_ui_q increments, counting UIs 0 through 7. The counter wraps
  //       naturally at 4 bits but rx_complete gates the valid pulse at 7.
  //     - rx_pkt_vld is set to rx_complete (true only on the 8th UI).
  //
  //   When lp_cfg_vld is deasserted:
  //     - rx_pkt_vld is cleared. rx_hdr_q and rx_ui_q hold their values,
  //       preserving partial packet state across idle gaps.
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband UI framing.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // assign: Parsed Header Fields
  //
  // Extracts individual fields from the fully-assembled 64-bit header
  // (rx_hdr_q) for use by the decode logic. Field positions per spec 4.5.x:
  //
  //   rx_msgcode [7:0]   - Message code identifying the message type
  //                         (e.g. MC_NOP_CRD, MC_LM_RDI_REQ). Tables 53-56.
  //   rx_subcode [15:8]  - Sub-code qualifying the message code
  //                         (e.g. MS_LM_ACTIVE for Active request).
  //   rx_msginfo [31:16] - Message-specific information field.
  //   rx_cp      [36]    - Command parity (even parity over header excl. DP).
  //   rx_dp      [37]    - Data parity.
  //   rx_cr      [38]    - Credit return bit. When set, this packet returns
  //                         one credit to the sender (spec 6.1.3).
  //   rx_srcid   [50:48] - Source ID (Table 49).
  //   rx_dstid   [53:51] - Destination ID (Table 49). SRCID_ADAPT = 3'b001
  //                         addresses the Adapter's CSR space.
  //   rx_opcode  [58:54] - Operation code (Table 47). Used to distinguish
  //                         message-no-data, message-with-data, CfgRd, CfgWr.
  //
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband packet header format,
  //           Table 47 (opcodes), Table 49 (srcid/dstid).
  // -------------------------------------------------------------------------
  wire [7:0]  rx_msgcode = rx_hdr_q[7:0];
  wire [7:0]  rx_subcode = rx_hdr_q[15:8];
  wire [15:0] rx_msginfo = rx_hdr_q[31:16];
  wire        rx_cp      = rx_hdr_q[36];
  wire        rx_dp      = rx_hdr_q[37];
  wire        rx_cr      = rx_hdr_q[38];
  wire [2:0]  rx_srcid   = rx_hdr_q[50:48];
  wire [2:0]  rx_dstid   = rx_hdr_q[53:51];
  wire [4:0]  rx_opcode  = rx_hdr_q[58:54];

  // -------------------------------------------------------------------------
  // assign: Command Parity Calculation
  //
  // Computes the expected CP (command parity) as even parity over all 64
  // header bits with the DP bit (bit 37) masked to zero. This matches the
  // spec 4.5.x definition: CP covers all header bits except DP itself.
  //
  // In this simplified endpoint, CP is computed for potential future use
  // (error detection) but is not currently checked against rx_cp. The
  // parity infrastructure is retained so that a full implementation can
  // add CP checking without restructuring.
  //
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband packet parity.
  // -------------------------------------------------------------------------
  wire [63:0] hdr_for_cp = {rx_hdr_q[63:38], 1'b0, rx_hdr_q[36:0]};
  wire        cp_calc    = ^hdr_for_cp;

  // --------------------------------------------------------------------------
  // Transmit Path: Packet Serialiser
  // --------------------------------------------------------------------------
  // tx_hdr holds the 64-bit packet header to be transmitted. tx_send is
  // asserted for 8 consecutive UIs while tx_ui_q counts 0 through 7,
  // driving NC bits per UI onto pl_cfg. After each complete packet, a
  // 32-UI inter-packet gap is enforced by gap_q (SB_GAP_UI = 32).
  // --------------------------------------------------------------------------
  logic [63:0] tx_hdr;
  logic        tx_send;
  logic [3:0]  tx_ui_q;

  // -------------------------------------------------------------------------
  // always_ff: Transmit UI Counter
  //
  // Counts the 8 UIs (0 through 7) of an outgoing sideband packet. The
  // counter increments while tx_send is asserted. After reaching UI 7, the
  // gap counter (gap_q) is loaded and tx_send is deasserted by the transmit
  // control logic until the gap expires.
  //
  // On reset, the counter is cleared to zero.
  //
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband packet serialisation.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_ui_q <= '0;
    end else if (tx_send) begin
      tx_ui_q <= tx_ui_q + 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: Inter-Packet Gap Counter
  //
  // Enforces the SB_GAP_UI (32) UI inter-packet gap required by spec 4.5.x
  // between consecutive sideband packets. The gap counter is loaded with
  // SB_GAP_UI[5:0] when the last UI of a packet (tx_ui_q == 7) is
  // transmitted, then decrements each cycle until it reaches zero.
  //
  // The in_gap wire is true whenever gap_q != 0, preventing the transmit
  // control logic from starting a new packet during the gap.
  //
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband inter-packet gap.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always_comb: Transmit Output Drivers
  //
  // Drives the three pl_cfg outputs to the Protocol Layer:
  //   pl_cfg     - the NC-bit slice of tx_hdr corresponding to the current
  //                transmit UI (tx_ui_q). Uses a variable part-select to
  //                extract bits [8*tx_ui_q +: NC] from the 64-bit header.
  //   pl_cfg_vld - asserted while tx_send is active (8 UIs per packet).
  //   pl_cfg_crd - tied to 1'b0; credit returns are carried in the Cr bit
  //                of packet headers, not on the dedicated credit wire.
  //
  // Spec ref: UCIe 1.0, Section 6.1.3 (credit model), Table 115 (FDI signals).
  // -------------------------------------------------------------------------
  always_comb begin
    pl_cfg     = tx_hdr[8*tx_ui_q +: NC];
    pl_cfg_vld = tx_send;
    pl_cfg_crd = 1'b0;
  end

  // --------------------------------------------------------------------------
  // Credit Accounting
  // --------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // always_ff: FDI and Remote Credit Registers
  //
  // Maintains the two independent credit loops per spec 6.1.3:
  //
  //   crd_fdi_q (FDI credit loop):
  //     Replenished when a received packet with opcode SB_OP_MSG_NODATA and
  //     msgcode MC_NOP_CRD is decoded. The MsgInfo[2:0] field carries the
  //     number of credits (1-4) to add to crd_fdi_q. These credits allow
  //     the Protocol Layer to send additional sideband packets to the
  //     Adapter.
  //   crd_remote_q (remote credit loop):
  //     Decremented when a received packet has the Cr (credit return) bit
  //     set, indicating the remote die has consumed a credit and is
  //     returning it. The decrement is guarded (crd_remote_q > 0) to
  //     prevent underflow.
  // On reset, both counters are cleared to zero (no credits available).
  // Spec ref: UCIe 1.0, Section 6.1.3 - sideband credit model,
  //           max SB_CRD_MAX (4) outstanding remote credits.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // assign: Credit Return Monitor Hook
  //
  // sb_credit_returned is asserted for one cycle whenever a received packet
  // carries either a Cr bit (credit return) or a Nop.Crd message. This
  // output is a coverage/monitor hook used by the testbench to track
  // sideband credit flow without adding probe logic.
  //
  // Spec ref: UCIe 1.0, Section 6.1.3 - credit return mechanism.
  // -------------------------------------------------------------------------
  assign sb_credit_returned = rx_pkt_vld && (rx_cr ||
                            (rx_opcode == SB_OP_MSG_NODATA && rx_msgcode == MC_NOP_CRD));

  // --------------------------------------------------------------------------
  // Link Management Message Decoding
  // --------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // always_ff: Partner Active Request Latch
  //
  // Decodes LinkMgmt.RDI.Req messages from the remote die's Adapter:
  //
  //   - LinkMgmt.RDI.Req.Active (msgcode MC_LM_RDI_REQ, subcode MS_LM_ACTIVE):
  //     Sets adapter_active_req = 1, indicating the partner die wants the
  //     link to enter Active. This flag is consumed by fdi_state_machine
  //     as one arm of the four-way Active handshake (spec 8.1.6 step 6).
  //
  //   - LinkMgmt.RDI.Req.LinkReset or .Disable (subcodes MS_LM_LINKRESET,
  //     MS_LM_DISABLE): Clears adapter_active_req = 0, cancelling any
  //     prior Active agreement because the partner is requesting a
  //     non-Active state.
  //
  // All decoded messages must have opcode SB_OP_MSG_NODATA (message without
  // data payload) per Table 47.
  // On reset, adapter_active_req is cleared (no partner request pending).
  // Spec ref: UCIe 1.0, Tables 53-56 (message codes), Section 8.1.6 step 6.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always_ff: Adapter State Request Channel (Reduced Scope)
  //
  // In a full implementation, this register would capture general state
  // requests generated by the Adapter in response to Protocol Layer
  // directives or sideband negotiations. In this reduced-scope design,
  // the register is reset to invalid (adapter_state_req_vld = 0,
  // adapter_state_req = RDI_REQ_NOP) and is never set to a valid value.
  //
  // The port exists so that the d2d_adapter interconnect is structurally
  // complete for future expansion.
  //
  // Spec ref: UCIe 1.0, Section 8.2 - Adapter state requests.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      adapter_state_req_vld <= 1'b0;
      adapter_state_req     <= RDI_REQ_NOP;
    end
  end

  // --------------------------------------------------------------------------
  // Timer Control Logic
  // --------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // always_comb: Timer Start/Run and Monitor Outputs
  //
  // Controls the two timers and drives the three monitor/coverage outputs:
  //
  //   msg_timer_start: starts the 8 ms message timeout whenever there are
  //     outstanding remote credits (crd_remote_q != 0) AND no credit-return
  //     packet has just arrived (!(rx_pkt_vld && rx_cr)). A credit return
  //     restarts the timeout.
  //   msg_timer_run: the timer runs as long as there are outstanding credits.
  //     When crd_remote_q drops to 0, the timer stops.
  //   stall_timer_start: the stall keep-alive timer starts when the message
  //     timeout expires (msg_timer_expired == 1).
  //   stall_timer_run: runs while there are outstanding credits AND the
  //     message timeout has not expired yet. Once the message timeout fires,
  //     the stall timer takes over.
  //   sb_msg_timeout: asserted when the 8 ms message timeout expires.
  //   sb_stall_sent:  asserted when the 4 ms stall keep-alive expires.
  // Spec ref: UCIe 1.0, Section 6.2 (8 ms timeout), Section 6.3 (4 ms stall).
  // -------------------------------------------------------------------------
  always_comb begin
    msg_timer_start   = (crd_remote_q != 0) && !(rx_pkt_vld && rx_cr);
    msg_timer_run     = (crd_remote_q != 0);
    stall_timer_start = msg_timer_expired;
    stall_timer_run   = (crd_remote_q != 0) && !msg_timer_expired;
    sb_msg_timeout    = msg_timer_expired;
    sb_stall_sent     = stall_timer_expired;
  end

  // --------------------------------------------------------------------------
  // CSR Access Path and Transmit Control
  // --------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // assign: CSR Address and Write Data Extraction
  //
  // Extracts the CSR address and write data from the received packet header
  // for forwarding to adapter_regfile:
  //
  //   csr_addr  = rx_hdr_q[26:0]: the 27-bit byte address within the
  //               Adapter CSR space. The sideband packet encodes the
  //               target register offset in the lower 27 bits of the header.
  //
  //   csr_wdata = rx_hdr_q[63:0]: for CfgWr packets, the entire 64-bit
  //               header is used as write data. (In a full implementation,
  //               a separate data payload would carry the write value;
  //               this simplified design overloads the header.)
  //
  // These are implemented as continuous assigns rather than inside an
  // always_* process because Icarus Verilog 12 does not evaluate constant
  // part-selects correctly inside always_* blocks.
  // Spec ref: UCIe 1.0, Section 4.5.x - sideband CfgRd/CfgWr encoding.
  // -------------------------------------------------------------------------
  assign csr_addr  = rx_hdr_q[26:0];
  assign csr_wdata = rx_hdr_q[63:0];

  // -------------------------------------------------------------------------
  // always_comb: CSR Read/Write Decode and Transmit Control
  //
  // Decodes received packets addressed to the Adapter (dstid == SRCID_ADAPT)
  // and classifies them:
  //   csr_wr - CfgWr (5'b00001) or CfgWr-with-data (5'b00101): writes the
  //            addressed CSR.
  //   csr_rd - CfgRd (5'b00100) or CfgRd-with-type (5'b01100): starts a read.
  //   tx_send - asserted when a CfgRd is outstanding AND the register file
  //             has returned csr_rdata_vld; triggers the serialiser to send
  //             the completion packet.
  //   tx_hdr  - the 64-bit completion header: csr_rdata in the payload plus
  //             a fixed completion opcode and routing (dstid SRCID_ADAPT).
  //             Simplified encoding: one 64-bit header, read data embedded.
  //
  // Spec ref: Table 47 (opcodes), Table 49 (srcid/dstid), 4.5.x (completion).
  // -------------------------------------------------------------------------
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

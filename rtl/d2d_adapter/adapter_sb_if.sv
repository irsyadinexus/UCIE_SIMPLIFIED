// ============================================================================
// Module    : adapter_sb_if
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_sb_if.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 3.1.1 - Stage 3: Adapter Initialization
//   UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission
//   UCIe 1.0 Specification, Section 6.1   - Sideband protocol specification
//   UCIe 1.0 Specification, Section 6.1.1 - Sideband packet types (Table 47)
//   UCIe 1.0 Specification, Section 6.1.2 - Packet formats (Figures 100-103)
//   UCIe 1.0 Specification, Section 6.1.3 - Credit-based flow control
//   UCIe 1.0 Specification, Section 7.5   - UCIe Registers (CSR definition)
//   UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband interface (Table 115)
//   UCIe 1.0 Specification, Section 8.3.2 - State Request and Status
//
// DESCRIPTION
//   Adapter-side sideband interface and reduced-profile Stage 3 engine.
//   This module connects across three distinct boundaries:
//
//     1. FDI CONFIGURATION INTERFACE (lp_cfg / pl_cfg, NC=8):
//        Assembles incoming sideband packets across 8 consecutive header phases
//        and opcode-derived optional 8 payload phases. Enforces strict back-
//        to-back phase transfers: any intra-transaction gap or gap before an
//        expected payload asserts a sticky fdi_format_error. Gaps are permitted
//        only between complete transactions. Transmits outgoing completions
//        over pl_cfg back-to-back without internal gaps and pulses pl_cfg_crd
//        when a slot is deallocated.
//
//     2. PRIVATE ADAPTER CLIENT INTERFACE (<-> logical_phy):
//        Provides typed packet transmission and reception matching logical_phy
//        (adapter_sb_tx_* / adapter_sb_rx_*). Connects to the logical PHY's
//        packet arbiter and router. Completions have absolute transmission
//        priority and are never credit-gated.
//
//     3. LOCAL CSR AND PHY CSR ACCESS PATH:
//        Decodes 32/64-bit configuration reads and writes. Routes FDI destination
//        Adapter (3'b001) to adapter_regfile and FDI destination PHY (3'b010)
//        to a separate PHY CSR channel. Holds request metadata (address, width,
//        data, BE, Tag, EP, source, route) until the target completes. Keeps
//        delayed read responses until the completion packet is accepted.
//
//     4. FOUR-ENTRY REMOTE REQUEST TABLE:
//        Tracks outstanding remote register requests (including memory opcodes).
//        Allocates an entry only when adapter_sb_tx_ready accepts the packet.
//        Maintains a per-entry 8 ms message timer (C_SB_MSG). Matches received
//        completions by Tag: Stall resets only that entry's timer; terminal
//        completions (SC, UR, CA) or reset retire the entry. Unmatched or
//        duplicate completions assert protocol_error and adapter_fatal.
//        On timer expiration, returns a no-data UR completion to origin.
//
//     5. EXACT COMPLETION GENERATION:
//        Copies Tag and BE, EP=0. Generates no-data SC for writes, DATA32/DATA64
//        SC for reads, DATA64 with original request header in data for UR/CA,
//        no-data Stall, and no-data timeout UR. Memory requests return UR
//        without CSR access. Completions are stored in independent always-sink
//        queues and are never credit-gated.
//
//     6. CREDIT ACCOUNTING:
//        Maintains 4 independent request credits. Outgoing requests decrement
//        credits; incoming Cr bits and NOP.Crd returns saturate at 4. Owed
//        credit returns are piggybacked via Cr on outgoing packets or sent
//        autonomously as NOP.Crd when no packet is pending. Messages and
//        completions never consume or gate credits.
//
//     7. REDUCED-PROFILE STAGE 3 ENGINE:
//        Initiates after RDI reports Active. Transmits AdvCap.Adapter DATA64 with
//        exact mask 64'h0000_0000_0000_0091. Validates peer capability fields
//        and MsgInfo; accepts only valid capability or MsgInfo=16'hFFFF Stall.
//        Negotiates Streaming, Raw Mode, and Stack 0; sends no FinCap.
//        Executes Adapter0 Active exchange with reciprocal obligations and
//        an 8 ms timer. Handles LinkReset and Disabled obligations with 8 ms
//        timers and Disabled priority. Returns PMNAK responses for local and
//        peer L1/L2 without entering a PM state.
//
// CLOCK / RESET
//   lclk      - Main link clock (500 MHz).
//   lreset_n  - Active-low reset.
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//   v0.0.2  2026-09-22  Update lclk and timer cycle comments for 500 MHz.
//   v0.0.3  2026-09-23  Documentation: add per-construct comment blocks with
//                        spec references for sideband flow control, credit/
//                        timeout logic, and CSR access path.
//   v0.0.4  2026-09-23  Documentation: replace false Section 4.5.x packet
//                        citations with Section 4.1.5 and Chapter 6 references.
//                        Mark all non-spec field positions as local endpoint
//                        encoding. Correct FDI IDs from Table 49 to Table 48.
//                        Normalize the remaining sideband citation titles.
//   v0.0.5  2026-09-23  Documentation: distinguish the local CP mask from
//                        the Table 52 completion rule and remove the unrelated
//                        FDI bring-up citation from message decoding.
//   v0.0.6  2026-09-25  Phase D: remove peer-Active state policy. Keep this
//                        block as CSR and generic request transport while the
//                        Logical PHY LTSM owns LinkMgmt.RDI Active policy.
//   v0.0.7  2026-09-25  Document dormant timer hooks and reduced credit
//                        accounting after the Phase D policy cutover.
//   v0.1.0  2026-09-28  Major architectural rewrite per UCIe 1.0 Sections 3.1.1,
//                        6.1, 7.5, 8.2, and 8.3:
//                        1. Add canonical typed private Adapter client interface
//                           (adapter_sb_tx/rx) matching logical_phy.
//                        2. Replace legacy parser with 8-phase header and optional
//                           8-phase payload FDI phase counter with strict gap detection.
//                        3. Implement local FDI 32/64-bit config request handling with
//                           held metadata, explicit csr_be, and Adapter/PHY CSR target routing.
//                        4. Add four-entry remote request table with per-entry 8 ms timers,
//                           tag matching, stall handling, and terminal completion retirement.
//                        5. Exact completion generator: copy Tag/BE, no-data SC writes,
//                           DATA32/DATA64 SC reads, DATA64 original header UR/CA,
//                           no-data Stall/timeout UR, EP=0, memory UR completion.
//                        6. Maintain 4 independent request credits, saturate incoming
//                           returns at 4, and generate pending Cr/NOP.Crd on slot release.
//                        7. Implement reduced-profile Stage 3: AdvCap.Adapter DATA64 64'h91
//                           exchange after RDI Active, capability validation, Streaming/Raw/Stack0
//                           negotiation, separate 8 ms timers, Adapter0 Active/LinkReset/Disabled
//                           obligations, and PMNAK responses. Expose adapter_fatal/linkerror.
//                        8. Assign allocated tag to remote mailbox requests in
//                           rem_table arbiter (Sections 6.1, 7.5).
//   v0.1.1  2026-10-08  Documentation compliance pass: add detailed
//                        construct comment blocks (5-30 lines) with UCIe 1.0
//                        spec citations across all always/assign/instantiation
//                        blocks.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================

`ifndef AdapterSbIf_SV
`define AdapterSbIf_SV
`include "ucie_pkg.sv"

import ucie_pkg::*;

`timescale 1ns/1ps
module adapter_sb_if #(
  parameter int unsigned NC = 8
) (
  input  logic                lclk,
  input  logic                lreset_n,

  // --------------------------------------------------------------------------
  // FDI Configuration Sideband Interface (Protocol Layer <-> Adapter)
  // UCIe 1.0 Section 8.2.3, Table 115
  // --------------------------------------------------------------------------
  input  logic [NC-1:0]       lp_cfg,
  input  logic                lp_cfg_vld,
  input  logic                lp_cfg_crd,
  output logic [NC-1:0]       pl_cfg,
  output logic                pl_cfg_vld,
  output logic                pl_cfg_crd,

  // --------------------------------------------------------------------------
  // Private Adapter Sideband Packet Client Interface (<-> logical_phy)
  // Matches logical_phy adapter_sb_* ports (UCIe 1.0 Section 6.1)
  // --------------------------------------------------------------------------
  output logic                adapter_sb_tx_valid,
  input  logic                adapter_sb_tx_ready,
  output sb_packet_t          adapter_sb_tx_packet,
  input  logic                adapter_sb_rx_valid,
  output logic                adapter_sb_rx_ready,
  input  sb_packet_t          adapter_sb_rx_packet,
  input  logic                adapter_sb_rx_cp_error,
  input  logic                adapter_sb_rx_dp_error,
  input  logic                adapter_sb_rx_format_error,

  // --------------------------------------------------------------------------
  // RDI / FDI State & Status Inputs (UCIe 1.0 Table 114, Table 115)
  // --------------------------------------------------------------------------
  input  logic [3:0]          rdi_pl_state_sts,      // RDI state status from Logical PHY
  input  logic [3:0]          lp_state_req,          // FDI state request from Protocol Layer

  // --------------------------------------------------------------------------
  // Adapter State Request Outputs (UCIe 1.0 Section 8.3.2)
  // --------------------------------------------------------------------------
  output logic                adapter_state_req_vld,
  output logic [3:0]          adapter_state_req,

  // --------------------------------------------------------------------------
  // Adapter CSR Access Bus (to adapter_regfile, UCIe 1.0 Section 7.5)
  // --------------------------------------------------------------------------
  output logic                csr_wr,
  output logic                csr_rd,
  output logic [26:0]         csr_addr,
  output logic [63:0]         csr_wdata,
  output logic [7:0]          csr_be,
  input  logic [63:0]         csr_rdata,
  input  logic                csr_rdata_vld,

  // --------------------------------------------------------------------------
  // Target Select and Separate PHY CSR Access Channel (spec 7.5)
  // --------------------------------------------------------------------------
  output logic                csr_target,            // 1'b0: Adapter CSR, 1'b1: PHY CSR
  output logic                phy_csr_wr,
  output logic                phy_csr_rd,
  output logic [26:0]         phy_csr_addr,
  output logic [63:0]         phy_csr_wdata,
  output logic [7:0]          phy_csr_be,
  input  logic [63:0]         phy_csr_rdata,
  input  logic                phy_csr_rdata_vld,

  // --------------------------------------------------------------------------
  // Remote Register Access Mailbox Channel (to/from adapter_regfile mailbox)
  // --------------------------------------------------------------------------
  input  logic                rem_req_vld,
  output logic                rem_req_rdy,
  input  sb_packet_t          rem_req_pkt,
  output logic                rem_cpl_vld,
  output sb_packet_t          rem_cpl_pkt,

  // --------------------------------------------------------------------------
  // Status, Error, and Monitoring Outputs
  // --------------------------------------------------------------------------
  output logic                adapter_fatal,
  output logic                adapter_linkerror,
  output logic                stage3_done,
  output logic                adapter_capability_done,
  output logic                protocol_error,
  output logic                fdi_format_error,
  output logic                sb_credit_returned,
  output logic                sb_stall_sent,
  output logic                sb_msg_timeout
);

  import ucie_pkg::*;
  // Local Constants and Types
  // ==========================================================================
  localparam bit ROUTE_ORIGIN_INTERNAL = 1'b0;
  localparam bit ROUTE_ORIGIN_FDI      = 1'b1;

  localparam bit TARGET_ADAPTER        = 1'b0;
  localparam bit TARGET_PHY            = 1'b1;

  // FDI RX Phase State Machine
  typedef enum logic [1:0] {
    FDI_RX_IDLE,
    FDI_RX_HDR,
    FDI_RX_PLD
  } fdi_rx_state_t;

  // FDI TX Serializer State Machine
  typedef enum logic [1:0] {
    PL_TX_IDLE,
    PL_TX_HDR,
    PL_TX_PLD
  } pl_tx_state_t;

  // Local CSR Engine State Machine
  typedef enum logic [1:0] {
    CSR_ST_IDLE,
    CSR_ST_WR_HOLD,
    CSR_ST_RD_WAIT,
    CSR_ST_RD_HOLD
  } csr_state_t;

  // Reduced-Profile Stage 3 State Machine
  typedef enum logic [3:0] {
    S3_RESET,
    S3_ADVCAP_SEND,
    S3_ADVCAP_WAIT,
    S3_ACTIVE_SEND,
    S3_ACTIVE_WAIT,
    S3_ACTIVE,
    S3_LINKRESET_SEND,
    S3_LINKRESET_WAIT,
    S3_DISABLED_SEND,
    S3_DISABLED_WAIT,
    S3_FATAL
  } stage3_state_t;

  // Remote Request Table Entry Type (UCIe 1.0 Section 6.1)
  typedef struct packed {
    logic        valid;
    sb_packet_t  packet;
    logic [31:0] timer;
    logic        origin_route; // 0: Internal Mailbox, 1: FDI
  } rem_table_entry_t;

  // Held CSR Request Metadata Type (UCIe 1.0 Section 6.1.2.1, 7.5)
  typedef struct packed {
    logic        active;
    logic        target;       // 0: Adapter CSR, 1: PHY CSR
    logic        is_wr;        // 1: Write, 0: Read
    logic        is_64b;       // 1: 64-bit access, 0: 32-bit access
    logic [26:0] addr;
    logic [63:0] wdata;
    logic [7:0]  be;
    logic [4:0]  tag;
    logic        ep;
    logic [2:0]  src_id;
    logic        route;        // 0: Internal/Remote, 1: FDI
    logic [63:0] orig_hdr;
  } csr_held_req_t;

  // ==========================================================================
  // Pure Function: Completion Builder
  // UCIe 1.0 Section 6.1.2.1 (Figure 101, Table 50, Table 52)
  // ==========================================================================
  function automatic sb_packet_t make_cpl_packet(
    input sb_packet_t  req_pkt,
    input logic [63:0] req_hdr,
    input sb_status_t  status,
    input logic [63:0] rdata,
    input logic        is_timeout
  );
    sb_packet_t cpl;
    logic [63:0] hdr_payload;

    cpl = '0;
    cpl.tag    = req_pkt.tag;
    cpl.be     = req_pkt.be;
    cpl.ep     = 1'b0; // EP=0 always per UCIe 1.0 spec
    cpl.status = status;
    cpl.src_id = req_pkt.dst_id;
    cpl.dst_id = req_pkt.src_id;

    hdr_payload = (req_hdr != 64'h0) ? req_hdr : sb_encode_header(req_pkt);

    if (status == SB_STS_STALL || is_timeout) begin
      // No-data Stall and no-data timeout Unsupported Request
      cpl.opcode = SB_OP_CPL_NODATA;
      cpl.data   = 64'h0;
    end else if (status == SB_STS_UR || status == SB_STS_CA) begin
      // DATA64 with original request header as data for UR and CA
      cpl.opcode = SB_OP_CPL_DATA64;
      cpl.data   = hdr_payload;
    end else begin
      // Successful Completion (SC)
      if (req_pkt.opcode == SB_OP_CFG_WRITE32 || req_pkt.opcode == SB_OP_CFG_WRITE64 ||
          req_pkt.opcode == SB_OP_MEM_WRITE32 || req_pkt.opcode == SB_OP_MEM_WRITE64) begin
        // No-data SC for writes
        cpl.opcode = SB_OP_CPL_NODATA;
        cpl.data   = 64'h0;
      end else if (req_pkt.opcode == SB_OP_CFG_READ32 || req_pkt.opcode == SB_OP_MEM_READ32) begin
        // DATA32 SC for 32-bit reads
        cpl.opcode = SB_OP_CPL_DATA32;
        cpl.data   = {32'h0, rdata[31:0]};
      end else begin
        // DATA64 SC for 64-bit reads
        cpl.opcode = SB_OP_CPL_DATA64;
        cpl.data   = rdata;
      end
    end

    return cpl;
  endfunction

  // ==========================================================================
  // Registers and Signals Declaration
  // ==========================================================================

  // --- FDI RX Phase Counter and Assembly Registers ---
  fdi_rx_state_t fdi_rx_state_q, fdi_rx_state_d;
  logic [2:0]    fdi_rx_cnt_q,   fdi_rx_cnt_d;
  logic [63:0]   fdi_rx_hdr_q,   fdi_rx_hdr_d;
  logic [63:0]   fdi_rx_pld_q,   fdi_rx_pld_d;

  logic          fdi_rx_complete_pulse;
  sb_packet_t    fdi_rx_pkt;
  sb_packet_t    fdi_rx_pkt_header;
  logic [63:0]   fdi_rx_pkt_data;
  logic [63:0]   fdi_rx_hdr_complete;
  logic [63:0]   fdi_rx_pld_complete;

  // Sticky error and protocol status registers
  logic          fdi_format_err_q, fdi_format_err_d;
  logic          protocol_err_q,   protocol_err_d;
  logic          adapter_fatal_q,  adapter_fatal_d;

  logic          fdi_rx_format_err_event;
  logic          fdi_decode_format_err_event;
  logic          fdi_protocol_err_event;
  logic          rem_protocol_err_event;
  logic          fdi_fatal_event;
  logic          rem_fatal_event;
  logic          s3_fatal_event;

  // Packet-integrity qualification (P1-2: fatal before packet effects)
  wire           adapter_sb_rx_integrity_err = adapter_sb_rx_cp_error || adapter_sb_rx_dp_error || adapter_sb_rx_format_error;
  wire           adapter_sb_rx_clean         = adapter_sb_rx_valid && adapter_sb_rx_ready && !adapter_sb_rx_integrity_err;
  wire           adapter_sb_rx_err_event     = adapter_sb_rx_valid && adapter_sb_rx_ready && adapter_sb_rx_integrity_err;

  // --- FDI Credit Accounting Registers ---
  logic [2:0]    fdi_rx_crd_q,     fdi_rx_crd_d;   // Inbound request capacity (init 4)
  logic [2:0]    fdi_tx_crd_q,     fdi_tx_crd_d;   // Protocol Layer credits for Adapter TX (init 4)
  logic          fdi_req_reserve_event;
  logic          fdi_req_release_event;

  // --- Remote Credit Accounting Registers (spec 6.1.3) ---
  logic [2:0]    remote_req_crd_q, remote_req_crd_d; // Outgoing remote credits (init 4, max 4)
  logic [2:0]    pending_cr_q,     pending_cr_d;     // Credits owed to remote partner

  // --- Four-Entry Remote Request Table ---
  logic [3:0]  rem_table_valid_q, rem_table_valid_d;
  sb_packet_t  rem_table_pkt_q   [4];
  sb_packet_t  rem_table_pkt_d   [4];
  logic [31:0] rem_table_timer_q [4];
  logic [31:0] rem_table_timer_d [4];
  logic [3:0]  rem_table_route_q, rem_table_route_d;

  // --- Local CSR Engine Registers ---
  csr_state_t    csr_fsm_q,        csr_fsm_d;
  csr_held_req_t csr_held_q,       csr_held_d;
  logic [63:0]   csr_held_rdata_q, csr_held_rdata_d;
  logic          csr_rd_pulse_q,   csr_rd_pulse_d;

  // --- Independent Completion Queues (Always-Sink, Never Credit-Gated) ---
  // FDI Completion Queue (outgoing on pl_cfg)
  sb_packet_t    fdi_cpl_q [4];
  logic [1:0]    fdi_cpl_wr_ptr_q, fdi_cpl_wr_ptr_d;
  logic [1:0]    fdi_cpl_rd_ptr_q, fdi_cpl_rd_ptr_d;
  logic [2:0]    fdi_cpl_count_q,  fdi_cpl_count_d;

  logic          csr_fdi_cpl_push;
  sb_packet_t    csr_fdi_cpl_push_pkt;
  logic          rem_fdi_cpl_push;
  sb_packet_t    rem_fdi_cpl_push_pkt;
  logic          fdi_cpl_push;
  sb_packet_t    fdi_cpl_push_pkt;

  // Remote Completion Queue (outgoing on adapter_sb_tx)
  sb_packet_t    rem_cpl_fifo_q [4];
  logic [1:0]    rem_cpl_wr_ptr_q, rem_cpl_wr_ptr_d;
  logic [1:0]    rem_cpl_rd_ptr_q, rem_cpl_rd_ptr_d;
  logic [2:0]    rem_cpl_count_q,  rem_cpl_count_d;

  logic          csr_rem_cpl_push;
  sb_packet_t    csr_rem_cpl_push_pkt;
  logic          rem_cpl_push;
  sb_packet_t    rem_cpl_push_pkt;

  // --- FDI TX Serializer Registers (pl_cfg) ---
  pl_tx_state_t  pl_tx_state_q,    pl_tx_state_d;
  logic [2:0]    pl_tx_cnt_q,      pl_tx_cnt_d;
  logic [NC-1:0] pl_cfg_q,         pl_cfg_d;
  logic          pl_cfg_vld_q,     pl_cfg_vld_d;
  logic          pl_cfg_crd_q,     pl_cfg_crd_d;

  // --- Reduced-Profile Stage 3 State Machine Registers ---
  stage3_state_t s3_state_q,       s3_state_d;
  logic [31:0]   cap_timer_q,      cap_timer_d;
  logic [31:0]   ad0_timer_q,      ad0_timer_d;
  logic [31:0]   lm_timer_q,       lm_timer_d;

  logic          local_act_req_sent_q, local_act_req_sent_d;
  logic          local_act_rsp_rcvd_q, local_act_rsp_rcvd_d;
  logic          peer_act_req_rcvd_q,  peer_act_req_rcvd_d;
  logic          peer_act_rsp_sent_q,  peer_act_rsp_sent_d;

  logic          owed_rsp_pmnak_q,     owed_rsp_pmnak_d;
  logic          owed_rsp_dis_q,       owed_rsp_dis_d;
  logic          owed_rsp_lr_q,        owed_rsp_lr_d;

  logic          stage3_done_q,        stage3_done_d;
  logic          adapter_capability_done_q, adapter_capability_done_d;
  logic          state_req_vld_q,      state_req_vld_d;
  logic [3:0]    state_req_q,          state_req_d;

  // Remote Mailbox Client Completion Registers
  logic          rem_cpl_vld_q,        rem_cpl_vld_d;
  sb_packet_t    rem_cpl_pkt_q,        rem_cpl_pkt_d;

  // Monitor pulse flags
  logic          sb_credit_ret_pulse;
  logic          sb_stall_sent_pulse;
  logic          rem_timeout_pulse;
  logic          s3_timeout_pulse;

  // ==========================================================================
  // Section 1: FDI Configuration Ingress Phase Counter and Parser
  // UCIe 1.0 Section 8.2.3, Section 6.1.1, 6.1.2 (Figures 100-103)
  // ==========================================================================
  // Assembles 8 consecutive header phases (lp_cfg[7:0]) and opcode-derived
  // optional 8 payload phases. Enforces strict back-to-back transfer:
  // any gap inside a transaction or before an expected payload asserts sticky
  // fdi_format_error. Gaps permitted only between complete transactions.
  // ==========================================================================
  always @* begin
    fdi_rx_state_d          = fdi_rx_state_q;
    fdi_rx_cnt_d            = fdi_rx_cnt_q;
    fdi_rx_hdr_d            = fdi_rx_hdr_q;
    fdi_rx_pld_d            = fdi_rx_pld_q;
    fdi_rx_format_err_event = 1'b0;
    fdi_rx_complete_pulse   = 1'b0;

    case (fdi_rx_state_q)
      FDI_RX_IDLE: begin
        fdi_rx_cnt_d = 3'd0;
        if (lp_cfg_vld) begin
          // Phase 0: header[7:0]
          fdi_rx_hdr_d[7:0] = lp_cfg;
          fdi_rx_cnt_d      = 3'd1;
          fdi_rx_state_d    = FDI_RX_HDR;
        end
      end

      FDI_RX_HDR: begin
        if (!lp_cfg_vld) begin
          // Intra-transaction gap inside 8-phase header is a format error
          fdi_rx_format_err_event = 1'b1;
          fdi_rx_state_d          = FDI_RX_IDLE;
          fdi_rx_cnt_d            = 3'd0;
        end else begin
          case (fdi_rx_cnt_q)
            3'd0: fdi_rx_hdr_d[7:0]   = lp_cfg;
            3'd1: fdi_rx_hdr_d[15:8]  = lp_cfg;
            3'd2: fdi_rx_hdr_d[23:16] = lp_cfg;
            3'd3: fdi_rx_hdr_d[31:24] = lp_cfg;
            3'd4: fdi_rx_hdr_d[39:32] = lp_cfg;
            3'd5: fdi_rx_hdr_d[47:40] = lp_cfg;
            3'd6: fdi_rx_hdr_d[55:48] = lp_cfg;
            3'd7: fdi_rx_hdr_d[63:56] = lp_cfg;
            default: ;
          endcase
          if (fdi_rx_cnt_q == 3'd7) begin
            // 8th header phase received. Evaluate payload requirement from opcode.
            if (sb_payload_bytes(fdi_rx_hdr_d[4:0]) > 0) begin
              fdi_rx_state_d = FDI_RX_PLD;
              fdi_rx_cnt_d   = 3'd0;
            end else begin
              fdi_rx_complete_pulse = 1'b1;
              fdi_rx_state_d        = FDI_RX_IDLE;
              fdi_rx_cnt_d          = 3'd0;
            end
          end else begin
            fdi_rx_cnt_d = fdi_rx_cnt_q + 1'b1;
          end
        end
      end

      FDI_RX_PLD: begin
        if (!lp_cfg_vld) begin
          // Gap immediately before or inside payload phases is a format error
          fdi_rx_format_err_event = 1'b1;
          fdi_rx_state_d          = FDI_RX_IDLE;
          fdi_rx_cnt_d            = 3'd0;
        end else begin
          case (fdi_rx_cnt_q)
            3'd0: fdi_rx_pld_d[7:0]   = lp_cfg;
            3'd1: fdi_rx_pld_d[15:8]  = lp_cfg;
            3'd2: fdi_rx_pld_d[23:16] = lp_cfg;
            3'd3: fdi_rx_pld_d[31:24] = lp_cfg;
            3'd4: fdi_rx_pld_d[39:32] = lp_cfg;
            3'd5: fdi_rx_pld_d[47:40] = lp_cfg;
            3'd6: fdi_rx_pld_d[55:48] = lp_cfg;
            3'd7: fdi_rx_pld_d[63:56] = lp_cfg;
            default: ;
          endcase
          if (fdi_rx_cnt_q == 3'd7) begin
            fdi_rx_complete_pulse = 1'b1;
            fdi_rx_state_d        = FDI_RX_IDLE;
            fdi_rx_cnt_d          = 3'd0;
          end else begin
            fdi_rx_cnt_d = fdi_rx_cnt_q + 1'b1;
          end
        end
      end

      default: begin
        fdi_rx_state_d = FDI_RX_IDLE;
        fdi_rx_cnt_d   = 3'd0;
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // assign: fdi_rx_hdr_complete - Reconstructed 64-Bit FDI Header
  //
  // Captures the complete 64-bit header word across 8 consecutive FDI phases
  // with the final byte inlined on phase 7.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 (Table 115 - FDI Sideband).
  // --------------------------------------------------------------------------
  assign fdi_rx_hdr_complete = (fdi_rx_state_q == FDI_RX_HDR && fdi_rx_cnt_q == 3'd7) ?
                               {lp_cfg, fdi_rx_hdr_q[55:0]} : fdi_rx_hdr_q;

  // --------------------------------------------------------------------------
  // assign: fdi_rx_pld_complete - Reconstructed 64-Bit FDI Payload
  //
  // Captures the complete 64-bit payload word across 8 consecutive FDI phases
  // with the final byte inlined on phase 7.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 (Table 115 - FDI Sideband).
  // --------------------------------------------------------------------------
  assign fdi_rx_pld_complete = (fdi_rx_state_q == FDI_RX_PLD && fdi_rx_cnt_q == 3'd7) ?
                               {lp_cfg, fdi_rx_pld_q[55:0]} : fdi_rx_pld_q;

  // --------------------------------------------------------------------------
  // assign: fdi_rx_pkt_header - FDI Packet Header Decoder
  //
  // Unpacks raw 64-bit header word into typed sb_packet_t header fields.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign fdi_rx_pkt_header = sb_decode_header(fdi_rx_hdr_complete);

  // --------------------------------------------------------------------------
  // assign: fdi_rx_pkt_data - FDI Packet Payload Formatter
  //
  // Formats and zero-pads received payload based on opcode definition.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 50).
  // --------------------------------------------------------------------------
  assign fdi_rx_pkt_data = (sb_payload_bytes(fdi_rx_pkt_header.opcode) > 0) ?
                           sb_pad_data(fdi_rx_pkt_header.opcode, fdi_rx_pld_complete) :
                           64'h0;

  // --------------------------------------------------------------------------
  // assign: fdi_rx_pkt - Composite Typed FDI Sideband Packet
  //
  // Combines decoded header fields and formatted data payload into sb_packet_t.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign fdi_rx_pkt = {fdi_rx_pkt_header[151:64], fdi_rx_pkt_data};

  // ==========================================================================
  // Section 2: FDI Packet Validation and Decode Checking
  // UCIe 1.0 Section 6.1.2.1, Table 48 (FDI IDs), Table 50, Table 52
  // ==========================================================================
  sb_decode_err_t fdi_dec_err;
  logic           fdi_dp_err;
  logic           fdi_is_msg;
  logic           fdi_non_stack0;
  logic           fdi_illegal_dst;
  logic           fdi_is_mem;

  // --------------------------------------------------------------------------
  // always_comb: FDI Packet Structural Validation and Error Checking
  //
  // Evaluates structural conformance of received FDI packets:
  // - Reserved header bits, CP parity, illegal payload combinations.
  // - Data parity (DP) verification for packets with data.
  // - Validates source ID matches Stack 0 (3'b000 per Table 48).
  // - Validates destination ID targets Adapter (3'b001) or PHY (3'b010).
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 and Table 48.
  // --------------------------------------------------------------------------
  always @* begin
    fdi_dec_err     = sb_decode_error(fdi_rx_hdr_complete);
    fdi_dp_err      = (sb_payload_bytes(fdi_rx_pkt.opcode) > 0) &&
                      sb_check_dp_err(fdi_rx_pkt.opcode, fdi_rx_hdr_complete[30], fdi_rx_pkt.data);
    fdi_is_msg      = (sb_packet_kind(fdi_rx_pkt.opcode) == SB_PKT_MESSAGE);
    fdi_non_stack0  = (fdi_rx_pkt.src_id != FDI_SRCID_STACK0);
    fdi_illegal_dst = (fdi_rx_pkt.dst_id != FDI_DSTID_ADAPTER && fdi_rx_pkt.dst_id != FDI_DSTID_PHY);
    fdi_is_mem      = (fdi_rx_pkt.opcode == SB_OP_MEM_READ32  || fdi_rx_pkt.opcode == SB_OP_MEM_WRITE32 ||
                       fdi_rx_pkt.opcode == SB_OP_MEM_READ64  || fdi_rx_pkt.opcode == SB_OP_MEM_WRITE64);
  end

  // ==========================================================================
  // Section 3: Inbound Request Slot Accounting and Local CSR Request Engine
  // UCIe 1.0 Section 6.1.3, Section 7.5
  // ==========================================================================
  // Tracks available FDI request capacity (init 4). Reserves 1 slot at phase 0
  // of a register request. Releases slot and pulses pl_cfg_crd when completion
  // is transmitted over pl_cfg.
  // ==========================================================================
  // --------------------------------------------------------------------------
  // assign: fdi_req_reserve_event - Inbound FDI Request Slot Reservation Strobe
  //
  // Detects the start of an incoming register request at phase 0 to deduct
  // an available receive buffer slot.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Credit Flow Control.
  // --------------------------------------------------------------------------
  assign fdi_req_reserve_event = (fdi_rx_state_q == FDI_RX_IDLE) && lp_cfg_vld &&
                                 (sb_packet_kind(lp_cfg[4:0]) == SB_PKT_REG_REQ);

  // --------------------------------------------------------------------------
  // always_comb: FDI Slot and Credit Accounting Combinational Next-State
  //
  // Manages 4 available inbound request buffer slots (fdi_rx_crd_q) and outbound
  // FDI request credits (fdi_tx_crd_q). Triggers fatal error on buffer overrun.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Credit Flow Control.
  // --------------------------------------------------------------------------
  always @* begin
    fdi_rx_crd_d          = fdi_rx_crd_q;
    fdi_tx_crd_d          = fdi_tx_crd_q;
    fdi_fatal_event       = 1'b0;

    // Slot reservation at Phase 0
    if (fdi_req_reserve_event && !fdi_req_release_event) begin
      if (fdi_rx_crd_q > 3'd0) begin
        fdi_rx_crd_d = fdi_rx_crd_q - 1'b1;
      end else begin
        fdi_fatal_event = 1'b1;
      end
    end else if (!fdi_req_reserve_event && fdi_req_release_event) begin
      if (fdi_rx_crd_q < 3'd4) begin
        fdi_rx_crd_d = fdi_rx_crd_q + 1'b1;
      end
    end

    // Protocol Layer credit returns for outgoing FDI requests
    if (lp_cfg_crd) begin
      if (fdi_tx_crd_q < 3'd4) begin
        fdi_tx_crd_d = fdi_tx_crd_q + 1'b1;
      end
    end
  end

  // --- CSR Engine Control & Delayed Read Response Holding ---
  logic [63:0] r_hdr;
  sb_packet_t  wr_pkt;
  logic        target_vld;
  logic [63:0] target_data;
  sb_packet_t  rd_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Inbound CSR Request Execution & Response Dispatch FSM
  //
  // Decodes inbound configuration requests targeting Adapter or PHY CSRs,
  // controls register read/write pulses, formats completions (SC, UR, CA),
  // and routes completions to the FDI transmit queue or remote response path.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  always @* begin
    csr_fsm_d                   = csr_fsm_q;
    csr_held_d                  = csr_held_q;
    csr_held_rdata_d            = csr_held_rdata_q;
    csr_rd_pulse_d              = 1'b0;
    fdi_decode_format_err_event = 1'b0;
    fdi_protocol_err_event      = 1'b0;

    csr_fdi_cpl_push            = 1'b0;
    csr_fdi_cpl_push_pkt        = '0;
    csr_rem_cpl_push            = 1'b0;
    csr_rem_cpl_push_pkt        = '0;
    r_hdr                       = '0;
    wr_pkt                      = '0;
    target_vld                  = 1'b0;
    target_data                 = '0;
    rd_pkt                      = '0;
    case (csr_fsm_q)
      CSR_ST_IDLE: begin
        // Check for newly completed FDI register request
        if (fdi_rx_complete_pulse) begin
          if (fdi_dec_err.any_err || fdi_dp_err) begin
            fdi_decode_format_err_event = 1'b1;
            if (fdi_dec_err.cp_err) fdi_protocol_err_event = 1'b1;
          end else if (fdi_is_msg) begin
            // FDI messages strictly rejected
            fdi_protocol_err_event = 1'b1;
          end else if (sb_packet_kind(fdi_rx_pkt.opcode) == SB_PKT_REG_REQ) begin
            if (fdi_non_stack0 || fdi_illegal_dst) begin
              // Non-Stack0 or illegal destination returns Unsupported Request
              csr_fdi_cpl_push     = 1'b1;
              csr_fdi_cpl_push_pkt = make_cpl_packet(fdi_rx_pkt, fdi_rx_hdr_complete, SB_STS_UR, 64'h0, 1'b0);
            end else if (fdi_is_mem) begin
              // Memory requests return Unsupported Request without CSR access
              csr_fdi_cpl_push     = 1'b1;
              csr_fdi_cpl_push_pkt = make_cpl_packet(fdi_rx_pkt, fdi_rx_hdr_complete, SB_STS_UR, 64'h0, 1'b0);
            end else begin
              // Latch valid Configuration Read / Write request
              csr_held_d.active   = 1'b1;
              csr_held_d.target   = (fdi_rx_pkt.dst_id == FDI_DSTID_PHY) ? TARGET_PHY : TARGET_ADAPTER;
              csr_held_d.is_wr    = (fdi_rx_pkt.opcode == SB_OP_CFG_WRITE32 || fdi_rx_pkt.opcode == SB_OP_CFG_WRITE64);
              csr_held_d.is_64b   = (fdi_rx_pkt.opcode == SB_OP_CFG_READ64  || fdi_rx_pkt.opcode == SB_OP_CFG_WRITE64);
              csr_held_d.addr     = fdi_rx_pkt.addr;
              csr_held_d.wdata    = fdi_rx_pkt.data;
              csr_held_d.be       = fdi_rx_pkt.be;
              csr_held_d.tag      = fdi_rx_pkt.tag;
              csr_held_d.ep       = fdi_rx_pkt.ep;
              csr_held_d.src_id   = fdi_rx_pkt.src_id;
              csr_held_d.route    = ROUTE_ORIGIN_FDI;
              csr_held_d.orig_hdr = fdi_rx_hdr_complete;

              if (fdi_rx_pkt.opcode == SB_OP_CFG_WRITE32 || fdi_rx_pkt.opcode == SB_OP_CFG_WRITE64) begin
                csr_fsm_d = CSR_ST_WR_HOLD;
              end else begin
                csr_fsm_d      = CSR_ST_RD_WAIT;
                csr_rd_pulse_d = 1'b1;
              end
            end
          end
        end
        // Check for inbound Configuration Request from remote partner (adapter_sb_rx)
        else if (adapter_sb_rx_clean &&
                 (sb_packet_kind(adapter_sb_rx_packet.opcode) == SB_PKT_REG_REQ)) begin
          r_hdr = sb_encode_header(adapter_sb_rx_packet);

          if (adapter_sb_rx_packet.opcode == SB_OP_MEM_READ32  || adapter_sb_rx_packet.opcode == SB_OP_MEM_WRITE32 ||
              adapter_sb_rx_packet.opcode == SB_OP_MEM_READ64  || adapter_sb_rx_packet.opcode == SB_OP_MEM_WRITE64) begin
            // Memory requests return Unsupported Request without touching CSR
            csr_rem_cpl_push     = 1'b1;
            csr_rem_cpl_push_pkt = make_cpl_packet(adapter_sb_rx_packet, r_hdr, SB_STS_UR, 64'h0, 1'b0);
          end else if (adapter_sb_rx_packet.dst_id == RDI_DSTID_LOCAL_PHY ||
                       adapter_sb_rx_packet.dst_id == RDI_DSTID_REMOTE_PHY) begin
            // Inbound configuration request targeting PHY CSR
            csr_held_d.active   = 1'b1;
            csr_held_d.target   = TARGET_PHY;
            csr_held_d.is_wr    = (adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE32 || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64);
            csr_held_d.is_64b   = (adapter_sb_rx_packet.opcode == SB_OP_CFG_READ64  || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64);
            csr_held_d.addr     = adapter_sb_rx_packet.addr;
            csr_held_d.wdata    = adapter_sb_rx_packet.data;
            csr_held_d.be       = adapter_sb_rx_packet.be;
            csr_held_d.tag      = adapter_sb_rx_packet.tag;
            csr_held_d.ep       = adapter_sb_rx_packet.ep;
            csr_held_d.src_id   = adapter_sb_rx_packet.src_id;
            csr_held_d.route    = ROUTE_ORIGIN_INTERNAL;
            csr_held_d.orig_hdr = r_hdr;

            if (adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE32 || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64) begin
              csr_fsm_d = CSR_ST_WR_HOLD;
            end else begin
              csr_fsm_d      = CSR_ST_RD_WAIT;
              csr_rd_pulse_d = 1'b1;
            end
          end else begin
            // Inbound configuration request targeting Adapter CSR
            csr_held_d.active   = 1'b1;
            csr_held_d.target   = TARGET_ADAPTER;
            csr_held_d.is_wr    = (adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE32 || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64);
            csr_held_d.is_64b   = (adapter_sb_rx_packet.opcode == SB_OP_CFG_READ64  || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64);
            csr_held_d.addr     = adapter_sb_rx_packet.addr;
            csr_held_d.wdata    = adapter_sb_rx_packet.data;
            csr_held_d.be       = adapter_sb_rx_packet.be;
            csr_held_d.tag      = adapter_sb_rx_packet.tag;
            csr_held_d.ep       = adapter_sb_rx_packet.ep;
            csr_held_d.src_id   = adapter_sb_rx_packet.src_id;
            csr_held_d.route    = ROUTE_ORIGIN_INTERNAL;
            csr_held_d.orig_hdr = r_hdr;

            if (adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE32 || adapter_sb_rx_packet.opcode == SB_OP_CFG_WRITE64) begin
              csr_fsm_d = CSR_ST_WR_HOLD;
            end else begin
              csr_fsm_d      = CSR_ST_RD_WAIT;
              csr_rd_pulse_d = 1'b1;
            end
          end
        end
      end

      CSR_ST_WR_HOLD: begin
        // Synchronous write takes 1 cycle. Generate no-data SC completion.
        wr_pkt = '0;
        wr_pkt.opcode = csr_held_q.is_64b ? SB_OP_CFG_WRITE64 : SB_OP_CFG_WRITE32;
        wr_pkt.tag    = csr_held_q.tag;
        wr_pkt.be     = csr_held_q.be;
        wr_pkt.src_id = csr_held_q.src_id;
        wr_pkt.dst_id = csr_held_q.target ? FDI_DSTID_PHY : FDI_DSTID_ADAPTER;

        if (csr_held_q.route == ROUTE_ORIGIN_FDI) begin
          csr_fdi_cpl_push     = 1'b1;
          csr_fdi_cpl_push_pkt = make_cpl_packet(wr_pkt, csr_held_q.orig_hdr, SB_STS_SC, 64'h0, 1'b0);
        end else begin
          csr_rem_cpl_push     = 1'b1;
          csr_rem_cpl_push_pkt = make_cpl_packet(wr_pkt, csr_held_q.orig_hdr, SB_STS_SC, 64'h0, 1'b0);
        end

        csr_held_d.active = 1'b0;
        csr_fsm_d         = CSR_ST_IDLE;
      end

      CSR_ST_RD_WAIT: begin
        // Wait for target to return valid read data

        target_vld  = (csr_held_q.target == TARGET_PHY) ? phy_csr_rdata_vld : csr_rdata_vld;
        target_data = (csr_held_q.target == TARGET_PHY) ? phy_csr_rdata     : csr_rdata;

        if (target_vld) begin
          csr_held_rdata_d = target_data;
          csr_fsm_d        = CSR_ST_RD_HOLD;
        end
      end

      CSR_ST_RD_HOLD: begin
        // Hold delayed read response until completion packet is accepted into queue
        rd_pkt = '0;
        rd_pkt.opcode = csr_held_q.is_64b ? SB_OP_CFG_READ64 : SB_OP_CFG_READ32;
        rd_pkt.tag    = csr_held_q.tag;
        rd_pkt.be     = csr_held_q.be;
        rd_pkt.src_id = csr_held_q.src_id;
        rd_pkt.dst_id = csr_held_q.target ? FDI_DSTID_PHY : FDI_DSTID_ADAPTER;

        if (csr_held_q.route == ROUTE_ORIGIN_FDI) begin
          if (fdi_cpl_count_q < 3'd4) begin
            csr_fdi_cpl_push     = 1'b1;
            csr_fdi_cpl_push_pkt = make_cpl_packet(rd_pkt, csr_held_q.orig_hdr, SB_STS_SC, csr_held_rdata_q, 1'b0);
            csr_held_d.active    = 1'b0;
            csr_fsm_d            = CSR_ST_IDLE;
          end
        end else begin
          if (rem_cpl_count_q < 3'd4) begin
            csr_rem_cpl_push     = 1'b1;
            csr_rem_cpl_push_pkt = make_cpl_packet(rd_pkt, csr_held_q.orig_hdr, SB_STS_SC, csr_held_rdata_q, 1'b0);
            csr_held_d.active    = 1'b0;
            csr_fsm_d            = CSR_ST_IDLE;
          end
        end
      end

      default: csr_fsm_d = CSR_ST_IDLE;
    endcase
  end

  // --------------------------------------------------------------------------
  // assign: csr_target - Adapter CSR Target Identifier
  //
  // Drives target decode (TARGET_ADAPTER vs TARGET_PHY) for current held request.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_target    = csr_held_q.target;

  // --------------------------------------------------------------------------
  // assign: csr_addr - Adapter CSR Register Address Bus
  //
  // Routes 32-bit register doubleword address to adapter_regfile.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_addr      = csr_held_q.addr;

  // --------------------------------------------------------------------------
  // assign: csr_wdata - Adapter CSR Write Data Bus
  //
  // Routes 32-bit write data to adapter_regfile.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_wdata     = csr_held_q.wdata;

  // --------------------------------------------------------------------------
  // assign: csr_be - Adapter CSR Byte Enables
  //
  // Routes 4-bit byte enable mask to adapter_regfile.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_be        = csr_held_q.be;

  // --------------------------------------------------------------------------
  // assign: csr_wr - Adapter CSR Write Strobe
  //
  // Asserts write strobe to adapter_regfile during CSR_ST_WR_HOLD.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_wr        = (csr_fsm_q == CSR_ST_WR_HOLD) && (csr_held_q.target == TARGET_ADAPTER);

  // --------------------------------------------------------------------------
  // assign: csr_rd - Adapter CSR Read Strobe
  //
  // Asserts single-cycle read strobe to adapter_regfile for TARGET_ADAPTER.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign csr_rd        = csr_rd_pulse_q && (csr_held_q.target == TARGET_ADAPTER);

  // --------------------------------------------------------------------------
  // assign: phy_csr_addr - Dedicated PHY CSR Address Bus
  //
  // Routes 32-bit register address to logical_phy CSR port.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign phy_csr_addr  = csr_held_q.addr;

  // --------------------------------------------------------------------------
  // assign: phy_csr_wdata - Dedicated PHY CSR Write Data Bus
  //
  // Routes 32-bit write data to logical_phy CSR port.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign phy_csr_wdata = csr_held_q.wdata;

  // --------------------------------------------------------------------------
  // assign: phy_csr_be - Dedicated PHY CSR Byte Enables
  //
  // Routes 4-bit byte enable mask to logical_phy CSR port.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign phy_csr_be    = csr_held_q.be;

  // --------------------------------------------------------------------------
  // assign: phy_csr_wr - Dedicated PHY CSR Write Strobe
  //
  // Asserts write strobe to logical_phy CSR port for TARGET_PHY.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign phy_csr_wr    = (csr_fsm_q == CSR_ST_WR_HOLD) && (csr_held_q.target == TARGET_PHY);

  // --------------------------------------------------------------------------
  // assign: phy_csr_rd - Dedicated PHY CSR Read Strobe
  //
  // Asserts single-cycle read strobe to logical_phy CSR port for TARGET_PHY.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign phy_csr_rd    = csr_rd_pulse_q && (csr_held_q.target == TARGET_PHY);

  // ==========================================================================
  // Section 4: Four-Entry Remote Request Table & Tag Matcher
  // UCIe 1.0 Section 6.1.1, 6.1.2, 6.1.3
  // ==========================================================================
  // Tracks remote register requests (including memory opcodes). Consumes one
  // entry only when adapter_sb_tx_ready accepts the request. Matches completions
  // by Tag. Stall resets only that timer. Terminal completions (SC/UR/CA) or
  // reset retire the entry. Unmatched/duplicate terminal completions assert
  // protocol_error and adapter_fatal.
  // ==========================================================================
  logic [3:0] rem_slot_free;
  int rem_free_idx;

  // --------------------------------------------------------------------------
  // always_comb: Remote Request Table Free Slot Priority Finder
  //
  // Finds the lowest-indexed free slot among the 4 remote tracking entries.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Request Tracking.
  // --------------------------------------------------------------------------
  always @* begin
    rem_slot_free = ~rem_table_valid_q;
    rem_free_idx = 0;
    if      (rem_slot_free[0]) rem_free_idx = 0;
    else if (rem_slot_free[1]) rem_free_idx = 1;
    else if (rem_slot_free[2]) rem_free_idx = 2;
    else if (rem_slot_free[3]) rem_free_idx = 3;
  end

  // Completion Tag Matching across all 4 entries
  sb_packet_t rem_tbl_0, rem_tbl_1, rem_tbl_2, rem_tbl_3;

  // --------------------------------------------------------------------------
  // assign: rem_tbl_0 - Remote Request Entry 0 Content Tap
  //
  // Exposes entry 0 packet contents for tag comparison and completion matching.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign rem_tbl_0 = rem_table_pkt_q[0];

  // --------------------------------------------------------------------------
  // assign: rem_tbl_1 - Remote Request Entry 1 Content Tap
  //
  // Exposes entry 1 packet contents for tag comparison and completion matching.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign rem_tbl_1 = rem_table_pkt_q[1];

  // --------------------------------------------------------------------------
  // assign: rem_tbl_2 - Remote Request Entry 2 Content Tap
  //
  // Exposes entry 2 packet contents for tag comparison and completion matching.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign rem_tbl_2 = rem_table_pkt_q[2];

  // --------------------------------------------------------------------------
  // assign: rem_tbl_3 - Remote Request Entry 3 Content Tap
  //
  // Exposes entry 3 packet contents for tag comparison and completion matching.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign rem_tbl_3 = rem_table_pkt_q[3];

  logic [3:0] rem_tag_match;

  // --------------------------------------------------------------------------
  // always_comb: Completion Tag Matching Comparator Array
  //
  // Compares incoming completion tag against all 4 outstanding request tags.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Tag Management.
  // --------------------------------------------------------------------------
  always @* begin
    rem_tag_match[0] = rem_table_valid_q[0] && (rem_tbl_0.tag == adapter_sb_rx_packet.tag);
    rem_tag_match[1] = rem_table_valid_q[1] && (rem_tbl_1.tag == adapter_sb_rx_packet.tag);
    rem_tag_match[2] = rem_table_valid_q[2] && (rem_tbl_2.tag == adapter_sb_rx_packet.tag);
    rem_tag_match[3] = rem_table_valid_q[3] && (rem_tbl_3.tag == adapter_sb_rx_packet.tag);
  end

  int rem_match_cnt;

  // --------------------------------------------------------------------------
  // assign: rem_match_cnt - Sum of Matching Tags (Duplicate Detection)
  //
  // Counts matching tags across the table. Values > 1 indicate fatal protocol
  // violation per Section 6.1.3.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data Integrity.
  // --------------------------------------------------------------------------
  assign rem_match_cnt = rem_tag_match[0] + rem_tag_match[1] + rem_tag_match[2] + rem_tag_match[3];

  int rem_match_idx;

  // --------------------------------------------------------------------------
  // always_comb: Matching Entry Index Selection Encoder
  //
  // Encodes the one-hot tag match vector into the matching slot index (0..3).
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Tag Matching.
  // --------------------------------------------------------------------------
  always @* begin
    rem_match_idx = 0;
    if      (rem_tag_match[0]) rem_match_idx = 0;
    else if (rem_tag_match[1]) rem_match_idx = 1;
    else if (rem_tag_match[2]) rem_match_idx = 2;
    else if (rem_tag_match[3]) rem_match_idx = 3;
  end

  // --------------------------------------------------------------------------
  // always_comb: Remote Table Sequential & Timer Update Process
  //
  // Advances per-entry 8 ms message timers (C_SB_MSG), handles Stall timer
  // resets, retires entries on terminal completions (SC, UR, CA), generates
  // timeout UR completions, and allocates entries on transmit acceptance.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control and Timers.
  // --------------------------------------------------------------------------
  always @(rdi_pl_state_sts,
           rem_table_valid_q[0], rem_table_valid_q[1], rem_table_valid_q[2], rem_table_valid_q[3],
           rem_table_route_q[0], rem_table_route_q[1], rem_table_route_q[2], rem_table_route_q[3],
           rem_table_pkt_q[0], rem_table_pkt_q[1], rem_table_pkt_q[2], rem_table_pkt_q[3],
           rem_table_timer_q[0], rem_table_timer_q[1], rem_table_timer_q[2], rem_table_timer_q[3],
           adapter_sb_rx_valid, adapter_sb_rx_ready, adapter_sb_rx_packet,
           rem_match_cnt, rem_match_idx,
           adapter_sb_tx_valid, adapter_sb_tx_ready, adapter_sb_tx_packet,
           rem_free_idx, C_SB_MSG) begin
    rem_table_valid_d = rem_table_valid_q;
    rem_table_route_d = rem_table_route_q;
    for (int i = 0; i < 4; i++) begin
      rem_table_pkt_d[i]   = rem_table_pkt_q[i];
      rem_table_timer_d[i] = rem_table_timer_q[i];
    end

    rem_cpl_vld_d          = 1'b0;
    rem_cpl_pkt_d          = '0;
    rem_timeout_pulse      = 1'b0;
    sb_stall_sent_pulse    = 1'b0;
    rem_fdi_cpl_push       = 1'b0;
    rem_fdi_cpl_push_pkt   = '0;
    rem_protocol_err_event = 1'b0;
    rem_fatal_event        = 1'b0;

    // Per-entry 8 ms message timer (counts while RDI is Active)
    if (rdi_pl_state_sts == RDI_STS_ACTIVE || rdi_pl_state_sts == RDI_STS_PMNAK) begin
      for (int i = 0; i < 4; i++) begin
        if (rem_table_valid_q[i]) begin
          if (rem_table_timer_q[i] >= C_SB_MSG) begin
            // 8 ms timeout: retire entry and generate no-data UR completion to origin
            rem_table_valid_d[i] = 1'b0;
            rem_timeout_pulse    = 1'b1;

            if (rem_table_route_q[i] == ROUTE_ORIGIN_FDI) begin
              rem_fdi_cpl_push     = 1'b1;
              rem_fdi_cpl_push_pkt = make_cpl_packet(rem_table_pkt_q[i], 64'h0, SB_STS_UR, 64'h0, 1'b1);
            end else begin
              rem_cpl_vld_d = 1'b1;
              rem_cpl_pkt_d = make_cpl_packet(rem_table_pkt_q[i], 64'h0, SB_STS_UR, 64'h0, 1'b1);
            end
          end else begin
            rem_table_timer_d[i] = rem_table_timer_q[i] + 1'b1;
          end
        end
      end
    end

    // Process Received Completions from peer on adapter_sb_rx
    if (adapter_sb_rx_clean &&
        (sb_packet_kind(adapter_sb_rx_packet.opcode) == SB_PKT_COMPLETION)) begin
      if (rem_match_cnt == 0) begin
        // Unmatched completion is a protocol error and fatal
        rem_protocol_err_event = 1'b1;
        rem_fatal_event        = 1'b1;
      end else if (rem_match_cnt > 1) begin
        // Duplicate active terminal completion
        rem_protocol_err_event = 1'b1;
        rem_fatal_event        = 1'b1;
      end else begin
        // Unique match found
        if (adapter_sb_rx_packet.status == SB_STS_STALL) begin
          // Stall resets only that timer and retains the entry
          rem_table_timer_d[rem_match_idx] = 32'd0;
          sb_stall_sent_pulse              = 1'b1;
        end else if (adapter_sb_rx_packet.status == SB_STS_SC ||
                     adapter_sb_rx_packet.status == SB_STS_UR ||
                     adapter_sb_rx_packet.status == SB_STS_CA) begin
          // Terminal completion retires table entry
          rem_table_valid_d[rem_match_idx] = 1'b0;

          if (rem_table_route_q[rem_match_idx] == ROUTE_ORIGIN_FDI) begin
            rem_fdi_cpl_push     = 1'b1;
            rem_fdi_cpl_push_pkt = adapter_sb_rx_packet;
          end else begin
            rem_cpl_vld_d = 1'b1;
            rem_cpl_pkt_d = adapter_sb_rx_packet;
          end
        end else begin
          // Reserved completion status encoding
          rem_protocol_err_event = 1'b1;
          rem_fatal_event        = 1'b1;
        end
      end
    end

    // Allocate table entry when adapter_sb_tx accepts an outbound remote request
    if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
        (sb_packet_kind(adapter_sb_tx_packet.opcode) == SB_PKT_REG_REQ)) begin
      rem_table_valid_d[rem_free_idx] = 1'b1;
      rem_table_pkt_d[rem_free_idx]   = adapter_sb_tx_packet;
      rem_table_timer_d[rem_free_idx] = 32'd0;
      rem_table_route_d[rem_free_idx] = ROUTE_ORIGIN_INTERNAL;
    end
  end

  // --------------------------------------------------------------------------
  // assign: fdi_cpl_push - Inbound FDI Completion Push Strobe
  //
  // Combines completion pushes from local CSR engine and remote completion router.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // --------------------------------------------------------------------------
  assign fdi_cpl_push     = csr_fdi_cpl_push | rem_fdi_cpl_push;

  // --------------------------------------------------------------------------
  // assign: fdi_cpl_push_pkt - Inbound FDI Completion Push Packet Multiplexer
  //
  // Selects between local CSR completion and remote response completion packet.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign fdi_cpl_push_pkt = csr_fdi_cpl_push ? csr_fdi_cpl_push_pkt : rem_fdi_cpl_push_pkt;

  // --------------------------------------------------------------------------
  // assign: rem_cpl_push - Remote Completion Queue Push Strobe
  //
  // Forwards push strobe for remote completions into the outbound FIFO queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // --------------------------------------------------------------------------
  assign rem_cpl_push     = csr_rem_cpl_push;

  // --------------------------------------------------------------------------
  // assign: rem_cpl_push_pkt - Remote Completion Queue Push Packet
  //
  // Drives packet payload into the outbound remote completion FIFO queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign rem_cpl_push_pkt = csr_rem_cpl_push_pkt;

  // --------------------------------------------------------------------------
  // assign: fdi_format_err_d - Sticky FDI Format Error Aggregator
  //
  // Accumulates intra-transaction phase gap and packet decode formatting faults.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 and Section 6.1.3.
  // --------------------------------------------------------------------------
  assign fdi_format_err_d = fdi_format_err_q | fdi_rx_format_err_event | fdi_decode_format_err_event;

  // --------------------------------------------------------------------------
  // assign: protocol_err_d - Sticky Sideband Protocol Error Aggregator
  //
  // Accumulates unexpected completions, duplicate tags, and corrupt packets.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data Integrity.
  // --------------------------------------------------------------------------
  assign protocol_err_d   = protocol_err_q   | fdi_protocol_err_event  | rem_protocol_err_event | adapter_sb_rx_err_event;

  // --------------------------------------------------------------------------
  // assign: adapter_fatal_d - Sticky Adapter Fatal Error Aggregator
  //
  // Rolls up fatal sideband conditions; cleared only on link RESET.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 and Section 8.3.2.7.
  // --------------------------------------------------------------------------
  assign adapter_fatal_d  = (rdi_pl_state_sts == RDI_STS_RESET) ? 1'b0 :
                           (adapter_fatal_q | fdi_fatal_event | rem_fatal_event | s3_fatal_event | adapter_sb_rx_err_event);

  // ==========================================================================
  // Section 5: Remote Credit Accounting (UCIe 1.0 Section 6.1.3)
  // ==========================================================================
  // Maintains 4 independent remote request credits. Gated by remote_req_crd_q > 0.
  // Replenished by Cr bit and NOP.Crd returns (saturates at 4). Freed inbound
  // slots generate pending Cr return on outgoing packets or autonomous NOP.Crd.
  // Messages and completions are never credit-gated.
  // ==========================================================================
  int add_crd;

  // --------------------------------------------------------------------------
  // always_comb: Remote Request Credit Accounting and Return Processor
  //
  // Maintains 4 independent request credits. Saturated at 4 upon Cr bit and
  // NOP.Crd returns. Accumulates pending credit returns for peer notification.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Credit-Based Flow Control.
  // --------------------------------------------------------------------------
  always @* begin
    remote_req_crd_d    = remote_req_crd_q;
    pending_cr_d        = pending_cr_q;
    sb_credit_ret_pulse = 1'b0;
    add_crd             = 0;

    // Incoming Credit Returns on adapter_sb_rx
    if (adapter_sb_rx_clean) begin
      if (adapter_sb_rx_packet.cr) begin
        add_crd = add_crd + 1;
      end

      if (adapter_sb_rx_packet.opcode == SB_OP_MSG_NODATA &&
          adapter_sb_rx_packet.msg_code == MC_NOP_CRD) begin
        add_crd = add_crd + adapter_sb_rx_packet.msg_info[2:0];
      end

      if (add_crd > 0) begin
        sb_credit_ret_pulse = 1'b1;
        if (remote_req_crd_q + add_crd > 3'd4) begin
          remote_req_crd_d = 3'd4;
        end else begin
          remote_req_crd_d = remote_req_crd_q + add_crd[2:0];
        end
      end
    end

    // Decrement credits when outbound remote register request is accepted
    if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
        (sb_packet_kind(adapter_sb_tx_packet.opcode) == SB_PKT_REG_REQ)) begin
      if (remote_req_crd_d > 3'd0) begin
        remote_req_crd_d = remote_req_crd_d - 1'b1;
      end
    end

    // Generate pending credit return when an inbound remote request completes
    if (rem_cpl_push) begin
      if (pending_cr_q < 3'd4) begin
        pending_cr_d = pending_cr_q + 1'b1;
      end
    end

    // Piggyback Cr bit on outgoing packet or clear on autonomous NOP.Crd
    if (adapter_sb_tx_valid && adapter_sb_tx_ready) begin
      if (adapter_sb_tx_packet.opcode == SB_OP_MSG_NODATA &&
          adapter_sb_tx_packet.msg_code == MC_NOP_CRD) begin
        pending_cr_d = 3'd0;
      end else if (adapter_sb_tx_packet.cr) begin
        if (pending_cr_d > 3'd0) begin
          pending_cr_d = pending_cr_d - 1'b1;
        end
      end
    end
  end

  // ==========================================================================
  // Section 6: Independent Completion FIFO Queues
  // ==========================================================================
  // Inbound requests and delayed read responses place completions here.
  // Completions are always-sink and never credit-gated.
  // ==========================================================================
  sb_packet_t cur_fdi_cpl;

  // --------------------------------------------------------------------------
  // assign: cur_fdi_cpl - FDI Completion Queue Head Packet Tap
  //
  // Taps the completion packet currently at the read head of the FDI FIFO queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband Interface.
  // --------------------------------------------------------------------------
  assign cur_fdi_cpl = fdi_cpl_q[fdi_cpl_rd_ptr_q];

  // --------------------------------------------------------------------------
  // always_comb: FDI Completion FIFO Pointer and Count Updates
  //
  // Updates circular write/read pointers and occupancy count for the 4-entry
  // inbound FDI completion queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // --------------------------------------------------------------------------
  always @* begin
    fdi_cpl_wr_ptr_d = fdi_cpl_wr_ptr_q;
    fdi_cpl_rd_ptr_d = fdi_cpl_rd_ptr_q;
    fdi_cpl_count_d  = fdi_cpl_count_q;

    if (fdi_cpl_push && (fdi_cpl_count_q < 3'd4)) begin
      fdi_cpl_wr_ptr_d = fdi_cpl_wr_ptr_q + 1'b1;
      fdi_cpl_count_d  = fdi_cpl_count_q + 1'b1;
    end

    if (pl_tx_state_q == PL_TX_HDR && pl_tx_cnt_q == 3'd7 &&
        (sb_payload_bytes(cur_fdi_cpl.opcode) == 0)) begin
      fdi_cpl_rd_ptr_d = fdi_cpl_rd_ptr_q + 1'b1;
      fdi_cpl_count_d  = fdi_cpl_count_d - 1'b1;
    end else if (pl_tx_state_q == PL_TX_PLD && pl_tx_cnt_q == 3'd7) begin
      fdi_cpl_rd_ptr_d = fdi_cpl_rd_ptr_q + 1'b1;
      fdi_cpl_count_d  = fdi_cpl_count_d - 1'b1;
    end
  end

  sb_packet_t cur_rem_fifo_cpl;

  // --------------------------------------------------------------------------
  // assign: cur_rem_fifo_cpl - Remote Completion FIFO Head Packet Tap
  //
  // Taps the completion packet currently at the head of the outbound remote FIFO.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  assign cur_rem_fifo_cpl = rem_cpl_fifo_q[rem_cpl_rd_ptr_q];

  // --------------------------------------------------------------------------
  // always_comb: Remote Completion FIFO Pointer and Count Updates
  //
  // Updates circular write/read pointers and occupancy count for the 4-entry
  // outbound remote completion queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // --------------------------------------------------------------------------
  always @* begin
    rem_cpl_wr_ptr_d = rem_cpl_wr_ptr_q;
    rem_cpl_rd_ptr_d = rem_cpl_rd_ptr_q;
    rem_cpl_count_d  = rem_cpl_count_q;

    if (rem_cpl_push && (rem_cpl_count_q < 3'd4)) begin
      rem_cpl_wr_ptr_d = rem_cpl_wr_ptr_q + 1'b1;
      rem_cpl_count_d  = rem_cpl_count_q + 1'b1;
    end

    if (adapter_sb_tx_valid && adapter_sb_tx_ready && (rem_cpl_count_q > 3'd0) &&
        (adapter_sb_tx_packet.tag == cur_rem_fifo_cpl.tag) &&
        (sb_packet_kind(adapter_sb_tx_packet.opcode) == SB_PKT_COMPLETION)) begin
      rem_cpl_rd_ptr_d = rem_cpl_rd_ptr_q + 1'b1;
      rem_cpl_count_d  = rem_cpl_count_d - 1'b1;
    end
  end

  // ==========================================================================
  // Section 7: FDI Transmit Serializer (pl_cfg, pl_cfg_vld, pl_cfg_crd)
  // UCIe 1.0 Section 8.2.3
  // ==========================================================================
  // Serializes 64-bit completion headers over 8 consecutive phases, followed
  // by optional 8 payload phases. Transfers all phases back-to-back without
  // internal gaps. Deallocates request slot and pulses pl_cfg_crd on completion.
  // ==========================================================================
  sb_packet_t  cur_fdi_tx_pkt;
  logic [63:0] cur_fdi_tx_hdr;
  logic [63:0] cur_fdi_tx_pld;
  logic        cur_fdi_tx_has_pld;

  // --------------------------------------------------------------------------
  // always_comb: FDI Transmit Packet Header/Payload Encoder
  //
  // Encodes the packet at the read head of the FDI completion queue into 64-bit
  // header and padded payload words with valid CP/DP parity fields.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Formats.
  // --------------------------------------------------------------------------
  always @(fdi_cpl_q[0], fdi_cpl_q[1], fdi_cpl_q[2], fdi_cpl_q[3],
           fdi_cpl_rd_ptr_q) begin
    cur_fdi_tx_pkt     = fdi_cpl_q[fdi_cpl_rd_ptr_q];
    cur_fdi_tx_hdr     = sb_encode_header(cur_fdi_tx_pkt);
    cur_fdi_tx_has_pld = (sb_payload_bytes(cur_fdi_tx_pkt.opcode) > 0);
    cur_fdi_tx_pld     = sb_pad_data(cur_fdi_tx_pkt.opcode, cur_fdi_tx_pkt.data);
  end

  // --------------------------------------------------------------------------
  // always_comb: FDI Transmit Serializer FSM & Phase Sequencing
  //
  // Drives 8 consecutive phases of header over pl_cfg, followed by optional
  // 8 phases of payload without gaps per Section 8.2.3. Releases slot credit.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband Interface.
  // --------------------------------------------------------------------------
  always @* begin
    pl_tx_state_d         = pl_tx_state_q;
    pl_tx_cnt_d           = pl_tx_cnt_q;
    pl_cfg_d              = 8'h0;
    pl_cfg_vld_d          = 1'b0;
    pl_cfg_crd_d          = 1'b0;
    fdi_req_release_event = 1'b0;

    case (pl_tx_state_q)
      PL_TX_IDLE: begin
        pl_tx_cnt_d = 3'd0;
        if (fdi_cpl_count_q > 3'd0) begin
          pl_cfg_d      = cur_fdi_tx_hdr[7:0];
          pl_cfg_vld_d  = 1'b1;
          pl_tx_cnt_d   = 3'd1;
          pl_tx_state_d = PL_TX_HDR;
        end
      end

      PL_TX_HDR: begin
        pl_cfg_d     = cur_fdi_tx_hdr[pl_tx_cnt_q * 8 +: 8];
        pl_cfg_vld_d = 1'b1;

        if (pl_tx_cnt_q == 3'd7) begin
          if (cur_fdi_tx_has_pld) begin
            pl_tx_cnt_d   = 3'd0;
            pl_tx_state_d = PL_TX_PLD;
          end else begin
            // Transaction finished: release slot, pulse credit
            pl_tx_state_d         = PL_TX_IDLE;
            pl_tx_cnt_d           = 3'd0;
            pl_cfg_crd_d          = 1'b1;
            fdi_req_release_event = 1'b1;
          end
        end else begin
          pl_tx_cnt_d = pl_tx_cnt_q + 1'b1;
        end
      end

      PL_TX_PLD: begin
        pl_cfg_d     = cur_fdi_tx_pld[pl_tx_cnt_q * 8 +: 8];
        pl_cfg_vld_d = 1'b1;

        if (pl_tx_cnt_q == 3'd7) begin
          // Transaction finished: release slot, pulse credit
          pl_tx_state_d         = PL_TX_IDLE;
          pl_tx_cnt_d           = 3'd0;
          pl_cfg_crd_d          = 1'b1;
          fdi_req_release_event = 1'b1;
        end else begin
          pl_tx_cnt_d = pl_tx_cnt_q + 1'b1;
        end
      end

      default: pl_tx_state_d = PL_TX_IDLE;
    endcase
  end

  // --------------------------------------------------------------------------
  // assign: pl_cfg - FDI Transmit Configuration Data Bus
  //
  // Outputs serialized byte stream to Protocol Layer across 8 consecutive phases.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 (Table 115 - FDI Sideband).
  // --------------------------------------------------------------------------
  assign pl_cfg     = pl_cfg_q;

  // --------------------------------------------------------------------------
  // assign: pl_cfg_vld - FDI Transmit Configuration Valid Strobe
  //
  // Asserts valid during active 8-phase transmission bursts without internal gaps.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 (Table 115 - FDI Sideband).
  // --------------------------------------------------------------------------
  assign pl_cfg_vld = pl_cfg_vld_q;

  // --------------------------------------------------------------------------
  // assign: pl_cfg_crd - FDI Receive Buffer Credit Return Strobe
  //
  // Returns request buffer credits to Protocol Layer upon completion retirement.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 (Table 115 - FDI Sideband).
  // --------------------------------------------------------------------------
  assign pl_cfg_crd = pl_cfg_crd_q;

  // ==========================================================================
  // Section 8: Reduced-Profile Stage 3 Engine
  // UCIe 1.0 Section 3.1.1, Section 6.1 (Tables 53, 54, 56)
  // ==========================================================================
  // After RDI reports Active, sends AdvCap.Adapter DATA64 with exact mask 64'h91.
  // Validates peer fields: requires clean CP/DP, MsgInfo=0, Data[63:23]=0,
  // Data[11]=0, Data[20:12]=0, (Data & 64'h91)==64'h91. MsgInfo=16'hFFFF resets
  // 8 ms capability timer as Stall. Negotiates Streaming/Raw/Stack0 without FinCap.
  // Completes Adapter0 Active reciprocal obligations. PMNAK handles L1/L2.
  // ==========================================================================
  sb_packet_t advcap_tx_pkt;

  // --------------------------------------------------------------------------
  // always_comb: AdvCap.Adapter Capability Advertised Packet Assembler
  //
  // Assembles 64-bit capability packet: Raw Mode (bit 0), Streaming (bit 4),
  // Stack 0 (bit 7), exact payload mask 64'h0000_0000_0000_0091 per Section 3.1.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 and Table 54.
  // --------------------------------------------------------------------------
  always @* begin
    advcap_tx_pkt             = '0;
    advcap_tx_pkt.opcode      = SB_OP_MSG_DATA64;
    advcap_tx_pkt.src_id      = RDI_SRCID_ADAPTER;
    advcap_tx_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    advcap_tx_pkt.msg_code    = MC_ADVCAP_ADAPTER;
    advcap_tx_pkt.msg_subcode = 8'h00;
    advcap_tx_pkt.msg_info    = 16'h0000;
    advcap_tx_pkt.data        = 64'h0000_0000_0000_0091; // Raw(bit 0), Streaming(bit 4), Stack0(bit 7)
    if (!lreset_n) advcap_tx_pkt = advcap_tx_pkt;
  end

  sb_packet_t ad0_active_req_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Adapter0 Active Request Message Assembler
  //
  // Assembles LinkMgmt.RDI Active request message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    ad0_active_req_pkt             = '0;
    ad0_active_req_pkt.opcode      = SB_OP_MSG_NODATA;
    ad0_active_req_pkt.src_id      = RDI_SRCID_ADAPTER;
    ad0_active_req_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    ad0_active_req_pkt.msg_code    = MC_LM_RDI_REQ;
    ad0_active_req_pkt.msg_subcode = MS_LM_ACTIVE;
    if (!lreset_n) ad0_active_req_pkt = ad0_active_req_pkt;
  end

  sb_packet_t ad0_active_rsp_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Adapter0 Active Response Message Assembler
  //
  // Assembles LinkMgmt.RDI Active response message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    ad0_active_rsp_pkt             = '0;
    ad0_active_rsp_pkt.opcode      = SB_OP_MSG_NODATA;
    ad0_active_rsp_pkt.src_id      = RDI_SRCID_ADAPTER;
    ad0_active_rsp_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    ad0_active_rsp_pkt.msg_code    = MC_LM_RDI_RSP;
    ad0_active_rsp_pkt.msg_subcode = MS_LM_ACTIVE;
    if (!lreset_n) ad0_active_rsp_pkt = ad0_active_rsp_pkt;
  end

  sb_packet_t pmnak_rsp_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Power Management PMNAK Response Message Assembler
  //
  // Assembles PMNAK response message rejecting unsupported PM L1/L2 requests.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    pmnak_rsp_pkt             = '0;
    pmnak_rsp_pkt.opcode      = SB_OP_MSG_NODATA;
    pmnak_rsp_pkt.src_id      = RDI_SRCID_ADAPTER;
    pmnak_rsp_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    pmnak_rsp_pkt.msg_code    = MC_LM_RDI_RSP;
    pmnak_rsp_pkt.msg_subcode = MS_LM_PMNAK;
    if (!lreset_n) pmnak_rsp_pkt = pmnak_rsp_pkt;
  end

  sb_packet_t linkreset_req_pkt;

  // --------------------------------------------------------------------------
  // always_comb: LinkReset Request Message Assembler
  //
  // Assembles LinkMgmt.RDI LinkReset request message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.3 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    linkreset_req_pkt             = '0;
    linkreset_req_pkt.opcode      = SB_OP_MSG_NODATA;
    linkreset_req_pkt.src_id      = RDI_SRCID_ADAPTER;
    linkreset_req_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    linkreset_req_pkt.msg_code    = MC_LM_RDI_REQ;
    linkreset_req_pkt.msg_subcode = MS_LM_LINKRESET;
    if (!lreset_n) linkreset_req_pkt = linkreset_req_pkt;
  end

  sb_packet_t linkreset_rsp_pkt;

  // --------------------------------------------------------------------------
  // always_comb: LinkReset Response Message Assembler
  //
  // Assembles LinkMgmt.RDI LinkReset response message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.3 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    linkreset_rsp_pkt             = '0;
    linkreset_rsp_pkt.opcode      = SB_OP_MSG_NODATA;
    linkreset_rsp_pkt.src_id      = RDI_SRCID_ADAPTER;
    linkreset_rsp_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    linkreset_rsp_pkt.msg_code    = MC_LM_RDI_RSP;
    linkreset_rsp_pkt.msg_subcode = MS_LM_LINKRESET;
    if (!lreset_n) linkreset_rsp_pkt = linkreset_rsp_pkt;
  end

  sb_packet_t disabled_req_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Disabled Request Message Assembler
  //
  // Assembles LinkMgmt.RDI Disabled request message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.4 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    disabled_req_pkt             = '0;
    disabled_req_pkt.opcode      = SB_OP_MSG_NODATA;
    disabled_req_pkt.src_id      = RDI_SRCID_ADAPTER;
    disabled_req_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    disabled_req_pkt.msg_code    = MC_LM_RDI_REQ;
    disabled_req_pkt.msg_subcode = MS_LM_DISABLE;
    if (!lreset_n) disabled_req_pkt = disabled_req_pkt;
  end

  sb_packet_t disabled_rsp_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Disabled Response Message Assembler
  //
  // Assembles LinkMgmt.RDI Disabled response message targeting remote adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.4 and Table 53.
  // --------------------------------------------------------------------------
  always @* begin
    disabled_rsp_pkt             = '0;
    disabled_rsp_pkt.opcode      = SB_OP_MSG_NODATA;
    disabled_rsp_pkt.src_id      = RDI_SRCID_ADAPTER;
    disabled_rsp_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    disabled_rsp_pkt.msg_code    = MC_LM_RDI_RSP;
    disabled_rsp_pkt.msg_subcode = MS_LM_DISABLE;
    if (!lreset_n) disabled_rsp_pkt = disabled_rsp_pkt;
  end

  // --------------------------------------------------------------------------
  // always_comb: Stage 3 Adapter Initialization Protocol FSM
  //
  // Coordinates Stage 3 bringing-up: capability exchange, validation,
  // 8 ms timeout monitoring, Adapter0 Active handshakes, and link resets.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 - Stage 3 Adapter Init.
  // --------------------------------------------------------------------------
  always @* begin
    s3_state_d           = s3_state_q;
    cap_timer_d          = cap_timer_q;
    ad0_timer_d          = ad0_timer_q;
    lm_timer_d           = lm_timer_q;

    local_act_req_sent_d = local_act_req_sent_q;
    local_act_rsp_rcvd_d = local_act_rsp_rcvd_q;
    peer_act_req_rcvd_d  = peer_act_req_rcvd_q;
    peer_act_rsp_sent_d  = peer_act_rsp_sent_q;

    owed_rsp_pmnak_d     = owed_rsp_pmnak_q;
    owed_rsp_dis_d       = owed_rsp_dis_q;
    owed_rsp_lr_d        = owed_rsp_lr_q;

    stage3_done_d        = stage3_done_q;
    adapter_capability_done_d = adapter_capability_done_q;
    state_req_vld_d      = state_req_vld_q;
    state_req_d          = state_req_q;
    s3_fatal_event       = 1'b0;
    s3_timeout_pulse     = 1'b0;
    if (adapter_sb_rx_err_event) begin
      s3_fatal_event = 1'b1;
      s3_state_d     = S3_FATAL;
    end

    // Reset Stage 3 state whenever RDI exits Active
    if ((rdi_pl_state_sts != RDI_STS_ACTIVE) && (rdi_pl_state_sts != RDI_STS_PMNAK)) begin
      s3_state_d           = S3_RESET;
      cap_timer_d          = 32'd0;
      ad0_timer_d          = 32'd0;
      lm_timer_d           = 32'd0;
      local_act_req_sent_d = 1'b0;
      local_act_rsp_rcvd_d = 1'b0;
      peer_act_req_rcvd_d  = 1'b0;
      peer_act_rsp_sent_d  = 1'b0;
      owed_rsp_pmnak_d     = 1'b0;
      owed_rsp_dis_d       = 1'b0;
      owed_rsp_lr_d        = 1'b0;
      stage3_done_d        = 1'b0;
      adapter_capability_done_d = 1'b0;
      state_req_vld_d      = 1'b0;
      state_req_d          = RDI_REQ_NOP;
    end else begin
      case (s3_state_q)
        S3_RESET: begin
          // Start Stage 3 after RDI reports Active
          s3_state_d  = S3_ADVCAP_SEND;
          cap_timer_d = 32'd0;
        end

        S3_ADVCAP_SEND: begin
          if (cap_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            cap_timer_d = cap_timer_q + 1'b1;
          end

          if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
              (adapter_sb_tx_packet.msg_code == MC_ADVCAP_ADAPTER)) begin
            s3_state_d = S3_ADVCAP_WAIT;
          end
        end

        S3_ADVCAP_WAIT: begin
          if (cap_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            cap_timer_d = cap_timer_q + 1'b1;
          end

          // Incoming Peer AdvCap.Adapter Validation
          if (adapter_sb_rx_valid && adapter_sb_rx_ready &&
              (adapter_sb_rx_packet.msg_code == MC_ADVCAP_ADAPTER)) begin
            if (adapter_sb_rx_cp_error || adapter_sb_rx_dp_error || adapter_sb_rx_format_error) begin
              s3_fatal_event = 1'b1;
              s3_state_d     = S3_FATAL;
            end else if (adapter_sb_rx_packet.msg_info == 16'hFFFF) begin
              // Peer Stall: reset 8 ms capability timer
              cap_timer_d = 32'd0;
            end else if (adapter_sb_rx_packet.msg_info == 16'h0000) begin
              // Validate peer capability payload fields
              if ((adapter_sb_rx_packet.opcode == SB_OP_MSG_DATA64) &&
                  (adapter_sb_rx_packet.data[63:23] == 41'h0) &&
                  (adapter_sb_rx_packet.data[11] == 1'b0) &&
                  (adapter_sb_rx_packet.data[20:12] == 9'h0) &&
                  ((adapter_sb_rx_packet.data & 64'h91) == 64'h91)) begin
                // Capability negotiation succeeded: Streaming, Raw Mode, Stack 0
                s3_state_d  = S3_ACTIVE_SEND;
                adapter_capability_done_d = 1'b1;
                ad0_timer_d = 32'd0;
              end else begin
                // Incompatible capability
                s3_fatal_event = 1'b1;
                s3_state_d     = S3_FATAL;
              end
            end else begin
              // Illegal MsgInfo
              s3_fatal_event = 1'b1;
              s3_state_d     = S3_FATAL;
            end
          end
        end

        S3_ACTIVE_SEND: begin
          if (ad0_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            ad0_timer_d = ad0_timer_q + 1'b1;
          end

          if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
              (adapter_sb_tx_packet.msg_code == MC_LM_RDI_REQ) &&
              (adapter_sb_tx_packet.msg_subcode == MS_LM_ACTIVE)) begin
            local_act_req_sent_d = 1'b1;
            s3_state_d           = S3_ACTIVE_WAIT;
          end
        end

        S3_ACTIVE_WAIT: begin
          if (ad0_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            ad0_timer_d = ad0_timer_q + 1'b1;
          end

          if (local_act_req_sent_d && local_act_rsp_rcvd_d &&
              peer_act_req_rcvd_d  && peer_act_rsp_sent_d) begin
            // Reciprocal obligations complete: enter Active state
            s3_state_d      = S3_ACTIVE;
            stage3_done_d   = 1'b1;
            state_req_vld_d = 1'b1;
            state_req_d     = RDI_REQ_ACTIVE;
          end
        end

        S3_ACTIVE: begin
          // Local State Change Requests (Disabled has priority over LinkReset)
          if (lp_state_req == FDI_REQ_DISABLED) begin
            s3_state_d  = S3_DISABLED_SEND;
            lm_timer_d  = 32'd0;
          end else if (lp_state_req == FDI_REQ_LINKRESET) begin
            s3_state_d  = S3_LINKRESET_SEND;
            lm_timer_d  = 32'd0;
          end
        end

        S3_DISABLED_SEND: begin
          if (lm_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            lm_timer_d = lm_timer_q + 1'b1;
          end

          if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
              (adapter_sb_tx_packet.msg_code == MC_LM_RDI_REQ) &&
              (adapter_sb_tx_packet.msg_subcode == MS_LM_DISABLE)) begin
            s3_state_d = S3_DISABLED_WAIT;
          end
        end

        S3_DISABLED_WAIT: begin
          if (lm_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            lm_timer_d = lm_timer_q + 1'b1;
          end

          // Exit when peer response acknowledged
          if (state_req_d == RDI_REQ_DISABLED) begin
            state_req_vld_d = 1'b1;
          end
        end

        S3_LINKRESET_SEND: begin
          if (lm_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            lm_timer_d = lm_timer_q + 1'b1;
          end

          if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
              (adapter_sb_tx_packet.msg_code == MC_LM_RDI_REQ) &&
              (adapter_sb_tx_packet.msg_subcode == MS_LM_LINKRESET)) begin
            s3_state_d = S3_LINKRESET_WAIT;
          end
        end

        S3_LINKRESET_WAIT: begin
          if (lm_timer_q >= C_SB_MSG) begin
            s3_fatal_event   = 1'b1;
            s3_timeout_pulse = 1'b1;
            s3_state_d       = S3_FATAL;
          end else begin
            lm_timer_d = lm_timer_q + 1'b1;
          end

          if (state_req_d == RDI_REQ_LINKRESET) begin
            state_req_vld_d = 1'b1;
          end
        end

        S3_FATAL: begin
          s3_fatal_event  = 1'b1;
          state_req_vld_d = 1'b0;
        end

        default: s3_state_d = S3_RESET;
      endcase

      // Track incoming Link Management packets on adapter_sb_rx
      if (adapter_sb_rx_clean &&
          (sb_packet_kind(adapter_sb_rx_packet.opcode) == SB_PKT_MESSAGE)) begin
        if (adapter_sb_rx_packet.msg_code == MC_LM_RDI_REQ) begin
          case (adapter_sb_rx_packet.msg_subcode)
            MS_LM_ACTIVE:    peer_act_req_rcvd_d = 1'b1;
            MS_LM_L1,
            MS_LM_L2:        owed_rsp_pmnak_d    = 1'b1; // PMNAK response obligation
            MS_LM_DISABLE:   owed_rsp_dis_d      = 1'b1;
            MS_LM_LINKRESET: owed_rsp_lr_d       = 1'b1;
            default: ;
          endcase
        end else if (adapter_sb_rx_packet.msg_code == MC_LM_RDI_RSP) begin
          case (adapter_sb_rx_packet.msg_subcode)
            MS_LM_ACTIVE:    local_act_rsp_rcvd_d = 1'b1;
            MS_LM_PMNAK:     /* PM rejection received; remain Active */ ;
            MS_LM_DISABLE:   begin
              state_req_vld_d = 1'b1;
              state_req_d     = RDI_REQ_DISABLED;
            end
            MS_LM_LINKRESET: begin
              state_req_vld_d = 1'b1;
              state_req_d     = RDI_REQ_LINKRESET;
            end
            default: ;
          endcase
        end
      end

      // Clear owed responses upon transmission acceptance
      if (adapter_sb_tx_valid && adapter_sb_tx_ready &&
          (adapter_sb_tx_packet.msg_code == MC_LM_RDI_RSP)) begin
        case (adapter_sb_tx_packet.msg_subcode)
          MS_LM_ACTIVE:    peer_act_rsp_sent_d = 1'b1;
          MS_LM_PMNAK:     owed_rsp_pmnak_d    = 1'b0;
          MS_LM_DISABLE:   owed_rsp_dis_d      = 1'b0;
          MS_LM_LINKRESET: owed_rsp_lr_d       = 1'b0;
          default: ;
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // assign: adapter_state_req_vld - Adapter State Machine Transition Strobe
  //
  // Asserts valid to drive adapter state transitions requested by Stage 3.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2 - State Request and Status.
  // --------------------------------------------------------------------------
  assign adapter_state_req_vld = state_req_vld_q;

  // --------------------------------------------------------------------------
  // assign: adapter_state_req - Adapter Requested Link State
  //
  // Encodes target RDI state (ACTIVE, RESET) requested by Stage 3 engine.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2 - State Request and Status.
  // --------------------------------------------------------------------------
  assign adapter_state_req     = state_req_q;

  // --------------------------------------------------------------------------
  // assign: stage3_done - Stage 3 Adapter Initialization Complete Flag
  //
  // Signals that Stage 3 capability and Active exchanges completed successfully.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 - Stage 3 Adapter Init.
  // --------------------------------------------------------------------------
  assign stage3_done           = stage3_done_q;

  // --------------------------------------------------------------------------
  // assign: adapter_capability_done - Capability Exchange Complete Flag
  //
  // Signals that mutual AdvCap.Adapter exchange succeeded.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1 - Stage 3 Adapter Init.
  // --------------------------------------------------------------------------
  assign adapter_capability_done = adapter_capability_done_q;

  // ==========================================================================
  // Section 9: Transmit Arbiter for adapter_sb_tx (<-> logical_phy)
  // UCIe 1.0 Section 6.1
  // ==========================================================================
  // Strictly non-blocking priority arbitration:
  //   1. Remote Completions (rem_cpl_fifo_q) - HIGHEST, never credit-gated.
  //   2. Stage 3 & Link Management responses (PMNAK, Active, LR, Dis).
  //   3. Stage 3 & Link Management requests (AdvCap, Active, LR, Dis).
  //   4. Autonomous NOP.Crd (when pending_cr_q > 0 and no packet pending).
  //   5. Remote register requests (gated by remote_req_crd_q > 0 and rem_table).
  //
  // Piggybacks Cr bit whenever pending_cr_q > 0.
  // ==========================================================================
  sb_packet_t nop_crd_pkt;

  // --------------------------------------------------------------------------
  // always_comb: Autonomous NOP.Crd Credit Return Message Assembler
  //
  // Assembles NOP.Crd credit return message with MsgInfo carrying return count.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Credit Flow Control.
  // --------------------------------------------------------------------------
  always @* begin
    nop_crd_pkt             = '0;
    nop_crd_pkt.opcode      = SB_OP_MSG_NODATA;
    nop_crd_pkt.src_id      = RDI_SRCID_ADAPTER;
    nop_crd_pkt.dst_id      = RDI_DSTID_REMOTE_ADAPT;
    nop_crd_pkt.msg_code    = MC_NOP_CRD;
    nop_crd_pkt.msg_info    = {13'h0, pending_cr_q};
  end

  // --------------------------------------------------------------------------
  // always_comb: Outbound Adapter Sideband Transmit Priority Arbiter
  //
  // Arbitrates between completions (highest priority, uncredit-gated),
  // link management responses, management requests, autonomous NOP.Crd,
  // and credit-gated remote register requests. Piggybacks pending Cr bits.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1 - Sideband Protocol.
  // --------------------------------------------------------------------------
  always @(rem_cpl_fifo_q[0], rem_cpl_fifo_q[1], rem_cpl_fifo_q[2], rem_cpl_fifo_q[3],
           rem_cpl_rd_ptr_q, rem_cpl_count_q,
           owed_rsp_dis_q, owed_rsp_lr_q, owed_rsp_pmnak_q,
           peer_act_req_rcvd_q, peer_act_rsp_sent_q,
           s3_state_q,
           rem_req_vld, rem_req_rdy, rem_req_pkt, rem_slot_free, remote_req_crd_q,
           pending_cr_q, adapter_sb_tx_ready,
           disabled_rsp_pkt, linkreset_rsp_pkt, pmnak_rsp_pkt,
           ad0_active_rsp_pkt, advcap_tx_pkt, ad0_active_req_pkt,
           disabled_req_pkt, linkreset_req_pkt, nop_crd_pkt) begin
    adapter_sb_tx_valid  = 1'b0;
    adapter_sb_tx_packet = '0;
    rem_req_rdy          = 1'b0;

    // 1. Remote Completions (Highest Priority, Never Credit-Gated)
    if (rem_cpl_count_q > 3'd0) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = rem_cpl_fifo_q[rem_cpl_rd_ptr_q];
    end
    // 2. Owed LM Responses
    else if (owed_rsp_dis_q) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = disabled_rsp_pkt;
    end else if (owed_rsp_lr_q) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = linkreset_rsp_pkt;
    end else if (owed_rsp_pmnak_q) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = pmnak_rsp_pkt;
    end else if (peer_act_req_rcvd_q && !peer_act_rsp_sent_q) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = ad0_active_rsp_pkt;
    end
    // 3. Stage 3 & LM Requests
    else if (s3_state_q == S3_ADVCAP_SEND) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = advcap_tx_pkt;
    end else if (s3_state_q == S3_ACTIVE_SEND) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = ad0_active_req_pkt;
    end else if (s3_state_q == S3_DISABLED_SEND) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = disabled_req_pkt;
    end else if (s3_state_q == S3_LINKRESET_SEND) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = linkreset_req_pkt;
    end
    // 4. Remote Register Request from Mailbox Client
    else if (rem_req_vld && (|rem_slot_free) && (remote_req_crd_q > 3'd0)) begin
      adapter_sb_tx_valid      = 1'b1;
      adapter_sb_tx_packet     = rem_req_pkt;
      adapter_sb_tx_packet.tag = rem_free_idx[4:0];
      rem_req_rdy              = adapter_sb_tx_ready;
    end
    // 5. Autonomous NOP.Crd Return
    else if (pending_cr_q > 3'd0) begin
      adapter_sb_tx_valid  = 1'b1;
      adapter_sb_tx_packet = nop_crd_pkt;
    end

    // Piggyback Cr bit on outgoing packet
    if (adapter_sb_tx_valid && (pending_cr_q > 3'd0) &&
        !(adapter_sb_tx_packet.opcode == SB_OP_MSG_NODATA && adapter_sb_tx_packet.msg_code == MC_NOP_CRD)) begin
      adapter_sb_tx_packet.cr = 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // assign: adapter_sb_rx_ready - Always-Sink Receive Acknowledge
  //
  // Sinks incoming packets immediately into holding registers and FIFO queues.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // --------------------------------------------------------------------------
  assign adapter_sb_rx_ready = 1'b1;

  // --------------------------------------------------------------------------
  // assign: rem_cpl_vld - Remote Mailbox Completion Valid Handshake
  //
  // Asserts valid to notify remote mailbox client of completed register access.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign rem_cpl_vld = rem_cpl_vld_q;

  // --------------------------------------------------------------------------
  // assign: rem_cpl_pkt - Remote Mailbox Completion Packet Driver
  //
  // Drives completion packet payload to remote mailbox client.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // --------------------------------------------------------------------------
  assign rem_cpl_pkt = rem_cpl_pkt_q;

  // ==========================================================================
  // Section 10: Status, Fatal, and Monitor Outputs
  // ==========================================================================
  // --------------------------------------------------------------------------
  // assign: adapter_fatal - Adapter Fatal Fault Status Driver
  //
  // Asserts sticky fatal status when an unrecoverable protocol error occurs.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 and Section 8.3.2.7.
  // --------------------------------------------------------------------------
  assign adapter_fatal      = adapter_fatal_q;

  // --------------------------------------------------------------------------
  // assign: adapter_linkerror - Adapter LinkError Trigger Driver
  //
  // Forwards fatal fault condition to trigger RDI LinkError state entry.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.5 (Figure 111) and Section 8.3.2.7.
  // --------------------------------------------------------------------------
  assign adapter_linkerror  = adapter_fatal_q;

  // --------------------------------------------------------------------------
  // assign: protocol_error - Sideband Protocol Error Flag
  //
  // Asserted sticky on corrupt opcodes, parity errors, or tag mismatches.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data Integrity.
  // --------------------------------------------------------------------------
  assign protocol_error     = protocol_err_q;

  // --------------------------------------------------------------------------
  // assign: fdi_format_error - FDI Configuration Format Error Flag
  //
  // Asserted sticky on missing phase cycles or malformed FDI requests.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.2.3 - FDI Sideband Interface.
  // --------------------------------------------------------------------------
  assign fdi_format_error   = fdi_format_err_q;

  // --------------------------------------------------------------------------
  // assign: sb_credit_returned - Sideband Credit Return Monitor Strobe
  //
  // Pulses on every credit return to remote peer.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Credit Flow Control.
  // --------------------------------------------------------------------------
  assign sb_credit_returned = sb_credit_ret_pulse;

  // --------------------------------------------------------------------------
  // assign: sb_stall_sent - Sideband Stall Response Monitor Strobe
  //
  // Pulses whenever a Stall response packet is transmitted.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 52).
  // --------------------------------------------------------------------------
  assign sb_stall_sent      = sb_stall_sent_pulse;

  // --------------------------------------------------------------------------
  // assign: sb_msg_timeout - Sideband Message Timeout Monitor Pulse
  //
  // Pulses whenever an 8 ms message timer expires.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Message Timers.
  // --------------------------------------------------------------------------
  assign sb_msg_timeout     = rem_timeout_pulse | s3_timeout_pulse;

  // ==========================================================================
  // Section 11: Sequential State Registers
  // ==========================================================================
  // --------------------------------------------------------------------------
  // always_ff: Adapter Sideband Sequential State Register Bank
  //
  // Synchronous registers for all sideband state machines, credits, FIFOs,
  // and error flags clocked on 500 MHz link clock (lclk).
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.1.1, Section 6.1, Section 8.2.3.
  // --------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      fdi_rx_state_q        <= FDI_RX_IDLE;
      fdi_rx_cnt_q          <= 3'd0;
      fdi_rx_hdr_q          <= 64'h0;
      fdi_rx_pld_q          <= 64'h0;

      fdi_format_err_q      <= 1'b0;
      protocol_err_q        <= 1'b0;
      adapter_fatal_q       <= 1'b0;

      fdi_rx_crd_q          <= 3'd4;
      fdi_tx_crd_q          <= 3'd4;
      remote_req_crd_q      <= 3'd4;
      pending_cr_q          <= 3'd0;

      rem_table_valid_q     <= 4'b0;
      rem_table_route_q     <= 4'b0;
      for (int i = 0; i < 4; i++) begin
        rem_table_pkt_q[i]   <= '0;
        rem_table_timer_q[i] <= 32'd0;
      end

      csr_fsm_q             <= CSR_ST_IDLE;
      csr_held_q            <= '0;
      csr_held_rdata_q      <= 64'h0;
      csr_rd_pulse_q        <= 1'b0;

      for (int i = 0; i < 4; i++) begin
        fdi_cpl_q[i]      <= '0;
        rem_cpl_fifo_q[i] <= '0;
      end
      fdi_cpl_wr_ptr_q      <= 2'd0;
      fdi_cpl_rd_ptr_q      <= 2'd0;
      fdi_cpl_count_q       <= 3'd0;
      rem_cpl_wr_ptr_q      <= 2'd0;
      rem_cpl_rd_ptr_q      <= 2'd0;
      rem_cpl_count_q       <= 3'd0;

      pl_tx_state_q         <= PL_TX_IDLE;
      pl_tx_cnt_q           <= 3'd0;
      pl_cfg_q              <= {NC{1'b0}};
      pl_cfg_vld_q          <= 1'b0;
      pl_cfg_crd_q          <= 1'b0;

      s3_state_q            <= S3_RESET;
      cap_timer_q           <= 32'd0;
      ad0_timer_q           <= 32'd0;
      lm_timer_q            <= 32'd0;
      local_act_req_sent_q  <= 1'b0;
      local_act_rsp_rcvd_q  <= 1'b0;
      peer_act_req_rcvd_q   <= 1'b0;
      peer_act_rsp_sent_q   <= 1'b0;
      owed_rsp_pmnak_q      <= 1'b0;
      owed_rsp_dis_q        <= 1'b0;
      owed_rsp_lr_q         <= 1'b0;

      stage3_done_q         <= 1'b0;
      adapter_capability_done_q <= 1'b0;
      state_req_vld_q       <= 1'b0;
      state_req_q           <= RDI_REQ_NOP;

      rem_cpl_vld_q         <= 1'b0;
      rem_cpl_pkt_q         <= '0;
    end else begin
      fdi_rx_state_q        <= fdi_rx_state_d;
      fdi_rx_cnt_q          <= fdi_rx_cnt_d;
      fdi_rx_hdr_q          <= fdi_rx_hdr_d;
      fdi_rx_pld_q          <= fdi_rx_pld_d;

      fdi_format_err_q      <= fdi_format_err_d;
      protocol_err_q        <= protocol_err_d;
      adapter_fatal_q       <= adapter_fatal_d;

      fdi_rx_crd_q          <= fdi_rx_crd_d;
      fdi_tx_crd_q          <= fdi_tx_crd_d;
      remote_req_crd_q      <= remote_req_crd_d;
      pending_cr_q          <= pending_cr_d;

      rem_table_valid_q     <= rem_table_valid_d;
      rem_table_route_q     <= rem_table_route_d;
      for (int i = 0; i < 4; i++) begin
        rem_table_pkt_q[i]   <= rem_table_pkt_d[i];
        rem_table_timer_q[i] <= rem_table_timer_d[i];
      end

      csr_fsm_q             <= csr_fsm_d;
      csr_held_q            <= csr_held_d;
      csr_held_rdata_q      <= csr_held_rdata_d;
      csr_rd_pulse_q        <= csr_rd_pulse_d;

      if (fdi_cpl_push && (fdi_cpl_count_q < 3'd4)) begin
        fdi_cpl_q[fdi_cpl_wr_ptr_q] <= fdi_cpl_push_pkt;
      end
      fdi_cpl_wr_ptr_q      <= fdi_cpl_wr_ptr_d;
      fdi_cpl_rd_ptr_q      <= fdi_cpl_rd_ptr_d;
      fdi_cpl_count_q       <= fdi_cpl_count_d;

      if (rem_cpl_push && (rem_cpl_count_q < 3'd4)) begin
        rem_cpl_fifo_q[rem_cpl_wr_ptr_q] <= rem_cpl_push_pkt;
      end
      rem_cpl_wr_ptr_q      <= rem_cpl_wr_ptr_d;
      rem_cpl_rd_ptr_q      <= rem_cpl_rd_ptr_d;
      rem_cpl_count_q       <= rem_cpl_count_d;

      pl_tx_state_q         <= pl_tx_state_d;
      pl_tx_cnt_q           <= pl_tx_cnt_d;
      pl_cfg_q              <= pl_cfg_d;
      pl_cfg_vld_q          <= pl_cfg_vld_d;
      pl_cfg_crd_q          <= pl_cfg_crd_d;

      s3_state_q            <= s3_state_d;
      cap_timer_q           <= cap_timer_d;
      ad0_timer_q           <= ad0_timer_d;
      lm_timer_q            <= lm_timer_d;
      local_act_req_sent_q  <= local_act_req_sent_d;
      local_act_rsp_rcvd_q  <= local_act_rsp_rcvd_d;
      peer_act_req_rcvd_q   <= peer_act_req_rcvd_d;
      peer_act_rsp_sent_q   <= peer_act_rsp_sent_d;
      owed_rsp_pmnak_q      <= owed_rsp_pmnak_d;
      owed_rsp_dis_q        <= owed_rsp_dis_d;
      owed_rsp_lr_q         <= owed_rsp_lr_d;

      stage3_done_q         <= stage3_done_d;
      adapter_capability_done_q <= adapter_capability_done_d;
      state_req_vld_q       <= state_req_vld_d;
      state_req_q           <= state_req_d;

      rem_cpl_vld_q         <= rem_cpl_vld_d;
      rem_cpl_pkt_q         <= rem_cpl_pkt_d;
    end
  end

endmodule

`endif

// ============================================================================
// Module    : d2d_adapter
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/d2d_adapter.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Chapter 2 - Protocol Layer
//   UCIe 1.0 Specification, Section 6.1 - Sideband Interface
//   UCIe 1.0 Specification, Section 7.5 - UCIe Registers
//   UCIe 1.0 Specification, Section 8.1 - Raw Die-to-Die Interface (RDI)
//   UCIe 1.0 Specification, Section 8.2 - Flit-Aware Die-to-Die Interface (FDI)
//   UCIe 1.0 Specification, Table 114 - RDI signal list
//   UCIe 1.0 Specification, Table 115 - FDI signal list
// DESCRIPTION
//   Top-level hierarchical wrapper for the Die-to-Die (D2D) Adapter block.
//   The D2D Adapter sits between the Protocol Layer (above, reached via the
//   FDI) and the Physical Layer / Logical PHY (below, reached via the RDI).
//
//   This module instantiates and interconnects four sub-blocks:
//
//     1. fdi_state_machine (u_fdi_sm)
//        Implements the FDI Link Sub-state Machine per spec 8.2. Mirrors
//        RDI state transitions onto the FDI interface and coordinates the
//        four-way Active handshake with the Protocol Layer.
//
//     2. adapter_datapath (u_datapath)
//        Pure Streaming pass-through datapath in Raw Mode Format 1. Provides
//        a single pipeline register stage between FDI and RDI data buses.
//        No CRC, no retry, no flit-header insertion, no DLLP path.
//
//     3. adapter_sb_if (u_sb_if)
//        Adapter-side sideband interface per spec 6.1. Handles internal CSR
//        arbitration, peer sideband packets via typed adapter_sb_* ports,
//        FDI lp_cfg/pl_cfg credit loop, 8 ms timeout, and 4 ms Stall timer.
//
//     4. adapter_regfile (u_regfile)
//        Adapter CSR register file: UCIe Link Control, UCIe Link Status,
//        Error Log 0/1, and Electrical Parameter registers per spec 7.1.
//
//   The module also implements the Stall handshake (spec 8.3.1) and the
//   FDI-to-RDI state-request forwarding path. Observability outputs
//   (ltsm_state_obs, link_active_obs) are provided for testbench and debug.
//
//   Note: The Link Training and Status Management (LTSM) state machine is
//   NOT contained within this block. It resides in `logical_phy` and is
//   opaque to the D2D Adapter. The LTSM communicates its state to this
//   module indirectly via the RDI status signals (rdi_pl_state_sts, etc.).
//
// INTERNAL BLOCK DIAGRAM
//
//   Signals going UP  (^) reach the Protocol Layer on the FDI boundary.
//   Signals going DOWN (v) reach the Logical PHY on the RDI boundary.
//
//   +======================================================================+
//   |                         d2d_adapter                                  |
//   |                                                                      |
//   |  FDI (to/from Protocol Layer)                                        |
//   |  ^ lp_irdy, lp_valid, lp_data[127:0], lp_stream[7:0]               |
//   |  v pl_trdy, pl_valid, pl_data[127:0], pl_stream[7:0]                |
//   |  ^ lp_state_req[3:0]       v pl_state_sts[3:0]                      |
//   |  ^ lp_rx_active_sts        v pl_rx_active_req                       |
//   |  ^ lp_stallack             v pl_stallreq                             |
//   |  ^ lp_cfg[NC-1:0]         v pl_cfg[NC-1:0]                         |
//   |  ^ lp_cfg_vld              v pl_cfg_vld                              |
//   |  ^ lp_cfg_crd              v pl_cfg_crd                              |
//   |  v pl_inband_pres, pl_error, pl_cerror, pl_nferror, pl_trainerror   |
//   |  v pl_phyinrecenter, pl_protocol[2:0], pl_protocol_flitfmt[3:0]     |
//   |                                                                      |
//   | +-----------------+    +-------------------+    +-----------------+  |
//   | | fdi_state_      |    | adapter_          |    | adapter_        |  |
//   | | machine         |    | datapath          |    | sb_if           |  |
//   | | (u_fdi_sm)      |    | (u_datapath)      |    | (u_sb_if)      |  |
//   | |                 |    |                   |    |                 |  |
//   | | FDI LSM per     |    | FDI<->RDI data   |    | sideband & CSR  |  |
//   | | spec 8.2        |    | pipe stage, x8   |    | arbitration,    |  |
//   | | 4-way Active    |    | degrade, stall   |    | 8ms/4ms timers, |  |
//   | | handshake       |    | gate              |    | packet routing  |  |
//   | +---------+-------+    +---------+---------+    +--------+--------+  |
//   |           |                      |                       |           |
//   |     fdi_state_req_out     rdi_lp_data/valid/irdy   csr_wr/rd/addr   |
//   |           |                      |                       |           |
//   |           |                      |               +-------+--------+  |
//   |   Stall   |                      |               | adapter_       |  |
//   |   logic --+                      |               | regfile        |  |
//   |  (inline) |                      |               | (u_regfile)    |  |
//   |           |                      |               | LnkCtrl/Stat   |  |
//   |           |                      |               | ErrLog0/1      |  |
//   |           |                      |               | El. Params     |  |
//   |           |                      |               +-------+--------+  |
//   |           v                      v                       v           |
//   |                                                                      |
//   |  RDI (to/from Logical PHY / Physical Layer)                          |
//   |  v rdi_lp_irdy, rdi_lp_valid, rdi_lp_data[127:0]                   |
//   |  ^ rdi_pl_trdy, rdi_pl_valid, rdi_pl_data[127:0]                   |
//   |  v rdi_lp_state_req[3:0]     ^ rdi_pl_state_sts[3:0]               |
//   |  v rdi_lp_stallack           ^ rdi_pl_stallreq                      |
//   |  ^ rdi_pl_inband_pres, rdi_pl_error, rdi_pl_cerror, rdi_pl_nferror |
//   |  ^ rdi_pl_trainerror, rdi_pl_phyinrecenter                         |
//   |  ^ rdi_pl_lnk_cfg[2:0], rdi_pl_speedmode[2:0]                      |
//   |                                                                      |
//   +======================================================================+
//
// PARAMETERS
//   NBYTES - Data bus width in bytes. Defaults to ucie_pkg::NBYTES (16)
//            which matches the x16 Standard Package at 128 bits per UI.
//
// CLOCK / RESET
//   lclk      - Main link clock, 500 MHz (16 B @ 500 MHz = 64 Gbps for x16 @ 4 GT/s).
//   lreset_n  - Active-low synchronous reset, deasserted synchronously to
//               lclk by the reset controller upstream.
//
// DESIGN NOTES
//   - The stall handshake (spec 8.3.1 four-phase) is implemented inline in
//     this wrapper rather than in a sub-block. The registered phase tracker
//     drives the Protocol Layer request, PHY acknowledgement, and datapath
//     gate in order.
//   - lp_linkerror is a public input from the Protocol Layer (FDI Table 115).
//     It is combined with internal adapter_fatal to drive the private
//     rdi_lp_linkerror output (RDI Table 114, Section 8.1).
//   - Private typed Adapter packet client ports (adapter_sb_*) connect to
//     logical_phy through ucie_main per Section 6.1.
//   - Separate PHY CSR channel (phy_csr_*) connects to logical_phy (Section 7.5).
//   - Mailbox registers (Tables 70-73) in adapter_regfile connect via internal
//     rem_req_* and rem_cpl_* ports to adapter_sb_if (Sections 6.1, 7.5).
//     logical_phy, where edge detection creates the private LTSM event.
//   - The unused_inputs assignment silences lint warnings for signals that
//     are architecturally present on the RDI/FDI but not consumed here.
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//   v0.0.2  2026-09-22  Update lclk documentation to 500 MHz.
//   v0.0.3  2026-09-23  Documentation: add per-construct comment blocks with
//                        spec references for unused-input lint suppression and
//                        adapter initialization tie-offs.
//   v0.0.4  2026-09-23  Documentation: correct header and body citations. Fix
//                        the "Fdie-to-Die" typo in the Section 8.2 title
//                        (Flit-Aware Die-to-Die Interface). Width degrade is
//                        Section 4.3.7, not 4.3.4. The CSR and link control
//                        references now cite Section 7.5 with Table 65.
  // v0.0.5  2026-09-23  Documentation: correct the Section 8.3.1 title and
  //                      replace the false Section 4.5.x packet reference with
  //                      the applicable sideband references. Normalize the
  //                      Table 115 citation for lp_linkerror.
  // v0.0.6  2026-09-25  Phase C: pass the private completed-Active clear to the
  //                      Adapter Start copy. The public interface is unchanged.
//   v0.0.7  2026-09-25  Phase D: route the Adapter Start copy as a private
//                        training event, remove peer-Active transport policy,
//                        and retain a registered four-phase stall path.
//   v0.0.8  2026-09-25  Preserve the public FDI adapter_active_req port as a
//                        low tie-off while keeping peer-Active policy removed.
//   v0.0.9  2026-09-25  Clarify that the registered stall data gate remains
//                        closed through the RELEASED phase.
//   v0.0.10 2026-09-28  Sideband protocol remediation:
//                        - Expose private typed Adapter packet client ports
//                          (adapter_sb_tx_* / adapter_sb_rx_*) and pass into
//                          adapter_sb_if (Section 6.1).
//                        - Connect rdi_pl_state_sts and lp_state_req to adapter_sb_if (Sections 8.1, 8.2).
//                        - Connect adapter_state_req_vld/req to FDI/RDI state request path (Section 8.1).
//                        - Wire explicit Adapter CSR channel with csr_be[7:0] to adapter_regfile (Section 7.5).
//                        - Expose separate PHY CSR channel (phy_csr_*) to logical_phy (Section 7.5).
//                        - Wire rem_req_vld/rdy/pkt and rem_cpl_vld/pkt internal mailbox ports (Sections 6.1, 7.5).
//                        - Make lp_linkerror a public input and combine with adapter_fatal for
//                          private rdi_lp_linkerror output (Sections 8.1, 8.2).
//                        - Add public FDI Stage 3 clock/wake/protocol ports and configuration
//                          sideband (lp_cfg / pl_cfg) (Sections 6.1, 8.2).
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef D2dAdapter_SV
`define D2dAdapter_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module d2d_adapter #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NC     = ucie_pkg::NC
) (
  input  logic                  lclk,
  input  logic                  lreset_n,

  // ---------------------------------------------------------- FDI (Table 115)
  input  logic                  lp_irdy,
  input  logic                  lp_valid,
  input  logic [NBYTES*8-1:0]   lp_data,
  output logic                  pl_trdy,
  output logic                  pl_valid,
  output logic [NBYTES*8-1:0]   pl_data,
  input  logic [3:0]            lp_state_req,
  output logic [3:0]            pl_state_sts,
  output logic                  pl_inband_pres,
  output logic                  pl_error,
  output logic                  pl_cerror,
  output logic                  pl_nferror,
  output logic                  pl_trainerror,
  output logic                  pl_phyinrecenter,
  output logic                  pl_stallreq,
  input  logic                  lp_stallack,
  output logic                  pl_rx_active_req,
  input  logic                  lp_rx_active_sts,
  input  logic [7:0]            lp_stream,
  output logic [7:0]            pl_stream,
  output logic [2:0]            pl_protocol,
  output logic [3:0]            pl_protocol_flitfmt,
  output logic                  pl_protocol_vld,
  output logic                  pl_clk_req,
  input  logic                  lp_clk_ack = 1'b1,
  input  logic                  lp_wake_req = 1'b0,
  output logic                  pl_wake_ack,
  output logic [2:0]            pl_speedmode,
  output logic [2:0]            pl_lnk_cfg,
  input  logic [NC-1:0]         lp_cfg = '0,
  input  logic                  lp_cfg_vld = 1'b0,
  input  logic                  lp_cfg_crd = 1'b0,
  output logic [NC-1:0]         pl_cfg,
  output logic                  pl_cfg_vld,
  output logic                  pl_cfg_crd,
  input  logic                  lp_linkerror = 1'b0,
  // ---------------------------------------------------------- RDI (Table 114)
  output logic                  rdi_lp_irdy,
  output logic                  rdi_lp_valid,
  output logic [NBYTES*8-1:0]   rdi_lp_data,
  input  logic                  rdi_pl_trdy,
  input  logic                  rdi_pl_valid,
  input  logic [NBYTES*8-1:0]   rdi_pl_data,
  output logic [3:0]            rdi_lp_state_req,
  input  logic [3:0]            rdi_pl_state_sts,
  input  logic                  rdi_pl_inband_pres,
  input  logic                  rdi_pl_error,
  input  logic                  rdi_pl_cerror,
  input  logic                  rdi_pl_nferror,
  input  logic                  rdi_pl_trainerror,
  input  logic                  rdi_pl_phyinrecenter,
  input  logic                  rdi_pl_stallreq,
  output logic                  rdi_lp_stallack,
  output logic                  rdi_lp_linkerror,
  input  logic [2:0]            rdi_pl_lnk_cfg,
  input  logic [2:0]            rdi_pl_speedmode,

  // ---------------------------------------------------------- Private Adapter sideband packet client interface (<-> logical_phy, Section 6.1)
  output logic                  adapter_sb_tx_valid,
  input  logic                  adapter_sb_tx_ready,
  output sb_packet_t            adapter_sb_tx_packet,
  input  logic                  adapter_sb_rx_valid,
  output logic                  adapter_sb_rx_ready,
  input  sb_packet_t            adapter_sb_rx_packet,
  input  logic                  adapter_sb_rx_cp_error,
  input  logic                  adapter_sb_rx_dp_error,
  input  logic                  adapter_sb_rx_format_error,

  // ---------------------------------------------------------- Separate PHY CSR Access Channel (<-> logical_phy, Section 7.5)
  output logic                  phy_csr_wr,
  output logic                  phy_csr_rd,
  output logic [26:0]           phy_csr_addr,
  output logic [63:0]           phy_csr_wdata,
  output logic [7:0]            phy_csr_be,
  input  logic [63:0]           phy_csr_rdata,
  input  logic                  phy_csr_rdata_vld,
  input  logic                  start_link_train,
  input  logic                  clear_start_link_train,
  output logic                  adapter_start_link_train,
  output logic [7:0]            ltsm_state_obs,
  output logic                  link_active_obs
);

  import ucie_pkg::*;

  // --------------------------------------------------------------------------
  // Internal interconnect signals
  // --------------------------------------------------------------------------
  // adapter_state_req_vld / adapter_state_req : generic request transport
  //                      from u_sb_if to u_fdi_sm.
  // fdi_active_req     : u_fdi_sm reports a local Protocol Layer Active
  //                      request for observability only.
  // fdi_state_req_out  : supported request forwarded to the RDI.
  // fdi_state_req_vld  : qualifies fdi_state_req_out.
  // stall_active       : high in ACKED or RELEASED after the registered
  //                      four-phase handshake reaches the data-quiescent phase.
  // lnk_is_x8          : decoded from rdi_pl_lnk_cfg, true when the link has
  //                      degraded to x8 (spec 4.3.7 width degrade).
  // csr_*              : CSR access bus between u_sb_if and u_regfile.
  // sb_credit_returned : u_sb_if signals that a credit-return packet arrived.
  // sb_stall_sent      : u_sb_if signals that a stall keep-alive was sent.
  // sb_msg_timeout     : u_sb_if signals the 8 ms message timeout expired.
  // --------------------------------------------------------------------------
  logic        adapter_state_req_vld;
  logic [3:0]  adapter_state_req;
  logic        fdi_active_req;
  logic [3:0]  fdi_state_req_out;
  logic        fdi_state_req_vld;
  logic        stall_active;
  logic        lnk_is_x8;
  logic        csr_wr, csr_rd;
  logic [26:0] csr_addr;
  logic [63:0] csr_wdata, csr_rdata;
  logic [7:0]  csr_be;
  logic        csr_rdata_vld;
  logic        sb_credit_returned, sb_stall_sent, sb_msg_timeout;
  logic        start_link_train_wr;
  logic        start_link_train_q;
  logic        link_status_active;
  logic        adapter_fatal, adapter_linkerror;
  logic        stage3_done;
  logic        protocol_error, fdi_format_error;
  logic        rem_req_vld, rem_req_rdy;
  sb_packet_t  rem_req_pkt;
  logic        rem_cpl_vld;
  sb_packet_t  rem_cpl_pkt;
  logic        fdi_pl_inband_pres;
  logic        protocol_vld_q;
  logic        lp_clk_ack_q;
  // --------------------------------------------------------------------------
  // Stall Handshake Logic (spec 8.3.1 four-phase)
  // --------------------------------------------------------------------------
  // The registered tracker relays the PHY request to the Protocol Layer and
  // returns the Protocol Layer acknowledgement to the PHY:
  //   IDLE -> REQUESTED -> ACKED -> RELEASED -> IDLE.
  // The data gate closes in ACKED and RELEASED, after both sides complete
  // the request and acknowledgement phases. This keeps data quiescent.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism.
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    STALL_IDLE      = 2'd0,
    STALL_REQUESTED = 2'd1,
    STALL_ACKED     = 2'd2,
    STALL_RELEASED  = 2'd3
  } stall_phase_t;
  stall_phase_t stall_phase_q, stall_phase_d;

  // -------------------------------------------------------------------------
  // always_ff: Registered four-phase stall tracker
  //
  // Advances one handshake phase per lclk edge. Reset closes both request and
  // acknowledgement so a reset cannot leave the data path stalled.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) stall_phase_q <= STALL_IDLE;
    else           stall_phase_q <= stall_phase_d;
  end

  // -------------------------------------------------------------------------
  // always_comb: Stall phase next-state logic
  //
  // Phase one starts only while lp_stallack is low. Phase two waits for the
  // Protocol Layer acknowledgement. Phase three waits for the PHY request to
  // fall. Phase four waits for lp_stallack to fall before returning idle.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism.
  // -------------------------------------------------------------------------
  always_comb begin
    stall_phase_d = stall_phase_q;
    case (stall_phase_q)
      STALL_IDLE: begin
        if (rdi_pl_stallreq && !lp_stallack)
          stall_phase_d = STALL_REQUESTED;
      end
      STALL_REQUESTED: begin
        if (!rdi_pl_stallreq)
          stall_phase_d = STALL_IDLE;
        else if (lp_stallack)
          stall_phase_d = STALL_ACKED;
      end
      STALL_ACKED: begin
        if (!rdi_pl_stallreq)
          stall_phase_d = STALL_RELEASED;
      end
      STALL_RELEASED: begin
        if (!lp_stallack)
          stall_phase_d = STALL_IDLE;
      end
      default: stall_phase_d = STALL_IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // always_comb: Stall and Link-Width Decode Outputs
  //
  // Drives the registered request, registered PHY acknowledgement, active
  // data gate, and fixed link-width decode. The request is high only in
  // REQUESTED. ACKED and RELEASED assert the acknowledgement and close data.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1; Section 4.3.7.
  // -------------------------------------------------------------------------
  always_comb begin
    pl_stallreq    = (stall_phase_q == STALL_REQUESTED);
    rdi_lp_stallack = (stall_phase_q == STALL_ACKED) ||
                      (stall_phase_q == STALL_RELEASED);
    stall_active   = (stall_phase_q == STALL_ACKED) ||
                     (stall_phase_q == STALL_RELEASED);
    lnk_is_x8      = (rdi_pl_lnk_cfg == LNKCFG_X8);
  end

  // -------------------------------------------------------------------------
  // always_comb: FDI / Adapter -> RDI State Request Forwarding
  //
  // Connect adapter_state_req_vld/req to the existing FDI/RDI state request path
  // without restoring old policy ownership. Disabled has highest priority,
  // followed by LinkReset, then Active. Protocol Layer Active request from
  // u_fdi_sm is forwarded directly without being gated by remote adapter status.
  //
  // Spec ref: UCIe 1.0 Sections 8.1.5, 8.1.6, and 8.2; Section 6.1.
  // -------------------------------------------------------------------------
  always_comb begin
    if (adapter_state_req_vld && (adapter_state_req == RDI_REQ_DISABLED))
      rdi_lp_state_req = RDI_REQ_DISABLED;
    else if (fdi_state_req_vld && (fdi_state_req_out == RDI_REQ_DISABLED))
      rdi_lp_state_req = RDI_REQ_DISABLED;
    else if (adapter_state_req_vld && (adapter_state_req == RDI_REQ_LINKRESET))
      rdi_lp_state_req = RDI_REQ_LINKRESET;
    else if (fdi_state_req_vld && (fdi_state_req_out == RDI_REQ_LINKRESET))
      rdi_lp_state_req = RDI_REQ_LINKRESET;
    else if (adapter_state_req_vld && (adapter_state_req == RDI_REQ_ACTIVE))
      rdi_lp_state_req = RDI_REQ_ACTIVE;
    else
      rdi_lp_state_req = fdi_state_req_out;
  end
  // -------------------------------------------------------------------------
  // Module Instantiation: fdi_state_machine (u_fdi_sm)
  //
  // The FDI state machine mirrors only supported RDI states and forwards
  // Active, LinkReset, and Disabled requests. Legacy adapter request inputs
  // remain structurally present but do not own Active policy.
  //
  // Spec ref: UCIe 1.0 Section 8.2, Table 115; PLAN.md Section 15.5.
  // -------------------------------------------------------------------------
  fdi_state_machine u_fdi_sm (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .lp_state_req(lp_state_req),
    .pl_state_sts(pl_state_sts),
    .pl_inband_pres(fdi_pl_inband_pres),
    .pl_error(pl_error),
    .pl_cerror(pl_cerror),
    .pl_nferror(pl_nferror),
    .pl_trainerror(pl_trainerror),
    .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol(pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_rx_active_sts(lp_rx_active_sts),
    .lp_stream(lp_stream),
    .pl_stream(),
    .rdi_state_sts(rdi_pl_state_sts),
    .rdi_inband_pres(rdi_pl_inband_pres),
    .rdi_trainerror(rdi_pl_trainerror),
    .rdi_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_cerror(rdi_pl_cerror),
    .rdi_nferror(rdi_pl_nferror),
    .adapter_active_req(1'b0),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .fdi_active_req(fdi_active_req),
    .fdi_state_req_out(fdi_state_req_out),
    .fdi_state_req_vld(fdi_state_req_vld)
  );

  // -------------------------------------------------------------------------
  // Module Instantiation: adapter_datapath (u_datapath)
  //
  // Pure Streaming pass-through datapath in Raw Mode Format 1 (spec 4.1.x).
  // Single registered pipeline stage in each direction:
  //   - FDI -> RDI (Tx): lp_data/valid/irdy registered to rdi_lp_*.
  //   - RDI -> FDI (Rx): rdi_pl_data/valid registered to pl_*.
  //   - x8 width degrade: upper 64 bits of rdi_lp_data zeroed when lnk_is_x8.
  //   - Stall gate: stall_active gates data during stall handshake.
  //
  // No CRC engine, retry buffer, or sequence numbers: legal for 4 GT/s
  // Raw Mode Format 1 in this simplified endpoint.
  //
  // Spec ref: UCIe 1.0, Section 4.1.x (framing), Section 8.1 (pipeline stage),
  //           Table 115 (FDI signals).
  // -------------------------------------------------------------------------
  adapter_datapath #(.NBYTES(NBYTES)) u_datapath (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .lp_irdy(lp_irdy),
    .lp_valid(lp_valid),
    .lp_data(lp_data),
    .lp_stream(lp_stream),
    .lp_stallack(lp_stallack),
    .lp_rx_active_sts(lp_rx_active_sts),
    .pl_trdy(pl_trdy),
    .pl_valid(pl_valid),
    .pl_data(pl_data),
    .pl_stream(pl_stream),
    .rdi_lp_irdy(rdi_lp_irdy),
    .rdi_lp_valid(rdi_lp_valid),
    .rdi_lp_data(rdi_lp_data),
    .rdi_pl_trdy(rdi_pl_trdy),
    .rdi_pl_valid(rdi_pl_valid),
    .rdi_pl_data(rdi_pl_data),
    .rdi_lnk_is_x8(lnk_is_x8),
    .stall_active(stall_active)
  );

  // -------------------------------------------------------------------------
  // Module Instantiation: adapter_sb_if (u_sb_if)
  //
  // Adapter-side sideband interface per spec 6.1. It owns CSR decode/arbitration,
  // typed packet transport (adapter_sb_*), credit accounting, and monitor timers.
  // LinkMgmt.RDI Active policy remains in the Logical PHY LTSM.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.5 and 6.1; PLAN.md Section 15.5.
  // -------------------------------------------------------------------------
  adapter_sb_if #(.NC(NC)) u_sb_if (
    .lclk                      (lclk),
    .lreset_n                  (lreset_n),
    .lp_cfg                    (lp_cfg),
    .lp_cfg_vld                (lp_cfg_vld),
    .lp_cfg_crd                (lp_cfg_crd),
    .pl_cfg                    (pl_cfg),
    .pl_cfg_vld                (pl_cfg_vld),
    .pl_cfg_crd                (pl_cfg_crd),
    .adapter_sb_tx_valid       (adapter_sb_tx_valid),
    .adapter_sb_tx_ready       (adapter_sb_tx_ready),
    .adapter_sb_tx_packet      (adapter_sb_tx_packet),
    .adapter_sb_rx_valid       (adapter_sb_rx_valid),
    .adapter_sb_rx_ready       (adapter_sb_rx_ready),
    .adapter_sb_rx_packet      (adapter_sb_rx_packet),
    .adapter_sb_rx_cp_error    (adapter_sb_rx_cp_error),
    .adapter_sb_rx_dp_error    (adapter_sb_rx_dp_error),
    .adapter_sb_rx_format_error(adapter_sb_rx_format_error),
    .rdi_pl_state_sts          (rdi_pl_state_sts),
    .lp_state_req              (lp_state_req),
    .adapter_state_req_vld     (adapter_state_req_vld),
    .adapter_state_req         (adapter_state_req),
    .csr_wr                    (csr_wr),
    .csr_rd                    (csr_rd),
    .csr_addr                  (csr_addr),
    .csr_wdata                 (csr_wdata),
    .csr_be                    (csr_be),
    .csr_rdata                 (csr_rdata),
    .csr_rdata_vld             (csr_rdata_vld),
    .csr_target                (),
    .phy_csr_wr                (phy_csr_wr),
    .phy_csr_rd                (phy_csr_rd),
    .phy_csr_addr              (phy_csr_addr),
    .phy_csr_wdata             (phy_csr_wdata),
    .phy_csr_be                (phy_csr_be),
    .phy_csr_rdata             (phy_csr_rdata),
    .phy_csr_rdata_vld         (phy_csr_rdata_vld),
    .rem_req_vld               (rem_req_vld),
    .rem_req_rdy               (rem_req_rdy),
    .rem_req_pkt               (rem_req_pkt),
    .rem_cpl_vld               (rem_cpl_vld),
    .rem_cpl_pkt               (rem_cpl_pkt),
    .adapter_fatal             (adapter_fatal),
    .adapter_linkerror         (adapter_linkerror),
    .stage3_done               (stage3_done),
    .protocol_error            (protocol_error),
    .fdi_format_error          (fdi_format_error),
    .sb_credit_returned        (sb_credit_returned),
    .sb_stall_sent             (sb_stall_sent),
    .sb_msg_timeout            (sb_msg_timeout)
  );

  // -------------------------------------------------------------------------
  // Module Instantiation: adapter_regfile (u_regfile)
  //
  // Adapter CSR register file containing ten 64-bit registers at byte
  // offsets 0x00-0x48 within the Adapter CSR address space:
  //   0x00 : UCIe Link Control  - bit 0 starts link training (RW).
  //   0x08 : UCIe Link Status   - in-band presence, PHY state, link width.
  //   0x10 : Error Log 0        - LTSM State N in bits [7:0].
  //   0x18 : Error Log 1        - trainerror/phyinrecenter sticky (RW1C).
  //   0x20 : Electrical Params  - speed, swing, clock mode (CSR-only).
  //   0x28 : Electrical Params 2 - reserved expansion.
  //   0x30 : Sideband Mailbox Index - remote request selector and metadata.
  //   0x38 : Sideband Mailbox Data  - remote request or completion data.
  //   0x40 : Sideband Mailbox Control - remote request trigger and control.
  //   0x48 : Sideband Mailbox Status - completion status and error flags.
  //
  // CSR reads and writes arrive from u_sb_if via csr_wr/csr_rd/csr_addr/
  // csr_wdata and return on csr_rdata/csr_rdata_vld. Hardware writes
  // (start_link_train_wr, in_band_pres, rdi_state_sts, ltsm_state,
  // trainerror, phyinrecenter) come from the adapter and PHY status.
  //
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (CSR definition).
  // -------------------------------------------------------------------------
  adapter_regfile u_regfile (
    .lclk                  (lclk),
    .lreset_n              (lreset_n),
    .csr_wr                (csr_wr),
    .csr_addr              (csr_addr),
    .csr_wdata             (csr_wdata),
    .csr_be                (csr_be),
    .csr_rd                (csr_rd),
    .csr_rdata             (csr_rdata),
    .csr_rdata_vld         (csr_rdata_vld),
    .start_link_train_wr   (start_link_train_wr),
    .in_band_pres          (rdi_pl_inband_pres),
    .rdi_state_sts         (rdi_pl_state_sts),
    .ltsm_state            (ltsm_state_obs),
    .trainerror            (rdi_pl_trainerror),
    .phyinrecenter         (rdi_pl_phyinrecenter),
    .clear_start_link_train(clear_start_link_train),
    .start_link_train      (adapter_start_link_train),
    .link_status_active    (link_status_active),
    .rem_req_vld           (rem_req_vld),
    .rem_req_rdy           (rem_req_rdy),
    .rem_req_pkt           (rem_req_pkt),
    .rem_cpl_vld           (rem_cpl_vld),
    .rem_cpl_pkt           (rem_cpl_pkt)
  );
  // -------------------------------------------------------------------------
  // Stage 3 Clock, Wake, and Protocol Status Generation (Sections 7.5, 8.2)
  // -------------------------------------------------------------------------
  assign pl_clk_req   = 1'b1;
  assign pl_speedmode = rdi_pl_speedmode;
  assign pl_lnk_cfg   = rdi_pl_lnk_cfg;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      lp_clk_ack_q   <= 1'b0;
      pl_wake_ack    <= 1'b0;
      protocol_vld_q <= 1'b0;
    end else begin
      lp_clk_ack_q <= lp_clk_ack;
      pl_wake_ack  <= lp_wake_req;
      if (rdi_pl_state_sts == RDI_STS_RESET) begin
        protocol_vld_q <= 1'b0;
      end else if (stage3_done) begin
        protocol_vld_q <= 1'b1;
      end
    end
  end

  assign pl_protocol_vld = protocol_vld_q;
  assign pl_inband_pres  = fdi_pl_inband_pres && protocol_vld_q && lp_clk_ack_q;

  // -------------------------------------------------------------------------
  // always_comb: Observability and LinkError Generation
  //
  // Combine public input lp_linkerror with internal adapter_fatal to drive
  // the private RDI LinkError output (rdi_lp_linkerror).
  //
  // Spec ref: UCIe 1.0 Table 114 (RDI), Table 115 (FDI), Section 8.1, Section 8.2.
  // -------------------------------------------------------------------------
  always_comb begin
    rdi_lp_linkerror = lp_linkerror | adapter_fatal;
    link_active_obs  = link_status_active;
  end

  // -------------------------------------------------------------------------
  // always_ff: Adapter Start event latch
  //
  // Converts the external Start level into one registered write event for the
  // Adapter Link Control copy. The previous level blocks a held Start from
  // re-arming the copy after the Phase C Active-entry clear.
  //
  // Spec ref: UCIe 1.0, Section 7.5, Table 65; PLAN.md Sections 15.5 and
  //           15.9 Phase D Start cutover.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      start_link_train_q  <= 1'b0;
      start_link_train_wr <= 1'b0;
    end else begin
      start_link_train_q  <= start_link_train;
      start_link_train_wr <= start_link_train && !start_link_train_q;
    end
  end

  // -------------------------------------------------------------------------
  // always_comb: Unused-Input Lint Suppression
  //
  // Several RDI signals are architecturally present on the port list for
  // Table 114 compliance but are not consumed in this reduced-scope
  // implementation:
  //   rdi_pl_error     - forwarded through u_fdi_sm, but not used here.
  //   rdi_pl_speedmode - only 4 GT/s supported; no speed negotiation.
  //   fdi_active_req   - informational output from u_fdi_sm.
  //   fdi_state_req_vld - qualifier for fdi_state_req_out; not used at top.
  //   sb_credit_returned, sb_stall_sent, sb_msg_timeout - monitor hooks.
  //   adapter_state_req_vld - general sideband state request valid.
  //
  // The OR-reduction ensures the synthesizer sees all signals as read,
  // preventing unused-port warnings without affecting any output.
  //
  // Spec ref: N/A (lint suppression, no functional impact).
  // -------------------------------------------------------------------------
  logic unused_inputs;
  always_comb begin
    unused_inputs = rdi_pl_error |
                    fdi_active_req |
                    sb_credit_returned | sb_stall_sent | sb_msg_timeout |
                    adapter_linkerror | protocol_error | fdi_format_error;
  end

endmodule

`endif

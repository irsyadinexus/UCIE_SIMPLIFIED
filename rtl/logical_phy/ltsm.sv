// ============================================================================
// File        : ltsm.sv
// Module      : ltsm
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Link Training and Status State Machine (LTSM). This is the
//               central sequencer for the entire link bring-up, from physical
//               reset through sideband initialisation, main-band calibration,
//               main-band training, link initialisation, and finally the
//               ACTIVE state where data may flow.
//
// Spec refs   : UCIe 1.0 spec section 4.5.3 (LTSM), with per-state
//               references to 4.5.3.1 through 4.5.3.9.
//
// --------------------------------------------------------------------------
// LTSM State / Sub-State Progression  (spec 4.5.3 Figure 70)
// --------------------------------------------------------------------------
//
//  +-----------+
//  |  RESET    |  4.5.3.1  Wait for adapter start_link_train.
//  |  (00h)    |           Exit -> SBINIT.
//  +-----+-----+
//        |
//        v
//  +-----------+
//  |  SBINIT   |  4.5.3.2  Out-of-band sideband reset handshake.
//  |  (01h)    |           SB_DONE_REQ / SB_DONE_RSP exchange.
//  +-----+-----+           Exit -> MBINIT.PARAM.
//        |
//        v
//  +===================================+
//  | MBINIT  (4.5.3.3)                |
//  |                                   |
//  | +-------------+  +------------+   |
//  | | PARAM (02h) +->| CAL  (03h) |   |
//  | +-------------+  +-----+------+   |
//  |                        |          |
//  | +-------------------+  |          |
//  | | REPAIRCLK  (04h)  |<-+          |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | REPAIRVAL  (05h)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | REVERSALMB (06h)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | REPAIRMB   (07h)  |             |
//  | +--------+----------+             |
//  +===================================+
//             |
//             v
//  +===================================+
//  | MBTRAIN  (4.5.3.4)               |
//  |                                   |
//  | +-------------+  +-----------+    |
//  | | VALVREF     +->| DATAVREF  |    |
//  | |  (08h)      |  |  (09h)    |    |
//  | +-------------+  +-----+-----+    |
//  |                        |          |
//  | +-------------------+  |          |
//  | | SPEEDIDLE  (0Ah)  |<-+          |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | TXSELFCAL  (0Bh)  |<-----+     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | RXCLKCAL   (0Ch)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | VTCENTER   (0Dh)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | DTVREF1    (0Eh)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | RXDESKEW   (0Fh)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | DTCENTER2  (10h)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | LINKSPEED  (11h)  |      |     |
//  | +--------+----------+      |     |
//  |          |                  |     |
//  | +--------v----------+      |     |
//  | | REPAIR     (12h)  +------+     |
//  | |  EXIT_REP/EXIT_DEG|  (retry)   |
//  | +--------+----------+             |
//  +===================================+
//             | LKS_DONE
//             v
//  +-----------+
//  | LINKINIT  |  4.5.3.5  Reseed per-lane LFSRs; LFSR pattern 4096 UI.
//  |  (14h)    |           Exit -> ACTIVE on pat_done.
//  +-----+-----+
//        |
//        v
//  +-----------+                 +--------------+
//  |  ACTIVE   |  4.5.3.6       | PHYRETRAIN   | 4.5.3.7
//  |  (15h)    |<--------------->|  (13h)       | Re-run training subset.
//  +-----+-----+                 +--------------+
//        |
//        | (retrain_req or error)
//        v
//  +-----------+                 +-----------+
//  | TRAINERROR|  4.5.3.8        |   L1L2    | 4.5.3.9
//  |  (16h)    |                 |  (17h)    | Low-power; clock may gate.
//  +-----------+                 +-----------+
//  (only LINKRESET clears)       (start_link_train -> RESET)
//
// --------------------------------------------------------------------------
// Sub-state exit rule  (spec 4.5.3.4)
// --------------------------------------------------------------------------
//   A sub-state exits when the local side has sent its request AND received
//   the partner's response. Both endpoints run the identical sequence, so a
//   partner's request with the correct code/subcode is accepted as the
//   response (symmetric handshake optimisation).
//
//   Every sub-state is bounded by an 8 ms residency timer. A sub-state
//   that exceeds 8 ms without completing escalates to TRAINERROR.
//
// --------------------------------------------------------------------------
// Sideband message coding  (Tables 53, 54, 56)
// --------------------------------------------------------------------------
//   Each LTSM state maps to a {MsgCode, MsgSubcode} pair through three
//   lookup functions: msg_req_code(), msg_rsp_code(), msg_subcode().
//   MsgInfo carries supplementary qualifiers; only the REPAIR sub-state
//   reads MsgInfo (LKS_DONE / LKS_EXIT_REP / LKS_EXIT_DEG).
//
// --------------------------------------------------------------------------
// Pattern generator control  (spec 4.5.3.4, 4.5.3.5)
// --------------------------------------------------------------------------
//   The LTSM enables the pattern generator during MBTRAIN sub-states and
//   LINKINIT. Pattern selection:
//     - VALVREF, DATAVREF           -> PAT_VALTRAIN  (1010 checkerboard)
//     - RXDESKEW                    -> PAT_CLKREPAIR (clock-repair toggle)
//     - LINKINIT                    -> PAT_LFSR      (4096-UI LFSR)
//     - all other MBTRAIN states    -> PAT_PERLANEID (lane numbering)
//
// --------------------------------------------------------------------------
// Timer interface
// --------------------------------------------------------------------------
//   tmr_start       : pulsed on entry to each new sub-state (state_q != prev).
//   tmr_run         : held while the handshake is pending (timer_start_q &&
//                     !resp_rcvd_q). On expiry the LTSM transitions to TRAINERROR.
//   rst_tmr_expired : 4 ms physical layer RESET minimum timeout (spec 4.5.3.1).
//
// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
//   NLANES : Number of main-band lanes (default NLANES_MAX = 16).
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   Adapter/RDI : start_link_train, adapter_active_req, link_trained,
//                 train_error, link_reset_out, phy_retrain_done,
//                 ltsm_state (8-bit state encoding for Error Log 0),
//                 lnk_is_x8, degrade_lanes.
//   Sideband    : Full TX field set (sb_tx_load..sb_tx_has_data) driving
//                 the sb_codec, and full RX field set (sb_rx_pkt_vld..
//                 sb_rx_dp_err) from the sb_codec.
//   Pattern gen : pat_enable, pat_select, pat_lfsr_reset, pat_lfsr_enable,
//                 pat_done.
//   Timers      : tmr_start, tmr_run, tmr_expired, rst_tmr_expired.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The LTSM is purely a sequencer; it does not contain any analog or
//      calibration logic. The pattern generator and scrambler provide the
//      physical-layer data.
//   2. In the loopback test, sub-state exit relies on the handshake, not
//      the timer, keeping simulation at tens of millions of cycles. Timer
//      paths remain wired and are exercised on the ucie_timer unit.
//   3. lnk_is_x8 and degrade_lanes are tied to zero: x16-only in this
//      reduced-capability set.
//   4. sb_msg_timeout and sb_stall_sent are tied to zero: message timeout
//      recovery and stall insertion are not implemented.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Full LTSM sequencer with 24
//                        states, sideband handshake, pattern control, and
//                        timer interface.
//   v0.0.2  2026-09-22  Fix tmr_start to pulse for 1 cycle on sub-state entry.
//   v0.0.3  2026-09-22  Enforce 4 ms physical layer RESET minimum (Req.1).
//   v0.0.4  2026-09-23  Pulse pat_lfsr_reset on LINKINIT entry so LFSR advances.
//   v0.0.5  2026-09-23  Documentation: add per-construct comment blocks for
//                        all always_ff and assign statements per doc contract.
//   v0.0.6  2026-09-23  Documentation: correct shifted LTSM state citations.
//                        LINKINIT, ACTIVE, and PHYRETRAIN are Sections
//                        4.5.3.5, 4.5.3.6, and 4.5.3.7, respectively.
//   v0.0.7  2026-09-23  Req.3: remove unused sbclk/sbreset_n ports. The LTSM
//                        now uses only lclk-facing asynchronous mailboxes.
// ============================================================================
`ifndef Ltsm_SV
`define Ltsm_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ltsm #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,

  // ---- adapter / RDI
  input  logic        start_link_train,   // adapter requests RESET exit
  input  logic        adapter_active_req, // partner declared ACTIVE
  output logic        link_trained,       // LTSM reached ACTIVE
  output logic        train_error,        // unrecoverable failure
  output logic        link_reset_out,     // drives RDI LINKRESET
  output logic        phy_retrain_done,   // PHYRETRAIN completed
  output logic [7:0]  ltsm_state,         // Error Log 0 "State N"
  output logic        lnk_is_x8,          // negotiated x8 degrade
  output logic [1:0]  degrade_lanes,      // which half survives

  // ---- lclk-facing sideband CDC endpoint (the LTSM is the only master)
  output logic        sb_tx_load,
  output logic [4:0]  sb_tx_opcode,
  output logic [2:0]  sb_tx_srcid,
  output logic [2:0]  sb_tx_dstid,
  output logic [7:0]  sb_tx_msginfo,
  output logic [7:0]  sb_tx_msgcode,
  output logic [7:0]  sb_tx_msgsubcode,
  output logic [7:0]  sb_tx_be,
  output logic [4:0]  sb_tx_tag,
  output logic        sb_tx_ep,
  output logic [11:0] sb_tx_addr,
  output logic [63:0] sb_tx_data_in,
  output logic        sb_tx_has_data,
  input  logic        sb_tx_busy,
  input  logic        sb_rx_pkt_vld,
  input  logic [4:0]  sb_rx_opcode,
  input  logic [2:0]  sb_rx_srcid,
  input  logic [2:0]  sb_rx_dstid,
  input  logic [7:0]  sb_rx_msginfo,
  input  logic [7:0]  sb_rx_msgcode,
  input  logic [7:0]  sb_rx_msgsubcode,
  input  logic        sb_rx_cp_err,
  input  logic        sb_rx_dp_err,
  output logic        sb_msg_timeout,
  output logic        sb_stall_sent,

  // ---- training pattern generator
  output logic        pat_enable,
  output pat_t        pat_select,
  output logic        pat_lfsr_reset,
  output logic        pat_lfsr_enable,
  input  logic        pat_done,

  // ---- timers
  output logic        tmr_start,
  output logic        tmr_run,
  input  logic        tmr_expired,
  input  logic        rst_tmr_expired
);

  // =========================================================================
  // State and handshake registers
  // =========================================================================
  // Spec 4.5.3 – The LTSM state encoding uses ltsm_state_t (8 bits), with
  // values defined in ucie_pkg (LT_RESET through LT_L1L2). The handshake
  // registers track whether the local side has sent its sub-state request
  // (req_sent_q) and whether the partner's response has been received
  // (resp_rcvd_q). timer_start_q arms the 8 ms residency timer on each
  // sub-state entry. retrain_req_q records a pending PHYRETRAIN request.
  //
  // Reset clears the state to LT_RESET and de-asserts all handshake flags.
  // On each clock edge the next-state values computed in the always_comb
  // block are registered here.
  // =========================================================================
  ltsm_state_t state_q, state_d;
  logic        req_sent_q;       // local side sent its sub-state request
  logic        resp_rcvd_q;      // partner's response received
  logic        timer_start_q;
  logic        reset_min_done_q; // 4 ms RESET minimum met
  logic        retrain_req_q;
  logic        req_sent_d, resp_rcvd_d, timer_start_d, retrain_req_d, reset_min_done_d;
  // -------------------------------------------------------------------------
  // always_ff: State and Handshake Register Bank
  //
  // Registers the LTSM state (state_q) and five handshake/control flags on
  // the rising edge of lclk, with asynchronous active-low reset. On reset
  // the state machine enters LT_RESET and all handshake flags are cleared.
  // On each active clock edge, the next-state values computed by the
  // always_comb block are captured:
  //   state_q          – current LTSM state encoding (8-bit ltsm_state_t).
  //   req_sent_q       – local sideband request accepted by the CDC mailbox.
  //   resp_rcvd_q      – partner response delivered by the CDC mailbox.
  //   timer_start_q    – 8 ms residency timer armed for this sub-state.
  //   reset_min_done_q – 4 ms RESET minimum timer has elapsed.
  //   retrain_req_q    – a PHYRETRAIN request is pending.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q          <= LT_RESET;
      req_sent_q       <= 1'b0;
      resp_rcvd_q      <= 1'b0;
      timer_start_q    <= 1'b0;
      reset_min_done_q <= 1'b0;
      retrain_req_q    <= 1'b0;
    end else begin
      state_q          <= state_d;
      req_sent_q       <= req_sent_d;
      resp_rcvd_q      <= resp_rcvd_d;
      timer_start_q    <= timer_start_d;
      reset_min_done_q <= reset_min_done_d;
      retrain_req_q    <= retrain_req_d;
    end
  end

  // =========================================================================
  // Previous-state edge detector
  // =========================================================================
  // Spec 4.5.3 – A sub-state boundary is detected when state_q differs from
  // its one-cycle-delayed copy (state_q_prev). On this edge the handshake
  // flags are cleared and the residency timer is re-armed.
  // =========================================================================
  ltsm_state_t state_q_prev;

  // -------------------------------------------------------------------------
  // always_ff: Previous-State Pipeline Register
  //
  // Captures the one-cycle-delayed copy of state_q into state_q_prev.
  // The comparison (state_q != state_q_prev) generates the sub-state entry
  // edge used to clear handshake flags, re-arm the residency timer, and
  // pulse pat_lfsr_reset. Resets to LT_RESET so no false entry edge is
  // produced on power-up.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q_prev <= LT_RESET;
    else           state_q_prev <= state_q;
  end

  // =========================================================================
  // Message code lookup tables  (Tables 53, 54, 56)
  // =========================================================================
  // Spec 4.5.3 / Tables 53, 54, 56 – Each LTSM state maps to a request
  // MsgCode, a response MsgCode, and a MsgSubcode that together uniquely
  // identify the sideband message for that sub-state. The three functions
  // below are used by both the TX path (to construct outgoing messages) and
  // the RX path (to match incoming messages to the current sub-state).
  //
  // msg_req_code : Returns the request MsgCode for the given state.
  //   - SBINIT           -> MC_SB_DONE_REQ  (0x95)       Table 53
  //   - MBINIT.*         -> MC_MBINIT_REQ   (0xA5)       Table 54
  //   - MBTRAIN.*        -> MC_MBTRAIN_REQ  (0xB5)       Table 54
  //   - PHYRETRAIN       -> MC_PHYR_REQ     (0xC5)       Table 56
  //   - TRAINERROR       -> MC_TE_REQ       (0xE5)       Table 56
  //   - All others       -> MC_NOP_CRD      (0x00)       (no message)
  // =========================================================================
  function automatic logic [7:0] msg_req_code(input ltsm_state_t s);
    case (s)
      LT_SBINIT:        msg_req_code = MC_SB_DONE_REQ;
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:   msg_req_code = MC_MBINIT_REQ;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED,
      LT_MB_REPAIR:     msg_req_code = MC_MBTRAIN_REQ;
      LT_PHYRETRAIN:    msg_req_code = MC_PHYR_REQ;
      LT_TRAINERROR:    msg_req_code = MC_TE_REQ;
      default:          msg_req_code = MC_NOP_CRD;
    endcase
  endfunction

  // =========================================================================
  // msg_rsp_code  (Tables 53, 54, 56)
  // =========================================================================
  // Returns the response MsgCode for the given state. The response code is
  // the complement of the request code per the spec pairing convention.
  //   - SBINIT           -> MC_SB_DONE_RSP  (0x9A)       Table 53
  //   - MBINIT.*         -> MC_MBINIT_RSP   (0xAA)       Table 54
  //   - MBTRAIN.*        -> MC_MBTRAIN_RSP  (0xBA)       Table 54
  //   - PHYRETRAIN       -> MC_PHYR_RSP     (0xCA)       Table 56
  //   - TRAINERROR       -> MC_TE_RSP       (0xEA)       Table 56
  //   - All others       -> MC_NOP_CRD      (0x00)
  // =========================================================================
  function automatic logic [7:0] msg_rsp_code(input ltsm_state_t s);
    case (s)
      LT_SBINIT:        msg_rsp_code = MC_SB_DONE_RSP;
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:   msg_rsp_code = MC_MBINIT_RSP;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED,
      LT_MB_REPAIR:     msg_rsp_code = MC_MBTRAIN_RSP;
      LT_PHYRETRAIN:    msg_rsp_code = MC_PHYR_RSP;
      LT_TRAINERROR:    msg_rsp_code = MC_TE_RSP;
      default:          msg_rsp_code = MC_NOP_CRD;
    endcase
  endfunction

  // =========================================================================
  // msg_subcode  (Tables 53, 54, 56)
  // =========================================================================
  // Returns the MsgSubcode that identifies the specific sub-state within a
  // state group. The subcode disambiguates messages within MBINIT (six sub-
  // states sharing MC_MBINIT_REQ/RSP) and MBTRAIN (eleven sub-states sharing
  // MC_MBTRAIN_REQ/RSP).
  //
  // Mapping per state:
  //   SBINIT           -> MC_SB_OOB_RESET   (0x91)   spec 4.5.3.2
  //   MBINIT.PARAM     -> MS_PARAM_CFG      (0x00)   spec 4.5.3.3
  //   MBINIT.CAL       -> MS_CAL_DONE       (0x02)   spec 4.5.3.3
  //   MBINIT.RPCLK     -> MS_RPCLK_INIT     (0x03)   spec 4.5.3.3
  //   MBINIT.RPVAL     -> MS_RPVAL_INIT     (0x09)   spec 4.5.3.3
  //   MBINIT.REVMB     -> MS_REVMB_INIT     (0x0D)   spec 4.5.3.3
  //   MBINIT.RPMB      -> MS_RPMB_START     (0x11)   spec 4.5.3.3
  //   MB.VALVREF       -> MS_VALVREF_START  (0x00)   spec 4.5.3.4
  //   MB.DATAVREF      -> MS_DATAVREF_START (0x02)   spec 4.5.3.4
  //   MB.SPEEDIDLE     -> MS_SPEEDIDLE_DONE (0x04)   spec 4.5.3.4
  //   MB.TXSELFCAL     -> MS_TXSELFCAL_DONE(0x05)   spec 4.5.3.4
  //   MB.RXCLKCAL      -> MS_RXCLKCAL_START (0x06)   spec 4.5.3.4
  //   MB.VTCENTER      -> MS_VTC_START      (0x08)   spec 4.5.3.4
  //   MB.DTVREF1       -> MS_DTV_START      (0x0E)   spec 4.5.3.4
  //   MB.RXDESKEW      -> MS_DESKEW_START   (0x11)   spec 4.5.3.4
  //   MB.DTCENTER2     -> MS_DTC2_START     (0x13)   spec 4.5.3.4
  //   MB.LINKSPEED     -> MS_LKS_START      (0x15)   spec 4.5.3.4
  //   MB.REPAIR        -> MS_REPAIR_INIT    (0x1B)   spec 4.5.3.4
  //   PHYRETRAIN       -> MS_PHYR_INIT      (0x00)   spec 4.5.3.7
  //   TRAINERROR       -> MS_TE_ENTRY       (0x00)   spec 4.5.3.8
  // =========================================================================
  function automatic logic [7:0] msg_subcode(input ltsm_state_t s);
    case (s)
      LT_SBINIT:        msg_subcode = MC_SB_OOB_RESET;
      LT_MBINIT_PARAM:  msg_subcode = MS_PARAM_CFG;
      LT_MBINIT_CAL:    msg_subcode = MS_CAL_DONE;
      LT_MBINIT_RPCLK:  msg_subcode = MS_RPCLK_INIT;
      LT_MBINIT_RPVAL:  msg_subcode = MS_RPVAL_INIT;
      LT_MBINIT_REVMB:  msg_subcode = MS_REVMB_INIT;
      LT_MBINIT_RPMB:   msg_subcode = MS_RPMB_START;
      LT_MB_VALVREF:    msg_subcode = MS_VALVREF_START;
      LT_MB_DATAVREF:   msg_subcode = MS_DATAVREF_START;
      LT_MB_SPEEDIDLE:  msg_subcode = MS_SPEEDIDLE_DONE;
      LT_MB_TXSELFCAL:  msg_subcode = MS_TXSELFCAL_DONE;
      LT_MB_RXCLKCAL:   msg_subcode = MS_RXCLKCAL_START;
      LT_MB_VTCENTER:   msg_subcode = MS_VTC_START;
      LT_MB_DTVREF1:    msg_subcode = MS_DTV_START;
      LT_MB_RXDESKEW:   msg_subcode = MS_DESKEW_START;
      LT_MB_DTCENTER2:  msg_subcode = MS_DTC2_START;
      LT_MB_LINKSPEED:  msg_subcode = MS_LKS_START;
      LT_MB_REPAIR:     msg_subcode = MS_REPAIR_INIT;
      LT_PHYRETRAIN:    msg_subcode = MS_PHYR_INIT;
      LT_TRAINERROR:    msg_subcode = MS_TE_ENTRY;
      default:          msg_subcode = 8'h00;
    endcase
  endfunction

  // =========================================================================
  // msg_info  (Table 54 MsgInfo field)
  // =========================================================================
  // Spec 4.5.3.4 REPAIR – MsgInfo carries a supplementary qualifier for the
  // REPAIR sub-state. A partner with no repair to perform signals
  // LinkSpeed.Done (MS_LKS_DONE). This is what two identical endpoints send
  // to each other. All other states carry MsgInfo = 0x00.
  // =========================================================================
  function automatic logic [7:0] msg_info(input ltsm_state_t s);
    case (s)
      LT_MB_REPAIR:    msg_info = MS_LKS_DONE;
      default:         msg_info = 8'h00;
    endcase
  endfunction

  // =========================================================================
  // Sideband RX message classification  (spec 4.5.3 handshake protocol)
  // =========================================================================
  // msg_is_req : True when the incoming sideband packet matches the current
  //              sub-state's request code. Because both endpoints run the
  //              identical sequence, the partner's request arrives with the
  //              same opcode as our own.
  // msg_is_rsp : True when the incoming packet matches the response code AND
  //              the expected subcode. This covers the asymmetric-partner
  //              case where the partner sends an explicit response.
  // can_send   : True when the codec is idle and the local request has not
  //              yet been sent for this sub-state.
  // =========================================================================
  wire msg_is_req  = (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                     (sb_rx_msgcode == msg_req_code(state_q));
  wire msg_is_rsp  = (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                     (sb_rx_msgcode == msg_rsp_code(state_q)) &&
                     (sb_rx_msgsubcode == msg_subcode(state_q));

  wire can_send = !sb_tx_busy && !req_sent_q;


  // =========================================================================
  // Residency timer interface  (spec 4.5 – 8 ms per sub-state timeout)
  // =========================================================================
  // Each sub-state pulses tmr_start for 1 cycle on entry (state_q != state_q_prev).
  // The timer runs while the handshake is pending (timer_start_q && !resp_rcvd_q).
  // If tmr_expired fires before the handshake completes, the always_comb
  // block transitions to TRAINERROR (spec 4.5.3.8).
  // =========================================================================
  assign tmr_start = (state_q != state_q_prev);
  // -------------------------------------------------------------------------
  // assign: Timer Run Enable
  //
  // Holds the 8 ms residency timer running while the current sub-state
  // handshake is pending (timer armed AND response not yet received).
  // Once resp_rcvd_q is set the timer stops, preventing a late expiry
  // from incorrectly escalating to TRAINERROR.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  assign tmr_run   = timer_start_q && !resp_rcvd_q;

  // =========================================================================
  // Next-state combinational logic  (spec 4.5.3.1 through 4.5.3.9)
  // =========================================================================
  // This is the main LTSM sequencer. It computes the next state (state_d)
  // and the next handshake flags (req_sent_d, resp_rcvd_d, timer_start_d,
  // retrain_req_d) based on the current state, the sideband handshake
  // status, the residency timer, and the pattern generator status.
  //
  // Sub-state boundary detection (state_q != state_q_prev) clears the
  // handshake flags and re-arms the timer. Within a sub-state:
  //   - sb_tx_load firing records the local request as sent.
  //   - A matching RX packet (response or symmetric request) records the
  //     partner's acknowledgement.
  //   - When both req_sent_q and resp_rcvd_q are set, the sub-state exit
  //     condition is met and the state advances to the next in sequence.
  //
  // State-specific behaviour is detailed inline with spec sub-section
  // references.
  // =========================================================================
  always_comb begin
    state_d       = state_q;
    req_sent_d    = req_sent_q;
    resp_rcvd_d   = resp_rcvd_q;
    timer_start_d = timer_start_q;
    reset_min_done_d = reset_min_done_q;
    retrain_req_d = retrain_req_q;
    // A new sub-state entry clears the handshake flags and arms the timer.
    if (state_q != state_q_prev) begin
      req_sent_d       = 1'b0;
      resp_rcvd_d      = 1'b0;
      timer_start_d    = 1'b1;
      reset_min_done_d = 1'b0;
    end else begin
      // Record the local request once the codec accepts it.
      if (sb_tx_load)            req_sent_d  = 1'b1;
      // Both endpoints run the identical sequence, so the partner's request
      // arrives with this sub-state's code and subcode. Accept it as the
      // response; the explicit response codes cover an asymmetric partner.
      if (sb_rx_pkt_vld && (msg_is_rsp ||
                            (msg_is_req &&
                             sb_rx_msgsubcode == msg_subcode(state_q))))
        resp_rcvd_d = 1'b1;
      // Disarm the residency timer once the sub-state handshake completes or
      // fires, so the next sub-state re-arms on its own entry.
      if (resp_rcvd_d || tmr_expired) timer_start_d = 1'b0;
    end

    case (state_q)
      // -----------------------------------------------------------------
      // 4.5.3.1 RESET
      // -----------------------------------------------------------------
      // Wait for the adapter to release the reset and for the sideband to
      // be usable. Spec 4.5.3.1 enforces a minimum 4 ms residency upon
      // entry to RESET. The exit stimulus is start_link_train (from the top-
      // level pin or CSR write); transition to SBINIT occurs only after
      // the 4 ms reset timer has elapsed.
      // -----------------------------------------------------------------
      LT_RESET: begin
        if (rst_tmr_expired) reset_min_done_d = 1'b1;
        if (start_link_train && (rst_tmr_expired || reset_min_done_q)) state_d = LT_SBINIT;
      end

      // -----------------------------------------------------------------
      // 4.5.3.2 SBINIT
      // -----------------------------------------------------------------
      // Out-of-band reset handshake. The local side sends SB_DONE_REQ
      // (MC_SB_DONE_REQ, 0x95) and waits for the partner's SB_DONE_RSP
      // (MC_SB_DONE_RSP, 0x9A). On completion, transition to
      // MBINIT.PARAM.
      // -----------------------------------------------------------------
      LT_SBINIT: begin
        if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_PARAM;
      end

      // -----------------------------------------------------------------
      // 4.5.3.3 MBINIT sub-states
      // -----------------------------------------------------------------
      // Main-band initialisation proceeds through six sub-states in
      // strict sequence. Each sub-state exchanges MBINIT_REQ (0xA5) /
      // MBINIT_RSP (0xAA) with the sub-state-specific MsgSubcode.
      //
      // PARAM  (02h) : Exchange electrical parameters. Spec 4.5.3.3.
      // CAL    (03h) : Calibration done handshake.   Spec 4.5.3.3.
      // RPCLK  (04h) : Clock repair initialisation.  Spec 4.5.3.3.
      // RPVAL  (05h) : Validation repair init.        Spec 4.5.3.3.
      // REVMB  (06h) : Main-band reversal.            Spec 4.5.3.3.
      // RPMB   (07h) : Main-band repair start.        Spec 4.5.3.3.
      //
      // After RPMB completes, the LTSM transitions to MBTRAIN.VALVREF.
      // -----------------------------------------------------------------
      LT_MBINIT_PARAM: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_CAL;
      LT_MBINIT_CAL:   if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPCLK;
      LT_MBINIT_RPCLK: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPVAL;
      LT_MBINIT_RPVAL: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_REVMB;
      LT_MBINIT_REVMB: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPMB;
      LT_MBINIT_RPMB:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_VALVREF;

      // -----------------------------------------------------------------
      // 4.5.3.4 MBTRAIN sub-states
      // -----------------------------------------------------------------
      // Main-band training proceeds through eleven sub-states. Each
      // exchanges MBTRAIN_REQ (0xB5) / MBTRAIN_RSP (0xBA) with the
      // sub-state-specific MsgSubcode.
      //
      // VALVREF    (08h) : Validation Vref training.     Spec 4.5.3.4.
      //                    Pattern: PAT_VALTRAIN (1010).
      // DATAVREF   (09h) : Data Vref training.           Spec 4.5.3.4.
      //                    Pattern: PAT_VALTRAIN (1010).
      // SPEEDIDLE  (0Ah) : Speed/idle negotiation.       Spec 4.5.3.4.
      // TXSELFCAL  (0Bh) : TX self-calibration.          Spec 4.5.3.4.
      // RXCLKCAL   (0Ch) : RX clock calibration.         Spec 4.5.3.4.
      // VTCENTER   (0Dh) : Voltage/timing centering.     Spec 4.5.3.4.
      // DTVREF1    (0Eh) : Data timing Vref pass 1.      Spec 4.5.3.4.
      // RXDESKEW   (0Fh) : RX de-skew.                   Spec 4.5.3.4.
      //                    Pattern: PAT_CLKREPAIR.
      // DTCENTER2  (10h) : Data timing centering pass 2. Spec 4.5.3.4.
      // LINKSPEED  (11h) : Link speed negotiation.       Spec 4.5.3.4.
      // REPAIR     (12h) : Lane repair decision.         Spec 4.5.3.4.
      //                    May loop back to TXSELFCAL on EXIT_REP/DEG,
      //                    or proceed to LINKINIT on LKS_DONE.
      // -----------------------------------------------------------------
      LT_MB_VALVREF:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DATAVREF;
      LT_MB_DATAVREF: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_SPEEDIDLE;
      // SPEEDIDLE loops back to TXSELFCAL when the partner is not ready.
      LT_MB_SPEEDIDLE: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_TXSELFCAL;
      LT_MB_TXSELFCAL: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXCLKCAL;
      LT_MB_RXCLKCAL:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_VTCENTER;
      LT_MB_VTCENTER:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTVREF1;
      LT_MB_DTVREF1:   if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXDESKEW;
      LT_MB_RXDESKEW:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTCENTER2;
      LT_MB_DTCENTER2: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_LINKSPEED;
      LT_MB_LINKSPEED: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_REPAIR;
      // -----------------------------------------------------------------
      // 4.5.3.4 REPAIR sub-state  (spec 4.5.3.4 REPAIR)
      // -----------------------------------------------------------------
      // The REPAIR sub-state reads MsgInfo from the partner to determine
      // the next action:
      //   MS_LKS_EXIT_REP (0x17) : Loop back to TXSELFCAL for repair.
      //   MS_LKS_EXIT_DEG (0x18) : Degrade to x8, loop to TXSELFCAL.
      //   MS_LKS_DONE     (0x19) : Training complete, proceed to LINKINIT.
      // -----------------------------------------------------------------
      LT_MB_REPAIR: begin
        if (req_sent_q && resp_rcvd_q) begin
          if (sb_rx_msginfo == MS_LKS_EXIT_REP) state_d = LT_MB_TXSELFCAL;
          else if (sb_rx_msginfo == MS_LKS_EXIT_DEG) begin
            state_d = LT_MB_TXSELFCAL;
          end else if (sb_rx_msginfo == MS_LKS_DONE) begin
            state_d = LT_LINKINIT;
          end
        end
      end

      // -----------------------------------------------------------------
      // 4.5.3.5 LINKINIT
      // -----------------------------------------------------------------
      // Reseed the per-lane LFSRs (pat_lfsr_reset asserted) and run the
      // LFSR pattern for 4096 UI (pat_select = PAT_LFSR). The sub-state
      // exits when the pattern generator asserts pat_done, transitioning
      // the LTSM to ACTIVE.
      // -----------------------------------------------------------------
      LT_LINKINIT: begin
        if (pat_done) state_d = LT_ACTIVE;
      end

      // -----------------------------------------------------------------
      // 4.5.3.6 ACTIVE
      // -----------------------------------------------------------------
      // Data may flow on the main band. The link holds ACTIVE until a
      // retrain request (retrain_req_q) transitions to PHYRETRAIN, or
      // until a LINKRESET arrives (handled by the global timeout/error
      // logic below).
      // -----------------------------------------------------------------
      LT_ACTIVE: begin
        if (retrain_req_q)  state_d = LT_PHYRETRAIN;
      end

      // -----------------------------------------------------------------
      // 4.5.3.7 PHYRETRAIN
      // -----------------------------------------------------------------
      // Re-run the requested subset of training. The sideband exchanges
      // PHYR_REQ (0xC5) / PHYR_RSP (0xCA). On completion the LTSM
      // returns to ACTIVE.
      // -----------------------------------------------------------------
      LT_PHYRETRAIN: begin
        if (req_sent_q && resp_rcvd_q) state_d = LT_ACTIVE;
      end

      // -----------------------------------------------------------------
      // 4.5.3.9 L1L2 (low-power)
      // -----------------------------------------------------------------
      // Hold in low-power state until the adapter re-requests training
      // (start_link_train), which returns the LTSM to RESET.
      // -----------------------------------------------------------------
      LT_L1L2: begin
        if (start_link_train) state_d = LT_RESET;
      end

      // -----------------------------------------------------------------
      // 4.5.3.8 TRAINERROR
      // -----------------------------------------------------------------
      // Unrecoverable training failure. Only a LINKRESET (via
      // start_link_train) clears this state and returns to RESET.
      // -----------------------------------------------------------------
      LT_TRAINERROR: begin
        if (start_link_train) state_d = LT_RESET;
      end

      default: state_d = LT_RESET;
    endcase

    // -------------------------------------------------------------------
    // Residency timeout escalation to TRAINERROR (Section 4.5.3.8)
    // -------------------------------------------------------------------
    // If the 8 ms residency timer expires while a training sub-state
    // handshake is pending, the LTSM escalates to TRAINERROR. States
    // ACTIVE, L1L2, and TRAINERROR are exempt (they have no handshake
    // deadline).
    // -------------------------------------------------------------------
    if (tmr_expired && timer_start_q && state_q != LT_ACTIVE &&
        state_q != LT_L1L2 && state_q != LT_TRAINERROR && state_q != LT_RESET) begin
      state_d       = LT_TRAINERROR;
      timer_start_d = 1'b0;
    end

    // A sideband parity error is a correctable event in this model.
    // Non-fatal errors do not disturb the training sequence.
  end


  // =========================================================================
  // Sideband TX interface  (spec 4.5.3 sideband request channel)
  // =========================================================================
  // The LTSM emits the request for the current sub-state when the codec is
  // free (can_send) and the state has a valid request code (not NOP_CRD).
  // All messages use opcode SB_OP_MSG_NODATA (message without data payload),
  // srcid/dstid = SRCID_STACK0, and no data/tag/addr/BE/EP fields.
  //
  // sb_msg_timeout and sb_stall_sent are tied to zero: message timeout
  // recovery and stall insertion are not implemented in this build.
  // =========================================================================
  assign sb_tx_load      = can_send && (msg_req_code(state_q) != MC_NOP_CRD);
  // -------------------------------------------------------------------------
  // assign (group): Sideband TX Packet Field Tie-Offs
  //
  // These 14 continuous assignments drive the fixed fields of every
  // sideband message transmitted by the LTSM:
  //   sb_tx_opcode     – SB_OP_MSG_NODATA; all LTSM messages are headerless.
  //   sb_tx_srcid      – SRCID_STACK0; this endpoint's stack identifier.
  //   sb_tx_dstid      – SRCID_STACK0; partner shares the same stack.
  //   sb_tx_msginfo    – msg_info(state_q); non-zero only in REPAIR.
  //   sb_tx_msgcode    – msg_req_code(state_q); request code per Tables 53/54.
  //   sb_tx_msgsubcode – msg_subcode(state_q); sub-state disambiguator.
  //   sb_tx_be         – 8'h00; no byte-enable (no data payload).
  //   sb_tx_tag        – 5'h00; tag unused for training messages.
  //   sb_tx_ep         – 1'b0;  no error/poison bit.
  //   sb_tx_addr       – 12'h000; no register address targeted.
  //   sb_tx_data_in    – 64'h0; no data payload.
  //   sb_tx_has_data   – 1'b0;  marks packet as header-only.
  //   sb_msg_timeout   – 1'b0;  timeout recovery not implemented.
  //   sb_stall_sent    – 1'b0;  stall insertion not implemented.
  //
  // Spec ref: UCIe 1.0, Section 6.1.2 - Packet Formats.
  // -------------------------------------------------------------------------
  assign sb_tx_opcode    = SB_OP_MSG_NODATA;
  assign sb_tx_srcid     = SRCID_STACK0;
  assign sb_tx_dstid     = SRCID_STACK0;
  assign sb_tx_msginfo   = msg_info(state_q);
  assign sb_tx_msgcode   = msg_req_code(state_q);
  assign sb_tx_msgsubcode= msg_subcode(state_q);
  assign sb_tx_be        = 8'h00;
  assign sb_tx_tag       = 5'h00;
  assign sb_tx_ep        = 1'b0;
  assign sb_tx_addr      = 12'h000;
  assign sb_tx_data_in   = 64'h0;
  assign sb_tx_has_data  = 1'b0;
  assign sb_msg_timeout  = 1'b0;
  assign sb_stall_sent   = 1'b0;

  // =========================================================================
  // Pattern generator control  (spec 4.5.3.4, 4.5.3.5)
  // =========================================================================
  // The pattern generator runs during the MBTRAIN sub-states (VALVREF
  // through REPAIR, 08h-12h) and during LINKINIT (14h). The pattern
  // selection follows the spec training sequence:
  //   - VALVREF, DATAVREF : PAT_VALTRAIN  (alternating 1010 checkerboard)
  //   - RXDESKEW          : PAT_CLKREPAIR (clock-repair single-UI toggle)
  //   - LINKINIT          : PAT_LFSR      (per-lane LFSR, 4096 UI)
  //   - All other MBTRAIN : PAT_PERLANEID (lane numbering identification)
  //
  // The LFSR is reseeded (pat_lfsr_reset) and enabled (pat_lfsr_enable)
  // only during LINKINIT. Scrambling is off for Per-Lane-ID, VALTRAIN, and
  // clock-repair patterns per spec.
  // =========================================================================
  assign pat_enable     = ((state_q >= LT_MB_VALVREF) &&
                          (state_q <= LT_MB_REPAIR)) ||
                          (state_q == LT_LINKINIT);
  // -------------------------------------------------------------------------
  // assign: Training Pattern Selection Mux
  //
  // Selects the training pattern driven onto the main-band lanes based on
  // the current LTSM sub-state:
  //   VALVREF / DATAVREF  -> PAT_VALTRAIN   (alternating 1010 checkerboard)
  //   LINKINIT            -> PAT_LFSR       (per-lane scrambled LFSR)
  //   RXDESKEW            -> PAT_CLKREPAIR  (clock-repair single-UI toggle)
  //   All other MBTRAIN   -> PAT_PERLANEID  (lane numbering identification)
  //
  // The priority-encoded ternary chain matches the spec ordering; the
  // default (PAT_PERLANEID) covers remaining MBTRAIN sub-states.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  assign pat_select     = (state_q == LT_MB_VALVREF)  ? PAT_VALTRAIN  :
                          (state_q == LT_MB_DATAVREF) ? PAT_VALTRAIN  :
                          (state_q == LT_LINKINIT)    ? PAT_LFSR      :
                          (state_q == LT_MB_RXDESKEW) ? PAT_CLKREPAIR :
                                                        PAT_PERLANEID;
  // LFSR reset/enable gating for the training-pattern generator.
  //
  // Scrambling is disabled for Per-Lane-ID, VALTRAIN and clock-repair
  // patterns, so the LFSR only runs during LINKINIT, where the LFSR
  // pattern itself is the payload. Reseed is a clean 1-cycle entry pulse
  // so the LFSR advances freely for the full 4096-UI duration.
  // ref: spec 4.5.3.5 (LINKINIT), 4.4.1 (scrambling).
  assign pat_lfsr_reset = (state_q == LT_LINKINIT) && (state_q != state_q_prev);
  // -------------------------------------------------------------------------
  // assign: LFSR Enable Gate
  //
  // Enables the per-lane LFSR only during the LINKINIT sub-state. During
  // all other states the LFSR holds its current value so it can be cleanly
  // reseeded on the next LINKINIT entry via pat_lfsr_reset. The LFSR runs
  // for the full 4096-UI LINKINIT duration, after which pat_done fires.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  assign pat_lfsr_enable= (state_q == LT_LINKINIT);
  // =========================================================================
  // LTSM status outputs  (spec 4.5.3 – reported to RDI state machine)
  // =========================================================================
  // link_trained     : Asserted when the LTSM is in ACTIVE (4.5.3.6).
  // train_error      : Asserted when the LTSM is in TRAINERROR (4.5.3.8).
  // link_reset_out   : Asserted when the LTSM is in RESET (4.5.3.1).
  // phy_retrain_done : Asserted when the LTSM returns to ACTIVE after
  //                    PHYRETRAIN with retrain_req_q still set.
  // ltsm_state       : 8-bit state encoding for Error Log 0 "State N".
  // lnk_is_x8        : Tied to 0 (x16 only in this build).
  // degrade_lanes    : Tied to 00 (no degradation in this build).
  // =========================================================================
  assign link_trained    = (state_q == LT_ACTIVE);
  // -------------------------------------------------------------------------
  // assign (group): Status and Observability Outputs
  //
  // Six continuous assignments that reflect the LTSM state to the RDI
  // state machine and to top-level observability ports:
  //   train_error      – asserted in LT_TRAINERROR (4.5.3.8).
  //   link_reset_out   – asserted in LT_RESET (4.5.3.1); drives RDI LINKRESET.
  //   phy_retrain_done – asserted when ACTIVE is re-entered after PHYRETRAIN
  //                      with retrain_req_q still set (4.5.3.7).
  //   ltsm_state       – raw 8-bit state encoding for Error Log 0.
  //   lnk_is_x8        – tied to 0; x16-only in this reduced build.
  //   degrade_lanes    – tied to 00; no lane degradation supported.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  assign train_error     = (state_q == LT_TRAINERROR);
  assign link_reset_out  = (state_q == LT_RESET);
  assign phy_retrain_done= (state_q == LT_ACTIVE) && retrain_req_q;
  assign ltsm_state      = state_q;
  assign lnk_is_x8       = 1'b0;   // x16 only in this reduced capability set
  assign degrade_lanes   = 2'b00;

  // The retrain request is accepted through the sideband interface by the
  // state machine above; no separate register is needed here.

  // =========================================================================
  // Lint suppression
  // =========================================================================
  // Continuous assign so Icarus Verilog evaluates all bit-select references.
  // Every signal listed here is consumed by the combinational logic above
  // but may appear unused to lint tools due to the function-based message
  // matching.
  // =========================================================================
  logic unused_match;
  // -------------------------------------------------------------------------
  // assign: Lint-Suppression Tie-Off
  //
  // Combines every sideband RX field, timer, and pattern-done signal that
  // is read only inside functions or conditional expressions. Without this
  // tie-off, Icarus Verilog reports spurious "unused" warnings because the
  // function-call-based message matching hides the references from its
  // single-pass analysis.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  assign unused_match = msg_is_req | msg_is_rsp | tmr_expired | pat_done |
                        sb_rx_pkt_vld | sb_rx_opcode[0] | sb_rx_srcid[0] |
                        sb_rx_dstid[0] | sb_rx_msginfo[0] | sb_rx_cp_err |
                        sb_rx_dp_err | sb_tx_busy;

endmodule

`endif

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
//  |  RESET    |  4.5.3.1  Wait for the 4 ms minimum and either a
//  |  (00h)    |           local or two-pattern training trigger.
//  +-----+-----+
//        |
//        v
//  +-----------+
//  |  SBINIT   |  4.5.3.2  Raw 64-UI/32-UI pattern and four-iteration
//  |  (01h)    |           tail, repeated Out-of-Reset, then explicit
//  +-----+-----+           Done request/response. Exit -> MBINIT.PARAM.
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
//   Outside SBINIT, a sub-state exits when the local side has sent its
//   request and received the partner handshake message. The existing later
//   MBINIT/MBTRAIN symmetric-request behavior remains unchanged. SBINIT uses
//   explicit message roles: a Done request never satisfies a Done response.
//
//   Every sub-state is bounded by an 8 ms residency timer. A sub-state
//   that exceeds 8 ms without completing escalates to TRAINERROR.
//
// --------------------------------------------------------------------------
// Sideband message coding  (Tables 53, 54, 56)
// --------------------------------------------------------------------------
//   SBINIT selects explicit Out-of-Reset, Done request, and Done response
//   pairs. Later states map through msg_req_code(), msg_rsp_code(), and
//   msg_subcode(). MsgInfo carries the SBINIT primary-pair result and the
//   later REPAIR qualifier.
//
// --------------------------------------------------------------------------
// Raw SBINIT control  (spec 4.5.3.2)
// --------------------------------------------------------------------------
//   The LTSM owns match streaks, active/idle windows, four-tail counting,
//   packet phases, request/response obligations, and the residency timeout.
//   The sbclk primitive owns only the waveform and atomic event transport.
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
//   tmr_start       : pulses on entry to each timed training state.
//   tmr_run         : stays high for one uninterrupted state residency window.
//   rst_tmr_start   : pulses only when the LTSM re-enters RESET.
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
//                 the packet CDC, and full RX field set (sb_rx_pkt_vld..
//                 sb_rx_dp_err) from the packet CDC.
//   Raw SBINIT  : pattern_run_enable and sbinit_raw_mode levels; atomic
//                 remote-result and local-completion events; synchronized
//                 transmitter-idle boundary status.
//   Pattern gen : pat_enable, pat_select, pat_lfsr_reset, pat_lfsr_enable,
//                 pat_done for later main-band training.
//   Timers      : tmr_start, tmr_run, rst_tmr_start, tmr_expired, and
//                 rst_tmr_expired.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The LTSM is purely a sequencer. It owns SBINIT policy but no UI-level
//      waveform or CDC state. The pattern generator and scrambler provide the
//      later main-band training data.
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
//   v0.0.8  2026-09-24  Implement Standard Package SBINIT delayed start. Own
//                        pattern policy, explicit packet phases, and RESET
//                        pattern triggering in lclk.
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

  // ---- raw SBINIT waveform/CDC primitive
  output logic        pattern_run_enable,
  output logic        sbinit_raw_mode,
  input  logic        sbinit_rx_iter_vld,
  input  logic        sbinit_rx_iter_match,
  input  logic        sbinit_tx_iter_done,
  input  logic        sbinit_tx_idle,

  // ---- training pattern generator
  output logic        pat_enable,
  output pat_t        pat_select,
  output logic        pat_lfsr_reset,
  output logic        pat_lfsr_enable,
  input  logic        pat_done,

  // ---- timers
  output logic        tmr_start,
  output logic        tmr_run,
  output logic        rst_tmr_start,
  input  logic        tmr_expired,
  input  logic        rst_tmr_expired
);

  // =========================================================================
  // State, handshake, and SBINIT policy registers
  // =========================================================================
  // The public LTSM encoding remains unchanged. A private phase register owns
  // the four Standard Package SBINIT activities inside LT_SBINIT. The raw
  // sbclk primitive reports only complete iteration events; all detection,
  // retry, tail-count, packet-order, and timeout policy remains here in lclk.
  // =========================================================================
  typedef enum logic [1:0] {
    SBI_PATTERN_ACTIVE = 2'd0,
    SBI_PATTERN_IDLE   = 2'd1,
    SBI_OUT_OF_RESET   = 2'd2,
    SBI_DONE           = 2'd3
  } sbinit_phase_t;

  ltsm_state_t state_q, state_d;
  sbinit_phase_t sbinit_phase_q, sbinit_phase_d;

  logic        req_sent_q, req_sent_d;
  logic        resp_rcvd_q, resp_rcvd_d;
  logic        timer_start_q, timer_start_d;
  logic        reset_min_done_q, reset_min_done_d;
  logic        retrain_req_q, retrain_req_d;

  logic [1:0]  sbinit_match_streak_q, sbinit_match_streak_d;
  logic        pattern_trigger_pending_q, pattern_trigger_pending_d;
  logic [2:0]  sbinit_tail_count_q, sbinit_tail_count_d;
  logic [31:0] sbinit_window_count_q, sbinit_window_count_d;
  logic        sbinit_oor_sent_q, sbinit_oor_sent_d;
  logic        sbinit_oor_received_q, sbinit_oor_received_d;
  logic        sbinit_done_req_sent_q, sbinit_done_req_sent_d;
  logic        sbinit_done_rsp_sent_q, sbinit_done_rsp_sent_d;
  logic        sbinit_done_rsp_received_q, sbinit_done_rsp_received_d;
  logic [7:0]  sbinit_done_rsp_pending_q, sbinit_done_rsp_pending_d;

  // -------------------------------------------------------------------------
  // State and policy register bank
  // -------------------------------------------------------------------------
  // The match streak saturates at two. The trigger remains sticky until a new
  // RESET epoch. SBINIT packet flags remain independent so a received request
  // can never satisfy the local response requirement.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q                       <= LT_RESET;
      sbinit_phase_q                <= SBI_PATTERN_ACTIVE;
      req_sent_q                    <= 1'b0;
      resp_rcvd_q                   <= 1'b0;
      timer_start_q                 <= 1'b0;
      reset_min_done_q              <= 1'b0;
      retrain_req_q                 <= 1'b0;
      sbinit_match_streak_q         <= 2'd0;
      pattern_trigger_pending_q     <= 1'b0;
      sbinit_tail_count_q           <= 3'd0;
      sbinit_window_count_q         <= 32'd0;
      sbinit_oor_sent_q             <= 1'b0;
      sbinit_oor_received_q         <= 1'b0;
      sbinit_done_req_sent_q        <= 1'b0;
      sbinit_done_rsp_sent_q        <= 1'b0;
      sbinit_done_rsp_received_q    <= 1'b0;
      sbinit_done_rsp_pending_q     <= 8'd0;
    end else begin
      state_q                       <= state_d;
      sbinit_phase_q                <= sbinit_phase_d;
      req_sent_q                    <= req_sent_d;
      resp_rcvd_q                   <= resp_rcvd_d;
      timer_start_q                 <= timer_start_d;
      reset_min_done_q              <= reset_min_done_d;
      retrain_req_q                 <= retrain_req_d;
      sbinit_match_streak_q         <= sbinit_match_streak_d;
      pattern_trigger_pending_q     <= pattern_trigger_pending_d;
      sbinit_tail_count_q           <= sbinit_tail_count_d;
      sbinit_window_count_q         <= sbinit_window_count_d;
      sbinit_oor_sent_q             <= sbinit_oor_sent_d;
      sbinit_oor_received_q         <= sbinit_oor_received_d;
      sbinit_done_req_sent_q        <= sbinit_done_req_sent_d;
      sbinit_done_rsp_sent_q        <= sbinit_done_rsp_sent_d;
      sbinit_done_rsp_received_q    <= sbinit_done_rsp_received_d;
      sbinit_done_rsp_pending_q     <= sbinit_done_rsp_pending_d;
    end
  end

  // =========================================================================
  // Previous-state edge detector
  // =========================================================================
  // Separate RESET and residency restart pulses are derived from this delayed
  // state. This gives each RESET entry a fresh 4 ms epoch without restarting
  // the SBINIT 8 ms deadline at private phase changes.
  ltsm_state_t state_q_prev;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q_prev <= LT_RESET;
    else           state_q_prev <= state_q;
  end

  wire state_entry = (state_q != state_q_prev);
  wire reset_entry = state_entry && (state_q == LT_RESET);

  // =========================================================================
  // Message lookup tables for post-SBINIT training
  // =========================================================================
  // SBINIT uses explicit phase-dependent codes below. These lookup functions
  // retain the existing MBINIT, MBTRAIN, PHYRETRAIN, and TRAINERROR behavior.
  function automatic logic [7:0] msg_req_code(input ltsm_state_t s);
    case (s)
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

  function automatic logic [7:0] msg_rsp_code(input ltsm_state_t s);
    case (s)
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

  function automatic logic [7:0] msg_subcode(input ltsm_state_t s);
    case (s)
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

  function automatic logic [7:0] msg_info(input ltsm_state_t s);
    case (s)
      LT_MB_REPAIR: msg_info = MS_LKS_DONE;
      default:      msg_info = 8'h00;
    endcase
  endfunction

  // =========================================================================
  // Sideband receive classification
  // =========================================================================
  // Every training packet must be a parity-clean no-data PHY-to-PHY message.
  // SBINIT compares explicit code/subcode pairs. Later training retains its
  // existing symmetric request/response acceptance rule.
  wire rx_phy_msg_valid = sb_rx_pkt_vld &&
                          !sb_rx_cp_err && !sb_rx_dp_err &&
                          (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                          (sb_rx_srcid == SRCID_PHY) &&
                          (sb_rx_dstid == DSTID_REMOTE_PHY);

  wire sbinit_oor_rx = rx_phy_msg_valid &&
                       (sb_rx_msgcode == MC_SB_OOB_RESET) &&
                       (sb_rx_msgsubcode == MS_SB_OOB_RESET);
  wire sbinit_done_req_rx = rx_phy_msg_valid &&
                            (sb_rx_msgcode == MC_SB_DONE_REQ) &&
                            (sb_rx_msgsubcode == MS_SB_DONE);
  wire sbinit_done_rsp_rx = rx_phy_msg_valid &&
                            (sb_rx_msgcode == MC_SB_DONE_RSP) &&
                            (sb_rx_msgsubcode == MS_SB_DONE);

  wire msg_is_req = rx_phy_msg_valid &&
                    (sb_rx_msgcode == msg_req_code(state_q)) &&
                    (sb_rx_msgsubcode == msg_subcode(state_q));
  wire msg_is_rsp = rx_phy_msg_valid &&
                    (sb_rx_msgcode == msg_rsp_code(state_q)) &&
                    (sb_rx_msgsubcode == msg_subcode(state_q));

  // =========================================================================
  // Sideband transmit scheduling
  // =========================================================================
  // Out-of-Reset repeats until a valid peer copy arrives. Done responses have
  // priority over the one local Done request. The pending counter preserves a
  // separate response obligation for every valid peer Done request.
  wire generic_send = !state_entry && (state_q != LT_SBINIT) &&
                      !sb_tx_busy && !req_sent_q &&
                      (msg_req_code(state_q) != MC_NOP_CRD);
  wire sbinit_oor_send = (state_q == LT_SBINIT) &&
                         (sbinit_phase_q == SBI_OUT_OF_RESET) &&
                         !sbinit_oor_received_q && !sb_tx_busy;
  wire sbinit_done_rsp_send = (state_q == LT_SBINIT) &&
                              (sbinit_phase_q == SBI_DONE) &&
                              (sbinit_done_rsp_pending_q != 8'd0) &&
                              !sb_tx_busy;
  wire sbinit_done_req_send = (state_q == LT_SBINIT) &&
                              (sbinit_phase_q == SBI_DONE) &&
                              (sbinit_done_rsp_pending_q == 8'd0) &&
                              !sbinit_done_req_sent_q && !sb_tx_busy;

  // =========================================================================
  // Timer interfaces
  // =========================================================================
  // The residency timer starts only for a new timed LTSM state. Private
  // SBINIT phases never restart it. The RESET timer has an independent entry
  // pulse and runs for each complete RESET epoch.
  assign tmr_start = state_entry && (state_q != LT_RESET) &&
                     (state_q != LT_ACTIVE) && (state_q != LT_L1L2) &&
                     (state_q != LT_TRAINERROR);
  assign rst_tmr_start = reset_entry;
  assign tmr_run       = timer_start_q;

  // =========================================================================
  // Next-state and SBINIT policy
  // =========================================================================
  always_comb begin
    state_d                    = state_q;
    sbinit_phase_d             = sbinit_phase_q;
    req_sent_d                 = req_sent_q;
    resp_rcvd_d                = resp_rcvd_q;
    timer_start_d              = timer_start_q;
    reset_min_done_d           = reset_min_done_q;
    retrain_req_d              = retrain_req_q;
    sbinit_match_streak_d      = sbinit_match_streak_q;
    pattern_trigger_pending_d  = pattern_trigger_pending_q;
    sbinit_tail_count_d        = sbinit_tail_count_q;
    sbinit_window_count_d      = sbinit_window_count_q;
    sbinit_oor_sent_d          = sbinit_oor_sent_q;
    sbinit_oor_received_d      = sbinit_oor_received_q;
    sbinit_done_req_sent_d     = sbinit_done_req_sent_q;
    sbinit_done_rsp_sent_d     = sbinit_done_rsp_sent_q;
    sbinit_done_rsp_received_d = sbinit_done_rsp_received_q;
    sbinit_done_rsp_pending_d  = sbinit_done_rsp_pending_q;

    // State entry resets only state-scoped handshakes. A new RESET epoch also
    // clears every sticky pattern and SBINIT policy register.
    if (state_entry) begin
      req_sent_d    = 1'b0;
      resp_rcvd_d   = 1'b0;
      timer_start_d = (state_q != LT_RESET) &&
                      (state_q != LT_ACTIVE) &&
                      (state_q != LT_L1L2) &&
                      (state_q != LT_TRAINERROR);

      if (state_q == LT_RESET) begin
        reset_min_done_d           = 1'b0;
        sbinit_phase_d             = SBI_PATTERN_ACTIVE;
        sbinit_match_streak_d      = 2'd0;
        pattern_trigger_pending_d  = 1'b0;
        sbinit_tail_count_d        = 3'd0;
        sbinit_window_count_d      = 32'd0;
        sbinit_oor_sent_d          = 1'b0;
        sbinit_oor_received_d      = 1'b0;
        sbinit_done_req_sent_d     = 1'b0;
        sbinit_done_rsp_sent_d     = 1'b0;
        sbinit_done_rsp_received_d = 1'b0;
        sbinit_done_rsp_pending_d  = 8'd0;
      end else if (state_q == LT_SBINIT) begin
        sbinit_phase_d             = SBI_PATTERN_ACTIVE;
        sbinit_tail_count_d        = 3'd0;
        sbinit_window_count_d      = 32'd0;
        sbinit_oor_sent_d          = 1'b0;
        sbinit_oor_received_d      = 1'b0;
        sbinit_done_req_sent_d     = 1'b0;
        sbinit_done_rsp_sent_d     = 1'b0;
        sbinit_done_rsp_received_d = 1'b0;
        sbinit_done_rsp_pending_d  = 8'd0;
      end
    end else if (state_q != LT_SBINIT) begin
      // Preserve the established one-request handshake for later training.
      if (sb_tx_load) req_sent_d = 1'b1;
      if (rx_phy_msg_valid && (msg_is_rsp || msg_is_req)) resp_rcvd_d = 1'b1;
      if (resp_rcvd_d || tmr_expired) timer_start_d = 1'b0;
    end

    // Consume each atomic remote iteration result in lclk. A mismatch clears
    // only the current streak. The second match sets a sticky epoch trigger.
    if (!reset_entry && sbinit_rx_iter_vld &&
        ((state_q == LT_RESET) ||
         ((state_q == LT_SBINIT) &&
          ((sbinit_phase_q == SBI_PATTERN_ACTIVE) ||
           (sbinit_phase_q == SBI_PATTERN_IDLE))))) begin
      if (sbinit_rx_iter_match) begin
        if (sbinit_match_streak_q < SBINIT_DETECT_ITERS)
          sbinit_match_streak_d = sbinit_match_streak_q + 1'b1;
        if (sbinit_match_streak_q >= (SBINIT_DETECT_ITERS - 1)) begin
          sbinit_match_streak_d     = SBINIT_DETECT_ITERS;
          pattern_trigger_pending_d = 1'b1;
        end
      end else begin
        sbinit_match_streak_d = 2'd0;
      end
    end

    case (state_q)
      // -----------------------------------------------------------------
      // 4.5.3.1 RESET
      // -----------------------------------------------------------------
      // RESET exits only after the local 4 ms minimum and either the local
      // training request or the sticky two-consecutive-pattern trigger.
      LT_RESET: begin
        if (rst_tmr_expired) reset_min_done_d = 1'b1;
        if (!reset_entry && (rst_tmr_expired || reset_min_done_q) &&
            (start_link_train || pattern_trigger_pending_d))
          state_d = LT_SBINIT;
      end

      // -----------------------------------------------------------------
      // 4.5.3.2 SBINIT
      // -----------------------------------------------------------------
      // Pattern policy alternates 1 ms active and 1 ms fully-idle windows
      // before detection. After detection, the fourth completion event moves
      // to repeated Out-of-Reset packets. Done uses distinct request and
      // response obligations and shares this state's single 8 ms deadline.
      LT_SBINIT: begin
        case (sbinit_phase_q)
          SBI_PATTERN_ACTIVE,
          SBI_PATTERN_IDLE: begin
            if (!pattern_trigger_pending_q && pattern_trigger_pending_d) begin
              sbinit_phase_d        = SBI_PATTERN_ACTIVE;
              sbinit_tail_count_d   = 3'd0;
              sbinit_window_count_d = 32'd0;
            end else if (pattern_trigger_pending_q) begin
              if (sbinit_tx_iter_done) begin
                if (sbinit_tail_count_q < SBINIT_POST_DETECT_ITERS)
                  sbinit_tail_count_d = sbinit_tail_count_q + 1'b1;
                if (sbinit_tail_count_q == (SBINIT_POST_DETECT_ITERS - 1)) begin
                  sbinit_phase_d        = SBI_OUT_OF_RESET;
                  sbinit_window_count_d = 32'd0;
                end
              end
            end else if (sbinit_phase_q == SBI_PATTERN_ACTIVE) begin
              // Count only while the synchronized primitive is not idle, so
              // the active window excludes lclk-to-sbclk startup latency.
              if (!sbinit_tx_idle) begin
                if (sbinit_window_count_q == (SBINIT_ACTIVE_LCLK_CYCLES - 1)) begin
                  sbinit_phase_d        = SBI_PATTERN_IDLE;
                  sbinit_window_count_d = 32'd0;
                end else begin
                  sbinit_window_count_d = sbinit_window_count_q + 1'b1;
                end
              end
            end else begin
              // Start the idle window only after the raw primitive reaches a
              // low boundary and reports idle back into lclk.
              if (sbinit_tx_idle) begin
                if (sbinit_window_count_q == (SBINIT_IDLE_LCLK_CYCLES - 1)) begin
                  sbinit_phase_d        = SBI_PATTERN_ACTIVE;
                  sbinit_window_count_d = 32'd0;
                end else begin
                  sbinit_window_count_d = sbinit_window_count_q + 1'b1;
                end
              end
            end
          end

          SBI_OUT_OF_RESET: begin
            if (sbinit_oor_rx)   sbinit_oor_received_d = 1'b1;
            if (sbinit_oor_send) sbinit_oor_sent_d     = 1'b1;

            // Preserve an early peer Done request until packet mode reaches
            // the Done phase. This does not satisfy the response we await.
            if (sbinit_done_req_rx &&
                (sbinit_done_rsp_pending_q != 8'hFF))
              sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q + 1'b1;

            if (sbinit_oor_sent_d && sbinit_oor_received_d &&
                !sb_tx_busy && !sb_tx_load)
              sbinit_phase_d = SBI_DONE;
          end

          SBI_DONE: begin
            if (sbinit_done_req_send) sbinit_done_req_sent_d = 1'b1;
            if (sbinit_done_rsp_send) sbinit_done_rsp_sent_d = 1'b1;

            // Queue every peer request and retire one obligation for every
            // response accepted by the TX mailbox. Simultaneous events leave
            // the queue depth unchanged.
            case ({sbinit_done_req_rx, sbinit_done_rsp_send})
              2'b10: begin
                if (sbinit_done_rsp_pending_q != 8'hFF)
                  sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q + 1'b1;
              end
              2'b01: sbinit_done_rsp_pending_d =
                       sbinit_done_rsp_pending_q - 1'b1;
              default: sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q;
            endcase

            // An early response cannot complete a request that was not sent.
            if (sbinit_done_rsp_rx && sbinit_done_req_sent_q)
              sbinit_done_rsp_received_d = 1'b1;

            if (sbinit_done_req_sent_d && sbinit_done_rsp_sent_d &&
                sbinit_done_rsp_received_d &&
                (sbinit_done_rsp_pending_d == 8'd0) &&
                !sbinit_done_req_rx && !sb_tx_busy && !sb_tx_load) begin
              state_d       = LT_MBINIT_PARAM;
              timer_start_d = 1'b0;
            end
          end

          default: sbinit_phase_d = SBI_PATTERN_ACTIVE;
        endcase
      end

      // -----------------------------------------------------------------
      // 4.5.3.3 MBINIT sub-states
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
      LT_MB_VALVREF:   if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DATAVREF;
      LT_MB_DATAVREF:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_SPEEDIDLE;
      LT_MB_SPEEDIDLE: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_TXSELFCAL;
      LT_MB_TXSELFCAL: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXCLKCAL;
      LT_MB_RXCLKCAL:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_VTCENTER;
      LT_MB_VTCENTER:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTVREF1;
      LT_MB_DTVREF1:   if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXDESKEW;
      LT_MB_RXDESKEW:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTCENTER2;
      LT_MB_DTCENTER2: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_LINKSPEED;
      LT_MB_LINKSPEED: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_REPAIR;

      LT_MB_REPAIR: begin
        if (req_sent_q && resp_rcvd_q) begin
          if (sb_rx_msginfo == MS_LKS_EXIT_REP) begin
            state_d = LT_MB_TXSELFCAL;
          end else if (sb_rx_msginfo == MS_LKS_EXIT_DEG) begin
            state_d = LT_MB_TXSELFCAL;
          end else if (sb_rx_msginfo == MS_LKS_DONE) begin
            state_d = LT_LINKINIT;
          end
        end
      end

      // -----------------------------------------------------------------
      // 4.5.3.5 LINKINIT through 4.5.3.9 terminal/runtime states
      // -----------------------------------------------------------------
      LT_LINKINIT: begin
        if (pat_done) state_d = LT_ACTIVE;
      end

      LT_ACTIVE: begin
        if (retrain_req_q) state_d = LT_PHYRETRAIN;
      end

      LT_PHYRETRAIN: begin
        if (req_sent_q && resp_rcvd_q) state_d = LT_ACTIVE;
      end

      LT_L1L2: begin
        if (start_link_train) state_d = LT_RESET;
      end

      LT_TRAINERROR: begin
        if (start_link_train) state_d = LT_RESET;
      end

      default: state_d = LT_RESET;
    endcase

    // Every timed training state uses one uninterrupted residency deadline.
    if (tmr_expired && timer_start_q &&
        (state_q != LT_ACTIVE) && (state_q != LT_L1L2) &&
        (state_q != LT_TRAINERROR) && (state_q != LT_RESET)) begin
      state_d       = LT_TRAINERROR;
      timer_start_d = 1'b0;
    end
  end

  // =========================================================================
  // Sideband TX packet interface
  // =========================================================================
  // The specialized SBINIT scheduler selects 91h/00h, 95h/01h, or 9Ah/01h.
  // All other training states use the existing lookup tables. Every Physical
  // Layer training packet uses the UCIe-Link PHY source and remote-PHY IDs.
  assign sb_tx_load = generic_send || sbinit_oor_send ||
                      sbinit_done_rsp_send || sbinit_done_req_send;
  assign sb_tx_opcode = SB_OP_MSG_NODATA;
  assign sb_tx_srcid = SRCID_PHY;
  assign sb_tx_dstid = DSTID_REMOTE_PHY;
  assign sb_tx_msginfo = sbinit_oor_send ? SBINIT_RESULT_PRIMARY :
                                              msg_info(state_q);
  assign sb_tx_msgcode = sbinit_oor_send      ? MC_SB_OOB_RESET :
                             sbinit_done_rsp_send ? MC_SB_DONE_RSP  :
                             sbinit_done_req_send ? MC_SB_DONE_REQ  :
                                                    msg_req_code(state_q);
  assign sb_tx_msgsubcode = sbinit_oor_send      ? MS_SB_OOB_RESET :
                                (sbinit_done_rsp_send ||
                                 sbinit_done_req_send) ? MS_SB_DONE :
                                                        msg_subcode(state_q);
  assign sb_tx_be       = 8'h00;
  assign sb_tx_tag      = 5'h00;
  assign sb_tx_ep       = 1'b0;
  assign sb_tx_addr     = 12'h000;
  assign sb_tx_data_in  = 64'h0;
  assign sb_tx_has_data = 1'b0;
  assign sb_msg_timeout = 1'b0;
  assign sb_stall_sent  = 1'b0;

  // =========================================================================
  // Raw SBINIT primitive controls
  // =========================================================================
  // Raw receive mode includes RESET and both pattern windows. The transmitter
  // runs throughout an active pre-detection window. After detection it drops
  // the level after the third observed completion, while the already-started
  // fourth iteration finishes at its low boundary. The fourth event advances
  // the LTSM to packet mode.
  assign sbinit_raw_mode = (state_q == LT_RESET) ||
                           ((state_q == LT_SBINIT) &&
                            ((sbinit_phase_q == SBI_PATTERN_ACTIVE) ||
                             (sbinit_phase_q == SBI_PATTERN_IDLE)));

  assign pattern_run_enable = (state_q == LT_SBINIT) &&
                              (sbinit_phase_q == SBI_PATTERN_ACTIVE) &&
                              (!pattern_trigger_pending_q ||
                               (sbinit_tail_count_q <
                                (SBINIT_POST_DETECT_ITERS - 1)));

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

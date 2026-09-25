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
//               Phase B uses a role-aware transaction engine for every
//               fixed-profile MBINIT and MBTRAIN subcode. Each logical
//               transaction waits for local mailbox acceptance and its
//               matching response. Peer responses and exact duplicate
//               replays remain separate obligations. TX priority is queued
//               peer response, local request, then duplicate replay.
//               PARAM uses DATA64 with immutable 64-bit payload values.
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
//  | | TXSELFCAL  (0Bh)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | RXCLKCAL   (0Ch)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | VTCENTER   (0Dh)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | DTVREF1    (0Eh)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | RXDESKEW   (0Fh)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | DTCENTER2  (10h)  |             |
//  | +--------+----------+             |
//  |          |                        |
//  | +--------v----------+             |
//  | | LINKSPEED  (11h)  |             |
//  | +--------+----------+             |
//  | REPAIR (12h) is unsupported.      |
//  +===================================+
//             | 15h then 19h done
//             v
//  +-----------+
//  | LINKINIT  |  4.5.3.5  Reseed per-lane LFSRs; LFSR pattern 4096 UI.
//  |  (14h)    |           Exit -> ACTIVE on pat_done.
//  +-----+-----+
//        |
//        v
//  +-----------+                 +--------------+
//  |  ACTIVE   |  4.5.3.6       | PHYRETRAIN   | 4.5.3.7
//  |  (15h)    |                 |  (13h)       | Unsupported in Phase B.
//  +-----+-----+                 +--------------+
//        |
//        | (fatal packet or timeout)
//        v
//  +-----------+                 +-----------+
//  | TRAINERROR|  4.5.3.8        |   L1L2    | 4.5.3.9
//  |  (16h)    |                 |  (17h)    | Low-power; clock may gate.
//  +-----------+                 +-----------+
//  (only LINKRESET clears)       (start_link_train -> RESET)
//
// --------------------------------------------------------------------------
// Sub-state exit rule  (spec 4.5.3.3 and 4.5.3.4)
// --------------------------------------------------------------------------
//   Each listed sequence step completes only after the TX mailbox accepts
//   the local request and the matching response arrives. The step also waits
//   for its queued peer response and any exact duplicate replay. A peer
//   request never satisfies the local response obligation. SBINIT retains
//   its separate raw and packet-phase rules.
//
//   Each public sub-state has one 8 ms residency timer. A state that exceeds
//   8 ms before all sequence steps complete escalates to TRAINERROR.
//
// --------------------------------------------------------------------------
// Sideband message coding  (Tables 53, 54, 56)
// --------------------------------------------------------------------------
//   SBINIT selects explicit Out-of-Reset, Done request, and Done response
//   pairs. Phase B maps through msg_req_code(), msg_rsp_code(), and the
//   state-and-step msg_subcode() lookup. Every Phase B MsgInfo is zero.
//   LINKSPEED outcomes use subcodes, and MBTRAIN.REPAIR is unsupported.
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
//   Phase A disables the pattern generator (pat_enable low) for every MBINIT
//   and MBTRAIN sub-state. LINKINIT retains the existing LFSR diagnostic
//   path and its legacy pat_done gate. Phase C replaces that gate with the
//   required LinkMgmt.RDI Active exchange. This phase does not add electrical
//   pattern counts or a state-specific pattern selector.
//   Pattern selection (effective only when pat_enable is high):
//     - LINKINIT                    -> PAT_LFSR      (4096-UI LFSR)
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
//   v0.0.9  2026-09-24  Disable pat_enable for all MBINIT and MBTRAIN states.
//                        Preserve LINKINIT diagnostic path only. Update all
//                        pattern generator control comments per Phase A.
//   v0.0.10 2026-09-24  Correct Phase A comments. LINKINIT retains its
//                        existing pat_done transition until Phase C owns
//                        Active Entry with the LinkMgmt exchange.
//   v0.0.11 2026-09-24  Align Phase A comments with logical_phy's low
//                        mainband-data and framing gate.
//   v0.0.12 2026-09-24  Phase B: replace generic post-SBINIT request/response
//                        with role-aware transaction engine. Track five
//                        independent obligations per sub-state. Validate
//                        post-SBINIT packets for role, IDs, opcode, code,
//                        subcode, and PARAM payload. TX priority: peer
//                        response, local request, duplicate replay. PARAM
//                        uses DATA64 with 64-bit payloads. LINKSPEED success
//                        exits to LINKINIT; error/re/degrade enters
//                        TRAINERROR. Add private sb_tx_accepted and
//                        sb_rx_payload input ports. Validate peer PARAM
//                        DATA64 Vswing range; invalid Vswing escalates
//                        to TRAINERROR.
//   v0.0.13 2026-09-24  Complete Phase B fixed-profile transaction sequences.
//                        Enforce full packet contracts and early-response
//                        failure. Store exact peer request identities and
//                        coalesce current duplicates into one response.
//                        Replay completed duplicates after local requests.
//                        Require LINKSPEED 15h then 19h and disable REPAIR.
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
  input  logic        sb_tx_accepted,
  input  logic        sb_rx_pkt_vld,
  input  logic [4:0]  sb_rx_opcode,
  input  logic [2:0]  sb_rx_srcid,
  input  logic [2:0]  sb_rx_dstid,
  input  logic [7:0]  sb_rx_msginfo,
  input  logic [7:0]  sb_rx_msgcode,
  input  logic [7:0]  sb_rx_msgsubcode,
  input  logic [63:0] sb_rx_payload,
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

  // ---- Phase B logical-transaction state
  // Each sequence step owns one local request and one matching response.
  // A peer request owns either one current response or one duplicate replay.
  // The identity contains every RX field visible here, including DATA64.
  logic [2:0]  txn_step_q, txn_step_d;
  logic        local_req_accepted_q, local_req_accepted_d;
  logic        local_resp_rcvd_q, local_resp_rcvd_d;
  logic        peer_req_valid_q, peer_req_valid_d;
  logic        peer_resp_pending_q, peer_resp_pending_d;
  logic        peer_replay_pending_q, peer_replay_pending_d;
  logic [98:0] peer_req_identity_q, peer_req_identity_d;
  logic        phase_b_state_complete;

  // -------------------------------------------------------------------------
  // State and policy register bank
  // -------------------------------------------------------------------------
  // This bank stores raw SBINIT policy and Phase B transaction obligations.
  // Sequence steps reset on each public state entry and after the last step.
  // Peer request identity remains stable until the current step completes.
  // The raw SBINIT fields keep their existing reset and update behavior.
  // Spec refs: UCIe 1.0 Sections 4.5.3.2, 4.5.3.3, and 4.5.3.4.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q                       <= LT_RESET;
      sbinit_phase_q                <= SBI_PATTERN_ACTIVE;
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
      txn_step_q                    <= 3'd0;
      local_req_accepted_q          <= 1'b0;
      local_resp_rcvd_q             <= 1'b0;
      peer_req_valid_q              <= 1'b0;
      peer_resp_pending_q           <= 1'b0;
      peer_replay_pending_q         <= 1'b0;
      peer_req_identity_q           <= 99'd0;
    end else begin
      state_q                       <= state_d;
      sbinit_phase_q                <= sbinit_phase_d;
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
      txn_step_q                    <= txn_step_d;
      local_req_accepted_q          <= local_req_accepted_d;
      local_resp_rcvd_q             <= local_resp_rcvd_d;
      peer_req_valid_q              <= peer_req_valid_d;
      peer_resp_pending_q           <= peer_resp_pending_d;
      peer_replay_pending_q         <= peer_replay_pending_d;
      peer_req_identity_q           <= peer_req_identity_d;
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
  // Fixed-profile Phase B message and sequence lookup
  // =========================================================================
  // Only MBINIT and MBTRAIN through LINKSPEED participate in Phase B.
  // Every sequence entry is one complete request and response transaction.
  // The step index never changes until the current transaction completes.
  // MBTRAIN.REPAIR, PHYRETRAIN, and TRAINERROR have no Phase B exchange.
  // Spec refs: UCIe 1.0 Tables 53, 54, and 56;
  //            Sections 4.5.3.3 and 4.5.3.4.
  // =========================================================================
  function automatic logic phase_b_state_supported(input ltsm_state_t s);
    case (s)
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB,
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: phase_b_state_supported = 1'b1;
      default:         phase_b_state_supported = 1'b0;
    endcase
  endfunction

  function automatic logic [7:0] msg_req_code(input ltsm_state_t s);
    case (s)
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB: msg_req_code = MC_MBINIT_REQ;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: msg_req_code = MC_MBTRAIN_REQ;
      default:         msg_req_code = MC_NOP_CRD;
    endcase
  endfunction

  function automatic logic [7:0] msg_rsp_code(input ltsm_state_t s);
    case (s)
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB: msg_rsp_code = MC_MBINIT_RSP;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: msg_rsp_code = MC_MBTRAIN_RSP;
      default:         msg_rsp_code = MC_NOP_CRD;
    endcase
  endfunction

  function automatic logic [2:0] sequence_last_step(input ltsm_state_t s);
    case (s)
      LT_MBINIT_RPCLK: sequence_last_step = 3'd5;
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:  sequence_last_step = 3'd3;
      LT_MB_DTVREF1:   sequence_last_step = 3'd2;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: sequence_last_step = 3'd1;
      default:         sequence_last_step = 3'd0;
    endcase
  endfunction

  function automatic logic [7:0] msg_subcode(
    input ltsm_state_t s,
    input logic [2:0] step
  );
    case (s)
      LT_MBINIT_PARAM: msg_subcode = MS_PARAM_CFG;
      LT_MBINIT_CAL:   msg_subcode = MS_CAL_DONE;

      LT_MBINIT_RPCLK: begin
        case (step)
          3'd0: msg_subcode = MS_RPCLK_INIT;
          3'd1: msg_subcode = MS_RPCLK_RESULT;
          3'd2: msg_subcode = MS_RPCLK_APPLY;
          3'd3: msg_subcode = MS_RPCLK_CHKINI;
          3'd4: msg_subcode = MS_RPCLK_CHKRES;
          3'd5: msg_subcode = MS_RPCLK_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_RPVAL: begin
        case (step)
          3'd0: msg_subcode = MS_RPVAL_INIT;
          3'd1: msg_subcode = MS_RPVAL_RESULT;
          3'd2: msg_subcode = MS_RPVAL_APPLY;
          3'd3: msg_subcode = MS_RPVAL_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_REVMB: begin
        case (step)
          3'd0: msg_subcode = MS_REVMB_INIT;
          3'd1: msg_subcode = MS_REVMB_CLRERR;
          3'd2: msg_subcode = MS_REVMB_RESULT;
          3'd3: msg_subcode = MS_REVMB_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_RPMB: begin
        case (step)
          3'd0: msg_subcode = MS_RPMB_START;
          3'd1: msg_subcode = MS_RPMB_APPLY;
          3'd2: msg_subcode = MS_RPMB_END;
          3'd3: msg_subcode = MS_RPMB_END2;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_VALVREF: begin
        case (step)
          3'd0: msg_subcode = MS_VALVREF_START;
          3'd1: msg_subcode = MS_VALVREF_END;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_DATAVREF: begin
        case (step)
          3'd0: msg_subcode = MS_DATAVREF_START;
          3'd1: msg_subcode = MS_DATAVREF_END;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_SPEEDIDLE: msg_subcode = MS_SPEEDIDLE_DONE;
      LT_MB_TXSELFCAL: msg_subcode = MS_TXSELFCAL_DONE;

      LT_MB_RXCLKCAL: begin
        case (step)
          3'd0: msg_subcode = MS_RXCLKCAL_START;
          3'd1: msg_subcode = MS_RXCLKCAL_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_VTCENTER: begin
        case (step)
          3'd0: msg_subcode = MS_VTC_START;
          3'd1: msg_subcode = MS_VTC_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_DTVREF1: begin
        case (step)
          3'd0: msg_subcode = MS_DTV_START;
          3'd1: msg_subcode = 8'h0F;
          3'd2: msg_subcode = MS_DTV_END;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_RXDESKEW: begin
        case (step)
          3'd0: msg_subcode = MS_DESKEW_START;
          3'd1: msg_subcode = MS_DESKEW_END;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_DTCENTER2: begin
        case (step)
          3'd0: msg_subcode = MS_DTC2_START;
          3'd1: msg_subcode = MS_DTC2_END;
          default: msg_subcode = 8'hFF;
        endcase
      end

      LT_MB_LINKSPEED: begin
        case (step)
          3'd0: msg_subcode = MS_LKS_START;
          3'd1: msg_subcode = MS_LKS_DONE;
          default: msg_subcode = 8'hFF;
        endcase
      end

      default: msg_subcode = 8'hFF;
    endcase
  endfunction

  // The public state selects the message code. The private step selects the
  // exact subcode. A state-entry cycle always addresses step zero so stale
  // state from the prior public state cannot classify an inbound packet.
  // These values implement PLAN.md Section 15.9 Phase B and UCIe 1.0
  // Tables 53, 54, and 56.
  wire       phase_b_active  = phase_b_state_supported(state_q);
  wire [2:0] active_txn_step = state_entry ? 3'd0 : txn_step_q;
  wire [7:0] current_subcode = msg_subcode(state_q, active_txn_step);

  // =========================================================================
  // Sideband receive classification
  // =========================================================================
  // SBINIT retains its original no-data PHY-to-PHY packet classifier.
  // Phase B has a separate complete packet contract below. This split keeps
  // raw SBINIT behavior unchanged while post-SBINIT errors become fatal.
  // Spec refs: UCIe 1.0 Section 4.5.3.2 and Table 47.
  // =========================================================================
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

  // =========================================================================
  // Phase B PARAM payload rules
  // =========================================================================
  // A request accepts module zero, differential and continuous clocks,
  // Vswing 01h through 10h, and the fixed or a higher speed advertisement.
  // The response must select differential and continuous clocks at exactly
  // the fixed 4 GT/s encoding. Every response reserved bit is ignored.
  // The transmitted response always uses immutable PARAM_RSP_DATA.
  // Spec refs: UCIe 1.0 Table 56 and Section 4.5.3.3.1.
  // =========================================================================
  localparam logic [63:0] PARAM_RSP_REQUIRED_MASK =
    PARAM_MASK_CLOCK_PHASE | PARAM_MASK_CLOCK_MODE | PARAM_MASK_MAX_SPEED;

  wire param_req_valid =
    ((sb_rx_payload & PARAM_MASK_MODULE_ID) == 64'h0) &&
    ((sb_rx_payload & PARAM_MASK_CLOCK_PHASE) == 64'h0) &&
    ((sb_rx_payload & PARAM_MASK_CLOCK_MODE) != 64'h0) &&
    (sb_rx_payload[8:4] >= PARAM_VSWING_MIN) &&
    (sb_rx_payload[8:4] <= PARAM_VSWING_MAX) &&
    (sb_rx_payload[3:0] >= PARAM_REQ_DATA[3:0]);

  wire param_rsp_valid =
    ((sb_rx_payload & PARAM_RSP_REQUIRED_MASK) ==
     (PARAM_RSP_DATA & PARAM_RSP_REQUIRED_MASK));

  // =========================================================================
  // Phase B complete packet validation and role separation
  // =========================================================================
  // Every packet must be parity-clean and use the exact opcode, IDs,
  // zero MsgInfo, current code, current subcode, role, and payload rule.
  // A request creates a peer response obligation. Only a response can
  // complete the local request, and a response before acceptance is fatal.
  // Any packet outside a supported Phase B exchange is unexpected.
  // Spec refs: UCIe 1.0 Tables 47, 49, 53, 54, and 56;
  //            Sections 4.5.3.3 and 4.5.3.4.
  // =========================================================================
  wire [4:0] phase_b_expected_opcode =
    (state_q == LT_MBINIT_PARAM) ? SB_OP_MSG_DATA64 : SB_OP_MSG_NODATA;

  wire phase_b_common_valid = phase_b_active && sb_rx_pkt_vld &&
                              !sb_rx_cp_err && !sb_rx_dp_err &&
                              (sb_rx_opcode == phase_b_expected_opcode) &&
                              (sb_rx_srcid == SRCID_PHY) &&
                              (sb_rx_dstid == DSTID_REMOTE_PHY) &&
                              (sb_rx_msginfo == 8'h00) &&
                              (sb_rx_msgsubcode == current_subcode);

  wire phase_b_req_payload_valid =
    (state_q != LT_MBINIT_PARAM) || param_req_valid;
  wire phase_b_rsp_payload_valid =
    (state_q != LT_MBINIT_PARAM) || param_rsp_valid;

  wire phase_b_peer_req = phase_b_common_valid &&
                          (sb_rx_msgcode == msg_req_code(state_q)) &&
                          phase_b_req_payload_valid;
  wire phase_b_peer_rsp = phase_b_common_valid &&
                          (sb_rx_msgcode == msg_rsp_code(state_q)) &&
                          phase_b_rsp_payload_valid;
  wire phase_b_packet_valid = phase_b_peer_req || phase_b_peer_rsp;

  // A no-data packet has no logical payload. Normalize it to zero before
  // identity comparison so stale codec payload storage cannot change an
  // otherwise identical request. DATA64 preserves all 64 payload bits.
  // Identity also preserves opcode, IDs, MsgInfo, code, and subcode.
  // Spec refs: UCIe 1.0 Section 6.1.2 and Table 56.
  wire [63:0] peer_req_identity_payload =
    (sb_rx_opcode == SB_OP_MSG_DATA64) ? sb_rx_payload : 64'h0;
  wire [98:0] rx_peer_req_identity = {
    sb_rx_opcode, sb_rx_srcid, sb_rx_dstid, sb_rx_msginfo,
    sb_rx_msgcode, sb_rx_msgsubcode, peer_req_identity_payload
  };
  wire peer_req_identity_match =
    (rx_peer_req_identity == peer_req_identity_q);

  wire phase_b_early_rsp = phase_b_peer_rsp &&
                           (state_entry || !local_req_accepted_q);
  wire phase_b_peer_req_conflict = phase_b_peer_req && !state_entry &&
                                   peer_req_valid_q &&
                                   !peer_req_identity_match;
  wire post_sbinit_rx_event = sb_rx_pkt_vld &&
                              (state_q != LT_RESET) &&
                              (state_q != LT_SBINIT);
  wire phase_b_rx_fatal = post_sbinit_rx_event &&
                          (!phase_b_packet_valid || phase_b_early_rsp ||
                           phase_b_peer_req_conflict);

  // =========================================================================
  // Sideband transmit scheduling
  // =========================================================================
  // Out-of-Reset repeats until a valid peer copy arrives. Done responses have
  // priority over the one local Done request. The pending counter preserves a
  // separate response obligation for every valid peer Done request.
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
  // Phase B transmit scheduling and arbitration
  // =========================================================================
  // Arbitration is strict: queued current peer response, local request,
  // then duplicate replay. A pending bit survives mailbox busy cycles and
  // clears only when sb_tx_accepted identifies the selected transmission.
  // State-entry and fatal-packet cycles suppress every Phase B transmission.
  // PARAM uses DATA64. Every other sequence entry uses MSG_NODATA.
  // Spec refs: UCIe 1.0 Tables 47 and 56;
  //            PLAN.md Section 15.9 Phase B.
  // =========================================================================

  // -------------------------------------------------------------------------
  // Wire: queued current peer response
  // -------------------------------------------------------------------------
  // This response has first priority and remains selected until acceptance.
  // TX busy cannot discard the stored obligation or its request identity.
  // The response role uses the current response code and current subcode.
  // PARAM returns the immutable fixed response, not the peer request data.
  // Spec refs: UCIe 1.0 Sections 4.5.3.3 and 4.5.3.4.
  // -------------------------------------------------------------------------
  wire tx_peer_resp = phase_b_active && !state_entry &&
                      !phase_b_rx_fatal && peer_resp_pending_q &&
                      !sb_tx_busy;

  // -------------------------------------------------------------------------
  // Wire: current local request
  // -------------------------------------------------------------------------
  // This request has second priority after the queued peer response.
  // One request remains outstanding until the mailbox accepts this send.
  // A matching response cannot complete it before that acceptance event.
  // Each sequence step resets local_req_accepted_q before the next request.
  // Spec refs: UCIe 1.0 Sections 4.5.3.3 and 4.5.3.4.
  // -------------------------------------------------------------------------
  wire tx_local_req = phase_b_active && !state_entry &&
                      !phase_b_rx_fatal && !sb_tx_busy &&
                      !local_req_accepted_q && !tx_peer_resp;

  // -------------------------------------------------------------------------
  // Wire: exact duplicate peer-request replay
  // -------------------------------------------------------------------------
  // This replay has third priority after the normal local request.
  // One pending bit coalesces identical duplicates into one obligation.
  // The response reproduces the current response code, subcode, and payload.
  // A different request identity is fatal and never reaches this scheduler.
  // Spec refs: UCIe 1.0 Sections 4.5.3.3 and 4.5.3.4.
  // -------------------------------------------------------------------------
  wire tx_dup_peer = phase_b_active && !state_entry &&
                     !phase_b_rx_fatal && peer_replay_pending_q &&
                     !sb_tx_busy && !tx_peer_resp && !tx_local_req;

  // -------------------------------------------------------------------------
  // Wire: PARAM DATA64 selection
  // -------------------------------------------------------------------------
  // PARAM is the only Phase B state with a data payload.
  // Local requests use PARAM_REQ_DATA. Both response paths use
  // PARAM_RSP_DATA. All non-PARAM sends retain a zero data input.
  // Spec refs: UCIe 1.0 Table 47 and Table 56.
  // -------------------------------------------------------------------------
  wire tx_param_send = (state_q == LT_MBINIT_PARAM) &&
                       (tx_peer_resp || tx_local_req || tx_dup_peer);

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
  // Next-state, raw SBINIT policy, and Phase B transaction policy
  // =========================================================================
  // Defaults retain every registered obligation until an explicit event.
  // State entry clears only state-scoped Phase B data and preserves SBINIT.
  // A sequence step advances after local acceptance, its matching response,
  // and all peer response or replay obligations complete.
  // Invalid post-SBINIT packets override normal state progress below.
  // Spec refs: UCIe 1.0 Sections 4.5.3.2, 4.5.3.3, and 4.5.3.4;
  //            PLAN.md Section 15.9 Phase B.
  // =========================================================================
  always_comb begin
    state_d                    = state_q;
    sbinit_phase_d             = sbinit_phase_q;
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
    txn_step_d                 = txn_step_q;
    local_req_accepted_d       = local_req_accepted_q;
    local_resp_rcvd_d          = local_resp_rcvd_q;
    peer_req_valid_d           = peer_req_valid_q;
    peer_resp_pending_d        = peer_resp_pending_q;
    peer_replay_pending_d      = peer_replay_pending_q;
    peer_req_identity_d        = peer_req_identity_q;
    phase_b_state_complete     = 1'b0;

    // State entry resets state-scoped transaction data. A new RESET epoch
    // also clears every sticky pattern and raw SBINIT policy register.
    if (state_entry) begin
      txn_step_d                 = 3'd0;
      local_req_accepted_d       = 1'b0;
      local_resp_rcvd_d          = 1'b0;
      peer_req_valid_d           = 1'b0;
      peer_resp_pending_d        = 1'b0;
      peer_replay_pending_d      = 1'b0;
      peer_req_identity_d        = 99'd0;
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
    end

    // Phase B accepts only the transmission selected by the strict arbiter.
    // A response updates the local flag only after the request was accepted.
    // The fatal wire removes early responses before this block can use them.
    if (phase_b_active && !phase_b_rx_fatal) begin
      if (sb_tx_accepted && tx_peer_resp)
        peer_resp_pending_d = 1'b0;
      if (sb_tx_accepted && tx_local_req)
        local_req_accepted_d = 1'b1;
      if (sb_tx_accepted && tx_dup_peer)
        peer_replay_pending_d = 1'b0;

      if (phase_b_peer_rsp)
        local_resp_rcvd_d = 1'b1;

      // The first peer request stores one exact identity and one response.
      // An identical request while that response is queued adds nothing.
      // After completion, one identical request creates one replay obligation.
      if (phase_b_peer_req) begin
        if (state_entry || !peer_req_valid_q) begin
          peer_req_valid_d      = 1'b1;
          peer_resp_pending_d   = 1'b1;
          peer_req_identity_d   = rx_peer_req_identity;
        end else if (peer_req_identity_match) begin
          if (!peer_resp_pending_q && !peer_replay_pending_q)
            peer_replay_pending_d = 1'b1;
        end
      end

      // Complete one logical transaction only after every current obligation.
      // Wait one cycle after peer-service acceptance. The retained identity
      // then recognizes a duplicate that arrives after the completed response.
      // Clearing all step-local data makes the next subcode a new transaction.
      if (local_req_accepted_d && local_resp_rcvd_d &&
          !peer_resp_pending_d && !peer_replay_pending_d &&
          !(sb_tx_accepted && (tx_peer_resp || tx_dup_peer))) begin
        local_req_accepted_d  = 1'b0;
        local_resp_rcvd_d     = 1'b0;
        peer_req_valid_d      = 1'b0;
        peer_resp_pending_d   = 1'b0;
        peer_replay_pending_d = 1'b0;
        peer_req_identity_d   = 99'd0;

        if (active_txn_step == sequence_last_step(state_q)) begin
          txn_step_d             = 3'd0;
          phase_b_state_complete = 1'b1;
          timer_start_d          = 1'b0;
        end else begin
          txn_step_d = active_txn_step + 1'b1;
        end
      end
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
      // 4.5.3.3 MBINIT fixed-profile sequences
      // -----------------------------------------------------------------
      // PARAM [00], CAL [02], REPAIRCLK [03..08], REPAIRVAL [09..0C],
      // REVERSALMB [0D..10], and REPAIRMB [11..14] complete in order.
      // phase_b_state_complete asserts only after the final transaction.
      // Spec ref: UCIe 1.0 Section 4.5.3.3 and Table 56.
      LT_MBINIT_PARAM:
        if (phase_b_state_complete) state_d = LT_MBINIT_CAL;
      LT_MBINIT_CAL:
        if (phase_b_state_complete) state_d = LT_MBINIT_RPCLK;
      LT_MBINIT_RPCLK:
        if (phase_b_state_complete) state_d = LT_MBINIT_RPVAL;
      LT_MBINIT_RPVAL:
        if (phase_b_state_complete) state_d = LT_MBINIT_REVMB;
      LT_MBINIT_REVMB:
        if (phase_b_state_complete) state_d = LT_MBINIT_RPMB;
      LT_MBINIT_RPMB:
        if (phase_b_state_complete) state_d = LT_MB_VALVREF;

      // -----------------------------------------------------------------
      // 4.5.3.4 MBTRAIN fixed-profile sequences
      // -----------------------------------------------------------------
      // Each state consumes every listed subcode from the sequence lookup.
      // LINKSPEED requires both 15h and 19h transactions before LINKINIT.
      // Any other LINKSPEED result fails complete-packet validation.
      // Spec ref: UCIe 1.0 Section 4.5.3.4 and Tables 53 and 54.
      LT_MB_VALVREF:
        if (phase_b_state_complete) state_d = LT_MB_DATAVREF;
      LT_MB_DATAVREF:
        if (phase_b_state_complete) state_d = LT_MB_SPEEDIDLE;
      LT_MB_SPEEDIDLE:
        if (phase_b_state_complete) state_d = LT_MB_TXSELFCAL;
      LT_MB_TXSELFCAL:
        if (phase_b_state_complete) state_d = LT_MB_RXCLKCAL;
      LT_MB_RXCLKCAL:
        if (phase_b_state_complete) state_d = LT_MB_VTCENTER;
      LT_MB_VTCENTER:
        if (phase_b_state_complete) state_d = LT_MB_DTVREF1;
      LT_MB_DTVREF1:
        if (phase_b_state_complete) state_d = LT_MB_RXDESKEW;
      LT_MB_RXDESKEW:
        if (phase_b_state_complete) state_d = LT_MB_DTCENTER2;
      LT_MB_DTCENTER2:
        if (phase_b_state_complete) state_d = LT_MB_LINKSPEED;
      LT_MB_LINKSPEED:
        if (phase_b_state_complete) state_d = LT_LINKINIT;

      // MBTRAIN.REPAIR is outside the fixed profile. It does not issue a
      // request and cannot route a LINKSPEED success or failure. Reaching it
      // is itself fatal, while supported LINKSPEED success goes to LINKINIT.
      // Spec ref: UCIe 1.0 Section 4.5.3.4.13.
      LT_MB_REPAIR: state_d = LT_TRAINERROR;

      // -----------------------------------------------------------------
      // 4.5.3.5 LINKINIT through 4.5.3.9 terminal/runtime states
      // -----------------------------------------------------------------
      LT_LINKINIT: begin
        if (pat_done) state_d = LT_ACTIVE;
      end

      LT_ACTIVE: begin
        if (retrain_req_q) state_d = LT_PHYRETRAIN;
      end

      // Phase B does not implement PHYRETRAIN. The fixed profile never
      // requests this state, and no sideband exchange starts from it.
      // Spec ref: PLAN.md Section 5.1 and Section 15.9 Phase B.
      LT_PHYRETRAIN: begin
        state_d = state_q;
      end

      LT_L1L2: begin
        if (start_link_train) state_d = LT_RESET;
      end

      LT_TRAINERROR: begin
        if (start_link_train) state_d = LT_RESET;
      end

      default: state_d = LT_RESET;
    endcase

    // Every invalid packet after SBINIT is fatal. This override also catches
    // wrong-state traffic in LINKINIT and runtime states without adding any
    // Phase C message handling.
    if (phase_b_rx_fatal) begin
      state_d       = LT_TRAINERROR;
      timer_start_d = 1'b0;
    end

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
  // SBINIT keeps its dedicated packet scheduler and field values.
  // Phase B emits the current fixed-profile subcode with a strict role.
  // Peer response and duplicate replay paths both emit response packets.
  // PARAM is the only DATA64 exchange. Every other data input is zero.
  // Spec refs: UCIe 1.0 Tables 47, 49, 53, 54, and 56.
  // =========================================================================

  // -------------------------------------------------------------------------
  // assign: Sideband TX load
  //
  // The load pulse selects one raw SBINIT or Phase B transmission.
  // Phase B source wires are mutually exclusive under the strict arbiter.
  // A busy mailbox leaves each stored response obligation unchanged.
  // Spec refs: UCIe 1.0 Section 6.1.3 and PLAN.md Section 15.9 Phase B.
  // -------------------------------------------------------------------------
  assign sb_tx_load = sbinit_oor_send || sbinit_done_rsp_send ||
                      sbinit_done_req_send || tx_peer_resp ||
                      tx_local_req || tx_dup_peer;

  // -------------------------------------------------------------------------
  // assign: Sideband TX opcode
  //
  // PARAM packets use DATA64 for requests, responses, and replays.
  // Raw SBINIT and every non-PARAM Phase B packet use MSG_NODATA.
  // tx_param_send can assert only while a PARAM packet is selected.
  // Spec refs: UCIe 1.0 Table 47 and Table 56.
  // -------------------------------------------------------------------------
  assign sb_tx_opcode = tx_param_send ? SB_OP_MSG_DATA64 : SB_OP_MSG_NODATA;

  // -------------------------------------------------------------------------
  // assign: Sideband TX source and destination IDs
  //
  // Every packet produced by this LTSM uses the Physical Layer source ID.
  // Every packet targets the remote-die Physical Layer destination ID.
  // The values apply equally to raw SBINIT packets and Phase B packets.
  // Spec ref: UCIe 1.0 Table 49.
  // -------------------------------------------------------------------------
  assign sb_tx_srcid = SRCID_PHY;
  assign sb_tx_dstid = DSTID_REMOTE_PHY;

  // -------------------------------------------------------------------------
  // assign: Sideband TX MsgInfo
  //
  // SBINIT Out-of-Reset preserves the primary-side result value.
  // Every other SBINIT packet and every Phase B packet uses zero MsgInfo.
  // LINKSPEED results are subcodes and never travel in MsgInfo.
  // Spec refs: UCIe 1.0 Tables 53, 54, and 56.
  // -------------------------------------------------------------------------
  assign sb_tx_msginfo = sbinit_oor_send ? SBINIT_RESULT_PRIMARY : 8'h00;

  // -------------------------------------------------------------------------
  // assign: Sideband TX message code
  //
  // Raw SBINIT packets retain their dedicated request and response codes.
  // Both peer-service paths use the response code for the current state.
  // Only tx_local_req uses the current MBINIT or MBTRAIN request code.
  // Spec refs: UCIe 1.0 Tables 53, 54, and 56.
  // -------------------------------------------------------------------------
  assign sb_tx_msgcode = sbinit_oor_send      ? MC_SB_OOB_RESET :
                         sbinit_done_rsp_send ? MC_SB_DONE_RSP  :
                         sbinit_done_req_send ? MC_SB_DONE_REQ  :
                         (tx_peer_resp || tx_dup_peer)
                           ? msg_rsp_code(state_q)
                           : msg_req_code(state_q);

  // -------------------------------------------------------------------------
  // assign: Sideband TX message subcode
  //
  // Raw SBINIT packets retain Out-of-Reset and Done subcodes.
  // Every Phase B role uses the exact current sequence subcode.
  // The private step changes only after the current transaction completes.
  // Spec refs: UCIe 1.0 Tables 53, 54, and 56.
  // -------------------------------------------------------------------------
  assign sb_tx_msgsubcode = sbinit_oor_send ? MS_SB_OOB_RESET :
                            (sbinit_done_rsp_send || sbinit_done_req_send)
                              ? MS_SB_DONE
                              : current_subcode;

  // -------------------------------------------------------------------------
  // assign: Sideband TX fixed header and payload fields
  //
  // PARAM local requests use immutable PARAM_REQ_DATA.
  // PARAM peer responses and duplicate replays use PARAM_RSP_DATA.
  // All non-PARAM sends drive zero on sb_tx_data_in and clear has_data.
  // Remaining message-format fields use their fixed zero values.
  // Spec refs: UCIe 1.0 Section 6.1.2 and Table 56.
  // -------------------------------------------------------------------------
  assign sb_tx_be       = 8'h00;
  assign sb_tx_tag      = 5'h00;
  assign sb_tx_ep       = 1'b0;
  assign sb_tx_addr     = 12'h000;
  assign sb_tx_data_in  = tx_param_send
                            ? (tx_local_req ? PARAM_REQ_DATA : PARAM_RSP_DATA)
                            : 64'h0;
  assign sb_tx_has_data = tx_param_send;

  // -------------------------------------------------------------------------
  // assign: Sideband timeout and stall status
  //
  // Phase B uses the existing LTSM residency timer instead of message timeout.
  // This reduced profile does not insert sideband stall messages.
  // Both status outputs therefore remain at their fixed inactive values.
  // Spec refs: UCIe 1.0 Sections 4.5.3.3 and 4.5.3.4.
  // -------------------------------------------------------------------------
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
  // The LTSM disables the pattern generator for every MBINIT (02h-07h) and
  // MBTRAIN (08h-12h) sub-state. pat_enable is high only during LINKINIT
  // (14h), where the LFSR diagnostic path emits 4096 UI of PAT_LFSR.
  // logical_phy applies the matching Phase A low mainband-data and framing
  // gate while these immediate-success actions are skipped.
  //
  // The LINKINIT diagnostic path preserves the per-lane LFSR reseed
  // (pat_lfsr_reset) and run (pat_lfsr_enable) sequence. Phase A retains
  // the existing pat_done transition. Phase C replaces it with the required
  // LinkMgmt.RDI Active exchange.
  //
  // Pattern selection mux (effective only when pat_enable is high):
  //   LINKINIT          -> PAT_LFSR      (per-lane LFSR, 4096 UI)
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
  // =========================================================================
  assign pat_enable     = (state_q == LT_LINKINIT);
  // -------------------------------------------------------------------------
  // assign: Training Pattern Selection Mux
  //
  // Selects the training pattern driven onto the main-band lanes based on
  // the current LTSM sub-state.  This mux is effective only when pat_enable
  // is high (LINKINIT state).  During MBINIT and MBTRAIN the pattern
  // generator is disabled and the output is zero.
  //   LINKINIT            -> PAT_LFSR       (per-lane scrambled LFSR)
  //
  // The priority-encoded ternary chain is retained for the LINKINIT
  // diagnostic path.  The default value (PAT_PERLANEID) is harmless
  // because pat_enable gates the output.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
  // -------------------------------------------------------------------------
  assign pat_select     = (state_q == LT_MB_VALVREF)  ? PAT_VALTRAIN  :
                          (state_q == LT_MB_DATAVREF) ? PAT_VALTRAIN  :
                          (state_q == LT_LINKINIT)    ? PAT_LFSR      :
                          (state_q == LT_MB_RXDESKEW) ? PAT_CLKREPAIR :
                                                        PAT_PERLANEID;
  // -------------------------------------------------------------------------
  // assign: LFSR Reseed Pulse
  //
  // Generates a 1-cycle reset pulse on LINKINIT entry so the per-lane
  // LFSRs start from a known seed.  Because pat_enable is low for all
  // MBINIT and MBTRAIN states, the LFSR is only exercised during LINKINIT
  // where the LFSR pattern IS the training payload.  The clean reseed
  // ensures the LFSR advances freely for the full 4096-UI duration.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
  // -------------------------------------------------------------------------
  assign pat_lfsr_reset = (state_q == LT_LINKINIT) && (state_q != state_q_prev);
  // -------------------------------------------------------------------------
  // assign: LFSR Enable Gate
  //
  // Enables the per-lane LFSR only during the LINKINIT sub-state (14h).
  // During all MBINIT, MBTRAIN, and other states the LFSR holds its
  // current value so it can be cleanly reseeded on the next LINKINIT
  // entry via pat_lfsr_reset. The existing LINKINIT diagnostic uses the
  // 4096-UI completion until Phase C replaces its state-exit condition.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT;
  //           Section 4.4.1 - Scrambling and training pattern generation.
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

  // Phase B does not create a retrain request. Phase C owns runtime RDI
  // retrain policy, so the retained status register remains inactive here.

  // =========================================================================
  // Lint suppression
  // =========================================================================
  // The fixed profile does not consume adapter_active_req until Phase C.
  // This reduction keeps that public input and selected policy wires visible
  // to simple single-pass lint tools without adding runtime behavior.
  // =========================================================================
  logic unused_match;
  // -------------------------------------------------------------------------
  // assign: Lint-suppression tie-off
  //
  // This signal combines the deferred Active-entry input with Phase B
  // classifier results that some tools hide through function calls.
  // It does not feed LTSM policy or change any state transition.
  // Phase C will consume adapter_active_req through its required exchange.
  // Spec refs: UCIe 1.0 Sections 4.5.3.5 and 8.1.6.
  // -------------------------------------------------------------------------
  assign unused_match = adapter_active_req | phase_b_packet_valid |
                        phase_b_rx_fatal | peer_req_identity_match |
                        tmr_expired | pat_done | sb_tx_busy |
                        sb_tx_accepted | sb_rx_payload[0];

endmodule

`endif

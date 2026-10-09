// ============================================================================
// File        : ltsm.sv
// Module      : ltsm
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Link Training and Status State Machine (LTSM). This is the
//               central sequencer for the entire link bring-up, from physical
//               reset through sideband initialisation, main-band calibration,
//               main-band training, link initialisation, and finally the
//               ACTIVE state where data may flow. Link management makes this module
//               the sole owner of Active Entry, fatal recovery, LinkReset,
//               Disabled, RESET dwell, and fresh training triggers.
//
//               The parameter negotiation logic uses a role-aware transaction engine for every
//               fixed-profile MBINIT and MBTRAIN subcode. Each logical
//               transaction waits for local mailbox acceptance and its
//               matching response. Peer responses and exact duplicate
//               replays remain separate obligations. TX priority is queued
//               peer response, local request, then duplicate replay.
//               PARAM uses DATA64 with immutable 64-bit payload values.
//
//               The link training logic adds the LinkMgmt.RDI Active exchange in LINKINIT.
//               Fatal events use the TRAINERROR Entry exchange before the
//               public TRAINERROR hold. LinkReset and Disabled use retained
//               request/response obligations and the common 8 ms timer.
//               Priority is LinkError, Disabled, LinkReset, then normal work.
//
//               The physical datapath adds one private fatal source: the mainband framing
//               fault. The receive gearbox in mb_gearbox.sv reports a
//               qualifier change inside a four-mbclk-cycle word boundary as
//               a sticky level, the logical PHY synchronises that level into
//               lclk and reduces it to one fresh event, and this module
//               treats the event exactly like a LinkError request. It needs
//               no new public port and no new state: the existing TRAINERROR
//               Entry exchange, LinkReset, Disabled, and RESET dwell carry
//               the recovery.
//
// Spec refs   : UCIe 1.0 spec section 4.5.3 (LTSM), with per-state
//               references to 4.5.3.1 through 4.5.3.9.
//
// --------------------------------------------------------------------------
// LTSM State / Sub-State Progression  (spec 4.5.3 Figure 70)
// --------------------------------------------------------------------------
//
//  +-----------+
//  |  RESET    |  4.5.3.1  Wait for the 4 ms minimum and a fresh local
//  |  (00h)    |           event. Initial RESET also accepts raw detection.
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
//  | LINKINIT  |  4.5.3.5  Reseed per-lane LFSRs; perform the complete
//  |  (14h)    |           LinkMgmt.RDI Active Entry exchange.
//  +-----+-----+
//        |
//        v
//  +-----------+                 +--------------+
//  |  ACTIVE   |  4.5.3.6       | PHYRETRAIN   | 4.5.3.7
//  |  (15h)    |                 |  (13h)       | Unsupported in this profile.
//  +-----+-----+                 +--------------+
//        |
//        | (fatal packet or timeout, then TRAINERROR Entry exchange)
//        v
//  +-----------+                 +-----------+
//  | TRAINERROR|  4.5.3.8        |   L1L2    | 4.5.3.9
//  |  (16h)    |                 |  (17h)    | Low-power; clock may gate.
//  +-----+-----+                 +-----------+
//        |                       (unsupported in this profile)
//        v (direct exit to RESET per Fig 111, 119, 126 & §8.3.2.7)
//  +-----+-----+
//  |   RESET   |  4.5.3.1  Full 4 ms physical layer RESET minimum dwell.
//  +-----------+           Exits on fresh Start or RDI NOP-to-Active trigger.
//
//  LinkError exits directly to RESET per Section 8.3.2.7 and Figures 111,
//  119, and 126 once the 8 ms residency dwell is satisfied (or bypassed by
//  sideband LinkError handshake). No LinkReset exchange occurs from LinkError.
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
//   Each public sub-state has one 8 ms residency timer. A post-SBINIT state
//   that exceeds 8 ms starts TRAINERROR Entry before the public error hold.
//
// --------------------------------------------------------------------------
// Sideband message coding  (Tables 53, 54, 56)
// --------------------------------------------------------------------------
//   SBINIT selects explicit Out-of-Reset, Done request, and Done response
//   pairs. Sideband training maps through msg_req_code(), msg_rsp_code(), and the
//   state-and-step msg_subcode() lookup. Link management uses only LinkMgmt.RDI
//   Active, LinkReset, Disabled, and TRAINERROR Entry no-data messages.
//   Every sideband training and LinkMgmt MsgInfo is zero.
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
//   The sequencer disables the pattern generator (pat_enable low) for every MBINIT
//   and MBTRAIN sub-state. LINKINIT retains the LFSR diagnostic path, but
//   pat_done does not delay Active Entry. LINKINIT exits only after the full
//   LinkMgmt.RDI Active exchange. This phase does not add electrical pattern
//   counts or a state-specific pattern selector.
//   Pattern selection (effective only when pat_enable is high):
//     - LINKINIT                    -> PAT_LFSR      (4096-UI LFSR)
//
// --------------------------------------------------------------------------
// Timer interface
// --------------------------------------------------------------------------
//   tmr_start       : pulses on timed-state entry and LinkMgmt.RDI exchange start.
//   tmr_run         : stays high for one uninterrupted residency or exchange.
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
//   Adapter/RDI : software_start_event, rdi_active_event, rdi_active_req,
//                 rdi_linkreset_req, rdi_disabled_req, active_entry_done,
//                 transition_active, clear_start_link_train, link_trained,
//                 train_error, link_reset_out, phy_retrain_done,
//                 ltsm_state (8-bit state encoding for Error Log 0),
//                 lnk_is_x8, degrade_lanes.
//   Framing     : framing_fault_event, the private mainband framing fault
//                 from the logical PHY receive gearbox. It is one fresh
//                 event of at least one lclk cycle, not a port of ucie_main.
//   Sideband    : Full TX field set (sb_tx_load..sb_tx_has_data) driving
//                 the packet CDC, and full RX field set (sb_rx_pkt_vld..
//                 sb_rx_dp_err) from the packet CDC.
//   Raw SBINIT  : pattern_run_enable and sbinit_raw_mode levels; atomic
//                 remote-result and local-completion events; synchronized
//                 transmitter-idle boundary status.
//   Pattern gen : pat_enable, pat_select, pat_lfsr_reset, pat_lfsr_enable,
//                 and retained diagnostic pat_done observation.
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
//   4. The existing residency timer supplies each LinkMgmt.RDI exchange with an
//      8 ms window. TRAINERROR itself has no residency timeout.
//   5. A peer transition request creates a retained response obligation.
//      Higher-priority policy can abort normal work but cannot discard it.
//   6. Recovery RESET does not use a stale request level or LinkReset itself
//      as a training trigger. Raw SBINIT detection remains unchanged for the
//      initial RESET epoch.
//   7. sb_msg_timeout and sb_stall_sent stay low. The LTSM residency timer
//      owns the supported message-exchange deadlines.
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
//   v0.0.14 2026-09-25  Phase C: own LinkMgmt.RDI Active Entry, TRAINERROR
//                        Entry exchange and hold, LinkReset and Disabled
//                        exchange, full recovery RESET dwell, and fresh
//                        software or RDI triggers. Enforce LinkError over
//                        Disabled over LinkReset over normal transactions.
//   v0.0.15 2026-09-25  Phase E: add the private `framing_fault_event` input,
//                        one fresh synchronised lclk event, and include it in
//                        the existing fatal trigger. The event reuses the
//                        TRAINERROR Entry exchange, the LinkReset and
//                        Disabled exchanges, and the full recovery RESET
//                        dwell. No public port changes.
//   v0.0.16 2026-09-25  Phase E correctness: add the private
//                        `transition_active` level. It closes the logical
//                        PHY Active-data gate when a private transition
//                        starts, including the TRAINERROR Entry exchange
//                        before the registered state leaves ACTIVE.
//   v0.0.17 2026-10-08  Implement UCIe 1.0 Section 8.3.2.7 LinkError minimum
//                        residency timer (8 ms fallback), sideband LinkError
//                        handshake bypass, direct transition to RESET (Figures
//                        111, 119, 126), response draining prior to reset,
//                        and exclusion of LinkReset exchange from LinkError.
//   v0.0.18 2026-10-08  Documentation compliance pass: add spec-cited comment
//                        blocks (5-20 lines) above state-tracking always_ff
//                        registers and all continuous assign drivers
//                        (transition_active, le_tmr_start, pat_*, phy_*).
//   v0.0.19 2026-10-09  Documentation compliance pass: remove obsolete implementation-phase
//                        references outside revision history, add per-port inline
//                        comments, and split multi-signal declarations.
//   v0.0.20 2026-10-09  Contract extension: add private mb_source_ready and
//                        mb_clock_running inputs and mb_clock_enable and
//                        mb_clock_run outputs. Gate RESET exit on mb_source_ready
//                        without lost start events. Disable OEs in RESET,
//                        SBINIT, PARAM, CAL; enable in electrical idle states.
//                        Run clock continuously in LINKSPEED, LINKINIT, ACTIVE.
//                        Govern RXCLKCAL local TX clock by received peer
//                        start/done requests and wait for physical clock running
//                        acknowledgement before emitting matching responses.
// ============================================================================
`ifndef Ltsm_SV
`define Ltsm_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ltsm #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,                   // Main link clock (500 MHz)
  input  logic        lreset_n,               // Active-low asynchronous reset

  // ---- private adapter / RDI policy
  input  logic        software_start_event,   // fresh software Start event
  input  logic        rdi_active_event,       // fresh RDI NOP-to-Active event
  input  logic        rdi_active_req,         // current local Active request
  input  logic        rdi_linkreset_req,      // current local LinkReset request
  input  logic        rdi_disabled_req,       // current local Disabled request
  input  logic        rdi_linkreset_published = 1'b1, // RDI has published LINKRESET (or TRAINERROR)
  input  logic        rdi_disabled_published  = 1'b1, // RDI has published DISABLED
  input  logic        rdi_lp_linkerror        = 1'b0, // RDI lp_linkerror input from Adapter/Protocol
  output logic        active_entry_done,      // completed Active Entry result
  output logic        transition_active,      // private transition in progress
  output logic        clear_start_link_train, // one-cycle Start-copy clear
  output logic        link_trained,           // LTSM reached ACTIVE
  output logic        phy_training_done,      // physical training reached LINKINIT
  output logic        train_error,            // unrecoverable failure
  output logic        link_reset_out,         // drives RDI RESET indication
  output logic        phy_linkreset_req,      // LinkReset exchange in progress (local or remote)
  output logic        phy_disabled_req,       // Disabled exchange in progress (local or remote)
  output logic        phy_retrain_done,       // fixed profile never retrains
  output logic [7:0]  ltsm_state,             // Error Log 0 "State N"
  output logic        lnk_is_x8,              // negotiated x8 degrade
  output logic [1:0]  degrade_lanes,          // which half survives

  // ---- private physical-layer fatal input (mainband framing fault)
  input  logic        framing_fault_event,    // fresh mainband framing fault
  // ---- lclk-facing sideband CDC endpoint (the LTSM is the only master)
  output logic        sb_tx_load,             // Load strobe for outgoing sideband packet
  output logic [4:0]  sb_tx_opcode,           // Outgoing sideband packet opcode
  output logic [2:0]  sb_tx_srcid,            // Outgoing sideband packet source ID
  output logic [2:0]  sb_tx_dstid,            // Outgoing sideband packet destination ID
  output logic [15:0] sb_tx_msginfo,          // Outgoing sideband packet message info
  output logic [7:0]  sb_tx_msgcode,          // Outgoing sideband packet message code
  output logic [7:0]  sb_tx_msgsubcode,       // Outgoing sideband packet message subcode
  output logic [7:0]  sb_tx_be,               // Outgoing sideband packet byte enable
  output logic [4:0]  sb_tx_tag,              // Outgoing sideband packet tag
  output logic        sb_tx_ep,               // Outgoing sideband packet poisoned indicator
  output logic [11:0] sb_tx_addr,             // Outgoing sideband packet register address
  output logic [63:0] sb_tx_data_in,          // Outgoing sideband packet 64-bit payload data
  output logic        sb_tx_has_data,         // Outgoing packet carries data payload
  input  logic        sb_tx_busy,             // Sideband TX mailbox busy status
  input  logic        sb_tx_accepted,         // Sideband TX packet accepted acknowledgement
  input  logic        sb_rx_pkt_vld,          // Received sideband packet valid strobe
  input  logic [4:0]  sb_rx_opcode,           // Received sideband packet opcode
  input  logic [2:0]  sb_rx_srcid,            // Received sideband packet source ID
  input  logic [2:0]  sb_rx_dstid,            // Received sideband packet destination ID
  input  logic [15:0] sb_rx_msginfo,          // Received sideband packet message info
  input  logic [7:0]  sb_rx_msgcode,          // Received sideband packet message code
  input  logic [7:0]  sb_rx_msgsubcode,       // Received sideband packet message subcode
  input  logic [63:0] sb_rx_payload,          // Received sideband packet 64-bit payload data
  input  logic        sb_rx_cp_err,           // Received packet header parity error status
  input  logic        sb_rx_dp_err,           // Received packet data parity error status
  output logic        sb_msg_timeout,         // Sideband message timeout indicator
  output logic        sb_stall_sent,          // Sideband stall response sent indicator

  // ---- raw SBINIT waveform/CDC primitive
  output logic        pattern_run_enable,     // Enable raw SBINIT pattern generator
  output logic        sbinit_raw_mode,        // Active during raw SBINIT pattern phase
  input  logic        sbinit_rx_iter_vld,     // Raw RX iteration complete strobe
  input  logic        sbinit_rx_iter_match,   // Raw RX iteration pattern matched
  input  logic        sbinit_tx_iter_done,    // Raw TX iteration pattern finished
  input  logic        sbinit_tx_idle,         // Raw TX primitive idle status

  // ---- training pattern generator
  output logic        pat_enable,             // Training pattern generator enable
  output pat_t        pat_select,             // Pattern select (clock repair, per-lane, LFSR)
  output logic        pat_lfsr_reset,         // Reset strobe for LFSR pattern generator
  output logic        pat_lfsr_enable,        // Advance strobe for LFSR pattern generator
  input  logic        pat_done,               // LFSR training pattern completion strobe

  // ---- timers
  output logic        tmr_start,              // Sub-state residency timer start trigger
  output logic        tmr_run,                // Sub-state residency timer run enable
  output logic        rst_tmr_start,          // RESET minimum timer start trigger
  input  logic        tmr_expired,            // Sub-state residency timer expired indicator
  input  logic        rst_tmr_expired,        // RESET minimum timer expired indicator
  output logic        le_tmr_start,           // LinkError residency timer start trigger
  input  logic        le_tmr_expired = 1'b0,  // LinkError residency timer expired indicator

  // ---- private physical clock and source control contract
  input  logic        mb_source_ready,        // Internal domain reset / source release acknowledgement
  input  logic        mb_clock_running,       // Physical clock running acknowledgement
  output logic        mb_clock_enable,        // Mainband clock output buffer enable (OE)
  output logic        mb_clock_run            // Mainband forwarded clock active run request
);

  // =========================================================================
  // State, handshake, and SBINIT policy registers
  // =========================================================================
  // The public LTSM encoding remains unchanged. Private state retains raw
  // SBINIT policy, sideband transactions, Active Entry, and recovery exchanges.
  // A LinkMgmt.RDI exchange remains in the current public state until all required
  // responses are accepted or its 8 ms timer expires.
  // =========================================================================
  typedef enum logic [1:0] {
    SBI_PATTERN_ACTIVE = 2'd0,
    SBI_PATTERN_IDLE   = 2'd1,
    SBI_OUT_OF_RESET   = 2'd2,
    SBI_DONE           = 2'd3
  } sbinit_phase_t;

  typedef enum logic [1:0] {
    PC_NONE       = 2'd0,
    PC_LINKRESET  = 2'd1,
    PC_DISABLED   = 2'd2,
    PC_TRAINERROR = 2'd3
  } phase_c_mode_t;

  ltsm_state_t state_q;
  ltsm_state_t state_d;
  sbinit_phase_t sbinit_phase_q;
  sbinit_phase_t sbinit_phase_d;
  phase_c_mode_t phase_c_mode_q;
  phase_c_mode_t phase_c_mode_d;

  logic timer_start_q;
  logic timer_start_d;
  logic reset_min_done_q;
  logic reset_min_done_d;
  logic reset_trigger_pending_q;
  logic reset_trigger_pending_d;
  logic recovery_reset_q;
  logic recovery_reset_d;
  logic        reset_rdi_req_sampled_q;

  logic [1:0]  sbinit_match_streak_q;
  logic [1:0]  sbinit_match_streak_d;
  logic        pattern_trigger_pending_q;
  logic        pattern_trigger_pending_d;
  logic [2:0]  sbinit_tail_count_q;
  logic [2:0]  sbinit_tail_count_d;
  logic [31:0] sbinit_window_count_q;
  logic [31:0] sbinit_window_count_d;
  logic        sbinit_oor_sent_q;
  logic        sbinit_oor_sent_d;
  logic        sbinit_oor_received_q;
  logic        sbinit_oor_received_d;
  logic        sbinit_done_req_sent_q;
  logic        sbinit_done_req_sent_d;
  logic        sbinit_done_rsp_sent_q;
  logic        sbinit_done_rsp_sent_d;
  logic        sbinit_done_rsp_received_q;
  logic        sbinit_done_rsp_received_d;
  logic [7:0]  sbinit_done_rsp_pending_q;
  logic [7:0]  sbinit_done_rsp_pending_d;

  // ---- Parameter exchange logical-transaction state
  // Each sequence step owns one local request and one matching response.
  // A peer request owns either one current response or one duplicate replay.
  // The identity contains every RX field visible here, including DATA64.
  logic [2:0]  txn_step_q;
  logic [2:0]  txn_step_d;
  logic        local_req_accepted_q;
  logic        local_req_accepted_d;
  logic        local_resp_rcvd_q;
  logic        local_resp_rcvd_d;
  logic        peer_req_valid_q;
  logic        peer_req_valid_d;
  logic        peer_resp_pending_q;
  logic        peer_resp_pending_d;
  logic        peer_replay_pending_q;
  logic        peer_replay_pending_d;
  logic [106:0] peer_req_identity_q;
  logic [106:0] peer_req_identity_d;
  logic        phase_b_state_complete;

  // ---- LinkMgmt.RDI Active Entry state
  // The local RDI Active level is sampled and retained in active_ready_q.
  // Peer requests and local requests remain separate obligations.
  logic active_ready_q;
  logic active_ready_d;
  logic active_req_accepted_q;
  logic active_req_accepted_d;
  logic active_rsp_received_q;
  logic active_rsp_received_d;
  logic active_peer_req_seen_q;
  logic active_peer_req_seen_d;
  logic active_peer_rsp_pending_q;
  logic active_peer_rsp_pending_d;
  logic active_peer_rsp_accepted_q;
  logic active_peer_rsp_accepted_d;

  // ---- LinkMgmt.RDI LinkReset exchange state
  logic linkreset_local_needed_q;
  logic linkreset_local_needed_d;
  logic linkreset_req_accepted_q;
  logic linkreset_req_accepted_d;
  logic linkreset_rsp_received_q;
  logic linkreset_rsp_received_d;
  logic linkreset_peer_rsp_pending_q;
  logic linkreset_peer_rsp_pending_d;

  // ---- LinkMgmt.RDI Disabled exchange state
  logic disabled_local_needed_q;
  logic disabled_local_needed_d;
  logic disabled_req_accepted_q;
  logic disabled_req_accepted_d;
  logic disabled_rsp_received_q;
  logic disabled_rsp_received_d;
  logic disabled_peer_rsp_pending_q;
  logic disabled_peer_rsp_pending_d;

  // ---- LinkMgmt.RDI TRAINERROR Entry exchange state
  logic trainerror_local_needed_q;
  logic trainerror_local_needed_d;
  logic trainerror_req_accepted_q;
  logic trainerror_req_accepted_d;
  logic trainerror_rsp_received_q;
  logic trainerror_rsp_received_d;
  logic trainerror_peer_rsp_pending_q;
  logic trainerror_peer_rsp_pending_d;
  logic sb_linkerror_ack_q;
  logic sb_linkerror_ack_d;
  logic linkerror_min_done_q;
  logic linkerror_min_done_d;
  logic trainerror_exchange_timeout_q;
  logic trainerror_exchange_timeout_d;

  // ---- RXCLKCAL directional peer clock governance
  logic rxclkcal_tx_clk_run_q;
  logic rxclkcal_tx_clk_run_d;
  logic [7:0] rxclkcal_peer_rsp_subcode_q;
  logic [7:0] rxclkcal_peer_rsp_subcode_d;
  logic rxclkcal_peer_start_done_q;
  logic rxclkcal_peer_start_done_d;
  logic rxclkcal_peer_finish_done_q;
  logic rxclkcal_peer_finish_done_d;
  logic rxclkcal_local_done_q;
  logic rxclkcal_local_done_d;

  // -------------------------------------------------------------------------
  // State and policy register bank
  // -------------------------------------------------------------------------
  // This bank retains every accepted peer response obligation across a
  // higher-priority LinkMgmt.RDI transition. It also records fresh RESET triggers.
  // UCIe 1.0 Sections 4.5.3.1, 4.5.3.8, 8.1.6, and 8.3.2.8 define the
  // RESET, Active Entry, TRAINERROR, and transition ordering rules.
  // UCIe 1.0 Sections 8.1.6, 8.3.2.8, and 8.3.3 define this fixed-profile policy.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q                         <= LT_RESET;
      sbinit_phase_q                  <= SBI_PATTERN_ACTIVE;
      phase_c_mode_q                  <= PC_NONE;
      timer_start_q                   <= 1'b0;
      reset_min_done_q                <= 1'b0;
      reset_trigger_pending_q         <= 1'b0;
      recovery_reset_q                <= 1'b0;
      sbinit_match_streak_q           <= 2'd0;
      pattern_trigger_pending_q       <= 1'b0;
      sbinit_tail_count_q             <= 3'd0;
      sbinit_window_count_q           <= 32'd0;
      sbinit_oor_sent_q               <= 1'b0;
      sbinit_oor_received_q           <= 1'b0;
      sbinit_done_req_sent_q          <= 1'b0;
      sbinit_done_rsp_sent_q          <= 1'b0;
      sbinit_done_rsp_received_q      <= 1'b0;
      sbinit_done_rsp_pending_q       <= 8'd0;
      txn_step_q                      <= 3'd0;
      local_req_accepted_q            <= 1'b0;
      local_resp_rcvd_q               <= 1'b0;
      peer_req_valid_q                <= 1'b0;
      peer_resp_pending_q             <= 1'b0;
      peer_replay_pending_q           <= 1'b0;
      peer_req_identity_q             <= 107'd0;
      active_ready_q                  <= 1'b0;
      active_req_accepted_q           <= 1'b0;
      active_rsp_received_q           <= 1'b0;
      active_peer_req_seen_q          <= 1'b0;
      active_peer_rsp_pending_q       <= 1'b0;
      active_peer_rsp_accepted_q      <= 1'b0;
      linkreset_local_needed_q        <= 1'b0;
      linkreset_req_accepted_q        <= 1'b0;
      linkreset_rsp_received_q        <= 1'b0;
      linkreset_peer_rsp_pending_q    <= 1'b0;
      disabled_local_needed_q         <= 1'b0;
      disabled_req_accepted_q         <= 1'b0;
      disabled_rsp_received_q         <= 1'b0;
      disabled_peer_rsp_pending_q     <= 1'b0;
      trainerror_local_needed_q       <= 1'b0;
      trainerror_req_accepted_q       <= 1'b0;
      trainerror_rsp_received_q       <= 1'b0;
      trainerror_peer_rsp_pending_q   <= 1'b0;
      sb_linkerror_ack_q              <= 1'b0;
      linkerror_min_done_q            <= 1'b0;
      trainerror_exchange_timeout_q   <= 1'b0;
      rxclkcal_tx_clk_run_q           <= 1'b0;
      rxclkcal_peer_rsp_subcode_q     <= 8'h00;
      rxclkcal_peer_start_done_q      <= 1'b0;
      rxclkcal_peer_finish_done_q     <= 1'b0;
      rxclkcal_local_done_q           <= 1'b0;
    end else begin
      state_q                         <= state_d;
      sbinit_phase_q                  <= sbinit_phase_d;
      phase_c_mode_q                  <= phase_c_mode_d;
      timer_start_q                   <= timer_start_d;
      reset_min_done_q                <= reset_min_done_d;
      reset_trigger_pending_q         <= reset_trigger_pending_d;
      recovery_reset_q                <= recovery_reset_d;
      sbinit_match_streak_q           <= sbinit_match_streak_d;
      pattern_trigger_pending_q       <= pattern_trigger_pending_d;
      sbinit_tail_count_q             <= sbinit_tail_count_d;
      sbinit_window_count_q           <= sbinit_window_count_d;
      sbinit_oor_sent_q               <= sbinit_oor_sent_d;
      sbinit_oor_received_q           <= sbinit_oor_received_d;
      sbinit_done_req_sent_q          <= sbinit_done_req_sent_d;
      sbinit_done_rsp_sent_q          <= sbinit_done_rsp_sent_d;
      sbinit_done_rsp_received_q      <= sbinit_done_rsp_received_d;
      sbinit_done_rsp_pending_q       <= sbinit_done_rsp_pending_d;
      txn_step_q                      <= txn_step_d;
      local_req_accepted_q            <= local_req_accepted_d;
      local_resp_rcvd_q               <= local_resp_rcvd_d;
      peer_req_valid_q                <= peer_req_valid_d;
      peer_resp_pending_q             <= peer_resp_pending_d;
      peer_replay_pending_q           <= peer_replay_pending_d;
      peer_req_identity_q             <= peer_req_identity_d;
      active_ready_q                  <= active_ready_d;
      active_req_accepted_q           <= active_req_accepted_d;
      active_rsp_received_q           <= active_rsp_received_d;
      active_peer_req_seen_q          <= active_peer_req_seen_d;
      active_peer_rsp_pending_q       <= active_peer_rsp_pending_d;
      active_peer_rsp_accepted_q      <= active_peer_rsp_accepted_d;
      linkreset_local_needed_q        <= linkreset_local_needed_d;
      linkreset_req_accepted_q        <= linkreset_req_accepted_d;
      linkreset_rsp_received_q        <= linkreset_rsp_received_d;
      linkreset_peer_rsp_pending_q    <= linkreset_peer_rsp_pending_d;
      disabled_local_needed_q         <= disabled_local_needed_d;
      disabled_req_accepted_q         <= disabled_req_accepted_d;
      disabled_rsp_received_q         <= disabled_rsp_received_d;
      disabled_peer_rsp_pending_q     <= disabled_peer_rsp_pending_d;
      trainerror_local_needed_q       <= trainerror_local_needed_d;
      trainerror_req_accepted_q       <= trainerror_req_accepted_d;
      trainerror_rsp_received_q       <= trainerror_rsp_received_d;
      trainerror_peer_rsp_pending_q   <= trainerror_peer_rsp_pending_d;
      sb_linkerror_ack_q              <= sb_linkerror_ack_d;
      linkerror_min_done_q            <= linkerror_min_done_d;
      trainerror_exchange_timeout_q   <= trainerror_exchange_timeout_d;
      rxclkcal_tx_clk_run_q           <= rxclkcal_tx_clk_run_d;
      rxclkcal_peer_rsp_subcode_q     <= rxclkcal_peer_rsp_subcode_d;
      rxclkcal_peer_start_done_q      <= rxclkcal_peer_start_done_d;
      rxclkcal_peer_finish_done_q     <= rxclkcal_peer_finish_done_d;
      rxclkcal_local_done_q           <= rxclkcal_local_done_d;
    end
  end

  // =========================================================================
  // Previous-state edge detector
  ltsm_state_t state_q_prev;

  // -------------------------------------------------------------------------
  // always_ff: Previous LTSM State Register
  //
  // Captures the previous cycle LTSM state to detect state entry edges.
  // RESET uses the entry pulse to restart its full 4 ms minimum dwell,
  // while ACTIVE uses it to produce the one-cycle Start-copy clear.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.1 and Section 4.5.3.5;
  //           UCIe 1.0 Sections 8.1.6, 8.3.2.8, and 8.3.3.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q_prev <= LT_RESET;
    else           state_q_prev <= state_q;
  end

  // -------------------------------------------------------------------------
  // always_ff: Reset Epoch RDI NOP Qualifier Register
  //
  // A Reset epoch accepts an RDI Active edge only after it samples the
  // equivalent of NOP (!rdi_active_req && !rdi_linkreset_req && !rdi_disabled_req).
  // This prevents a stale held Active level from restarting physical link
  // training after LinkReset or Disabled recovery.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.1 and Section 4.5.3.1.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n)
      reset_rdi_req_sampled_q <= 1'b0;
    else if (state_q != LT_RESET)
      reset_rdi_req_sampled_q <= 1'b0;
    else if (!rdi_active_req && !rdi_linkreset_req && !rdi_disabled_req)
      reset_rdi_req_sampled_q <= 1'b1;
  end

  wire state_entry = (state_q != state_q_prev);
  wire reset_entry = state_entry && (state_q == LT_RESET);

  // =========================================================================
  // Mainband Output Enable (OE) State Classification
  // =========================================================================
  // Per UCIe 1.0 Section 5.12 and architectural contract:
  // - OEs disabled (mb_clock_enable = 0) in RESET, SBINIT, PARAM, CAL.
  // - OEs enabled (mb_clock_enable = 1) in electrical-idle states and active states.
  // =========================================================================
  function automatic logic state_oe_disabled(input ltsm_state_t s);
    case (s)
      LT_RESET,
      LT_SBINIT,
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL: state_oe_disabled = 1'b1;
      default:       state_oe_disabled = 1'b0;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // assign: mb_clock_enable - Mainband Output Enable Driver
  //
  // Controls pin-level driver enable for mainband lanes and forwarded clock.
  // Held disabled (high-Z/off) in RESET, SBINIT, PARAM, and CAL. Enabled
  // in all electrical-idle and active states.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3 and Section 5.12.
  // -------------------------------------------------------------------------
  assign mb_clock_enable = !state_oe_disabled(state_q) &&
                           (phase_c_mode_q == PC_NONE) &&
                           (state_q != LT_TRAINERROR);

  // -------------------------------------------------------------------------
  // assign: mb_clock_run - Mainband Forwarded Clock Run Request Driver
  //
  // Asserts active forwarded clock running request during continuous-clock
  // operational states (LINKSPEED, LINKINIT, ACTIVE) and during RXCLKCAL
  // when actively governed by received peer clock start/done requests.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.4.5, 4.5.3.4.12, and 5.12.
  // -------------------------------------------------------------------------
  assign mb_clock_run = (phase_c_mode_q == PC_NONE) &&
                        ((state_q == LT_MB_LINKSPEED) ||
                         (state_q == LT_LINKINIT)     ||
                         (state_q == LT_ACTIVE)       ||
                         rxclkcal_tx_clk_run_q);

  // =========================================================================
  // Fixed-profile sideband training message and sequence lookup
  // =========================================================================
  // Only MBINIT and MBTRAIN through LINKSPEED participate in sideband training.
  // Every sequence entry is one complete request and response transaction.
  // The step index never changes until the current transaction completes.
  // MBTRAIN.REPAIR, PHYRETRAIN, and TRAINERROR have no sideband training exchange.
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

  function automatic logic [7:0] expected_req_code(input ltsm_state_t s, input logic [2:0] step);
    case (s)
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:  expected_req_code = MC_MBINIT_REQ;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL:  expected_req_code = MC_MBTRAIN_REQ;
      LT_MB_VTCENTER:  expected_req_code = (step == 3'd1) ? 8'hBA : MC_MBTRAIN_REQ;
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: expected_req_code = 8'hBA;
      default:         expected_req_code = MC_NOP_CRD;
    endcase
  endfunction

  function automatic logic [7:0] expected_rsp_code(input ltsm_state_t s, input logic [2:0] step);
    case (s)
      LT_MBINIT_PARAM,
      LT_MBINIT_CAL,
      LT_MBINIT_RPCLK,
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:  expected_rsp_code = MC_MBINIT_RSP;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_SPEEDIDLE,
      LT_MB_TXSELFCAL,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER:  expected_rsp_code = MC_MBTRAIN_RSP;
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: expected_rsp_code = 8'hB5;
      default:         expected_rsp_code = MC_NOP_CRD;
    endcase
  endfunction

  function automatic logic [2:0] sequence_last_step(input ltsm_state_t s);
    case (s)
      LT_MBINIT_RPCLK: sequence_last_step = 3'd5;
      LT_MBINIT_RPVAL,
      LT_MBINIT_REVMB,
      LT_MBINIT_RPMB:  sequence_last_step = 3'd3;
      LT_MB_VALVREF,
      LT_MB_DATAVREF,
      LT_MB_RXCLKCAL,
      LT_MB_VTCENTER,
      LT_MB_DTVREF1,
      LT_MB_RXDESKEW,
      LT_MB_DTCENTER2,
      LT_MB_LINKSPEED: sequence_last_step = 3'd1;
      default:         sequence_last_step = 3'd0;
    endcase
  endfunction

  function automatic logic [7:0] expected_req_subcode(
    input ltsm_state_t s,         // LTSM state to evaluate
    input logic [2:0]  step       // Sequence step within state
  );
    case (s)
      LT_MBINIT_PARAM: expected_req_subcode = MS_PARAM_CFG;
      LT_MBINIT_CAL:   expected_req_subcode = MS_CAL_DONE;

      LT_MBINIT_RPCLK: begin
        case (step)
          3'd0: expected_req_subcode = MS_RPCLK_INIT;
          3'd1: expected_req_subcode = MS_RPCLK_RESULT;
          3'd2: expected_req_subcode = MS_RPCLK_APPLY;
          3'd3: expected_req_subcode = MS_RPCLK_CHKINI;
          3'd4: expected_req_subcode = MS_RPCLK_CHKRES;
          3'd5: expected_req_subcode = MS_RPCLK_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_RPVAL: begin
        case (step)
          3'd0: expected_req_subcode = MS_RPVAL_INIT;
          3'd1: expected_req_subcode = MS_RPVAL_RESULT;
          3'd2: expected_req_subcode = MS_RPVAL_APPLY;
          3'd3: expected_req_subcode = MS_RPVAL_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_REVMB: begin
        case (step)
          3'd0: expected_req_subcode = MS_REVMB_INIT;
          3'd1: expected_req_subcode = MS_REVMB_CLRERR;
          3'd2: expected_req_subcode = MS_REVMB_RESULT;
          3'd3: expected_req_subcode = MS_REVMB_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MBINIT_RPMB: begin
        case (step)
          3'd0: expected_req_subcode = MS_RPMB_START;
          3'd1: expected_req_subcode = MS_RPMB_APPLY;
          3'd2: expected_req_subcode = MS_RPMB_END;
          3'd3: expected_req_subcode = MS_RPMB_END2;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_VALVREF: begin
        case (step)
          3'd0: expected_req_subcode = MS_VALVREF_START;
          3'd1: expected_req_subcode = MS_VALVREF_END;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_DATAVREF: begin
        case (step)
          3'd0: expected_req_subcode = MS_DATAVREF_START;
          3'd1: expected_req_subcode = MS_DATAVREF_END;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_SPEEDIDLE: expected_req_subcode = MS_SPEEDIDLE_DONE;
      LT_MB_TXSELFCAL: expected_req_subcode = MS_TXSELFCAL_DONE;

      LT_MB_RXCLKCAL: begin
        case (step)
          3'd0: expected_req_subcode = MS_RXCLKCAL_START;
          3'd1: expected_req_subcode = MS_RXCLKCAL_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_VTCENTER: begin
        case (step)
          3'd0: expected_req_subcode = MS_VTC_START;
          3'd1: expected_req_subcode = MS_VTC_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_DTVREF1: begin
        case (step)
          3'd0: expected_req_subcode = MS_DTV_START;
          3'd1: expected_req_subcode = MS_DTV_END;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_RXDESKEW: begin
        case (step)
          3'd0: expected_req_subcode = MS_DESKEW_START;
          3'd1: expected_req_subcode = MS_DESKEW_END;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_DTCENTER2: begin
        case (step)
          3'd0: expected_req_subcode = MS_DTC2_START;
          3'd1: expected_req_subcode = MS_DTC2_END;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      LT_MB_LINKSPEED: begin
        case (step)
          3'd0: expected_req_subcode = MS_LKS_START;
          3'd1: expected_req_subcode = MS_LKS_DONE;
          default: expected_req_subcode = 8'hFF;
        endcase
      end

      default: expected_req_subcode = 8'hFF;
    endcase
  endfunction

  function automatic logic [7:0] expected_rsp_subcode(
    input ltsm_state_t s,         // LTSM state to evaluate
    input logic [2:0]  step       // Sequence step within state
  );
    case (s)
      LT_MB_DTVREF1: begin
        case (step)
          3'd0: expected_rsp_subcode = 8'h0F;
          3'd1: expected_rsp_subcode = MS_DTV_END;
          default: expected_rsp_subcode = 8'hFF;
        endcase
      end
      default: expected_rsp_subcode = expected_req_subcode(s, step);
    endcase
  endfunction

  // The public state selects the message code. The private step selects the
  // exact subcode. A state-entry cycle always addresses step zero so stale
  // state from the prior public state cannot classify an inbound packet.
  // These values implement UCIe 1.0 Table 53 and Section 4.5.3
  // Tables 53, 54, and 56.
  wire       phase_b_active  = phase_b_state_supported(state_q);
  wire [2:0] active_txn_step = state_entry ? 3'd0 : txn_step_q;
  wire [7:0] current_req_code    = expected_req_code(state_q, active_txn_step);
  wire [7:0] current_req_subcode = expected_req_subcode(state_q, active_txn_step);
  wire [7:0] current_rsp_code    = expected_rsp_code(state_q, active_txn_step);
  wire [7:0] current_rsp_subcode = expected_rsp_subcode(state_q, active_txn_step);

  wire [7:0] current_subcode    = current_req_subcode;
  // =========================================================================
  // Sideband receive classification
  // =========================================================================
  // SBINIT retains its original no-data PHY-to-PHY packet classifier.
  // Sideband training has a separate complete packet contract below. This split keeps
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
  // Parameter exchange PARAM payload rules
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
  // Parameter exchange complete packet validation and role separation
  // =========================================================================
  // Every packet must be parity-clean and use the exact opcode, IDs,
  // zero MsgInfo, current code, current subcode, role, and payload rule.
  // A request creates a peer response obligation. Only a response can
  // complete the local request, and a response before acceptance is fatal.
  // Any packet outside a supported parameter exchange is unexpected.
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
                              (sb_rx_msginfo == 16'h0000);

  wire phase_b_req_payload_valid =
    (state_q != LT_MBINIT_PARAM) || param_req_valid;
  wire phase_b_rsp_payload_valid =
    (state_q != LT_MBINIT_PARAM) || param_rsp_valid;

  wire rxclkcal_skew_subcode =
    (sb_rx_msgcode == MC_MBTRAIN_REQ) &&
    ((sb_rx_msgsubcode == MS_RXCLKCAL_START) ||
     (sb_rx_msgsubcode == MS_RXCLKCAL_DONE));

  wire rxclkcal_skew_state =
    (state_q == LT_MB_TXSELFCAL) ||
    (state_q == LT_MB_RXCLKCAL)  ||
    (state_q == LT_MB_VTCENTER);

  wire peer_subcode_match =
    (rxclkcal_skew_state && rxclkcal_skew_subcode)
      ? 1'b1
      : (state_q == LT_MB_RXCLKCAL)
        ? ((sb_rx_msgsubcode == MS_RXCLKCAL_START) ||
           (sb_rx_msgsubcode == MS_RXCLKCAL_DONE))
        : (sb_rx_msgsubcode == current_req_subcode);

  wire phase_b_peer_req = phase_b_common_valid &&
                          (sb_rx_msgcode == current_req_code) &&
                          peer_subcode_match &&
                          phase_b_req_payload_valid &&
                          !(phase_b_rsp_expected && !local_resp_rcvd_q &&
                            (current_req_code == current_rsp_code) &&
                            (current_req_subcode == current_rsp_subcode));
  wire phase_b_peer_rsp = phase_b_common_valid &&
                          (sb_rx_msgcode == current_rsp_code) &&
                          (sb_rx_msgsubcode == current_rsp_subcode) &&
                          phase_b_rsp_payload_valid;
  wire phase_b_packet_valid = phase_b_peer_req || phase_b_peer_rsp;

  // A no-data packet has no logical payload. Normalize it to zero before
  // identity comparison so stale codec payload storage cannot change an
  // otherwise identical request. DATA64 preserves all 64 payload bits.
  // Identity also preserves opcode, IDs, MsgInfo, code, and subcode.
  // Spec refs: UCIe 1.0 Section 6.1.2 and Table 56.
  wire [63:0] peer_req_identity_payload =
    (sb_rx_opcode == SB_OP_MSG_DATA64) ? sb_rx_payload : 64'h0;
  wire [106:0] rx_peer_req_identity = {
    sb_rx_opcode, sb_rx_srcid, sb_rx_dstid, sb_rx_msginfo,
    sb_rx_msgcode, sb_rx_msgsubcode, peer_req_identity_payload
  };
  wire peer_req_identity_match =
    (rx_peer_req_identity == peer_req_identity_q);
  wire [7:0] peer_req_saved_subcode = peer_req_identity_q[71:64];

  wire phase_b_early_rsp = phase_b_peer_rsp &&
                           (state_entry || !local_req_accepted_q);

  wire rxclkcal_subsequent_req = (sb_rx_msgcode == MC_MBTRAIN_REQ) &&
                                 (sb_rx_msgsubcode == MS_RXCLKCAL_DONE) &&
                                 (peer_req_saved_subcode == MS_RXCLKCAL_START) &&
                                 !peer_resp_pending_q;

  wire phase_b_peer_req_conflict = phase_b_peer_req && !state_entry &&
                                   peer_req_valid_q &&
                                   !peer_req_identity_match &&
                                   !rxclkcal_subsequent_req;

  // =========================================================================
  // LinkMgmt.RDI no-data packet decoding
  // =========================================================================
  // Every supported LinkMgmt.RDI and TRAINERROR packet is a parity-clean,
  // no-data PHY-to-PHY packet with zero MsgInfo. The decoder intentionally
  // accepts no other LinkMgmt subcode. A valid remote LinkError request is a
  // fatal trigger and therefore starts TRAINERROR Entry instead of producing
  // an unsupported LinkMgmt.RDI LinkError response.
  // Spec refs: UCIe 1.0 Sections 4.5.3.8, 6.1.2.2, 8.1.6, and 8.3.2.8;
  //            Tables 53 and 54; Sections 8.1.6, 8.3.2.8, and 8.3.3.
  // =========================================================================
  wire phase_c_common_valid = sb_rx_pkt_vld &&
                              !sb_rx_cp_err && !sb_rx_dp_err &&
                              (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                              (sb_rx_srcid == SRCID_PHY) &&
                              (sb_rx_dstid == DSTID_REMOTE_PHY) &&
                              (sb_rx_msginfo == 16'h0000);

  wire rx_active_req = phase_c_common_valid &&
                       (sb_rx_msgcode == MC_LM_RDI_REQ) &&
                       (sb_rx_msgsubcode == MS_LM_ACTIVE);
  wire rx_active_rsp = phase_c_common_valid &&
                       (sb_rx_msgcode == MC_LM_RDI_RSP) &&
                       (sb_rx_msgsubcode == MS_LM_ACTIVE);
  wire rx_linkreset_req = phase_c_common_valid &&
                          (sb_rx_msgcode == MC_LM_RDI_REQ) &&
                          (sb_rx_msgsubcode == MS_LM_LINKRESET);
  wire rx_linkreset_rsp = phase_c_common_valid &&
                          (sb_rx_msgcode == MC_LM_RDI_RSP) &&
                          (sb_rx_msgsubcode == MS_LM_LINKRESET);
  wire rx_disabled_req = phase_c_common_valid &&
                         (sb_rx_msgcode == MC_LM_RDI_REQ) &&
                         (sb_rx_msgsubcode == MS_LM_DISABLE);
  wire rx_disabled_rsp = phase_c_common_valid &&
                         (sb_rx_msgcode == MC_LM_RDI_RSP) &&
                         (sb_rx_msgsubcode == MS_LM_DISABLE);
  wire rx_linkerror_req = phase_c_common_valid &&
                          (sb_rx_msgcode == MC_LM_RDI_REQ) &&
                          (sb_rx_msgsubcode == MS_LM_LINKERROR);
  wire rx_trainerror_req = phase_c_common_valid &&
                           (sb_rx_msgcode == MC_TE_REQ) &&
                           (sb_rx_msgsubcode == MS_TE_ENTRY);
  wire rx_trainerror_rsp = phase_c_common_valid &&
                           (sb_rx_msgcode == MC_TE_RSP) &&
                           (sb_rx_msgsubcode == MS_TE_ENTRY);

  // A response is valid only after the matching local request was accepted.
  // Valid requests remain accepted while a higher-priority transition aborts
  // normal progress, because their response obligation must not be discarded.
  wire phase_b_rsp_expected = phase_b_peer_rsp &&
                              local_req_accepted_q;
  wire active_rsp_expected = rx_active_rsp && active_req_accepted_q;
  wire linkreset_rsp_expected = rx_linkreset_rsp &&
                                (phase_c_mode_q == PC_LINKRESET) &&
                                linkreset_req_accepted_q;
  wire disabled_rsp_expected = rx_disabled_rsp &&
                               (phase_c_mode_q == PC_DISABLED) &&
                               disabled_req_accepted_q;
  wire trainerror_rsp_expected = rx_trainerror_rsp &&
                                 (phase_c_mode_q == PC_TRAINERROR) &&
                                 trainerror_req_accepted_q;

  wire sideband_policy_active = (state_q != LT_RESET) &&
                                (state_q != LT_SBINIT);
  wire current_phase_b_packet_valid = phase_b_active &&
    ((phase_b_peer_req && !phase_b_peer_req_conflict) ||
     phase_b_rsp_expected);
  wire current_active_packet_valid = (state_q == LT_LINKINIT) &&
    (rx_active_req || active_rsp_expected);
  wire phase_c_request_valid = rx_linkreset_req ||
    ((state_q != LT_TRAINERROR) &&
     (rx_disabled_req || rx_linkerror_req || rx_trainerror_req));
  wire phase_c_response_valid = linkreset_rsp_expected ||
                                disabled_rsp_expected ||
                                trainerror_rsp_expected;
  wire post_sbinit_packet_valid = current_phase_b_packet_valid ||
                                  current_active_packet_valid ||
                                  phase_c_request_valid ||
                                  phase_c_response_valid;
  wire post_sbinit_rx_event = sb_rx_pkt_vld && sideband_policy_active;
  wire post_sbinit_rx_fatal = post_sbinit_rx_event &&
                              !post_sbinit_packet_valid;
  wire local_packet_fatal = post_sbinit_rx_fatal;
  // The datapath adds the private mainband framing fault. The logical PHY derives
  // one fresh event from the sticky receive-gearbox level, so the LTSM needs
  // no edge detector of its own. This term is combinational and feeds
  // start_trainerror_exchange directly, which the LinkMgmt.RDI next-state logic
  // consumes on the same rising lclk edge, so a single-cycle event is enough.
  // One event starts one fatal entry; a second event during the TRAINERROR
  // Entry exchange only joins the local obligation beside an existing one.
  wire fatal_trigger_event = local_packet_fatal || rx_linkerror_req ||
                             framing_fault_event;

  // Validated peer LinkError request (TRAINERROR Entry req or LinkMgmt LinkError req)
  wire peer_linkerror_req_valid = sideband_policy_active &&
                                  (rx_trainerror_req || rx_linkerror_req);
  // Valid matching response to our accepted local request
  wire local_linkerror_rsp_valid = trainerror_rsp_expected && !local_packet_fatal;

  // Dwell satisfaction per Section 8.3.2.7:
  // Dwell is satisfied if peer acknowledged/requested LinkError, or if
  // LinkError residency timer expired, or if 8 ms elapsed in PC_TRAINERROR.
  wire linkerror_dwell_satisfied = sb_linkerror_ack_q ||
                                   linkerror_min_done_q ||
                                   le_tmr_expired ||
                                   trainerror_exchange_timeout_q;

  // Legal recovery triggers per Section 8.3.2.7 and Figure 126
  wire linkerror_recovery_trigger = (!rdi_lp_linkerror && rdi_active_req) ||
                                    software_start_event ||
                                    rdi_linkreset_req;

  // =========================================================================
  // LinkMgmt.RDI transition triggers and 8 ms timeout classes
  // =========================================================================
  // LinkError has priority over Disabled, which has priority over LinkReset.
  // A normal state timeout and a LinkReset or Disabled response timeout are
  // local fatal events. A TRAINERROR timeout enters the public error hold.
  // SBINIT keeps its separate direct timeout path because Section 4.5.3.8
  // exempts SBINIT from the TRAINERROR Entry handshake.
  // The datapath adds the private mainband framing fault to fatal_trigger_event.
  // It is not a new class: internal_fatal_event applies the same
  // post-SBINIT and non-TRAINERROR gating to it as to every other fatal
  // cause, so RESET and SBINIT ignore it and TRAINERROR does not restart its
  // own exchange for it.
  // Spec refs: UCIe 1.0 Sections 4.5, 4.5.3.8, and 8.3.2.8;
  //            UCIe 1.0 Sections 4.1.2, 4.5.3.8, 8.1.6, and 8.3.3.2.
  // =========================================================================
  wire normal_timed_state = (state_q != LT_RESET) &&
                            (state_q != LT_ACTIVE) &&
                            (state_q != LT_L1L2) &&
                            (state_q != LT_TRAINERROR);
  wire normal_residency_timeout = tmr_expired && timer_start_q &&
                                  (phase_c_mode_q == PC_NONE) &&
                                  normal_timed_state &&
                                  (state_q != LT_SBINIT);
  wire transition_timeout_fatal = tmr_expired && timer_start_q &&
    (((phase_c_mode_q == PC_LINKRESET) &&
      (state_q != LT_TRAINERROR)) ||
     (phase_c_mode_q == PC_DISABLED));
  wire trainerror_exchange_timeout = tmr_expired && timer_start_q &&
                                     (phase_c_mode_q == PC_TRAINERROR);
  wire recovery_exchange_timeout = tmr_expired && timer_start_q &&
                                    (phase_c_mode_q == PC_LINKRESET) &&
                                    (state_q == LT_TRAINERROR);

  wire internal_fatal_event = sideband_policy_active &&
                              (state_q != LT_TRAINERROR) &&
    (fatal_trigger_event || normal_residency_timeout ||
     (state_q == LT_MB_REPAIR));
  wire peer_trainerror_event = sideband_policy_active &&
                               (state_q != LT_TRAINERROR) &&
                               rx_trainerror_req;

  wire start_trainerror_exchange =
    (phase_c_mode_q != PC_TRAINERROR) &&
    (internal_fatal_event || peer_trainerror_event);
  wire disabled_request_event = sideband_policy_active &&
                                (state_q != LT_TRAINERROR) &&
                                (rdi_disabled_req ||
                                 (rx_disabled_req && !rx_linkerror_req));
  wire start_disabled_exchange = !start_trainerror_exchange &&
                                 disabled_request_event &&
                                 (phase_c_mode_q != PC_DISABLED) &&
                                 (phase_c_mode_q != PC_TRAINERROR);
  wire linkreset_request_event = sideband_policy_active &&
                                 (state_q != LT_TRAINERROR) &&
                                 (rdi_linkreset_req ||
                                  (rx_linkreset_req && !rx_linkerror_req &&
                                   !rx_disabled_req));
  wire start_linkreset_exchange = !start_trainerror_exchange &&
                                  !start_disabled_exchange &&
                                  linkreset_request_event &&
                                  (phase_c_mode_q == PC_NONE);
  wire phase_c_exchange_start = start_trainerror_exchange ||
                                start_disabled_exchange ||
                                start_linkreset_exchange;
  // -------------------------------------------------------------------------
  // assign: Private transition indication for the logical PHY
  //
  // A LinkMgmt.RDI exchange starts before the registered public state changes.
  // Keep the indication high in that start cycle and for the registered
  // exchange residency. Include direct state changes for the other private
  // LTSM transitions. The logical PHY uses this level to stop accepting
  // Active data before a transition can commit.
  //
  // Spec ref: UCIe 1.0 Sections 4.5.3 and 8.1.6;
  //            UCIe 1.0 Sections 4.5.3.8, 8.1.6, and 8.3.3.2.
  // -------------------------------------------------------------------------
  wire transition_start_event = phase_c_exchange_start ||
                                (state_d != state_q);

  // -------------------------------------------------------------------------
  // assign: transition_active - Physical Layer Transition Guard
  //
  // Asserts whenever an LTSM state change or LinkMgmt.RDI exchange starts or remains
  // pending. Guards the physical layer datapath and tells the adapter to stop
  // sending mainband data before any state commit occurs.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3 and Section 8.1.6;
  //           UCIe 1.0 Sections 4.5.3.8, 8.1.6, and 8.3.3.2.
  // -------------------------------------------------------------------------
  assign transition_active = transition_start_event ||
                             (phase_c_mode_q != PC_NONE);

  wire normal_transaction_allowed = (phase_c_mode_q == PC_NONE) &&
                                    !phase_c_exchange_start;

  // =========================================================================
  // Sideband transmit scheduling
  // =========================================================================
  // SBINIT keeps its private scheduler. Post-SBINIT arbitration preserves the
  // required response-first ordering across training and LinkMgmt.RDI obligations.
  // =========================================================================
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
  // LinkMgmt.RDI and sideband training transmit arbitration
  // =========================================================================
  // The fixed priority is Disabled or LinkReset response, TRAINERROR response,
  // current peer response, current local request, then duplicate replay.
  // LinkError never emits LinkMgmt.RDI LinkError in this fixed profile. It
  // selects TRAINERROR Entry. Pending bits survive mailbox busy cycles and
  // clear only when sb_tx_accepted identifies the selected transmission.
  // Spec refs: UCIe 1.0 Sections 4.5.3.8, 8.1.6, and 8.3.2.8;
  //            UCIe 1.0 Section 6.1 and Tables 53-54.
  // =========================================================================
  wire tx_disabled_resp = sideband_policy_active &&
                          disabled_peer_rsp_pending_q && !sb_tx_busy;
  wire tx_linkreset_resp = sideband_policy_active &&
                           linkreset_peer_rsp_pending_q && !sb_tx_busy &&
                           !tx_disabled_resp;
  wire tx_trainerror_resp = sideband_policy_active &&
                            trainerror_peer_rsp_pending_q && !sb_tx_busy &&
                            !tx_disabled_resp && !tx_linkreset_resp;

  wire rxclkcal_resp_ack_satisfied =
    (rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_START) ? (mb_clock_running == 1'b1) :
    (rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_DONE)  ? (mb_clock_running == 1'b0) :
    1'b1;

  wire rxclkcal_replay_ack_satisfied =
    (peer_req_saved_subcode == MS_RXCLKCAL_START) ? (mb_clock_running == 1'b1) :
    (peer_req_saved_subcode == MS_RXCLKCAL_DONE)  ? (mb_clock_running == 1'b0) :
    1'b1;

  wire tx_peer_resp = phase_b_active && peer_resp_pending_q && !sb_tx_busy &&
                      rxclkcal_resp_ack_satisfied &&
                      !tx_disabled_resp && !tx_linkreset_resp &&
                      !tx_trainerror_resp;
  wire tx_active_peer_resp = (state_q == LT_LINKINIT) && active_ready_q &&
                             active_peer_rsp_pending_q && !sb_tx_busy &&
                             !tx_disabled_resp && !tx_linkreset_resp &&
                             !tx_trainerror_resp && !tx_peer_resp;

  wire high_priority_response_tx = tx_disabled_resp ||
                                   tx_linkreset_resp || tx_trainerror_resp;
  wire current_peer_response_tx = tx_peer_resp || tx_active_peer_resp;
  wire higher_response_tx = high_priority_response_tx ||
                            current_peer_response_tx || peer_resp_pending_q;
  wire tx_trainerror_req = (phase_c_mode_q == PC_TRAINERROR) &&
                           trainerror_local_needed_q &&
                           !trainerror_req_accepted_q && !sb_tx_busy &&
                           !higher_response_tx;
  wire tx_disabled_req = (phase_c_mode_q == PC_DISABLED) &&
                         disabled_local_needed_q &&
                         !disabled_req_accepted_q && !sb_tx_busy &&
                         !higher_response_tx && !tx_trainerror_req;
  wire tx_linkreset_req = (phase_c_mode_q == PC_LINKRESET) &&
                          linkreset_local_needed_q &&
                          !linkreset_req_accepted_q && !sb_tx_busy &&
                          !higher_response_tx && !tx_trainerror_req &&
                          !tx_disabled_req;
  wire tx_active_req = normal_transaction_allowed &&
                       (state_q == LT_LINKINIT) && active_ready_q &&
                       !active_req_accepted_q && !sb_tx_busy &&
                       !higher_response_tx && !tx_trainerror_req &&
                       !tx_disabled_req && !tx_linkreset_req;

  wire phase_c_local_tx = tx_trainerror_req || tx_disabled_req ||
                          tx_linkreset_req || tx_active_req;
  wire tx_local_req = phase_b_active && normal_transaction_allowed &&
                      !local_req_accepted_q && !sb_tx_busy &&
                      !higher_response_tx && !phase_c_local_tx;
  wire tx_dup_peer = phase_b_active && peer_replay_pending_q && !sb_tx_busy &&
                     rxclkcal_replay_ack_satisfied &&
                     !high_priority_response_tx && !tx_peer_resp &&
                     !tx_active_peer_resp && !phase_c_local_tx &&
                     !tx_local_req;

  // PARAM is the only supported packet with a data payload. LinkMgmt.RDI sends are
  // all MSG_NODATA packets and therefore never select this payload path.
  wire tx_param_send = (state_q == LT_MBINIT_PARAM) &&
                       (tx_peer_resp || tx_local_req || tx_dup_peer);

  wire phase_c_response_accept = sb_tx_accepted &&
    (tx_disabled_resp || tx_linkreset_resp || tx_trainerror_resp ||
     tx_active_peer_resp || tx_peer_resp || tx_dup_peer);

  // =========================================================================
  // Timer interfaces
  // =========================================================================
  // A public timed-state entry and each new or upgraded LinkMgmt.RDI exchange
  // restart the shared 8 ms timer. The running level remains high for the
  // complete uninterrupted state or exchange. RESET uses its separate timer.
  // Spec refs: UCIe 1.0 Sections 4.5, 4.5.3.1, 4.5.3.8, and 8.3.2.8;
  //            UCIe 1.0 Sections 8.1.6, 8.3.2.8, and 8.3.3.
  // =========================================================================
  // This pulse starts the 8 ms interval on a transition to a timed state
  // or a private exchange-mode change. It aligns with the register update.
  // UCIe 1.0 Section 4.5 defines the 8 ms residency requirement.
  // UCIe 1.0 Section 8.3.2.8 applies it to RDI transition handshakes.
  // UCIe 1.0 Section 8.3.2.8 requires reuse of this timer interface.
  assign tmr_start = ((state_d != state_q) &&
                      (state_d != LT_RESET) &&
                      (state_d != LT_ACTIVE) &&
                      (state_d != LT_L1L2) &&
                      (state_d != LT_TRAINERROR)) ||
                     (phase_c_mode_d != phase_c_mode_q);

  // Every transition into RESET starts an independent 4 ms interval.
  // LinkReset and Disabled completion both generate this transition pulse.
  // UCIe 1.0 Section 4.5.3.1 requires the dwell on every RESET entry.
  // UCIe 1.0 Section 8.3.2.8 requires fresh training after recovery.
  // UCIe 1.0 Sections 8.1.6 and 8.3.2.8 preserve both requirements.
  assign rst_tmr_start = (state_d == LT_RESET) && (state_q != LT_RESET);

  // -------------------------------------------------------------------------
  // assign: le_tmr_start - LinkError 8 ms residency timer start trigger
  //
  // Generates a one-cycle pulse when the state machine enters LT_TRAINERROR
  // to start the unscaled 8 ms residency timer (u_linkerror_timer).
  // This timer enforces the physical layer dwell required when sideband
  // is non-functional to allow the remote partner time to detect timeouts.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.7 - LinkError State.
  // -------------------------------------------------------------------------
  assign le_tmr_start  = (state_d == LT_TRAINERROR) && (state_q != LT_TRAINERROR);

  // The registered running level spans each public residency or private
  // exchange. Completion and terminal timeout clear it without a gap.
  // UCIe 1.0 Section 4.5 defines uninterrupted state residency timing.
  // UCIe 1.0 Section 4.5.3.8 defines the TRAINERROR Entry timeout.
  // UCIe 1.0 Section 8.3.2.8 requires the existing tmr_run interface.
  assign tmr_run = timer_start_q;

  // =========================================================================
  // Next-state, SBINIT, training, and LinkMgmt.RDI policy
  // =========================================================================
  // This block keeps raw SBINIT behavior isolated, advances training only when
  // no higher-priority transition exists, and retains every peer response
  // obligation across a transition. Active Entry requires both directions.
  // TRAINERROR, Disabled, and LinkReset each use a private 8 ms exchange.
  // UCIe 1.0 Sections 4.5.3.1, 4.5.3.8, 8.1.6, and 8.3.2.8 define the
  // state transitions and handshakes. UCIe 1.0 Sections 8.1.6 and 8.3.2.8
  // define the reduced-profile priority and fresh-trigger policy.
  // =========================================================================
  always_comb begin
    state_d                          = state_q;
    sbinit_phase_d                   = sbinit_phase_q;
    phase_c_mode_d                   = phase_c_mode_q;
    timer_start_d                    = timer_start_q;
    reset_min_done_d                 = reset_min_done_q;
    reset_trigger_pending_d          = reset_trigger_pending_q;
    recovery_reset_d                 = recovery_reset_q;
    sbinit_match_streak_d            = sbinit_match_streak_q;
    pattern_trigger_pending_d        = pattern_trigger_pending_q;
    sbinit_tail_count_d              = sbinit_tail_count_q;
    sbinit_window_count_d            = sbinit_window_count_q;
    sbinit_oor_sent_d                = sbinit_oor_sent_q;
    sbinit_oor_received_d            = sbinit_oor_received_q;
    sbinit_done_req_sent_d           = sbinit_done_req_sent_q;
    sbinit_done_rsp_sent_d           = sbinit_done_rsp_sent_q;
    sbinit_done_rsp_received_d       = sbinit_done_rsp_received_q;
    sbinit_done_rsp_pending_d        = sbinit_done_rsp_pending_q;
    txn_step_d                       = txn_step_q;
    local_req_accepted_d             = local_req_accepted_q;
    local_resp_rcvd_d                = local_resp_rcvd_q;
    peer_req_valid_d                 = peer_req_valid_q;
    peer_resp_pending_d              = peer_resp_pending_q;
    peer_replay_pending_d            = peer_replay_pending_q;
    peer_req_identity_d              = peer_req_identity_q;
    active_ready_d                   = active_ready_q;
    active_req_accepted_d            = active_req_accepted_q;
    active_rsp_received_d            = active_rsp_received_q;
    active_peer_req_seen_d           = active_peer_req_seen_q;
    active_peer_rsp_pending_d        = active_peer_rsp_pending_q;
    active_peer_rsp_accepted_d       = active_peer_rsp_accepted_q;
    linkreset_local_needed_d         = linkreset_local_needed_q;
    linkreset_req_accepted_d         = linkreset_req_accepted_q;
    linkreset_rsp_received_d         = linkreset_rsp_received_q;
    linkreset_peer_rsp_pending_d     = linkreset_peer_rsp_pending_q;
    disabled_local_needed_d          = disabled_local_needed_q;
    disabled_req_accepted_d          = disabled_req_accepted_q;
    disabled_rsp_received_d          = disabled_rsp_received_q;
    disabled_peer_rsp_pending_d      = disabled_peer_rsp_pending_q;
    trainerror_local_needed_d        = trainerror_local_needed_q;
    trainerror_req_accepted_d        = trainerror_req_accepted_q;
    trainerror_rsp_received_d        = trainerror_rsp_received_q;
    trainerror_peer_rsp_pending_d    = trainerror_peer_rsp_pending_q;
    sb_linkerror_ack_d               = sb_linkerror_ack_q;
    linkerror_min_done_d             = linkerror_min_done_q;
    trainerror_exchange_timeout_d    = trainerror_exchange_timeout_q;
    rxclkcal_tx_clk_run_d            = rxclkcal_tx_clk_run_q;
    rxclkcal_peer_rsp_subcode_d      = rxclkcal_peer_rsp_subcode_q;
    rxclkcal_peer_start_done_d       = rxclkcal_peer_start_done_q;
    rxclkcal_peer_finish_done_d      = rxclkcal_peer_finish_done_q;
    rxclkcal_local_done_d            = rxclkcal_local_done_q;
    phase_b_state_complete           = 1'b0;

    // Every public state owns fresh state-scoped transaction data. A RESET
    // entry also creates a recovery epoch and clears all raw SBINIT history.
    if (state_entry) begin
      phase_c_mode_d                 = PC_NONE;
      reset_trigger_pending_d        = 1'b0;
      txn_step_d                     = 3'd0;
      local_req_accepted_d           = 1'b0;
      local_resp_rcvd_d              = 1'b0;
      peer_req_valid_d               = 1'b0;
      peer_resp_pending_d            = 1'b0;
      peer_replay_pending_d          = 1'b0;
      peer_req_identity_d            = 99'd0;
      active_ready_d                 = 1'b0;
      active_req_accepted_d          = 1'b0;
      active_rsp_received_d          = 1'b0;
      active_peer_req_seen_d         = 1'b0;
      active_peer_rsp_pending_d      = 1'b0;
      active_peer_rsp_accepted_d     = 1'b0;
      linkreset_local_needed_d       = 1'b0;
      linkreset_req_accepted_d       = 1'b0;
      linkreset_rsp_received_d       = 1'b0;
      linkreset_peer_rsp_pending_d   = 1'b0;
      disabled_local_needed_d        = 1'b0;
      disabled_req_accepted_d        = 1'b0;
      disabled_rsp_received_d        = 1'b0;
      disabled_peer_rsp_pending_d    = 1'b0;
      trainerror_local_needed_d      = 1'b0;
      trainerror_req_accepted_d      = 1'b0;
      trainerror_rsp_received_d      = 1'b0;
      trainerror_peer_rsp_pending_d  = 1'b0;
      if ((state_q != LT_MB_TXSELFCAL) &&
          (state_q != LT_MB_RXCLKCAL)  &&
          (state_q != LT_MB_VTCENTER)) begin
        rxclkcal_tx_clk_run_d          = 1'b0;
        rxclkcal_peer_rsp_subcode_d    = 8'h00;
        rxclkcal_peer_start_done_d     = 1'b0;
        rxclkcal_peer_finish_done_d    = 1'b0;
        rxclkcal_local_done_d          = 1'b0;
      end
      timer_start_d                  = normal_timed_state;

      if (state_q == LT_RESET) begin
        reset_min_done_d             = 1'b0;
        linkerror_min_done_d         = 1'b0;
        sb_linkerror_ack_d           = 1'b0;
        trainerror_exchange_timeout_d = 1'b0;
        recovery_reset_d             = 1'b1;
        sbinit_phase_d               = SBI_PATTERN_ACTIVE;
        sbinit_match_streak_d        = 2'd0;
        pattern_trigger_pending_d    = 1'b0;
        sbinit_tail_count_d          = 3'd0;
        sbinit_window_count_d        = 32'd0;
        sbinit_oor_sent_d            = 1'b0;
        sbinit_oor_received_d        = 1'b0;
        sbinit_done_req_sent_d       = 1'b0;
        sbinit_done_rsp_sent_d       = 1'b0;
        sbinit_done_rsp_received_d   = 1'b0;
        sbinit_done_rsp_pending_d    = 8'd0;
      end else if (state_q == LT_SBINIT) begin
        sbinit_phase_d               = SBI_PATTERN_ACTIVE;
        sbinit_tail_count_d          = 3'd0;
        sbinit_window_count_d        = 32'd0;
        sbinit_oor_sent_d            = 1'b0;
        sbinit_oor_received_d        = 1'b0;
        sbinit_done_req_sent_d       = 1'b0;
        sbinit_done_rsp_sent_d       = 1'b0;
        sbinit_done_rsp_received_d   = 1'b0;
        sbinit_done_rsp_pending_d    = 8'd0;
      end
    end

    // RESET consumes event inputs, never their source levels. An event on the
    // RESET-entry cycle belongs to the transition being completed and cannot
    // trigger recovery. A later event remains pending through the 4 ms dwell.
    if ((state_q == LT_RESET) && !reset_entry &&
        (software_start_event ||
         (rdi_active_event && reset_rdi_req_sampled_q)))
      reset_trigger_pending_d = 1'b1;

    // LINKINIT remembers that the local RDI requested Active. This permits a
    // queued peer response after the level later changes, while preventing any
    // request or response before Active was sampled at least once.
    if ((state_q == LT_LINKINIT) && rdi_active_req)
      active_ready_d = 1'b1;

    // Accepted transmissions retire exactly the selected obligation. Request
    // acceptance and peer-response acceptance remain separate state bits.
    if (sb_tx_accepted) begin
      if (tx_disabled_resp)
        disabled_peer_rsp_pending_d = 1'b0;
      if (tx_linkreset_resp)
        linkreset_peer_rsp_pending_d = 1'b0;
      if (tx_trainerror_resp)
        trainerror_peer_rsp_pending_d = 1'b0;
      if (tx_peer_resp) begin
        peer_resp_pending_d = 1'b0;
        if (rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_START) begin
          rxclkcal_peer_start_done_d  = 1'b1;
          rxclkcal_peer_rsp_subcode_d = 8'h00;
        end else if (rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_DONE) begin
          rxclkcal_peer_finish_done_d = 1'b1;
          rxclkcal_peer_rsp_subcode_d = 8'h00;
        end
      end
      if (tx_active_peer_resp) begin
        active_peer_rsp_pending_d  = 1'b0;
        active_peer_rsp_accepted_d = 1'b1;
      end
      if (tx_trainerror_req)
        trainerror_req_accepted_d = 1'b1;
      if (tx_disabled_req)
        disabled_req_accepted_d = 1'b1;
      if (tx_linkreset_req)
        linkreset_req_accepted_d = 1'b1;
      if (tx_active_req)
        active_req_accepted_d = 1'b1;
      if (tx_local_req)
        local_req_accepted_d = 1'b1;
      if (tx_dup_peer)
        peer_replay_pending_d = 1'b0;
    end

    // A valid peer transition request creates one retained response.
    // TRAINERROR accepts only LinkReset recovery, so it ignores Disabled.
    // A valid TRAINERROR request is retained even if another field is bad.
    // A duplicate coalesces into the one pending obligation.
    if (sideband_policy_active && (state_q != LT_TRAINERROR) &&
        rx_disabled_req && !rx_linkerror_req &&
        !local_packet_fatal &&
        !(sb_tx_accepted && tx_disabled_resp))
      disabled_peer_rsp_pending_d = 1'b1;
    if (sideband_policy_active && rx_linkreset_req &&
        !rx_linkerror_req && !rx_disabled_req && !local_packet_fatal &&
        !(sb_tx_accepted && tx_linkreset_resp))
      linkreset_peer_rsp_pending_d = 1'b1;
    if (sideband_policy_active && rx_trainerror_req &&
        !(sb_tx_accepted && tx_trainerror_resp))
      trainerror_peer_rsp_pending_d = 1'b1;

    // Matching responses complete only requests already accepted by the TX
    // mailbox. Early and unsupported responses fail packet validation above.
    if (disabled_rsp_expected && !local_packet_fatal)
      disabled_rsp_received_d = 1'b1;
    if (linkreset_rsp_expected && !local_packet_fatal)
      linkreset_rsp_received_d = 1'b1;
    if (trainerror_rsp_expected && !local_packet_fatal)
      trainerror_rsp_received_d = 1'b1;

    if (peer_linkerror_req_valid || local_linkerror_rsp_valid)
      sb_linkerror_ack_d = 1'b1;
    if (le_tmr_expired)
      linkerror_min_done_d = 1'b1;
    if (trainerror_exchange_timeout)
      trainerror_exchange_timeout_d = 1'b1;

    // Training retains a current peer response or one exact duplicate replay
    // even while LinkMgmt.RDI blocks normal transaction advancement.
    if (phase_b_peer_req && !phase_b_peer_req_conflict &&
        !local_packet_fatal) begin
      if (state_entry || !peer_req_valid_q || rxclkcal_subsequent_req) begin
        peer_req_valid_d      = 1'b1;
        peer_resp_pending_d   = 1'b1;
        peer_req_identity_d   = rx_peer_req_identity;
        if (rxclkcal_skew_subcode) begin
          if (sb_rx_msgsubcode == MS_RXCLKCAL_START) begin
            rxclkcal_tx_clk_run_d       = 1'b1;
            rxclkcal_peer_rsp_subcode_d = MS_RXCLKCAL_START;
          end else if (sb_rx_msgsubcode == MS_RXCLKCAL_DONE) begin
            rxclkcal_tx_clk_run_d       = 1'b0;
            rxclkcal_peer_rsp_subcode_d = MS_RXCLKCAL_DONE;
          end
        end
      end else if (peer_req_identity_match) begin
        if (!peer_resp_pending_d && !peer_replay_pending_d &&
            !(sb_tx_accepted && tx_dup_peer))
          peer_replay_pending_d = 1'b1;
      end
    end
    if (phase_b_rsp_expected && !local_packet_fatal)
      local_resp_rcvd_d = 1'b1;

    // Active requests are fixed-field idempotent requests. One pending bit
    // coalesces duplicates, but every accepted replay delays state completion.
    if ((state_q == LT_LINKINIT) && rx_active_req &&
        !local_packet_fatal) begin
      active_peer_req_seen_d = 1'b1;
      if (!(sb_tx_accepted && tx_active_peer_resp))
        active_peer_rsp_pending_d = 1'b1;
    end
    if ((state_q == LT_LINKINIT) && active_rsp_expected &&
        !local_packet_fatal)
      active_rsp_received_d = 1'b1;

    // A remote-only transition can become bidirectional if the local RDI
    // requests the same state before the exchange completes.
    if ((phase_c_mode_q == PC_LINKRESET) && rdi_linkreset_req)
      linkreset_local_needed_d = 1'b1;
    if ((phase_c_mode_q == PC_DISABLED) && rdi_disabled_req)
      disabled_local_needed_d = 1'b1;
    if ((phase_c_mode_q == PC_TRAINERROR) && internal_fatal_event)
      trainerror_local_needed_d = 1'b1;

    // Start or upgrade one transition according to the required priority.
    // An upgrade drops the lower-priority local request but retains all peer
    // response obligations. Each change restarts the shared 8 ms timer.
    if (start_trainerror_exchange) begin
      phase_c_mode_d             = PC_TRAINERROR;
      linkreset_local_needed_d   = 1'b0;
      linkreset_req_accepted_d   = 1'b0;
      linkreset_rsp_received_d   = 1'b0;
      disabled_local_needed_d    = 1'b0;
      disabled_req_accepted_d    = 1'b0;
      disabled_rsp_received_d    = 1'b0;
      if (internal_fatal_event)
        trainerror_local_needed_d = 1'b1;
      timer_start_d = 1'b1;
    end else if (start_disabled_exchange) begin
      phase_c_mode_d             = PC_DISABLED;
      linkreset_local_needed_d   = 1'b0;
      linkreset_req_accepted_d   = 1'b0;
      linkreset_rsp_received_d   = 1'b0;
      if (rdi_disabled_req)
        disabled_local_needed_d = 1'b1;
      timer_start_d = 1'b1;
    end else if (start_linkreset_exchange) begin
      phase_c_mode_d = PC_LINKRESET;
      if (rdi_linkreset_req)
        linkreset_local_needed_d = 1'b1;
      timer_start_d = 1'b1;
    end

    // Complete one normal training transaction only after every current
    // request, response, and replay obligation is complete.
    if (phase_b_active && normal_transaction_allowed &&
        local_req_accepted_d && local_resp_rcvd_d &&
        !peer_resp_pending_d && !peer_replay_pending_d &&
        !phase_c_response_accept) begin
      local_req_accepted_d  = 1'b0;
      local_resp_rcvd_d     = 1'b0;
      if (state_q != LT_MB_RXCLKCAL) begin
        peer_req_valid_d      = 1'b0;
        peer_resp_pending_d   = 1'b0;
        peer_replay_pending_d = 1'b0;
        peer_req_identity_d   = 99'd0;
      end

      if (active_txn_step == sequence_last_step(state_q)) begin
        txn_step_d             = 3'd0;
        phase_b_state_complete = 1'b1;
        timer_start_d          = 1'b0;
        if (state_q == LT_MB_RXCLKCAL)
          rxclkcal_local_done_d = 1'b1;
      end else begin
        txn_step_d = active_txn_step + 1'b1;
      end
    end

    // Consume each atomic remote iteration result in lclk. This is the
    // unchanged raw SBINIT detection and post-detection tail policy.
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
      // The initial epoch can use raw detection or either fresh event.
      // Recovery epochs require a fresh software or RDI event after entry.
      LT_RESET: begin
        if (rst_tmr_expired)
          reset_min_done_d = 1'b1;
        if (!reset_entry && (rst_tmr_expired || reset_min_done_q) &&
            mb_source_ready &&
            (reset_trigger_pending_d ||
             (!recovery_reset_q && pattern_trigger_pending_d)))
          state_d = LT_SBINIT;
      end

      // -----------------------------------------------------------------
      // 4.5.3.2 SBINIT
      // -----------------------------------------------------------------
      // Raw waveform, detection, retry, packet ordering, and timeout policy
      // remain unchanged from the immediate-success low-data baseline.
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
              if (!sbinit_tx_idle) begin
                if (sbinit_window_count_q == (SBINIT_ACTIVE_LCLK_CYCLES - 1)) begin
                  sbinit_phase_d        = SBI_PATTERN_IDLE;
                  sbinit_window_count_d = 32'd0;
                end else begin
                  sbinit_window_count_d = sbinit_window_count_q + 1'b1;
                end
              end
            end else begin
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
            if (sbinit_oor_rx)
              sbinit_oor_received_d = 1'b1;
            if (sbinit_oor_send)
              sbinit_oor_sent_d = 1'b1;

            if (sbinit_done_req_rx &&
                (sbinit_done_rsp_pending_q != 8'hFF))
              sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q + 1'b1;

            if (sbinit_oor_sent_d && sbinit_oor_received_d &&
                !sb_tx_busy && !sb_tx_load)
              sbinit_phase_d = SBI_DONE;
          end

          SBI_DONE: begin
            if (sbinit_done_req_send)
              sbinit_done_req_sent_d = 1'b1;
            if (sbinit_done_rsp_send)
              sbinit_done_rsp_sent_d = 1'b1;

            case ({sbinit_done_req_rx, sbinit_done_rsp_send})
              2'b10: begin
                if (sbinit_done_rsp_pending_q != 8'hFF)
                  sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q + 1'b1;
              end
              2'b01: sbinit_done_rsp_pending_d =
                         sbinit_done_rsp_pending_q - 1'b1;
              default: sbinit_done_rsp_pending_d = sbinit_done_rsp_pending_q;
            endcase

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
      LT_MB_VALVREF:
        if (phase_b_state_complete) state_d = LT_MB_DATAVREF;
      LT_MB_DATAVREF:
        if (phase_b_state_complete) state_d = LT_MB_SPEEDIDLE;
      LT_MB_SPEEDIDLE:
        if (phase_b_state_complete) state_d = LT_MB_TXSELFCAL;
      LT_MB_TXSELFCAL:
        if (phase_b_state_complete) state_d = LT_MB_RXCLKCAL;
      LT_MB_RXCLKCAL: begin
        if ((phase_b_state_complete || rxclkcal_local_done_q || rxclkcal_local_done_d) &&
            (!rxclkcal_peer_start_done_q || rxclkcal_peer_finish_done_q) &&
            !rxclkcal_tx_clk_run_q && (mb_clock_running == 1'b0) &&
            !peer_resp_pending_d && !peer_replay_pending_d) begin
          state_d       = LT_MB_VTCENTER;
          timer_start_d = 1'b0;
        end
      end
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

      // Unsupported MBTRAIN.REPAIR is converted to a local fatal event above.
      LT_MB_REPAIR: state_d = state_q;

      // -----------------------------------------------------------------
      // 4.5.3.5 LINKINIT and fixed-profile runtime states
      // -----------------------------------------------------------------
      // Active Entry does not wait for pat_done. The local request and its
      // matching response complete the mandatory local exchange. A valid peer
      // request, if received, adds a response obligation but is not required
      // before Active because the remote exchange can be peer-initiated.
      LT_LINKINIT: begin
        if (normal_transaction_allowed && active_ready_d &&
            active_req_accepted_d && active_rsp_received_d &&
            !active_peer_rsp_pending_d && !phase_c_response_accept) begin
          state_d       = LT_ACTIVE;
          timer_start_d = 1'b0;
        end
      end

      LT_ACTIVE: state_d = state_q;

      // PHYRETRAIN and L1/L2 remain unsupported in the fixed profile.
      LT_PHYRETRAIN: state_d = state_q;
      LT_L1L2:       state_d = state_q;

      // -----------------------------------------------------------------
      // UCIe 1.0 Section 8.3.2.7 & Figure 126: LinkError Direct Exit to RESET
      // -----------------------------------------------------------------
      // LT_TRAINERROR holds until the 8 ms residency dwell is satisfied
      // (either via sideband ACK bypass or fallback 8 ms timer expiration)
      // AND an approved recovery trigger (fresh Start event, RDI Active
      // request, or LinkReset request) is asserted with errors cleared.
      // Prior to exiting directly to RESET, all in-flight or pending sideband
      // responses are fully drained to prevent CDC truncation in raw mode.
      // Spec ref: UCIe 1.0 Sections 4.5.3.8, 8.1.5 (Fig 111), 8.2.5 (Fig 119),
      //           8.3.2.7 (LinkError State), and 8.3.3.2 (Figure 126).
      // -----------------------------------------------------------------
      LT_TRAINERROR: begin
        if (linkerror_dwell_satisfied && linkerror_recovery_trigger &&
            !trainerror_peer_rsp_pending_d && !sb_tx_busy && !sb_tx_load)
          state_d = LT_RESET;
        else
          state_d = state_q;
      end

      default: state_d = LT_RESET;
    endcase

    // A newly selected higher-priority exchange suppresses any normal state
    // transition calculated in the same cycle.
    if (phase_c_exchange_start)
      state_d = state_q;

    // A missing LinkReset or Disabled response is a fatal LinkError result.
    // It starts TRAINERROR Entry with a new 8 ms interval. If that exchange
    // also times out, the public TRAINERROR hold begins unconditionally.

    // Complete the selected LinkMgmt.RDI exchange only after its local exchange,
    // when required, and every retained peer response obligation are done.
    case (phase_c_mode_q)
      PC_LINKRESET: begin
        if (recovery_exchange_timeout) begin
          state_d        = LT_TRAINERROR;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end else if ((phase_c_mode_d == PC_LINKRESET) &&
                     (!linkreset_local_needed_d ||
                      (linkreset_req_accepted_d &&
                       linkreset_rsp_received_d)) &&
                     !peer_resp_pending_d && !peer_replay_pending_d &&
                     !active_peer_rsp_pending_d &&
                     !linkreset_peer_rsp_pending_d &&
                     !disabled_peer_rsp_pending_d &&
                     !trainerror_peer_rsp_pending_d &&
                     !phase_c_response_accept &&
                     !sb_tx_busy && !sb_tx_load &&
                     rdi_linkreset_published) begin
          state_d        = LT_RESET;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end
      end

      PC_DISABLED: begin
        if ((phase_c_mode_d == PC_DISABLED) &&
            (!disabled_local_needed_d ||
             (disabled_req_accepted_d && disabled_rsp_received_d)) &&
            !peer_resp_pending_d && !peer_replay_pending_d &&
            !active_peer_rsp_pending_d &&
            !linkreset_peer_rsp_pending_d &&
            !disabled_peer_rsp_pending_d &&
            !trainerror_peer_rsp_pending_d &&
            !phase_c_response_accept &&
            !sb_tx_busy && !sb_tx_load &&
            rdi_disabled_published) begin
          state_d        = LT_RESET;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end
      end

      PC_TRAINERROR: begin
        if (trainerror_exchange_timeout) begin
          state_d        = LT_TRAINERROR;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end else if ((phase_c_mode_d == PC_TRAINERROR) &&
                     trainerror_local_needed_d &&
                     trainerror_req_accepted_d &&
                     trainerror_rsp_received_d &&
                     !peer_resp_pending_d && !peer_replay_pending_d &&
                     !active_peer_rsp_pending_d &&
                     !linkreset_peer_rsp_pending_d &&
                     !disabled_peer_rsp_pending_d &&
                     !trainerror_peer_rsp_pending_d &&
                     !phase_c_response_accept &&
                     !sb_tx_busy && !sb_tx_load) begin
          state_d        = LT_TRAINERROR;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end else if ((phase_c_mode_d == PC_TRAINERROR) &&
                     !trainerror_local_needed_d &&
                     !peer_resp_pending_d && !peer_replay_pending_d &&
                     !active_peer_rsp_pending_d &&
                     !linkreset_peer_rsp_pending_d &&
                     !disabled_peer_rsp_pending_d &&
                     !trainerror_peer_rsp_pending_d &&
                     !phase_c_response_accept &&
                     !sb_tx_busy && !sb_tx_load) begin
          state_d        = LT_TRAINERROR;
          phase_c_mode_d = PC_NONE;
          timer_start_d  = 1'b0;
        end
      end

      default: ;
    endcase

    // SBINIT is the one sideband-initialization exception to TRAINERROR Entry.
    // Its existing 8 ms timeout enters the public error hold directly.
    if (tmr_expired && timer_start_q &&
        (phase_c_mode_q == PC_NONE) && (state_q == LT_SBINIT)) begin
      state_d        = LT_TRAINERROR;
      phase_c_mode_d = PC_NONE;
      timer_start_d  = 1'b0;
    end
  end

  // =========================================================================
  // Sideband TX packet interface
  // =========================================================================
  // SBINIT, training, and LinkMgmt.RDI share one mailbox source. The scheduler above
  // makes every source mutually exclusive and keeps response obligations until
  // sb_tx_accepted. LinkMgmt.RDI packets are no-data PHY-to-PHY messages with zero
  // MsgInfo, as required by the fixed profile.
  // Spec refs: UCIe 1.0 Sections 4.5.3.8, 6.1.2.2, and 8.1.6;
  //            UCIe 1.0 Section 6.1 and Tables 53-54.
  // =========================================================================

  // The mailbox load includes every raw, training, and LinkMgmt.RDI source.
  // The strict scheduler permits only one source in a cycle.
  // Busy mailbox cycles retain each registered response obligation.
  // UCIe 1.0 Section 6.1.3 defines packet transmission behavior.
  // PLAN.md Sections 15.3 and 15.9 define the arbitration contract.
  assign sb_tx_load = sbinit_oor_send || sbinit_done_rsp_send ||
                      sbinit_done_req_send || tx_disabled_resp ||
                      tx_linkreset_resp || tx_trainerror_resp ||
                      tx_peer_resp || tx_active_peer_resp ||
                      tx_trainerror_req || tx_disabled_req ||
                      tx_linkreset_req || tx_active_req ||
                      tx_local_req || tx_dup_peer;

  // PARAM remains the only DATA64 packet generated by this module.
  // Every Active, LinkReset, Disabled, and TRAINERROR packet is no-data.
  // UCIe 1.0 Section 6.1.2.2 defines no-data message packets.
  // UCIe 1.0 Tables 53 and 54 list the LinkMgmt.RDI encodings.
  // The supported profile limits the packet set.
  assign sb_tx_opcode = tx_param_send ? SB_OP_MSG_DATA64 : SB_OP_MSG_NODATA;

  // Every generated sideband message originates at the local PHY.
  // LinkMgmt.RDI and TRAINERROR both use the Physical Layer source.
  // UCIe 1.0 Section 6.1.2.2 defines LinkMgmt.RDI endpoint ownership.
  // UCIe 1.0 Table 49 defines the source identifier field.
  // UCIe 1.0 Section 6.1 preserves the PHY-to-PHY contract.
  assign sb_tx_srcid = SRCID_PHY;

  // Every generated sideband message targets the remote PHY.
  // No LinkMgmt.RDI message is routed through the Adapter destination.
  // UCIe 1.0 Section 6.1.2.2 defines LinkMgmt.RDI endpoint ownership.
  // UCIe 1.0 Table 49 defines the destination identifier field.
  // UCIe 1.0 Section 6.1 preserves the PHY-to-PHY contract.
  assign sb_tx_dstid = DSTID_REMOTE_PHY;

  // SBINIT Out-of-Reset retains its primary-side result encoding.
  // All other SBINIT, training, and LinkMgmt.RDI messages use zero MsgInfo.
  // UCIe 1.0 Tables 53, 54, and 56 define these MsgInfo values.
  // UCIe 1.0 Section 4.5.3.8 defines TRAINERROR Entry.
  // UCIe 1.0 Table 53 specifies zero MsgInfo for LinkMgmt.RDI.
  assign sb_tx_msginfo = sbinit_oor_send ? {8'h00, SBINIT_RESULT_PRIMARY} : 16'h0000;

  // The selected role determines the message code. LinkMgmt responses cover
  // Active, LinkReset, and Disabled. TRAINERROR uses E5h and EAh.
  // Training keeps its state-specific request and response lookup.
  // UCIe 1.0 Tables 53, 54, and 56 define all selected codes.
  // PLAN.md Sections 15.3 and 15.9 define the supported roles.
  assign sb_tx_msgcode = sbinit_oor_send      ? MC_SB_OOB_RESET :
                         sbinit_done_rsp_send ? MC_SB_DONE_RSP  :
                         sbinit_done_req_send ? MC_SB_DONE_REQ  :
                         (tx_disabled_resp || tx_linkreset_resp ||
                          tx_active_peer_resp) ? MC_LM_RDI_RSP :
                         tx_trainerror_resp ? MC_TE_RSP :
                         (tx_peer_resp || tx_dup_peer)
                           ? current_rsp_code :
                         tx_trainerror_req ? MC_TE_REQ :
                         (tx_disabled_req || tx_linkreset_req || tx_active_req)
                           ? MC_LM_RDI_REQ : current_req_code;

  // The selected transition determines the LinkMgmt.RDI message subcode.
  // Active uses 01h, LinkReset uses 09h, and Disabled uses 0Ch.
  // TRAINERROR Entry uses subcode 00h for request and response.
  // UCIe 1.0 Tables 53 and 54 define these exact values.
  // UCIe 1.0 Table 54 defines the supported subcodes.
  assign sb_tx_msgsubcode = sbinit_oor_send ? MS_SB_OOB_RESET :
                            (sbinit_done_rsp_send || sbinit_done_req_send)
                              ? MS_SB_DONE :
                            (tx_disabled_resp || tx_disabled_req)
                              ? MS_LM_DISABLE :
                            (tx_linkreset_resp || tx_linkreset_req)
                              ? MS_LM_LINKRESET :
                            (tx_active_peer_resp || tx_active_req)
                              ? MS_LM_ACTIVE :
                            (tx_trainerror_resp || tx_trainerror_req)
                              ? MS_TE_ENTRY :
                            (tx_peer_resp || tx_dup_peer)
                              ? (((tx_peer_resp && (rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_START || rxclkcal_peer_rsp_subcode_q == MS_RXCLKCAL_DONE)) ||
                                  (tx_dup_peer && (peer_req_saved_subcode == MS_RXCLKCAL_START || peer_req_saved_subcode == MS_RXCLKCAL_DONE)))
                                  ? (tx_peer_resp ? rxclkcal_peer_rsp_subcode_q : peer_req_saved_subcode)
                                  : current_rsp_subcode)
                              : current_req_subcode;

  // Message packets in this profile do not use byte enables.
  // PARAM carries a fixed full DATA64 payload through its message format.
  // UCIe 1.0 Section 6.1.2 defines the packet fields.
  // UCIe 1.0 Tables 53 through 56 define the supported messages.
  // PLAN.md Sections 15.3 and 15.9 add no byte-enable behavior.
  assign sb_tx_be = 8'h00;

  // Message packets in this profile do not use a transaction tag.
  // The value remains zero for raw, training, and LinkMgmt.RDI messages.
  // UCIe 1.0 Section 6.1.2 defines the packet fields.
  // UCIe 1.0 Tables 53 through 56 define the supported messages.
  // PLAN.md Sections 15.3 and 15.9 add no tag behavior.
  assign sb_tx_tag = 5'h00;

  // The fixed packet profile does not request end-to-end poison handling.
  // The EP bit remains low for every generated message.
  // UCIe 1.0 Section 6.1.2 defines the packet fields.
  // UCIe 1.0 Tables 53 through 56 define the supported messages.
  // PLAN.md Sections 15.3 and 15.9 add no EP behavior.
  assign sb_tx_ep = 1'b0;

  // These messages do not carry a register-access address.
  // The address field remains zero for every generated packet.
  // UCIe 1.0 Section 6.1.2 defines the packet fields.
  // UCIe 1.0 Tables 53 through 56 define the supported messages.
  // PLAN.md Sections 15.3 and 15.9 add no address behavior.
  assign sb_tx_addr = 12'h000;

  // PARAM local requests use PARAM_REQ_DATA and peer responses use
  // PARAM_RSP_DATA. Every LinkMgmt.RDI packet drives a zero payload value.
  // UCIe 1.0 Table 56 defines the PARAM DATA64 payload.
  // UCIe 1.0 Tables 53 and 54 define LinkMgmt.RDI as no-data.
  // PLAN.md Sections 15.3 and 15.9 preserve this separation.
  assign sb_tx_data_in = tx_param_send
                           ? (tx_local_req ? PARAM_REQ_DATA : PARAM_RSP_DATA)
                           : 64'h0;

  // Only PARAM asserts the mailbox data-payload qualifier.
  // LinkMgmt.RDI and TRAINERROR always clear this qualifier.
  // UCIe 1.0 Section 6.1.2 separates data and no-data messages.
  // UCIe 1.0 Tables 53, 54, and 56 define the selected formats.
  // UCIe 1.0 Tables 53 and 54 specify no-data exchanges.
  assign sb_tx_has_data = tx_param_send;

  // The LTSM residency timer owns training and LinkMgmt.RDI deadlines.
  // No independent sideband timeout status is exposed by this profile.
  // UCIe 1.0 Sections 4.5 and 8.3.2.8 define the 8 ms deadlines.
  // UCIe 1.0 Section 4.5.3.8 defines TRAINERROR timeout behavior.
  // UCIe 1.0 Section 8.3.2.8 requires reuse of tmr_start and tmr_run.
  assign sb_msg_timeout = 1'b0;

  // This fixed profile does not transmit a Stall encoding.
  // LinkMgmt.RDI therefore leaves the sideband stall status inactive.
  // UCIe 1.0 Section 4.5 defines the optional timer reset on Stall.
  // UCIe 1.0 Section 8.3.2.8 defines the transition timeout result.
  // The fixed profile does not use Stall transmission.
  assign sb_stall_sent = 1'b0;

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

  // -------------------------------------------------------------------------
  // assign: pattern_run_enable - SBINIT Raw Pattern Generation Enable
  //
  // Enables the raw pattern generator during SBINIT pattern execution.
  // Runs continuously prior to remote pattern detection, and extends for
  // exactly 3 full 64-UI iterations after detection to ensure the peer locks.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.2 and Section 5.13.
  // -------------------------------------------------------------------------
  assign pattern_run_enable = (state_q == LT_SBINIT) &&
                              (sbinit_phase_q == SBI_PATTERN_ACTIVE) &&
                              (!pattern_trigger_pending_q ||
                               (sbinit_tail_count_q <
                                (SBINIT_POST_DETECT_ITERS - 1)));

  // =========================================================================
  // Pattern generator control
  // =========================================================================
  // MBINIT and MBTRAIN keep the immediate-success low-data policy.
  // LINKINIT retains the diagnostic LFSR path and reseeds it on entry.
  // Diagnostic completion does not gate Active Entry. The LinkMgmt.RDI
  // exchange is the only normal LINKINIT exit condition.
  // Spec refs: UCIe 1.0 Sections 4.4.1 and 4.5.3.5;
  //            UCIe 1.0 Sections 8.1.6, 8.3.2.8, and 8.3.3.
  // =========================================================================

  // -------------------------------------------------------------------------
  // assign: pat_enable - Mainband Pattern Generator Enable
  //
  // Enables mainband pattern transmission during MBTRAIN.LINKSPEED per
  // Section 4.5.3.4.12. Transmitters remain idle during LINKINIT per Step 7.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.4.12 and Section 4.5.3.5.
  // -------------------------------------------------------------------------
  assign pat_enable = (state_q == LT_MB_LINKSPEED);

  // -------------------------------------------------------------------------
  // assign: pat_select - Pattern Multiplexer Selection Driver
  //
  // Selects which training pattern drives the physical lanes:
  // - VALTRAIN for VALVREF and DATAVREF sub-states.
  // - PAT_LFSR for LINKSPEED 4K-UI pseudorandom training sequence.
  // - CLKREPAIR for RXDESKEW clock phase alignment.
  // - PERLANEID for per-lane identification during link init.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.4.12 and Section 4.4.1.
  // -------------------------------------------------------------------------
  assign pat_select = (state_q == LT_MB_VALVREF)   ? PAT_VALTRAIN  :
                      (state_q == LT_MB_DATAVREF)  ? PAT_VALTRAIN  :
                      (state_q == LT_MB_LINKSPEED) ? PAT_LFSR      :
                      (state_q == LT_MB_RXDESKEW)  ? PAT_CLKREPAIR :
                                                     PAT_PERLANEID;

  // -------------------------------------------------------------------------
  // assign: pat_lfsr_reset - Training LFSR Synchronous Reset Strobe
  //
  // Resets the pseudorandom LFSR to its per-lane seed on entry to
  // MBTRAIN.LINKSPEED (to run the 4K UI pattern) and on entry to LINKINIT
  // per Section 4.5.3.5: "The LFSR must be RESET upon entering this state."
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.4.12 and Section 4.5.3.5.
  // -------------------------------------------------------------------------
  assign pat_lfsr_reset = ((state_q == LT_MB_LINKSPEED) || (state_q == LT_LINKINIT)) && state_entry;

  // -------------------------------------------------------------------------
  // assign: pat_lfsr_enable - Training LFSR Advance Clock Enable
  //
  // Advances the 23-bit Fibonacci LFSR by 8 UIs per lclk cycle during
  // MBTRAIN.LINKSPEED. Idle during LINKINIT diagnostic dwell.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.4.12 and Section 4.4.1.
  // -------------------------------------------------------------------------
  assign pat_lfsr_enable = (state_q == LT_MB_LINKSPEED);
  // =========================================================================
  // LTSM status and private LinkMgmt.RDI outputs
  // =========================================================================
  // ACTIVE and TRAINERROR remain public LTSM states. Active Entry completion
  // is a stable result while ACTIVE, while the Start clear is a one-cycle
  // state-entry pulse. RESET remains visible only after a completed LinkReset
  // or Disabled exchange, or a defensive state recovery.
  // Spec refs: UCIe 1.0 Sections 4.5.3.1, 4.5.3.5, and 4.5.3.8;
  //            UCIe 1.0 Sections 8.1.6, 8.3.2.8, and 8.3.3.
  // =========================================================================

  // active_entry_done stays high for the complete ACTIVE residency.
  // The parent RDI state machine can therefore sample a stable result.
  // UCIe 1.0 Section 8.1.6 requires Active Entry before RDI Active.
  // UCIe 1.0 Section 4.5.3.6 defines the LTSM ACTIVE state.
  // UCIe 1.0 Section 8.1.6 adds this private result port.
  assign active_entry_done = (state_q == LT_ACTIVE);

  // clear_start_link_train pulses for one cycle on successful ACTIVE entry.
  // No timeout or recovery transition can produce this clear pulse.
  // UCIe 1.0 Section 4.5.3.5 requires clearing the PHY Start copy.
  // UCIe 1.0 Section 8.1.6 defines successful Active Entry.
  // PLAN.md Sections 15.4 and 15.9 require the one-shot clear.
  assign clear_start_link_train = (state_q == LT_ACTIVE) && state_entry;

  // link_trained reflects the same completed ACTIVE residency.
  // It remains low during LINKINIT even after diagnostic pat_done.
  // UCIe 1.0 Section 4.5.3.6 defines completed physical initialization.
  // UCIe 1.0 Section 8.1.6 requires the Active Entry handshake first.
  // UCIe 1.0 Section 8.1.6 makes the LTSM the sole owner.
  assign link_trained = (state_q == LT_ACTIVE);
  // phy_training_done marks the first registered LINKINIT cycle. It remains
  // high through ACTIVE, while link_trained remains reserved for completed
  // Active Entry and RDI Active gating.
  // UCIe 1.0 Sections 8.1.5 and 8.1.6 require in-band presence before
  // Active Entry, while the LTSM completes Active Entry in LINKINIT.
  assign phy_training_done = (state_q == LT_LINKINIT) || (state_q == LT_ACTIVE);

  // train_error remains high throughout the public TRAINERROR hold.
  // It deasserts only after a completed LinkReset exchange enters RESET.
  // UCIe 1.0 Section 4.5.3.8 defines TRAINERROR behavior.
  // UCIe 1.0 Section 8.3.2.7 defines LinkError recovery constraints.
  // PLAN.md Sections 15.4 and 15.9 require LinkReset-only recovery.
  assign train_error = (state_q == LT_TRAINERROR) || (phase_c_mode_q == PC_TRAINERROR);

  // -------------------------------------------------------------------------
  // assign: link_reset_out - LTSM Public RESET Indication Driver
  //
  // Identifies that the LTSM has completed transition handshakes and is in
  // LT_RESET. Active during the full 4 ms minimum dwell per Section 4.5.3.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.1 and Section 8.3.2.8.
  // -------------------------------------------------------------------------
  assign link_reset_out     = (state_q == LT_RESET);

  // -------------------------------------------------------------------------
  // assign: phy_linkreset_req - Physical Layer LinkReset Request Status
  //
  // Indicates that a private LinkMgmt.RDI LinkReset request exchange is active.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.3 - LinkReset Handshake.
  // -------------------------------------------------------------------------
  assign phy_linkreset_req  = (phase_c_mode_q == PC_LINKRESET);

  // -------------------------------------------------------------------------
  // assign: phy_disabled_req - Physical Layer Disabled Request Status
  //
  // Indicates that a private LinkMgmt.RDI Disabled request exchange is active.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2.4 - Disabled Handshake.
  // -------------------------------------------------------------------------
  assign phy_disabled_req   = (phase_c_mode_q == PC_DISABLED);
  // Runtime PHYRETRAIN is outside the fixed profile and never completes.
  // The retained public compatibility output therefore remains inactive.
  // UCIe 1.0 Section 4.5.3.7 defines PHYRETRAIN.
  // PLAN.md Sections 15.4 and 15.9 exclude runtime retrain behavior.
  // RDI policy cutover governs the interface, not internal exchange state.
  assign phy_retrain_done = 1'b0;

  // ltsm_state exports the exact public state encoding for observability.
  // Private LinkMgmt.RDI exchange modes do not add public LTSM encodings.
  // UCIe 1.0 Section 4.5.3 defines the LTSM states.
  // UCIe 1.0 Section 7.5 defines state logging through PHY registers.
  // UCIe 1.0 Section 4.5.3 keeps public state compatibility.
  assign ltsm_state = state_q;

  // Width degradation remains unsupported in the fixed x16 profile.
  // LinkMgmt.RDI transition policy does not change negotiated width.
  // UCIe 1.0 Section 4.5.3.4 defines unsupported degrade outcomes.
  // PLAN.md Section 15.3 fixes width and treats degrade as fatal.
  // The link training policy preserves that negotiated result.
  assign lnk_is_x8 = 1'b0;

  // No half-lane selection exists because x8 degradation is unsupported.
  // The output remains zero through Active Entry and all recovery states.
  // UCIe 1.0 Section 4.5.3.4 defines width training outcomes.
  // PLAN.md Section 15.3 fixes this endpoint at x16.
  // The link training policy does not alter lane negotiation.
  assign degrade_lanes = 2'b00;

  // =========================================================================
  // Lint suppression for retained diagnostic observations
  // =========================================================================
  // pat_done remains a public compatibility input, but Active Entry does not use it
  // as a state condition. phase_b_packet_valid and phase_b_early_rsp remain
  // useful decode observations while the contextual validator drives policy.
  // =========================================================================
  logic unused_match;

  // This reduction combines intentionally non-policy observations.
  // It cannot affect a state transition or a sideband transmission.
  // UCIe 1.0 Sections 4.5.3.5 and 8.1.6 separate pat_done from Active Entry.
  // PLAN.md Sections 15.4 and 15.9 require no diagnostic completion gate.
  // The transaction terms retain visibility for simple single-pass lint tools.
  assign unused_match = phase_b_packet_valid | phase_b_early_rsp |
                        peer_req_identity_match | pat_done |
                        sb_tx_busy | sb_rx_payload[0] |
                        mb_source_ready | mb_clock_running;

endmodule

`endif

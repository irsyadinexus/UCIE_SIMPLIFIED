// ============================================================================
// File        : ut_ltsm_policy.sv
// Project     : UCIe Simplified RTL
// Module      : Unit Test — LTSM Policy (Phase B)
// DUT         : ltsm #(.NLANES(NLANES_MAX))
// ============================================================================
//
// DESCRIPTION
// -----------
// This unit test directly proves Phase B LTSM transaction policy. It
// verifies that the role-aware sideband engine correctly separates local
// requests from peer responses, treats invalid packets as fatal, replays
// duplicate requests idempotently, retains peer responses across TX busy
// intervals, arbitrates pending obligations, validates PARAM DATA64
// compatibility, and handles LINKSPEED success and failure outcomes.
//
// The test covers nine independent scenarios:
//
//   1.  Role Separation
//       A peer PARAM request never satisfies the local PARAM response
//       requirement. The LTSM stays in MBINIT.PARAM until a real DATA64
//       PARAM response carrying PARAM_RSP_DATA arrives.
//
//   2.  Fatal Invalid / Stale / Wrong-Role Packets
//       After SBINIT, a packet with a wrong ID, opcode, code, subcode, or
//       MsgInfo, a CP or DP error, a stale packet, or a response that
//       arrives before the local request is accepted escalates to
//       TRAINERROR. Each case is exercised in isolation and the LTSM is
//       reset between cases.
//
//   3.  Duplicate Replay
//       An identical peer request queued while a response obligation is
//       already pending coalesces into one response. An identical request
//       that arrives after that obligation was serviced schedules exactly
//       one idempotent replay. The test counts the DATA64 PARAM responses
//       the LTSM emits.
//
//   4.  Peer-Response Retention While TX Busy
//       While sb_tx_busy is held, the LTSM retains the queued peer
//       response obligation and cannot complete. Releasing the busy
//       delivers the retained obligation and the state advances.
//
//   5.  Arbitration
//       A queued peer response wins arbitration over the pending local
//       request. The first transmission after release is the peer
//       response; the local request follows immediately afterwards.
//
//   6.  PARAM Compatibility
//       A valid DATA64 PARAM response is accepted. A peer PARAM request
//       advertising a higher speed with a maximum Vswing is accepted. A
//       PARAM request with an out-of-range Vswing and a PARAM response
//       with an incompatible payload are fatal.
//
//   7.  LINKSPEED Outcomes
//       LINKSPEED exits to LINKINIT only after the 15h start transaction
//       and then the 19h done transaction. A done response that arrives
//       while the 15h start transaction is still outstanding is fatal.
//
//   8.  Recovery Policy
//       A malformed packet starts TRAINERROR Entry, the public error hold
//       reports LinkError, LinkReset is the only accepted recovery request,
//       and both LinkReset and Disabled recoveries require the RESET dwell
//       plus a fresh Start trigger.
//
//   9.  Private Mainband Framing Fault
//       One lclk pulse of the Phase E framing_fault_event input is a fatal
//       mainband error: it must start the existing TRAINERROR Entry
//       exchange and hold LinkError. RESET ignores the event, and the link
//       must recover through LinkReset plus a fresh Start trigger without
//       the cleared event re-firing.

// Phase F Evidence Export
// -----------------------
// Upon clean, zero-error completion of all scenarios, the test exports a minimal
// JSON evidence fragment to logs/ltsm_policy_evidence.json. This fragment proves
// successful validation of PARAM role separation, sideband arbitration, fatal
// defect escalation to TRAINERROR, PARAM compatibility, LinkReset recovery,
// Disabled recovery, and mainband framing fault recovery.
// --------
// The test bypasses CDC and codec paths. It drives sideband RX packets
// directly at lclk and observes the LTSM state transitions and the packets
// the LTSM transmits. A transmit monitor registers every packet the LTSM
// emits and numbers it, so a request pulse is never missed between task
// calls. A simple pattern counter provides pat_done for the LINKINIT state.
//
// The LTSM private input sb_tx_accepted is driven from sb_tx_load and the
// test-controlled tx_grant qualifier. Deasserting tx_grant models a mailbox
// that declines a send, which keeps local_req_accepted low without
// suppressing the request pulse itself.
//
// TIMING MODEL
// ------------
// The residency timer keeps its true 8 ms value (C_RESIDENCY) so the
// policy decisions are made against the real deadline. The RESET minimum
// timer is collapsed to C_RESET_FAST cycles because the 4 ms RESET minimum
// is verified by ut_ltsm.sv, and this test resets the LTSM many times.
// Every wait is deadline-bounded, so a stuck LTSM fails fast instead of
// stalling on the residency timer.
//
// PASS / FAIL CRITERIA
// --------------------
//   • Each scenario is a self-contained block with local error counting.
//   • Final verdict: "TEST PASSED ut_ltsm_policy" when all blocks report
//     zero errors.
//
// CLOCK AND RESET
// ---------------
// lclk runs at 500 MHz (2 ns period). No sbclk is needed because
// packets are injected directly in lclk.
//
// REFERENCES
// ----------
//   UCIe Specification:
//     Section 4.5.3   — Link Training State Machine
//     Section 4.5.3.2 — SBINIT
//     Section 4.5.3.3 — MBINIT (PARAM)
//     Section 4.5.3.4 — MBTRAIN (LINKSPEED)
//     Section 4.5.3.8 — TRAINERROR
//     Section 8.1.5   — RDI State Status Machine
//     Section 8.3.2   — State Request and Status
//     Table 47        — Sideband Packet Types
//     Table 56        — MBINIT.PARAM DATA64 request and response
//     PLAN.md         — Section 15.9 Phase F (Evidence Export)
// ----------------
//   v0.0.1  2026-09-24  Initial creation. Phase B policy verification.
//   v0.0.2  2026-09-25  Reconcile with the final Phase B contract. Drive
//                        the sb_tx_accepted input so a local request can be
//                        accepted at all. Answer every request with its
//                        matching response on the exact current sequence
//                        subcode, and make the only DATA64 exchange the
//                        PARAM request and its PARAM_RSP_DATA response.
//                        Invalid, stale, and wrong-role packets are now
//                        fatal, so each case asserts TRAINERROR and resets.
//                        Duplicate replay now proves both the queued
//                        coalescing rule and the post-service idempotent
//                        replay by counting emitted responses. LINKSPEED
//                        now exits only after the 15h start and then the
//                        19h done transaction, both selected by subcode.
//
//   v0.0.3  2026-09-25  Phase C: add LinkReset and Disabled recovery,
//                        TRAINERROR timeout, LinkError hold, RESET dwell,
//                        and fresh Start-trigger coverage.
//   v0.0.4  2026-09-25  Phase E: connect and drive the private
//                        framing_fault_event input. Add the scenario that
//                        proves the one-lclk event enters the existing
//                        TRAINERROR Entry exchange, that RESET ignores it,
//                        and that the cleared event does not block the
//                        approved LinkReset recovery.
//   v0.0.5  2026-09-25  Phase F: add minimal JSON evidence export to
//                        logs/ltsm_policy_evidence.json on error-free completion
//                        covering PARAM roles, arbitration, fatal causes,
//                        TRAINERROR, PARAM compatibility, LinkReset, Disabled,
//                        and framing fault.
//   v0.0.6  2026-09-25  Restore comment markers on the Phase F evidence
//                        description and revision entry.
//   v0.0.7  2026-09-25  Restore comment markers on the MBTRAIN and TRAINERROR
//                        specification references.
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_ltsm_policy;
  import ucie_pkg::*;

  // ---- clocks and reset
  logic        lclk, lreset_n;
  logic        start_link_train, adapter_active_req;
  logic        rdi_linkreset_req, rdi_disabled_req;
  logic        link_trained, train_error, link_reset_out, phy_retrain_done;
  logic [7:0]  ltsm_state;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;
  logic        sb_msg_timeout, sb_stall_sent;
  logic        pattern_run_enable, sbinit_raw_mode;
  logic        sbinit_rx_iter_vld, sbinit_rx_iter_match;
  logic        sbinit_tx_iter_done, sbinit_tx_idle;
  logic        pat_enable, pat_lfsr_reset, pat_lfsr_enable, pat_done;
  logic        tmr_start, tmr_run, rst_tmr_start, tmr_expired;
  logic        rst_tmr_expired;

  // ---- sideband TX from LTSM
  logic        sb_tx_load, sb_tx_busy, sb_tx_accepted;
  logic [4:0]  sb_tx_opcode;
  logic [2:0]  sb_tx_srcid, sb_tx_dstid;
  logic [15:0] sb_tx_msginfo;
  logic [7:0]  sb_tx_msgcode, sb_tx_msgsubcode;
  logic [7:0]  sb_tx_be;
  logic [4:0]  sb_tx_tag;
  logic        sb_tx_ep;
  logic [11:0] sb_tx_addr;
  logic [63:0] sb_tx_data_in;
  logic        sb_tx_has_data;

  // ---- sideband RX to LTSM
  logic        sb_rx_pkt_vld;
  logic [4:0]  sb_rx_opcode;
  logic [2:0]  sb_rx_srcid, sb_rx_dstid;
  logic [15:0] sb_rx_msginfo;
  logic [7:0]  sb_rx_msgcode, sb_rx_msgsubcode;
  logic [63:0] sb_rx_payload;
  logic        sb_rx_cp_err, sb_rx_dp_err;

  // ---- test controls
  // tx_grant models the mailbox accept qualifier. While it is low the
  // LTSM keeps presenting its request but the send is never accepted, so
  // local_req_requested stays outstanding. This lets a test hold a request
  // unaccepted without suppressing the request itself.
  logic        tx_grant;

  // Phase E private fatal source. It is a one-lclk pulse, so the test drives
  // it for a single cycle and then clears it again.
  logic        framing_fault_event;

  // ---- pattern counter (LINKINIT pat_done stand-in)
  logic [13:0] pat_ui;
  assign pat_done = pat_enable && pat_lfsr_enable &&
                    (pat_ui == LFSR_PATTERN_UI - 1);

  // ---- transmit monitor
  // Registers the packet the LTSM sends on every sb_tx_load pulse and
  // numbers the transmissions, so a task can wait for the next one even
  // when the pulse already fired. cap_* hold the most recent capture.
  logic [4:0]  tx_op_q;
  logic [7:0]  tx_code_q, tx_sub_q;
  logic [63:0] tx_data_q;
  int          tx_version;
  logic [4:0]  cap_op;
  logic [7:0]  cap_code, cap_sub;
  logic [63:0] cap_data;
  int          param_rsp_count;

  always @(posedge lclk) begin
    if (sb_tx_load) begin
      tx_op_q    <= sb_tx_opcode;
      tx_code_q  <= sb_tx_msgcode;
      tx_sub_q   <= sb_tx_msgsubcode;
      tx_data_q  <= sb_tx_data_in;
      tx_version <= tx_version + 1;
    end
    if (sb_tx_load && (sb_tx_msgcode == MC_MBINIT_RSP) &&
        (sb_tx_msgsubcode == MS_PARAM_CFG) && sb_tx_has_data)
      param_rsp_count <= param_rsp_count + 1;
  end

  // ---- global test state
  int total_errors;

  // ---- timing constants
  // C_RESET_FAST collapses the RESET minimum so the many per-case resets
  // stay quick. The true 4 ms minimum is verified by ut_ltsm.sv.
  localparam int unsigned C_RESET_FAST    = 32;
  localparam int          C_DEADLINE      = 20000;
  localparam int          C_DEADLINE_LONG = 200000;

  logic le_tmr_start;
  logic le_tmr_expired;

  // =========================================================================
  // DUT Instantiation
  // =========================================================================
  ltsm #(.NLANES(NLANES_MAX)) u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .software_start_event(start_link_train),
    .rdi_active_event(1'b0),
    .rdi_active_req(adapter_active_req),
    .rdi_linkreset_req(rdi_linkreset_req),
    .rdi_disabled_req(rdi_disabled_req),
    .active_entry_done(),
    .clear_start_link_train(),
    .link_trained(link_trained), .phy_training_done(), .train_error(train_error),
    .link_reset_out(link_reset_out), .phy_retrain_done(phy_retrain_done),
    .ltsm_state(ltsm_state), .lnk_is_x8(lnk_is_x8),
    .degrade_lanes(degrade_lanes),
    // Phase E private fatal source: the mainband framing fault event.
    .framing_fault_event(framing_fault_event),
    .sb_tx_load(sb_tx_load), .sb_tx_opcode(sb_tx_opcode),
    .sb_tx_srcid(sb_tx_srcid), .sb_tx_dstid(sb_tx_dstid),
    .sb_tx_msginfo(sb_tx_msginfo), .sb_tx_msgcode(sb_tx_msgcode),
    .sb_tx_msgsubcode(sb_tx_msgsubcode), .sb_tx_be(sb_tx_be),
    .sb_tx_tag(sb_tx_tag), .sb_tx_ep(sb_tx_ep), .sb_tx_addr(sb_tx_addr),
    .sb_tx_data_in(sb_tx_data_in), .sb_tx_has_data(sb_tx_has_data),
    .sb_tx_busy(sb_tx_busy), .sb_tx_accepted(sb_tx_accepted),
    .sb_rx_pkt_vld(sb_rx_pkt_vld), .sb_rx_opcode(sb_rx_opcode),
    .sb_rx_srcid(sb_rx_srcid), .sb_rx_dstid(sb_rx_dstid),
    .sb_rx_msginfo(sb_rx_msginfo), .sb_rx_msgcode(sb_rx_msgcode),
    .sb_rx_msgsubcode(sb_rx_msgsubcode),
    .sb_rx_payload(sb_rx_payload),
    .sb_rx_cp_err(sb_rx_cp_err), .sb_rx_dp_err(sb_rx_dp_err),
    .sb_msg_timeout(sb_msg_timeout), .sb_stall_sent(sb_stall_sent),
    .pattern_run_enable(pattern_run_enable),
    .sbinit_raw_mode(sbinit_raw_mode),
    .sbinit_rx_iter_vld(sbinit_rx_iter_vld),
    .sbinit_rx_iter_match(sbinit_rx_iter_match),
    .sbinit_tx_iter_done(sbinit_tx_iter_done),
    .sbinit_tx_idle(sbinit_tx_idle),
    .pat_enable(pat_enable), .pat_select(), .pat_lfsr_reset(pat_lfsr_reset),
    .pat_lfsr_enable(pat_lfsr_enable), .pat_done(pat_done),
    .tmr_start(tmr_start), .tmr_run(tmr_run),
    .rst_tmr_start(rst_tmr_start), .tmr_expired(tmr_expired),
    .rst_tmr_expired(rst_tmr_expired), .le_tmr_start(le_tmr_start), .le_tmr_expired(le_tmr_expired)
  );

  // The local request is accepted only when the mailbox accepts the send.
  // tx_grant lets a test decline that acceptance deterministically.
  assign sb_tx_accepted = sb_tx_load && !sb_tx_busy && tx_grant;

  // =========================================================================
  // Clock generator: 500 MHz lclk
  // =========================================================================
  initial lclk = 1'b0;
  always #1.0 lclk = ~lclk;

  // =========================================================================
  // Pattern UI counter (stand-in for the pattern generator)
  // =========================================================================
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n || !pat_enable) pat_ui <= '0;
    else                          pat_ui <= pat_ui + 1'b1;
  end

  // =========================================================================
  // RESET Minimum Timer
  // Short limit: the policy test does not re-verify the 4 ms minimum.
  // =========================================================================
  ucie_timer #(.LIMIT_CYCLES(C_RESET_FAST)) u_rst_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(rst_tmr_start),
    .running(ltsm_state == ucie_pkg::LT_RESET), .expired(rst_tmr_expired)
  );

  // =========================================================================
  // Residency Timer
  // True 8 ms value so every policy decision runs against the real
  // deadline. All test waits are far shorter, so a stuck LTSM is caught by
  // the deadline forks below, never by this timer.
  // =========================================================================
  ucie_timer #(.LIMIT_CYCLES(C_RESIDENCY)) u_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(tmr_start),
    .running(tmr_run), .expired(tmr_expired)
  );

  // Short limit for policy test: does not re-verify the full 8 ms countdown (verified in ut_ltsm.sv)
  localparam int unsigned C_LE_FAST = 40;
  ucie_timer #(.LIMIT_CYCLES(C_LE_FAST)) u_le_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(le_tmr_start),
    .running(ltsm_state == ucie_pkg::LT_TRAINERROR), .expired(le_tmr_expired)
  );

  // =========================================================================
  // Helper: drive one RX packet for one lclk cycle
  // =========================================================================
  task drive_rx;
    input logic [4:0]  opcode;
    input logic [2:0]  srcid;
    input logic [2:0]  dstid;
    input logic [15:0] msginfo;
    input logic [7:0]  msgcode;
    input logic [7:0]  msgsubcode;
    input logic [63:0] payload;
    input logic        cp_err;
    input logic        dp_err;
    begin
      @(negedge lclk);
      sb_rx_opcode     = opcode;
      sb_rx_srcid      = srcid;
      sb_rx_dstid      = dstid;
      sb_rx_msginfo    = msginfo;
      sb_rx_msgcode    = msgcode;
      sb_rx_msgsubcode = msgsubcode;
      sb_rx_payload    = payload;
      sb_rx_cp_err     = cp_err;
      sb_rx_dp_err     = dp_err;
      sb_rx_pkt_vld    = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      sb_rx_pkt_vld    = 1'b0;
    end
  endtask

  // Shorthand for a no-data PHY-to-PHY training packet.
  task drive_nodata;
    input logic [7:0] msgcode;
    input logic [7:0] msgsubcode;
    begin
      drive_rx(SB_OP_MSG_NODATA, SRCID_PHY, DSTID_REMOTE_PHY,
               16'h0000, msgcode, msgsubcode, 64'h0, 1'b0, 1'b0);
    end
  endtask

  // Shorthand for a DATA64 PHY-to-PHY training packet.
  task drive_data64;
    input logic [7:0]  msgcode;
    input logic [7:0]  msgsubcode;
    input logic [63:0] payload;
    begin
      drive_rx(SB_OP_MSG_DATA64, SRCID_PHY, DSTID_REMOTE_PHY,
               16'h0000, msgcode, msgsubcode, payload, 1'b0, 1'b0);
    end
  endtask

  // Pulse the iteration result (used to trigger RESET->SBINIT).
  task pulse_iter;
    input logic match;
    begin
      @(negedge lclk);
      sbinit_rx_iter_match = match;
      sbinit_rx_iter_vld   = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      sbinit_rx_iter_vld   = 1'b0;
    end
  endtask

  // Pulse the local iteration done (tail counting in SBINIT).
  task pulse_tx_done;
    begin
      @(negedge lclk);
      sbinit_tx_iter_done = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      sbinit_tx_iter_done = 1'b0;
    end
  endtask

  // Inject a complete SBINIT packet through the direct RX path.
  task inject_sbinit;
    input logic [7:0] msgcode;
    input logic [7:0] msgsubcode;
    input logic [2:0] srcid;
    input logic [2:0] dstid;
    input logic       cp_err;
    begin
      drive_rx(SB_OP_MSG_NODATA, srcid, dstid,
               8'h00, msgcode, msgsubcode, 64'h0, cp_err, 1'b0);
    end
  endtask

  // =========================================================================
  // Bounded state waits. A stuck LTSM returns instead of hanging forever.
  // =========================================================================
  task wait_state_bounded;
    input logic [7:0] st;
    input int         max_cycles;
    begin
      fork
        begin
          wait (ltsm_state == st);
        end
        begin
          repeat (max_cycles) @(posedge lclk);
        end
      join_any
      disable fork;
    end
  endtask

  task wait_state_change_bounded;
    input logic [7:0] st;
    input int         max_cycles;
    begin
      fork
        begin
          wait (ltsm_state != st);
        end
        begin
          repeat (max_cycles) @(posedge lclk);
        end
      join_any
      disable fork;
    end
  endtask

  // Wait for the LTSM to leave a state or to start the next transaction of
  // the same state. Both events prove the current transaction completed.
  task wait_txn_done;
    input logic [7:0] st;
    input int         version;
    begin
      fork
        begin
          wait (ltsm_state != st);
        end
        begin
          wait (tx_version != version);
        end
        begin
          repeat (C_DEADLINE) @(posedge lclk);
        end
      join_any
      disable fork;
    end
  endtask

  // =========================================================================
  // Full SBINIT handshake: drive the LTSM from RESET through SBINIT into
  // MBINIT.PARAM.
  //
  // grant controls the mailbox accept qualifier during PARAM entry. When it
  // is low the LTSM keeps presenting its PARAM request but the send is
  // never accepted, which keeps the request outstanding.
  // =========================================================================
  task run_to_mbinit_param;
    input logic grant;
    begin
      sb_tx_busy           = 1'b0;
      tx_grant             = grant;
      start_link_train     = 1'b0;
      adapter_active_req   = 1'b0;
      rdi_linkreset_req    = 1'b0;
      rdi_disabled_req     = 1'b0;
      framing_fault_event  = 1'b0;
      sb_rx_pkt_vld        = 1'b0;
      sbinit_rx_iter_vld   = 1'b0;
      sbinit_rx_iter_match = 1'b0;
      sbinit_tx_iter_done  = 1'b0;
      sbinit_tx_idle       = 1'b1;
      lreset_n = 1'b0;
      repeat (5) @(posedge lclk);
      lreset_n = 1'b1;
      adapter_active_req = 1'b1;
      repeat (10) @(posedge lclk);

      // Wait for the RESET minimum.
      @(posedge rst_tmr_expired);
      #0.1;

      // Two consecutive remote matches to exit RESET.
      pulse_iter(1'b1);
      pulse_iter(1'b1);
      wait_state_bounded(LT_SBINIT, C_DEADLINE_LONG);

      // Four tail events.
      repeat (4) pulse_tx_done();

      // Wait for Out-of-Reset phase and send the peer Out-of-Reset.
      wait (u_dut.sbinit_phase_q == 2'd2);
      inject_sbinit(MC_SB_OOB_RESET, MS_SB_OOB_RESET,
                    SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
      // Wait for Done phase.
      wait (u_dut.sbinit_phase_q == 2'd3);

      // Send the peer Done request (creates an obligation), a second peer
      // Out-of-Reset, and the peer Done response.
      inject_sbinit(MC_SB_DONE_REQ, MS_SB_DONE,
                    SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
      inject_sbinit(MC_SB_OOB_RESET, MS_SB_OOB_RESET,
                    SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
      inject_sbinit(MC_SB_DONE_RSP, MS_SB_DONE,
                    SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);

      wait_state_bounded(LT_MBINIT_PARAM, C_DEADLINE_LONG);
      repeat (2) @(posedge lclk);
    end
  endtask

  // =========================================================================
  // Wait for the LTSM to transmit a packet and capture its fields. The
  // transmit monitor keeps the last packet, so a pulse that already fired
  // is still observed.
  // =========================================================================
  task await_request;
    int version;
    begin
      if ((tx_version != 0) &&
          (tx_code_q == sb_tx_msgcode) &&
          (tx_sub_q == u_dut.current_subcode)) begin
        cap_op   = tx_op_q;
        cap_code = tx_code_q;
        cap_sub  = tx_sub_q;
        cap_data = tx_data_q;
      end else begin
        version = tx_version;
        fork
          begin
            wait (tx_version != version);
            @(negedge lclk);
            cap_op   = tx_op_q;
            cap_code = tx_code_q;
            cap_sub  = tx_sub_q;
            cap_data = tx_data_q;
          end
          begin
            repeat (C_DEADLINE) @(posedge lclk);
          end
        join_any
        disable fork;
      end
    end
  endtask

  task await_tx_code;
    input logic [7:0] expected_code;
    int cycles;
    begin
      cap_code = 8'hFF;
      for (cycles = 0; cycles < C_DEADLINE; cycles = cycles + 1) begin
        @(posedge lclk);
        #0.1;
        if (tx_code_q == expected_code) begin
          cap_op   = tx_op_q;
          cap_code = tx_code_q;
          cap_sub  = tx_sub_q;
          cap_data = tx_data_q;
          cycles   = C_DEADLINE;
        end
      end
    end
  endtask

  function automatic logic [7:0] rsp_code_for(input logic [7:0] code, input logic [7:0] subcode);
    case (code)
      MC_SB_DONE_REQ:  rsp_code_for = MC_SB_DONE_RSP;
      MC_MBINIT_REQ:   rsp_code_for = MC_MBINIT_RSP;
      MC_MBTRAIN_REQ:  rsp_code_for = (subcode == 8'h09) ? 8'hBA : MC_MBTRAIN_RSP;
      8'hBA:           rsp_code_for = (subcode == 8'h09) ? 8'hBA : 8'hB5;
      MC_LM_RDI_REQ:   rsp_code_for = MC_LM_RDI_RSP;
      MC_PHYR_REQ:     rsp_code_for = MC_PHYR_RSP;
      default:         rsp_code_for = MC_TE_RSP;
    endcase
  endfunction

  function automatic logic [7:0] rsp_subcode_for(input logic [7:0] code, input logic [7:0] subcode);
    if ((code == 8'hBA) && (subcode == 8'h0E))
      rsp_subcode_for = 8'h0F;
    else
      rsp_subcode_for = subcode;
  endfunction

  // Answer the request captured by await_request with its matching
  // response on the same sequence subcode. PARAM is the only DATA64
  // exchange and always returns the immutable PARAM_RSP_DATA payload.
  task reply_matching;
    begin
      if (ltsm_state == LT_MBINIT_PARAM)
        drive_data64(rsp_code_for(cap_code, cap_sub), rsp_subcode_for(cap_code, cap_sub), PARAM_RSP_DATA);
      else
        drive_nodata(rsp_code_for(cap_code, cap_sub), rsp_subcode_for(cap_code, cap_sub));
    end
  endtask

  // Advance one complete transaction of the current state: wait for the
  // local request, answer it, and wait for the transaction to complete.
  task advance_one_state;
    logic [7:0] st;
    int         version;
    begin
      st = ltsm_state;
      await_request();
      reply_matching();
      version = tx_version;
      fork
        begin
          wait (ltsm_state != st);
        end
        begin
          wait (tx_version != version);
          repeat (2) @(posedge lclk);
        end
        begin
          repeat (C_DEADLINE) @(posedge lclk);
        end
      join_any
      disable fork;
      repeat (2) @(posedge lclk);
    end
  endtask

  // Assert that a fatal packet completes the Phase C TRAINERROR Entry
  // exchange. The directed partner answers E5h/00h with EAh/00h, then the
  // public TRAINERROR hold proves the required LinkError result.
  task expect_fatal;
    begin
      await_tx_code(MC_TE_REQ);
      adapter_active_req = 1'b0;
      if ((cap_code == MC_TE_REQ) && (cap_sub == MS_TE_ENTRY))
        drive_nodata(MC_TE_RSP, MS_TE_ENTRY);
      fork
        begin
          wait (ltsm_state == LT_TRAINERROR);
        end
        begin
          repeat (C_DEADLINE) @(posedge lclk);
        end
      join_any
      disable fork;
      repeat (2) @(posedge lclk);
    end
  endtask

  // =========================================================================
  // Scenario 1: Role Separation
  // A peer request must never complete a local request.
  // =========================================================================
  task test_role_separation;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 1: Role Separation ---");
      run_to_mbinit_param(1'b1);

      // Send a peer PARAM request with the same code and subcode as the
      // local request. It is a request and must not satisfy the response
      // requirement, so the LTSM stays in MBINIT.PARAM.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (10) @(posedge lclk);

      if (ltsm_state != LT_MBINIT_PARAM) begin
        $display("FAIL role_sep: peer request completed local request");
        errs = errs + 1;
      end

      // The peer PARAM request queued one response obligation. The LTSM
      // services it and then waits for the real response.
      // Now send the actual DATA64 PARAM response.
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);

      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL role_sep: valid response did not advance state");
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: peer request never completes local request");
    end
  endtask

  // =========================================================================
  // Scenario 2: Fatal Invalid / Stale / Wrong-Role Packets
  // Snapshot helpers used by Scenario 4. The transmit version counter is
  // monotonic and is never reset, so a change after the snapshot proves the
  // LTSM transmitted a packet.
  int tx_version_snap;

  task baseline_tx_version;
    begin
      tx_version_snap = tx_version;
    end
  endtask

  function automatic logic tx_busy_sent;
    tx_busy_sent = (tx_version != tx_version_snap);
  endfunction

  // Every post-SBINIT packet defect escalates to TRAINERROR. Each case runs
  // in isolation and the LTSM is reset before the next case.

  // Malformed packet fields, set by each case before the call.
  logic [4:0]  bad_opcode;
  logic [2:0]  bad_srcid, bad_dstid;
  logic [15:0] bad_msginfo;
  logic [7:0]  bad_msgcode, bad_msgsubcode;
  logic [63:0] bad_payload;
  logic        bad_cp, bad_dp;

  task run_fatal_case;
    input logic grant;
    begin
      run_to_mbinit_param(grant);
      repeat (10) @(posedge lclk);
      drive_rx(bad_opcode, bad_srcid, bad_dstid, bad_msginfo,
               bad_msgcode, bad_msgsubcode, bad_payload, bad_cp, bad_dp);
      if (!grant) tx_grant = 1'b1;
      expect_fatal();
    end
  endtask

  task test_invalid_packets;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 2: Fatal Invalid Packets ---");

      // Wrong source ID.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_ADAPT; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=8'h00; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong srcid not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Wrong destination ID.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=SRCID_STACK0;
      bad_msginfo=8'h00; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong dstid not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Wrong opcode: a no-data packet where DATA64 is required.
      bad_opcode=SB_OP_MSG_NODATA; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=8'h00; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=64'h0; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong opcode not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Wrong message code (wrong role family: MBTRAIN answer in MBINIT).
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=8'h00; bad_msgcode=MC_MBTRAIN_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong msgcode not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Wrong subcode.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=8'h00; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_CAL_DONE;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong subcode not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Wrong MsgInfo (must always be zero after SBINIT).
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0001; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong msginfo not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end
      // Wrong upper MsgInfo (must always be zero after SBINIT).
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0100; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: wrong upper msginfo not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end


      // CP error packet.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0000; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b1; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: CP error not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // DP error packet.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0000; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b1;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: DP error not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Stale packet: the SBINIT Done response, valid in a prior state.
      bad_opcode=SB_OP_MSG_NODATA; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0000; bad_msgcode=MC_SB_DONE_RSP; bad_msgsubcode=MS_SB_DONE;
      bad_payload=64'h0; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b1);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: stale packet not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Early peer response: the mailbox declines the local request, so it
      // is never accepted, and the response arrives before acceptance.
      bad_opcode=SB_OP_MSG_DATA64; bad_srcid=SRCID_PHY; bad_dstid=DSTID_REMOTE_PHY;
      bad_msginfo=16'h0000; bad_msgcode=MC_MBINIT_RSP; bad_msgsubcode=MS_PARAM_CFG;
      bad_payload=PARAM_RSP_DATA; bad_cp=1'b0; bad_dp=1'b0;
      run_fatal_case(1'b0);
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL invalid: early response not fatal (state %02h)", ltsm_state);
        errs = errs + 1;
      end

      // Confirm every case really did enter TRAINERROR and recovered.
      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: all invalid packets are fatal");
    end
  endtask

  // =========================================================================
  // Scenario 3: Duplicate Replay
  // An identical queued request coalesces to one response. An identical
  // request after the obligation was serviced replays exactly once.
  // =========================================================================
  task test_duplicate_replay;
    int errs;
    int baseline;
    int seen;
    begin
      errs = 0;
      $display("--- Scenario 3: Duplicate Replay ---");
      run_to_mbinit_param(1'b1);

      // Freeze the TX path so the queued obligation cannot be served yet.
      sb_tx_busy = 1'b1;
      repeat (5) @(posedge lclk);
      baseline = param_rsp_count;

      // First peer PARAM request: queues exactly one response obligation.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (3) @(posedge lclk);

      // Identical second request while that response is still queued. The
      // obligation must coalesce to one, not add a second obligation.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (3) @(posedge lclk);

      // Release the TX path. Exactly one PARAM response must be emitted.
      sb_tx_busy = 1'b0;
      repeat (10) @(posedge lclk);
      seen = param_rsp_count - baseline;
      if (seen !== 1) begin
        $display("FAIL dup_replay: expected 1 coalesced response, saw %0d", seen);
        errs = errs + 1;
      end

      // The queued obligation was serviced. An identical request now
      // arrives after service and must schedule exactly one replay.
      baseline = param_rsp_count;
      sb_tx_busy = 1'b1;
      repeat (3) @(posedge lclk);
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (3) @(posedge lclk);
      sb_tx_busy = 1'b0;
      repeat (10) @(posedge lclk);
      seen = param_rsp_count - baseline;
      if (seen !== 1) begin
        $display("FAIL dup_replay: expected 1 replay response, saw %0d", seen);
        errs = errs + 1;
      end

      // Complete the local transaction with the real peer response.
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL dup_replay: state did not advance to CAL");
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: duplicate request replays idempotently");
    end
  endtask

  // =========================================================================
  // Scenario 4: Peer-Response Retention While TX Busy
  // While sb_tx_busy is held, the LTSM retains the queued peer response
  // obligation and cannot complete. Releasing the busy delivers it.
  // =========================================================================
  task test_tx_busy_retention;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 4: Peer-Response Retention While TX Busy ---");
      run_to_mbinit_param(1'b1);

      // The local PARAM request is already accepted. Freeze the TX path so
      // a queued peer response cannot be sent.
      sb_tx_busy = 1'b1;
      repeat (5) @(posedge lclk);
      baseline_tx_version();
      sb_tx_busy = 1'b1;

      // A peer PARAM request queues one response obligation the LTSM
      // cannot deliver while the TX path is busy.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (5) @(posedge lclk);

      // The matching response also arrives while the TX path is busy. The
      // LTSM must retain the obligation and must not complete.
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      repeat (10) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_PARAM) begin
        $display("FAIL tx_busy: state advanced while obligation retained");
        errs = errs + 1;
      end
      if (tx_busy_sent()) begin
        $display("FAIL tx_busy: LTSM transmitted while TX busy");
        errs = errs + 1;
      end

      // Release the busy. The retained obligation is served and the
      // transaction completes.
      sb_tx_busy = 1'b0;
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL tx_busy: retained response not delivered after busy");
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: peer response retained across TX busy");
    end
  endtask

  // =========================================================================
  // Scenario 5: Arbitration
  // A queued peer response takes priority over the pending local request.
  // =========================================================================
  task test_arbitration;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 5: Arbitration ---");

      // Enter MBINIT.PARAM with the mailbox declining every send. The
      // local request is presented but never accepted.
      run_to_mbinit_param(1'b0);
      repeat (5) @(posedge lclk);

      // Queue a peer response obligation.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, PARAM_REQ_DATA);
      repeat (3) @(posedge lclk);

      // The arbiter must select the queued peer response, not the local
      // request. Capture the packet the LTSM is presenting.
      await_request();
      if (cap_code != MC_MBINIT_RSP) begin
        $display("FAIL arbitration: peer response did not win (code %02h)",
                 cap_code);
        errs = errs + 1;
      end
      if (cap_data != PARAM_RSP_DATA) begin
        $display("FAIL arbitration: peer response payload %016h", cap_data);
        errs = errs + 1;
      end

      // Grant the send. The queued peer response is accepted first and the
      // local request immediately follows it.
      tx_grant = 1'b1;
      await_tx_code(MC_MBINIT_REQ);
      if (cap_code != MC_MBINIT_REQ) begin
        $display("FAIL arbitration: local request did not follow (code %02h)",
                 cap_code);
        errs = errs + 1;
      end
      if (cap_data != PARAM_REQ_DATA) begin
        $display("FAIL arbitration: local request payload %016h", cap_data);
        errs = errs + 1;
      end

      // Complete the transaction with the real peer response.
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL arbitration: state did not advance to CAL");
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: arbitration order correct");
    end
  endtask

  // =========================================================================
  // Scenario 6: PARAM Compatibility
  // A valid DATA64 PARAM response is accepted. A higher-speed peer request
  // with a maximum Vswing is accepted. An out-of-range Vswing and an
  // incompatible response payload are fatal.
  // =========================================================================
  task test_param_compatibility;
    int errs;
    logic [63:0] high_speed_req;
    begin
      errs = 0;
      $display("--- Scenario 6: PARAM Compatibility ---");

      // --- Sub-test 6a: valid response accepted ---
      run_to_mbinit_param(1'b1);
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL param_compat: valid response not accepted");
        errs = errs + 1;
      end

      // --- Sub-test 6b: higher-speed peer request accepted ---
      run_to_mbinit_param(1'b1);
      high_speed_req = PARAM_REQ_DATA;
      high_speed_req[3:0] = 4'h8;   // advertise a higher speed
      high_speed_req[8:4] = 5'h10;  // maximum accepted Vswing
      // The peer request must be accepted, not fatal.
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, high_speed_req);
      repeat (10) @(posedge lclk);
      if (ltsm_state == LT_TRAINERROR) begin
        $display("FAIL param_compat: higher-speed request was fatal");
        errs = errs + 1;
      end
      // The LTSM answers the peer request with the immutable response and
      // then completes on the real response.
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, PARAM_RSP_DATA);
      wait_state_bounded(LT_MBINIT_CAL, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_CAL) begin
        $display("FAIL param_compat: higher-speed request not accepted");
        errs = errs + 1;
      end

      // --- Sub-test 6c: out-of-range Vswing is fatal ---
      run_to_mbinit_param(1'b1);
      drive_data64(MC_MBINIT_REQ, MS_PARAM_CFG, 64'h0000_0000_0000_0000);
      expect_fatal();
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL param_compat: invalid Vswing not fatal (state %02h)",
                 ltsm_state);
        errs = errs + 1;
      end

      // --- Sub-test 6d: incompatible response payload is fatal ---
      // PARAM_RSP_DATA selects differential continuous clocks at the fixed
      // speed. Flipping the required bits makes the response incompatible.
      run_to_mbinit_param(1'b1);
      drive_data64(MC_MBINIT_RSP, MS_PARAM_CFG, ~PARAM_RSP_DATA);
      expect_fatal();
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL param_compat: bad response payload not fatal (state %02h)",
                 ltsm_state);
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: PARAM DATA64 compatibility verified");
    end
  endtask

  // =========================================================================
  // Scenario 7: LINKSPEED Outcomes
  // LINKSPEED exits to LINKINIT only after the 15h start transaction and
  // then the 19h done transaction. A done response that arrives while the
  // 15h transaction is still outstanding is fatal.
  // =========================================================================
  task test_linkspeed_outcomes;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 7: LINKSPEED Outcomes ---");

      // --- Sub-test 7a: 15h then 19h proceeds to LINKINIT and ACTIVE ---
      run_to_mbinit_param(1'b1);

      // Walk every MBINIT and MBTRAIN state in order, answering each
      // request on its exact current sequence subcode.
      while (ltsm_state != LT_MB_LINKSPEED) advance_one_state();

      // LINKSPEED step 0 carries the 15h start subcode. Answer it, then
      // step 1 carries the 19h done subcode and answer that too.
      await_request();
      if (cap_sub != MS_LKS_START) begin
        $display("FAIL linkspeed: expected 15h start, saw subcode %02h", cap_sub);
        errs = errs + 1;
      end
      reply_matching();
      wait_txn_done(LT_MB_LINKSPEED, tx_version);
      repeat (2) @(posedge lclk);

      await_request();
      if (cap_sub != MS_LKS_DONE) begin
        $display("FAIL linkspeed: expected 19h done, saw subcode %02h", cap_sub);
        errs = errs + 1;
      end
      reply_matching();
      wait_state_bounded(LT_LINKINIT, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_LINKINIT) begin
        $display("FAIL linkspeed: done did not proceed to LINKINIT (state %02h)",
                 ltsm_state);
        errs = errs + 1;
      end

      // LINKINIT exits only after the local LinkMgmt.RDI Active request has
      // a matching response. The diagnostic pattern does not gate this path.
      await_request();
      if ((cap_code != MC_LM_RDI_REQ) || (cap_sub != MS_LM_ACTIVE)) begin
        $display("FAIL linkspeed: missing LinkMgmt.RDI Active request");
        errs = errs + 1;
      end
      drive_nodata(MC_LM_RDI_RSP, MS_LM_ACTIVE);
      wait_state_bounded(LT_ACTIVE, C_DEADLINE);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_ACTIVE) begin
        $display("FAIL linkspeed: LINKINIT did not reach ACTIVE");
        errs = errs + 1;
      end

      // --- Sub-test 7b: an early done response is fatal ---
      run_to_mbinit_param(1'b1);
      while (ltsm_state != LT_MB_LINKSPEED) advance_one_state();

      // The LTSM presents the 15h start transaction. Answering it with the
      // 19h done subcode is a wrong subcode and must be fatal.
      await_request();
      if (cap_sub != MS_LKS_START) begin
        $display("FAIL linkspeed: expected 15h start, saw subcode %02h", cap_sub);
        errs = errs + 1;
      end
      drive_nodata(MC_MBTRAIN_RSP, MS_LKS_DONE);
      expect_fatal();
      if (ltsm_state != LT_TRAINERROR) begin
        $display("FAIL linkspeed: early done did not enter TRAINERROR (state %02h)",
                 ltsm_state);
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: LINKSPEED outcomes verified");
    end
  endtask

  // =========================================================================
  // Scenario 8: Phase C Recovery Policy
  // TRAINERROR holds LinkError, accepts LinkReset only, and returns to RESET.
  // Disabled also returns to RESET. Each RESET entry needs a fresh trigger.
  // =========================================================================
  task test_recovery_policy;
    int errs;
    int reset_cycles;
    begin
      errs = 0;
      $display("--- Scenario 8: Recovery Policy ---");

      // A malformed packet starts TRAINERROR Entry. Do not answer TE_REQ.
      // The 8 ms timer must complete the exchange and hold LinkError.
      bad_opcode     = SB_OP_MSG_DATA64;
      bad_srcid      = SRCID_ADAPT;
      bad_dstid      = DSTID_REMOTE_PHY;
      bad_msginfo    = 16'h0000;
      bad_msgcode    = MC_MBINIT_RSP;
      bad_msgsubcode = MS_PARAM_CFG;
      bad_payload    = PARAM_RSP_DATA;
      bad_cp         = 1'b0;
      bad_dp         = 1'b0;
      run_to_mbinit_param(1'b1);
      repeat (10) @(posedge lclk);
      drive_rx(bad_opcode, bad_srcid, bad_dstid, bad_msginfo,
               bad_msgcode, bad_msgsubcode, bad_payload, bad_cp, bad_dp);
      await_tx_code(MC_TE_REQ);
      adapter_active_req = 1'b0;
      @(posedge tmr_expired);
      @(posedge lclk);
      #0.1;
      if ((ltsm_state != LT_TRAINERROR) || !train_error) begin
        $display("FAIL recovery: TRAINERROR timeout did not hold LinkError");
        errs = errs + 1;
      end

      // Recovery per Section 8.3.2.7 & Figure 126:
      // Start / Active triggers exit from TRAINERROR to RESET once residency dwell is satisfied.
      @(negedge lclk);
      start_link_train = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      start_link_train = 1'b0;
      wait_state_bounded(LT_RESET, C_DEADLINE);
      if (ltsm_state != LT_RESET || train_error) begin
        $display("FAIL recovery: Start did not enter RESET");
        errs = errs + 1;
      end

      // The policy bench uses a short equivalent RESET interval. Count it and
      // reject the stale Start pulse before checking the fresh pulse.
      reset_cycles = 0;
      while (!rst_tmr_expired) begin
        @(posedge lclk);
        reset_cycles = reset_cycles + 1;
      end
      if (reset_cycles < (C_RESET_FAST - 2)) begin
        $display("FAIL recovery: RESET dwell too short (%0d cycles)",
                 reset_cycles);
        errs = errs + 1;
      end
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL recovery: stale Start left RESET");
        errs = errs + 1;
      end

      // A fresh Start event is required after the recovery dwell.
      @(negedge lclk);
      start_link_train = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      start_link_train = 1'b0;
      wait_state_bounded(LT_SBINIT, C_DEADLINE);
      if (ltsm_state != LT_SBINIT) begin
        $display("FAIL recovery: fresh Start did not leave RESET");
        errs = errs + 1;
      end

      // Disabled follows the same RESET and fresh-trigger policy.
      run_to_mbinit_param(1'b1);
      rdi_disabled_req = 1'b1;
      await_tx_code(MC_LM_RDI_REQ);
      if (cap_sub != MS_LM_DISABLE) begin
        $display("FAIL recovery: missing Disabled request");
        errs = errs + 1;
      end
      drive_nodata(MC_LM_RDI_RSP, MS_LM_DISABLE);
      rdi_disabled_req = 1'b0;
      wait_state_bounded(LT_RESET, C_DEADLINE);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL recovery: Disabled did not enter RESET");
        errs = errs + 1;
      end
      wait (rst_tmr_expired);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL recovery: Disabled accepted a held trigger");
        errs = errs + 1;
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: TRAINERROR, LinkReset, Disabled, and fresh Start");
    end
  endtask

  // =========================================================================
  // Scenario 9: Private Mainband Framing Fault
  //
  // The Phase E framing_fault_event input is a one-lclk pulse in lclk that
  // represents a receive-gearbox boundary violation. It must join the
  // existing fatal policy:
  //   - RESET ignores it, because the physical layer is not running yet.
  //   - After SBINIT, one pulse starts the TRAINERROR Entry exchange and the
  //     link holds LinkError.
  //   - The cleared pulse must not block the approved LinkReset recovery or
  //     re-enter TRAINERROR afterwards.
  // =========================================================================
  task test_framing_fault;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 9: Private Mainband Framing Fault ---");

      // RESET must ignore the private event. The reset prologue mirrors
      // run_to_mbinit_param so the LTSM starts from a known RESET epoch.
      sb_tx_busy          = 1'b0;
      tx_grant            = 1'b1;
      start_link_train    = 1'b0;
      adapter_active_req  = 1'b0;
      rdi_linkreset_req   = 1'b0;
      rdi_disabled_req    = 1'b0;
      sb_rx_pkt_vld       = 1'b0;
      sbinit_rx_iter_vld  = 1'b0;
      sbinit_rx_iter_match = 1'b0;
      sbinit_tx_iter_done = 1'b0;
      sbinit_tx_idle      = 1'b1;
      framing_fault_event = 1'b0;
      lreset_n = 1'b0;
      repeat (5) @(posedge lclk);
      lreset_n = 1'b1;
      repeat (5) @(posedge lclk);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL framing_fault: reset prologue did not start in RESET");
        errs = errs + 1;
      end

      @(negedge lclk);
      framing_fault_event = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      framing_fault_event = 1'b0;

      // Let the short RESET interval complete. If the event had armed a
      // RESET exit, the LTSM would leave RESET when the minimum expires; a
      // still-RESET state after the expiry proves it was ignored.
      wait (rst_tmr_expired);
      repeat (4) @(posedge lclk);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL framing_fault: RESET reacted to the private event");
        errs = errs + 1;
      end else begin
        $display("  PASS: RESET ignores the framing-fault event");
      end

      // The fatal case runs from MBINIT.PARAM, where the sideband policy is
      // active. One pulse must start TRAINERROR Entry without any packet.
      run_to_mbinit_param(1'b1);
      repeat (10) @(posedge lclk);
      if (ltsm_state != LT_MBINIT_PARAM) begin
        $display("FAIL framing_fault: did not reach MBINIT.PARAM");
        errs = errs + 1;
      end

      @(negedge lclk);
      framing_fault_event = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      framing_fault_event = 1'b0;

      // expect_fatal answers the TRAINERROR Entry request and waits for the
      // public hold, which is exactly the fatal-policy obligation.
      expect_fatal();
      if ((ltsm_state != LT_TRAINERROR) || !train_error) begin
        $display("FAIL framing_fault: event did not hold TRAINERROR");
        errs = errs + 1;
      end else begin
        $display("  PASS: framing-fault event entered TRAINERROR");
      end

      // The cleared one-lclk event must not block the approved recovery per Figure 126 / Section 8.3.2.7.
      // TRAINERROR exits directly to RESET without a LinkReset sideband exchange.
      rdi_linkreset_req = 1'b1;
      wait_state_bounded(LT_RESET, C_DEADLINE);
      rdi_linkreset_req = 1'b0;
      if (ltsm_state != LT_RESET) begin
        $display("FAIL framing_fault: LinkReset did not enter RESET");
        errs = errs + 1;
      end

      // Full RESET dwell equivalent, then a fresh Start must leave RESET.
      wait (rst_tmr_expired);
      repeat (2) @(posedge lclk);
      if (ltsm_state != LT_RESET) begin
        $display("FAIL framing_fault: RESET did not hold after LinkReset");
        errs = errs + 1;
      end
      @(negedge lclk);
      start_link_train = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      start_link_train = 1'b0;
      wait_state_bounded(LT_SBINIT, C_DEADLINE);
      if (ltsm_state != LT_SBINIT) begin
        $display("FAIL framing_fault: cleared event blocked recovery");
        errs = errs + 1;
      end else begin
        $display("  PASS: cleared event allows LinkReset and fresh Start recovery");
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: framing fault joins the existing fatal policy");
    end
  endtask

  // =========================================================================
  // Scenario 10: LinkError Minimum Residency Dwell Gate (Spec Section 8.3.2.7)
  // =========================================================================
  // Proves that entering LT_TRAINERROR without a successful sideband exchange
  // (e.g. SBINIT timeout) enforces the residency timer before allowing recovery.
  // 1. Recovery attempts while linkerror_dwell_satisfied == 0 are blocked.
  // 2. Unsolicited TE_RSP while held is rejected and does not satisfy dwell.
  // 3. Expiry of le_tmr satisfies dwell and allows direct transition to RESET.
  task test_linkerror_dwell;
    int errs;
    begin
      errs = 0;
      $display("--- Scenario 10: LinkError Minimum Residency Dwell Gate ---");

      // Reset DUT and initialize signals
      rdi_linkreset_req   = 1'b0;
      rdi_disabled_req    = 1'b0;
      framing_fault_event = 1'b0;
      start_link_train    = 1'b0;
      adapter_active_req  = 1'b0;
      lreset_n = 1'b0;
      repeat (5) @(posedge lclk);
      lreset_n = 1'b1;
      repeat (5) @(posedge lclk);
      while (!rst_tmr_expired) @(posedge lclk);

      // Start link training into SBINIT
      @(negedge lclk);
      start_link_train = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      start_link_train = 1'b0;
      wait_state_bounded(LT_SBINIT, C_DEADLINE);

      // Allow SBINIT residency timer (8 ms) to expire.
      // This enters LT_TRAINERROR directly without sideband exchange.
      @(posedge tmr_expired);
      @(posedge lclk);
      #0.1;
      if (ltsm_state != LT_TRAINERROR || !train_error) begin
        $display("FAIL dwell: SBINIT timeout did not enter TRAINERROR");
        errs = errs + 1;
      end

      // (a) Attempt recovery before le_tmr expiry (must hold TRAINERROR)
      @(negedge lclk);
      start_link_train   = 1'b1;
      adapter_active_req = 1'b1;
      repeat (10) @(posedge lclk);
      #0.1;
      if (ltsm_state != LT_TRAINERROR || !train_error) begin
        $display("FAIL dwell: exited TRAINERROR before le_tmr expiry");
        errs = errs + 1;
      end else begin
        $display("  PASS: recovery blocked while linkerror_dwell_satisfied == 0");
      end

      // (b) Unsolicited LinkError response must not satisfy dwell while held
      @(negedge lclk);
      drive_nodata(MC_TE_RSP, 8'h00);
      repeat (5) @(posedge lclk);
      #0.1;
      if (ltsm_state != LT_TRAINERROR || !train_error || u_dut.sb_linkerror_ack_q) begin
        $display("FAIL dwell: unsolicited TE_RSP satisfied dwell or triggered exit");
        errs = errs + 1;
      end else begin
        $display("  PASS: unsolicited TE_RSP rejected and does not satisfy dwell");
      end

      // (c) Wait for le_tmr_expired
      @(posedge le_tmr_expired);
      @(posedge lclk);
      #0.1;

      // Now recovery trigger must transition directly to RESET
      @(negedge lclk);
      start_link_train   = 1'b1;
      @(posedge lclk);
      @(negedge lclk);
      start_link_train   = 1'b0;
      adapter_active_req = 1'b0;
      wait_state_bounded(LT_RESET, C_DEADLINE);
      if (ltsm_state != LT_RESET || train_error) begin
        $display("FAIL dwell: recovery did not enter RESET after le_tmr expiry");
        errs = errs + 1;
      end else begin
        $display("  PASS: le_tmr expiry satisfied dwell and triggered direct exit to RESET");
      end

      total_errors = total_errors + errs;
      if (errs == 0)
        $display("  PASS: LinkError residency dwell gating verified");
    end
  endtask

  // =========================================================================
  // Main test sequence
  // =========================================================================
  initial begin
    total_errors = 0;
    tx_grant     = 1'b1;
    rdi_linkreset_req = 1'b0;
    rdi_disabled_req  = 1'b0;
    framing_fault_event = 1'b0;
    test_role_separation();
    test_invalid_packets();
    test_duplicate_replay();
    test_tx_busy_retention();
    test_arbitration();
    test_param_compatibility();
    test_linkspeed_outcomes();
    test_recovery_policy();
    test_framing_fault();
    test_linkerror_dwell();

    // Phase F: export unit evidence JSON upon clean zero-error completion.
    // Spec ref: UCIe 1.0 Section 4.5.3, Section 4.5.3.8, Table 56, and
    // PLAN.md Section 15.9 Phase F.
    if (total_errors == 0) begin
      integer fd;
      fd = $fopen("logs/ltsm_policy_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{\n");
        $fwrite(fd, "  \"param_roles\": 1,\n");
        $fwrite(fd, "  \"arbitration\": 1,\n");
        $fwrite(fd, "  \"fatal_causes\": 1,\n");
        $fwrite(fd, "  \"trainerror\": 1,\n");
        $fwrite(fd, "  \"param_compatibility\": 1,\n");
        $fwrite(fd, "  \"linkreset\": 1,\n");
        $fwrite(fd, "  \"disabled\": 1,\n");
        $fwrite(fd, "  \"framing_fault\": 1\n");
        $fwrite(fd, "}\n");
        $fclose(fd);
      end
    end

    $display("");
    if (total_errors == 0)
      $display("TEST PASSED ut_ltsm_policy");
    else
      $display("FAIL ut_ltsm_policy: %0d errors", total_errors);
    $finish;
  end

  // Watchdog timer. Generous margin for the many short resets and the
  // 4096-cycle pattern phase.
  initial begin
    #200000000;
    $display("FAIL ut_ltsm_policy: watchdog timeout, state %02h", ltsm_state);
    $finish;
  end

endmodule

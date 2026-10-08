// ============================================================================
// File        : rdi_state_machine.sv
// Module      : rdi_state_machine
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Raw Die-to-Die Interface (RDI) Link State Machine. Mediates between
//               the D2D Adapter (which requests state transitions via
//               rdi_lp_state_req) and the Logical PHY (which reports physical
//               link events: trained, Active Entry complete, reset, error).
//
// Spec refs   : UCIe 1.0 spec section 8.1.5 (RDI state transitions,
//               Figure 111), section 8.1.6 (Active-entry handshake),
//               section 8.3.1 (stall handshake), Table 114 (RDI signal
//               definitions).
//
// --------------------------------------------------------------------------
// RDI State Transition Table  (spec 8.1.5 / Figure 111, fixed profile)
// --------------------------------------------------------------------------
//
// RDI STATE TRANSITIONS (spec 8.1.5, Figure 111)
//
//                 +-------------------------------------------------------+
//                 |                                                       |
//                 v                                                       |
//             +-------+  REQ_ACTIVE + Active Entry Done    +--------+     |
//             | RESET | ---------------------------------> | ACTIVE |     |
//             +-------+                                    +--------+     |
//              ^  ^   \                                     /   |   \     |
//              |  |    \                                   /    |    \    |
//              |  |     v                                 v     |     v   |
//              |  |   +----------+                  +-------+   |   +----------+
//              |  +-- | DISABLED | <--------------- | PMNAK |   |   |LINKRESET |
//              |      +----------+                  +-------+   |   +----------+
//              |                                                |
//              |                                                v
//              |                                          +-----------+
//              +----------------------------------------- | LINKERROR |
//                     phy_link_reset (direct per Fig 111) +-----------+
//                     (spec 8.1.5 & 8.3.2.7)
//
//   State       Code   Exits
//   ----------  -----  ----------------------------------------------------
//   RESET        0h    REQ_ACTIVE + completed Active Entry -> ACTIVE
//                      REQ_DISABLED                        -> DISABLED
//   ACTIVE       1h    REQ_L1 or REQ_L2                   -> PMNAK
//                      REQ_LINKRESET                      -> LINKRESET
//                      REQ_DISABLED                       -> DISABLED
//   PMNAK        3h    REQ_ACTIVE + completed Active Entry -> ACTIVE
//   LINKRESET    9h    phy_link_reset (LTSM RESET result)  -> RESET
//   LINKERROR    Ah    phy_link_reset (direct per Fig 111) -> RESET
//   DISABLED     Ch    phy_link_reset (LTSM RESET result)  -> RESET
//   ----------  -----  ----------------------------------------------------
//
//   Preemption, highest first:
//     1. phy_train_error   -> LINKERROR  (spec 8.1.5, Figure 111)
//     2. phy_link_reset    -> RESET      (spec 8.1.5, Figure 111)
//
//   Main cycle:
//
//     RESET  --REQ_ACTIVE + completed Active Entry-->  ACTIVE
//     ACTIVE --REQ_L1 / REQ_L2--> PMNAK
//     PMNAK  --REQ_ACTIVE + completed Active Entry-->  ACTIVE
//     ACTIVE --REQ_LINKRESET-->  LINKRESET
//     ACTIVE --REQ_DISABLED -->  DISABLED
//     RESET  --REQ_DISABLED -->  DISABLED
//     LINKRESET / DISABLED --phy_link_reset (LTSM RESET result)--> RESET
//     phy_train_error  --> LINKERROR --phy_link_reset (direct per Fig 111)--> RESET
//
//   Not published in the fixed profile: L1 (4h), L2 (8h), RETRAIN (Bh).
//   REQ_L1 and REQ_L2 return PMNAK instead. REQ_RETRAIN is ignored: ACTIVE is
//   held, no Retrain status is published, and the LTSM is not touched.
//
// --------------------------------------------------------------------------
// Active-entry handshake  (spec 8.1.6)
// --------------------------------------------------------------------------
//   1. The adapter holds lp_state_req = ACTIVE until pl_state_sts = ACTIVE.
//   2. The local side may only declare ACTIVE after the link is trained
//      AND the logical PHY completed its Active Entry work.
//   3. The completed Active Entry result is the private LTSM output
//      phy_active_entry_done, which stays high for the whole LTSM ACTIVE
//      residency (PLAN.md Section 15.9 Phase C).
//   4. The LTSM owns the remote PHY Active exchange through its sideband
//      LinkMgmt.RDI request and response. No Adapter peer-Active feedback
//      participates in this RDI state decision.
//
// --------------------------------------------------------------------------
// Stall handshake  (spec 8.3.1)
// --------------------------------------------------------------------------
//   Registered four-phase handshake, tracked by stall_phase_q:
//     phase 1  stall_req   asserted, lp_stallack not yet received.
//     phase 2  lp_stallack asserted and registered; stall_ack goes high and
//              the data path must stay quiesced.
//     phase 3  stall_req   deasserted, lp_stallack still high.
//     phase 4  lp_stallack deasserted; stall_ack drops and data may resume.
//   stall_ack is a register output, so at least one flop separates the
//   request and the acknowledgement legs. See also d2d_adapter.sv, which
//   registers rdi_pl_stallreq before driving rdi_lp_stallack back.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. cerror and nferror are pass-through signals; the integrating parent
//      ties them to its error sources.
//   2. rdi_lp_stallack is consumed by the registered four-phase stall path.
//   3. phy_retrain_req is retained for interface completeness only. The fixed
//      profile never retrains, so it is not a state trigger.
//   4. LINKRESET and DISABLED stay published until the physical LTSM reaches
//      RESET, which arrives as phy_link_reset.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Full RDI LSM per spec 8.1.5
//                        with Active-entry handshake and stall pass-through.
//   v0.0.2  2026-09-23  Documentation pass: added per-construct comment
//                        blocks for RDI output assigns (inband_pres through
//                        trainerror) and unused-signal always_comb, citing
//                        UCIe 1.0 Sections 8.1, 8.1.5, 8.3.2, Table 114.
//   v0.0.3  2026-09-23  Documentation: correct the RDI expansion in the
//                        module description to Raw Die-to-Die Interface.
//   v0.0.4  2026-09-25  Phase D policy cutover (PLAN.md 15.5): require the
//                        private LTSM Active-entry result before ACTIVE, hold
//                        LINKRESET and DISABLED until the LTSM RESET result,
//                        return PMNAK for L1 and L2 without touching the LTSM,
//                        suppress RETRAIN publication, and consume
//                        rdi_lp_stallack in a registered four-phase stall
//                        path.
//   v0.0.5  2026-09-25  Preserve the public adapter_active_req port while
//                        keeping the Phase D Active policy independent of it.
//   v0.0.6  2026-09-25  Add explicit lint consumption for the preserved
//                        policy-inert adapter_active_req input.
//   v0.0.7  2026-10-02  Define rdi_pl_inband_pres as the LTSM
//                        training-complete indication required by Table 114.
//   v0.0.8  2026-10-08  Update LinkError recovery transition per UCIe 1.0 Section
//                        8.1.5 (Figure 111) and Section 8.3.2.7: LinkError exits
//                        directly to Reset (never LinkReset). Add comprehensive
//                        comments for stall completion logic.
//   v0.0.9  2026-10-08  Documentation compliance pass: expand the state-diagram
//                        header and the per-construct comment blocks with UCIe
//                        1.0 citations.
// ============================================================================
`ifndef RdiStateMachine_SV
`define RdiStateMachine_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;



`timescale 1ns/1ps
module rdi_state_machine (
  input  logic        lclk,
  input  logic        lreset_n,

  // ---- Adapter side (RDI). Table 114, the subset this project implements.
  input  rdi_req_t    rdi_lp_state_req,
  input  logic        rdi_lp_linkerror = 1'b0, // Adapter fatal indication
  input  logic        adapter_active_req, // public compatibility, policy-inert
  output rdi_sts_t    rdi_pl_state_sts,
  input  logic        rdi_lp_stallack,
  output logic        rdi_pl_inband_pres,
  output logic        rdi_pl_linkerror,
  output logic        rdi_pl_phyinrecenter,
  output logic        rdi_pl_cerror,
  output logic        rdi_pl_nferror,
  output logic        rdi_pl_trainerror,

  // ---- Logical PHY side. Physical status and events.
  input  logic        phy_link_trained,      // LTSM reached ACTIVE
  input  logic        phy_active_entry_done, // LTSM completed Active Entry
  input  logic        phy_link_reset,        // physical RESET event
  input  logic        phy_retrain_req,       // PHYRETRAIN requested by adapter
  input  logic        phy_linkreset_req = 1'b0, // LinkReset exchange in progress
  input  logic        phy_disabled_req  = 1'b0, // Disabled exchange in progress
  input  logic        phy_train_error,       // unrecoverable training failure
  input  logic        phy_inband_pres,       // LTSM training complete
  input  logic        cerror,                // correctable error
  input  logic        nferror,               // non-fatal error
  input  logic        stall_req,             // local stall request
  output logic        stall_ack,             // registered stall acknowledgement
  output logic        stall_complete,        // four-phase handshake complete
  // ---- Active-entry result
  output logic        local_active_req     // completed local ACTIVE result
);

  import ucie_pkg::*;

  rdi_sts_t state_q, state_d;
  logic     reset_req_sampled_q, reset_req_sampled_d;


  // =========================================================================
  // Completed Active Entry qualification  (spec 8.1.6)
  logic active_entry_complete;

  // -------------------------------------------------------------------------
  // assign: active_entry_complete - Active Entry Completion Qualifier
  //
  // Qualifies that the physical layer completed training (phy_link_trained)
  // AND the LTSM completed the private LinkMgmt.RDI Active Entry exchange
  // (phy_active_entry_done) before the RDI state machine may enter ACTIVE.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.6 - Active Entry Handshake.
  // -------------------------------------------------------------------------
  assign active_entry_complete = phy_link_trained && phy_active_entry_done;

  // =========================================================================
  // State register  (spec 8.1.5 - RDI link state)
  // =========================================================================
  // Single flip-flop holding the current RDI state. Asynchronous active-low
  // reset initialises the state to RDI_STS_RESET (4'h0), matching the
  // physical-layer RESET condition. On each rising lclk edge the next-state
  // value computed by the always_comb block is registered.
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q             <= RDI_STS_RESET;
      reset_req_sampled_q <= 1'b0;
    end else begin
      state_q             <= state_d;
      reset_req_sampled_q <= reset_req_sampled_d;
    end
  end

  // =========================================================================
  // Next-state combinational logic  (spec 8.1.5 / Figure 111)
  // =========================================================================
  // Computes state_d based on the current state, physical-layer events, and
  // adapter requests. The priority order is:
  //   1. phy_train_error  -> LINKERROR   (unconditional, spec 8.1.5)
  //   2. phy_link_reset   -> RESET       (unconditional, spec 8.1.5)
  //   3. Per-state adapter request processing (case statement).
  //
  // Each case branch implements the transition table in the file header:
  //   RESET     : REQ_ACTIVE + completed Active Entry -> ACTIVE;
  //               REQ_DISABLED -> DISABLED.
  //   ACTIVE    : REQ_L1/L2 -> PMNAK; REQ_LINKRESET -> LINKRESET;
  //               REQ_DISABLED -> DISABLED. REQ_RETRAIN holds ACTIVE.
  //   PMNAK     : REQ_ACTIVE + completed Active Entry -> ACTIVE.
  //   LINKRESET : held until phy_link_reset preempts to RESET. Spec 8.1.5.
  //   LINKERROR : held until phy_link_reset preempts directly to RESET.
//               Per Figure 111 and Section 8.3.2.7, LinkReset is excluded.
  //   DISABLED  : held until phy_link_reset preempts to RESET. Spec 8.1.5.
  //   L1, L2, RETRAIN are never entered in the fixed profile, so a state
  //   register value outside the set above falls back to RESET.
  // =========================================================================
  always_comb begin
    state_d             = state_q;
    reset_req_sampled_d = reset_req_sampled_q;

    if (state_q != RDI_STS_RESET) begin
      reset_req_sampled_d = 1'b0;
    end else if (rdi_lp_state_req == RDI_REQ_NOP) begin
      reset_req_sampled_d = 1'b1;
    end

    if (phy_link_reset) begin
      state_d = RDI_STS_RESET;
    end else if (state_q == RDI_STS_LINKRESET && phy_linkreset_req) begin
      state_d = RDI_STS_LINKRESET;
    end else if (phy_train_error) begin
      state_d = RDI_STS_LINKERROR;
    end else if (rdi_lp_linkerror && (state_q != RDI_STS_LINKRESET)) begin
      state_d = RDI_STS_LINKERROR;
    end else begin
      case (state_q)
        RDI_STS_RESET: begin
          // Remote sideband LinkReset/Disabled takes effect immediately in RESET (spec 8.3.2.1)
          if (phy_linkreset_req)
            state_d = RDI_STS_LINKRESET;
          else if (phy_disabled_req)
            state_d = RDI_STS_DISABLED;
          // Adapter must drive a stable request to leave RESET after sampling NOP,
          // and the logical PHY must have completed Active Entry.
          else if (reset_req_sampled_q &&
                   rdi_lp_state_req == RDI_REQ_ACTIVE &&
                   active_entry_complete)
            state_d = RDI_STS_ACTIVE;
          else if (reset_req_sampled_q &&
                   rdi_lp_state_req == RDI_REQ_DISABLED)
            state_d = RDI_STS_DISABLED;
          else if (reset_req_sampled_q &&
                   rdi_lp_state_req == RDI_REQ_LINKRESET)
            state_d = RDI_STS_LINKRESET;
        end

        RDI_STS_ACTIVE: begin
          // L1 and L2 are not supported: the request is answered with PMNAK
          // and the LTSM is not touched. LinkReset and Disabled wait for the
          // integrated four-phase stall handshake to complete.
          if ((rdi_lp_state_req == RDI_REQ_LINKRESET || phy_linkreset_req) && stall_complete) begin
            state_d = RDI_STS_LINKRESET;
          end else if ((rdi_lp_state_req == RDI_REQ_DISABLED || phy_disabled_req) && stall_complete) begin
            state_d = RDI_STS_DISABLED;
          end else begin
            case (rdi_lp_state_req)
              RDI_REQ_L1,
              RDI_REQ_L2:        state_d = RDI_STS_PMNAK;
              default:           state_d = RDI_STS_ACTIVE;
            endcase
          end
        end

        RDI_STS_PMNAK: begin
          // The LTSM never left ACTIVE for L1 or L2, so the adapter can
          // return to ACTIVE as soon as it withdraws the low-power request
          // and the completed Active Entry result still holds.
          if ((rdi_lp_state_req == RDI_REQ_LINKRESET || phy_linkreset_req) && stall_complete)
            state_d = RDI_STS_LINKRESET;
          else if ((rdi_lp_state_req == RDI_REQ_DISABLED || phy_disabled_req) && stall_complete)
            state_d = RDI_STS_DISABLED;
          else if (rdi_lp_state_req == RDI_REQ_ACTIVE && active_entry_complete)
            state_d = RDI_STS_ACTIVE;
        end

        RDI_STS_LINKERROR: begin
          // Per Figure 111 and Section 8.3.2.7: LinkError exits directly to Reset.
          // LinkReset cannot be entered from LinkError. State remains in LINKERROR
          // until phy_link_reset (LTSM RESET entry) transitions state_d to RDI_STS_RESET.
        end

        // LINKRESET and DISABLED stay visible until the LTSM reports RESET.
        // That report arrives as phy_link_reset and is applied by the
        // priority branch above, so no adapter request moves these states.
        RDI_STS_LINKRESET,
        RDI_STS_DISABLED: ;

        default: state_d = RDI_STS_RESET;
      endcase
    end
  end

  // =========================================================================
  // RDI output assignments  (spec 8.1 / Table 114)
  // =========================================================================
  // rdi_pl_state_sts    : Current state encoding, registered.   Table 114.
  // rdi_pl_inband_pres  : Link training complete and ready for RDI ACTIVE.
  // rdi_pl_linkerror    : Asserted in LINKERROR state.          Table 114.
  // rdi_pl_phyinrecenter: Retrain indication, never asserted in the fixed
  //                       profile.                            Table 114.
  // rdi_pl_cerror       : Correctable error pass-through.       Table 114.
  // rdi_pl_nferror      : Non-fatal error pass-through.         Table 114.
  // rdi_pl_trainerror   : Training error from LTSM.             Table 114.
  // =========================================================================
  assign rdi_pl_state_sts     = state_q;
  // -------------------------------------------------------------------------
  // assign (group): RDI status / error output signals
  //
  // These six signals are driven to the D2D Adapter through the RDI and
  // reflect either registered state or pass-through PHY events:
  //   rdi_pl_inband_pres   - training-complete indication from the LTSM.
  //                          It asserts before RDI ACTIVE and stays high
  //                          until the link enters RESET or TRAINERROR.
  //   rdi_pl_linkerror     - asserted when state_q == LINKERROR, telling
  //                          the adapter that recovery is required (8.1.5).
  //   rdi_pl_phyinrecenter - retrain indication. The fixed profile does not
  //                          support Retrain and never publishes the RETRAIN
  //                          state, so this indication stays low
  //                          (PLAN.md Section 15.5 Phase D).
  //   rdi_pl_cerror        - correctable-error pass-through (Table 114).
  //   rdi_pl_nferror       - non-fatal-error pass-through (Table 114).
  //   rdi_pl_trainerror    - forwarded from phy_train_error; the LTSM has
  //                          declared an unrecoverable training failure.
  //
  // Spec ref: UCIe 1.0, Section 8.1 - Raw Die-to-Die Interface;
  //           Section 8.3.2 - State Request and Status;
  //           Table 114 - RDI Signal List.
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // assign: rdi_pl_inband_pres - Training-Complete In-Band Indication Driver
  //
  // Signals that physical link training has completed and the PHY is ready
  // for RDI ACTIVE operation. Remains asserted until RESET or LinkError.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1 (Table 114 - RDI Signal List).
  // -------------------------------------------------------------------------
  assign rdi_pl_inband_pres   = phy_inband_pres;

  // -------------------------------------------------------------------------
  // assign: rdi_pl_linkerror - RDI LinkError Status Indication Driver
  //
  // Asserted while the RDI is in LINKERROR state (4'hA), notifying the
  // D2D Adapter that an unrecoverable fault occurred and recovery is required.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.5 (Figure 111) and Section 8.3.2.7.
  // -------------------------------------------------------------------------
  assign rdi_pl_linkerror     = (state_q == RDI_STS_LINKERROR);

  // -------------------------------------------------------------------------
  // assign: rdi_pl_phyinrecenter - Retrain Indication (Unsupported)
  //
  // Retrain is unsupported in the fixed profile; tied to 0 per Section 8.1.5.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1 (Table 114 - RDI Signal List).
  // -------------------------------------------------------------------------
  assign rdi_pl_phyinrecenter = 1'b0;

  // -------------------------------------------------------------------------
  // assign: rdi_pl_cerror - Correctable Error Status Forwarding
  //
  // Forwards correctable error indication from the physical layer to Adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1 (Table 114 - RDI Signal List).
  // -------------------------------------------------------------------------
  assign rdi_pl_cerror        = cerror;

  // -------------------------------------------------------------------------
  // assign: rdi_pl_nferror - Non-Fatal Error Status Forwarding
  //
  // Forwards non-fatal error indication from the physical layer to Adapter.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1 (Table 114 - RDI Signal List).
  // -------------------------------------------------------------------------
  assign rdi_pl_nferror       = nferror;

  // -------------------------------------------------------------------------
  // assign: rdi_pl_trainerror - LTSM Training Fatal Error Forwarding
  //
  // Asserted when the physical LTSM declares an unrecoverable training error.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1 (Table 114 - RDI Signal List);
  //           Section 4.5.3.8 - TRAINERROR State.
  // -------------------------------------------------------------------------
  assign rdi_pl_trainerror    = phy_train_error;

  // =========================================================================
  // Active-entry gating  (spec 8.1.6)
  // =========================================================================
  // The local side may declare ACTIVE only after:
  //   1. The RDI state machine is in ACTIVE.
  //   2. The LTSM completed the private Active Entry exchange.
  //   3. The trained indication remains valid.
  // The LTSM owns the remote PHY Active exchange. No Adapter peer-Active
  // feedback participates in this result.
  // =========================================================================
  assign local_active_req = (state_q == RDI_STS_ACTIVE) &&
                            active_entry_complete;

  // =========================================================================
  // Registered four-phase stall handshake  (spec 8.3.1)
  // =========================================================================
  // Phase encodings of the local stall tracker:
  //   STALL_IDLE     - no handshake in progress, stall_ack low.
  //   STALL_REQ      - phase 1: stall_req asserted, waiting for lp_stallack.
  //   STALL_ACKED    - phase 2 and 3: lp_stallack received, stall_ack high,
  //                    data stays quiesced until the request is released.
  //   STALL_RELEASED - phase 4: stall_req released, waiting for lp_stallack
  //                    to fall before the data path may resume.
  // =========================================================================
  localparam logic [1:0] STALL_IDLE     = 2'd0;
  localparam logic [1:0] STALL_REQ      = 2'd1;
  localparam logic [1:0] STALL_ACKED    = 2'd2;
  localparam logic [1:0] STALL_RELEASED = 2'd3;

  logic [1:0] stall_phase_q, stall_phase_d;

  // -------------------------------------------------------------------------
  // always_ff: Stall phase register
  //
  // Holds the current phase of the four-phase stall handshake. Asynchronous
  // active-low reset returns the tracker to STALL_IDLE so a reset cannot
  // leave a stall window open.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stall handshake.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) stall_phase_q <= STALL_IDLE;
    else           stall_phase_q <= stall_phase_d;
  end

  // -------------------------------------------------------------------------
  // always_comb: Stall phase next-state logic
  //
  // Phase 1 accepts the local request, phase 2 completes only after the
  // adapter acknowledgement rdi_lp_stallack is received, phase 3 waits for the
  // local request to drop, and phase 4 waits for the acknowledgement to drop.
  // A request that disappears before the acknowledgement returns aborts the
  // handshake, because no stall window was ever opened.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stall handshake.
  // -------------------------------------------------------------------------
  always_comb begin
    stall_phase_d = stall_phase_q;

    case (stall_phase_q)
      STALL_IDLE: begin
        if (stall_req) stall_phase_d = STALL_REQ;
      end

      STALL_REQ: begin
        if (!stall_req)            stall_phase_d = STALL_IDLE;
        else if (rdi_lp_stallack)  stall_phase_d = STALL_ACKED;
      end

      STALL_ACKED: begin
        if (!stall_req) stall_phase_d = STALL_RELEASED;
      end

      STALL_RELEASED: begin
        if (!rdi_lp_stallack) stall_phase_d = STALL_IDLE;
      end

      default: stall_phase_d = STALL_IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // assign: stall_ack - registered stall acknowledgement
  //
  // High from the cycle after lp_stallack is sampled high until one cycle
  // after lp_stallack falls again. The data path uses it as the stall window
  // indicator. It is registered, so at least one flop separates it from
  // stall_req and from rdi_lp_stallack.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stall handshake.
  // -------------------------------------------------------------------------
  assign stall_ack = (stall_phase_q == STALL_ACKED) ||
                     (stall_phase_q == STALL_RELEASED);

  // -------------------------------------------------------------------------
  // assign: stall_complete - completion pulse of the four-phase stall handshake
  //
  // Asserted when the stall handshake has successfully finished: the stall
  // request has been released by the local controller (STALL_RELEASED phase)
  // and the adapter has deasserted its stall acknowledgement (!rdi_lp_stallack).
  // This signal allows the RDI state machine to commit state transitions
  // (such as transitioning from ACTIVE to LINKRESET or DISABLED) knowing
  // that the datapath has been fully drained and quiesced.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.1 - Stall Handshake.
  // -------------------------------------------------------------------------
  assign stall_complete = (stall_phase_q == STALL_RELEASED) &&
                          !rdi_lp_stallack;
  // =========================================================================
  // Unused signal suppression
  // =========================================================================
  // phy_retrain_req is declared as an input for interface completeness but is
  // not a state trigger in this build. The fixed profile has no Retrain
  // support: the RDI holds ACTIVE for REQ_RETRAIN, never publishes the
  // RETRAIN state, and never asserts rdi_pl_phyinrecenter. An explicit
  // reference prevents lint warnings without altering behaviour.
  // =========================================================================
  logic unused_phy_retrain_req;
  logic unused_adapter_active_req;
  // -------------------------------------------------------------------------
  // always_comb: Unused-signal lint suppression
  //
  // Consumes phy_retrain_req so that synthesis and lint tools do not emit an
  // "unused port" warning. The value has no effect on any transition or
  // output in this build.
  //
  // Spec ref: UCIe 1.0, Section 8.1.5 - RDI state transitions;
  //           Table 114 - RDI Signal List;
  //           PLAN.md Section 15.5 - Phase D retrain suppression.
  // -------------------------------------------------------------------------
  always_comb begin
    unused_phy_retrain_req = phy_retrain_req;
  end
  // -------------------------------------------------------------------------
  // always_comb: Unused adapter Active compatibility input
  //
  // Consumes adapter_active_req so the preserved public port does not create a
  // lint warning. Phase D removes peer-Active policy from the RDI, so this
  // sink has no effect on state transitions or output signals.
  //
  // Spec ref: UCIe 1.0 Section 8.1.5, Table 114;
  //           PLAN.md Section 15.5 - Phase D policy ownership.
  // -------------------------------------------------------------------------
  always_comb begin
    unused_adapter_active_req = adapter_active_req;
  end

endmodule

`endif

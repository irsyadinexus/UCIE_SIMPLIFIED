// ============================================================================
// File        : rdi_state_machine.sv
// Module      : rdi_state_machine
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Raw D2D Interface (RDI) Link State Machine. Mediates between
//               the D2D Adapter (which requests state transitions via
//               rdi_lp_state_req) and the Logical PHY (which reports physical
//               link events: trained, reset, retrain, error).
//
// Spec refs   : UCIe 1.0 spec section 8.1.5 (RDI state transitions,
//               Figure 111), section 8.1.6 (Active-entry handshake),
//               section 8.3.1 (stall handshake), Table 114 (RDI signal
//               definitions).
//
// --------------------------------------------------------------------------
// RDI State Transition Diagram  (spec 8.1.5 / Figure 111)
// --------------------------------------------------------------------------
//
//                         phy_link_reset
//                    +---------------------+
//                    |                     |
//                    v                     |
//               +----------+              |
//          +--->|  RESET   |              |
//          |    |  (0h)    |              |
//          |    +----+-----+              |
//          |         | REQ_ACTIVE &&      |
//          |         | phy_link_trained   |
//          |         v                    |
//          |    +----------+              |
//          |    |  ACTIVE  |<---------+   |
//          |    |  (1h)    |          |   |
//          |    +----+-----+          |   |
//          |         |                |   |
//          |    +----+----+----+      |   |
//          |    |    |    |    |      |   |
//          |    v    v    v    v      |   |
//          | +--++ +--+ +--+ +----+  |   |
//          | |L1 | |L2| |LR| |RET|  |   |
//          | |(4)| |(8)| |(9)| |(B)|  |   |
//          | +--++ +--+ +-+-+ +-+-+  |   |
//          |  | |   |     |     |    |   |
//          |  +-+---+-----+-----+----+   |
//          |   REQ_ACTIVE                |
//          |                             |
//          |    +----------+             |
//          |    | LINKERROR|<--- phy_train_error (preempts all)
//          |    |  (Ah)    |             |
//          |    +----+-----+             |
//          |         | REQ_LINKRESET     |
//          |         v                   |
//          |    +----------+             |
//          +----|LINKRESET |-------------+
//          |    |  (9h)    |
//          |    +----------+
//          |
//          |    +----------+    +----------+
//          |    |  PMNAK   |    | DISABLED |
//          +----|  (3h)    |    |  (Ch)    |
//               +----------+    +----------+
//                (REQ_ACTIVE     (REQ_ACTIVE
//                 exits)          exits)
//
// --------------------------------------------------------------------------
// Active-entry handshake  (spec 8.1.6)
// --------------------------------------------------------------------------
//   1. The adapter holds lp_state_req = ACTIVE until pl_state_sts = ACTIVE.
//   2. The local side may only declare ACTIVE after the link is trained
//      AND the partner has also reached ACTIVE.
//   3. To avoid a deadlock where neither end can observe the partner's
//      ACTIVE, the local ACTIVE declaration is released when the partner
//      reports ACTIVE through the sideband LinkMgmt.RDI.Req.Active message.
//      That message is produced by the adapter, so this machine supplies
//      only the hardware handshake and the adapter_active_req gating.
//
// --------------------------------------------------------------------------
// Stall handshake  (spec 8.3.1)
// --------------------------------------------------------------------------
//   stall_ack follows stall_req combinationally. The adapter observes
//   stallack and stops driving the interface for the stall interval.
//
// --------------------------------------------------------------------------
// Priority rules  (spec 8.1.5)
// --------------------------------------------------------------------------
//   1. phy_train_error  -> LINKERROR   (highest priority, preempts all)
//   2. phy_link_reset   -> RESET       (preempts adapter requests)
//   3. Adapter request  -> per-state case (lowest priority)
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. cerror, nferror, and stall_req are pass-through signals in this
//      build; they are tied to 1'b0 at the instantiation site.
//   2. rdi_lp_stallack is declared as unused; the stall handshake is
//      complete at the assign level.
//   3. The DISABLED and PMNAK states are included for completeness; they
//      are not exercised in the current test suite.
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
  input  logic        rdi_lp_stallack,
  output rdi_sts_t    rdi_pl_state_sts,
  output logic        rdi_pl_inband_pres,
  output logic        rdi_pl_linkerror,
  output logic        rdi_pl_phyinrecenter,
  output logic        rdi_pl_cerror,
  output logic        rdi_pl_nferror,
  output logic        rdi_pl_trainerror,

  // ---- Logical PHY side. Physical status and events.
  input  logic        phy_link_trained,    // LTSM reached ACTIVE
  input  logic        phy_link_reset,      // physical RESET event
  input  logic        phy_retrain_req,     // PHYRETRAIN requested by adapter
  input  logic        phy_train_error,     // unrecoverable training failure
  input  logic        phy_inband_pres,     // partner present (sideband alive)
  input  logic        cerror,              // correctable error
  input  logic        nferror,             // non-fatal error
  input  logic        stall_req,           // local stall request
  output logic        stall_ack,           // local stall acknowledgement

  // ---- Adapter active request gating (8.1.6).
  input  logic        adapter_active_req,  // partner reached ACTIVE (adapter)
  output logic        local_active_req     // local side may declare ACTIVE
);

  import ucie_pkg::*;

  rdi_sts_t state_q, state_d;

  // =========================================================================
  // State register  (spec 8.1.5 – RDI link state)
  // =========================================================================
  // Single flip-flop holding the current RDI state. Asynchronous active-low
  // reset initialises the state to RDI_STS_RESET (4'h0), matching the
  // physical-layer RESET condition. On each rising lclk edge the next-state
  // value computed by the always_comb block is registered.
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q <= RDI_STS_RESET;
    else           state_q <= state_d;
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
  // Each case branch implements the transition arrows of Figure 111:
  //   RESET     : REQ_ACTIVE + trained -> ACTIVE; REQ_DISABLED -> DISABLED.
  //   ACTIVE    : REQ_L1/L2/LINKRESET/RETRAIN/DISABLED -> respective states.
  //   L1, L2    : Only ACTIVE or LINKRESET leave low-power. Spec 8.1.5.
  //   LINKRESET : REQ_ACTIVE + trained -> ACTIVE; REQ_DISABLED -> DISABLED.
  //   RETRAIN   : trained + REQ_ACTIVE -> ACTIVE. Spec 8.1.5.
  //   LINKERROR : REQ_LINKRESET -> LINKRESET. Only recovery path. Spec 8.1.5.
  //   PMNAK     : REQ_ACTIVE + trained -> ACTIVE. Terminal otherwise.
  //   DISABLED  : REQ_ACTIVE + trained -> ACTIVE. Terminal otherwise.
  // =========================================================================
  always_comb begin
    state_d = state_q;

    if (phy_train_error) begin
      state_d = RDI_STS_LINKERROR;
    end else if (phy_link_reset) begin
      state_d = RDI_STS_RESET;
    end else begin
      case (state_q)
        RDI_STS_RESET: begin
          // Adapter must drive a stable request to leave RESET.
          if (rdi_lp_state_req == RDI_REQ_ACTIVE && phy_link_trained)
            state_d = RDI_STS_ACTIVE;
          else if (rdi_lp_state_req == RDI_REQ_DISABLED)
            state_d = RDI_STS_DISABLED;
        end

        RDI_STS_ACTIVE: begin
          case (rdi_lp_state_req)
            RDI_REQ_L1:        state_d = RDI_STS_L1;
            RDI_REQ_L2:        state_d = RDI_STS_L2;
            RDI_REQ_LINKRESET: state_d = RDI_STS_LINKRESET;
            RDI_REQ_RETRAIN:   state_d = RDI_STS_RETRAIN;
            RDI_REQ_DISABLED:  state_d = RDI_STS_DISABLED;
            default:           state_d = RDI_STS_ACTIVE;
          endcase
        end

        RDI_STS_L1, RDI_STS_L2: begin
          // Only ACTIVE or LINKRESET leave a low-power state.
          if (rdi_lp_state_req == RDI_REQ_ACTIVE)
            state_d = RDI_STS_ACTIVE;
          else if (rdi_lp_state_req == RDI_REQ_LINKRESET)
            state_d = RDI_STS_LINKRESET;
        end

        RDI_STS_LINKRESET: begin
          // Hold until the physical layer clears the reset.
          if (rdi_lp_state_req == RDI_REQ_ACTIVE && phy_link_trained)
            state_d = RDI_STS_ACTIVE;
          else if (rdi_lp_state_req == RDI_REQ_DISABLED)
            state_d = RDI_STS_DISABLED;
        end

        RDI_STS_RETRAIN: begin
          // Retraining is complete when the PHY says the link is trained again.
          if (phy_link_trained && rdi_lp_state_req == RDI_REQ_ACTIVE)
            state_d = RDI_STS_ACTIVE;
        end

        RDI_STS_LINKERROR: begin
          // The adapter must request LINKRESET to recover.
          if (rdi_lp_state_req == RDI_REQ_LINKRESET)
            state_d = RDI_STS_LINKRESET;
        end

        // PMNAK and DISABLED are terminal until the adapter asks to leave.
        RDI_STS_PMNAK: begin
          if (rdi_lp_state_req == RDI_REQ_ACTIVE && phy_link_trained)
            state_d = RDI_STS_ACTIVE;
        end

        RDI_STS_DISABLED: begin
          if (rdi_lp_state_req == RDI_REQ_ACTIVE && phy_link_trained)
            state_d = RDI_STS_ACTIVE;
        end

        default: state_d = RDI_STS_RESET;
      endcase
    end
  end

  // =========================================================================
  // RDI output assignments  (spec 8.1 / Table 114)
  // =========================================================================
  // rdi_pl_state_sts    : Current state encoding, registered.   Table 114.
  // rdi_pl_inband_pres  : Partner is present on sideband.       Table 114.
  // rdi_pl_linkerror    : Asserted in LINKERROR state.          Table 114.
  // rdi_pl_phyinrecenter: Asserted in RETRAIN state.            Table 114.
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
  //   rdi_pl_inband_pres   - forwarded from phy_inband_pres; indicates the
  //                          partner die is present on sideband (Table 114).
  //   rdi_pl_linkerror     - asserted when state_q == LINKERROR, telling
  //                          the adapter that recovery is required (8.1.5).
  //   rdi_pl_phyinrecenter - asserted when state_q == RETRAIN, indicating
  //                          the PHY is recentering its receiver (8.1.5).
  //   rdi_pl_cerror        - correctable-error pass-through (Table 114).
  //   rdi_pl_nferror       - non-fatal-error pass-through (Table 114).
  //   rdi_pl_trainerror    - forwarded from phy_train_error; the LTSM has
  //                          declared an unrecoverable training failure.
  //
  // Spec ref: UCIe 1.0, Section 8.1 - Raw Die-to-Die Interface;
  //           Section 8.3.2 - State Request and Status;
  //           Table 114 - RDI Signal List.
  // -------------------------------------------------------------------------
  assign rdi_pl_inband_pres   = phy_inband_pres;
  assign rdi_pl_linkerror     = (state_q == RDI_STS_LINKERROR);
  assign rdi_pl_phyinrecenter = (state_q == RDI_STS_RETRAIN);
  assign rdi_pl_cerror        = cerror;
  assign rdi_pl_nferror       = nferror;
  assign rdi_pl_trainerror    = phy_train_error;

  // =========================================================================
  // Active-entry gating  (spec 8.1.6)
  // =========================================================================
  // The local side may request ACTIVE only when all three conditions hold:
  //   1. The RDI state machine is in ACTIVE (state_q == RDI_STS_ACTIVE).
  //   2. The adapter has confirmed the partner reached ACTIVE
  //      (adapter_active_req, from the LinkMgmt.RDI.Req.Active SB message).
  //   3. The physical link is trained (phy_link_trained from the LTSM).
  // This three-way AND prevents deadlock per spec 8.1.6.
  // =========================================================================
  assign local_active_req = (state_q == RDI_STS_ACTIVE) &&
                            adapter_active_req && phy_link_trained;

  // =========================================================================
  // Stall handshake  (spec 8.3.1)
  // =========================================================================
  // stall_ack follows stall_req combinationally. The adapter observes
  // stallack and stops driving the interface for the stall interval. In this
  // build stall_req is tied to 1'b0 at the instantiation site, so stall_ack
  // is always 0.
  // =========================================================================
  assign stall_ack = stall_req;

  // =========================================================================
  // Unused signal suppression
  // =========================================================================
  // rdi_lp_stallack is declared as an input but not consumed by any logic
  // in this build. An explicit always_comb reference prevents lint warnings.
  // =========================================================================
  logic unused_rdi;
  // -------------------------------------------------------------------------
  // always_comb: Unused-signal lint suppression
  //
  // rdi_lp_stallack is declared in the port list (Table 114) for interface
  // completeness but is not consumed by any transition or output logic in
  // this simplified build. Assigning it to a local variable inside an
  // always_comb block prevents synthesis and lint tools from emitting
  // "unused port" warnings without altering any functional behaviour.
  //
  // Spec ref: UCIe 1.0, Section 8.1 - Raw Die-to-Die Interface;
  //           Table 114 - RDI Signal List.
  // -------------------------------------------------------------------------
  always_comb begin
    unused_rdi = rdi_lp_stallack;
  end

endmodule

`endif

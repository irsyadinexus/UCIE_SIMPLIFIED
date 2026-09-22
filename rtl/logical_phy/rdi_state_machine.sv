// UCIe 1.0 Simplified Endpoint - RDI link state machine
// Spec 8.1.5 (state transitions) and 8.1.6 (Active entry handshake).
//
// The RDI LSM sits between the D2D Adapter and the Logical PHY. The adapter
// requests a state with rdi_lp_state_req; the logical PHY acknowledges with
// rdi_pl_state_sts. RESET/RETRAIN are entered by the physical layer itself.
//
// Active-entry handshake (8.1.6):
//   1. lp_state_req = ACTIVE is held until pl_state_sts = ACTIVE.
//   2. The local side may only declare ACTIVE after the link is trained and
//      the partner has also reached ACTIVE.
// To avoid a deadlock where neither end can observe the partner's ACTIVE, the
// local ACTIVE declaration is released when the partner reports ACTIVE
// through the sideband LinkMgmt.RDI.Req.Active message. That message is
// produced by the adapter, so this machine only supplies the hardware
// handshake and the `adapter_active_req` gating.
`ifndef RdiStateMachine_SV
`define RdiStateMachine_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;



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

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q <= RDI_STS_RESET;
    else           state_q <= state_d;
  end

  // --------------------------------------------------------- next state
  // Physical RESET and TRAINERROR preempt every adapter request.
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

  // ------------------------------------------------------- outputs
  assign rdi_pl_state_sts     = state_q;
  assign rdi_pl_inband_pres   = phy_inband_pres;
  assign rdi_pl_linkerror     = (state_q == RDI_STS_LINKERROR);
  assign rdi_pl_phyinrecenter = (state_q == RDI_STS_RETRAIN);
  assign rdi_pl_cerror        = cerror;
  assign rdi_pl_nferror       = nferror;
  assign rdi_pl_trainerror    = phy_train_error;

  // 8.1.6: the local side may request ACTIVE only while the adapter asks for
  // ACTIVE and the link is trained. The partner's ACTIVE is supplied by the
  // adapter through the LinkMgmt.RDI.Req.Active sideband message.
  assign local_active_req = (state_q == RDI_STS_ACTIVE) &&
                            adapter_active_req && phy_link_trained;

  // Stall handshake 8.3.1: ack follows the request. The adapter observes
  // stallack and stops driving the interface for the stall interval.
  assign stall_ack = stall_req;

  // Unused for now; kept for completeness of the RDI port set.
  logic unused_rdi;
  always_comb begin
    unused_rdi = rdi_lp_stallack;
  end

endmodule

`endif

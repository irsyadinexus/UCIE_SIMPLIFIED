// ============================================================================
// Module    : fdi_state_machine
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/fdi_state_machine.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 8.2 - Flit-Aware Die-to-Die Interface
//                                         (FDI)
//   UCIe 1.0 Specification, Section 8.2.6 - Rx Active Handshake
//   UCIe 1.0 Specification, Section 8.1.6 Step 6 - Active Entry Gating
//   UCIe 1.0 Specification, Table 115 - FDI Signal List
//   UCIe 1.0 Specification, Table 114 - RDI Signal List (state encodings)
//
// DESCRIPTION
//   FDI Link Sub-state Machine (FDI LSM). This module sits between the
//   Protocol Layer (above, Table 115 signals) and the RDI status signals
//   from the Logical PHY (below, Table 114). Its responsibilities:
//
//     1. Track the FDI link state in a registered state variable (fdi_q)
//        that mirrors the RDI state transitions reported by rdi_state_sts.
//        The FDI state space reuses the same 4-bit encoding as the RDI:
//          F_RESET(0), F_ACTIVE(1), F_PMNAK(3), F_L1(4), F_L2(8),
//          F_LINKRESET(9), F_LINKERROR(A), F_RETRAIN(B), F_DISABLED(C).
//
//     2. Implement the four-way Active handshake (spec 8.2.6):
//        - The Protocol Layer asserts lp_state_req == FDI_REQ_ACTIVE.
//        - The Protocol Layer asserts lp_rx_active_sts.
//        - The RDI status reaches RDI_STS_ACTIVE.
//        - Only then does the FDI report F_ACTIVE on pl_state_sts.
//        pl_rx_active_req is asserted as soon as rdi_state_sts == ACTIVE,
//        NOT gated on F_ACTIVE, to avoid a deadlock where the Protocol
//        Layer waits for pl_rx_active_req before asserting lp_rx_active_sts.
//
//     3. Forward the Protocol Layer's state request to the RDI via
//        fdi_state_req_out, after applying the Active gating. Non-Active
//        requests (LinkReset, Retrain, L1, L2, Disabled) pass through
//        unconditionally.
//
//     4. Drive all FDI status and indication outputs to the Protocol Layer:
//        pl_state_sts, pl_inband_pres, pl_error, pl_cerror, pl_nferror,
//        pl_trainerror, pl_phyinrecenter, pl_protocol, pl_protocol_flitfmt,
//        pl_rx_active_req, pl_stream.
//
//   This module operates in Streaming-only mode:
//     pl_protocol       = 111b (PROTO_STREAMING)
//     pl_protocol_flitfmt = 0001b (FMT_RAW, Format 1 Raw Mode)
//
//   The LTSM (Link Training and Status Machine) is NOT in this module;
//   it lives in logical_phy. This module observes LTSM results only
//   through the RDI status signals.
//
// STATE TRANSITION TABLE (spec 8.2, simplified)
//   Current State  | Condition on rdi_state_sts       | Next State
//   ---------------+----------------------------------+------------
//   F_RESET        | LINKERROR                        | F_LINKERROR
//   F_RESET        | DISABLED                         | F_DISABLED
//   F_RESET        | ACTIVE && lp_rx_active_sts       | F_ACTIVE
//   F_ACTIVE       | PMNAK                            | F_PMNAK
//   F_ACTIVE       | LINKRESET                        | F_LINKRESET
//   F_ACTIVE       | RETRAIN                          | F_RETRAIN
//   F_ACTIVE       | L1                               | F_L1
//   F_ACTIVE       | L2                               | F_L2
//   F_ACTIVE       | LINKERROR                        | F_LINKERROR
//   F_ACTIVE       | DISABLED                         | F_DISABLED
//   F_ACTIVE       | != ACTIVE (catch-all)            | F_RESET
//   F_PMNAK        | ACTIVE                           | F_ACTIVE
//   F_PMNAK        | LINKRESET / LINKERROR / DISABLED | respective
//   F_L1           | RETRAIN / LINKRESET / ACTIVE /   | respective
//                  | LINKERROR                        |
//   F_L2           | RETRAIN / LINKRESET / LINKERROR  | respective
//   F_LINKRESET    | RESET / ACTIVE / LINKERROR       | respective
//   F_RETRAIN      | RESET / ACTIVE / LINKERROR       | respective
//   F_LINKERROR    | RESET / LINKRESET                | respective
//   F_DISABLED     | RESET / LINKRESET                | respective
//
// PORTS
//   See Table 115 for the FDI port definitions. RDI-side inputs are named
//   rdi_* and carry the Logical PHY's status. Adapter-internal ports
//   (adapter_active_req, adapter_state_req_vld, adapter_state_req,
//   fdi_active_req, fdi_state_req_out, fdi_state_req_vld) connect to
//   d2d_adapter and adapter_sb_if for the Active handshake coordination.
//
// CLOCK / RESET
//   lclk      - Main link clock (500 MHz).
//   lreset_n  - Active-low asynchronous reset.
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//   v0.0.2  2026-09-22  Update lclk documentation to 500 MHz.
//   v0.0.3  2026-09-23  Documentation: fix the Section 8.2 title in the header
//                        ("Fdie-to-Die" -> "Flit-Aware Die-to-Die Interface").
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef FdiStateMachine_SV
`define FdiStateMachine_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module fdi_state_machine (
  input  logic        lclk,
  input  logic        lreset_n,

  // Protocol Layer side (FDI, Table 115)
  input  logic [3:0]  lp_state_req,
  output logic [3:0]  pl_state_sts,
  output logic        pl_inband_pres,
  output logic        pl_error,
  output logic        pl_cerror,
  output logic        pl_nferror,
  output logic        pl_trainerror,
  output logic        pl_phyinrecenter,
  output logic [2:0]  pl_protocol,
  output logic [3:0]  pl_protocol_flitfmt,
  output logic        pl_rx_active_req,
  input  logic        lp_rx_active_sts,
  input  logic [7:0]  lp_stream,
  output logic [7:0]  pl_stream,

  // RDI side: the adapter observes the PHY result.
  input  logic [3:0]  rdi_state_sts,
  input  logic        rdi_inband_pres,
  input  logic        rdi_trainerror,
  input  logic        rdi_phyinrecenter,
  input  logic        rdi_cerror,
  input  logic        rdi_nferror,

  // Adapter-internal sideband link management (to/from adapter_sb_if)
  input  logic        adapter_active_req,     // partner Adapter wants Active
  input  logic        adapter_state_req_vld,
  input  logic [3:0]  adapter_state_req,
  output logic        fdi_active_req,
  output logic [3:0]  fdi_state_req_out,
  output logic        fdi_state_req_vld
);

  import ucie_pkg::*;

  // --------------------------------------------------------------------------
  // FDI LSM State Encoding
  // --------------------------------------------------------------------------
  // The FDI state encodings mirror the RDI state space (Table 114/115) so that
  // a simple equality comparison between the FDI and RDI states is meaningful.
  // Each state is a 4-bit value matching the pl_state_sts / lp_state_req
  // encoding defined in the UCIe 1.0 specification.
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_RESET    = 4'h0,
    F_ACTIVE   = 4'h1,
    F_PMNAK    = 4'h3,
    F_L1       = 4'h4,
    F_L2       = 4'h8,
    F_LINKRESET= 4'h9,
    F_LINKERROR= 4'hA,
    F_RETRAIN  = 4'hB,
    F_DISABLED = 4'hC
  } fdi_state_t;

  fdi_state_t fdi_q, fdi_d;
  logic       inband_pres_q;
  logic       local_active_req;   // Protocol Layer asked for Active
  logic       pl_inband_pres_d;

  // -------------------------------------------------------------------------
  // always_ff: FDI State Register and In-Band Presence Register
  //
  // On every rising edge of lclk (or asynchronous reset), this block
  // advances the FDI LSM state from fdi_d (combinationally computed in the
  // "transitions" always_comb below) into the registered state fdi_q.
  // Simultaneously, the in-band presence flag inband_pres_q is updated
  // from pl_inband_pres_d (computed in its own always_comb).
  //
  // On reset, the FDI starts in F_RESET with in-band presence deasserted,
  // per spec 8.2 initial conditions.
  //
  // Spec ref: UCIe 1.0, Section 8.2 - FDI initial state.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      fdi_q         <= F_RESET;
      inband_pres_q <= 1'b0;
    end else begin
      fdi_q         <= fdi_d;
      inband_pres_q <= pl_inband_pres_d;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: Protocol Layer Active Request Latch
  //
  // Captures and holds the fact that the Protocol Layer has requested Active
  // and has acknowledged the Rx-active handshake (lp_rx_active_sts == 1).
  // The latch sets when both conditions are true and clears when the FDI
  // enters F_RESET or F_LINKRESET, which invalidates any prior Active
  // agreement.
  //
  // This registered flag is used in the outputs always_comb to gate the
  // fdi_state_req_vld for Active: the Active request is only forwarded to
  // the RDI when both local_active_req (this latch) AND adapter_active_req
  // (partner's request, from adapter_sb_if) are asserted.
  //
  // Spec ref: UCIe 1.0, Section 8.1.6 step 6 (four-way Active handshake).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      local_active_req <= 1'b0;
    end else if (lp_state_req == FDI_REQ_ACTIVE && lp_rx_active_sts) begin
      local_active_req <= 1'b1;
    end else if (fdi_q == F_RESET || fdi_q == F_LINKRESET) begin
      local_active_req <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // always_comb: In-Band Presence Next-State Logic
  //
  // In-band presence (pl_inband_pres) is a sticky-high flag per spec 8.2:
  //   - It sets to 1 when the RDI reports rdi_inband_pres (the PHY has
  //     detected in-band signalling from the remote die).
  //   - It clears to 0 when the FDI enters F_RESET, F_LINKERROR, or
  //     F_DISABLED (these states invalidate any prior presence detection).
  //   - Otherwise, it holds its current registered value (sticky).
  //
  // The computed pl_inband_pres_d is registered into inband_pres_q in the
  // state register always_ff above.
  //
  // Spec ref: UCIe 1.0, Section 8.2 - pl_inband_pres behaviour.
  // -------------------------------------------------------------------------
  always_comb begin
    if (rdi_inband_pres)               pl_inband_pres_d = 1'b1;
    else if (fdi_q == F_RESET ||
             fdi_q == F_LINKERROR ||
             fdi_q == F_DISABLED)      pl_inband_pres_d = 1'b0;
    else                               pl_inband_pres_d = inband_pres_q;
  end

  // -------------------------------------------------------------------------
  // always_comb: FDI Output Drivers and State-Request Forwarding
  //
  // Single combinational driver for every FDI output port, so there are no
  // multi-driver conflicts and the RDI -> FDI mapping is explicit:
  //
  //   pl_protocol=PROTO_STREAMING  pl_protocol_flitfmt=FMT_RAW (Format 1)
  //   pl_stream=lp_stream          pl_error=1'b0 (not self-generated)
  //   pl_cerror/pl_nferror/pl_trainerror/pl_phyinrecenter = forwarded RDI
  //   pl_state_sts=fdi_q           pl_inband_pres=inband_pres_q (sticky)
  //   pl_rx_active_req = (rdi_state_sts == ACTIVE); per spec 8.2.6, asserted
  //     as the first arm of the four-way handshake and NOT gated on F_ACTIVE
  //     to avoid deadlock.
  //
  // State-request forwarding: FDI_REQ_ACTIVE sets fdi_active_req and forwards
  // only when local_active_req AND adapter_active_req are both asserted
  // (spec 8.1.6 step 6); LinkReset/Retrain/Disabled/L1/L2 pass straight
  // through with vld=1; default drives RDI_REQ_NOP.
  // Spec ref: 8.2 (FDI), 8.2.6 (Rx Active), 8.1.6 step 6, Table 115.
  // -------------------------------------------------------------------------
  always_comb begin
    pl_protocol        = PROTO_STREAMING;
    pl_protocol_flitfmt = FMT_RAW;
    pl_stream          = lp_stream;
    pl_error           = 1'b0;
    pl_cerror          = rdi_cerror;
    pl_nferror         = rdi_nferror;
    pl_trainerror      = rdi_trainerror;
    pl_phyinrecenter   = rdi_phyinrecenter;
    pl_state_sts       = fdi_q;
    pl_inband_pres     = inband_pres_q;
    pl_rx_active_req   = (rdi_state_sts == RDI_STS_ACTIVE);

    // Request forwarding to the RDI state machine.
    fdi_active_req     = 1'b0;
    fdi_state_req_out  = lp_state_req;
    fdi_state_req_vld  = 1'b0;

    case (lp_state_req)
      FDI_REQ_ACTIVE: begin
        // Active requires the local Protocol Layer and the partner Adapter both
        // to have requested it (spec 8.1.6 step 6, FDI mirror).
        fdi_active_req    = 1'b1;
        fdi_state_req_out = FDI_REQ_ACTIVE;
        fdi_state_req_vld = local_active_req && adapter_active_req;
      end
      FDI_REQ_LINKRESET, FDI_REQ_RETRAIN, FDI_REQ_DISABLED,
      FDI_REQ_L1, FDI_REQ_L2: begin
        fdi_active_req    = 1'b1;
        fdi_state_req_out = lp_state_req;
        fdi_state_req_vld = 1'b1;
      end
      default: begin
        fdi_state_req_out = RDI_REQ_NOP;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // always_comb: FDI State Transition Logic
  //
  // Computes next FDI state (fdi_d) from fdi_q and rdi_state_sts, per the
  // spec 8.2 FDI LSM (Streaming-only simplification):
  //   F_RESET    -> Active needs RDI Active AND lp_rx_active_sts (the second
  //                 arm of the four-way handshake); LinkError/Disabled win.
  //   F_ACTIVE   -> mirrors any RDI change; PMNAK while the partner has not
  //                 finished its own Active request; unknown -> RESET.
  //   F_PMNAK    -> Active when RDI Active; else LinkReset/LinkError/Disabled.
  //   F_L1/F_L2  -> L1 exits to Retrain/LinkReset/Active/LinkError; L2 lacks a
  //                 direct return to Active (spec 8.2 low-power behaviour).
  //   F_LINKRESET-> Reset / Active / LinkError.
  //   F_RETRAIN  -> re-enters bring-up: LTSM passes Reset to SBINIT, reports
  //                 Active once training completes.
  //   F_LINKERROR-> only Reset (Exit-Link-Error) or LinkReset.
  //   F_DISABLED -> only Reset or LinkReset.
  //   default    -> F_RESET (defensive).
  // Spec ref: 8.2 (FDI LSM transitions), 8.1.5 (Exit-Link-Error).
  // -------------------------------------------------------------------------
  always_comb begin
    case (fdi_q)
      F_RESET: begin
        // The four-way handshake: adapter offers Active, Protocol Layer answers
        // with lp_rx_active_sts, then FDI reports Active.
        if (rdi_state_sts == RDI_STS_LINKERROR)  fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_DISABLED) fdi_d = F_DISABLED;
        else if (rdi_state_sts == RDI_STS_ACTIVE && lp_rx_active_sts)
                                               fdi_d = F_ACTIVE;
        else                                    fdi_d = F_RESET;
      end
      F_ACTIVE: begin
        // Active.PMNAK is reported while the partner has not completed its own
        // Active request.
        if (rdi_state_sts == RDI_STS_PMNAK)      fdi_d = F_PMNAK;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_RETRAIN)   fdi_d = F_RETRAIN;
        else if (rdi_state_sts == RDI_STS_L1)        fdi_d = F_L1;
        else if (rdi_state_sts == RDI_STS_L2)        fdi_d = F_L2;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_DISABLED)  fdi_d = F_DISABLED;
        else if (rdi_state_sts != RDI_STS_ACTIVE)    fdi_d = F_RESET;
        else                                         fdi_d = F_ACTIVE;
      end
      F_PMNAK: begin
        if (rdi_state_sts == RDI_STS_ACTIVE)     fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_DISABLED)  fdi_d = F_DISABLED;
        else                                     fdi_d = F_PMNAK;
      end
      F_L1: begin
        // L1 exits via Retrain or LinkReset from either side.
        if (rdi_state_sts == RDI_STS_RETRAIN)    fdi_d = F_RETRAIN;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_ACTIVE)    fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else                                     fdi_d = F_L1;
      end
      F_L2: begin
        if (rdi_state_sts == RDI_STS_RETRAIN)    fdi_d = F_RETRAIN;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else                                     fdi_d = F_L2;
      end
      F_LINKRESET: begin
        if (rdi_state_sts == RDI_STS_RESET)      fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_ACTIVE) fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else                                     fdi_d = F_LINKRESET;
      end
      F_RETRAIN: begin
        // Retrain re-enters the bring-up path: the LTSM returns to RESET on the
        // way back to SBINIT, then reports Active when training completes.
        if (rdi_state_sts == RDI_STS_RESET)      fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_ACTIVE) fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else                                     fdi_d = F_RETRAIN;
      end
      F_LINKERROR: begin
        // LinkError exits only through Reset, per spec 8.1.5 Exit-Link-Error.
        if (rdi_state_sts == RDI_STS_RESET)      fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else                                     fdi_d = F_LINKERROR;
      end
      F_DISABLED: begin
        if (rdi_state_sts == RDI_STS_RESET)      fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else                                     fdi_d = F_DISABLED;
      end
      default: fdi_d = F_RESET;
    endcase
  end

endmodule

`endif

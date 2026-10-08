// ============================================================================
// Module    : fdi_state_machine
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/fdi_state_machine.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 8.2 - Flit-Aware Die-to-Die Interface
//                                         (FDI)
//   UCIe 1.0 Specification, Section 8.2.6 - Rx_active_req/Sts Handshake
//   UCIe 1.0 Specification, Section 8.2.7 - FDI Bring up flow
//   UCIe 1.0 Specification, Table 115 - FDI Signal List
//   UCIe 1.0 Specification, Table 114 - RDI Signal List (state encodings)
//
// DESCRIPTION
//   FDI Link Sub-state Machine (FDI LSM). This module sits between the
//   Protocol Layer (above, Table 115 signals) and the RDI status signals
//   from the Logical PHY (below, Table 114). Its responsibilities:
//
//     1. Track the FDI link state in a registered state variable (fdi_q)
//        that mirrors the supported RDI state transitions reported by
//        rdi_state_sts. The FDI state space reuses the same 4-bit encoding
//        as the RDI:
//          F_RESET(0), F_ACTIVE(1), F_PMNAK(3),
//          F_LINKRESET(9), F_LINKERROR(A), F_DISABLED(C).
//        The unsupported encodings L1(4), L2(8), and RETRAIN(B) are not part
//        of the FDI state space, because this build never publishes them.
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
//     3. Forward only the supported Protocol Layer state requests to the RDI
//        on fdi_state_req_out / fdi_state_req_vld:
//          - Active    : the request level is forwarded when requested. Its
//                        valid qualifier asserts after lp_rx_active_sts.
//          - LinkReset : forwarded unconditionally.
//          - Disabled  : forwarded unconditionally.
//          - L1, L2, and Retrain are suppressed (RDI_REQ_NOP, vld low), so
//            an unsupported request cannot move the RDI or the LTSM.
//
//     4. Hold the current supported state while the RDI reports an
//        unsupported status. RETRAIN is the case that matters: the FDI
//        keeps publishing its last supported state for the whole report.
//
//     5. Drive all FDI status and indication outputs to the Protocol Layer:
//        pl_state_sts, pl_inband_pres, pl_error, pl_cerror, pl_nferror,
//        pl_trainerror, pl_phyinrecenter, pl_protocol, pl_protocol_flitfmt,
//        pl_rx_active_req, pl_stream.
//
//   Active handshake ownership:
//     The FDI observes the RDI status after the PHY LTSM completes its
//     LinkMgmt.RDI Active exchange. The adapter_active_req port remains for
//     public interface stability, but it does not affect FDI policy.
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
//   F_RESET        | anything else                    | F_RESET (hold)
//   F_ACTIVE       | RESET                            | F_RESET
//   F_ACTIVE       | PMNAK                            | F_PMNAK
//   F_ACTIVE       | LINKRESET                        | F_LINKRESET
//   F_ACTIVE       | LINKERROR                        | F_LINKERROR
//   F_ACTIVE       | DISABLED                         | F_DISABLED
//   F_ACTIVE       | ACTIVE / RETRAIN / L1 / L2       | F_ACTIVE (hold)
//   F_PMNAK        | RESET / ACTIVE / LINKRESET /     | respective
//                  | LINKERROR / DISABLED             |
//   F_PMNAK        | anything else                    | F_PMNAK (hold)
//   F_LINKRESET    | RESET / ACTIVE / LINKERROR       | respective
//   F_LINKRESET    | anything else                    | hold
//   F_LINKERROR    | RESET / LINKRESET                | respective
//   F_LINKERROR    | anything else                    | hold
//   F_DISABLED     | RESET / LINKRESET                | respective
//   F_DISABLED     | anything else                    | hold
//
//   RETRAIN, L1, and L2 are absent from the table on purpose. The RDI of
//   this build never publishes them, and the FDI never publishes them
//   either: a report of an unsupported status leaves the current supported
//   state unchanged. That hold is the approved Retrain policy.
//
// PORTS
//   See Table 115 for the FDI port definitions. RDI-side inputs are named
//   rdi_* and carry the Logical PHY's status. Adapter-internal ports
//   (adapter_active_req, adapter_state_req_vld, adapter_state_req,
//   fdi_active_req, fdi_state_req_out, fdi_state_req_vld) connect to
//   d2d_adapter. adapter_active_req is intentionally policy-inert.
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
//   v0.0.4  2026-09-23  Documentation: correct the Rx_active_req/Sts and FDI
//                        Bring up flow citations in the header. Normalize the
//                        Section 8.2 citation for pl_inband_pres.
//   v0.0.5  2026-09-25  Phase D policy: forward only Active, LinkReset, and
//                        Disabled requests; suppress L1, L2, and Retrain.
//                        Hold the supported state for an unsupported RDI
//                        status and drop the unreachable L1/L2/Retrain
//                        states. Remove the stale peer-Active gate from the
//                        Active request path; fdi_active_req now reports an
//                        Active request only. F_PMNAK now mirrors RDI RESET
//                        so the FDI cannot stay stuck in PMNAK.
//   v0.0.6  2026-09-25  Keep the public adapter_active_req port unchanged
//                        while documenting and enforcing its policy-inert
//                        Phase D behavior.
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

  // Peer-Active compatibility input. Phase D removes it from policy logic,
  // but the public module interface remains unchanged per PLAN.md §15.1.
  input  logic        adapter_active_req,
  input  logic        adapter_state_req_vld,
  input  logic [3:0]  adapter_state_req,
  input  logic        adapter_stage3_ready = 1'b1,
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
  //
  // The unsupported encodings L1 (4'h4), L2 (4'h8), and RETRAIN (4'hB) are
  // deliberately absent: this build's RDI never reports them and the FDI must
  // never publish them, so they are not part of the state space.
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_RESET    = 4'h0,
    F_ACTIVE   = 4'h1,
    F_PMNAK    = 4'h3,
    F_LINKRESET= 4'h9,
    F_LINKERROR= 4'hA,
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
  // fdi_state_req_vld for Active: the Active request is only presented as
  // valid once the local Protocol Layer has completed its half of the four-
  // way handshake. The partner Adapter's Active request is NOT part of this
  // decision; that agreement is owned by the LTSM and observed through
  // rdi_state_sts.
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
  //   - It sets to 1 when the RDI reports completed link training.
  //   - It clears to 0 when the FDI enters F_RESET, F_LINKERROR, or
  //     F_DISABLED (these states invalidate any prior presence detection).
  //   - Otherwise, it holds its current registered value (sticky).
  //
  // The computed pl_inband_pres_d is registered into inband_pres_q in the
  // state register always_ff above.
  //
  // Spec ref: UCIe 1.0, Section 8.2 - Flit-Aware Die-to-Die Interface (FDI)
  //           (pl_inband_pres behavior).
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
  // State-request forwarding: only Active, LinkReset, and Disabled reach the
  // RDI, and every other request leaves RDI_REQ_NOP with vld low.
  //   - Active    : request level presented as soon as the Protocol Layer
  //                 asks, with fdi_state_req_vld qualified by local_active_req
  //                 (the local half of the four-way handshake). The request
  //                 level itself is NOT gated by the validity flag, because
  //                 the RDI and the LTSM observe that level to start training.
  //                 The partner Adapter's Active request is not consulted
  //                 here: that policy lives in the LTSM.
  //   - LinkReset : forwarded with vld=1.
  //   - Disabled  : forwarded with vld=1.
  //   - L1, L2, Retrain, NOP: suppressed (RDI_REQ_NOP, vld=0).
  // fdi_active_req reports an Active request from the Protocol Layer only.
  // Spec ref: 8.2 (FDI), 8.2.6 (Rx Active), Table 115.
  // -------------------------------------------------------------------------
  always_comb begin
    pl_protocol        = PROTO_STREAMING;
    pl_protocol_flitfmt = FMT_RAW;
    pl_stream          = STREAM_ID_S0_STREAMING;
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
    fdi_state_req_out  = RDI_REQ_NOP;
    fdi_state_req_vld  = 1'b0;

    case (lp_state_req)
      FDI_REQ_ACTIVE: begin
        // Forward the Active request level immediately. Qualify its valid
        // pulse after the local Rx-active handshake (spec 8.2.6).
        fdi_active_req    = 1'b1;
        fdi_state_req_out = FDI_REQ_ACTIVE;
        fdi_state_req_vld = local_active_req;
      end
      FDI_REQ_L1, FDI_REQ_L2,
      FDI_REQ_LINKRESET, FDI_REQ_DISABLED: begin
        fdi_state_req_out = lp_state_req;
        fdi_state_req_vld = 1'b1;
      end
      default: begin
        // FDI_REQ_RETRAIN and FDI_REQ_NOP are suppressed:
        // the RDI keeps seeing no request and no valid request.
        fdi_state_req_out = RDI_REQ_NOP;
        fdi_state_req_vld = 1'b0;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // always_comb: FDI State Transition Logic
  //
  // Computes next FDI state (fdi_d) from fdi_q and rdi_state_sts, per the
  // spec 8.2 FDI LSM (Streaming-only simplification). Only the supported RDI
  // statuses are mirrored. An unsupported status (RETRAIN, L1, L2) or an
  // undefined encoding leaves the current state unchanged, so the FDI never
  // publishes a state that the RDI of this build cannot report:
  //   F_RESET    -> Active needs RDI Active AND lp_rx_active_sts (the second
  //                 arm of the four-way handshake); LinkError/Disabled win.
  //   F_ACTIVE   -> mirrors PMNAK, LinkReset, LinkError, Disabled, and Reset;
  //                 a RETRAIN report holds F_ACTIVE (approved Retrain policy).
  //   F_PMNAK    -> Active when the RDI accepts a retry, Reset when the link
  //                 is torn down; LinkReset/LinkError/Disabled mirror through.
  //   F_LINKRESET-> Reset / Active / LinkError.
  //   F_LINKERROR-> only Reset (Exit-Link-Error) or LinkReset.
  //   F_DISABLED -> only Reset or LinkReset.
  //   default    -> F_RESET (defensive).
  // Spec ref: 8.2 (FDI LSM transitions), 8.1.5 (Exit-Link-Error).
  // -------------------------------------------------------------------------
  always_comb begin
    case (fdi_q)
      F_RESET: begin
        // RDI reports Active, the Protocol Layer answers with
        // lp_rx_active_sts, then FDI reports Active.
        if (rdi_state_sts == RDI_STS_LINKERROR)       fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_LINKRESET)  fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_DISABLED)   fdi_d = F_DISABLED;
        else if (rdi_state_sts == RDI_STS_ACTIVE && lp_rx_active_sts && adapter_stage3_ready)
                                                      fdi_d = F_ACTIVE;
        else                                    fdi_d = F_RESET;
      end
      F_ACTIVE: begin
        // PMNAK reports that the PHY NAKed a power-management request. The
        // final else also covers an ACTIVE report and, per the approved
        // Retrain hold, the unsupported RETRAIN/L1/L2 reports.
        if (rdi_state_sts == RDI_STS_RESET)          fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_PMNAK)     fdi_d = F_PMNAK;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_DISABLED)  fdi_d = F_DISABLED;
        else                                         fdi_d = fdi_q;
      end
      F_PMNAK: begin
        // PMNAK is a transient NAK: it ends when the RDI reports Active after
        // an accepted retry, or Reset when the link is torn down.
        if (rdi_state_sts == RDI_STS_RESET)          fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_ACTIVE && lp_rx_active_sts && adapter_stage3_ready)
                                                     fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_DISABLED)  fdi_d = F_DISABLED;
        else                                         fdi_d = fdi_q;
      end
      F_LINKRESET: begin
        if (rdi_state_sts == RDI_STS_RESET)          fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_ACTIVE && lp_rx_active_sts && adapter_stage3_ready) fdi_d = F_ACTIVE;
        else if (rdi_state_sts == RDI_STS_LINKERROR) fdi_d = F_LINKERROR;
        else                                         fdi_d = fdi_q;
      end
      F_LINKERROR: begin
        // LinkError exits only through Reset, per spec Figure 111, Figure 119, and 8.3.2.7.
        if (rdi_state_sts == RDI_STS_RESET)          fdi_d = F_RESET;
        else                                         fdi_d = fdi_q;
      end
      F_DISABLED: begin
        if (rdi_state_sts == RDI_STS_LINKERROR)      fdi_d = F_LINKERROR;
        else if (rdi_state_sts == RDI_STS_RESET)     fdi_d = F_RESET;
        else if (rdi_state_sts == RDI_STS_LINKRESET) fdi_d = F_LINKRESET;
        else                                         fdi_d = fdi_q;
      end
      default: fdi_d = F_RESET;
    endcase
  end

  logic [7:0] unused_lp_stream;
  assign unused_lp_stream = lp_stream;
endmodule

`endif

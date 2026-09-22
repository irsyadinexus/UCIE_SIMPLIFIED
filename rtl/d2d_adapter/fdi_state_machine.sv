// UCIe 1.0 Simplified Endpoint - FDI state machine
// Spec 8.2 / Table 115. FDI sits between the Protocol Layer and the D2D Adapter.
// Streaming only: pl_protocol = 111b, pl_protocol_flitfmt = 0001b (Format 1 Raw).
// The link management handshake mirrors the RDI sequence but uses
// pl_rx_active_req / lp_rx_active_sts.
`ifndef FdiStateMachine_SV
`define FdiStateMachine_SV
`include "ucie_pkg.sv"

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

  // FDI LSM states (mirrors the RDI state space).
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

  // ---------------------------------------------------------------- state
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      fdi_q         <= F_RESET;
      inband_pres_q <= 1'b0;
    end else begin
      fdi_q         <= fdi_d;
      inband_pres_q <= pl_inband_pres_d;
    end
  end

  // Protocol Layer Active request latch.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      local_active_req <= 1'b0;
    end else if (lp_state_req == FDI_REQ_ACTIVE && lp_rx_active_sts) begin
      local_active_req <= 1'b1;
    end else if (fdi_q == F_RESET || fdi_q == F_LINKRESET) begin
      local_active_req <= 1'b0;
    end
  end

  // in-band presence is sticky 1 until Reset/LinkError/Disable.
  always_comb begin
    if (rdi_inband_pres)               pl_inband_pres_d = 1'b1;
    else if (fdi_q == F_RESET ||
             fdi_q == F_LINKERROR ||
             fdi_q == F_DISABLED)      pl_inband_pres_d = 1'b0;
    else                               pl_inband_pres_d = inband_pres_q;
  end

  // ---------------------------------------------------------------- outputs
  // Single driver for every output. The Rx-active request is asserted as soon as
  // the RDI reaches Active, not after FDI does: spec 8.2.6 makes this the first
  // arm of the four-way handshake, and gating it on F_ACTIVE would deadlock
  // against a Protocol Layer that waits for pl_rx_active_req before answering.
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

  // ---------------------------------------------------------------- transitions
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

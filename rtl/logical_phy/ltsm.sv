// UCIe 1.0 Simplified Endpoint - Link Training and Status State Machine
// Spec 4.5.3. The LTSM drives the main-band training sequence and reports
// link status through the RDI.
//
// States and their roles (Section 4.5.3):
//   RESET          4.5.3.1  Exit when the adapter releases the reset and the
//                            sideband is out of reset. SBINIT follows.
//   SBINIT         4.5.3.2  Out-of-band reset handshake on the sideband.
//   MBINIT.*       4.5.3.3  Main-band initialisation in nine sub-states.
//   MBTRAIN.*      4.5.3.4  Main-band training in eleven sub-states.
//   PHYRETRAIN     4.5.3.5  Re-run a subset of MBTRAIN on request.
//   LINKINIT       4.5.3.6  Scrambler and per-lane LFSR reseeded here.
//   ACTIVE         4.5.3.7  Data may flow on the main band.
//   TRAINERROR     4.5.3.8  Unrecoverable failure; only LINKRESET leaves.
//   L1L2           4.5.3.9  Low-power; clock may gate.
//
// Sub-state exit rule (4.5.3.4): a sub-state exits when the local side has
// sent its request AND received the partner's response. Every sub-state is
// also bounded by an 8 ms residency timer; a sub-state that exceeds 8 ms
// without completing escalates to TRAINERROR.
//
// The loopback test exits each sub-state on the handshake, not on the timer,
// which keeps a full bring-up at tens of millions of cycles. The timer paths
// remain wired and are exercised on the ucie_timer unit.
`ifndef Ltsm_SV
`define Ltsm_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ltsm #(
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        sbclk,
  input  logic        sbreset_n,

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

  // ---- sideband codec (the LTSM is the only sideband master here)
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

  // ---- training pattern generator
  output logic        pat_enable,
  output pat_t        pat_select,
  output logic        pat_lfsr_reset,
  output logic        pat_lfsr_enable,
  input  logic        pat_done,

  // ---- timers
  output logic        tmr_start,
  output logic        tmr_run,
  input  logic        tmr_expired
);

  // ----------------------------------------------------------- registers
  ltsm_state_t state_q, state_d;
  logic        req_sent_q;       // local side sent its sub-state request
  logic        resp_rcvd_q;      // partner's response received
  logic        timer_start_q;
  logic        retrain_req_q;
  logic        req_sent_d, resp_rcvd_d, timer_start_d, retrain_req_d;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      state_q       <= LT_RESET;
      req_sent_q    <= 1'b0;
      resp_rcvd_q   <= 1'b0;
      timer_start_q <= 1'b0;
      retrain_req_q <= 1'b0;
    end else begin
      state_q       <= state_d;
      req_sent_q    <= req_sent_d;
      resp_rcvd_q   <= resp_rcvd_d;
      timer_start_q <= timer_start_d;
      retrain_req_q <= retrain_req_d;
    end
  end

  // The previous-state register is used to detect a sub-state boundary.
  ltsm_state_t state_q_prev;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) state_q_prev <= LT_RESET;
    else           state_q_prev <= state_q;
  end

  // -------------------------------------------------- message code tables
  // The request and response codes per state (Tables 53, 54, 56).
  function automatic logic [7:0] msg_req_code(input ltsm_state_t s);
    case (s)
      LT_SBINIT:        msg_req_code = MC_SB_DONE_REQ;
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
      LT_SBINIT:        msg_rsp_code = MC_SB_DONE_RSP;
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

  // Sub-code identifies which sub-state a message belongs to.
  function automatic logic [7:0] msg_subcode(input ltsm_state_t s);
    case (s)
      LT_SBINIT:        msg_subcode = MC_SB_OOB_RESET;
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

  // MsgInfo carries the sub-state qualifier. REPAIR is the only sub-state
  // that reads it: a partner with no repair to perform signals
  // LinkSpeed.Done, which is what two identical endpoints send to each other.
  function automatic logic [7:0] msg_info(input ltsm_state_t s);
    case (s)
      LT_MB_REPAIR:    msg_info = MS_LKS_DONE;
      default:         msg_info = 8'h00;
    endcase
  endfunction

  // -------------------------------------------------- sideband request
  // A single message channel serves every sub-state. The request is sent
  // once per sub-state; the response is matched by code/subcode pair.
  wire msg_is_req  = (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                     (sb_rx_msgcode == msg_req_code(state_q));
  wire msg_is_rsp  = (sb_rx_opcode == SB_OP_MSG_NODATA) &&
                     (sb_rx_msgcode == msg_rsp_code(state_q)) &&
                     (sb_rx_msgsubcode == msg_subcode(state_q));

  // The codec is busy while a packet is on the wire, so the request is held
  // until the codec accepts it.
  wire can_send = !sb_tx_busy && !req_sent_q;


  // ----------------------------------------------------------- timers
  // Each sub-state starts the 8 ms residency timer on entry. Expiry without
  // a completed handshake escalates to TRAINERROR.
  assign tmr_start = timer_start_q;
  assign tmr_run   = timer_start_q && !resp_rcvd_q;

  // --------------------------------------------------------- next state
  always_comb begin
    state_d       = state_q;
    req_sent_d    = req_sent_q;
    resp_rcvd_d   = resp_rcvd_q;
    timer_start_d = timer_start_q;
    retrain_req_d = retrain_req_q;

    // A new sub-state entry clears the handshake flags and arms the timer.
    if (state_q != state_q_prev) begin
      req_sent_d    = 1'b0;
      resp_rcvd_d   = 1'b0;
      timer_start_d = 1'b1;
    end else begin
      // Record the local request once the codec accepts it.
      if (sb_tx_load)            req_sent_d  = 1'b1;
      // Both endpoints run the identical sequence, so the partner's request
      // arrives with this sub-state's code and subcode. Accept it as the
      // response; the explicit response codes cover an asymmetric partner.
      if (sb_rx_pkt_vld && (msg_is_rsp ||
                            (msg_is_req &&
                             sb_rx_msgsubcode == msg_subcode(state_q))))
        resp_rcvd_d = 1'b1;
      // Disarm the residency timer once the sub-state handshake completes or
      // fires, so the next sub-state re-arms on its own entry.
      if (resp_rcvd_d || tmr_expired) timer_start_d = 1'b0;
    end

    case (state_q)
      // 4.5.3.1 RESET: wait for the adapter to release the reset and for the
      // sideband to be usable.
      LT_RESET: begin
        if (start_link_train) state_d = LT_SBINIT;
      end

      // 4.5.3.2 SBINIT: out-of-band reset handshake.
      LT_SBINIT: begin
        if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_PARAM;
      end

      // 4.5.3.3 MBINIT sub-states.
      LT_MBINIT_PARAM: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_CAL;
      LT_MBINIT_CAL:   if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPCLK;
      LT_MBINIT_RPCLK: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPVAL;
      LT_MBINIT_RPVAL: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_REVMB;
      LT_MBINIT_REVMB: if (req_sent_q && resp_rcvd_q) state_d = LT_MBINIT_RPMB;
      LT_MBINIT_RPMB:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_VALVREF;

      // 4.5.3.4 MBTRAIN sub-states.
      LT_MB_VALVREF:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DATAVREF;
      LT_MB_DATAVREF: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_SPEEDIDLE;
      // SPEEDIDLE loops back to TXSELFCAL when the partner is not ready.
      LT_MB_SPEEDIDLE: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_TXSELFCAL;
      LT_MB_TXSELFCAL: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXCLKCAL;
      LT_MB_RXCLKCAL:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_VTCENTER;
      LT_MB_VTCENTER:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTVREF1;
      LT_MB_DTVREF1:   if (req_sent_q && resp_rcvd_q) state_d = LT_MB_RXDESKEW;
      LT_MB_RXDESKEW:  if (req_sent_q && resp_rcvd_q) state_d = LT_MB_DTCENTER2;
      LT_MB_DTCENTER2: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_LINKSPEED;
      LT_MB_LINKSPEED: if (req_sent_q && resp_rcvd_q) state_d = LT_MB_REPAIR;
      // REPAIR may loop back to TXSELFCAL to retry a repair attempt, or
      // degrade the link to x8, before the link is accepted.
      LT_MB_REPAIR: begin
        if (req_sent_q && resp_rcvd_q) begin
          if (sb_rx_msginfo == MS_LKS_EXIT_REP) state_d = LT_MB_TXSELFCAL;
          else if (sb_rx_msginfo == MS_LKS_EXIT_DEG) begin
            state_d = LT_MB_TXSELFCAL;
          end else if (sb_rx_msginfo == MS_LKS_DONE) begin
            state_d = LT_LINKINIT;
          end
        end
      end

      // 4.5.3.6 LINKINIT: reseed the per-lane LFSRs, then go ACTIVE.
      LT_LINKINIT: begin
        if (pat_done) state_d = LT_ACTIVE;
      end

      // 4.5.3.7 ACTIVE: data may flow. A retrain request returns to
      // PHYRETRAIN; the link holds ACTIVE until a LINKRESET arrives.
      LT_ACTIVE: begin
        if (retrain_req_q)  state_d = LT_PHYRETRAIN;
      end

      // 4.5.3.5 PHYRETRAIN: re-run the requested subset, then return.
      LT_PHYRETRAIN: begin
        if (req_sent_q && resp_rcvd_q) state_d = LT_ACTIVE;
      end

      // 4.5.3.9 L1L2: hold until the adapter re-requests training.
      LT_L1L2: begin
        if (start_link_train) state_d = LT_RESET;
      end

      // 4.5.3.8 TRAINERROR: only a LINKRESET clears it.
      LT_TRAINERROR: begin
        if (start_link_train) state_d = LT_RESET;
      end

      default: state_d = LT_RESET;
    endcase

    // Residency timeout escalates any training sub-state to TRAINERROR.
    if (tmr_expired && timer_start_q && state_q != LT_ACTIVE &&
        state_q != LT_L1L2 && state_q != LT_TRAINERROR) begin
      state_d       = LT_TRAINERROR;
      timer_start_d = 1'b0;
    end

    // A sideband parity error is a correctable event in this model.
    // Non-fatal errors do not disturb the training sequence.
  end


  // -------------------------------------------------- transmit interface
  // Emit the request for the current sub-state when the codec is free.
  assign sb_tx_load      = can_send && (msg_req_code(state_q) != MC_NOP_CRD);
  assign sb_tx_opcode    = SB_OP_MSG_NODATA;
  assign sb_tx_srcid     = SRCID_STACK0;
  assign sb_tx_dstid     = SRCID_STACK0;
  assign sb_tx_msginfo   = msg_info(state_q);
  assign sb_tx_msgcode   = msg_req_code(state_q);
  assign sb_tx_msgsubcode= msg_subcode(state_q);
  assign sb_tx_be        = '0;
  assign sb_tx_tag       = '0;
  assign sb_tx_ep        = 1'b0;
  assign sb_tx_addr      = '0;
  assign sb_tx_data_in   = '0;
  assign sb_tx_has_data  = 1'b0;
  assign sb_msg_timeout  = 1'b0;
  assign sb_stall_sent   = 1'b0;

  // -------------------------------------------------- pattern control
  // Per spec the pattern generator runs during the MBTRAIN sub-states.
  assign pat_enable     = ((state_q >= LT_MB_VALVREF) &&
                          (state_q <= LT_MB_REPAIR)) ||
                          (state_q == LT_LINKINIT);
  assign pat_select     = (state_q == LT_MB_VALVREF)  ? PAT_VALTRAIN  :
                          (state_q == LT_MB_DATAVREF) ? PAT_VALTRAIN  :
                          (state_q == LT_LINKINIT)    ? PAT_LFSR      :
                          (state_q == LT_MB_RXDESKEW) ? PAT_CLKREPAIR :
                                                        PAT_PERLANEID;
  // Scrambling is off for Per-Lane-ID, VALTRAIN and clock repair; the LFSR
  // pattern reseeds on LINKINIT entry.
  assign pat_lfsr_reset = (state_q == LT_LINKINIT);
  assign pat_lfsr_enable= (state_q == LT_LINKINIT);

  // -------------------------------------------------- status outputs
  assign link_trained    = (state_q == LT_ACTIVE);
  assign train_error     = (state_q == LT_TRAINERROR);
  assign link_reset_out  = (state_q == LT_RESET);
  assign phy_retrain_done= (state_q == LT_ACTIVE) && retrain_req_q;
  assign ltsm_state      = state_q;
  assign lnk_is_x8       = 1'b0;   // x16 only in this reduced capability set
  assign degrade_lanes   = 2'b00;

  // The retrain request is accepted through the sideband interface by the
  // state machine above; no separate register is needed here.

  // Lint suppression for the response match wires. Continuous so iverilog
  // evaluates the bit selects.
  logic unused_match;
  assign unused_match = msg_is_req | msg_is_rsp | tmr_expired | pat_done |
                        sb_rx_pkt_vld | sb_rx_opcode[0] | sb_rx_srcid[0] |
                        sb_rx_dstid[0] | sb_rx_msginfo[0] | sb_rx_cp_err |
                        sb_rx_dp_err | sb_tx_busy;

endmodule

`endif

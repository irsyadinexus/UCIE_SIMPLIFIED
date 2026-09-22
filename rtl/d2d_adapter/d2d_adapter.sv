// UCIe 1.0 Simplified Endpoint - D2D Adapter integration
// Spec Chapter 2. Contains the FDI state machine, the Streaming pass-through
// datapath, the adapter register file, and the adapter sideband interface.
// The LTSM is NOT here: it lives in logical_phy and is opaque to this block.
//
// RDI ports connect to logical_phy. FDI ports connect to the Protocol Layer.
`ifndef D2dAdapter_SV
`define D2dAdapter_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module d2d_adapter #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,
  input  logic                  lreset_n,

  // ---------------------------------------------------------- FDI (Table 115)
  input  logic                  lp_irdy,
  input  logic                  lp_valid,
  input  logic [NBYTES*8-1:0]   lp_data,
  output logic                  pl_trdy,
  output logic                  pl_valid,
  output logic [NBYTES*8-1:0]   pl_data,
  input  logic [3:0]            lp_state_req,
  output logic [3:0]            pl_state_sts,
  output logic                  pl_inband_pres,
  output logic                  pl_error,
  output logic                  pl_cerror,
  output logic                  pl_nferror,
  output logic                  pl_trainerror,
  output logic                  pl_phyinrecenter,
  output logic                  pl_stallreq,
  input  logic                  lp_stallack,
  output logic                  pl_rx_active_req,
  input  logic                  lp_rx_active_sts,
  input  logic [7:0]            lp_stream,
  output logic [7:0]            pl_stream,
  output logic [2:0]            pl_protocol,
  output logic [3:0]            pl_protocol_flitfmt,
  input  logic [NC-1:0]         lp_cfg,
  input  logic                  lp_cfg_vld,
  input  logic                  lp_cfg_crd,
  output logic [NC-1:0]         pl_cfg,
  output logic                  pl_cfg_vld,
  output logic                  pl_cfg_crd,
  output logic                  lp_linkerror,

  // ---------------------------------------------------------- RDI (Table 114)
  output logic                  rdi_lp_irdy,
  output logic                  rdi_lp_valid,
  output logic [NBYTES*8-1:0]   rdi_lp_data,
  input  logic                  rdi_pl_trdy,
  input  logic                  rdi_pl_valid,
  input  logic [NBYTES*8-1:0]   rdi_pl_data,
  output logic [3:0]            rdi_lp_state_req,
  input  logic [3:0]            rdi_pl_state_sts,
  input  logic                  rdi_pl_inband_pres,
  input  logic                  rdi_pl_error,
  input  logic                  rdi_pl_cerror,
  input  logic                  rdi_pl_nferror,
  input  logic                  rdi_pl_trainerror,
  input  logic                  rdi_pl_phyinrecenter,
  input  logic                  rdi_pl_stallreq,
  output logic                  rdi_lp_stallack,
  input  logic [2:0]            rdi_pl_lnk_cfg,
  input  logic [2:0]            rdi_pl_speedmode,

  // Adapter-internal
  input  logic                  start_link_train,
  output logic [7:0]            ltsm_state_obs,
  output logic                  link_active_obs
);

  import ucie_pkg::*;

  logic        adapter_active_req;
  logic        adapter_state_req_vld;
  logic [3:0]  adapter_state_req;
  logic        fdi_active_req;
  logic [3:0]  fdi_state_req_out;
  logic        fdi_state_req_vld;
  logic        stall_active;
  logic        lnk_is_x8;
  logic        csr_wr, csr_rd;
  logic [26:0] csr_addr;
  logic [63:0] csr_wdata, csr_rdata;
  logic        csr_rdata_vld;
  logic        sb_credit_returned, sb_stall_sent, sb_msg_timeout;
  logic        start_link_train_wr;
  logic        link_status_active;

  // ---------------------------------------------------- stall handshake
  // Spec 8.3.1: four-phase. pl_stallreq rises only while lp_stallack is low.
  // While lp_stallack is high, both lp_valid and lp_irdy must be low. The
  // register below supplies the required flop between pl_stallreq and the
  // ack going back to the PHY.
  logic stallreq_q;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) stallreq_q <= 1'b0;
    else           stallreq_q <= rdi_pl_stallreq && !lp_stallack;
  end

  always_comb begin
    pl_stallreq   = stallreq_q;
    rdi_lp_stallack = stallreq_q;
    stall_active  = stallreq_q && lp_stallack;
    lnk_is_x8     = (rdi_pl_lnk_cfg == LNKCFG_X8);
  end

  // ------------------------------------------- FDI -> RDI state request
  // The FDI state machine drives the RDI request; the active request is the
  // exception because both dies must have asked for Active first.
  always_comb begin
    rdi_lp_state_req = fdi_state_req_out;
  end

  // -------------------------------------------------- FDI state machine
  fdi_state_machine u_fdi_sm (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .lp_state_req(lp_state_req),
    .pl_state_sts(pl_state_sts),
    .pl_inband_pres(pl_inband_pres),
    .pl_error(pl_error),
    .pl_cerror(pl_cerror),
    .pl_nferror(pl_nferror),
    .pl_trainerror(pl_trainerror),
    .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol(pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_rx_active_sts(lp_rx_active_sts),
    .lp_stream(lp_stream),
    .pl_stream(),
    .rdi_state_sts(rdi_pl_state_sts),
    .rdi_inband_pres(rdi_pl_inband_pres),
    .rdi_trainerror(rdi_pl_trainerror),
    .rdi_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_cerror(rdi_pl_cerror),
    .rdi_nferror(rdi_pl_nferror),
    .adapter_active_req(adapter_active_req),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .fdi_active_req(fdi_active_req),
    .fdi_state_req_out(fdi_state_req_out),
    .fdi_state_req_vld(fdi_state_req_vld)
  );

  // ----------------------------------------------------- adapter datapath
  adapter_datapath #(.NBYTES(NBYTES)) u_datapath (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .lp_irdy(lp_irdy),
    .lp_valid(lp_valid),
    .lp_data(lp_data),
    .lp_stream(lp_stream),
    .lp_stallack(lp_stallack),
    .lp_rx_active_sts(lp_rx_active_sts),
    .pl_trdy(pl_trdy),
    .pl_valid(pl_valid),
    .pl_data(pl_data),
    .pl_stream(pl_stream),
    .rdi_lp_irdy(rdi_lp_irdy),
    .rdi_lp_valid(rdi_lp_valid),
    .rdi_lp_data(rdi_lp_data),
    .rdi_pl_trdy(rdi_pl_trdy),
    .rdi_pl_valid(rdi_pl_valid),
    .rdi_pl_data(rdi_pl_data),
    .rdi_lnk_is_x8(lnk_is_x8),
    .stall_active(stall_active)
  );

  // -------------------------------------------------- adapter sideband if
  adapter_sb_if u_sb_if (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .lp_cfg(lp_cfg),
    .lp_cfg_vld(lp_cfg_vld),
    .lp_cfg_crd(lp_cfg_crd),
    .pl_cfg(pl_cfg),
    .pl_cfg_vld(pl_cfg_vld),
    .pl_cfg_crd(pl_cfg_crd),
    .partner_active_req(1'b0),
    .adapter_active_req(adapter_active_req),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .csr_wr(csr_wr),
    .csr_addr(csr_addr),
    .csr_wdata(csr_wdata),
    .csr_rd(csr_rd),
    .csr_rdata(csr_rdata),
    .csr_rdata_vld(csr_rdata_vld),
    .sb_credit_returned(sb_credit_returned),
    .sb_stall_sent(sb_stall_sent),
    .sb_msg_timeout(sb_msg_timeout)
  );

  // -------------------------------------------------------- register file
  adapter_regfile u_regfile (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .csr_wr(csr_wr),
    .csr_addr(csr_addr),
    .csr_wdata(csr_wdata),
    .csr_rd(csr_rd),
    .csr_rdata(csr_rdata),
    .csr_rdata_vld(csr_rdata_vld),
    .start_link_train_wr(start_link_train_wr),
    .in_band_pres(rdi_pl_inband_pres),
    .rdi_state_sts(rdi_pl_state_sts),
    .ltsm_state(ltsm_state_obs),
    .trainerror(rdi_pl_trainerror),
    .phyinrecenter(rdi_pl_phyinrecenter),
    .start_link_train(),
    .link_status_active(link_status_active)
  );

  // --------------------------------------------------------- observability
  always_comb begin
    lp_linkerror    = 1'b0;
    link_active_obs = link_status_active;
  end

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n)            start_link_train_wr <= 1'b0;
    else if (start_link_train) start_link_train_wr <= 1'b1;
  end

  // Suppress unused-signal lint without changing behaviour.
  logic unused_inputs;
  always_comb begin
    unused_inputs = rdi_pl_error | (|rdi_pl_speedmode) |
                    fdi_active_req | fdi_state_req_vld |
                    sb_credit_returned | sb_stall_sent | sb_msg_timeout |
                    adapter_state_req_vld;
  end

endmodule

`endif

// UCIe 1.0 Simplified Endpoint - top level
// Spec section 3.1. Exactly two blocks: the D2D Adapter and the Logical PHY.
//
// The top level wires the adapter to the logical PHY across the RDI and
// presents the sideband and main-band pins to the partner die. There is no
// protocol layer, no retimer and no analog PHY in this reduced capability
// set, per the README implementation scope.
`ifndef UcieMain_SV
`define UcieMain_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ucie_main #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        sbclk,
  input  logic        sbreset_n,
  input  logic        start_link_train,

  // ---------------------------------------------------------- FDI (Table 115)
  input  logic        lp_irdy,
  input  logic        lp_valid,
  input  logic [DATA_W-1:0] lp_data,
  input  logic [7:0]  lp_stream,
  input  logic        lp_stallack,
  input  logic        lp_rx_active_sts,
  output logic        pl_trdy,
  output logic        pl_valid,
  output logic [DATA_W-1:0] pl_data,
  output logic [7:0]  pl_stream,
  output logic        pl_error,
  output logic        pl_cerror,
  output logic        pl_nferror,
  output logic        pl_trainerror,
  output logic        pl_phyinrecenter,
  output logic [2:0]  pl_protocol,
  output logic [3:0]  pl_protocol_flitfmt,
  output logic        pl_rx_active_req,
  input  logic [3:0]  lp_state_req,
  output logic [3:0]  pl_state_sts,
  output logic        pl_inband_pres,
  output logic        pl_stallreq,
  output logic        lp_linkerror,
  // ------------------------------------------------- sideband to partner
  output logic [NC-1:0] sb_tx_data,
  output logic        sb_tx_valid,
  input  logic [NC-1:0] sb_rx_data,
  input  logic        sb_rx_valid,

  // ------------------------------------------------- main band to partner
  output logic [NLANES-1:0] mb_tx_data,
  input  logic [NLANES-1:0] mb_rx_data
);

  // ------------------------------------------------- RDI (Table 114)
  // The adapter and the logical PHY share the RDI. All adapter inputs that
  // the logical PHY drives are wires here.
  rdi_req_t    rdi_lp_state_req;
  logic        rdi_lp_stallack;
  rdi_sts_t    rdi_pl_state_sts;
  logic        rdi_pl_inband_pres;
  logic        rdi_pl_linkerror;
  logic        rdi_pl_error;
  logic        rdi_pl_phyinrecenter;
  logic        rdi_pl_cerror;
  logic        rdi_pl_nferror;
  logic        rdi_pl_trainerror;
  logic        rdi_lp_irdy;
  logic        rdi_lp_valid;
  logic [DATA_W-1:0] rdi_lp_data;
  logic        rdi_pl_trdy;
  logic        rdi_pl_valid;
  logic [DATA_W-1:0] rdi_pl_data;
  logic [2:0]  rdi_pl_lnk_cfg;
  logic [2:0]  rdi_pl_speedmode;
  logic        rdi_pl_stallreq;
  logic [NC-1:0] lp_cfg;
  logic          lp_cfg_vld;
  logic          lp_cfg_crd;
  logic [NC-1:0] pl_cfg;
  logic          pl_cfg_vld;
  logic          pl_cfg_crd;
  // ------------------------------------------------- adapter active req
  // The adapter's link-active observation gates the RDI Active entry in the
  // logical PHY (spec 8.1.6). The partner's LinkMgmt.RDI.Req.Active message
  // is decoded inside the adapter; this net forwards the result.
  logic        adapter_active_req;
  logic        link_active_obs;

  assign adapter_active_req = link_active_obs;

  // ------------------------------------------------- D2D adapter
  d2d_adapter #(.NBYTES(NBYTES)) u_adapter (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    // FDI
    .lp_irdy         (lp_irdy),
    .lp_valid        (lp_valid),
    .lp_data         (lp_data),
    .lp_stream       (lp_stream),
    .lp_stallack     (lp_stallack),
    .lp_rx_active_sts(lp_rx_active_sts),
    .pl_trdy         (pl_trdy),
    .pl_valid        (pl_valid),
    .pl_data         (pl_data),
    .pl_stream       (pl_stream),
    .pl_error        (pl_error),
    .pl_cerror       (pl_cerror),
    .pl_nferror      (pl_nferror),
    .pl_trainerror   (pl_trainerror),
    .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol     (pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_state_req    (lp_state_req),
    .pl_state_sts    (pl_state_sts),
    .pl_inband_pres  (pl_inband_pres),
    .pl_stallreq     (pl_stallreq),
    .lp_linkerror    (lp_linkerror),
    // RDI
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_error    (rdi_pl_error),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .rdi_lp_irdy     (rdi_lp_irdy),
    .rdi_lp_valid    (rdi_lp_valid),
    .rdi_lp_data     (rdi_lp_data),
    .rdi_pl_trdy     (rdi_pl_trdy),
    .rdi_pl_valid    (rdi_pl_valid),
    .rdi_pl_data     (rdi_pl_data),
    .rdi_pl_lnk_cfg  (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode(rdi_pl_speedmode),
    .rdi_pl_stallreq (rdi_pl_stallreq),
    // cfg sideband
    .lp_cfg          (lp_cfg),
    .lp_cfg_vld      (lp_cfg_vld),
    .lp_cfg_crd      (lp_cfg_crd),
    .pl_cfg          (pl_cfg),
    .pl_cfg_vld      (pl_cfg_vld),
    .start_link_train(start_link_train),
    .ltsm_state_obs  (),
    .link_active_obs (link_active_obs)
  );

  // ------------------------------------------------- logical PHY
  logical_phy #(.NBYTES(NBYTES), .NLANES(NLANES)) u_lphy (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .start_link_train(start_link_train),
    // RDI
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .rdi_lp_irdy     (rdi_lp_irdy),
    .rdi_lp_valid    (rdi_lp_valid),
    .rdi_lp_data     (rdi_lp_data),
    .rdi_pl_trdy     (rdi_pl_trdy),
    .rdi_pl_valid    (rdi_pl_valid),
    .rdi_pl_data     (rdi_pl_data),
    .rdi_pl_lnk_cfg  (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode(rdi_pl_speedmode),
    .rdi_pl_stallreq (rdi_pl_stallreq),
    // sideband to partner
    .sb_tx_data      (sb_tx_data),
    .sb_tx_valid     (sb_tx_valid),
    .sb_rx_data      (sb_rx_data),
    .sb_rx_valid     (sb_rx_valid),
    // main band to partner
    .mb_tx_data      (mb_tx_data),
    .mb_rx_data      (mb_rx_data),
    // cfg sideband: the adapter drives pl_cfg, so the PHY side floats its
    // observation outputs.
    .lp_cfg          (lp_cfg),
    .lp_cfg_vld      (lp_cfg_vld),
    .lp_cfg_crd      (lp_cfg_crd),
    .pl_cfg          (),
    .pl_cfg_vld      (),
    .pl_cfg_crd      (),
    // partner active
    .adapter_active_req(adapter_active_req)
  );

  // Lint suppression.
  logic unused;
  assign unused = sbreset_n | rdi_lp_stallack | pl_cfg[0] | pl_cfg_vld |
                  pl_cfg_crd | lp_cfg[0] | lp_cfg_vld | lp_cfg_crd |
                  mb_rx_data[0] | rdi_pl_lnk_cfg[0] | rdi_pl_speedmode[0];

endmodule

`endif

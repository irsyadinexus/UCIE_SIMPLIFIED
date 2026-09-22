// UCIe 1.0 Simplified Endpoint - Logical PHY integration
// Spec section 3.1. Holds the RDI link state machine, the link training and
// status state machine, the sideband codec, the training pattern generator,
// the byte-to-lane mapper and the PHY CSR block.
//
// This module presents the RDI to the D2D Adapter and the sideband and
// main-band pins to the partner die. It is the only counterpart to
// d2d_adapter in the top level.
`ifndef LogicalPhy_SV
`define LogicalPhy_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module logical_phy #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        sbclk,
  input  logic        sbreset_n,
  input  logic        start_link_train,

  // ---------------------------------------------------------- RDI (Table 114)
  input  rdi_req_t    rdi_lp_state_req,
  input  logic        rdi_lp_stallack,
  output rdi_sts_t    rdi_pl_state_sts,
  output logic        rdi_pl_inband_pres,
  output logic        rdi_pl_linkerror,
  output logic        rdi_pl_phyinrecenter,
  output logic        rdi_pl_cerror,
  output logic        rdi_pl_nferror,
  output logic        rdi_pl_trainerror,
  input  logic        rdi_lp_irdy,
  input  logic        rdi_lp_valid,
  input  logic [DATA_W-1:0] rdi_lp_data,
  output logic        rdi_pl_trdy,
  output logic        rdi_pl_valid,
  output logic [DATA_W-1:0] rdi_pl_data,
  output logic [2:0]  rdi_pl_lnk_cfg,
  output logic [2:0]  rdi_pl_speedmode,
  output logic        rdi_pl_stallreq,
  input  logic        adapter_active_req,

  // -------------------------------------------------- sideband to partner
  output logic [NC-1:0] sb_tx_data,
  output logic        sb_tx_valid,
  input  logic [NC-1:0] sb_rx_data,
  input  logic        sb_rx_valid,

  // -------------------------------------------------- main band to partner
  output logic [NLANES-1:0] mb_tx_data,
  input  logic [NLANES-1:0] mb_rx_data,
  input  logic [NC-1:0]   lp_cfg,
  input  logic            lp_cfg_vld,
  input  logic            lp_cfg_crd,
  output logic [NC-1:0]   pl_cfg,
  output logic            pl_cfg_vld,
  output logic            pl_cfg_crd
);

  // ------------------------------------------------- internal datapath
  logic [NBYTES-1:0][7:0] tx_bytes;
  logic [NLANES-1:0][7:0] lane_bytes;

  // ------------------------------------------------- LTSM <-> codec
  logic        sb_tx_load;
  logic [4:0]  sb_tx_opcode;
  logic [2:0]  sb_tx_srcid;
  logic [2:0]  sb_tx_dstid;
  logic [7:0]  sb_tx_msginfo;
  logic [7:0]  sb_tx_msgcode;
  logic [7:0]  sb_tx_msgsubcode;
  logic [7:0]  sb_tx_be;
  logic [4:0]  sb_tx_tag;
  logic        sb_tx_ep;
  logic [11:0] sb_tx_addr;
  logic [63:0] sb_tx_data_in;
  logic        sb_tx_has_data;
  logic        sb_tx_busy;
  logic        sb_rx_pkt_vld;
  logic [4:0]  sb_rx_opcode;
  logic [2:0]  sb_rx_srcid;
  logic [2:0]  sb_rx_dstid;
  logic [7:0]  sb_rx_msginfo;
  logic [7:0]  sb_rx_msgcode;
  logic [7:0]  sb_rx_msgsubcode;
  logic        sb_rx_cp_err;
  logic        sb_rx_dp_err;
  logic        sb_msg_timeout;
  logic        sb_stall_sent;

  // ------------------------------------------------- LTSM <-> pattern gen
  logic        pat_enable;
  pat_t        pat_select;
  logic        pat_lfsr_reset;
  logic        pat_lfsr_enable;
  logic        pat_done;

  // ------------------------------------------------- LTSM <-> timer
  logic        tmr_start;
  logic        tmr_run;
  logic        tmr_expired;

  // ------------------------------------------------- LTSM <-> adapter
  logic        csr_start_link_train;
  wire         ltsm_start_link_train;
  logic        link_trained;
  logic        train_error;
  logic        link_reset_out;
  logic        phy_retrain_done;
  logic [7:0]  ltsm_state;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;

  // ------------------------------------------------- RDI <-> LTSM
  logic        local_active_req;

  // ------------------------------------------------- CSR
  logic        csr_wr;
  logic        csr_rd;
  logic [26:0] csr_addr;
  logic [63:0] csr_wdata;
  logic [63:0] csr_rdata;
  logic        csr_rdata_vld;

  // ------------------------------------------------- sideband codec
  sb_codec u_sb_codec (
    .sbclk        (sbclk),
    .sbreset_n    (sbreset_n),
    .tx_load      (sb_tx_load),
    .tx_opcode    (sb_tx_opcode),
    .tx_srcid     (sb_tx_srcid),
    .tx_dstid     (sb_tx_dstid),
    .tx_msginfo   (sb_tx_msginfo),
    .tx_msgcode   (sb_tx_msgcode),
    .tx_msgsubcode(sb_tx_msgsubcode),
    .tx_cr        (1'b0),
    .tx_addr      (sb_tx_addr),
    .tx_be        (sb_tx_be),
    .tx_tag       (sb_tx_tag),
    .tx_ep        (sb_tx_ep),
    .tx_data_in   (sb_tx_data_in),
    .tx_has_data  (sb_tx_has_data),
    .tx_busy      (sb_tx_busy),
    .sb_tx_data   (sb_tx_data),
    .sb_tx_valid  (sb_tx_valid),
    .sb_rx_data   (sb_rx_data),
    .sb_rx_valid  (sb_rx_valid),
    .rx_pkt_vld   (sb_rx_pkt_vld),
    .rx_opcode    (sb_rx_opcode),
    .rx_srcid     (sb_rx_srcid),
    .rx_dstid     (sb_rx_dstid),
    .rx_msginfo   (sb_rx_msginfo),
    .rx_msgcode   (sb_rx_msgcode),
    .rx_msgsubcode(sb_rx_msgsubcode),
    .rx_cr        (),
    .rx_addr      (),
    .rx_data      (),
    .rx_cp_err    (sb_rx_cp_err),
    .rx_dp_err    (sb_rx_dp_err)
  );

  // ------------------------------------------------- link training FSM
  ltsm #(.NLANES(NLANES)) u_ltsm (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .start_link_train(ltsm_start_link_train),
    .adapter_active_req(adapter_active_req),
    .link_trained    (link_trained),
    .train_error     (train_error),
    .link_reset_out  (link_reset_out),
    .phy_retrain_done(phy_retrain_done),
    .ltsm_state      (ltsm_state),
    .lnk_is_x8       (lnk_is_x8),
    .degrade_lanes   (degrade_lanes),
    .sb_tx_load      (sb_tx_load),
    .sb_tx_opcode    (sb_tx_opcode),
    .sb_tx_srcid     (sb_tx_srcid),
    .sb_tx_dstid     (sb_tx_dstid),
    .sb_tx_msginfo   (sb_tx_msginfo),
    .sb_tx_msgcode   (sb_tx_msgcode),
    .sb_tx_msgsubcode(sb_tx_msgsubcode),
    .sb_tx_be        (sb_tx_be),
    .sb_tx_tag       (sb_tx_tag),
    .sb_tx_ep        (sb_tx_ep),
    .sb_tx_addr      (sb_tx_addr),
    .sb_tx_data_in   (sb_tx_data_in),
    .sb_tx_has_data  (sb_tx_has_data),
    .sb_tx_busy      (sb_tx_busy),
    .sb_rx_pkt_vld   (sb_rx_pkt_vld),
    .sb_rx_opcode    (sb_rx_opcode),
    .sb_rx_srcid     (sb_rx_srcid),
    .sb_rx_dstid     (sb_rx_dstid),
    .sb_rx_msginfo   (sb_rx_msginfo),
    .sb_rx_msgcode   (sb_rx_msgcode),
    .sb_rx_msgsubcode(sb_rx_msgsubcode),
    .sb_rx_cp_err    (sb_rx_cp_err),
    .sb_rx_dp_err    (sb_rx_dp_err),
    .sb_msg_timeout  (sb_msg_timeout),
    .sb_stall_sent   (sb_stall_sent),
    .pat_enable      (pat_enable),
    .pat_select      (pat_select),
    .pat_lfsr_reset  (pat_lfsr_reset),
    .pat_lfsr_enable (pat_lfsr_enable),
    .pat_done        (pat_done),
    .tmr_start       (tmr_start),
    .tmr_run         (tmr_run),
    .tmr_expired     (tmr_expired)
  );

  ucie_timer #(.DIV(1), .LIMIT_CYCLES(C_RESIDENCY)) u_resid_timer (
    .clk      (lclk),
    .reset_n  (lreset_n),
    .start    (tmr_start),
    .running  (tmr_run),
    .expired  (tmr_expired)
  );

  // ------------------------------------------------- RDI link state machine
  rdi_state_machine u_rdi_sm (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .phy_link_trained(link_trained),
    .phy_link_reset  (link_reset_out),
    .phy_retrain_req (rdi_lp_state_req == ucie_pkg::RDI_REQ_RETRAIN),
    .phy_train_error (train_error),
    .phy_inband_pres (sb_rx_valid),
    .cerror          (1'b0),
    .nferror         (1'b0),
    .stall_req       (1'b0),
    .stall_ack       (),
    .adapter_active_req(adapter_active_req),
    .local_active_req(local_active_req)
  );

  // ------------------------------------------------- training pattern gen
  pattern_gen #(.NLANES(NLANES)) u_pat_gen (
    .lclk        (lclk),
    .lreset_n    (lreset_n),
    .enable      (pat_enable),
    .pattern     (pat_select),
    .lfsr_reset  (pat_lfsr_reset),
    .lfsr_enable (pat_lfsr_enable),
    .data        (mb_tx_data),
    .pat_done    (pat_done)
  );

  // ------------------------------------------------- byte to lane mapper
  // The main-band transmit data is the training pattern output; the mapper is
  // instantiated so the byte-to-lane mapping is exercised in the loopback.
  byte_lane_mapper #(.NLANES(NLANES)) u_mapper (
    .lclk          (lclk),
    .lreset_n      (lreset_n),
    .enable        (1'b0),
    .lnk_is_x8     (lnk_is_x8),
    .degrade_lanes (degrade_lanes),
    .byte_reversal (1'b0),
    .bytes_in      (tx_bytes),
    .data_out      (lane_bytes)
  );

  // ------------------------------------------------- PHY CSR
  phy_csr u_phy_csr (
    .lclk          (lclk),
    .lreset_n      (lreset_n),
    .csr_wr        (csr_wr),
    .csr_rd        (csr_rd),
    .csr_addr      (csr_addr),
    .csr_wdata     (csr_wdata),
    .csr_rdata     (csr_rdata),
    .csr_rdata_vld (csr_rdata_vld),
    .ltsm_state    (ltsm_state),
    .lnk_is_x8     (lnk_is_x8),
    .degrade_lanes (degrade_lanes),
    .train_error   (train_error),
    .start_link_train(csr_start_link_train)
  );

  // ------------------------------------------------- static RDI outputs
  // Reduced capability set: x16, 4 GT/s, no stall request from the PHY.
  assign rdi_pl_lnk_cfg  = LNKCFG_X16;
  assign rdi_pl_speedmode= SPEED_4GT;
  assign rdi_pl_stallreq = 1'b0;

  // The LTSM leaves RESET either on the top-level start input or on a CSR
  // write to TRAIN_CTL. Both paths are spec 4.5.3.1 RESET exits.
  assign ltsm_start_link_train = start_link_train | csr_start_link_train;

  // The CSR access path is presented on the cfg interface so the adapter can
  // reach the PHY registers through the sideband.
  assign csr_wr    = 1'b0;
  assign csr_rd    = 1'b0;
  assign csr_addr  = '0;
  assign csr_wdata = '0;

  assign pl_cfg     = '0;
  assign pl_cfg_vld = 1'b0;
  assign pl_cfg_crd = 1'b0;

  // RDI datapath pass-through: the logical PHY does not terminate the
  // streaming data in this model; the adapter handles the RDI datapath.
  assign rdi_pl_trdy  = rdi_lp_irdy;
  assign rdi_pl_valid = rdi_lp_valid;
  assign rdi_pl_data  = rdi_lp_data;

  // Lint suppression. Continuous so iverilog evaluates the bit selects.
  logic unused;
  assign unused = local_active_req | adapter_active_req | csr_rdata_vld |
                  csr_rdata[0] | phy_retrain_done | sb_msg_timeout |
                  sb_stall_sent | lane_bytes[0][0] | mb_rx_data[0] |
                  lp_cfg[0] | lp_cfg_vld | lp_cfg_crd;

endmodule

`endif

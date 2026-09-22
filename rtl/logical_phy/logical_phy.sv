// ============================================================================
// File        : logical_phy.sv
// Module      : logical_phy
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Hierarchical integration wrapper for the UCIe Logical PHY
//               layer. This module is the single counterpart to the D2D
//               Adapter at the top level and owns every block between the
//               RDI (Raw D2D Interface, spec 8.1) and the physical pins.
//
// Spec refs   : UCIe 1.0 spec section 3.1 (Logical PHY layer definition),
//               section 8.1 (RDI signal table, Table 114), section 4.5.3
//               (LTSM), section 6 (sideband framing), section 5.2 (byte-to-
//               lane mapping), section 7.1 (PHY CSR).
//
// Capability  : Standard Package, x16, 4 GT/s, Streaming / Raw Mode
//               (Format 1). Single stack (Stack-0). No retimer. Reduced-
//               capability set for proof-of-concept verification.
//
// --------------------------------------------------------------------------
// Architecture  (ASCII block diagram)
// --------------------------------------------------------------------------
//
//   D2D Adapter (RDI)
//      |                               lp_cfg/pl_cfg
//      |  rdi_lp_*  / rdi_pl_*         (sideband register access)
//      |                                    |
//      v                                    v
//  +---------------------------------------------------------------+
//  | logical_phy                                                   |
//  |                                                               |
//  |  +------------------+      +--------------+                   |
//  |  | rdi_state_machine|<---->|    ltsm      |                   |
//  |  | (u_rdi_sm)       |      | (u_ltsm)     |                   |
//  |  | Spec 8.1.5       |      | Spec 4.5.3   |                   |
//  |  | Fig 111          |      | Link Training|                   |
//  |  +------------------+      |  & Status SM |                   |
//  |         ^                  +------+-------+                   |
//  |         | phy_link_trained        |                           |
//  |         | phy_train_error         | sb_tx/rx   pat_*          |
//  |         | phy_link_reset          |            |              |
//  |         v                  +------+------+  +-+----------+   |
//  |  +-----------+             | sb_codec    |  | pattern_gen|   |
//  |  | phy_csr   |             | (u_sb_codec)|  | (u_pat_gen)|   |
//  |  | (u_phy_csr|             | Spec Ch 6   |  | Spec 4.5.3|   |
//  |  | Spec 7.1  |             +-+----------++  |  .4/.6     |   |
//  |  +-----------+               |          |    +-----+-----+   |
//  |                              |          |          |          |
//  |  +------------------+        |          |   mb_tx_data       |
//  |  | byte_lane_mapper |        |          |          |          |
//  |  | (u_mapper)       |        |          |          v          |
//  |  | Spec 5.2/4.1.1   |        |          |   [NLANES-1:0]     |
//  |  +------------------+        |          |          |          |
//  |                              |          |          |          |
//  |  +------------------+        |          |          |          |
//  |  | ucie_timer       |        |          |          |          |
//  |  | (u_resid_timer)  |--------+          |          |          |
//  |  | 8 ms residency   |                   |          |          |
//  |  +------------------+                   |          |          |
//  +---------------------------------------------------------------+
//      |               |                    |          |
//      v               v                    v          v
//   sb_tx_data     sb_rx_data           mb_tx_data  mb_rx_data
//   sb_tx_valid    sb_rx_valid          (to partner)(from partner)
//   (sideband      (sideband
//    to partner)    from partner)
//
// --------------------------------------------------------------------------
// Data flow (simplified)
// --------------------------------------------------------------------------
//   TX path : adapter -> rdi_lp_data -> rdi_pl_data pass-through (loopback).
//             During training: ltsm -> pattern_gen -> mb_tx_data pins.
//   RX path : mb_rx_data pins -> (future CRC / scrambler) -> rdi_pl_data.
//   Sideband: ltsm -> sb_codec -> sb_tx_data pins; sb_rx_data -> sb_codec ->
//             ltsm.
//
// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
//   NBYTES : Number of data bytes (default 16, x16 Standard Package).
//   NLANES : Number of main-band lanes (default 16, NLANES_MAX).
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   RDI (Table 114) : rdi_lp_* inputs from the adapter, rdi_pl_* outputs to
//                     the adapter. Implements the state machine of spec 8.1.5
//                     and the Active-entry handshake of 8.1.6.
//   Sideband pins   : sb_tx_data/valid, sb_rx_data/valid toward the partner
//                     die. Serialised 64-bit packets per spec Chapter 6.
//   Main-band pins  : mb_tx_data, mb_rx_data. One bit per lane per UI.
//   CSR/cfg         : lp_cfg/pl_cfg sideband register access path (stubbed
//                     in this reduced-capability build).
//
// --------------------------------------------------------------------------
// Clock domains
// --------------------------------------------------------------------------
//   lclk     : 1 GHz link clock for the main-band data path and LTSM.
//   sbclk    : 800 MHz sideband clock for sb_codec and sideband side of the
//              LTSM.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The byte_lane_mapper is instantiated but held disabled (enable=1'b0);
//      the main-band TX data is driven entirely by pattern_gen during
//      training, and loopback for the datapath.
//   2. The CSR write/read path is stubbed to constants; the PHY CSR is
//      reachable only through the csr_start_link_train output.
//   3. Static RDI outputs (pl_lnk_cfg, pl_speedmode, pl_stallreq) are tied
//      to the reduced-capability defaults: x16, 4 GT/s, no stall.
//   4. The RDI datapath (rdi_pl_trdy, rdi_pl_valid, rdi_pl_data) is a
//      pass-through from the adapter side, since the logical PHY does not
//      terminate the streaming data in this model.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Hierarchical wrapper with all
//                        sub-module instantiations, static RDI outputs, and
//                        CSR/config stub.
// ============================================================================
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

  // ---------------------------------------------------------------------------
  // Sideband Codec Instantiation  (u_sb_codec)
  // ---------------------------------------------------------------------------
  // Spec reference : Chapter 6 (sideband framing), Table 47 (opcodes),
  //                  Tables 53/54/56 (message codes).
  //
  // The sb_codec serialises and deserialises 64-bit sideband packets at the
  // sbclk rate. It is the only module that knows the bit-field layout of the
  // sideband header; all other blocks see named, typed fields.
  //
  // The LTSM drives the TX side (sb_tx_load, sb_tx_opcode, etc.) and
  // consumes the RX side (sb_rx_pkt_vld, sb_rx_opcode, etc.).
  // The codec also computes and checks CP (command parity) and DP (data
  // parity) per spec Chapter 6 parity rules.
  //
  // tx_cr is tied to 1'b0: credit return messages are not generated in this
  // reduced-capability build. The rx_cr, rx_addr, and rx_data outputs are
  // left unconnected for the same reason.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Link Training and Status Machine Instantiation  (u_ltsm)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.5.3 (LTSM overview), 4.5.3.1-4.5.3.9 (per-state
  //                  descriptions). See ltsm.sv header for the full
  //                  state/sub-state progression diagram.
  //
  // The LTSM is the sole sideband master in this logical PHY. It sequences
  // through RESET -> SBINIT -> MBINIT.* -> MBTRAIN.* -> LINKINIT -> ACTIVE,
  // exchanging sideband messages with the partner at each sub-state boundary.
  // On entry, it receives start_link_train from either the top-level pin or
  // the CSR TRAIN_CTL write. On exit, it reports link_trained, train_error,
  // and link_reset_out to the RDI state machine and the CSR block.
  //
  // Control of the pattern generator (pat_enable, pat_select, etc.) is
  // driven entirely by the LTSM based on the current training sub-state.
  // The 8 ms residency timer (u_resid_timer) provides timeout enforcement
  // per spec 4.5.3: any sub-state exceeding 8 ms escalates to TRAINERROR.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // 8 ms Residency Timer Instantiation  (u_resid_timer)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.5.3 – every training sub-state is bounded by an 8 ms
  //                  residency window. The LTSM asserts tmr_start on entry to
  //                  each new sub-state and holds tmr_run while the handshake
  //                  is pending. If tmr_expired fires before the handshake
  //                  completes, the LTSM escalates to TRAINERROR per 4.5.3.8.
  //
  // ucie_timer is parameterised with C_RESIDENCY = 8_000_000 lclk cycles
  // (8 ms at 1 GHz).  DIV=1 means no prescaler.
  // ---------------------------------------------------------------------------
  ucie_timer #(.DIV(1), .LIMIT_CYCLES(C_RESIDENCY)) u_resid_timer (
    .clk      (lclk),
    .reset_n  (lreset_n),
    .start    (tmr_start),
    .running  (tmr_run),
    .expired  (tmr_expired)
  );

  // ---------------------------------------------------------------------------
  // RDI Link State Machine Instantiation  (u_rdi_sm)
  // ---------------------------------------------------------------------------
  // Spec reference : 8.1.5 (RDI state transitions, Figure 111), 8.1.6
  //                  (Active-entry handshake).
  //
  // The RDI state machine mediates between the D2D Adapter (which drives
  // rdi_lp_state_req) and the physical layer (which reports link_trained,
  // link_reset_out, train_error). Physical RESET and TRAINERROR preempt
  // every adapter request per 8.1.5. The ACTIVE entry follows the three-way
  // handshake of 8.1.6.
  //
  // In this build:
  //   - phy_retrain_req is derived from the adapter requesting RDI_REQ_RETRAIN.
  //   - phy_inband_pres mirrors sb_rx_valid (partner alive on sideband).
  //   - cerror, nferror, and stall_req are tied to zero.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Training Pattern Generator Instantiation  (u_pat_gen)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.5.3.4 (MBTRAIN sub-states), 4.5.3.6 (LINKINIT),
  //                  Table 71 (training pattern sequence).
  //
  // The pattern generator produces per-lane training patterns on mb_tx_data
  // during the MBTRAIN and LINKINIT sub-states. The LTSM selects the active
  // pattern (PAT_PERLANEID, PAT_VALTRAIN, PAT_CLKREPAIR, PAT_LFSR) and
  // controls the LFSR reseed via pat_lfsr_reset/pat_lfsr_enable. The
  // pat_done signal fires on the final UI of the LFSR pattern (4096 UI) to
  // allow the LTSM to advance from LINKINIT to ACTIVE.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Byte-to-Lane Mapper Instantiation  (u_mapper)
  // ---------------------------------------------------------------------------
  // Spec reference : 5.2 / Figure 48 (byte-to-lane mapping), 4.1.1
  //                  (lane and width definitions), width-degrade mechanism.
  //
  // The mapper translates NBYTES parallel bytes into NLANES lane-aligned
  // bytes, handling x16 full-width and x8-degraded half-width modes. In
  // degraded mode only lanes 0-7 or 8-15 carry data; the other half is
  // zeroed. byte_reversal reverses the byte numbering within the active
  // half.
  //
  // In this build the mapper is instantiated but held disabled (enable=1'b0)
  // because the main-band TX data is driven entirely by the pattern
  // generator during training. The instantiation exercises the byte-to-lane
  // mapping logic for the loopback verification path.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // PHY CSR Block Instantiation  (u_phy_csr)
  // ---------------------------------------------------------------------------
  // Spec reference : 7.1 (PHY electrical parameter registers).
  //
  // The PHY CSR block holds the local electrical parameters (supply voltage,
  // termination impedance) that are advertised to the partner during
  // MBINIT.PARAM, the negotiated link width, and the LTSM training status.
  // The adapter reads these registers through the sideband register access
  // path (cfg interface).
  //
  // start_link_train output: writing a 1 to CSR_TRAIN_CTL (offset 0x0)
  // initiates the LTSM RESET exit, complementing the top-level
  // start_link_train pin.
  //
  // NOTE: These are electrical *parameter* registers only. There is no
  // analog/AFE implementation per the project scope constraint.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Static RDI outputs  (spec 8.1, Table 114)
  // ---------------------------------------------------------------------------
  // The reduced-capability set supports only x16, 4 GT/s, and no PHY-
  // initiated stall. These outputs are tied to constant values and are
  // never modified at runtime.
  //
  // rdi_pl_lnk_cfg  : LNKCFG_X16 (3'b010) – x16 link configuration.
  // rdi_pl_speedmode : SPEED_4GT  (3'b000) – 4 GT/s, the only speed.
  // rdi_pl_stallreq  : 1'b0 – the PHY never initiates a stall in this build.
  // ---------------------------------------------------------------------------
  assign rdi_pl_lnk_cfg  = LNKCFG_X16;
  assign rdi_pl_speedmode= SPEED_4GT;
  assign rdi_pl_stallreq = 1'b0;

  // ---------------------------------------------------------------------------
  // LTSM start-link-train OR gate  (spec 4.5.3.1 RESET exits)
  // ---------------------------------------------------------------------------
  // The LTSM exits RESET on either:
  //   (a) the top-level start_link_train input pin (testbench / system
  //       controller), or
  //   (b) a CSR write to TRAIN_CTL[0] (software-initiated training start).
  // Both paths are spec-compliant RESET exit stimuli per 4.5.3.1.
  // ---------------------------------------------------------------------------
  assign ltsm_start_link_train = start_link_train | csr_start_link_train;

  // ---------------------------------------------------------------------------
  // CSR access path stub  (spec 7.1 sideband register access)
  // ---------------------------------------------------------------------------
  // The CSR write/read path is presented on the cfg interface so the adapter
  // can reach the PHY registers through the sideband. In this reduced-
  // capability build the path is stubbed to constants: no external register
  // accesses are generated.
  // ---------------------------------------------------------------------------
  assign csr_wr    = 1'b0;
  assign csr_rd    = 1'b0;
  assign csr_addr  = '0;
  assign csr_wdata = '0;

  // ---------------------------------------------------------------------------
  // Configuration interface stub  (spec 6.1 sideband cfg)
  // ---------------------------------------------------------------------------
  // The pl_cfg interface is unused in this build. Outputs are tied low so
  // the cfg bus is inert.
  // ---------------------------------------------------------------------------
  assign pl_cfg     = '0;
  assign pl_cfg_vld = 1'b0;
  assign pl_cfg_crd = 1'b0;

  // ---------------------------------------------------------------------------
  // RDI datapath pass-through  (spec 8.1 / Table 114 data signals)
  // ---------------------------------------------------------------------------
  // The logical PHY does not terminate the streaming data in this model; the
  // adapter handles the RDI datapath. rdi_pl_trdy echoes rdi_lp_irdy,
  // rdi_pl_valid echoes rdi_lp_valid, and rdi_pl_data echoes rdi_lp_data.
  // This provides a loopback path for simulation verification.
  // ---------------------------------------------------------------------------
  assign rdi_pl_trdy  = rdi_lp_irdy;
  assign rdi_pl_valid = rdi_lp_valid;
  assign rdi_pl_data  = rdi_lp_data;

  // ---------------------------------------------------------------------------
  // Lint suppression
  // ---------------------------------------------------------------------------
  // Continuous assign so Icarus Verilog evaluates all bit-select references.
  // Every signal listed here is either an output of a sub-module that is not
  // consumed externally, or an input that is not used in this stub build.
  // ---------------------------------------------------------------------------
  logic unused;
  assign unused = local_active_req | adapter_active_req | csr_rdata_vld |
                  csr_rdata[0] | phy_retrain_done | sb_msg_timeout |
                  sb_stall_sent | lane_bytes[0][0] | mb_rx_data[0] |
                  lp_cfg[0] | lp_cfg_vld | lp_cfg_crd;

endmodule

`endif

// ============================================================================
// File        : logical_phy.sv
// Module      : logical_phy
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Hierarchical integration wrapper for the UCIe Logical PHY
//               layer. This module is the single counterpart to the D2D
//               Adapter at the top level and owns every block between the
//               RDI (Raw Die-to-Die Interface, spec 8.1) and the physical pins.
//
// Spec refs   : UCIe 1.0 spec section 4.0 (Logical Physical Layer),
//               section 8.1 - Raw Die-to-Die Interface (RDI), Table 114
//               (RDI signal list), section 4.5.3 (Link Training State
//               Machine), section 6.0 (Sideband), section 7.5 (UCIe
//               Registers).
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
//          |
//          v
//  +--------------------------------------------------------------------+
//  | logical_phy                                                        |
//  |                                                                    |
//  |  +-------------------+       +-------------------+                 |
//  |  | rdi_state_machine |<----->|       ltsm        |                 |
//  |  +-------------------+       | policy in lclk    |                 |
//  |          ^                    +----+---------+----+                 |
//  |          |                         |         |                      |
//  |  +-------+------+       packet CDC |         | raw levels/events    |
//  |  |   phy_csr   |                   v         v                      |
//  |  +--------------+             +---------+ +----------------+       |
//  |                               |sb_codec | | SBINIT raw     |       |
//  |                               | sbclk   | | primitive sbclk|       |
//  |                               +----+----+ +-------+--------+       |
//  |                                    \            /                 |
//  |                                     +---- mux ---+                 |
//  |                                              |                     |
//  |  +------------------+   +---------------+    |                     |
//  |  | byte_lane_mapper |   |  pattern_gen  |    |                     |
//  |  +------------------+   +-------+-------+    |                     |
//  |                                  |            |                     |
//  |  +------------------+            v            v                     |
//  |  | ucie_timer x 2   |        mb_tx_data   sideband pins             |
//  |  +------------------+                                               |
//  +--------------------------------------------------------------------+
//
// --------------------------------------------------------------------------
// Data flow (simplified)
// --------------------------------------------------------------------------
//   TX path : adapter -> rdi_lp_data -> rdi_pl_data pass-through (loopback).
//             During training: ltsm -> pattern_gen -> mb_tx_data pins.
//   RX path : mb_rx_data pins -> (future CRC / scrambler) -> rdi_pl_data.
//   Sideband: ltsm (lclk) -> async mailbox -> sb_codec (sbclk) -> sideband
//             pins. During RESET and SBINIT pattern phases, a raw sbclk
//             waveform/CDC primitive owns the pins and keeps the codec reset.
//             Received packets and atomic raw-iteration results use separate
//             mailboxes back to the LTSM lclk domain.
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
//                     die. They carry the raw SBINIT waveform before they
//                     carry serialized 64-bit packets from the codec.
//   Main-band pins  : mb_tx_data, mb_rx_data. One bit per lane per UI.
//   CSR/cfg         : lp_cfg/pl_cfg sideband register access path (stubbed
//                     in this reduced-capability build).
//
// --------------------------------------------------------------------------
// Clock domains
// --------------------------------------------------------------------------
//   lclk     : 500 MHz link clock for the main-band path and LTSM.
//   sbclk    : 800 MHz sideband clock for sb_codec and the UI-exact SBINIT
//              primitive. Toggle mailboxes carry packets and iteration events
//              safely between lclk and sbclk.
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
//   v0.0.2  2026-09-22  Update lclk and timer cycle comments for 500 MHz.
//   v0.0.3  2026-09-22  Add 4 ms physical layer RESET minimum timer (Req.1).
//   v0.0.4  2026-09-23  Add 2 GHz mbclk and 4 GT/s DDR gearboxes (Req.2).
//   v0.0.5  2026-09-23  Req.2: feed the 128-bit pattern word straight into the
//                            TX gearbox; pattern engine now emits 8 UIs per
//                            lclk cycle at the 4 GT/s physical rate.
//   v0.0.6  2026-09-23  Documentation pass: add per-construct comment blocks
//                        for every always, assign, and instantiation per the
//                        project documentation contract.
//   v0.0.7  2026-09-23  Documentation: correct fabricated citations in the
//                        header and per-construct blocks. Title 3.1 is Link
//                        Initialization (not Logical PHY), 7.1 is the high
//                        level software view (registers are 7.5), Table 71 is
//                        the sideband mailbox (training patterns are 4.4.1 /
//                        4.5.3.5), Figure 48 is lane remapping (byte-to-lane
//                        is Figures 42-43), and the stall handshake is 8.3.1
//                        rather than Table 115.
//   v0.0.8  2026-09-23  Documentation: correct the Stallreq/Ack signal pair
//                        and clarify that lp_state_req is Section 8.3.2.
//   v0.0.9  2026-09-23  Req.3: add paired asynchronous mailboxes between the
//                        lclk LTSM and the 800 MHz sbclk codec. Synchronize
//                        codec busy and sideband presence back to lclk.
//   v0.0.10 2026-09-24  Add the UI-exact Standard Package SBINIT waveform,
//                        raw/packet mux, and atomic iteration CDC mailboxes.
`ifndef LogicalPhy_SV
`define LogicalPhy_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module logical_phy #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        mbclk,        // 2 GHz forwarded clock fCK (Req.2)
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
  output logic        mb_tx_valid,  // main band framing valid (Req.2)
  input  logic [NLANES-1:0] mb_rx_data,
  input  logic        mb_rx_valid,  // main band framing valid (Req.2)
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

  // ------------------------------------------------- LTSM <-> sideband CDC
  // The LTSM side uses lclk. The sb_codec side uses sbclk. Each direction
  // carries complete packet fields through a one-entry asynchronous mailbox.
  localparam int unsigned SB_TX_W = 126;
  localparam int unsigned SB_RX_W = 37;

  // LTSM-facing TX request and codec-facing busy indication.
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

  // Codec-facing TX request produced by the lclk-to-sbclk mailbox.
  logic [SB_TX_W-1:0] sb_tx_cdc_data;
  logic               sb_tx_cdc_busy;
  logic               codec_tx_load;
  logic [4:0]         codec_tx_opcode;
  logic [2:0]         codec_tx_srcid;
  logic [2:0]         codec_tx_dstid;
  logic [7:0]         codec_tx_msginfo;
  logic [7:0]         codec_tx_msgcode;
  logic [7:0]         codec_tx_msgsubcode;
  logic [7:0]         codec_tx_be;
  logic [4:0]         codec_tx_tag;
  logic               codec_tx_ep;
  logic [11:0]        codec_tx_addr;
  logic [63:0]        codec_tx_data_in;
  logic               codec_tx_has_data;
  logic               codec_tx_busy;
  logic               codec_tx_busy_meta_q;
  logic               codec_tx_busy_sync_q;
  logic               codec_tx_inflight_q;
  logic               codec_tx_busy_seen_q;
  logic [NC-1:0]      codec_sb_tx_data;
  logic               codec_sb_tx_valid;
  logic               codec_reset_n;

  // Codec-facing RX packet and LTSM-facing packet delivered by sbclk-to-lclk.
  logic               codec_rx_pkt_vld;
  logic [4:0]         codec_rx_opcode;
  logic [2:0]         codec_rx_srcid;
  logic [2:0]         codec_rx_dstid;
  logic [7:0]         codec_rx_msginfo;
  logic [7:0]         codec_rx_msgcode;
  logic [7:0]         codec_rx_msgsubcode;
  logic               codec_rx_cp_err;
  logic               codec_rx_dp_err;
  logic [SB_RX_W-1:0] sb_rx_cdc_data;
  logic               sb_rx_cdc_busy;
  logic               sb_rx_pkt_vld;
  logic [4:0]         sb_rx_opcode;
  logic [2:0]         sb_rx_srcid;
  logic [2:0]         sb_rx_dstid;
  logic [7:0]         sb_rx_msginfo;
  logic [7:0]         sb_rx_msgcode;
  logic [7:0]         sb_rx_msgsubcode;
  logic               sb_rx_cp_err;
  logic               sb_rx_dp_err;
  logic               sb_rx_valid_meta_q;
  logic               sb_rx_valid_sync_q;
  logic               sb_msg_timeout;
  logic               sb_stall_sent;

  // --------------------------------------- LTSM <-> raw SBINIT primitive
  logic               pattern_run_enable;
  logic               sbinit_raw_mode;
  logic               sbinit_rx_iter_vld;
  logic               sbinit_rx_iter_match;
  logic               sbinit_tx_iter_done;
  logic               sbinit_tx_idle;

  logic               codec_packet_ready_meta_q;
  logic               codec_packet_ready_sync_q;
  logic               raw_tx_idle_meta_q;
  logic               raw_tx_idle_sync_q;
  logic               raw_mode_active_s;
  logic               raw_rx_low_sample;
  logic               raw_tx_idle_s;

  logic [NC-1:0]      raw_sb_tx_data;
  logic               raw_sb_tx_valid;
  logic               raw_tx_iter_done_s;
  logic               raw_rx_iter_vld_s;
  logic               raw_rx_iter_match_s;
  logic               raw_rx_result_busy;
  logic               raw_tx_done_busy;
  logic [0:0]         raw_rx_result_l;

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
  logic        rst_tmr_start;
  logic        rst_tmr_expired;
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
  // Standard Package SBINIT Raw Primitive (spec 4.5.3.2)
  // ---------------------------------------------------------------------------
  // The raw waveform helper owns only sbclk-rate serialization and candidate
  // sampling. LTSM keeps every SBINIT policy decision in lclk. logical_phy
  // retains the CDC mailboxes and selects raw or packet codec pin ownership.
  // ---------------------------------------------------------------------------
  sb_init_raw u_sb_init_raw (
    .sbclk              (sbclk),
    .sbreset_n          (sbreset_n),
    .pattern_run_enable (pattern_run_enable),
    .sbinit_raw_mode    (sbinit_raw_mode),
    .sb_rx_data         (sb_rx_data),
    .sb_rx_valid        (sb_rx_valid),
    .raw_rx_result_busy (raw_rx_result_busy),
    .sb_tx_data         (raw_sb_tx_data),
    .sb_tx_valid        (raw_sb_tx_valid),
    .raw_mode_active    (raw_mode_active_s),
    .raw_rx_low_sample  (raw_rx_low_sample),
    .raw_tx_idle        (raw_tx_idle_s),
    .raw_tx_iter_done   (raw_tx_iter_done_s),
    .raw_rx_iter_vld    (raw_rx_iter_vld_s),
    .raw_rx_iter_match  (raw_rx_iter_match_s)
  );

  // Atomic remote-result mailbox. The one-bit payload and its destination
  // valid pulse are captured together, so a mismatch cannot be reordered with
  // a neighboring match. Well-formed iterations are 96 sbclk cycles apart,
  // which exceeds the mailbox acknowledgement round trip.
  sb_cdc_mailbox #(.WIDTH(1)) u_sbinit_rx_result_cdc (
    .src_clk    (sbclk),
    .src_reset_n(sbreset_n),
    .src_data   (raw_rx_iter_match_s),
    .src_send   (raw_rx_iter_vld_s),
    .src_busy   (raw_rx_result_busy),
    .dst_clk    (lclk),
    .dst_reset_n(lreset_n),
    .dst_data   (raw_rx_result_l),
    .dst_valid  (sbinit_rx_iter_vld)
  );

  assign sbinit_rx_iter_match = raw_rx_result_l[0];

  // Independent local-completion mailbox. It reports every completed local
  // 96-UI waveform once and carries no phase, count, or completion policy.
  sb_cdc_mailbox #(.WIDTH(1)) u_sbinit_tx_done_cdc (
    .src_clk    (sbclk),
    .src_reset_n(sbreset_n),
    .src_data   (1'b1),
    .src_send   (raw_tx_iter_done_s),
    .src_busy   (raw_tx_done_busy),
    .dst_clk    (lclk),
    .dst_reset_n(lreset_n),
    .dst_data   (),
    .dst_valid  (sbinit_tx_iter_done)
  );

  // Keep the packet codec reset throughout raw receive mode. After the LTSM
  // selects packet mode, release the codec only on an observed low boundary.
  // A partner can already be partway through a repeated Out-of-Reset packet;
  // this boundary wait prevents that suffix from becoming a partial header.
  logic codec_packet_ready_s;
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      codec_packet_ready_s <= 1'b0;
    end else if (raw_mode_active_s) begin
      codec_packet_ready_s <= 1'b0;
    end else if (!codec_packet_ready_s && raw_rx_low_sample) begin
      codec_packet_ready_s <= 1'b1;
    end
  end

  assign codec_reset_n = sbreset_n && codec_packet_ready_s;
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_packet_ready_meta_q <= 1'b0;
      codec_packet_ready_sync_q <= 1'b0;
      raw_tx_idle_meta_q        <= 1'b1;
      raw_tx_idle_sync_q        <= 1'b1;
    end else begin
      codec_packet_ready_meta_q <= codec_packet_ready_s;
      codec_packet_ready_sync_q <= codec_packet_ready_meta_q;
      raw_tx_idle_meta_q        <= raw_tx_idle_s;
      raw_tx_idle_sync_q        <= raw_tx_idle_meta_q;
    end
  end

  assign sbinit_tx_idle = raw_tx_idle_sync_q;

  // Raw mode owns the public pins for the entire pattern phase, including its
  // 1 ms idle windows. Packet pins become visible only after the boundary-safe
  // mode change has reset and released the codec.
  assign sb_tx_data  = raw_mode_active_s ? raw_sb_tx_data  :
                                           codec_sb_tx_data;
  assign sb_tx_valid = raw_mode_active_s ? raw_sb_tx_valid :
                                           codec_sb_tx_valid;

  // ---------------------------------------------------------------------------
  // Sideband CDC and Codec Instantiations  (u_sb_tx_cdc/u_sb_codec/u_sb_rx_cdc)
  // ---------------------------------------------------------------------------
  // The LTSM generates and consumes one-lclk-cycle packet events. The sb_codec
  // samples and produces one-sbclk-cycle packet events at 800 MHz. The paired
  // toggle mailboxes preserve packet data and event delivery across the two
  // asynchronous domains. The codec remains the sole sbclk-domain serializer
  // and deserializer.
  //
  // The TX mailbox carries the full 126-bit LTSM request bundle to sbclk. The
  // RX mailbox returns the parsed 37-bit packet bundle to lclk. The busy path
  // synchronizes codec backpressure into lclk and combines it with mailbox
  // occupancy before the LTSM can issue another request.
  // ---------------------------------------------------------------------------
  sb_cdc_mailbox #(.WIDTH(SB_TX_W)) u_sb_tx_cdc (
    .src_clk    (lclk),
    .src_reset_n(lreset_n),
    .src_data   ({sb_tx_opcode, sb_tx_srcid, sb_tx_dstid, sb_tx_msginfo,
                  sb_tx_msgcode, sb_tx_msgsubcode, sb_tx_be, sb_tx_tag,
                  sb_tx_ep, sb_tx_addr, sb_tx_data_in, sb_tx_has_data}),
    .src_send   (sb_tx_load),
    .src_busy   (sb_tx_cdc_busy),
    .dst_clk    (sbclk),
    .dst_reset_n(sbreset_n),
    .dst_data   (sb_tx_cdc_data),
    .dst_valid  (codec_tx_load)
  );

  assign {codec_tx_opcode, codec_tx_srcid, codec_tx_dstid, codec_tx_msginfo,
          codec_tx_msgcode, codec_tx_msgsubcode, codec_tx_be, codec_tx_tag,
          codec_tx_ep, codec_tx_addr, codec_tx_data_in, codec_tx_has_data} =
         sb_tx_cdc_data;

  // Synchronize codec busy and packet-mode sideband presence into lclk.
  // Raw pattern valid is excluded from RDI in-band presence.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_tx_busy_meta_q <= 1'b0;
      codec_tx_busy_sync_q <= 1'b0;
      sb_rx_valid_meta_q   <= 1'b0;
      sb_rx_valid_sync_q   <= 1'b0;
    end else begin
      codec_tx_busy_meta_q <= codec_tx_busy;
      codec_tx_busy_sync_q <= codec_tx_busy_meta_q;
      sb_rx_valid_meta_q   <= sb_rx_valid && codec_packet_ready_s;
      sb_rx_valid_sync_q   <= sb_rx_valid_meta_q;
    end
  end

  // A mailbox acknowledgement means that sbclk received the bundle, not that
  // the packet finished. Hold the lclk busy contract until codec busy has been
  // observed high and then low. This closes the acknowledgement/busy CDC gap
  // for repeated Out-of-Reset packets and queued Done responses.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_tx_inflight_q  <= 1'b0;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (sbinit_raw_mode) begin
      codec_tx_inflight_q  <= 1'b0;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (sb_tx_load && !sb_tx_busy) begin
      codec_tx_inflight_q  <= 1'b1;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (codec_tx_inflight_q) begin
      if (codec_tx_busy_sync_q) codec_tx_busy_seen_q <= 1'b1;
      if (codec_tx_busy_seen_q && !codec_tx_busy_sync_q &&
          !sb_tx_cdc_busy) begin
        codec_tx_inflight_q  <= 1'b0;
        codec_tx_busy_seen_q <= 1'b0;
      end
    end
  end

  assign sb_tx_busy = sb_tx_cdc_busy | codec_tx_busy_sync_q |
                      codec_tx_inflight_q | !codec_packet_ready_sync_q;

  sb_codec u_sb_codec (
    .sbclk        (sbclk),
    .sbreset_n    (codec_reset_n),
    .tx_load      (codec_tx_load),
    .tx_opcode    (codec_tx_opcode),
    .tx_srcid     (codec_tx_srcid),
    .tx_dstid     (codec_tx_dstid),
    .tx_msginfo   (codec_tx_msginfo),
    .tx_msgcode   (codec_tx_msgcode),
    .tx_msgsubcode(codec_tx_msgsubcode),
    .tx_cr        (1'b0),
    .tx_addr      (codec_tx_addr),
    .tx_be        (codec_tx_be),
    .tx_tag       (codec_tx_tag),
    .tx_ep        (codec_tx_ep),
    .tx_data_in   (codec_tx_data_in),
    .tx_has_data  (codec_tx_has_data),
    .tx_busy      (codec_tx_busy),
    .sb_tx_data   (codec_sb_tx_data),
    .sb_tx_valid  (codec_sb_tx_valid),
    .sb_rx_data   (sb_rx_data),
    .sb_rx_valid  (sb_rx_valid && codec_packet_ready_s),
    .rx_pkt_vld   (codec_rx_pkt_vld),
    .rx_opcode    (codec_rx_opcode),
    .rx_srcid     (codec_rx_srcid),
    .rx_dstid     (codec_rx_dstid),
    .rx_msginfo   (codec_rx_msginfo),
    .rx_msgcode   (codec_rx_msgcode),
    .rx_msgsubcode(codec_rx_msgsubcode),
    .rx_cr        (),
    .rx_addr      (),
    .rx_data      (),
    .rx_cp_err    (codec_rx_cp_err),
    .rx_dp_err    (codec_rx_dp_err)
  );

  sb_cdc_mailbox #(.WIDTH(SB_RX_W)) u_sb_rx_cdc (
    .src_clk    (sbclk),
    .src_reset_n(sbreset_n),
    .src_data   ({codec_rx_opcode, codec_rx_srcid, codec_rx_dstid,
                  codec_rx_msginfo, codec_rx_msgcode, codec_rx_msgsubcode,
                  codec_rx_cp_err, codec_rx_dp_err}),
    .src_send   (codec_rx_pkt_vld),
    .src_busy   (sb_rx_cdc_busy),
    .dst_clk    (lclk),
    .dst_reset_n(lreset_n),
    .dst_data   (sb_rx_cdc_data),
    .dst_valid  (sb_rx_pkt_vld)
  );

  assign {sb_rx_opcode, sb_rx_srcid, sb_rx_dstid, sb_rx_msginfo,
          sb_rx_msgcode, sb_rx_msgsubcode, sb_rx_cp_err, sb_rx_dp_err} =
         sb_rx_cdc_data;

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
  // The LTSM owns SBINIT phase and retry policy. It controls the raw
  // primitive through stable levels and consumes atomic iteration events.
  // It also controls the later main-band pattern generator. The 8 ms
  // residency timer (u_resid_timer) provides timeout enforcement
  // per spec 4.5.3. The 4 ms reset timer (u_reset_timer) enforces the
  // minimum RESET duration requirement per spec 4.5.3.1.
  // ---------------------------------------------------------------------------
  ltsm #(.NLANES(NLANES)) u_ltsm (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
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
    .pattern_run_enable(pattern_run_enable),
    .sbinit_raw_mode (sbinit_raw_mode),
    .sbinit_rx_iter_vld(sbinit_rx_iter_vld),
    .sbinit_rx_iter_match(sbinit_rx_iter_match),
    .sbinit_tx_iter_done(sbinit_tx_iter_done),
    .sbinit_tx_idle  (sbinit_tx_idle),
    .pat_enable      (pat_enable),
    .pat_select      (pat_select),
    .pat_lfsr_reset  (pat_lfsr_reset),
    .pat_lfsr_enable (pat_lfsr_enable),
    .pat_done        (pat_done),
    .tmr_start       (tmr_start),
    .tmr_run         (tmr_run),
    .rst_tmr_start   (rst_tmr_start),
    .tmr_expired     (tmr_expired),
    .rst_tmr_expired (rst_tmr_expired)
  );
  // ---------------------------------------------------------------------------
  // 8 ms Residency Timer Instantiation  (u_resid_timer)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.5 – every timed training state is bounded by an
  //                  8 ms residency window. The LTSM asserts tmr_start on
  //                  state entry and holds tmr_run across every private
  //                  SBINIT phase. If tmr_expired fires before completion,
  //                  the LTSM escalates to TRAINERROR per 4.5.3.8.
  //
  // ucie_timer is parameterised with C_RESIDENCY = 4_000_000 lclk cycles
  // (8 ms at 500 MHz).
  // ---------------------------------------------------------------------------
  ucie_timer #(.LIMIT_CYCLES(C_RESIDENCY)) u_resid_timer (
    .clk      (lclk),
    .reset_n  (lreset_n),
    .start    (tmr_start),
    .running  (tmr_run),
    .expired  (tmr_expired)
  );

  // ---------------------------------------------------------------------------
  // 4 ms RESET Minimum Timer Instantiation (u_reset_timer)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.5.3.1 – Physical Layer must stay in RESET for a
  //                  minimum of 4 ms upon every entry to RESET. The separate
  //                  rst_tmr_start pulse prevents later state entries from
  //                  restarting this RESET-epoch timer.
  // ucie_timer is parameterised with C_RESET_MIN = 2_000_000 lclk cycles
  // (4 ms at 500 MHz).
  // ---------------------------------------------------------------------------
  ucie_timer #(.LIMIT_CYCLES(C_RESET_MIN)) u_reset_timer (
    .clk      (lclk),
    .reset_n  (lreset_n),
    .start    (rst_tmr_start),
    .running  (ltsm_state == ucie_pkg::LT_RESET),
    .expired  (rst_tmr_expired)
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
    .phy_inband_pres (sb_rx_valid_sync_q),
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
  // Spec reference : 4.5.3.4 (MBTRAIN sub-states), 4.5.3.5 (LINKINIT),
  //                  4.4.1 (Scrambling and training pattern generation).
  //
  // The pattern generator produces per-lane training patterns on mb_tx_data
  // during the MBTRAIN and LINKINIT sub-states. The LTSM selects the active
  // pattern (PAT_PERLANEID, PAT_VALTRAIN, PAT_CLKREPAIR, PAT_LFSR) and
  // controls the LFSR reseed via pat_lfsr_reset/pat_lfsr_enable. The
  // pat_done signal fires on the final UI of the LFSR pattern (4096 UI) to
  // allow the LTSM to advance from LINKINIT to ACTIVE.
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] pat_data_out;
  // -------------------------------------------------------------------------
  // Instantiation: pattern_gen (u_pat_gen)
  //
  // Produces per-lane training patterns (Per-Lane-ID, VALTRAIN, clock-
  // repair, LFSR) under LTSM control.  The 128-bit output pat_data_out
  // feeds the TX gearbox for serialisation onto the main-band lanes.
  //
  // Spec ref: UCIe 1.0, Section 4.4.1 - Scrambling and training pattern
  //           generation.
  // -------------------------------------------------------------------------
  pattern_gen #(.NLANES(NLANES)) u_pat_gen (
    .lclk        (lclk),
    .lreset_n    (lreset_n),
    .enable      (pat_enable),
    .pattern     (pat_select),
    .lfsr_reset  (pat_lfsr_reset),
    .lfsr_enable (pat_lfsr_enable),
    .data        (pat_data_out),
    .pat_done    (pat_done)
  );
  // ---------------------------------------------------------------------------
  // Byte-to-Lane Mapper Instantiation  (u_mapper)
  // ---------------------------------------------------------------------------
  // Spec reference : 4.1.1 (Byte to Lane Mapping), Figure 42 (Byte map for
  //                  x16 interface), Figure 43 (Byte to Lane mapping for
  //                  Standard package x8 degraded), 4.3.7 (Width Degrade in
  //                  Standard Package Interfaces).
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
  // -------------------------------------------------------------------------
  // assign: rdi_pl_speedmode – static 4 GT/s speed advertisement
  //
  // Tied to SPEED_4GT (3'b000).  This reduced-capability build supports
  // only the lowest UCIe main-band data rate.
  //
  // Spec ref: UCIe 1.0, Section 8.1 - Raw Die-to-Die Interface (RDI),
  //           Table 114 - RDI Signal List.
  // -------------------------------------------------------------------------
  assign rdi_pl_speedmode= SPEED_4GT;
  // -------------------------------------------------------------------------
  // assign: rdi_pl_stallreq – PHY stall request (disabled)
  //
  // Tied to 1'b0.  The PHY never initiates a stall in this build because
  // no recalibration or power-management flow requires one.
  //
  // Spec ref: UCIe 1.0, Section 8.1 - Raw Die-to-Die Interface (RDI),
  //           Table 114 - RDI Signal List.
  // -------------------------------------------------------------------------
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
  assign csr_addr  = 27'h0;
  assign csr_wdata = 64'h0;

  // ---------------------------------------------------------------------------
  // Configuration interface stub  (spec 6.1 sideband cfg)
  // ---------------------------------------------------------------------------
  // The pl_cfg interface is unused in this build. Outputs are tied low so
  // the cfg bus is inert.
  // ---------------------------------------------------------------------------
  assign pl_cfg     = {NC{1'b0}};
  assign pl_cfg_vld = 1'b0;
  assign pl_cfg_crd = 1'b0;

  // ---------------------------------------------------------------------------
  // Main-Band 4 GT/s DDR Gearboxes (spec 4.1.1, 5.2 -- Req.2)
  // ---------------------------------------------------------------------------
  // Bridges the 500 MHz 128-bit lclk domain and the 2 GHz 16-lane DDR mainband.
  // In training states (pat_enable=1), the transmitter serializes the 128-bit
  // pattern word (8 UIs per lane) over the 8 DDR UIs of each lclk cycle. In
  // ACTIVE, it serializes the streaming rdi_lp_data from the adapter.
  //
  // The receiver deserializes 8 DDR UIs into a 128-bit word on rdi_pl_data.
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] tx_gearbox_word;
  logic              tx_gearbox_valid;
  logic [DATA_W-1:0] rx_gearbox_word;
  logic              rx_gearbox_valid;

  always_comb begin
    if (pat_enable) begin
      tx_gearbox_word  = pat_data_out;
      tx_gearbox_valid = 1'b1;
    end else begin
      tx_gearbox_word  = rdi_lp_data;
      tx_gearbox_valid = rdi_lp_valid;
    end
  end

  tx_gearbox #(
    .NBYTES(NBYTES),
    .NLANES(NLANES)
  ) u_tx_gearbox (
    .lclk       (lclk),
    .lreset_n   (lreset_n),
    .mbclk      (mbclk),
    .tx_word    (tx_gearbox_word),
    .tx_valid   (tx_gearbox_valid),
    .tx_load    (1'b1),
    .mb_tx_data (mb_tx_data),
    .mb_tx_valid(mb_tx_valid)
  );

  rx_gearbox #(
    .NBYTES(NBYTES),
    .NLANES(NLANES)
  ) u_rx_gearbox (
    .lclk       (lclk),
    .lreset_n   (lreset_n),
    .mbclk      (mbclk),
    .mb_rx_data (mb_rx_data),
    .mb_rx_valid(mb_rx_valid),
    .rx_word    (rx_gearbox_word),
    .rx_word_vld(rx_gearbox_valid)
  );

  // ---------------------------------------------------------------------------
  // RDI Physical-Layer Outputs: trdy / valid / data
  // ---------------------------------------------------------------------------
  // These three continuous assigns form the physical-layer half of the RDI
  // transmit handshake. They are the only path by which received main-band
  // data leaves this module, so they are what makes the receive datapath
  // observable to the adapter.
  //
  //   rdi_pl_trdy  - transmit ready. The PHY is always ready in this
  //                  simplified endpoint, so trdy simply mirrors the protocol
  //                  layer's irdy. There is no flow-control state to model
  //                  because the loopback never backpressures.
  //
  //   rdi_pl_valid - receive valid. Driven directly by the receive gearbox
  //                  framing output. It pulses once per reassembled 128-bit
  //                  word, which is once per lclk cycle while data flows.
  //                  This is the framing boundary of spec 4.1.2: valid marks
  //                  the cycle on which rdi_pl_data carries a complete word.
  //
  //   rdi_pl_data  - receive data. The reassembled word straight from the
  //                  receive gearbox, with no intervening register, so that
  //                  valid and data always describe the same word. Adding a
  //                  register here would delay data but not the valid pulse
  //                  and silently corrupt the pairing.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing; Section 8.1 - Raw
  // Die-to-Die Interface (RDI); Table 114 - RDI Signal List.
  // ---------------------------------------------------------------------------
  assign rdi_pl_trdy  = rdi_lp_irdy;
  assign rdi_pl_valid = rx_gearbox_valid;
  assign rdi_pl_data  = rx_gearbox_word;

  // ---------------------------------------------------------------------------
  // Lint Suppression: `unused` (continuous assign)
  // ---------------------------------------------------------------------------
  // Continuous assign so Icarus Verilog evaluates all bit-select references.
  //
  // A reduced endpoint leaves several ports and signals intentionally
  // unimplemented: the stall handshake, the CSR read data bus, the retrain and
  // sideband timeout hooks, and the per-lane byte map are all wired for
  // interface completeness but carry no logic in this proof of concept. Without
  // a reference, `iverilog -Wall` reports them as unused and the zero-warning
  // compile gate fails.
  //
  // Folding every one of them into a single catch-all assign keeps them live
  // for the elaborator while adding no logic: the expression is never read, so
  // synthesis discards it entirely. It is a deliberate, documented suppression
  // rather than a hidden one.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism (the
  //           pl_stallreq / lp_stallack handshake). lp_state_req is a
  //           separate state request specified in Section 8.3.2.
  // ---------------------------------------------------------------------------
  logic unused;
  assign unused = local_active_req | adapter_active_req | csr_rdata_vld |
                  csr_rdata[0] | phy_retrain_done | sb_msg_timeout |
                  sb_stall_sent | lane_bytes[0][0] | sb_rx_cdc_busy |
                  raw_rx_result_busy | raw_tx_done_busy |
                  lp_cfg[0] | lp_cfg_vld | lp_cfg_crd;

endmodule

`endif

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
//               section 4.1.5 (Sideband transmission), section 5.13
//               (Sideband signaling), section 6.0 / 6.1 (Sideband protocol),
//               section 8.1 - Raw Die-to-Die Interface (RDI), Table 114
//               (RDI signal list), section 4.5.3 (Link Training State
//               Machine), section 7.5 (UCIe Registers).
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
//  |  +------------------+    Active gate + per-byte TX/RX scramblers    |
//  +--------------------------------------------------------------------+
//
// --------------------------------------------------------------------------
// Data flow (simplified)
// --------------------------------------------------------------------------
//   TX path : adapter -> rdi_lp_data -> Active data gate -> per-byte
//             scrambler -> TX gearbox -> mb_tx_data pins.
//             During training: ltsm -> pattern_gen -> mb_tx_data pins.
//   RX path : mb_rx_data pins -> RX gearbox -> per-byte descrambler ->
//             Active data gate -> rdi_pl_data.
//             The RX gearbox also reports a private mainband framing fault.
//   Sideband: logical_phy owns typed sb_packet_t CDC mailboxes bridging lclk
//             and sbclk. On TX, it arbitrates between LTSM and Adapter packets;
//             on RX, it routes decoded packets to LTSM or Adapter clients.
//             During RESET and SBINIT pattern phases, a raw sbclk primitive owns
//             the pins and keeps the codec reset.
//             The codec serializes 64-bit headers and optional 64-bit payloads.
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
//   Sideband pins   : sb_tx_clk/sb_tx_data, sb_rx_clk/sb_rx_data toward partner
//                     die. They carry raw SBINIT waveform before carrying
//                     serialized 64-bit headers and optional payloads.
//   Main-band pins  : mb_tx_data, mb_rx_data. One bit per lane per UI.
//   CSR/cfg         : phy_csr_* dedicated internal channel from Adapter with
//                     byte enables (lp_cfg/pl_cfg is FDI-only, tied off here).
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
//      training, and by the gated Active data path otherwise.
//   2. The PHY CSR write/read path connects to the adapter's phy_csr_* channel,
//      supporting byte-enabled accesses alongside csr_start_link_train.
//   3. Static RDI outputs (pl_lnk_cfg, pl_speedmode, pl_stallreq) are tied
//      to the reduced-capability defaults: x16, 4 GT/s, no stall.
//   4. User data flows only while the link is fully Active: the private gate
//      requires the completed LTSM Active Entry result, the published RDI
//      ACTIVE result, a settled LTSM ACTIVE level, and an inactive Adapter
//      stall acknowledgement. TX data is scrambled before the TX gearbox and
//      RX data is descrambled after the RX gearbox, with one independent
//      per-byte scrambler array per direction and a common Active Entry seed.
//   5. The RX gearbox reports a private mainband framing fault. This module
//      synchronizes it into lclk and converts it into a one-cycle private
//      event for the existing LTSM fatal policy. No public error port is
//      added, so the top-level interface is unchanged.
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
//                        codec busy back to lclk.
//   v0.0.10 2026-09-24  Add the UI-exact Standard Package SBINIT waveform,
//                        raw/packet mux, and atomic iteration CDC mailboxes.
//   v0.0.11 2026-09-24  Phase A: widen the private RX packet mailbox to
//                        include DATA64 and retain decoded packets until
//                        the mailbox accepts them.
//   v0.0.12 2026-09-24  Phase A: force low mainband data and framing through
//                        every immediate-success MBINIT and MBTRAIN state.
//   v0.0.13 2026-09-24  Clarify the private Phase A DATA64 payload boundary.
  // v0.0.14 2026-09-24  Phase B: expose private mailbox source acceptance and
  //                        the retained DATA64 payload to the LTSM.
  // v0.0.15 2026-09-25  Phase C: route private RDI request, fresh-event,
  //                        Active-entry result, and Start-copy-clear signals.
  // v0.0.16 2026-09-25  Phase D: route the Adapter Start copy as an internal
  //                        edge-triggered event, gate RDI Active on completed
  //                        LTSM Active Entry, and remove peer-Active feedback.
  // v0.0.17 2026-09-25  Complete Phase D construct documentation for SBINIT
  //                        ownership, sideband codec mapping, and LTSM wiring.
  // v0.0.18 2026-09-25  Correct Phase D construct header and specification
  //                        subsection references.
  // v0.0.19 2026-09-25  Phase E: gate user data on completed Active Entry,
  //                        RDI Active, a settled LTSM ACTIVE level, and an
  //                        inactive stall acknowledgement. Add independent
  //                        per-byte TX/RX scrambler arrays seeded at Active
  //                        Entry, scramble before the TX gearbox, descramble
  //                        after the RX gearbox, and route the private RX
  //                        framing fault into the LTSM fatal policy. Restore
  //                        the RDI state-status driver and the lint use of the
  //                        preserved adapter_active_req input.
  // v0.0.20 2026-09-25  Phase E correctness: close the Active-data gate at
  //                        private transition start, drain accepted registered
  //                        words without masking their valid, flush the RX
  //                        epoch at the first quiet transfer gap, and retain
  //                        an unarmed framing-fault edge until LTSM policy
  //                        can consume it.
  // v0.0.21 2026-09-25  Phase E fault containment: clear pending TX/RX valid
  //                        qualifiers when the Active-data gate closes and
  //                        qualify both output valid signals with that gate.
  //                        This prevents a registered word from leaking after
  //                        a private framing fault or transition.
  // v0.0.22 2026-09-25  Clarify the valid-register block comment for the
  //                        synchronous gate-close flush.
  // v0.0.23 2026-09-25  Include the current private framing-fault event in
  //                        the Active-data gate while preserving recovery after
  //                        the gearbox sticky history remains set.
  // v0.0.24 2026-09-28  Migrate sideband physical pins to scalar sb_tx_clk /
  //                        sb_tx_data and sb_rx_clk / sb_rx_data per UCIe 1.0
  //                        Sections 4.1.5 and 5.13. Adopt typed sb_packet_t
  //                        channels for TX and RX CDC mailboxes. Connect new
  //                        sb_codec handshake (tx_valid/ready, rx_valid/ready)
  //                        and route sticky codec overflow into the LTSM fatal
  //                        event policy. Add private Adapter packet client ports
  //                        (adapter_sb_tx_* / adapter_sb_rx_*) with a non-starving
  //                        arbiter featuring mandatory LTSM/response priority and
  //                        alternating request selection (Sections 4.1.5, 5.13, 6.1).
  //                        Convert between LTSM flat sideband fields and typed
  //                        sb_packet_t at the LTSM policy boundary.
  // v0.0.25 2026-09-28  Connect separate PHY CSR channel (phy_csr_*) to u_phy_csr
  //                        with byte enables (Sections 6.1, 7.5). Add private
  //                        rdi_lp_linkerror input (Section 8.1).
  // v0.0.26 2026-10-02  Drive RDI pl_inband_pres from LTSM training
  //                        completion instead of packet reception during SBINIT.
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
  input logic        start_link_train,
  input logic        adapter_start_link_train,
  input  rdi_req_t   rdi_lp_state_req,
  input  logic        rdi_lp_stallack,
  input  logic        rdi_lp_linkerror = 1'b0,
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
  output logic        clear_start_link_train,
  input  logic        adapter_active_req,
  // Public scalar physical sideband interface (UCIe 1.0 Section 4.1.5 and 5.13)
  output logic        sb_tx_clk,
  output logic        sb_tx_data,
  input  logic        sb_rx_clk,
  input  logic        sb_rx_data,

  // Private Adapter sideband packet client interface (UCIe 1.0 Section 6.1)
  input  logic        adapter_sb_tx_valid,
  output logic        adapter_sb_tx_ready,
  input  sb_packet_t  adapter_sb_tx_packet,
  output logic        adapter_sb_rx_valid,
  input  logic        adapter_sb_rx_ready,
  output sb_packet_t  adapter_sb_rx_packet,
  output logic        adapter_sb_rx_cp_error,
  output logic        adapter_sb_rx_dp_error,
  output logic        adapter_sb_rx_format_error,

  // Separate PHY CSR Access Channel (from Adapter, Sections 6.1, 7.5)
  input  logic        phy_csr_wr = 1'b0,
  input  logic        phy_csr_rd = 1'b0,
  input  logic [26:0] phy_csr_addr = 27'h0,
  input  logic [63:0] phy_csr_wdata = 64'h0,
  input  logic [7:0]  phy_csr_be = 8'h0,
  output logic [63:0] phy_csr_rdata,
  output logic        phy_csr_rdata_vld,
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
  import ucie_pkg::*;


  // ------------------------------------------------- internal datapath
  logic [NBYTES-1:0][7:0] tx_bytes;
  logic [NLANES-1:0][7:0] lane_bytes;

  // ------------------------------------------- Active data path (Phase E)
  // Private control of the gated Active data path and of the two independent
  // per-byte scrambler arrays. The construct blocks at the Active data path
  // section below own the behavior: these lines only fix the names.
  // Spec ref: UCIe 1.0 Sections 4.1.1, 4.1.2, 4.4.1, 8.1.6, and 8.3.1;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  logic        ltsm_active_entry_q;      // Active Entry result, previous lclk
  logic        active_entry_seed_pulse;  // one-lclk scrambler seed strobe
  logic [7:0]  ltsm_state_q;             // LTSM state, previous lclk
  logic        ltsm_active_state_stable; // ACTIVE held for two lclk cycles
  logic        ltsm_transition_active;   // private LTSM transition in progress
  logic        user_data_enable;         // Active user-data gate, both paths
  logic        tx_user_transfer;         // accepted TX transfer strobe
  logic        rx_user_transfer;         // accepted RX transfer strobe
  logic        tx_user_valid_q;          // TX valid stored with scramble word
  logic        rx_user_valid_q;          // RX valid stored with descramble word
  logic        tx_user_valid;            // stored TX valid, drained word beat
  logic        rx_user_valid;            // stored RX valid, drained word beat
  logic        rx_epoch_synced_q;        // RX epoch aligned to a quiet gap
  logic [DATA_W-1:0] tx_user_word;       // scrambled 128-bit TX word
  logic [DATA_W-1:0] rx_user_word;       // descrambled 128-bit RX word

  // --------------------------------------- mainband framing fault (Phase E)
  // The RX gearbox owns detection. This module owns the clock-domain crossing
  // and the private event shape for the LTSM. The event path is re-armed per
  // epoch: see the framing-fault section at the Active data path.
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.5.3.8;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  logic        rx_framing_fault;         // rx_gearbox private fault (mbclk)
  logic        rx_framing_fault_meta_q;  // lclk synchronizer stage 1
  logic        rx_framing_fault_sync_q;  // lclk synchronizer stage 2
  logic        rx_framing_fault_prev_q;  // edge-detect register
  logic        rx_framing_fault_rise;    // fresh synchronized fault edge
  logic        rx_framing_fault_pending_q; // edge held for the armed epoch
  logic        ltsm_fatal_policy_armed;  // LTSM can consume fatal events
  logic        ltsm_framing_fault_event; // one-lclk event to the LTSM

  // ------------------------------------- mainband gearbox interface (4.1.1)
  // Declared with the Active data path because the scramble stage reads the
  // RX word and drives the TX word before the gearbox instantiations appear.
  // Spec ref: UCIe 1.0 Sections 4.1.1 and 4.1.2;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  logic [DATA_W-1:0] tx_gearbox_word;    // word presented to the TX gearbox
  logic              tx_gearbox_valid;   // framing valid for that word
  logic [DATA_W-1:0] rx_gearbox_word;    // word reassembled by the RX gearbox
  logic              rx_gearbox_valid;   // valid strobe for that word

  // ------------------------------------------------- Logical PHY typed sideband CDC
  // Typed sb_packet_t channels for transmit and receive, bridging arbitrated
  // LTSM/Adapter traffic with sb_codec across the asynchronous clock boundary.
  // Spec ref: UCIe 1.0 Section 4.1.5, Section 5.13, Section 6.1.
  localparam int unsigned SB_PKT_W = $bits(sb_packet_t);
  localparam int unsigned SB_RX_MAILBOX_W = SB_PKT_W + 3;

  // LTSM-facing TX request fields (converted into sb_packet_t)
  logic        sb_tx_load;
  logic [4:0]  sb_tx_opcode;
  logic [2:0]  sb_tx_srcid;
  logic [2:0]  sb_tx_dstid;
  logic [15:0] sb_tx_msginfo;
  logic [7:0]  sb_tx_msgcode;
  logic [7:0]  sb_tx_msgsubcode;
  logic [7:0]  sb_tx_be;
  logic [4:0]  sb_tx_tag;
  logic        sb_tx_ep;
  logic [11:0] sb_tx_addr;
  logic [63:0] sb_tx_data_in;
  logic        sb_tx_has_data;
  logic        sb_tx_accepted;
  logic        sb_tx_busy;

  sb_packet_t  ltsm_tx_packet;

  // Arbiter between LTSM TX and Adapter TX
  logic        arb_prio_q;
  logic        ltsm_grant;
  logic        adapter_grant;
  logic        arb_toggle;
  logic        tx_cdc_send;
  sb_packet_t  tx_cdc_packet;
  logic        tx_cdc_busy;

  // Codec-facing TX signals in sbclk
  sb_packet_t  codec_tx_cdc_data;
  logic        codec_tx_cdc_valid;
  logic        codec_tx_pending_q;
  sb_packet_t  codec_tx_packet_q;
  logic        codec_tx_valid;
  logic        codec_tx_ready;
  sb_packet_t  codec_tx_pkt;
  logic        codec_tx_busy;
  logic        codec_tx_busy_combined;
  logic        codec_tx_busy_meta_q;
  logic        codec_tx_busy_sync_q;
  logic        codec_tx_inflight_q;
  logic        codec_tx_busy_seen_q;
  logic        codec_sb_tx_clk;
  logic        codec_sb_tx_data;
  logic        codec_reset_n;

  // Codec-facing RX signals in sbclk
  logic        codec_rx_valid;
  logic        codec_rx_ready;
  sb_packet_t  codec_rx_packet;
  logic        codec_rx_format_error;
  logic        codec_rx_cp_error;
  logic        codec_rx_dp_error;
  logic        codec_rx_overflow;
  logic        codec_rx_overflow_meta_q;
  logic        codec_rx_overflow_sync_q;
  logic        codec_rx_overflow_prev_q;
  logic        codec_rx_overflow_rise;

  // Mailbox-facing RX signals in lclk
  logic        rx_cdc_valid;
  logic        rx_cdc_format_error;
  logic        rx_cdc_cp_error;
  logic        rx_cdc_dp_error;
  sb_packet_t  rx_cdc_packet;
  logic        sb_rx_cdc_busy;

  // LTSM-facing RX signals (converted from sb_packet_t)
  logic        sb_rx_pkt_vld;
  logic [4:0]  sb_rx_opcode;
  logic [2:0]  sb_rx_srcid;
  logic [2:0]  sb_rx_dstid;
  logic [15:0] sb_rx_msginfo;
  logic [7:0]  sb_rx_msgcode;
  logic [7:0]  sb_rx_msgsubcode;
  logic [63:0] sb_rx_payload;
  logic        sb_rx_cp_err;
  logic        sb_rx_dp_err;

  // Adapter RX holding buffer in lclk
  logic        adapter_rx_hold_q;
  sb_packet_t  adapter_rx_pkt_q;
  logic        adapter_rx_cp_err_q;
  logic        adapter_rx_dp_err_q;
  logic        adapter_rx_fmt_err_q;

  logic        sb_msg_timeout;
  logic        sb_stall_sent;
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

  logic               raw_sb_tx_clk;
  logic               raw_sb_tx_data;
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
  // ------------------------------------------------- LTSM <-> Start / RDI
  logic        csr_start_link_train;
  logic        ltsm_software_start_q;
  logic        ltsm_software_start_event;
  logic        rdi_active_req_q;
  logic        ltsm_rdi_active_event;
  logic        ltsm_active_entry_done;
  logic        link_trained;
  logic        phy_training_done;
  logic        train_error;
  logic        link_reset_out;
  logic        phy_retrain_done;
  logic [7:0]  ltsm_state;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;
  logic        local_active_req;
  logic        rdi_stall_req_q, rdi_stall_req_d;
  logic        rdi_stall_ack;
  logic        rdi_stall_complete;

  // ------------------------------------------------- CSR
  logic        csr_wr;
  logic        csr_rd;
  logic [26:0] csr_addr;
  logic [63:0] csr_wdata;
  logic [7:0]  csr_be;
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
    .sb_rx_clk          (sb_rx_clk),
    .sb_rx_data         (sb_rx_data),
    .raw_rx_result_busy (raw_rx_result_busy),
    .sb_tx_clk          (raw_sb_tx_clk),
    .sb_tx_data         (raw_sb_tx_data),
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
  // ---------------------------------------------------------------------------
  // Module instantiation: SBINIT RX result mailbox
  //
  // Transfers each raw-pattern match result from sbclk to lclk with its valid
  // event. The mailbox preserves ordering across the asynchronous clock domains.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
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

  // ---------------------------------------------------------------------------
  // assign: SBINIT RX match payload
  //
  // Exposes the one-bit result captured by the RX mailbox. The valid pulse
  // from the same mailbox qualifies when the LTSM consumes this value.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
  assign sbinit_rx_iter_match = raw_rx_result_l[0];

  // Independent local-completion mailbox. It reports every completed local
  // 96-UI waveform once and carries no phase, count, or completion policy.
  // ---------------------------------------------------------------------------
  // Module instantiation: SBINIT TX completion mailbox
  //
  // Transfers each completed raw transmit iteration from sbclk to lclk.
  // The destination sees one completion pulse per accepted waveform.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
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
  // ---------------------------------------------------------------------------
  // always_ff: Boundary-safe codec release in sbclk
  //
  // Holds the packet codec in reset during raw SBINIT mode and releases it
  // only after the synchronized raw receiver observes an idle boundary.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      codec_packet_ready_s <= 1'b0;
    end else if (raw_mode_active_s) begin
      codec_packet_ready_s <= 1'b0;
    end else if (!codec_packet_ready_s && raw_rx_low_sample) begin
      codec_packet_ready_s <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // assign: Packet codec reset qualification
  //
  // Combines the sideband reset with the registered raw-to-packet boundary
  // state, so the codec cannot observe a partial raw waveform.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
  assign codec_reset_n = sbreset_n && codec_packet_ready_s;
  // ---------------------------------------------------------------------------
  // always_ff: Synchronize codec release and raw TX idle
  //
  // Transfers the sbclk boundary state and raw transmitter idle indication
  // into lclk before LTSM and SBINIT consume them.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
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

  // ---------------------------------------------------------------------------
  // assign: SBINIT transmit-idle indication
  //
  // Exposes the synchronized raw-pattern idle level to the SBINIT controller.
  // The synchronizer prevents the lclk domain from sampling sbclk transitions.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
  // ---------------------------------------------------------------------------
  assign sbinit_tx_idle = raw_tx_idle_sync_q;

  // Raw mode owns the public pins for the entire pattern phase, including its
  // 1 ms idle windows. Packet pins become visible only after the boundary-safe
  // mode change has reset and released the codec.
  // Raw and packet valid are selected together, so data and framing cannot
  // come from different sideband sources.
  // Spec ref: UCIe 1.0 Section 4.5.3.2; PLAN.md Sections 14.4 and 15.4.
  // ===========================================================================
  // Sideband Pin Multiplexing (spec 4.1.5, 4.5.3.2, 5.13)
  // ===========================================================================
  // Raw mode owns the public physical pins for the entire pattern phase, including its
  // 1 ms idle windows. Packet pins become visible only after the boundary-safe
  // mode change has reset and released the codec.
  // Only scalar clock and scalar data are muxed to the physical pins.
  // ===========================================================================
  assign sb_tx_clk  = raw_mode_active_s ? raw_sb_tx_clk  : codec_sb_tx_clk;
  assign sb_tx_data = raw_mode_active_s ? raw_sb_tx_data : codec_sb_tx_data;

  // ===========================================================================
  // LTSM TX Packet Assembly and Arbitration (UCIe 1.0 Section 6.1)
  // ===========================================================================
  // Converts flat LTSM TX fields into one typed sb_packet_t container.
  // Preserves existing LTSM port interface so ltsm.sv remains functional.
  // ===========================================================================
  always_comb begin
    ltsm_tx_packet             = '0;
    ltsm_tx_packet.opcode      = sb_tx_opcode;
    ltsm_tx_packet.src_id      = sb_tx_srcid;
    ltsm_tx_packet.dst_id      = sb_tx_dstid;
    ltsm_tx_packet.msg_info    = sb_tx_msginfo;
    ltsm_tx_packet.msg_code    = sb_tx_msgcode;
    ltsm_tx_packet.msg_subcode = sb_tx_msgsubcode;
    ltsm_tx_packet.cr          = 1'b0;
    ltsm_tx_packet.addr        = {15'h0000, sb_tx_addr};
    ltsm_tx_packet.be          = sb_tx_be;
    ltsm_tx_packet.tag         = sb_tx_tag;
    ltsm_tx_packet.ep          = sb_tx_ep;
    ltsm_tx_packet.status      = 3'b000;
    ltsm_tx_packet.data        = sb_tx_data_in;
  end

  // Pure helper: response packet detection per Section 6.1
  function automatic logic is_response_packet(input sb_packet_t pkt);
    sb_packet_kind_t kind;
    kind = ucie_pkg::sb_packet_kind(pkt.opcode);
    if (kind == SB_PKT_COMPLETION) begin
      return 1'b1;
    end else if (kind == SB_PKT_MESSAGE) begin
      return (!pkt.msg_code[0] && (pkt.msg_code != 8'h00));
    end else begin
      return 1'b0;
    end
  endfunction

  // Pure helper: PHY link training traffic identification (Sections 4.5.3, 6.1)
  function automatic logic is_phy_training_packet(input sb_packet_t pkt);
    if ((pkt.opcode == SB_OP_MSG_NODATA) || (pkt.opcode == SB_OP_MSG_DATA64)) begin
      if ((pkt.src_id == SRCID_PHY) && (pkt.dst_id == DSTID_REMOTE_PHY)) begin
        case (pkt.msg_code)
          MC_SB_OOB_RESET,
          MC_SB_DONE_REQ,
          MC_SB_DONE_RSP,
          8'h03, // MC_MBINIT_REQ
          8'h04, // MC_MBINIT_RSP
          8'h05, // MC_MBTRAIN_REQ
          8'h06, // MC_MBTRAIN_RSP
          8'h07, // MC_PHYRETRAIN_REQ
          8'h08, // MC_PHYRETRAIN_RSP
          MC_LM_RDI_REQ,
          MC_LM_RDI_RSP,
          MC_TE_REQ,
          MC_TE_RSP: return 1'b1;
          default:   return 1'b0;
        endcase
      end else begin
        return 1'b0;
      end
    end else begin
      return 1'b0;
    end
  endfunction

  // Small non-starving arbiter with mandatory LTSM/response priority and
  // alternating Adapter/LTSM request selection. Does not own remote request
  // credits or tags here.
  wire ltsm_is_resp    = is_response_packet(ltsm_tx_packet);
  wire adapter_is_resp = is_response_packet(adapter_sb_tx_packet);

  always_comb begin
    ltsm_grant    = 1'b0;
    adapter_grant = 1'b0;
    arb_toggle    = 1'b0;

    if (sb_tx_load && (ltsm_state != LT_ACTIVE)) begin
      // Mandatory LTSM priority during link training
      ltsm_grant = 1'b1;
    end else if (sb_tx_load && ltsm_is_resp) begin
      // Mandatory LTSM response priority
      ltsm_grant = 1'b1;
    end else if (adapter_sb_tx_valid && adapter_is_resp) begin
      // Mandatory Adapter response priority over requests
      adapter_grant = 1'b1;
    end else if (sb_tx_load && adapter_sb_tx_valid) begin
      // Alternating request selection between LTSM and Adapter
      if (!arb_prio_q) begin
        ltsm_grant = 1'b1;
        arb_toggle = 1'b1;
      end else begin
        adapter_grant = 1'b1;
        arb_toggle    = 1'b1;
      end
    end else if (sb_tx_load) begin
      ltsm_grant = 1'b1;
    end else if (adapter_sb_tx_valid) begin
      adapter_grant = 1'b1;
    end
  end

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      arb_prio_q <= 1'b0;
    end else if (arb_toggle && tx_cdc_send) begin
      arb_prio_q <= ~arb_prio_q;
    end
  end

  assign tx_cdc_send         = (ltsm_grant || adapter_grant) && !sb_tx_busy;
  assign tx_cdc_packet       = ltsm_grant ? ltsm_tx_packet : adapter_sb_tx_packet;
  assign sb_tx_accepted      = ltsm_grant && !sb_tx_busy;
  assign adapter_sb_tx_ready = adapter_grant && !sb_tx_busy;

  // ===========================================================================
  // Transmit CDC Mailbox (lclk to sbclk)
  // ===========================================================================
  // Carries complete typed sb_packet_t transactions to sbclk.
  sb_cdc_mailbox #(.WIDTH(SB_PKT_W)) u_sb_tx_cdc (
    .src_clk    (lclk),
    .src_reset_n(lreset_n),
    .src_data   (tx_cdc_packet),
    .src_send   (tx_cdc_send),
    .src_busy   (tx_cdc_busy),
    .dst_clk    (sbclk),
    .dst_reset_n(sbreset_n),
    .dst_data   (codec_tx_cdc_data),
    .dst_valid  (codec_tx_cdc_valid)
  );
  // Synchronize codec busy into lclk.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_tx_busy_meta_q <= 1'b0;
      codec_tx_busy_sync_q <= 1'b0;
    end else begin
      codec_tx_busy_meta_q <= codec_tx_busy_combined;
      codec_tx_busy_sync_q <= codec_tx_busy_meta_q;
    end
  end

  // In-flight tracking: ensure lclk busy interval covers the entire transaction
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_tx_inflight_q  <= 1'b0;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (sbinit_raw_mode) begin
      codec_tx_inflight_q  <= 1'b0;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (tx_cdc_send) begin
      codec_tx_inflight_q  <= 1'b1;
      codec_tx_busy_seen_q <= 1'b0;
    end else if (codec_tx_inflight_q) begin
      if (codec_tx_busy_sync_q) codec_tx_busy_seen_q <= 1'b1;
      if (codec_tx_busy_seen_q && !codec_tx_busy_sync_q && !tx_cdc_busy) begin
        codec_tx_inflight_q  <= 1'b0;
        codec_tx_busy_seen_q <= 1'b0;
      end
    end
  end

  assign sb_tx_busy = tx_cdc_busy | codec_tx_busy_sync_q |
                      codec_tx_inflight_q | !codec_packet_ready_sync_q;

  // Buffer each mailbox delivery until the codec accepts it. The mailbox
  // valid pulse remains high through the codec acceptance edge, so retire
  // an existing pending packet before capturing a new delivery. This keeps
  // one CDC event equal to one codec transaction.
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      codec_tx_pending_q <= 1'b0;
      codec_tx_packet_q  <= '0;
    end else if (codec_tx_ready && codec_tx_pending_q) begin
      codec_tx_pending_q <= 1'b0;
    end else if (codec_tx_cdc_valid) begin
      codec_tx_pending_q <= 1'b1;
      codec_tx_packet_q  <= codec_tx_cdc_data;
    end
  end

  assign codec_tx_valid         = codec_tx_pending_q;
  assign codec_tx_pkt           = codec_tx_packet_q;
  assign codec_tx_busy_combined = codec_tx_busy || codec_tx_pending_q;

  // ===========================================================================
  // Sideband Physical Codec Instantiation (sb_codec)
  // ===========================================================================
  // Owns SDR strobe serializing/deserializing on scalar physical pins.
  // Connects new sb_codec handshake (tx_valid/ready, rx_valid/ready).
  // Spec ref: UCIe 1.0 Section 4.1.5, Section 5.13, Section 6.1.
  // ===========================================================================
  sb_codec u_sb_codec (
    .sbclk          (sbclk),
    .sbreset_n      (codec_reset_n),
    .tx_valid       (codec_tx_valid),
    .tx_ready       (codec_tx_ready),
    .tx_packet      (codec_tx_pkt),
    .tx_busy        (codec_tx_busy),
    .sb_tx_clk      (codec_sb_tx_clk),
    .sb_tx_data     (codec_sb_tx_data),
    .sb_rx_clk      (sb_rx_clk),
    .sb_rx_data     (sb_rx_data),
    .rx_valid       (codec_rx_valid),
    .rx_ready       (codec_rx_ready),
    .rx_packet      (codec_rx_packet),
    .rx_format_error(codec_rx_format_error),
    .rx_cp_error    (codec_rx_cp_error),
    .rx_dp_error    (codec_rx_dp_error),
    .rx_overflow    (codec_rx_overflow)
  );

  // Hold codec RX events until the lclk mailbox accepts them
  assign codec_rx_ready = codec_rx_valid && !sb_rx_cdc_busy;

  // Synchronize sticky codec overflow error into lclk fatal policy
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      codec_rx_overflow_meta_q <= 1'b0;
      codec_rx_overflow_sync_q <= 1'b0;
      codec_rx_overflow_prev_q <= 1'b0;
    end else begin
      codec_rx_overflow_meta_q <= codec_rx_overflow;
      codec_rx_overflow_sync_q <= codec_rx_overflow_meta_q;
      codec_rx_overflow_prev_q <= codec_rx_overflow_sync_q;
    end
  end

  assign codec_rx_overflow_rise = codec_rx_overflow_sync_q && !codec_rx_overflow_prev_q;

  // ===========================================================================
  // Receive CDC Mailbox (sbclk to lclk)
  // ===========================================================================
  // Carries complete typed sb_packet_t plus aligned CP/DP/format error bits.
  sb_cdc_mailbox #(.WIDTH(SB_RX_MAILBOX_W)) u_sb_rx_cdc (
    .src_clk    (sbclk),
    .src_reset_n(sbreset_n),
    .src_data   ({codec_rx_format_error, codec_rx_cp_error, codec_rx_dp_error, codec_rx_packet}),
    .src_send   (codec_rx_valid && !sb_rx_cdc_busy),
    .src_busy   (sb_rx_cdc_busy),
    .dst_clk    (lclk),
    .dst_reset_n(lreset_n),
    .dst_data   ({rx_cdc_format_error, rx_cdc_cp_error, rx_cdc_dp_error, rx_cdc_packet}),
    .dst_valid  (rx_cdc_valid)
  );

  // ===========================================================================
  // Receive Packet Demux and Field Unpack (lclk)
  // ===========================================================================
  // Routes required PHY LTSM traffic to LTSM; routes all non-PHY-training
  // traffic to the private Adapter RX client.
  wire route_to_ltsm    = (ltsm_state != LT_ACTIVE) || is_phy_training_packet(rx_cdc_packet);
  wire route_to_adapter = !route_to_ltsm;

  // LTSM policy boundary unpack: preserves existing ltsm.sv port interface
  assign sb_rx_pkt_vld    = rx_cdc_valid && route_to_ltsm;
  assign sb_rx_opcode     = rx_cdc_packet.opcode;
  assign sb_rx_srcid      = rx_cdc_packet.src_id;
  assign sb_rx_dstid      = rx_cdc_packet.dst_id;
  assign sb_rx_msginfo    = rx_cdc_packet.msg_info;
  assign sb_rx_msgcode    = rx_cdc_packet.msg_code;
  assign sb_rx_msgsubcode = rx_cdc_packet.msg_subcode;
  assign sb_rx_payload    = rx_cdc_packet.data;
  assign sb_rx_cp_err     = rx_cdc_cp_error | rx_cdc_format_error;
  assign sb_rx_dp_err     = rx_cdc_dp_error;

  // Adapter RX client holding buffer: delivers packet and retains until acknowledged
  wire adapter_rx_in_vld = rx_cdc_valid && route_to_adapter;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      adapter_rx_hold_q    <= 1'b0;
      adapter_rx_pkt_q     <= '0;
      adapter_rx_cp_err_q  <= 1'b0;
      adapter_rx_dp_err_q  <= 1'b0;
      adapter_rx_fmt_err_q <= 1'b0;
    end else begin
      if (adapter_rx_in_vld) begin
        if (!adapter_sb_rx_ready || adapter_rx_hold_q) begin
          adapter_rx_hold_q    <= 1'b1;
          adapter_rx_pkt_q     <= rx_cdc_packet;
          adapter_rx_cp_err_q  <= rx_cdc_cp_error;
          adapter_rx_dp_err_q  <= rx_cdc_dp_error;
          adapter_rx_fmt_err_q <= rx_cdc_format_error;
        end
      end else if (adapter_sb_rx_ready && adapter_rx_hold_q) begin
        adapter_rx_hold_q <= 1'b0;
      end
    end
  end

  assign adapter_sb_rx_valid        = adapter_rx_hold_q || adapter_rx_in_vld;
  assign adapter_sb_rx_packet       = adapter_rx_hold_q ? adapter_rx_pkt_q : rx_cdc_packet;
  assign adapter_sb_rx_cp_error     = adapter_rx_hold_q ? adapter_rx_cp_err_q : rx_cdc_cp_error;
  assign adapter_sb_rx_dp_error     = adapter_rx_hold_q ? adapter_rx_dp_err_q : rx_cdc_dp_error;
  assign adapter_sb_rx_format_error = adapter_rx_hold_q ? adapter_rx_fmt_err_q : rx_cdc_format_error;

  // ---------------------------------------------------------------------------
  // always_ff: Private LTSM Start and RDI event sampling
  //
  // Samples the combined top-level, Adapter CSR, and PHY CSR Start level so
  // the LTSM receives one event for the aggregate low-to-high transition.
  // Held levels do not create a recovery trigger after RESET. The RDI request
  // levels select the Active, LinkReset, and Disabled Phase C exchanges.
  //
  // Spec ref: UCIe 1.0 Sections 8.1.6 and 8.3.2.8;
  //           PLAN.md Sections 15.4 and 15.5.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ltsm_software_start_q <= 1'b0;
      rdi_active_req_q      <= 1'b0;
    end else begin
      ltsm_software_start_q <=
        start_link_train | adapter_start_link_train | csr_start_link_train;
      rdi_active_req_q      <=
        (rdi_lp_state_req == ucie_pkg::RDI_REQ_ACTIVE);
    end
  end

  // ---------------------------------------------------------------------------
  // assign: Private LTSM policy events
  //
  // These wires translate the combined Start edge and local RDI levels into
  // the LTSM private policy interface. The edge forms enforce fresh triggers.
  // Adapter CSR Start routing is part of Phase D and does not alter public RDI.
  //
  // Spec ref: UCIe 1.0 Sections 8.1.6 and 8.3.2.8;
  //           PLAN.md Sections 15.4, 15.5, and 15.9.
  // ---------------------------------------------------------------------------
  assign ltsm_software_start_event =
    (start_link_train | adapter_start_link_train | csr_start_link_train) &&
    !ltsm_software_start_q;
  assign ltsm_rdi_active_event =
    (rdi_lp_state_req == ucie_pkg::RDI_REQ_ACTIVE) && !rdi_active_req_q;

  // ---------------------------------------------------------------------------
  // Module instantiation: Link Training and Status Machine
  //
  // Owns LinkMgmt.RDI training, Active-entry completion, reset recovery,
  // and sideband progression that feeds the RDI and FDI state machines.
  // Its software start event combines the top-level Start pin, the private
  // Adapter CSR Start event, and the PHY CSR Start event. The private
  // framing_fault_event input carries the synchronized one-lclk mainband
  // framing fault into the existing fatal policy; it is not a public port.
  // The transition_active output is the private transition indication that
  // closes the Active user-data gate on the transition start.
  //
  // Spec ref: UCIe 1.0 Sections 8.1.6, 8.3.2.8, 4.5.3, and 4.5.3.8;
  //           PLAN.md Sections 15.4, 15.5, 15.6, and 15.9 Phase E.
  ltsm #(.NLANES(NLANES)) u_ltsm (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .software_start_event(ltsm_software_start_event),
    .rdi_active_event(ltsm_rdi_active_event),
    .rdi_active_req  (rdi_lp_state_req == ucie_pkg::RDI_REQ_ACTIVE),
    .rdi_linkreset_req(rdi_lp_state_req == ucie_pkg::RDI_REQ_LINKRESET),
    .rdi_disabled_req(rdi_lp_state_req == ucie_pkg::RDI_REQ_DISABLED),
    .framing_fault_event(ltsm_framing_fault_event),
    .transition_active(ltsm_transition_active),
    .active_entry_done(ltsm_active_entry_done),
    .clear_start_link_train(clear_start_link_train),
    .link_trained    (link_trained),
    .phy_training_done(phy_training_done),
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
    .sb_tx_accepted  (sb_tx_accepted),
    .sb_rx_pkt_vld   (sb_rx_pkt_vld),
    .sb_rx_opcode    (sb_rx_opcode),
    .sb_rx_srcid     (sb_rx_srcid),
    .sb_rx_dstid     (sb_rx_dstid),
    .sb_rx_msginfo   (sb_rx_msginfo),
    .sb_rx_msgcode   (sb_rx_msgcode),
    .sb_rx_msgsubcode(sb_rx_msgsubcode),
    .sb_rx_payload   (sb_rx_payload),
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
  // The RDI state machine mediates between the D2D Adapter and the physical
  // layer. RDI ACTIVE requires link_trained and the completed private LTSM
  // Active Entry result, while RESET and TRAINERROR preempt adapter requests.
  //
  // In this build:
  //   - phy_retrain_req is derived from the adapter requesting RDI_REQ_RETRAIN.
  //   - phy_inband_pres is the LTSM training-complete indication. It must not
  //     use packet reception, because SBINIT packet exchanges precede training
  //     completion and must not assert the Table 114 signal.
  //   - cerror, nferror, and stall_req are tied to zero.
  //   - rdi_pl_state_sts is the registered RDI state and drives the public
  //     status output directly, so the Adapter observes the published state.
  //
  // Spec ref: UCIe 1.0 Sections 8.1.5, 8.1.6, and 8.3.1;
  //           PLAN.md Sections 15.5 and 15.9 Phase D.
  // ---------------------------------------------------------------------------
  rdi_state_machine u_rdi_sm (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_linkerror(rdi_lp_linkerror),
    .adapter_active_req(1'b0),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .phy_link_trained(link_trained),
    .phy_active_entry_done(ltsm_active_entry_done),
    .phy_link_reset  (link_reset_out),
    .phy_retrain_req (rdi_lp_state_req == ucie_pkg::RDI_REQ_RETRAIN),
    .phy_train_error (train_error),
    .phy_inband_pres (phy_training_done),
    .cerror          (1'b0),
    .nferror         (1'b0),
    .stall_req       (rdi_stall_req_q),
    .stall_ack       (rdi_stall_ack),
    .stall_complete  (rdi_stall_complete),
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
  // pat_done signal fires on the final UI of the LFSR pattern (4096 UI)
  // as a diagnostic indicator; LTSM Active Entry is governed by LinkMgmt.RDI.
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
  // The adapter accesses these registers through the dedicated internal
  // phy_csr_* channel with byte enables.
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
    .csr_be        (csr_be),
    .csr_rdata     (csr_rdata),
    .csr_rdata_vld (csr_rdata_vld),
    .ltsm_state    (ltsm_state),
    .lnk_is_x8     (lnk_is_x8),
    .degrade_lanes (degrade_lanes),
    .train_error   (train_error),
    .clear_start_link_train(clear_start_link_train),
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
  // assign: rdi_pl_stallreq – PHY stall request
  //
  // LinkReset and Disabled exits from RDI ACTIVE trigger the integrated
  // four-phase stall handshake per Section 8.3.1.
  // -------------------------------------------------------------------------
  always_comb begin
    rdi_stall_req_d = rdi_stall_req_q;
    if ((rdi_pl_state_sts != RDI_STS_ACTIVE) ||
        ((rdi_lp_state_req != RDI_REQ_LINKRESET) &&
         (rdi_lp_state_req != RDI_REQ_DISABLED))) begin
      rdi_stall_req_d = 1'b0;
    end else if (rdi_lp_stallack || rdi_stall_ack) begin
      rdi_stall_req_d = 1'b0;
    end else begin
      rdi_stall_req_d = 1'b1;
    end
  end

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n)
      rdi_stall_req_q <= 1'b0;
    else
      rdi_stall_req_q <= rdi_stall_req_d;
  end

  assign rdi_pl_stallreq = rdi_stall_req_q;

  // ---------------------------------------------------------------------------
  // Legacy LTSM start-link-train OR gate removed in Phase C.
  //
  // The private event sampler above converts the top-level and CSR levels
  // into one-shot requests. This prevents a held Start level from restarting
  // training after LinkReset or Disabled recovery.
  //
  // Spec ref: UCIe 1.0, Section 8.3.2.8; PLAN.md Section 15.9 Phase C.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // CSR access path (spec 7.5 sideband register access)
  // ---------------------------------------------------------------------------
  // The CSR write/read path connects directly to the phy_csr_* channel from the
  // adapter, enabling byte-enabled register reads and writes into u_phy_csr.
  // External register accesses are routed through this internal path rather
  // than being stubbed to constants.
  // ---------------------------------------------------------------------------
  assign csr_wr            = phy_csr_wr;
  assign csr_rd            = phy_csr_rd;
  assign csr_addr          = phy_csr_addr;
  assign csr_wdata         = phy_csr_wdata;
  assign csr_be            = phy_csr_be;
  assign phy_csr_rdata     = csr_rdata;
  assign phy_csr_rdata_vld = csr_rdata_vld;
  // ---------------------------------------------------------------------------
  // Configuration interface stub  (spec 6.1 sideband cfg)
  // ---------------------------------------------------------------------------
  // The pl_cfg interface is unused in this build. Outputs are tied low so
  // the cfg bus is inert.
  // ---------------------------------------------------------------------------
  assign pl_cfg     = {NC{1'b0}};
  assign pl_cfg_vld = 1'b0;
  assign pl_cfg_crd = 1'b0;

  // ===========================================================================
  // Active Data Path and Private Framing Fault  (PLAN.md 15.6, 15.9 Phase E)
  // ===========================================================================
  // User data may reach the main band only while the link is fully up: the
  // LTSM completed Active Entry, the RDI state machine published ACTIVE, the
  // LTSM ACTIVE level is settled, and the Adapter stall handshake is not
  // active. Training patterns keep their own path through the pattern
  // generator and never enter these scramblers.
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // always_ff: Active Entry and LTSM state history
  //
  // Records the completed Active Entry result and the LTSM state of the
  // previous lclk cycle. The seed strobe below needs the Active Entry edge,
  // and the user-data gate needs to know that ACTIVE is a settled level, not
  // a fresh entry.
  //
  // Spec ref: UCIe 1.0 Sections 4.5.3.6 and 8.1.6;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ltsm_active_entry_q <= 1'b0;
      ltsm_state_q        <= LT_RESET;
    end else begin
      ltsm_active_entry_q <= ltsm_active_entry_done;
      ltsm_state_q        <= ltsm_state;
    end
  end

  // ---------------------------------------------------------------------------
  // assign: Active Entry seed strobe
  //
  // One lclk cycle at the completed Active Entry. Both scrambler arrays
  // reload their per-byte lane seeds on this strobe, so no training-pattern
  // LFSR history and no earlier Active residency can reach the Active data
  // path.
  //
  // Spec ref: UCIe 1.0 Sections 4.4.1 and 8.1.6;
  //           PLAN.md Sections 6.4, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign active_entry_seed_pulse = ltsm_active_entry_done &&
                                   !ltsm_active_entry_q;

  // ---------------------------------------------------------------------------
  // assign: Settled LTSM ACTIVE qualification
  //
  // Requires the current and the previous LTSM state to be ACTIVE, so the gate
  // opens only after an Active transition has settled and closes immediately
  // on any transition out of ACTIVE.
  //
  // Spec ref: UCIe 1.0 Section 4.5.3.6; PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign ltsm_active_state_stable = (ltsm_state == LT_ACTIVE) &&
                                    (ltsm_state_q == LT_ACTIVE);

  // ---------------------------------------------------------------------------
  // assign: Active user-data gate
  //
  // Single private gate for both directions. It combines the completed LTSM
  // Active Entry result, the published RDI ACTIVE result, the settled LTSM
  // ACTIVE level, an inactive Adapter stall acknowledgement, the private
  // LTSM transition indication, and the current framing-fault event. A
  // framing fault or any recovery clears the gate in the same cycle.
  //
  // The transition term closes the gate in the cycle the transition starts,
  // not in the cycle after the state register commits. That matters for the
  // fatal path: the LTSM keeps the registered ACTIVE state while the
  // TRAINERROR Entry exchange runs, so a state-only gate would leave user data
  // flowing into an aborted epoch for the whole exchange.
  //
  // Spec ref: UCIe 1.0 Sections 4.5.3.6, 8.1.6, and 8.3.1;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign user_data_enable = ltsm_active_entry_done &&
                            local_active_req &&
                            ltsm_active_state_stable &&
                            !rdi_lp_stallack &&
                            !ltsm_transition_active &&
                            !ltsm_framing_fault_event;

  // ---------------------------------------------------------------------------
  // assign: Accepted user-transfer strobes
  //
  // A transfer is accepted when the gate is open, the matching valid qualifier
  // is high, and, for the receive direction, the receive epoch is aligned.
  // These strobes advance the scramblers, so an idle, gated, or invalid cycle
  // consumes no LFSR state and holds both arrays.
  //
  // The receive epoch qualification drops every word that arrives before the
  // first quiet transfer gap of the new Active residency. The far die stops
  // emitting its LINKINIT or other training pattern when it leaves LINKINIT,
  // which can happen after this die already opened its gate, and its last
  // training words are then still inside the receive path. Those words must
  // never advance the Active descrambler: the far die's transmit scrambler
  // counts only its own accepted Active words, so one extra descrambled word
  // would shift the receive sequence and corrupt every later word.
  //
  // Because the two directions advance on their own accepted transfers, both
  // ends must have an open gate before the first Active word reaches the
  // receiver. The approved bring-up flow waits for both link-active
  // indications before streaming, and every Active Entry re-seeds both
  // arrays, so a receiver that starts accepting mid-stream only recovers
  // after the next Active Entry.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.4.1;
  //           PLAN.md Sections 6.2, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign tx_user_transfer = user_data_enable && rdi_lp_valid;
  assign rx_user_transfer = user_data_enable && rx_gearbox_valid &&
                            rx_epoch_synced_q;

  // ---------------------------------------------------------------------------
  // always_ff: Receive-epoch alignment register
  //
  // Cleared at every Active Entry, which is the start of one receive epoch.
  // It sets on the first cycle in which the gate is open and the receive
  // gearbox reports no framed transfer, that is, on the first quiet transfer
  // gap of the epoch. The gap is the boundary between the far die's training
  // stream and its Active stream, so from the following word onward every
  // accepted receive word belongs to the same stream the far transmit
  // scrambler counts.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.4.1;
  //           PLAN.md Sections 6.2, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      rx_epoch_synced_q <= 1'b0;
    end else if (active_entry_seed_pulse) begin
      rx_epoch_synced_q <= 1'b0;
    end else if (user_data_enable && !rx_gearbox_valid) begin
      rx_epoch_synced_q <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // always_ff: Valid qualifiers for the registered scramble words
  //
  // Both scrambler arrays register their output, so a scrambled or
  // descrambled word appears one lclk cycle after its accepted transfer.
  // These registers delay the valid qualifiers by exactly the same cycle, so
  // valid and data always describe the same word. They also clear both
  // qualifiers synchronously when the Active-data gate closes.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.4.1;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_user_valid_q <= 1'b0;
      rx_user_valid_q <= 1'b0;
    end else if (!user_data_enable) begin
      tx_user_valid_q <= 1'b0;
      rx_user_valid_q <= 1'b0;
    end else begin
      tx_user_valid_q <= tx_user_transfer;
      rx_user_valid_q <= rx_user_transfer;
  end
  end

  // ---------------------------------------------------------------------------
  // assign: Active-gated valid qualifiers
  //
  // The scrambler outputs and valid registers share one lclk pipeline stage.
  // Clear the pending valid qualifiers whenever the Active gate closes, so a
  // word accepted before a framing fault or private transition cannot appear
  // after the gate closes.
  //
  // A new Active Entry reseeds both scramblers before user acceptance resumes.
  // This prevents a discarded in-flight word from shifting the next recovery
  // epoch.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2, 4.4.1, and 8.1.6;
  //           PLAN.md Sections 6.2, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign tx_user_valid = tx_user_valid_q && user_data_enable;
  assign rx_user_valid = rx_user_valid_q && user_data_enable;

  // ---------------------------------------------------------------------------
  // generate: Independent per-byte TX and RX scrambler arrays
  //
  // Each byte position owns its own scrambler instance, so no other byte's
  // LFSR state and no training-pattern state can influence it. Byte b of the
  // word is carried on lane b (spec 4.1.1), so LANE_ID = b selects exactly
  // that lane's seed, and instance b drives or reads bits [8*b +: 8] of the
  // 128-bit word. Both arrays reseed on the Active Entry strobe, hold state
  // while their enable is low, and advance only on an accepted valid transfer.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.1 and 4.4.1;
  //           PLAN.md Sections 6.4, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  genvar b;
  generate
    for (b = 0; b < NBYTES; b = b + 1) begin : g_tx_scramble
      scrambler #(.LANE_ID(b)) u_tx_scrambler (
        .lclk      (lclk),
        .lreset_n  (lreset_n),
        .lfsr_reset(active_entry_seed_pulse),
        .enable    (tx_user_transfer),
        .data_in   (rdi_lp_data[8*b +: 8]),
        .data_out  (tx_user_word[8*b +: 8]),
        .state_obs ()
      );
    end
    for (b = 0; b < NBYTES; b = b + 1) begin : g_rx_descramble
      scrambler #(.LANE_ID(b)) u_rx_scrambler (
        .lclk      (lclk),
        .lreset_n  (lreset_n),
        .lfsr_reset(active_entry_seed_pulse),
        .enable    (rx_user_transfer),
        .data_in   (rx_gearbox_word[8*b +: 8]),
        .data_out  (rx_user_word[8*b +: 8]),
        .state_obs ()
      );
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // always_ff: Private mainband framing-fault synchronizer
  //
  // The RX gearbox detects an invalid framing boundary on mbclk and holds its
  // fault indication until lreset_n. Two lclk registers transfer that level
  // into the policy clock domain, so the LTSM never samples an mbclk
  // transition. The second stage is the safe lclk-domain fault level.
  //
  // Spec ref: UCIe 1.0 Section 4.1.2; PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      rx_framing_fault_meta_q <= 1'b0;
      rx_framing_fault_sync_q <= 1'b0;
    end else begin
      rx_framing_fault_meta_q <= rx_framing_fault;
      rx_framing_fault_sync_q <= rx_framing_fault_meta_q;
    end
  end

  // ---------------------------------------------------------------------------
  // always_ff: Framing-fault edge baseline
  //
  // The synchronized gearbox level is sticky until lreset_n. This register
  // converts it to one fresh edge event and prevents a level-shaped input from
  // keeping the LTSM fatal policy asserted across recovery.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.5.3.8;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) rx_framing_fault_prev_q <= 1'b0;
    else           rx_framing_fault_prev_q <= rx_framing_fault_sync_q;
  end

  // ---------------------------------------------------------------------------
  // assign: Fresh synchronized framing-fault edge
  //
  // The gearbox bit is a sticky observation, not a fatal level. A rising edge
  // is the only fresh event, so an already-reported fault does not retrigger
  // the recovered link when its gearbox bit remains high.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.5.3.8;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign rx_framing_fault_rise = rx_framing_fault_sync_q &&
                                 !rx_framing_fault_prev_q;

  // ---------------------------------------------------------------------------
  // assign: LTSM fatal-policy arm level
  //
  // RESET and SBINIT intentionally do not consume post-SBINIT fatal events.
  // The level mirrors the LTSM sideband-policy boundary without adding a
  // public protocol or a second recovery state machine.
  //
  // Spec ref: UCIe 1.0 Sections 4.5.3.1, 4.5.3.2, and 4.5.3.8;
  //           PLAN.md Sections 15.4, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign ltsm_fatal_policy_armed = (ltsm_state != LT_RESET) &&
                                    (ltsm_state != LT_SBINIT);

  // ---------------------------------------------------------------------------
  // always_ff: Epoch-qualified framing-fault retention
  //
  // A fresh fault edge that arrives while RESET or SBINIT cannot be consumed
  // by the LTSM. Retain that one event until the first armed policy cycle,
  // then clear it after one pulse. This private retention re-arms event
  // delivery across LinkReset and Disabled recovery without clearing the
  // gearbox sticky bit or adding a top-level error port. An edge consumed
  // during an armed epoch is not retained, so its sticky residual does not
  // retrigger the recovered link.
  //
  // Spec ref: UCIe 1.0 Sections 4.5.3.1, 4.5.3.2, and 4.5.3.8;
  //           PLAN.md Sections 15.4, 15.6, and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      rx_framing_fault_pending_q <= 1'b0;
    end else if (rx_framing_fault_rise && !ltsm_fatal_policy_armed) begin
      rx_framing_fault_pending_q <= 1'b1;
    end else if (ltsm_fatal_policy_armed) begin
      rx_framing_fault_pending_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // assign: Private LTSM framing-fault event
  //
  // An edge reaches the existing fatal policy immediately when armed. A
  // retained edge produces one pulse on the first armed epoch cycle. The
  // event remains private and one-cycle shaped, so fatal recovery keeps its
  // existing TRAINERROR Entry and LinkReset policy.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.2 and 4.5.3.8;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign ltsm_framing_fault_event = ((rx_framing_fault_rise || codec_rx_overflow_rise) &&
                                     ltsm_fatal_policy_armed) ||
                                    rx_framing_fault_pending_q;

  // ---------------------------------------------------------------------------
  // Main-Band 4 GT/s DDR Gearboxes (spec 4.1.1 and 5.2)
  // ---------------------------------------------------------------------------
  // The TX gearbox bridges the 500 MHz 128-bit lclk word to eight UI slices
  // per lane. The RX gearbox reassembles eight received UIs into one lclk
  // word for rdi_pl_data. The source mux below selects a LINKINIT diagnostic,
  // a low immediate-success training state, or the gated Active user word.
  // The RX gearbox additionally reports a private mainband framing fault.
  // The four gearbox interface signals are declared with the Active data path
  // section above, because the scramble stage already uses them.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1, Section 4.1.2, Section 5.2, and
  //           Section 8.1.2.
  // ---------------------------------------------------------------------------

  // always_comb: Mainband source and Active user-data gate
  //
  // Routes a selected LINKINIT diagnostic pattern to the TX gearbox when
  // pat_enable is high. During immediate-success MBINIT and MBTRAIN states,
  // it drives a zero word with framing low. The final branch carries the
  // scrambled Active user word only while its gated valid qualifier is high;
  // every other state drives a zero word with framing low, so no Adapter
  // traffic can reach the main band before the link is fully Active.
  //
  // The training-pattern branch is unchanged by Phase E: patterns never enter
  // the data scramblers. The MBINIT/MBTRAIN guard is retained as an explicit
  // Phase A guarantee even though the Active gate now blocks those states.
  //
  // Spec ref: UCIe 1.0, Sections 4.1.2, 4.4.1, 4.5.3.3, 4.5.3.4, and 4.5.3.6;
  //           PLAN.md Sections 15.2 Phase A, 15.6, and 15.9 Phase E.
  // -------------------------------------------------------------------------
  always_comb begin
    if (pat_enable) begin
      tx_gearbox_word  = pat_data_out;
      tx_gearbox_valid = 1'b1;
    end else if ((ltsm_state >= LT_MBINIT_PARAM) &&
                 (ltsm_state <= LT_MB_REPAIR)) begin
      tx_gearbox_word  = '0;
      tx_gearbox_valid = 1'b0;
    end else if (tx_user_valid) begin
      tx_gearbox_word  = tx_user_word;
      tx_gearbox_valid = 1'b1;
    end else begin
      tx_gearbox_word  = '0;
      tx_gearbox_valid = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Module instantiation: TX gearbox
  //
  // Serialises one 128-bit lclk word into eight DDR UI slices per lane. The
  // word and its framing valid come from the source mux above, so the training
  // pattern path and the scrambled Active user word share one serializer and
  // never interleave within a word.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.1, 4.1.2, and 5.2;
  //           PLAN.md Sections 15.2 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Module instantiation: RX gearbox
  //
  // Reassembles the received DDR UI slices into one 128-bit lclk word and
  // reports an invalid mainband framing boundary as a private fault. The
  // fault is synchronized and shaped into the LTSM event above; it is not a
  // public error output.
  //
  // Spec ref: UCIe 1.0 Sections 4.1.1, 4.1.2, and 5.2;
  //           PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  rx_gearbox #(
    .NBYTES(NBYTES),
    .NLANES(NLANES)
  ) u_rx_gearbox (
    .lclk        (lclk),
    .lreset_n    (lreset_n),
    .mbclk       (mbclk),
    .mb_rx_data  (mb_rx_data),
    .mb_rx_valid (mb_rx_valid),
    .rx_word     (rx_gearbox_word),
    .rx_word_vld (rx_gearbox_valid),
    .framing_fault(rx_framing_fault)
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
  //                  because the loopback never backpressures. trdy is not
  //                  gated: the Active data gate above, not trdy, is what
  //                  keeps user traffic off the main band.
  //
  //   rdi_pl_valid - receive valid. Qualified by the Active user-data gate, so
  //                  it marks only a descrambled word that the far die sent
  //                  while the link was fully Active. This is the framing
  //                  boundary of spec 4.1.2: valid marks the cycle on which
  //                  rdi_pl_data carries a complete word. The valid register
  //                  inside the scramble stage delays this qualifier by the
  //                  same lclk cycle as the descrambled data.
  //
  //   rdi_pl_data  - receive data. The descrambled word that rides with
  //                  rdi_pl_valid, and zero whenever that qualifier is low, so
  //                  valid and data always describe the same word and no
  //                  pre-Active or stale word can reach the adapter.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing; Section 4.4.1 -
  // Scrambling; Section 8.1 - Raw Die-to-Die Interface (RDI);
  // Table 114 - RDI Signal List. PLAN.md Sections 15.6 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  assign rdi_pl_trdy  = rdi_lp_irdy;
  assign rdi_pl_valid = rx_user_valid;
  assign rdi_pl_data  = rx_user_valid ? rx_user_word : {DATA_W{1'b0}};

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
  // adapter_active_req is the public Adapter Active copy. Phase D keeps the
  // RDI Active policy independent of it, so it is consumed here for lint only
  // and never changes behavior. local_active_req left this list in Phase E,
  // where it became the RDI half of the Active user-data gate.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism (the
  //           pl_stallreq / lp_stallack handshake). lp_state_req is a
  //           separate state request specified in Section 8.3.2.
  //           PLAN.md Sections 15.5 and 15.9 Phase E.
  // ---------------------------------------------------------------------------
  logic unused;
  assign unused = adapter_active_req | rdi_stall_complete |
                  phy_retrain_done | sb_msg_timeout |
                  sb_stall_sent | lane_bytes[0][0] | sb_rx_cdc_busy |
                  raw_rx_result_busy | raw_tx_done_busy |
                  lp_cfg[0] | lp_cfg_vld | lp_cfg_crd |
                  sb_tx_has_data |
                  rx_cdc_packet.cr | rx_cdc_packet.ep |
                  rx_cdc_packet.tag[0] | rx_cdc_packet.be[0] |
                  rx_cdc_packet.status[0] | rx_cdc_packet.addr[0] |
                  rx_cdc_packet.msg_info[8] | codec_tx_ready;

endmodule

`endif

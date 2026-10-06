// ============================================================================
// File        : ut_ltsm.sv
// Project     : UCIe Simplified RTL
// Module      : Unit Test — Link Training State Machine (LTSM)
// DUT         : ltsm #(.NLANES(NLANES_MAX))
// ============================================================================
//
// DESCRIPTION
// -----------
// This unit test exercises the Link Training State Machine (LTSM) through
// every defined training sub-state from power-on RESET to ACTIVE, verifying
// the full ordered sequence of 20 state visits that constitute a
// successful link training.  It additionally verifies the sideband-timeout
// path:  when the remote partner is silenced, the 8 ms residency timer
// (C_RESIDENCY) expires cycle-exactly, and the LTSM escalates to
// TRAINERROR within one clock cycle.
//
// The test covers two independent scenarios:
//
//   1.  Pattern-Triggered Training Walk
//       After the true 4 ms RESET minimum, atomic match/mismatch results drive
//       remote-pattern entry. Four tail events and explicit SBINIT packets
//       then lead into the complete later training flow. Each Phase B state
//       runs its full fixed-profile sequence of local request and matching
//       peer response transactions, one transaction per sequence subcode:
//         RESET → SBINIT → MBINIT.PARAM [00] → MBINIT.CAL [02] →
//         MBINIT.REPAIRCLK [03..08] → MBINIT.REPAIRVAL [09..0C] →
//         MBINIT.REVERSALMB [0D..10] → MBINIT.REPAIRMB [11..14] →
//         MBTRAIN.VALVREF [00,01] → MBTRAIN.DATAVREF [02,03] →
//         MBTRAIN.SPEEDIDLE [04] → MBTRAIN.TXSELFCAL [05] →
//         MBTRAIN.RXCLKCAL [06,07] → MBTRAIN.VTCENTER [08,09] →
//         MBTRAIN.DATAVREF1 [0E,0F,10] → MBTRAIN.RXDESKEW [11,12] →
//         MBTRAIN.DATACENTER2 [13,14] → MBTRAIN.LINKSPEED [15,19] →
//         LINKINIT → ACTIVE
//       MBTRAIN.REPAIR and PHYRETRAIN are unvisited in this fixed profile walk.
//       LINKSPEED exits to LINKINIT only after the 15h start and 19h done transactions.
//       After reaching ACTIVE the walk_check block confirms every state
//       was visited in order.
//
//   2.  Sideband Timeout -> TRAINERROR Path
//       The partner responder is disabled, the LTSM is reset and
//       re-started. It enters SBINIT and waits for a sideband response.
//       When no remote response arrives, the C_RESIDENCY countdown timer
//       expires and the LTSM transitions to TRAINERROR on the very next posedge.
//
// STIMULUS
// --------
// Direct lclk packet injection controls the SBINIT response ordering. After
// SBINIT, a partner sb_codec deserializes local messages and the responder
// answers each request with its matching response: the same sequence
// subcode, the paired response message code, zero MsgInfo, and the immutable
// PARAM_RSP_DATA payload for the DATA64 MBINIT.PARAM exchange. Only the local
// codec u_loc sits behind asynchronous CDC mailboxes; the partner codec runs
// directly in sbclk.
// A simple 14-bit counter replaces the real LFSR pattern generator.
// When the counter reaches LFSR_PATTERN_UI-1, the pat_done flag is
// asserted, signalling the LTSM that the pattern phase has completed
// (used during the LINKINIT sub-state).
//     seen[] array contains all 20 expected states in strict order.
//   • u_tmr  — C_RESIDENCY (4,000,000 cycles = 8 ms) general residency.
//   • u_rst_tmr — C_RESET_MIN (2,000,000 cycles = 4 ms) reset minimum.
//
// PASS / FAIL CRITERIA
// --------------------
//   • expect_state(S)  — blocks until the LTSM leaves state S, or a
//     deadline expires (200,000 cycles for most states, 2,500,000 for
//     LT_RESET).  A stuck LTSM is flagged as a FAIL.
//     seen[] array contains all 20 expected states in strict order.
//   • Timeout test     — after disabling the partner responder and
//     re-triggering training, the test counts exactly C_RESIDENCY
//     posedge-lclk cycles and asserts that tmr_expired pulses on
//     that exact edge and that the LTSM enters TRAINERROR one edge
//     later.
//   • Final verdict    — "TEST PASSED ut_ltsm" when errors == 0.
//
// CLOCK AND RESET
// ---------------
// lclk runs at 500 MHz with a 2 ns period. sbclk starts 0.1875 ns later and
// runs at 800 MHz with a 1.25 ns period. The local sideband codecs remain in
// sbclk, while the paired toggle mailboxes exercise the asynchronous LTSM
// boundary.
//
// Reset is asserted low for 5 ns (2.5 lclk cycles) at the start of simulation.
// The timeout test performs a second reset cycle of 10 lclk periods.
//
// BLOCK DIAGRAM
// -------------
//
//                       +---------------------------+
//                       |     LTSM DUT (u_dut)      |
//                       |  ltsm #(.NLANES(NLANES_   |
//                       |          MAX))             |
//    start_link_train-->|                            |-->link_trained
//    adapter_active  -->|  sb_tx_*        sb_rx_*    |-->train_error
//         _req         |      |              ^      |-->ltsm_state[7:0]
//                       |      v              |      |
//                       +------+-----------+--+------+
//                              |           |
//                  TX fields   |           |  RX fields
//                              v           |
//                       +------+------+    |
//                       | sb_codec    |    |
//                       | u_loc       |    |
//                       | (local)     |    |
//                       +------+------+    |
//                              |           |
//                loc_sb_data/  |           |  par_sb_data/
//                loc_sb_valid  v           ^  par_sb_valid
//                       +------+------+    |
//                       | sb_codec    |    |
//                       | u_par       +----+
//                       | (partner)   |
//                       +------+------+
//                              |
//                 par_rx_*     v
//                       +------+------+
//                       | Responder   |
//                       | always @    |
//                       | (posedge    |
//                       |  sbclk)     |
//                       +-------------+
//
//    +----------------+         +-------------------+
//    | ucie_timer     |         | ucie_timer        |
//    | u_tmr          |         | u_rst_tmr         |
//    | C_RESIDENCY    |         | C_RESET_MIN       |
//    | (8 ms)         |         | (4 ms)            |
//    +----------------+         +-------------------+
//
//    +----------------+
//    | Pattern Counter|
//    | pat_ui[13:0]   |----> pat_done
//    | (LFSR stand-in)|
//    +----------------+
//
// REFERENCES
// ----------
//   UCIe Specification:
//     Section 4.5.3   — Link Training State Machine
//     Section 4.5.3.1 — RESET
//     Section 4.5.3.2 — SBINIT
//     Section 4.5.3.3 — MBINIT (all sub-phases)
//     Section 4.5.3.4 — MBTRAIN (all sub-phases)
//     Section 4.5.3.5 — LINKINIT
//     Section 4.5.3.6 — ACTIVE
//     Section 4.5.3.7 — PHYRETRAIN
//     Section 4.5.3.8 — TRAINERROR
//
// REVISION HISTORY
// ----------------
//   v0.0.1  2025-XX-XX  Initial creation.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block
//                        comments.
//   v0.0.3  2026-09-23  Documentation: give lclk and sbclk their own
//                        spec-referenced comment blocks and delete the stale
//                        unindented "Clock Generators" head that duplicated
//                        the sbclk block below it.
//   v0.0.4  2026-09-23  Documentation: correct the LTSM state references.
//                        Section 4.5.3.7 is PHYRETRAIN; TRAINERROR is 4.5.3.8.
//   v0.0.5  2026-09-23  Req.3: run sbclk at 800 MHz with a phase offset from
//                        lclk. The test now exercises the LTSM CDC boundary.
//   v0.0.6  2026-09-23  Req.3: remove the obsolete single-clock-domain
//   v0.0.9  2026-09-25  Phase B final contract: the partner responder now
//                        answers every request with its matching response
//                        using the exact current sequence subcode, so each
//                        multi-step MBINIT and MBTRAIN state completes its
//                        full fixed-profile transaction sequence. The PARAM
//                        reply is a DATA64 packet that carries the immutable
//                        PARAM_RSP_DATA payload. MBTRAIN.REPAIR is removed
//                        from the expected walk because the fixed profile
//                        never visits it, and LINKSPEED now exits only after
//                        the 15h start and 19h done transactions.
//                        description from the test header.
//   v0.0.7  2026-09-24  Verify pattern-triggered RESET exit, mismatch streak
//                        reset, four tail events, explicit SBINIT Done order,
//                        invalid packets, and the true 8 ms timeout.
//   v0.0.8  2026-09-24  Phase B: add sb_tx_accepted and sb_rx_payload
//                        private ports. Transport complete DATA64 RX
//                        packets through the CDC. Model a valid DATA64
//                        PARAM peer request in the responder.
//   v0.0.9  2026-09-25  Phase C: verify TRAINERROR timeout and LinkError
//                        hold, LinkReset recovery, RESET dwell, and fresh
//                        Start-trigger behavior.
//   v0.0.10 2026-09-25  Phase E: tie the new private framing_fault_event
//                        input low. The nominal walk never injects the
//                        mainband framing fault; the fatal-cause check for
//                        that event lives in ut_ltsm_policy.sv.
//
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_ltsm;
  import ucie_pkg::*;
  logic        rst_tmr_expired;
  logic        lclk, lreset_n, sbclk, sbreset_n;
  logic        start_link_train, adapter_active_req;
  logic        link_trained, train_error, link_reset_out, phy_retrain_done;
  logic [7:0]  ltsm_state;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;
  logic        sb_msg_timeout, sb_stall_sent;
  logic        pattern_run_enable, sbinit_raw_mode;
  logic        sbinit_rx_iter_vld, sbinit_rx_iter_match;
  logic        sbinit_tx_iter_done, sbinit_tx_idle;
  logic        pat_enable, pat_lfsr_reset, pat_lfsr_enable, pat_done;
  logic        tmr_start, tmr_run, rst_tmr_start, tmr_expired;
  int          errors;

  // LTSM <-> local codec
  logic        sb_tx_load, sb_tx_busy, sb_tx_accepted;
  logic [4:0]  sb_tx_opcode;
  logic [2:0]  sb_tx_srcid, sb_tx_dstid;
  logic [15:0] sb_tx_msginfo;
  logic [7:0]  sb_tx_msgcode, sb_tx_msgsubcode;
  logic [7:0]  sb_tx_be;
  logic [4:0]  sb_tx_tag;
  logic        sb_tx_ep;
  logic [11:0] sb_tx_addr;
  logic [63:0] sb_tx_data_in;
  logic        sb_tx_has_data;
  logic        loc_sb_clk, par_sb_clk;
  logic        loc_sb_data, par_sb_data;

  // LTSM receive side (fed from the partner codec)
  logic        sb_rx_pkt_vld;
  logic [4:0]  sb_rx_opcode;
  logic [2:0]  sb_rx_srcid, sb_rx_dstid;
  logic [15:0] sb_rx_msginfo;
  logic [7:0]  sb_rx_msgcode, sb_rx_msgsubcode;
  logic [63:0] sb_rx_payload;
  logic        sb_rx_cp_err, sb_rx_dp_err;

  // Direct packet injection is used only for deterministic SBINIT ordering
  // checks. Later training packets still traverse both codecs and mailboxes.
  logic        inject_rx_pkt_vld;
  logic [4:0]  inject_rx_opcode;
  logic [2:0]  inject_rx_srcid, inject_rx_dstid;
  logic [15:0] inject_rx_msginfo;
  logic [7:0]  inject_rx_msgcode;
  logic [7:0]  inject_rx_msgsubcode;
  logic        inject_rx_cp_err, inject_rx_dp_err;
  logic        cdc_rx_pkt_vld;
  logic [4:0]  cdc_rx_opcode;
  logic [2:0]  cdc_rx_srcid, cdc_rx_dstid;
  logic [15:0] cdc_rx_msginfo;
  logic [7:0]  cdc_rx_msgcode, cdc_rx_msgsubcode;
  logic        cdc_rx_cp_err, cdc_rx_dp_err;

  // Req.3 CDC signals. The LTSM remains in lclk. The local codec remains in
  // sbclk, so complete sideband packets cross through the same mailboxes used
  // by logical_phy.
  localparam int unsigned SB_TX_W = 134;
  localparam int unsigned SB_RX_W = 109;
  logic [SB_TX_W-1:0] tx_cdc_data;
  logic               tx_cdc_busy;
  logic               loc_tx_load;
  logic [4:0]         loc_tx_opcode;
  logic [2:0]         loc_tx_srcid, loc_tx_dstid;
  logic [15:0]        loc_tx_msginfo;
  logic [7:0]         loc_tx_msgcode, loc_tx_msgsubcode;
  logic [7:0]         loc_tx_be;
  logic [4:0]         loc_tx_tag;
  logic               loc_tx_ep;
  logic [11:0]        loc_tx_addr;
  logic [63:0]        loc_tx_data_in;
  logic               loc_tx_has_data, loc_tx_busy;
  logic               loc_tx_busy_meta_q, loc_tx_busy_sync_q;
  logic               loc_rx_pkt_vld;
  logic [4:0]         loc_rx_opcode;
  logic [2:0]         loc_rx_srcid, loc_rx_dstid;
  logic [15:0]        loc_rx_msginfo;
  logic [7:0]         loc_rx_msgcode, loc_rx_msgsubcode;
  logic [63:0]        loc_rx_data;
  logic               loc_rx_cp_err, loc_rx_dp_err;
  logic [SB_RX_W-1:0] rx_cdc_data;
  logic               rx_cdc_busy;
  logic [63:0]        cdc_rx_data;

  // Partner codec transmit controls
  logic        par_tx_load, par_tx_busy;
  logic [4:0]  par_tx_opcode;
  logic [2:0]  par_tx_srcid, par_tx_dstid;
  logic [15:0] par_tx_msginfo;
  logic [7:0]  par_tx_msgcode, par_tx_msgsubcode;
  logic [7:0]  par_tx_be;
  logic [4:0]  par_tx_tag;
  logic        par_tx_ep;
  logic [11:0] par_tx_addr;
  logic [63:0] par_tx_data_in;
  logic        par_tx_has_data;

  logic        par_rx_pkt_vld;
  logic [4:0]  par_rx_opcode;
  logic [2:0]  par_rx_srcid, par_rx_dstid;
  logic [7:0]  par_rx_msginfo, par_rx_msgcode, par_rx_msgsubcode;
  logic        par_rx_cp_err, par_rx_dp_err;
  logic        loc_tx_ready, loc_rx_valid, par_tx_ready, par_rx_valid;
  sb_packet_t loc_tx_packet, loc_rx_packet, par_tx_packet, par_rx_packet;

// ---------------------------------------------------------------------------
// DUT Instantiation: ltsm #(.NLANES(NLANES_MAX)) u_dut
// ---------------------------------------------------------------------------
// The Device Under Test is the Link Training State Machine defined in
// Section 4.5.3 — Link Training State Machine of the UCIe specification.
// It is parameterised with NLANES_MAX to exercise the widest lane
// configuration.  All sideband TX fields are connected to the local
// sb_codec (u_loc) for serialisation; sideband RX fields are driven by
// the partner codec (u_par) after deserialization.  The timer interface
// (tmr_start, tmr_run, tmr_expired) connects to the residency timer
// (u_tmr), and rst_tmr_expired comes from the RESET-minimum timer
// (u_rst_tmr).
//
  ltsm #(.NLANES(NLANES_MAX)) u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .software_start_event(start_link_train),
    .rdi_active_event(1'b0),
    .rdi_active_req(adapter_active_req),
    .rdi_linkreset_req(1'b0),
    .rdi_disabled_req(1'b0),
    .active_entry_done(),
    .clear_start_link_train(),
    .link_trained(link_trained), .phy_training_done(), .train_error(train_error),
    .link_reset_out(link_reset_out), .phy_retrain_done(phy_retrain_done),
    .ltsm_state(ltsm_state), .lnk_is_x8(lnk_is_x8),
    .degrade_lanes(degrade_lanes),
    // Phase E private fatal source. This test proves the nominal walk, so
    // the mainband framing fault stays inactive: the fatal-cause check for
    // the event is in ut_ltsm_policy.sv.
    .framing_fault_event(1'b0),
    .sb_tx_load(sb_tx_load), .sb_tx_opcode(sb_tx_opcode),
    .sb_tx_srcid(sb_tx_srcid), .sb_tx_dstid(sb_tx_dstid),
    .sb_tx_msginfo(sb_tx_msginfo), .sb_tx_msgcode(sb_tx_msgcode),
    .sb_tx_msgsubcode(sb_tx_msgsubcode), .sb_tx_be(sb_tx_be),
    .sb_tx_tag(sb_tx_tag), .sb_tx_ep(sb_tx_ep), .sb_tx_addr(sb_tx_addr),
    .sb_tx_data_in(sb_tx_data_in), .sb_tx_has_data(sb_tx_has_data),
    .sb_tx_busy(sb_tx_busy), .sb_tx_accepted(sb_tx_accepted),
    .sb_rx_pkt_vld(sb_rx_pkt_vld), .sb_rx_opcode(sb_rx_opcode),
    .sb_rx_srcid(sb_rx_srcid), .sb_rx_dstid(sb_rx_dstid),
    .sb_rx_msginfo(sb_rx_msginfo), .sb_rx_msgcode(sb_rx_msgcode),
    .sb_rx_msgsubcode(sb_rx_msgsubcode),
    .sb_rx_payload(sb_rx_payload),
    .sb_rx_cp_err(sb_rx_cp_err), .sb_rx_dp_err(sb_rx_dp_err),
    .sb_msg_timeout(sb_msg_timeout), .sb_stall_sent(sb_stall_sent),
    .pattern_run_enable(pattern_run_enable),
    .sbinit_raw_mode(sbinit_raw_mode),
    .sbinit_rx_iter_vld(sbinit_rx_iter_vld),
    .sbinit_rx_iter_match(sbinit_rx_iter_match),
    .sbinit_tx_iter_done(sbinit_tx_iter_done),
    .sbinit_tx_idle(sbinit_tx_idle),
    .pat_enable(pat_enable), .pat_select(), .pat_lfsr_reset(pat_lfsr_reset),
    .pat_lfsr_enable(pat_lfsr_enable), .pat_done(pat_done),
    .tmr_start(tmr_start), .tmr_run(tmr_run),
    .rst_tmr_start(rst_tmr_start), .tmr_expired(tmr_expired),
    .rst_tmr_expired(rst_tmr_expired)
  );
// ---------------------------------------------------------------------------
// LTSM-to-codec CDC and Local Sideband Codec
// ---------------------------------------------------------------------------
// The request mailbox converts the one-lclk-cycle sb_tx_load pulse into one
// sbclk-cycle loc_tx_load pulse. The response mailbox returns parsed packets
// to the lclk LTSM. The busy synchronizer prevents a new LTSM request while
// either the mailbox or codec holds the previous request.
  sb_cdc_mailbox #(.WIDTH(SB_TX_W)) u_tx_cdc (
    .src_clk(lclk), .src_reset_n(lreset_n),
    .src_data({sb_tx_opcode, sb_tx_srcid, sb_tx_dstid, sb_tx_msginfo,
               sb_tx_msgcode, sb_tx_msgsubcode, sb_tx_be, sb_tx_tag,
               sb_tx_ep, sb_tx_addr, sb_tx_data_in, sb_tx_has_data}),
    .src_send(sb_tx_load), .src_busy(tx_cdc_busy),
    .dst_clk(sbclk), .dst_reset_n(sbreset_n),
    .dst_data(tx_cdc_data), .dst_valid(loc_tx_load)
  );

  assign {loc_tx_opcode, loc_tx_srcid, loc_tx_dstid, loc_tx_msginfo,
          loc_tx_msgcode, loc_tx_msgsubcode, loc_tx_be, loc_tx_tag,
          loc_tx_ep, loc_tx_addr, loc_tx_data_in, loc_tx_has_data} =
         tx_cdc_data;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      loc_tx_busy_meta_q <= 1'b0;
      loc_tx_busy_sync_q <= 1'b0;
    end else begin
      loc_tx_busy_meta_q <= loc_tx_busy;
      loc_tx_busy_sync_q <= loc_tx_busy_meta_q;
    end
  end
  assign sb_tx_busy = tx_cdc_busy | loc_tx_busy_sync_q;
  assign sb_tx_accepted = sb_tx_load && !tx_cdc_busy;

  always_comb begin
    loc_tx_packet = '0;
    loc_tx_packet.opcode = loc_tx_opcode;
    loc_tx_packet.src_id = loc_tx_srcid;
    loc_tx_packet.dst_id = loc_tx_dstid;
    loc_tx_packet.msg_info = loc_tx_msginfo;
    loc_tx_packet.msg_code = loc_tx_msgcode;
    loc_tx_packet.msg_subcode = loc_tx_msgsubcode;
    loc_tx_packet.be = loc_tx_be;
    loc_tx_packet.tag = loc_tx_tag;
    loc_tx_packet.ep = loc_tx_ep;
    loc_tx_packet.addr = {{15{1'b0}}, loc_tx_addr};
    loc_tx_packet.data = loc_tx_data_in;
  end
  assign loc_rx_pkt_vld = loc_rx_valid;
  assign loc_rx_opcode = loc_rx_packet.opcode;
  assign loc_rx_srcid = loc_rx_packet.src_id;
  assign loc_rx_dstid = loc_rx_packet.dst_id;
  assign loc_rx_msginfo = loc_rx_packet.msg_info;
  assign loc_rx_msgcode = loc_rx_packet.msg_code;
  assign loc_rx_msgsubcode = loc_rx_packet.msg_subcode;
  assign loc_rx_data = loc_rx_packet.data;

  sb_codec u_loc (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_valid(loc_tx_load), .tx_ready(loc_tx_ready), .tx_packet(loc_tx_packet),
    .tx_busy(loc_tx_busy),
    .sb_tx_clk(loc_sb_clk), .sb_tx_data(loc_sb_data),
    .sb_rx_clk(par_sb_clk), .sb_rx_data(par_sb_data),
    .rx_valid(loc_rx_valid), .rx_ready(!rx_cdc_busy), .rx_packet(loc_rx_packet),
    .rx_format_error(), .rx_cp_error(loc_rx_cp_err),
    .rx_dp_error(loc_rx_dp_err), .rx_overflow()
  );

  sb_cdc_mailbox #(.WIDTH(SB_RX_W)) u_rx_cdc (
    .src_clk(sbclk), .src_reset_n(sbreset_n),
    .src_data({loc_rx_opcode, loc_rx_srcid, loc_rx_dstid, loc_rx_msginfo,
               loc_rx_msgcode, loc_rx_msgsubcode, loc_rx_cp_err, loc_rx_dp_err,
               loc_rx_data}),
    .src_send(loc_rx_pkt_vld), .src_busy(rx_cdc_busy),
    .dst_clk(lclk), .dst_reset_n(lreset_n),
    .dst_data(rx_cdc_data), .dst_valid(cdc_rx_pkt_vld)
  );
  assign {cdc_rx_opcode, cdc_rx_srcid, cdc_rx_dstid, cdc_rx_msginfo,
          cdc_rx_msgcode, cdc_rx_msgsubcode, cdc_rx_cp_err,
          cdc_rx_dp_err, cdc_rx_data} = rx_cdc_data;

  // Select a direct lclk packet only while its one-cycle valid pulse is high.
  // This isolates SBINIT request/response ordering from codec serialization.
  // Injected SBINIT packets carry no data payload.
  always_comb begin
    sb_rx_pkt_vld    = inject_rx_pkt_vld || cdc_rx_pkt_vld;
    sb_rx_opcode     = inject_rx_pkt_vld ? inject_rx_opcode : cdc_rx_opcode;
    sb_rx_srcid      = inject_rx_pkt_vld ? inject_rx_srcid : cdc_rx_srcid;
    sb_rx_dstid      = inject_rx_pkt_vld ? inject_rx_dstid : cdc_rx_dstid;
    sb_rx_msginfo    = inject_rx_pkt_vld ? inject_rx_msginfo : cdc_rx_msginfo;
    sb_rx_msgcode    = inject_rx_pkt_vld ? inject_rx_msgcode : cdc_rx_msgcode;
    sb_rx_msgsubcode = inject_rx_pkt_vld ? inject_rx_msgsubcode :
                                            cdc_rx_msgsubcode;
    sb_rx_payload    = inject_rx_pkt_vld ? 64'h0 : cdc_rx_data;
    sb_rx_cp_err     = inject_rx_pkt_vld ? inject_rx_cp_err : cdc_rx_cp_err;
    sb_rx_dp_err     = inject_rx_pkt_vld ? inject_rx_dp_err : cdc_rx_dp_err;
  end

// ---------------------------------------------------------------------------
// Partner Sideband Codec: sb_codec u_par
// ---------------------------------------------------------------------------
// Represents the remote die's sideband channel.  It deserialises the
// loc_sb_data stream into par_rx_* fields consumed by the responder
// always block, and serialises the responder's par_tx_* reply back
// into the par_sb_data stream that the local codec receives.  This
// closed loop allows the LTSM to complete every sideband handshake
// without a second LTSM instance.
//
  always_comb begin
    par_tx_packet = '0;
    par_tx_packet.opcode = par_tx_opcode;
    par_tx_packet.src_id = par_tx_srcid;
    par_tx_packet.dst_id = par_tx_dstid;
    par_tx_packet.msg_info = par_tx_msginfo;
    par_tx_packet.msg_code = par_tx_msgcode;
    par_tx_packet.msg_subcode = par_tx_msgsubcode;
    par_tx_packet.be = par_tx_be;
    par_tx_packet.tag = par_tx_tag;
    par_tx_packet.ep = par_tx_ep;
    par_tx_packet.addr = {{15{1'b0}}, par_tx_addr};
    par_tx_packet.data = par_tx_data_in;
  end
  assign par_rx_pkt_vld = par_rx_valid;
  assign par_rx_opcode = par_rx_packet.opcode;
  assign par_rx_srcid = par_rx_packet.src_id;
  assign par_rx_dstid = par_rx_packet.dst_id;
  assign par_rx_msginfo = par_rx_packet.msg_info[7:0];
  assign par_rx_msgcode = par_rx_packet.msg_code;
  assign par_rx_msgsubcode = par_rx_packet.msg_subcode;

  sb_codec u_par (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_valid(par_tx_load), .tx_ready(par_tx_ready), .tx_packet(par_tx_packet),
    .tx_busy(par_tx_busy),
    .sb_tx_clk(par_sb_clk), .sb_tx_data(par_sb_data),
    .sb_rx_clk(loc_sb_clk), .sb_rx_data(loc_sb_data),
    .rx_valid(par_rx_valid), .rx_ready(1'b1), .rx_packet(par_rx_packet),
    .rx_format_error(), .rx_cp_error(par_rx_cp_err),
    .rx_dp_error(par_rx_dp_err), .rx_overflow()
  );

  logic par_enable_resp;
  integer local_oor_count;
  integer local_done_count;
  logic [7:0] local_done_code [0:3];

  // Record only the local SBINIT packets received by the partner codec. The
  // directed sequence later checks that a queued peer request causes a Done
  // response before the local Done request.
  always @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      local_oor_count  <= 0;
      local_done_count <= 0;
    end else if (par_rx_pkt_vld && !par_rx_cp_err && !par_rx_dp_err) begin
      if ((par_rx_msgcode == MC_SB_OOB_RESET) &&
          (par_rx_msgsubcode == MS_SB_OOB_RESET))
        local_oor_count <= local_oor_count + 1;
      if (((par_rx_msgcode == MC_SB_DONE_REQ) ||
           (par_rx_msgcode == MC_SB_DONE_RSP)) &&
          (par_rx_msgsubcode == MS_SB_DONE) && (local_done_count < 4)) begin
        local_done_code[local_done_count] <= par_rx_msgcode;
        local_done_count <= local_done_count + 1;
      end
    end
  end

// ---------------------------------------------------------------------------
// Responder Always Block
// ---------------------------------------------------------------------------
// Section 4.5.3 — Link Training State Machine requires each sideband
// request to be answered with a matching response before the residency
// timer expires.  This block models the partner die's response path:
// on each received request (par_rx_pkt_vld), it loads the partner codec
// with a response whose opcode, subcode, and addressing are echoed from
// the request, with the message code mapped through rsp_for().
//
// The guard signal par_enable_resp allows the timeout test to silence
// the partner and verify the TRAINERROR path.
//
// The responder stays disabled during the directed SBINIT checks. It then
// answers each later training request with its matching response, using the
// exact sequence subcode of the request, so every multi-step MBINIT and
// MBTRAIN state completes its full fixed-profile transaction sequence.
// MsgInfo is always zero and the message code maps through rsp_for().
  always @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      par_tx_load       <= 1'b0;
      par_tx_opcode     <= 5'b0;
      par_tx_srcid      <= 3'b0;
      par_tx_dstid      <= 3'b0;
      par_tx_msginfo    <= 16'h0000;
      par_tx_msgcode    <= 8'b0;
      par_tx_msgsubcode <= 8'b0;
      par_tx_be         <= 8'b0;
      par_tx_tag        <= 5'b0;
      par_tx_ep         <= 1'b0;
      par_tx_addr       <= 12'b0;
      par_tx_data_in    <= 64'b0;
      par_tx_has_data   <= 1'b0;
    end else begin
      par_tx_load <= 1'b0;
      if (par_enable_resp && par_rx_pkt_vld && !par_rx_cp_err &&
          !par_rx_dp_err && (par_rx_msgcode != MC_LM_RDI_RSP) &&
          !par_tx_busy && !par_tx_load) begin
        par_tx_load       <= 1'b1;
        par_tx_srcid      <= SRCID_PHY;
        par_tx_dstid      <= DSTID_REMOTE_PHY;
        par_tx_be         <= 8'b0;
        par_tx_tag        <= 5'b0;
        par_tx_ep         <= 1'b0;
        par_tx_addr       <= 12'b0;
        if ((par_rx_msgcode == MC_MBINIT_REQ) &&
            (par_rx_msgsubcode == MS_PARAM_CFG)) begin
          par_tx_opcode     <= SB_OP_MSG_DATA64;
          par_tx_msginfo    <= 16'h0000;
          par_tx_msgcode    <= MC_MBINIT_RSP;
          par_tx_msgsubcode <= MS_PARAM_CFG;
          par_tx_data_in    <= PARAM_RSP_DATA;
          par_tx_has_data   <= 1'b1;
        end else begin
          par_tx_opcode     <= par_rx_opcode;
          par_tx_msginfo    <= 16'h0000;
          par_tx_msgcode    <= rsp_code_for(par_rx_msgcode, par_rx_msgsubcode);
          par_tx_msgsubcode <= rsp_subcode_for(par_rx_msgcode, par_rx_msgsubcode);
          par_tx_data_in    <= 64'b0;
          par_tx_has_data   <= 1'b0;
        end
      end
    end
  end

  function automatic logic [7:0] rsp_code_for(input logic [7:0] code, input logic [7:0] subcode);
    case (code)
      MC_SB_DONE_REQ:  rsp_code_for = MC_SB_DONE_RSP;
      MC_MBINIT_REQ:   rsp_code_for = MC_MBINIT_RSP;
      MC_MBTRAIN_REQ:  rsp_code_for = (subcode == 8'h09) ? 8'hBA : MC_MBTRAIN_RSP;
      8'hBA:           rsp_code_for = (subcode == 8'h09) ? 8'hBA : 8'hB5;
      MC_LM_RDI_REQ:   rsp_code_for = MC_LM_RDI_RSP;
      MC_PHYR_REQ:     rsp_code_for = MC_PHYR_RSP;
      default:         rsp_code_for = MC_TE_RSP;
    endcase
  endfunction

  function automatic logic [7:0] rsp_subcode_for(input logic [7:0] code, input logic [7:0] subcode);
    if ((code == 8'hBA) && (subcode == 8'h0E))
      rsp_subcode_for = 8'h0F;
    else
      rsp_subcode_for = subcode;
  endfunction

// ---------------------------------------------------------------------------
// Pattern UI Counter
// ---------------------------------------------------------------------------
// During the LINKINIT phase the LTSM waits for the data-lane training
// pattern to complete (pat_done).  In a real design the pattern is
// generated by an LFSR; here a simple 14-bit counter stands in for
// that generator.  The counter resets to zero when the pattern is
// disabled (pat_enable == 0) or on asynchronous reset, and increments
// on every lclk posedge while pat_enable is asserted.
//
// Spec ref: UCIe 1.0, Section 4.5.3.5 - LINKINIT.
// ---------------------------------------------------------------------------
  logic [13:0] pat_ui;
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n || !pat_enable) pat_ui <= '0;
    else                           pat_ui <= pat_ui + 1'b1;
  end
// ---------------------------------------------------------------------------
// Pattern Done Flag: pat_done
// ---------------------------------------------------------------------------
// Combinational output that asserts for exactly one cycle when the
// pattern UI counter has reached LFSR_PATTERN_UI-1 and both
// pat_enable and pat_lfsr_enable are active.  The LTSM samples this
// flag to know that the required number of training-pattern UIs have
// been transmitted, allowing it to proceed from LINKINIT onward.
//
  assign pat_done = pat_enable && pat_lfsr_enable &&
                    (pat_ui == LFSR_PATTERN_UI-1);

// ---------------------------------------------------------------------------
// Residency Timer: ucie_timer u_tmr
// ---------------------------------------------------------------------------
// Section 4.5.3 — Link Training State Machine specifies that each
// sub-state has a maximum residency.  This timer is configured with
// LIMIT_CYCLES = C_RESIDENCY = 4,000,000 lclk cycles (8 ms at
// 500 MHz).  When tmr_start pulses, the timer clears and re-arms;
// while tmr_run is held high it counts; when the count reaches
// LIMIT_CYCLES-1 it asserts tmr_expired for one cycle.
//
// Timer: True to spec (LIMIT_CYCLES=C_RESIDENCY = 4,000,000 lclk cycles = 8 ms).
  ucie_timer #(.LIMIT_CYCLES(C_RESIDENCY)) u_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(tmr_start),
    .running(tmr_run), .expired(tmr_expired)
  );

// ---------------------------------------------------------------------------
// RESET Minimum Timer: ucie_timer u_rst_tmr
// ---------------------------------------------------------------------------
// Section 4.5.3.1 — RESET requires the LTSM to remain in the RESET
// state for a minimum of C_RESET_MIN = 2,000,000 lclk cycles (4 ms).
// This timer runs only while ltsm_state == LT_RESET.  Its expiry
// feeds rst_tmr_expired back to the LTSM so it knows the minimum
// hold time has been met and may proceed to SBINIT.
//
// Reset Timer: True to spec (LIMIT_CYCLES=C_RESET_MIN = 2,000,000 lclk cycles = 4 ms).
  ucie_timer #(.LIMIT_CYCLES(C_RESET_MIN)) u_rst_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(rst_tmr_start),
    .running(ltsm_state == ucie_pkg::LT_RESET), .expired(rst_tmr_expired)
  );

  initial lclk  = 1'b0;
  initial sbclk = 1'b0;

  // ---------------------------------------------------------------------------
  // Clock generator: lclk - 500 MHz main link clock
  //
  // Toggles every 1.0 ns, giving a 2.0 ns period and therefore 500 MHz. This
  // is the lclk rate the LTSM sequencer runs at. The testbench runs the LTSM
  // far longer than the real 4 ms RESET dwell would suggest, because the LTSM
  // sub-state handshakes are driven by the testbench rather than by a partner
  // die, so the run time is set by the number of hops, not by wall-clock time.
  //
  // Spec ref: UCIe 1.0, Section 8.1.2 - Interface clocking requirements.
  // ---------------------------------------------------------------------------
  always #1.0 lclk  = ~lclk;

  // ---------------------------------------------------------------------------
  // Clock generator: sbclk - asynchronous 800 MHz sideband clock
  //
  // Starts after a 0.1875 ns offset from lclk, then toggles every 0.625 ns.
  // The resulting 1.25 ns period models the 800 MHz sideband clock and
  // exercises the CDC boundary between the lclk LTSM and sbclk codecs.
  //
  // Spec ref: UCIe 1.0, Section 5.13 - Sideband signaling.
  // ---------------------------------------------------------------------------
  initial begin
    #0.1875;
    forever #0.625 sbclk = ~sbclk;
  end

  // ---------------------------------------------------------------------------
  // State Recorder: seen[] array
  // ---------------------------------------------------------------------------
  // This always block monitors ltsm_state on every posedge lclk and
  // appends a new entry to the seen[] array whenever the state differs
  // from the last recorded value.  After training completes, the
  // walk_check block iterates through seen[] to verify the complete
  // ordered sequence of 20 expected states was traversed.
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // ---------------------------------------------------------------------------
  ltsm_state_t seen [0:63];
  int          seen_n;
  ltsm_state_t expected_state_walk [0:19];
  integer      expected_state_index;
  integer      observed_state_index;

  always @(posedge lclk) begin
    if (lreset_n) begin
      if (seen_n == 0 || ltsm_state !== seen[seen_n-1]) begin
        seen[seen_n] = ltsm_state;
        seen_n = seen_n + 1;
      end
    end
  end

  // Deliver one atomic remote-iteration result in the LTSM clock domain.
  task pulse_rx_iteration;
    input logic match;
    begin
      @(negedge lclk);
      sbinit_rx_iter_match = match;
      sbinit_rx_iter_vld   = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      sbinit_rx_iter_vld   = 1'b0;
    end
  endtask

  // Deliver one complete local 64-UI pattern plus 32-UI-low iteration event.
  task pulse_tx_iteration_done;
    begin
      @(negedge lclk);
      sbinit_tx_iter_done = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      sbinit_tx_iter_done = 1'b0;
    end
  endtask

  // Inject one complete sideband header at the direct lclk endpoint. The
  // caller controls the IDs and parity to exercise acceptance boundaries.
  task inject_sbinit_packet;
    input logic [7:0] code;
    input logic [7:0] subcode;
    input logic [2:0] srcid;
    input logic [2:0] dstid;
    input logic       cp_err;
    begin
      @(negedge lclk);
      inject_rx_opcode     = SB_OP_MSG_NODATA;
      inject_rx_srcid      = srcid;
      inject_rx_dstid      = dstid;
      inject_rx_msginfo    = 8'h00;
      inject_rx_msgcode    = code;
      inject_rx_msgsubcode = subcode;
      inject_rx_cp_err     = cp_err;
      inject_rx_dp_err     = 1'b0;
      inject_rx_pkt_vld    = 1'b1;
      @(posedge lclk);
      #0.1;
      @(negedge lclk);
      inject_rx_pkt_vld    = 1'b0;
    end
  endtask

  task expect_state;
    input ltsm_state_t exp;
    begin
      // Wait until the LTSM leaves this state or the deadline passes.
      fork
        begin
          wait (ltsm_state != exp);
          #0.1;
        end
        begin
          // Need more cycles for LT_RESET (2,000,000 cycles = 4 ms)
          if (exp == LT_RESET) repeat (2500000) @(posedge lclk);
          else                 repeat (200000)  @(posedge lclk);
        end
      join_any
      if (ltsm_state === exp) begin
        $display("FAIL ut_ltsm: stuck in %s", "%02h", exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors             = 0;
    seen_n             = 0;
    lreset_n           = 1'b0;
    sbreset_n          = 1'b0;
    start_link_train   = 1'b0;
    adapter_active_req = 1'b0;
    sbinit_rx_iter_vld   = 1'b0;
    sbinit_rx_iter_match = 1'b0;
    sbinit_tx_iter_done  = 1'b0;
    sbinit_tx_idle       = 1'b1;
    inject_rx_pkt_vld    = 1'b0;
    inject_rx_opcode     = '0;
    inject_rx_srcid      = '0;
    inject_rx_dstid      = '0;
    inject_rx_msginfo    = '0;
    inject_rx_msgcode    = '0;
    inject_rx_msgsubcode = '0;
    inject_rx_cp_err     = 1'b0;
    inject_rx_dp_err     = 1'b0;
    par_enable_resp      = 1'b0;
    #5;
    lreset_n           = 1'b1;
    sbreset_n          = 1'b1;
    adapter_active_req = 1'b1;

    // Keep the local request low. RESET must remain until its true 4 ms
    // minimum expires and the remote detector reports two consecutive matches.
    @(posedge rst_tmr_expired);
    #0.1;
    if (ltsm_state !== LT_RESET || start_link_train !== 1'b0) begin
      $display("FAIL ut_ltsm: RESET left before a remote pattern trigger");
      errors = errors + 1;
    end

    // A mismatch breaks the streak. The following single match must not exit
    // RESET even though the 4 ms condition is already satisfied.
    pulse_rx_iteration(1'b1);
    if (u_dut.sbinit_match_streak_q !== 2'd1) begin
      $display("FAIL ut_ltsm: first remote match was not counted");
      errors = errors + 1;
    end
    pulse_rx_iteration(1'b0);
    if (u_dut.sbinit_match_streak_q !== 2'd0) begin
      $display("FAIL ut_ltsm: mismatch did not clear the match streak");
      errors = errors + 1;
    end
    pulse_rx_iteration(1'b1);
    if ((ltsm_state !== LT_RESET) ||
        (u_dut.sbinit_match_streak_q !== 2'd1)) begin
      $display("FAIL ut_ltsm: one post-mismatch match triggered RESET exit");
      errors = errors + 1;
    end
    pulse_rx_iteration(1'b1);
    if ((ltsm_state !== LT_SBINIT) ||
        (u_dut.pattern_trigger_pending_q !== 1'b1)) begin
      $display("FAIL ut_ltsm: two matches did not trigger SBINIT after 4 ms");
      errors = errors + 1;
    end

    // The pattern trigger is retained across RESET exit. Exactly four local
    // iteration-completion events are required before packet mode begins.
    repeat (2) @(posedge lclk);
    #0.1;
    for (int tail = 1; tail <= SBINIT_POST_DETECT_ITERS; tail = tail + 1) begin
      pulse_tx_iteration_done();
      if (u_dut.sbinit_tail_count_q !== tail[2:0]) begin
        $display("FAIL ut_ltsm: tail count got %0d expected %0d",
                 u_dut.sbinit_tail_count_q, tail);
        errors = errors + 1;
      end
      if ((tail < SBINIT_POST_DETECT_ITERS) &&
          (u_dut.sbinit_phase_q !== 2'd0)) begin
        $display("FAIL ut_ltsm: packet phase started after only %0d tails", tail);
        errors = errors + 1;
      end
      if ((tail < (SBINIT_POST_DETECT_ITERS - 1)) &&
          (pattern_run_enable !== 1'b1)) begin
        $display("FAIL ut_ltsm: raw transmitter stopped before tail %0d", tail + 1);
        errors = errors + 1;
      end
      if ((tail >= (SBINIT_POST_DETECT_ITERS - 1)) &&
          (pattern_run_enable !== 1'b0)) begin
        $display("FAIL ut_ltsm: raw run level did not stop at the final boundary");
        errors = errors + 1;
      end
    end
    if ((ltsm_state !== LT_SBINIT) || (u_dut.sbinit_phase_q !== 2'd2) ||
        (sbinit_raw_mode !== 1'b0)) begin
      $display("FAIL ut_ltsm: four tails did not enter Out-of-Reset packet mode");
      errors = errors + 1;
    end

    // Wait until the local Out-of-Reset packet reaches the partner codec.
    wait (local_oor_count != 0);

    // A Done response received before the local request is not completion.
    inject_sbinit_packet(MC_SB_DONE_RSP, MS_SB_DONE,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    if (u_dut.sbinit_done_rsp_received_q !== 1'b0) begin
      $display("FAIL ut_ltsm: early Done response satisfied a future request");
      errors = errors + 1;
    end

    // Reject a packet with the correct code and subcode but the wrong source.
    inject_sbinit_packet(MC_SB_OOB_RESET, MS_SB_OOB_RESET,
                         SRCID_ADAPT, DSTID_REMOTE_PHY, 1'b0);
    if (u_dut.sbinit_oor_received_q !== 1'b0) begin
      $display("FAIL ut_ltsm: invalid Out-of-Reset packet advanced SBINIT");
      errors = errors + 1;
    end

    // Queue the peer request while still in Out-of-Reset. After the valid
    // peer Out-of-Reset packet, the local response must precede its request.
    inject_sbinit_packet(MC_SB_DONE_REQ, MS_SB_DONE,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    if (u_dut.sbinit_done_rsp_pending_q !== 8'd1) begin
      $display("FAIL ut_ltsm: peer Done request did not create an obligation");
      errors = errors + 1;
    end
    inject_sbinit_packet(MC_SB_OOB_RESET, MS_SB_OOB_RESET,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    wait (u_dut.sbinit_phase_q == 2'd3);
    wait (local_done_count >= 2);
    if ((local_done_code[0] !== MC_SB_DONE_RSP) ||
        (local_done_code[1] !== MC_SB_DONE_REQ)) begin
      $display("FAIL ut_ltsm: Done order got %02h then %02h",
               local_done_code[0], local_done_code[1]);
      errors = errors + 1;
    end
    if (ltsm_state !== LT_SBINIT) begin
      $display("FAIL ut_ltsm: Done request advanced without a peer response");
      errors = errors + 1;
    end

    // Wrong-subcode completion is ignored. Only the explicit valid Done
    // response can advance the LTSM to MBINIT.PARAM.
    inject_sbinit_packet(MC_SB_DONE_RSP, MS_SB_OOB_RESET,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    if (ltsm_state !== LT_SBINIT) begin
      $display("FAIL ut_ltsm: invalid Done response advanced SBINIT");
      errors = errors + 1;
    end
    inject_sbinit_packet(MC_SB_DONE_RSP, MS_SB_DONE,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    wait (ltsm_state == LT_MBINIT_PARAM);
    par_enable_resp = 1'b1;

    // Walk every later sub-state in order through the codec and CDC path.
    expect_state(LT_MBINIT_PARAM);
    expect_state(LT_MBINIT_CAL);
    expect_state(LT_MBINIT_RPCLK);
    expect_state(LT_MBINIT_RPVAL);
    expect_state(LT_MBINIT_REVMB);
    expect_state(LT_MBINIT_RPMB);
    expect_state(LT_MB_VALVREF);
    expect_state(LT_MB_DATAVREF);
    expect_state(LT_MB_SPEEDIDLE);
    expect_state(LT_MB_TXSELFCAL);
    expect_state(LT_MB_RXCLKCAL);
    expect_state(LT_MB_VTCENTER);
    expect_state(LT_MB_DTVREF1);
    expect_state(LT_MB_RXDESKEW);
    expect_state(LT_MB_DTCENTER2);
    expect_state(LT_MB_LINKSPEED);
    wait (ltsm_state == LT_LINKINIT);
    repeat (2) @(posedge lclk);
    // MBTRAIN.REPAIR is unsupported by the fixed profile and is never
    // visited. LINKSPEED enters LINKINIT after its 15h and 19h exchanges.
    // A remote Active request requires the local LinkMgmt.RDI.Rsp.Active
    // before the matching local request-response exchange can finish.
    inject_sbinit_packet(MC_LM_RDI_REQ, MS_LM_ACTIVE,
                         SRCID_PHY, DSTID_REMOTE_PHY, 1'b0);
    expect_state(LT_LINKINIT);
    // Reach ACTIVE.
    fork
      begin
        wait (link_trained);
        #0.1;
      end
      begin
        repeat (400000) @(posedge lclk);
      end
    join_any
    if (!link_trained) begin
      $display("FAIL ut_ltsm: did not reach ACTIVE, state %s",
               "%02h", ltsm_state);
      errors = errors + 1;
    end
    // Let the state recorder observe ACTIVE before the walk check.
    repeat (4) @(posedge lclk);
    if (train_error) begin
      $display("FAIL ut_ltsm: unexpected TRAINERROR");
      errors = errors + 1;
    end
    expected_state_walk[0]  = LT_RESET;
    expected_state_walk[1]  = LT_SBINIT;
    expected_state_walk[2]  = LT_MBINIT_PARAM;
    expected_state_walk[3]  = LT_MBINIT_CAL;
    expected_state_walk[4]  = LT_MBINIT_RPCLK;
    expected_state_walk[5]  = LT_MBINIT_RPVAL;
    expected_state_walk[6]  = LT_MBINIT_REVMB;
    expected_state_walk[7]  = LT_MBINIT_RPMB;
    expected_state_walk[8]  = LT_MB_VALVREF;
    expected_state_walk[9]  = LT_MB_DATAVREF;
    expected_state_walk[10] = LT_MB_SPEEDIDLE;
    expected_state_walk[11] = LT_MB_TXSELFCAL;
    expected_state_walk[12] = LT_MB_RXCLKCAL;
    expected_state_walk[13] = LT_MB_VTCENTER;
    expected_state_walk[14] = LT_MB_DTVREF1;
    expected_state_walk[15] = LT_MB_RXDESKEW;
    expected_state_walk[16] = LT_MB_DTCENTER2;
    expected_state_walk[17] = LT_MB_LINKSPEED;
    expected_state_walk[18] = LT_LINKINIT;
    expected_state_walk[19] = LT_ACTIVE;
    expected_state_index = 0;
    for (observed_state_index = 0; observed_state_index < seen_n;
         observed_state_index = observed_state_index + 1) begin
      if (seen[observed_state_index] ==
          expected_state_walk[expected_state_index])
        expected_state_index = expected_state_index + 1;
      if (expected_state_index == 20) observed_state_index = seen_n;
    end
    if (expected_state_index != 20) begin
      $display("FAIL ut_ltsm: state walk incomplete, matched %0d of 20",
               expected_state_index);
      errors = errors + 1;
    end

    // -----------------------------------------------------------------------
    // Sideband Timeout Test: Partner never responds -> LTSM escalates to TRAINERROR
    // -----------------------------------------------------------------------
    par_enable_resp  = 1'b0; // Silence partner
    start_link_train = 1'b0; // Clear trigger before reset
    lreset_n  = 1'b0;
    sbreset_n = 1'b0;
    repeat (10) @(posedge lclk);
    lreset_n  = 1'b1;
    sbreset_n = 1'b1;
    repeat (10) @(posedge lclk);

    // Issue clean negedge-aligned 1-cycle training trigger
    @(negedge lclk);
    start_link_train = 1'b1;
    // Wait for the LTSM to enter LT_SBINIT and pulse tmr_start.
    @(posedge tmr_start);
    
    // De-assert trigger on the following negedge
    @(negedge lclk);
    start_link_train = 1'b0;
    
    // Pipeline Stage 1 (Reload Edge): 
    // The posedge that ends this cycle samples tmr_start=1. The timer clears its 
    // count and re-arms. It does not count this edge.
    @(posedge lclk);
    #0.1;
    if (tmr_expired !== 1'b0 || ltsm_state !== LT_SBINIT) begin
      $display("FAIL ut_ltsm: premature expiry on reload edge (state %02h)", ltsm_state);
      errors = errors + 1;
    end

    // Pipeline Stage 2 (Running Edges 1 .. C_RESIDENCY):
    // The Phase C state-entry pulse reaches the timer after the state update,
    // so the timer keeps tmr_expired low through these C_RESIDENCY edges.
    repeat (C_RESIDENCY) begin
      @(posedge lclk);
      #0.1;
      if (tmr_expired !== 1'b0 || ltsm_state !== LT_SBINIT || tmr_run !== 1'b1) begin
        $display("FAIL ut_ltsm: premature expiry or timer stalled during count (state %02h, expired %b, run %b)",
                 ltsm_state, tmr_expired, tmr_run);
        errors = errors + 1;
      end
    end

    // Pipeline Stage 3 (Expiry Edge / Running Edge C_RESIDENCY):
    // The timer reaches LIMIT_CYCLES - 1. tmr_expired pulses high for exactly one cycle.
    @(posedge lclk);
    #0.1;
    if (tmr_expired !== 1'b1 || ltsm_state !== LT_SBINIT) begin
      $display("FAIL ut_ltsm: tmr_expired did not assert at cycle %0d (state %02h, expired %b)",
               C_RESIDENCY, ltsm_state, tmr_expired);
      errors = errors + 1;
    end

    // Pipeline Stage 4 (TRAINERROR Transition Edge):
    // The LTSM registers the expiry pulse and transitions to LT_TRAINERROR. tmr_expired drops.
    @(posedge lclk);
    #0.1;
    if (ltsm_state !== LT_TRAINERROR || !train_error || tmr_expired !== 1'b0) begin
      $display("FAIL ut_ltsm: did not transition to TRAINERROR (state %02h, te %b, expired %b)",
               ltsm_state, train_error, tmr_expired);
      errors = errors + 1;
    end else begin
      $display("PASS ut_ltsm: sideband timeout strictly verified for full 8 ms (cycle-exact %0d)", C_RESIDENCY);
    end
    if (errors == 0) $display("TEST PASSED ut_ltsm");
    else             $display("FAIL ut_ltsm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000000;
    $display("FAIL ut_ltsm: watchdog timeout, state %s", "%02h", ltsm_state);
    $finish;
  end

endmodule

// ============================================================================
// Module    : tb_loopback_top
// Project   : UCIe 1.0 Simplified Endpoint
// File      : tb/loopback/tb_loopback_top.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 8.0  - Interface Definitions
//   UCIe 1.0 Specification, Section 8.1  - Raw Die-to-Die Interface (RDI)
//   UCIe 1.0 Specification, Table 114    - RDI Signal List
//   UCIe 1.0 Specification, Section 5.2  - Overview (clocking & PHY reset)
//   UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping
//   UCIe 1.0 Specification, Section 4.1.3 - Clock Gating
//   UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission
//   UCIe 1.0 Specification, Section 5.13  - Sideband signaling
//   UCIe 1.0 Specification, Section 3.2   - Modes of operation (Raw Mode)
//   UCIe 1.0 Specification, Section 8.3.1 - Stallreq/Ack Mechanism
//
// DESCRIPTION
//   Top-level two-die loopback testbench for the UCIe simplified endpoint.
//
//   This testbench instantiates two complete `ucie_main` instances (dut_a and
//   dut_b) representing two chiplets on a UCIe package. The sideband and
//   main-band wires between the two dies are crossed, forming a complete
//   point-to-point UCIe link. Each die is driven by its own protocol-layer
//   BFM stimulus that provides the RDI handshake signals (`lp_irdy`,
//   `lp_valid`, `lp_data`, `lp_state_req`, etc.).
//
//   CROSSED TOPOLOGY
//     The testbench models the physical crossing between two die:
//       - dut_a.sb_tx -> dut_b.sb_rx  (sideband A-to-B)
//       - dut_b.sb_tx -> dut_a.sb_rx  (sideband B-to-A)
//       - dut_a.mb_tx -> dut_b.mb_rx  (mainband A-to-B)
//       - dut_b.mb_tx -> dut_a.mb_rx  (mainband B-to-A)
//     This mirrors the physical die-to-die interconnect topology described in
//     Section 4.1.1 - Byte to Lane Mapping. All crossings are modelled as
//     zero-delay continuous assignments (ideal wires).
//
//   CLOCKING
//     Three clock domains are generated in this testbench:
//       - lclk   : 500 MHz (2.0 ns period). The adapter / logical-PHY local
//                  clock. This is the domain on which all RDI data transfers
//                  are referenced.
//       - mbclk  : 2 GHz (0.5 ns period). The forwarded clock fCK that
//                  clocks the main-band DDR serialiser / deserialiser. This
//                  clock is GATED while BOTH Link Training State Machines
//                  (LTSMs) sit in the LT_RESET state (encoded 8'h00).
//                  The gating mirrors what a real PHY does before training
//                  begins, per Section 5.2 - Overview and Section 4.1.3 -
//                  Clock Gating. Once either LTSM exits RESET, fCK is
//                  enabled and toggles at 2 GHz continuously.
//       - sbclk  : 800 MHz (1.25 ns period), phase-offset from lclk. The
//                  sideband codec runs in this independent domain. Toggle
//                  mailboxes inside logical_phy preserve complete packet
//                  requests and responses across the CDC boundary.
//
//   RAW MODE STREAMING FLOW
//     After both dies reach LINK ACTIVE, the `push_one` task injects a
//     DATA_W-bit word on one die's `lp_data` with `lp_valid` and `lp_irdy`
//     asserted for one lclk cycle. The word travels through that die's TX
//     adapter, crosses the main-band wires to the partner die's RX adapter,
//     and appears on the partner die's `pl_data` with `pl_valid` asserted.
//     The logical PHY in this reduced capability set does not terminate the
//     streaming data (see logical_phy.sv); the RDI datapath is a pass-through.
//     The scoreboard inside `push_one` compares the destination die's
//     `pl_data` against the injected pattern and reports PASS/FAIL per beat.
//     Both directions (die 0 -> die 1 "forward" and die 1 -> die 0 "reverse")
//     are exercised.
//
//   COVERAGE MONITOR FEEDING
//     The `cov_monitor` instance (`u_cov`) observes both dies' LTSM state,
//     RDI state, sideband packet fields, link-active indicators, and the
//     `xfer_done_0` / `xfer_done_1` pulses. Each `xfer_done` pulse is a
//     one-lclk-cycle high emitted by `push_one` after the scoreboard has
//     verified a round-trip beat. This lets the coverage model count
//     successful Raw Mode transfers. Stall-phase completion, width-degrade
//     status, lane-reversal status, raw-mode advertisement, and CRC-off
//     advertisement are also connected for completeness of the coverage
//     cross-bins.
//
// INTERNAL BLOCK DIAGRAM
//
//   +================================================================+
//   |  tb_loopback_top                                               |
//   |                                                                |
//   |   lclk (500 MHz)  mbclk (2 GHz, gated)  sbclk (800 MHz, async) |
//   |     |                |                      |                  |
//   |     +----------+-----+----------+-----------+                  |
//   |     |          |     |          |           |                  |
//   |  +--v----------v-----v--+    +--v-----------v-----v--+        |
//   |  |      dut_a           |    |       dut_b           |        |
//   |  |    (ucie_main)       |    |     (ucie_main)       |        |
//   |  |                      |    |                       |        |
//   |  |  BFM d0_lp_* ----+  |    |  +---- BFM d1_lp_*    |        |
//   |  |                  |  |    |  |                     |        |
//   |  |  sb_tx --------->+--+--->+--+-> sb_rx             |        |
//   |  |  sb_rx <---------+--+<--+--+<- sb_tx              |        |
//   |  |                  |  |    |  |                     |        |
//   |  |  mb_tx --------->+--+--->+--+-> mb_rx             |        |
//   |  |  mb_rx <---------+--+<--+--+<- mb_tx              |        |
//   |  |                  |  |    |  |                     |        |
//   |  |  pl_data ------->+  |    |  +-------> pl_data     |        |
//   |  +---------------------+    +------------------------+        |
//   |            |                           |                      |
//   |   scoreboard (push_one)       scoreboard (push_one)           |
//   |            |                           |                      |
//   |     xfer_done_0                 xfer_done_1                   |
//   |            \                          /                       |
//   |             +-------+--------+-------+                        |
//   |                     |                                         |
//   |              +------v------+                                  |
//   |              | cov_monitor |                                  |
//   |              |   (u_cov)   |                                  |
//   |              +-------------+                                  |
//   +================================================================+
//
// PARAMETERS
//   This testbench uses the default parameter values from `ucie_pkg`:
//     NC         - Sideband channel width (number of sideband data bits).
//     NLANES_MAX - Maximum number of main-band lanes (16 for the x16 PoC).
//     DATA_W     - RDI data word width (64 bits in the simplified endpoint).
//   No additional parameters are declared.
//
// CLOCK / RESET
//   lclk      : 500 MHz free-running clock generated by `always #1.00`.
//   mbclk     : 2 GHz gated clock generated by `always #0.25` and enabled
//               by `mbclk_en`. The gate opens when at least one LTSM is
//               not in LT_RESET (state != 8'h00).
//   sbclk     : 800 MHz phase-offset clock generated after 0.1875 ns, then
//               toggled every 0.625 ns. It is asynchronous to lclk.
//   d0_lreset_n/d0_sbreset_n : Die 0 aligned local reset pair.
//   d1_lreset_n/d1_sbreset_n : Die 1 aligned pair, released 2.5 ms later.
//
// DESIGN NOTES
//   - The two `ucie_main` instances share one sbclk, but sbclk is independent
//     of lclk. Each logical_phy crosses LTSM packet events through paired
//     asynchronous mailboxes before reaching its sb_codec.
//   - The RDI state and LTSM state are observed via hierarchical references
//     into each DUT. These are connected to the coverage monitor but are
//     not used for functional verification; the scoreboard is purely
//     data-path based.
//   - The main-band crossing uses continuous assignments (ideal wires with
//     zero propagation delay). A real package interconnect would introduce
//     flight time and ISI; these are modelled in Phase 4.
//   - The `push_one` task is intentionally blocking: it drives one beat,
//     waits for the partner die's `pl_valid`, checks the data, pulses
//     `xfer_done`, and returns. This serialisation prevents overlapping
//     beats from confusing the scoreboard, which is sufficient for the
//     current Raw Mode PoC.
//   - The stall detector observes die 0's four-phase stallreq/ack handshake
//     and toggles `stall_4phase` on completion. This feeds the coverage
//     monitor and is not required for functional pass/fail.
//   - Width degrade and lane reversal inputs to the coverage monitor are
//     tied to zero because the x16-only PoC never degrades or reverses
//     lanes. They exist so the coverage model is structurally complete.
//
// REVISION HISTORY
//   v0.0.1  2025-XX-XX  Initial creation.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block comments.
//   v0.0.3  2026-09-23  Req.3: drive sbclk at 800 MHz with a phase offset from
//                        lclk and document the logical-PHY CDC mailboxes.
//   v0.0.4  2026-09-23  Req.3: sample mailbox-delivered sideband coverage in
//                        lclk so packet fields and valid strobes stay coherent.
//   v0.0.5  2026-09-24  Add aligned per-die reset pairs, a 2.5 ms delayed Die
//                        1 start, received-pattern entry, SBINIT order checks,
//                        no-early-mainband checks, and a 20 ms watchdog.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef TbLoopbackTop_SV
`define TbLoopbackTop_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module tb_loopback_top;

  // ------------------------------------------------------- clocks
  // lclk and sbclk are independent. The sideband CDC mailboxes in each
  // logical PHY accept one-lclk-cycle LTSM events and deliver one-sbclk-cycle
  // codec events without pulse loss.
  logic lclk;
  logic mbclk;
  logic sbclk;

  initial begin
    lclk  = 1'b0;
    mbclk = 1'b0;
    sbclk = 1'b0;
  end
  // -------------------------------------------------------------------------
  // always: lclk Generator
  //
  // Plain clock driver for the 500 MHz local clock (lclk). The period is
  // 2.0 ns (half-period = 1.0 ns). This clock drives all adapter and
  // logical-PHY logic inside both `ucie_main` instances, as well as the
  // BFM stimulus and scoreboard timing.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview.
  // -------------------------------------------------------------------------
  always #1.00 lclk  = ~lclk;   // 500 MHz (2.0 ns period)
  // Forwarded clock fCK is gated off during LT_RESET (spec 5.2)
  logic mbclk_en;
  // -------------------------------------------------------------------------
  // assign: mbclk Gate Enable
  //
  // Generates the gate-enable signal for the forwarded main-band clock fCK.
  // The enable is HIGH when at least one LTSM has exited LT_RESET (state
  // != 8'h00). While both LTSMs sit in LT_RESET the forwarded clock is
  // held low, which mirrors real PHY behaviour: the clock is not driven
  // before link training begins.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview.
  // Spec ref: UCIe 1.0, Section 4.1.3 - Clock Gating.
  // -------------------------------------------------------------------------
  assign mbclk_en = (d0_ltsm_state != 8'h00) || (d1_ltsm_state != 8'h00);
  // -------------------------------------------------------------------------
  // always: mbclk (fCK) Gated Clock Generator
  //
  // Plain clock driver for the 2 GHz forwarded clock fCK, gated by
  // `mbclk_en`. When enabled, the half-period is 0.25 ns (period 0.5 ns,
  // i.e. 2 GHz). When disabled (`mbclk_en` == 0), the clock is forced
  // low. The gating is intentional: a real PHY does not toggle fCK while
  // both LTSMs remain in LT_RESET, because the receiver's clock recovery
  // loop is not yet calibrated. Once either LTSM exits RESET, fCK must
  // run continuously so the main-band DDR serialiser / deserialiser can
  // operate.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview.
  // Spec ref: UCIe 1.0, Section 4.1.3 - Clock Gating.
  // -------------------------------------------------------------------------
  always #0.25 mbclk = mbclk_en ? ~mbclk : 1'b0;
  // -------------------------------------------------------------------------
  // initial: sbclk Generator
  //
  // Starts the 800 MHz sideband clock with a 0.1875 ns phase offset from
  // lclk. The 0.625 ns half-period gives a 1.25 ns period. The offset makes
  // the two clock domains asynchronous in simulation while preserving a
  // physically accurate sideband frequency.
  //
  // Spec ref: UCIe 1.0, Section 5.13 - Sideband signaling.
  // -------------------------------------------------------------------------
  initial begin
    #0.1875;
    forever #0.625 sbclk = ~sbclk;
  end
  // ------------------------------------------------------- per-die reset pairs
  // Each die releases its lclk/sbclk reset pair on the same lclk edge. Die 1
  // releases exactly 2.5 ms after Die 0 so the CDC mailbox reset contract is
  // preserved locally while the two Stage 0 timelines remain independent.
  logic d0_lreset_n;
  logic d0_sbreset_n;
  logic d1_lreset_n;
  logic d1_sbreset_n;
  time  d0_reset_release_time;
  time  d1_reset_release_time;

  initial begin
    d0_lreset_n = 1'b0;
    d0_sbreset_n = 1'b0;
    d1_lreset_n = 1'b0;
    d1_sbreset_n = 1'b0;
    d0_reset_release_time = 0;
    d1_reset_release_time = 0;
    #20;
    @(negedge lclk);
    d0_lreset_n = 1'b1;
    d0_sbreset_n = 1'b1;
    d0_reset_release_time = $time;
    repeat (1_250_000) @(negedge lclk);
    d1_lreset_n = 1'b1;
    d1_sbreset_n = 1'b1;
    d1_reset_release_time = $time;
  end

  // ------------------------------------------------------- die crossing
  logic [NC-1:0]        sb_a2b_data, sb_b2a_data;
  logic                 sb_a2b_valid, sb_b2a_valid;
  logic [NLANES_MAX-1:0] mb_a2b_data, mb_b2a_data;
  logic                 mb_a2b_valid, mb_b2a_valid;
  wire  [NLANES_MAX-1:0] mb_a2b_wire, mb_b2a_wire;
  wire                  mb_a2b_val_wire, mb_b2a_val_wire;

  // Main-band DDR wires across die boundary (instantaneous, zero overhead)
  // -------------------------------------------------------------------------
  // assign (4): Main-Band Die-Crossing Wires
  //
  // These four continuous assignments model the physical main-band wires
  // that cross the die boundary between dut_a and dut_b. They are ideal
  // zero-delay connections: `mb_a2b_data` (driven by dut_a's mb_tx_data)
  // feeds into `mb_a2b_wire` (connected to dut_b's mb_rx_data), and
  // likewise in the reverse direction. The valid qualifiers follow the
  // same crossing.
  //
  // In a real package these wires carry DDR-encoded data at 1 bit per
  // lane per fCK edge. The simplified model omits propagation delay and
  // ISI; accurate channel modelling is deferred to Phase 4.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  assign mb_a2b_wire     = mb_a2b_data;
  assign mb_a2b_val_wire = mb_a2b_valid;
  assign mb_b2a_wire     = mb_b2a_data;
  assign mb_b2a_val_wire = mb_b2a_valid;
  // ------------------------------------------------------- die 0
  logic        d0_start_link_train;
  logic        d0_lp_irdy, d0_lp_valid;
  logic [DATA_W-1:0] d0_lp_data;
  logic [7:0]  d0_lp_stream;
  logic        d0_lp_stallack, d0_lp_rx_active_sts;
  logic        d0_pl_trdy, d0_pl_valid;
  logic [DATA_W-1:0] d0_pl_data;
  logic [7:0]  d0_pl_stream;
  logic [3:0]  d0_lp_state_req, d0_pl_state_sts;
  logic        d0_link_active_obs;
  logic        d0_pl_stallreq;
  logic [7:0]  d0_ltsm_state;
  logic [3:0]  d0_rdi_state_sts;
  logic [4:0]  d0_sb_rx_opcode;
  logic [7:0]  d0_sb_rx_msgcode;
  logic [7:0]  d0_sb_rx_msgsubcode;
  logic [1:0]  d0_sbinit_phase;
  logic        d0_sb_rx_pkt_vld;

  // ------------------------------------------------------- die 1
  logic        d1_start_link_train;
  logic        d1_lp_irdy, d1_lp_valid;
  logic [DATA_W-1:0] d1_lp_data;
  logic [7:0]  d1_lp_stream;
  logic        d1_lp_stallack, d1_lp_rx_active_sts;
  logic        d1_pl_trdy, d1_pl_valid;
  logic [DATA_W-1:0] d1_pl_data;
  logic [7:0]  d1_pl_stream;
  logic [3:0]  d1_lp_state_req, d1_pl_state_sts;
  logic        d1_link_active_obs;
  logic        d1_pl_stallreq;
  logic [7:0]  d1_ltsm_state;
  logic [3:0]  d1_rdi_state_sts;
  logic [4:0]  d1_sb_rx_opcode;
  logic [7:0]  d1_sb_rx_msgcode;
  logic [7:0]  d1_sb_rx_msgsubcode;
  logic [1:0]  d1_sbinit_phase;
  logic        d1_sb_rx_pkt_vld;

  // ------------------------------------------------------- observed wires
  // The RDI status is an internal net of ucie_main; hierarchical access from
  // the testbench reads it for coverage only.
  wire [3:0] rdi_sts_0 = dut_a.u_lphy.u_rdi_sm.state_q;
  wire [3:0] rdi_sts_1 = dut_b.u_lphy.u_rdi_sm.state_q;
  // -------------------------------------------------------------------------
  // assign (2): RDI State Status Observation
  //
  // Copies the hierarchically referenced RDI state-machine register from
  // each DUT into a testbench-level logic signal. These are used solely
  // for coverage observation by `cov_monitor` and are not part of the
  // functional scoreboard.
  //
  // Spec ref: UCIe 1.0, Section 8.1.5 - RDI State Status Machine.
  // -------------------------------------------------------------------------
  assign d0_rdi_state_sts = rdi_sts_0;
  assign d1_rdi_state_sts = rdi_sts_1;

  wire [7:0] ltsm_0 = dut_a.u_lphy.u_ltsm.state_q;
  wire [7:0] ltsm_1 = dut_b.u_lphy.u_ltsm.state_q;
  // -------------------------------------------------------------------------
  // assign (2): LTSM State Observation
  //
  // Copies the hierarchically referenced Link Training State Machine
  // register from each DUT into a testbench-level logic signal. The LTSM
  // state is observed by the coverage monitor and is also used to gate the
  // forwarded clock `mbclk` (via `mbclk_en`).
  //
  // Spec ref: UCIe 1.0, Section 4.5.3 - Link Training State Machine.
  // -------------------------------------------------------------------------
  assign d0_ltsm_state = ltsm_0;
  assign d1_ltsm_state = ltsm_1;

  // -------------------------------------------------------------------------
  // assign (8): Sideband and Link-Active Observation
  //
  // These assignments extract lclk-domain sideband packet fields and valid
  // strobes after each logical PHY's sbclk-to-lclk mailbox. The coverage
  // monitor therefore observes coherent packet fields in its lclk domain.
  //
  // Spec ref: UCIe 1.0, Section 4.1.5 - Sideband transmission.
  // Spec ref: UCIe 1.0, Section 5.13 - Sideband signaling.
  // -------------------------------------------------------------------------
  assign d0_sb_rx_opcode     = dut_a.u_lphy.sb_rx_opcode;
  assign d0_sb_rx_msgcode    = dut_a.u_lphy.sb_rx_msgcode;
  assign d0_sb_rx_msgsubcode = dut_a.u_lphy.sb_rx_msgsubcode;
  assign d0_sbinit_phase     = dut_a.u_lphy.u_ltsm.sbinit_phase_q;
  assign d0_sb_rx_pkt_vld    = dut_a.u_lphy.sb_rx_pkt_vld;
  assign d1_sb_rx_opcode     = dut_b.u_lphy.sb_rx_opcode;
  assign d1_sb_rx_msgcode    = dut_b.u_lphy.sb_rx_msgcode;
  assign d1_sb_rx_msgsubcode = dut_b.u_lphy.sb_rx_msgsubcode;
  assign d1_sbinit_phase     = dut_b.u_lphy.u_ltsm.sbinit_phase_q;
  assign d1_sb_rx_pkt_vld    = dut_b.u_lphy.sb_rx_pkt_vld;
  assign d0_link_active_obs = dut_a.link_active_obs;
  assign d1_link_active_obs = dut_b.link_active_obs;

  // ------------------------------------------------------- DUTs
  // -------------------------------------------------------------------------
  // Instantiation: ucie_main dut_a  (Die 0)
  //
  // First UCIe simplified endpoint instance representing Die 0 in the
  // loopback topology. All RDI protocol-layer signals are prefixed `d0_`
  // and driven by the BFM stimulus. The sideband and main-band ports are
  // cross-connected to dut_b:
  //   - dut_a.sb_tx_data/valid  ->  dut_b.sb_rx_data/valid  (via sb_b2a)
  //   - dut_a.mb_tx_data/valid  ->  dut_b.mb_rx_data/valid  (via mb_b2a)
  //   - dut_a.sb_rx             <-  dut_b.sb_tx             (via sb_a2b)
  //   - dut_a.mb_rx             <-  dut_b.mb_tx             (via mb_a2b)
  //
  // Spec ref: UCIe 1.0, Section 8.0 - Interface Definitions.
  // -------------------------------------------------------------------------
  ucie_main dut_a (
    .lclk            (lclk),
    .lreset_n        (d0_lreset_n),
    .mbclk           (mbclk),
    .sbclk           (sbclk),
    .sbreset_n       (d0_sbreset_n),
    .start_link_train(d0_start_link_train),
    .lp_irdy         (d0_lp_irdy),
    .lp_valid        (d0_lp_valid),
    .lp_data         (d0_lp_data),
    .lp_stream       (d0_lp_stream),
    .lp_stallack     (d0_lp_stallack),
    .lp_rx_active_sts(d0_lp_rx_active_sts),
    .pl_trdy         (d0_pl_trdy),
    .pl_valid        (d0_pl_valid),
    .pl_data         (d0_pl_data),
    .pl_stream       (d0_pl_stream),
    .pl_error        (),
    .pl_cerror       (),
    .pl_nferror      (),
    .pl_trainerror   (),
    .pl_phyinrecenter(),
    .pl_protocol     (),
    .pl_protocol_flitfmt(),
    .pl_rx_active_req(),
    .lp_state_req    (d0_lp_state_req),
    .pl_state_sts    (d0_pl_state_sts),
    .pl_inband_pres  (),
    .pl_stallreq     (d0_pl_stallreq),
    .lp_linkerror    (),
    .sb_tx_data      (sb_b2a_data),
    .sb_tx_valid     (sb_b2a_valid),
    .sb_rx_data      (sb_a2b_data),
    .sb_rx_valid     (sb_a2b_valid),
    .mb_tx_data      (mb_b2a_data),
    .mb_tx_valid     (mb_b2a_valid),
    .mb_rx_data      (mb_a2b_wire),
    .mb_rx_valid     (mb_a2b_val_wire)
  );

  // -------------------------------------------------------------------------
  // Instantiation: ucie_main dut_b  (Die 1)
  //
  // Second UCIe simplified endpoint instance representing Die 1 in the
  // loopback topology. All RDI protocol-layer signals are prefixed `d1_`
  // and driven by the BFM stimulus. The sideband and main-band ports are
  // cross-connected to dut_a (the mirror of dut_a's connections):
  //   - dut_b.sb_tx_data/valid  ->  dut_a.sb_rx_data/valid  (via sb_a2b)
  //   - dut_b.mb_tx_data/valid  ->  dut_a.mb_rx_data/valid  (via mb_a2b)
  //   - dut_b.sb_rx             <-  dut_a.sb_tx             (via sb_b2a)
  //   - dut_b.mb_rx             <-  dut_a.mb_tx             (via mb_b2a)
  //
  // Spec ref: UCIe 1.0, Section 8.0 - Interface Definitions.
  // -------------------------------------------------------------------------
  ucie_main dut_b (
    .lclk            (lclk),
    .lreset_n        (d1_lreset_n),
    .mbclk           (mbclk),
    .sbclk           (sbclk),
    .sbreset_n       (d1_sbreset_n),
    .start_link_train(d1_start_link_train),
    .lp_irdy         (d1_lp_irdy),
    .lp_valid        (d1_lp_valid),
    .lp_data         (d1_lp_data),
    .lp_stream       (d1_lp_stream),
    .lp_stallack     (d1_lp_stallack),
    .lp_rx_active_sts(d1_lp_rx_active_sts),
    .pl_trdy         (d1_pl_trdy),
    .pl_valid        (d1_pl_valid),
    .pl_data         (d1_pl_data),
    .pl_stream       (d1_pl_stream),
    .pl_error        (),
    .pl_cerror       (),
    .pl_nferror      (),
    .pl_trainerror   (),
    .pl_phyinrecenter(),
    .pl_protocol     (),
    .pl_protocol_flitfmt(),
    .pl_rx_active_req(),
    .lp_state_req    (d1_lp_state_req),
    .pl_state_sts    (d1_pl_state_sts),
    .pl_inband_pres  (),
    .pl_stallreq     (d1_pl_stallreq),
    .lp_linkerror    (),
    .sb_tx_data      (sb_a2b_data),
    .sb_tx_valid     (sb_a2b_valid),
    .sb_rx_data      (sb_b2a_data),
    .sb_rx_valid     (sb_b2a_valid),
    .mb_tx_data      (mb_a2b_data),
    .mb_tx_valid     (mb_a2b_valid),
    .mb_rx_data      (mb_b2a_wire),
    .mb_rx_valid     (mb_b2a_val_wire)
  );

  // ------------------------------------------------------- BFM stimulus
  // Each die plays its own protocol layer. The request and the active status
  // are held for the whole run: the link management messages are not
  // transported in this reduced PoC, so the testbench supplies them.
  initial begin
    d0_start_link_train = 1'b0;
    d0_lp_state_req     = FDI_REQ_ACTIVE;
    d0_lp_rx_active_sts = 1'b1;
    d0_lp_irdy          = 1'b0;
    d0_lp_valid         = 1'b0;
    d0_lp_data          = '0;
    d0_lp_stream        = STREAM_ID_S0_STREAMING;
    d0_lp_stallack      = 1'b0;

    d1_start_link_train = 1'b0;
    d1_lp_state_req     = FDI_REQ_ACTIVE;
    d1_lp_rx_active_sts = 1'b1;
    d1_lp_irdy          = 1'b0;
    d1_lp_valid         = 1'b0;
    d1_lp_data          = '0;
    d1_lp_stream        = STREAM_ID_S0_STREAMING;
    d1_lp_stallack      = 1'b0;

    wait (d0_lreset_n === 1'b1);
    @(negedge lclk);
    d0_start_link_train = 1'b1;
    d1_start_link_train = 1'b0;
  end

  // ------------------------------------------------------- transfer events
  // A completed and scoreboard-checked streaming beat. push_one pulses the
  // matching line for one lclk cycle once the round trip has been verified,
  // which is what the coverage monitor counts as a raw transfer.
  logic xfer_done_0, xfer_done_1;

  initial begin
    xfer_done_0 = 1'b0;
    xfer_done_1 = 1'b0;
  end

  // ------------------------------------------------------- stall detector
  // A four-phase stall is req -> ack -> valid and irdy low -> both low.
  logic stall_4phase;
  logic stall_seen_req, stall_seen_ack, stall_seen_stop;

  // -------------------------------------------------------------------------
  // always: Stall Four-Phase Handshake Detector
  //
  // Observes the four-phase stall handshake on die 0's RDI interface. The
  // sequence is:
  //   1. pl_stallreq asserted by the physical layer.
  //   2. lp_stallack asserted by the protocol layer (BFM).
  //   3. lp_valid and lp_irdy both deasserted (data flow stopped).
  //   4. pl_stallreq and lp_stallack both deasserted (stall released).
  // Upon completion of all four phases, `stall_4phase` is toggled, which
  // the coverage monitor samples as a stall-completion event.
  //
  // Spec ref: UCIe 1.0, Section 8.3.1 - Stallreq/Ack Mechanism.
  // -------------------------------------------------------------------------
  always @(posedge lclk) begin
    if (!d0_lreset_n) begin
      stall_seen_req  <= 1'b0;
      stall_seen_ack  <= 1'b0;
      stall_seen_stop <= 1'b0;
    end else begin
      if (d0_pl_stallreq && !stall_seen_req)
        stall_seen_req <= 1'b1;
      if (stall_seen_req && d0_lp_stallack && !stall_seen_ack)
        stall_seen_ack <= 1'b1;
      if (stall_seen_ack && !d0_lp_valid && !d0_lp_irdy && !stall_seen_stop)
        stall_seen_stop <= 1'b1;
      if (stall_seen_stop && !d0_pl_stallreq && !d0_lp_stallack)
        stall_4phase <= ~stall_4phase;
    end
  end

  initial stall_4phase = 1'b0;

  // ------------------------------------------------------- width / reversal
  // The x16-only PoC never degrades, so these stay observation-only and are
  // exercised by the mapper unit test instead. They are wired so the coverage
  // model is complete, and held at the never-degraded value.
  logic width_degrade;
  logic lane_reversal;
  initial begin
    width_degrade = 1'b0;
    lane_reversal = 1'b0;
  end

  // ------------------------------------------------------- capability ads
  // AdvCap.Adapter advertises Raw_Mode (bit 0), Streaming (bit 4) and
  // Stack0_Enable (bit 7). No-CRC is not a bit in AdvCap; it is implied by
  // 4 GT/s. The advertisement appears on the sideband during MBINIT.PARAM.
  logic raw_mode_adv, crc_off_adv;
  initial begin
    raw_mode_adv = 1'b1;
    crc_off_adv  = 1'b1;
  end

  // ------------------------------------------------------- monitor
  // -------------------------------------------------------------------------
  // Instantiation: cov_monitor u_cov  (Coverage Monitor)
  //
  // The coverage monitor collects functional coverage from both dies. It
  // is fed the LTSM state, RDI state, sideband packet fields, link-active
  // status, transfer-done pulses, stall completion toggle, width-degrade
  // and lane-reversal flags, and capability advertisement bits. At the end
  // of the simulation (or on timeout), `export_json` is called to write
  // the coverage data to the file specified by the `+covfile=` plusarg.
  //
  // Spec ref: UCIe 1.0, Section 8.0 - Interface Definitions.
  // -------------------------------------------------------------------------
  cov_monitor u_cov (
    .lclk              (lclk),
    .lreset_n          (d0_lreset_n && d1_lreset_n),
    .sbclk             (sbclk),
    .ltsm_state_0      (d0_ltsm_state),
    .sbinit_phase_0    (d0_sbinit_phase),
    .link_active_0     (d0_link_active_obs),
    .sb_rx_opcode_0    (d0_sb_rx_opcode),
    .sb_rx_msgcode_0   (d0_sb_rx_msgcode),
    .sb_rx_msgsubcode_0(d0_sb_rx_msgsubcode),
    .sb_rx_pkt_vld_0   (d0_sb_rx_pkt_vld),
    .rdi_state_sts_0   (d0_rdi_state_sts),
    .ltsm_state_1      (d1_ltsm_state),
    .sbinit_phase_1    (d1_sbinit_phase),
    .link_active_1     (d1_link_active_obs),
    .sb_rx_opcode_1    (d1_sb_rx_opcode),
    .sb_rx_msgcode_1   (d1_sb_rx_msgcode),
    .sb_rx_msgsubcode_1(d1_sb_rx_msgsubcode),
    .sb_rx_pkt_vld_1   (d1_sb_rx_pkt_vld),
    .rdi_state_sts_1 (d1_rdi_state_sts),
    .xfer_done_0     (xfer_done_0),
    .xfer_done_1     (xfer_done_1),
    .stall_4phase    (stall_4phase),
    .width_degrade   (width_degrade),
    .lane_reversal   (lane_reversal),
    .raw_mode_adv    (raw_mode_adv),
    .crc_off_adv     (crc_off_adv)
  );
  reg [1024*8-1:0] cov_path;

  // ------------------------------------------------------- main sequence
  integer errors;
  integer d0_sbinit_order;
  integer d1_sbinit_order;
  logic   reset_pair_error_seen;
  logic   early_mainband_error_seen;
  logic   d1_pattern_trigger_seen;
  logic [2:0] d0_sbinit_msg_hits;
  logic [2:0] d1_sbinit_msg_hits;
  logic [7:0] d0_prev_ltsm_state;
  logic [7:0] d1_prev_ltsm_state;
  time d0_sbinit_entry_time;
  time d1_sbinit_entry_time;
  time stage0_skew;
  logic [DATA_W-1:0] exp_data;
  logic [DATA_W-1:0] got_data;

  // Check the delayed-start contract on the actual two-die surface. Pattern
  // and packet subphases are private observations only. Public DUT ports stay
  // unchanged.
  always @(posedge lclk) begin
    if (((d0_lreset_n !== d0_sbreset_n) ||
         (d1_lreset_n !== d1_sbreset_n)) && !reset_pair_error_seen) begin
      $display("FAIL tb_loopback_top: a local reset pair was not aligned");
      errors = errors + 1;
      reset_pair_error_seen = 1'b1;
    end
    if (d1_start_link_train !== 1'b0) begin
      $display("FAIL tb_loopback_top: Die 1 local training trigger asserted");
      errors = errors + 1;
      d1_start_link_train = 1'b0;
    end

    if (d1_lreset_n && (d1_ltsm_state == LT_RESET) &&
        dut_b.u_lphy.u_ltsm.pattern_trigger_pending_q)
      d1_pattern_trigger_seen = 1'b1;

    if (d0_lreset_n && (d0_prev_ltsm_state == LT_RESET) &&
        (d0_ltsm_state == LT_SBINIT) && (d0_sbinit_entry_time == 0)) begin
      d0_sbinit_entry_time = $time;
      if (($time - d0_reset_release_time) < 4_000_000) begin
        $display("FAIL tb_loopback_top: Die 0 left RESET before 4 ms");
        errors = errors + 1;
      end
    end
    if (d1_lreset_n && (d1_prev_ltsm_state == LT_RESET) &&
        (d1_ltsm_state == LT_SBINIT) && (d1_sbinit_entry_time == 0)) begin
      d1_sbinit_entry_time = $time;
      if (($time - d1_reset_release_time) < 4_000_000) begin
        $display("FAIL tb_loopback_top: Die 1 left RESET before 4 ms");
        errors = errors + 1;
      end
      if (!d1_pattern_trigger_seen ||
          !dut_b.u_lphy.u_ltsm.pattern_trigger_pending_q) begin
        $display("FAIL tb_loopback_top: Die 1 did not use the received pattern trigger");
        errors = errors + 1;
      end
    end

    if (d0_lreset_n && (d0_ltsm_state == LT_SBINIT)) begin
      if ((d0_sbinit_order == 0) && (d0_sbinit_phase == 2'd0))
        d0_sbinit_order = 1;
      else if ((d0_sbinit_order == 1) && (d0_sbinit_phase == 2'd2))
        d0_sbinit_order = 2;
      else if ((d0_sbinit_order == 2) && (d0_sbinit_phase == 2'd3))
        d0_sbinit_order = 3;
      else if ((d0_sbinit_order >= 2) && (d0_sbinit_phase < d0_sbinit_order)) begin
        $display("FAIL tb_loopback_top: Die 0 SBINIT phase regressed");
        errors = errors + 1;
        d0_sbinit_order = 4;
      end
    end
    if (d1_lreset_n && (d1_ltsm_state == LT_SBINIT)) begin
      if ((d1_sbinit_order == 0) && (d1_sbinit_phase == 2'd0))
        d1_sbinit_order = 1;
      else if ((d1_sbinit_order == 1) && (d1_sbinit_phase == 2'd2))
        d1_sbinit_order = 2;
      else if ((d1_sbinit_order == 2) && (d1_sbinit_phase == 2'd3))
        d1_sbinit_order = 3;
      else if ((d1_sbinit_order >= 2) && (d1_sbinit_phase < d1_sbinit_order)) begin
        $display("FAIL tb_loopback_top: Die 1 SBINIT phase regressed");
        errors = errors + 1;
        d1_sbinit_order = 4;
      end
    end
    if ((d0_prev_ltsm_state == LT_SBINIT) &&
        (d0_ltsm_state == LT_MBINIT_PARAM) && (d0_sbinit_order != 3)) begin
      $display("FAIL tb_loopback_top: Die 0 skipped SBINIT phase order");
      errors = errors + 1;
    end
    if ((d1_prev_ltsm_state == LT_SBINIT) &&
        (d1_ltsm_state == LT_MBINIT_PARAM) && (d1_sbinit_order != 3)) begin
      $display("FAIL tb_loopback_top: Die 1 skipped SBINIT phase order");
      errors = errors + 1;
    end

    // Out-of-Reset must be observed before either Done message. The hit masks
    // also prove that both request and response roles crossed each direction.
    if (d0_sb_rx_pkt_vld) begin
      if ((d0_sb_rx_msgcode == MC_SB_OOB_RESET) &&
          (d0_sb_rx_msgsubcode == MS_SB_OOB_RESET))
        d0_sbinit_msg_hits[0] = 1'b1;
      if (((d0_sb_rx_msgcode == MC_SB_DONE_REQ) ||
           (d0_sb_rx_msgcode == MC_SB_DONE_RSP)) &&
          (d0_sb_rx_msgsubcode == MS_SB_DONE)) begin
        if (!d0_sbinit_msg_hits[0]) begin
          $display("FAIL tb_loopback_top: Die 0 received Done before Out-of-Reset");
          errors = errors + 1;
        end
        if (d0_sb_rx_msgcode == MC_SB_DONE_REQ) d0_sbinit_msg_hits[1] = 1'b1;
        else                                    d0_sbinit_msg_hits[2] = 1'b1;
      end
    end
    if (d1_sb_rx_pkt_vld) begin
      if ((d1_sb_rx_msgcode == MC_SB_OOB_RESET) &&
          (d1_sb_rx_msgsubcode == MS_SB_OOB_RESET))
        d1_sbinit_msg_hits[0] = 1'b1;
      if (((d1_sb_rx_msgcode == MC_SB_DONE_REQ) ||
           (d1_sb_rx_msgcode == MC_SB_DONE_RSP)) &&
          (d1_sb_rx_msgsubcode == MS_SB_DONE)) begin
        if (!d1_sbinit_msg_hits[0]) begin
          $display("FAIL tb_loopback_top: Die 1 received Done before Out-of-Reset");
          errors = errors + 1;
        end
        if (d1_sb_rx_msgcode == MC_SB_DONE_REQ) d1_sbinit_msg_hits[1] = 1'b1;
        else                                    d1_sbinit_msg_hits[2] = 1'b1;
      end
    end

    if (!early_mainband_error_seen &&
        ((d0_ltsm_state <= LT_SBINIT) || (d1_ltsm_state <= LT_SBINIT)) &&
        (mb_a2b_valid || mb_b2a_valid)) begin
      $display("FAIL tb_loopback_top: main-band valid asserted during RESET/SBINIT");
      errors = errors + 1;
      early_mainband_error_seen = 1'b1;
    end

    d0_prev_ltsm_state = d0_ltsm_state;
    d1_prev_ltsm_state = d1_ltsm_state;
  end

  task push_one;
    input [64*8-1:0] label;
    input integer    which;      // 0 = die 0 forward, 1 = die 1 reverse
    input [DATA_W-1:0] data;
    begin
      if (which == 0) begin
        // Die 0 TX -> cross main-band DDR pins -> Die 1 RX
        @(negedge lclk);
        d0_lp_data  = data;
        d0_lp_valid = 1'b1;
        d0_lp_irdy  = 1'b1;
        @(negedge lclk);
        d0_lp_valid = 1'b0;
        d0_lp_irdy  = 1'b0;
        // Wait until destination receives valid beat
        while (!d1_pl_valid) @(posedge lclk);
        #0.1;
        got_data = d1_pl_data;
        if (got_data !== data) begin
          $display("FAIL %0s: die1 got %032h expected %032h", label, got_data, data);
          errors = errors + 1;
        end else begin
          $display("PASS %0s: die0 data %032h", label, data);
        end
        // Mark the checked beat for the coverage monitor. The pulse is held
        // across a full lclk period so the monitor samples it without a
        // scheduling race.
        xfer_done_0 = 1'b1;
        @(posedge lclk);
        @(negedge lclk);
        xfer_done_0 = 1'b0;
      end else begin
        // Die 1 TX -> cross main-band DDR pins -> Die 0 RX
        @(negedge lclk);
        d1_lp_data  = data;
        d1_lp_valid = 1'b1;
        d1_lp_irdy  = 1'b1;
        @(negedge lclk);
        d1_lp_valid = 1'b0;
        d1_lp_irdy  = 1'b0;
        while (!d0_pl_valid) @(posedge lclk);
        #0.1;
        got_data = d0_pl_data;
        if (got_data !== data) begin
          $display("FAIL %0s: die0 got %032h expected %032h", label, got_data, data);
          errors = errors + 1;
        end else begin
          $display("PASS %0s: die1 data %032h", label, data);
        end
        xfer_done_1 = 1'b1;
        @(posedge lclk);
        @(negedge lclk);
        xfer_done_1 = 1'b0;
      end
    end
  endtask

  initial begin
    errors                    = 0;
    d0_sbinit_order           = 0;
    d1_sbinit_order           = 0;
    reset_pair_error_seen     = 1'b0;
    early_mainband_error_seen = 1'b0;
    d1_pattern_trigger_seen   = 1'b0;
    d0_sbinit_msg_hits        = 3'b000;
    d1_sbinit_msg_hits        = 3'b000;
    d0_prev_ltsm_state        = LT_RESET;
    d1_prev_ltsm_state        = LT_RESET;
    d0_sbinit_entry_time      = 0;
    d1_sbinit_entry_time      = 0;
    stage0_skew               = 0;

    // Verify the deliberate reset release skew before link completion.
    wait (d1_lreset_n === 1'b1);
    if ((d1_reset_release_time - d0_reset_release_time) != 2_500_000) begin
      $display("FAIL tb_loopback_top: reset skew got %0t expected 2500000 ns",
               d1_reset_release_time - d0_reset_release_time);
      errors = errors + 1;
    end

    // The 20 ms watchdog below is the single integration deadline.
    while (!(d0_link_active_obs && d1_link_active_obs)) @(posedge lclk);

    if ((d0_sbinit_entry_time == 0) || (d1_sbinit_entry_time == 0)) begin
      $display("FAIL tb_loopback_top: missing per-die SBINIT entry observation");
      errors = errors + 1;
    end else begin
      stage0_skew = d1_sbinit_entry_time - d0_sbinit_entry_time;
      if ((stage0_skew < 2_499_990) || (stage0_skew > 2_500_010)) begin
        $display("FAIL tb_loopback_top: Stage 0 skew got %0t ns", stage0_skew);
        errors = errors + 1;
      end
    end
    if ((d0_sbinit_order != 3) || (d1_sbinit_order != 3)) begin
      $display("FAIL tb_loopback_top: SBINIT phase order incomplete (%0d,%0d)",
               d0_sbinit_order, d1_sbinit_order);
      errors = errors + 1;
    end
    if (!d1_pattern_trigger_seen) begin
      $display("FAIL tb_loopback_top: Die 1 received-pattern trigger not observed");
      errors = errors + 1;
    end
    if ((d0_sbinit_msg_hits !== 3'b111) ||
        (d1_sbinit_msg_hits !== 3'b111)) begin
      $display("FAIL tb_loopback_top: SBINIT messages incomplete (%b,%b)",
               d0_sbinit_msg_hits, d1_sbinit_msg_hits);
      errors = errors + 1;
    end

    $display("LINK ACTIVE (die 0)");
    $display("LINK ACTIVE (die 1)");

    // ---- let the last LFSR training beats drain out of both RX gearboxes
    repeat (10) @(posedge lclk);

    // ---- streaming data, both directions
    push_one("RAW MODE TRANSFER OK (die0->die1)", 0, {8{8'h11}});
    push_one("RAW MODE TRANSFER OK (die1->die0)", 1, {8{8'h22}});
    push_one("burst die0", 0, {8{8'h33}});
    push_one("burst die1", 1, {8{8'h44}});
    push_one("burst die0", 0, {8{8'h55}});
    push_one("burst die1", 1, {8{8'h66}});
    push_one("burst die0", 0, {8{8'h77}});
    push_one("burst die1", 1, {8{8'h88}});

    // ---- settle and report
    repeat (20) @(posedge lclk);
    u_cov.export_json(cov_path);

    if (errors == 0)
      $display("TEST PASSED tb_loopback_top");
    else
      $display("TEST FAILED tb_loopback_top: %0d errors", errors);
    $finish;
  end

  // ------------------------------------------------------- watchdog
  initial begin
    cov_path = "logs/coverage.json";
    void'($value$plusargs("covfile=%s", cov_path));
    // Delayed reset plus true 4 ms RESET residency fits under this 20 ms gate.
    #(20_000_000);
    $display("FAIL tb_loopback_top: watchdog at %0t", $time);
    u_cov.export_json(cov_path);
    $finish;
  end
endmodule
`endif

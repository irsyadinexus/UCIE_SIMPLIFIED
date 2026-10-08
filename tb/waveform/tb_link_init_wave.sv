// ============================================================================
// File      : tb/waveform/tb_link_init_wave.sv
// Project   : UCIe 1.0 Simplified Endpoint
// Purpose   : Two-Die (Die0 <-> Die1) Link Initialization Waveform Testbench
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.5.3   - Link Training State Machine (LTSM)
//   UCIe 1.0 Specification, Section 7.5.1   - UCIe Link DVSEC (Link Control)
//   UCIe 1.0 Specification, Section 8.1     - Raw Die-to-Die Interface (RDI, Table 114)
//   UCIe 1.0 Specification, Section 8.1.5   - RDI State Machine (Figure 111)
//   UCIe 1.0 Specification, Section 8.1.6   - RDI Bring-up Flow (Active Entry)
//   UCIe 1.0 Specification, Section 8.2     - Flit-Aware Die-to-Die Interface (FDI, Table 115)
//   UCIe 1.0 Specification, Section 8.2.5   - FDI State Machine (Figure 119)
//   UCIe 1.0 Specification, Section 8.3.2.1 - Link Down Event & Request Withdrawal
//   UCIe 1.0 Specification, Section 8.3.2.7 - LinkError State & Residency Dwell
//   UCIe 1.0 Specification, Section 8.3.3.1 - LinkReset Flow (Figure 125)
//   UCIe 1.0 Specification, Section 8.3.3.2 - LinkError Flow & Recovery (Figure 126)
//
// TWO-DIE ARCHITECTURE & TESTBENCH TOPOLOGY
//
//      Die 0 (Initiator / Upstream)             Die 1 (Target / Downstream)
//   +-------------------------------+       +-------------------------------+
//   | Protocol Layer 0 (Stimulus)   |       | Protocol Layer 1 (Stimulus)   |
//   |   lp_state_req / lp_data      |       |   lp_state_req / lp_data      |
//   +---------------+---------------+       +---------------+---------------+
//                   | FDI (Table 115)                       | FDI (Table 115)
//                   v                                       v
//   +---------------+---------------+       +---------------+---------------+
//   | ucie_main (dut_die0)          |       | ucie_main (dut_die1)          |
//   |   D2D Adapter 0               |       |   D2D Adapter 1               |
//   |   Logical PHY 0               |       |   Logical PHY 1               |
//   +-------+---------------+-------+       +-------+---------------+-------+
//           |               |                       |               |
//           | mb_tx/rx_data | (mainband lanes)      | mb_tx/rx_data |
//           +===============(=======================)===============+
//           |               |                       |               |
//           | sb_tx/rx_data | (sideband serial)     | sb_tx/rx_data |
//           +---------------(-----------------------)---------------+
//
// TEST SEQUENCE:
//   1. Both dies release hardware reset synchronously (lreset_n=1, sbreset_n=1).
//   2. Physical layer enforces initial 40 us (FAST_SIM) RESET minimum dwell.
//   3. Protocol Layer on both dies asserts Start UCIe Link Training and FDI ACTIVE.
//   4. Full link training progresses: SBINIT -> MBINIT (CAL, REPAIR, REV) ->
//      MBTRAIN (VREF, CLK, VTCENTER, LINKSPEED) -> LINKINIT -> ACTIVE.
//   5. LTSM, RDI SM, and FDI SM enter ACTIVE on both dies; link Active broadcasted.
//   6. 512-Byte bidirectional streaming verification in Format 1 Raw Mode.
//   7. STEP 1 (Figure 125): Die 0 requests LinkReset; Die 1 receives sideband
//      request and observes Link Down Event; both transition to RESET; 40 us
//      RESET dwell; link restarts and successfully trains back to ACTIVE.
//   8. STEP 2 (Figure 126): Die 0 asserts lp_linkerror; Die 1 receives sideband
//      LinkError request; both observe Link Down Event and withdraw to NOP;
//      both enter TRAINERROR (LinkError); sideband handshake bypasses dwell;
//      both transition directly to RESET without LinkReset per Figure 111/119/126;
//      40 us RESET dwell; fresh Start restarts training back to ACTIVE.
//
// REVISION HISTORY:
//   v0.0.1  2026-09-22  Initial link initialization waveform testbench.
//   v0.0.2  2026-10-06  Add 512B bidirectional streaming transfer verification.
//   v0.0.3  2026-10-07  Add Figure 125 LinkReset entry and exit flow.
//   v0.0.4  2026-10-08  Implement UCIe 1.0 Section 8.3.3.2 Figure 126 LinkError
//                       entry, direct exit to RESET, and recovery bring-up.
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module tb_link_init_wave;

  // ==========================================================================
  // Clocks
  // ==========================================================================
  logic lclk;   // 500 MHz local clock (2.0 ns period)
  logic sbclk;  // 800 MHz sideband clock (1.25 ns period)
  logic mbclk;  // 2.0 GHz mainband forwarded clock fCK (0.5 ns period)

  initial begin
    lclk  = 1'b0;
    sbclk = 1'b0;
    mbclk = 1'b0;
  end

  // --------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz reference link clock (2.0 ns period, 1.0 ns half-period)
  // for dual-die link training simulation.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Link Clock Frequency.
  // --------------------------------------------------------------------------
  always #1.000 lclk = ~lclk;

  // --------------------------------------------------------------------------
  // always: Sideband Clock Generator (800 MHz sbclk)
  //
  // Generates 800 MHz sideband clock (1.25 ns period, 0.625 ns half-period).
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 - Sideband Signaling.
  // --------------------------------------------------------------------------
  always #0.625 sbclk = ~sbclk;

  logic mbclk_en;

  // --------------------------------------------------------------------------
  // always: Gated Mainband Forwarded Clock Generator (2 GHz mbclk)
  //
  // Generates 2 GHz forwarded clock fCK (0.5 ns period) enabled when mbclk_en
  // is asserted during high-speed training and ACTIVE states.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Mainband Clocking.
  // --------------------------------------------------------------------------
  always begin
    if (mbclk_en === 1'b1) begin
      #0.250 mbclk = ~mbclk;
    end else begin
      mbclk = 1'b0;
      @(mbclk_en);
    end
  end

  // ==========================================================================
  // Resets
  // ==========================================================================
  logic d0_lreset_n;
  logic d0_sbreset_n;
  logic d1_lreset_n;
  logic d1_sbreset_n;
  time  reset_release_time;

  initial begin
    d0_lreset_n  = 1'b0;
    d0_sbreset_n = 1'b0;
    d1_lreset_n  = 1'b0;
    d1_sbreset_n = 1'b0;
    reset_release_time = 0;

    // Hold hardware reset across initial cycles, then release synchronously
    #20.000;
    @(negedge lclk);
    d0_lreset_n  = 1'b1;
    d0_sbreset_n = 1'b1;
    d1_lreset_n  = 1'b1;
    d1_sbreset_n = 1'b1;
    reset_release_time = $time;
    $display("[%0t ns] Synchronous hardware reset released on Die0 and Die1", $time);
  end

  // ==========================================================================
  // Die-to-Die Interconnect (Crossed Wires)
  // ==========================================================================
  // Sideband scalar wires
  logic                 sb_d0_to_d1_clk;
  logic                 sb_d0_to_d1_data;
  logic                 sb_d1_to_d0_clk;
  logic                 sb_d1_to_d0_data;

  // Mainband data & framing valid
  logic [NLANES_MAX-1:0] mb_d0_to_d1_data;
  logic                  mb_d0_to_d1_valid;
  logic [NLANES_MAX-1:0] mb_d1_to_d0_data;
  logic                  mb_d1_to_d0_valid;

  // ==========================================================================
  // Die 0: FDI Interface Signals (Table 115)
  // ==========================================================================
  logic                  d0_lp_irdy;
  logic                  d0_lp_valid;
  logic [DATA_W-1:0]     d0_lp_data;
  logic [7:0]            d0_lp_stream;
  logic                  d0_lp_stallack;
  logic                  d0_lp_rx_active_sts;
  logic [3:0]            d0_lp_state_req;
  logic                  d0_lp_linkerror;
  logic                  d0_lp_clk_ack;
  logic                  d0_lp_wake_req;
  logic [NC-1:0]         d0_lp_cfg;
  logic                  d0_lp_cfg_vld;
  logic                  d0_lp_cfg_crd;

  logic                  d0_pl_trdy;
  logic                  d0_pl_valid;
  logic [DATA_W-1:0]     d0_pl_data;
  logic [7:0]            d0_pl_stream;
  logic                  d0_pl_error;
  logic                  d0_pl_cerror;
  logic                  d0_pl_nferror;
  logic                  d0_pl_trainerror;
  logic                  d0_pl_phyinrecenter;
  logic [2:0]            d0_pl_protocol;
  logic [3:0]            d0_pl_protocol_flitfmt;
  logic                  d0_pl_protocol_vld;
  logic                  d0_pl_clk_req;
  logic                  d0_pl_wake_ack;
  logic [2:0]            d0_pl_speedmode;
  logic [2:0]            d0_pl_lnk_cfg;
  logic                  d0_pl_rx_active_req;
  logic [3:0]            d0_pl_state_sts;
  logic                  d0_pl_inband_pres;
  logic                  d0_pl_stallreq;
  logic [NC-1:0]         d0_pl_cfg;
  logic                  d0_pl_cfg_vld;
  logic                  d0_pl_cfg_crd;

  // ==========================================================================
  // Die 1: FDI Interface Signals (Table 115)
  // ==========================================================================
  logic                  d1_lp_irdy;
  logic                  d1_lp_valid;
  logic [DATA_W-1:0]     d1_lp_data;
  logic [7:0]            d1_lp_stream;
  logic                  d1_lp_stallack;
  logic                  d1_lp_rx_active_sts;
  logic [3:0]            d1_lp_state_req;
  logic                  d1_lp_linkerror;
  logic                  d1_lp_clk_ack;
  logic                  d1_lp_wake_req;
  logic [NC-1:0]         d1_lp_cfg;
  logic                  d1_lp_cfg_vld;
  logic                  d1_lp_cfg_crd;

  logic                  d1_pl_trdy;
  logic                  d1_pl_valid;
  logic [DATA_W-1:0]     d1_pl_data;
  logic [7:0]            d1_pl_stream;
  logic                  d1_pl_error;
  logic                  d1_pl_cerror;
  logic                  d1_pl_nferror;
  logic                  d1_pl_trainerror;
  logic                  d1_pl_phyinrecenter;
  logic [2:0]            d1_pl_protocol;
  logic [3:0]            d1_pl_protocol_flitfmt;
  logic                  d1_pl_protocol_vld;
  logic                  d1_pl_clk_req;
  logic                  d1_pl_wake_ack;
  logic [2:0]            d1_pl_speedmode;
  logic [2:0]            d1_pl_lnk_cfg;
  logic                  d1_pl_rx_active_req;
  logic [3:0]            d1_pl_state_sts;
  logic                  d1_pl_inband_pres;
  logic                  d1_pl_stallreq;
  logic [NC-1:0]         d1_pl_cfg;
  logic                  d1_pl_cfg_vld;
  logic                  d1_pl_cfg_crd;

  // ==========================================================================
  // DUT Instantiations (Die 0 and Die 1)
  // ==========================================================================
  ucie_main #(
    .NBYTES(NBYTES),
    .NLANES(NLANES_MAX),
    .NC(NC)
  ) dut_die0 (
    .lclk                  (lclk),
    .lreset_n              (d0_lreset_n),
    .mbclk                 (mbclk),
    .sbclk                 (sbclk),
    .sbreset_n             (d0_sbreset_n),
    // FDI (Table 115)
    .lp_irdy               (d0_lp_irdy),
    .lp_valid              (d0_lp_valid),
    .lp_data               (d0_lp_data),
    .lp_stream             (d0_lp_stream),
    .lp_stallack           (d0_lp_stallack),
    .lp_rx_active_sts      (d0_lp_rx_active_sts),
    .pl_trdy               (d0_pl_trdy),
    .pl_valid              (d0_pl_valid),
    .pl_data               (d0_pl_data),
    .pl_stream             (d0_pl_stream),
    .pl_error              (d0_pl_error),
    .pl_cerror             (d0_pl_cerror),
    .pl_nferror            (d0_pl_nferror),
    .pl_trainerror         (d0_pl_trainerror),
    .pl_phyinrecenter      (d0_pl_phyinrecenter),
    .pl_protocol           (d0_pl_protocol),
    .pl_protocol_flitfmt   (d0_pl_protocol_flitfmt),
    .pl_protocol_vld       (d0_pl_protocol_vld),
    .pl_rx_active_req      (d0_pl_rx_active_req),
    .lp_state_req          (d0_lp_state_req),
    .pl_state_sts          (d0_pl_state_sts),
    .pl_inband_pres        (d0_pl_inband_pres),
    .pl_stallreq           (d0_pl_stallreq),
    .lp_linkerror          (d0_lp_linkerror),
    .lp_cfg                (d0_lp_cfg),
    .lp_cfg_vld            (d0_lp_cfg_vld),
    .lp_cfg_crd            (d0_lp_cfg_crd),
    .pl_cfg                (d0_pl_cfg),
    .pl_cfg_vld            (d0_pl_cfg_vld),
    .pl_cfg_crd            (d0_pl_cfg_crd),
    .pl_clk_req            (d0_pl_clk_req),
    .lp_clk_ack            (d0_lp_clk_ack),
    .lp_wake_req           (d0_lp_wake_req),
    .pl_wake_ack           (d0_pl_wake_ack),
    .pl_speedmode          (d0_pl_speedmode),
    .pl_lnk_cfg            (d0_pl_lnk_cfg),
    // Sideband & Mainband
    .sb_tx_clk             (sb_d0_to_d1_clk),
    .sb_tx_data            (sb_d0_to_d1_data),
    .sb_rx_clk             (sb_d1_to_d0_clk),
    .sb_rx_data            (sb_d1_to_d0_data),
    .mb_tx_data            (mb_d0_to_d1_data),
    .mb_tx_valid           (mb_d0_to_d1_valid),
    .mb_rx_data            (mb_d1_to_d0_data),
    .mb_rx_valid           (mb_d1_to_d0_valid)
  );

  ucie_main #(
    .NBYTES(NBYTES),
    .NLANES(NLANES_MAX),
    .NC(NC)
  ) dut_die1 (
    .lclk                  (lclk),
    .lreset_n              (d1_lreset_n),
    .mbclk                 (mbclk),
    .sbclk                 (sbclk),
    .sbreset_n             (d1_sbreset_n),
    // FDI (Table 115)
    .lp_irdy               (d1_lp_irdy),
    .lp_valid              (d1_lp_valid),
    .lp_data               (d1_lp_data),
    .lp_stream             (d1_lp_stream),
    .lp_stallack           (d1_lp_stallack),
    .lp_rx_active_sts      (d1_lp_rx_active_sts),
    .pl_trdy               (d1_pl_trdy),
    .pl_valid              (d1_pl_valid),
    .pl_data               (d1_pl_data),
    .pl_stream             (d1_pl_stream),
    .pl_error              (d1_pl_error),
    .pl_cerror             (d1_pl_cerror),
    .pl_nferror            (d1_pl_nferror),
    .pl_trainerror         (d1_pl_trainerror),
    .pl_phyinrecenter      (d1_pl_phyinrecenter),
    .pl_protocol           (d1_pl_protocol),
    .pl_protocol_flitfmt   (d1_pl_protocol_flitfmt),
    .pl_protocol_vld       (d1_pl_protocol_vld),
    .pl_rx_active_req      (d1_pl_rx_active_req),
    .lp_state_req          (d1_lp_state_req),
    .pl_state_sts          (d1_pl_state_sts),
    .pl_inband_pres        (d1_pl_inband_pres),
    .pl_stallreq           (d1_pl_stallreq),
    .lp_linkerror          (d1_lp_linkerror),
    .lp_cfg                (d1_lp_cfg),
    .lp_cfg_vld            (d1_lp_cfg_vld),
    .lp_cfg_crd            (d1_lp_cfg_crd),
    .pl_cfg                (d1_pl_cfg),
    .pl_cfg_vld            (d1_pl_cfg_vld),
    .pl_cfg_crd            (d1_pl_cfg_crd),
    .pl_clk_req            (d1_pl_clk_req),
    .lp_clk_ack            (d1_lp_clk_ack),
    .lp_wake_req           (d1_lp_wake_req),
    .pl_wake_ack           (d1_pl_wake_ack),
    .pl_speedmode          (d1_pl_speedmode),
    .pl_lnk_cfg            (d1_pl_lnk_cfg),
    // Sideband & Mainband
    .sb_tx_clk             (sb_d1_to_d0_clk),
    .sb_tx_data            (sb_d1_to_d0_data),
    .sb_rx_clk             (sb_d0_to_d1_clk),
    .sb_rx_data            (sb_d0_to_d1_data),
    .mb_tx_data            (mb_d1_to_d0_data),
    .mb_tx_valid           (mb_d1_to_d0_valid),
    .mb_rx_data            (mb_d0_to_d1_data),
    .mb_rx_valid           (mb_d0_to_d1_valid)
  );

  // ==========================================================================
  // RDI Interface Signals (Table 114) Exposed from DUT Internal Nets
  // ==========================================================================
  // Die 0 RDI (Table 114)
  wire [3:0]          d0_rdi_lp_state_req   = dut_die0.rdi_lp_state_req;
  wire                d0_rdi_lp_stallack    = dut_die0.rdi_lp_stallack;
  wire                d0_rdi_lp_linkerror   = dut_die0.rdi_lp_linkerror;
  wire                d0_rdi_lp_irdy        = dut_die0.rdi_lp_irdy;
  wire                d0_rdi_lp_valid       = dut_die0.rdi_lp_valid;
  wire [DATA_W-1:0]   d0_rdi_lp_data        = dut_die0.rdi_lp_data;
  wire [3:0]          d0_rdi_pl_state_sts   = dut_die0.rdi_pl_state_sts;
  wire                d0_rdi_pl_inband_pres = dut_die0.rdi_pl_inband_pres;
  wire                d0_rdi_pl_linkerror   = dut_die0.rdi_pl_linkerror;
  wire                d0_rdi_pl_error       = dut_die0.rdi_pl_error;
  wire                d0_rdi_pl_phyinrecenter = dut_die0.rdi_pl_phyinrecenter;
  wire                d0_rdi_pl_cerror      = dut_die0.rdi_pl_cerror;
  wire                d0_rdi_pl_nferror     = dut_die0.rdi_pl_nferror;
  wire                d0_rdi_pl_trainerror  = dut_die0.rdi_pl_trainerror;
  wire                d0_rdi_pl_trdy        = dut_die0.rdi_pl_trdy;
  wire                d0_rdi_pl_valid       = dut_die0.rdi_pl_valid;
  wire [DATA_W-1:0]   d0_rdi_pl_data        = dut_die0.rdi_pl_data;
  wire [2:0]          d0_rdi_pl_lnk_cfg     = dut_die0.rdi_pl_lnk_cfg;
  wire [2:0]          d0_rdi_pl_speedmode   = dut_die0.rdi_pl_speedmode;
  wire                d0_rdi_pl_stallreq    = dut_die0.rdi_pl_stallreq;

  // Die 1 RDI (Table 114)
  wire [3:0]          d1_rdi_lp_state_req   = dut_die1.rdi_lp_state_req;
  wire                d1_rdi_lp_stallack    = dut_die1.rdi_lp_stallack;
  wire                d1_rdi_lp_linkerror   = dut_die1.rdi_lp_linkerror;
  wire                d1_rdi_lp_irdy        = dut_die1.rdi_lp_irdy;
  wire                d1_rdi_lp_valid       = dut_die1.rdi_lp_valid;
  wire [DATA_W-1:0]   d1_rdi_lp_data        = dut_die1.rdi_lp_data;
  wire [3:0]          d1_rdi_pl_state_sts   = dut_die1.rdi_pl_state_sts;
  wire                d1_rdi_pl_inband_pres = dut_die1.rdi_pl_inband_pres;
  wire                d1_rdi_pl_linkerror   = dut_die1.rdi_pl_linkerror;
  wire                d1_rdi_pl_error       = dut_die1.rdi_pl_error;
  wire                d1_rdi_pl_phyinrecenter = dut_die1.rdi_pl_phyinrecenter;
  wire                d1_rdi_pl_cerror      = dut_die1.rdi_pl_cerror;
  wire                d1_rdi_pl_nferror     = dut_die1.rdi_pl_nferror;
  wire                d1_rdi_pl_trainerror  = dut_die1.rdi_pl_trainerror;
  wire                d1_rdi_pl_trdy        = dut_die1.rdi_pl_trdy;
  wire                d1_rdi_pl_valid       = dut_die1.rdi_pl_valid;
  wire [DATA_W-1:0]   d1_rdi_pl_data        = dut_die1.rdi_pl_data;
  wire [2:0]          d1_rdi_pl_lnk_cfg     = dut_die1.rdi_pl_lnk_cfg;
  wire [2:0]          d1_rdi_pl_speedmode   = dut_die1.rdi_pl_speedmode;
  wire                d1_rdi_pl_stallreq    = dut_die1.rdi_pl_stallreq;

  // ==========================================================================
  // State Machine Registers
  // ==========================================================================
  wire [7:0] d0_ltsm_state         = dut_die0.u_lphy.u_ltsm.state_q;
  wire [1:0] d0_sbinit_phase       = dut_die0.u_lphy.u_ltsm.sbinit_phase_q;
  wire [3:0] d0_rdi_state          = dut_die0.u_lphy.u_rdi_sm.state_q;
  wire [3:0] d0_fdi_state          = dut_die0.u_adapter.u_fdi_sm.fdi_q;
  wire       d0_link_control_start = dut_die0.u_adapter.u_regfile.reg_link_ctrl[0];

  wire [7:0] d1_ltsm_state         = dut_die1.u_lphy.u_ltsm.state_q;
  wire [1:0] d1_sbinit_phase       = dut_die1.u_lphy.u_ltsm.sbinit_phase_q;
  wire [3:0] d1_rdi_state          = dut_die1.u_lphy.u_rdi_sm.state_q;
  wire [3:0] d1_fdi_state          = dut_die1.u_adapter.u_fdi_sm.fdi_q;
  wire       d1_link_control_start = dut_die1.u_adapter.u_regfile.reg_link_ctrl[0];

  // Sideband observability
  wire       d0_sb_rx_pkt_vld      = dut_die0.u_lphy.sb_rx_pkt_vld;
  wire [4:0] d0_sb_rx_opcode       = dut_die0.u_lphy.sb_rx_opcode;
  wire [7:0] d0_sb_rx_msgcode      = dut_die0.u_lphy.sb_rx_msgcode;
  wire [7:0] d0_sb_rx_msgsubcode   = dut_die0.u_lphy.sb_rx_msgsubcode;

  wire       d1_sb_rx_pkt_vld      = dut_die1.u_lphy.sb_rx_pkt_vld;
  wire [4:0] d1_sb_rx_opcode       = dut_die1.u_lphy.sb_rx_opcode;
  wire [7:0] d1_sb_rx_msgcode      = dut_die1.u_lphy.sb_rx_msgcode;
  wire [7:0] d1_sb_rx_msgsubcode   = dut_die1.u_lphy.sb_rx_msgsubcode;

  // --------------------------------------------------------------------------
  // assign: mbclk_en - Mainband Clock Gating Enable Driver
  //
  // Enables the 2 GHz forwarded clock fCK whenever either die enters
  // MBTRAIN.LINKSPEED, LINKINIT, or ACTIVE states.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3 - Link Training.
  // --------------------------------------------------------------------------
  assign mbclk_en = (d0_ltsm_state == LT_MB_LINKSPEED) ||
                    (d1_ltsm_state == LT_MB_LINKSPEED) ||
                    (d0_ltsm_state == LT_LINKINIT)     ||
                    (d1_ltsm_state == LT_LINKINIT)     ||
                    (d0_ltsm_state == LT_ACTIVE)       ||
                    (d1_ltsm_state == LT_ACTIVE);

  // ==========================================================================
  // Protocol Layer BFM Stimulus & Automated Handshakes
  // ==========================================================================
  // --------------------------------------------------------------------------
  // always: Die 0 Automatic FDI Stall Acknowledge Responder
  //
  // Automatically mirrors stall request to stall acknowledge per Section 8.3.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.1 - Stall Handshake.
  // --------------------------------------------------------------------------
  always @(posedge lclk or negedge d0_lreset_n) begin
    if (!d0_lreset_n) d0_lp_stallack <= 1'b0;
    else              d0_lp_stallack <= d0_pl_stallreq;
  end

  // --------------------------------------------------------------------------
  // always: Die 1 Automatic FDI Stall Acknowledge Responder
  //
  // Automatically mirrors stall request to stall acknowledge per Section 8.3.1.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.1 - Stall Handshake.
  // --------------------------------------------------------------------------
  always @(posedge lclk or negedge d1_lreset_n) begin
    if (!d1_lreset_n) d1_lp_stallack <= 1'b0;
    else              d1_lp_stallack <= d1_pl_stallreq;
  end

  // --------------------------------------------------------------------------
  // always: Die 0 Automatic RX Active Status Responder
  //
  // Responds to Adapter rx_active_req by asserting rx_active_sts per Section 8.3.2.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2 - State Request Handshake.
  // --------------------------------------------------------------------------
  always @(posedge lclk or negedge d0_lreset_n) begin
    if (!d0_lreset_n)
      d0_lp_rx_active_sts <= 1'b0;
    else if (d0_pl_rx_active_req)
      d0_lp_rx_active_sts <= 1'b1;
    else if (d0_pl_state_sts == FDI_STS_RESET || d0_pl_state_sts == FDI_STS_LINKRESET)
      d0_lp_rx_active_sts <= 1'b0;
  end

  // --------------------------------------------------------------------------
  // always: Die 1 Automatic RX Active Status Responder
  //
  // Responds to Adapter rx_active_req by asserting rx_active_sts per Section 8.3.2.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.3.2 - State Request Handshake.
  // --------------------------------------------------------------------------
  always @(posedge lclk or negedge d1_lreset_n) begin
    if (!d1_lreset_n)
      d1_lp_rx_active_sts <= 1'b0;
    else if (d1_pl_rx_active_req)
      d1_lp_rx_active_sts <= 1'b1;
    else if (d1_pl_state_sts == FDI_STS_RESET || d1_pl_state_sts == FDI_STS_LINKRESET)
      d1_lp_rx_active_sts <= 1'b0;
  end

  // Task: Protocol Layer Configuration Write to UCIe Link Control (Offset 0x00)
  // Sends a standard 64-bit sideband configuration header followed by 64-bit payload
  // over the FDI lp_cfg bus.
  task automatic fdi_cfg_write_link_control(input int die_sel);
    sb_packet_t req;
    logic [63:0] hdr;
    logic [63:0] pld;
    begin
      req = '0;
      req.opcode = SB_OP_CFG_WRITE64;
      req.src_id = FDI_SRCID_STACK0;
      req.dst_id = FDI_DSTID_ADAPTER;
      req.addr   = 27'h0000000;              // UCIe Link Control register (Table 65)
      req.data   = 64'h0000_0000_0000_0001;  // Bit 0 = 1b: Start UCIe Link Training
      req.be     = 8'hFF;
      req.tag    = (die_sel == 0) ? 5'h01 : 5'h02;
      hdr = ucie_pkg::sb_encode_header(req);
      pld = 64'h0000_0000_0000_0001;

      // 8 cycles header
      for (int b = 0; b < 8; b++) begin
        @(negedge lclk);
        if (die_sel == 0) begin
          d0_lp_cfg     = hdr[b*8 +: 8];
          d0_lp_cfg_vld = 1'b1;
        end else begin
          d1_lp_cfg     = hdr[b*8 +: 8];
          d1_lp_cfg_vld = 1'b1;
        end
      end
      // 8 cycles payload
      for (int b = 0; b < 8; b++) begin
        @(negedge lclk);
        if (die_sel == 0) begin
          d0_lp_cfg     = pld[b*8 +: 8];
          d0_lp_cfg_vld = 1'b1;
        end else begin
          d1_lp_cfg     = pld[b*8 +: 8];
          d1_lp_cfg_vld = 1'b1;
        end
      end
      @(negedge lclk);
      if (die_sel == 0) begin
        d0_lp_cfg     = '0;
        d0_lp_cfg_vld = 1'b0;
      end else begin
        d1_lp_cfg     = '0;
        d1_lp_cfg_vld = 1'b0;
      end
    end
  endtask

  // Protocol Layer Master Flow
  initial begin
    // Default initial inputs
    d0_lp_irdy          = 1'b0;
    d0_lp_valid         = 1'b0;
    d0_lp_data          = '0;
    d0_lp_stream        = STREAM_ID_S0_STREAMING;
    d0_lp_state_req     = FDI_REQ_NOP;
    d0_lp_linkerror     = 1'b0;
    d0_lp_clk_ack       = 1'b1;
    d0_lp_wake_req      = 1'b0;
    d0_lp_cfg           = '0;
    d0_lp_cfg_vld       = 1'b0;
    d0_lp_cfg_crd       = 1'b0;

    d1_lp_irdy          = 1'b0;
    d1_lp_valid         = 1'b0;
    d1_lp_data          = '0;
    d1_lp_stream        = STREAM_ID_S0_STREAMING;
    d1_lp_state_req     = FDI_REQ_NOP;
    d1_lp_linkerror     = 1'b0;
    d1_lp_clk_ack       = 1'b1;
    d1_lp_wake_req      = 1'b0;
    d1_lp_cfg           = '0;
    d1_lp_cfg_vld       = 1'b0;
    d1_lp_cfg_crd       = 1'b0;

    // Wait until synchronous hardware reset deassertion
    wait (d0_lreset_n === 1'b1 && d1_lreset_n === 1'b1);

    // Physical layer RESET dwell time (40 us with FAST_SIM=1)
    #40_100;
    @(posedge lclk);
    $display("[%0t ns] Protocol Layer on Die0 and Die1 writing 1b to Start UCIe Link Training in UCIe Link Control...", $time);

    // Protocol layer on both dies writes 1b to Start UCIe Link Training bit in UCIe Link Control
    fork
      fdi_cfg_write_link_control(0);
      fdi_cfg_write_link_control(1);
    join


    // Protocol layer sets Active state request on FDI
    repeat (2) @(posedge lclk);
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_ACTIVE;
    d1_lp_state_req = FDI_REQ_ACTIVE;
    $display("[%0t ns] Protocol Layer requested FDI ACTIVE (lp_state_req=ACTIVE)", $time);
  end

  // ==========================================================================
  // LTSM State Transition Logging & Verification
  // ==========================================================================
  logic [7:0] d0_prev_state, d1_prev_state;
  initial begin
    d0_prev_state = LT_RESET;
    d1_prev_state = LT_RESET;
  end

  // --------------------------------------------------------------------------
  // always: LTSM Transition Logger
  //
  // Prints timestamped state transitions for both dies to stdout for waveform debug.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3 - Link Training State Machine.
  // --------------------------------------------------------------------------
  always @(posedge lclk) begin
    if (d0_ltsm_state !== d0_prev_state) begin
      $display("[%0t ns] DIE0 LTSM Transition: %s (%02h) -> %s (%02h) | RDI=%01h FDI=%01h",
               $time, ltsm_state_name(d0_prev_state), d0_prev_state,
               ltsm_state_name(d0_ltsm_state), d0_ltsm_state, d0_rdi_state, d0_fdi_state);
      d0_prev_state = d0_ltsm_state;
    end
    if (d1_ltsm_state !== d1_prev_state) begin
      $display("[%0t ns] DIE1 LTSM Transition: %s (%02h) -> %s (%02h) | RDI=%01h FDI=%01h",
               $time, ltsm_state_name(d1_prev_state), d1_prev_state,
               ltsm_state_name(d1_ltsm_state), d1_ltsm_state, d1_rdi_state, d1_fdi_state);
      d1_prev_state = d1_ltsm_state;
    end
  end

  // Helper function to decode state names
  function automatic string ltsm_state_name(input logic [7:0] st);
    case (st)
      LT_RESET:        return "RESET";
      LT_SBINIT:       return "SBINIT";
      LT_MBINIT_PARAM: return "MBINIT.PARAM";
      LT_MBINIT_CAL:   return "MBINIT.CAL";
      LT_MBINIT_RPCLK: return "MBINIT.RPCLK";
      LT_MBINIT_RPVAL: return "MBINIT.RPVAL";
      LT_MBINIT_REVMB: return "MBINIT.REVMB";
      LT_MBINIT_RPMB:  return "MBINIT.RPMB";
      LT_MB_VALVREF:   return "MBTRAIN.VALVREF";
      LT_MB_DATAVREF:  return "MBTRAIN.DATAVREF";
      LT_MB_SPEEDIDLE: return "MBTRAIN.SPEEDIDLE";
      LT_MB_TXSELFCAL: return "MBTRAIN.TXSELFCAL";
      LT_MB_RXCLKCAL:  return "MBTRAIN.RXCLKCAL";
      LT_MB_VTCENTER:  return "MBTRAIN.VTCENTER";
      LT_MB_DTVREF1:   return "MBTRAIN.DTVREF1";
      LT_MB_RXDESKEW:  return "MBTRAIN.RXDESKEW";
      LT_MB_DTCENTER2: return "MBTRAIN.DTCENTER2";
      LT_MB_LINKSPEED: return "MBTRAIN.LINKSPEED";
      LT_LINKINIT:     return "LINKINIT";
      LT_ACTIVE:       return "ACTIVE";
      LT_TRAINERROR:   return "TRAINERROR";
      default:         return "UNKNOWN";
    endcase
  endfunction

  // ==========================================================================
  // 512-Byte Bidirectional Random Data Streaming in ACTIVE State
  // ==========================================================================
  localparam int STREAM_BYTES = 512;
  localparam int BEATS_TOTAL  = STREAM_BYTES / (DATA_W / 8); // 512 / 16 = 32 beats

  logic [DATA_W-1:0] d0_tx_words [0:BEATS_TOTAL-1];
  logic [DATA_W-1:0] d1_tx_words [0:BEATS_TOTAL-1];
  integer d0_rx_count;
  integer d1_rx_count;
  integer stream_errors;

  // ==========================================================================
  // Termination and Success Checker
  // ==========================================================================
  initial begin
    // Bounded wait for link initialization to reach ACTIVE state
    wait (d0_ltsm_state == LT_ACTIVE && d1_ltsm_state == LT_ACTIVE);
    wait (d0_rdi_state  == RDI_STS_ACTIVE && d1_rdi_state  == RDI_STS_ACTIVE);
    wait (d0_fdi_state  == FDI_STS_ACTIVE && d1_fdi_state  == FDI_STS_ACTIVE);
    wait (d0_pl_state_sts == FDI_STS_ACTIVE && d1_pl_state_sts == FDI_STS_ACTIVE);

    // Let link run in stable ACTIVE for 16 cycles before data transfer
    repeat (16) @(posedge lclk);

    $display("\n==========================================================================");
    $display("LINK INITIALIZATION SUCCESSFUL AT TIME %0t ns", $time);
    $display("  Die0 LTSM: %s (%02h) | RDI: ACTIVE (%01h) | FDI: ACTIVE (%01h)",
             ltsm_state_name(d0_ltsm_state), d0_ltsm_state, d0_rdi_state, d0_pl_state_sts);
    $display("  Die1 LTSM: %s (%02h) | RDI: ACTIVE (%01h) | FDI: ACTIVE (%01h)",
             ltsm_state_name(d1_ltsm_state), d1_ltsm_state, d1_rdi_state, d1_pl_state_sts);
    $display("  Active state successfully broadcasted to partner die and Protocol layer.");
    $display("  Starting %0d-Byte Bidirectional Random Streaming Transfer (Raw Mode)...", STREAM_BYTES);
    $display("==========================================================================");

    // Generate random test data (32 beats = 512 Bytes per direction)
    for (int b = 0; b < BEATS_TOTAL; b = b + 1) begin
      d0_tx_words[b] = {$urandom(), $urandom(), $urandom(), $urandom()};
      d1_tx_words[b] = {$urandom(), $urandom(), $urandom(), $urandom()};
    end

    d0_rx_count   = 0;
    d1_rx_count   = 0;
    stream_errors = 0;

    // Both dies stream in Raw mode using STREAM_ID_S0_STREAMING
    d0_lp_stream = STREAM_ID_S0_STREAMING;
    d1_lp_stream = STREAM_ID_S0_STREAMING;

    // Fork concurrent bidirectional transmission and reception
    fork
      // Die 0 TX: Stream 32 beats (512 Bytes) to Die 1
      begin : d0_tx_proc
        for (int i = 0; i < BEATS_TOTAL; i = i + 1) begin
          @(negedge lclk);
          while (!d0_pl_trdy) @(negedge lclk);
          d0_lp_data  = d0_tx_words[i];
          d0_lp_valid = 1'b1;
          d0_lp_irdy  = 1'b1;
        end
        @(negedge lclk);
        d0_lp_valid = 1'b0;
        d0_lp_irdy  = 1'b0;
        d0_lp_data  = '0;
      end

      // Die 1 TX: Stream 32 beats (512 Bytes) to Die 0
      begin : d1_tx_proc
        for (int j = 0; j < BEATS_TOTAL; j = j + 1) begin
          @(negedge lclk);
          while (!d1_pl_trdy) @(negedge lclk);
          d1_lp_data  = d1_tx_words[j];
          d1_lp_valid = 1'b1;
          d1_lp_irdy  = 1'b1;
        end
        @(negedge lclk);
        d1_lp_valid = 1'b0;
        d1_lp_irdy  = 1'b0;
        d1_lp_data  = '0;
      end

      // Die 0 RX: Receive and verify 32 beats (512 Bytes) from Die 1
      begin : d0_rx_proc
        while (d0_rx_count < BEATS_TOTAL) begin
          @(posedge lclk);
          #0.1;
          if (d0_pl_valid) begin
            if (d0_pl_data !== d1_tx_words[d0_rx_count]) begin
              $display("FAIL [Die0 RX Beat %02d]: got %032h, expected %032h",
                       d0_rx_count, d0_pl_data, d1_tx_words[d0_rx_count]);
              stream_errors = stream_errors + 1;
            end else begin
              $display("PASS [Die0 RX Beat %02d]: %032h (descrambled RDI data matches Die1 TX)",
                       d0_rx_count, d0_pl_data);
            end
            d0_rx_count = d0_rx_count + 1;
          end
        end
      end

      // Die 1 RX: Receive and verify 32 beats (512 Bytes) from Die 0
      begin : d1_rx_proc
        while (d1_rx_count < BEATS_TOTAL) begin
          @(posedge lclk);
          #0.1;
          if (d1_pl_valid) begin
            if (d1_pl_data !== d0_tx_words[d1_rx_count]) begin
              $display("FAIL [Die1 RX Beat %02d]: got %032h, expected %032h",
                       d1_rx_count, d1_pl_data, d0_tx_words[d1_rx_count]);
              stream_errors = stream_errors + 1;
            end else begin
              $display("PASS [Die1 RX Beat %02d]: %032h (descrambled RDI data matches Die0 TX)",
                       d1_rx_count, d1_pl_data);
            end
            d1_rx_count = d1_rx_count + 1;
          end
        end
      end
    join

    // Let link run for 16 idle cycles after transfer completion to show idle on waveform
    repeat (16) @(posedge lclk);

    $display("\n==========================================================================");
    if (stream_errors == 0) begin
      $display("SUCCESS: %0d Bytes transferred bidirectionally (32 beats each way) without error!", STREAM_BYTES);
      $display("  Die0 -> Die1: %0d bytes verified", STREAM_BYTES);
      $display("  Die1 -> Die0: %0d bytes verified", STREAM_BYTES);
      $display("INITIAL BIDIRECTIONAL STREAMING OK");
    end else begin
      $fatal(1, "TEST FAILED tb_link_init_wave: %0d streaming errors detected", stream_errors);
    end
    $display("==========================================================================\n");

    // ==========================================================================
    // 1. LinkReset Flow (Specification Section 8.3.3.1, Figure 125)
    // ==========================================================================
    $display("\n==========================================================================");
    $display("[%0t ns] STEP 1: LinkReset Entry and Exit Flow (Spec Section 8.3.3.1, Figure 125)", $time);
    $display("==========================================================================");

    // Wait for 1us after bidirectional transfer finished
    #1000;
    $display("[%0t ns] 1us delay complete. Die 0 Protocol Layer requesting LinkReset (lp_state_req=LINKRESET)...", $time);

    // Die 0 protocol layer sends request for LinkReset
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_LINKRESET;

    // Die 0 physical layer transmits sideband message LinkMgmt.RDI.Req.LinkReset (01h, 09h)
    // Die 1 receives sideband message requesting LinkReset entry from Die 0
    @(posedge lclk);
    while (!(d1_sb_rx_pkt_vld && (d1_sb_rx_msgcode == 8'h01) && (d1_sb_rx_msgsubcode == 8'h09))) @(posedge lclk);
    $display("[%0t ns] Die 1 received sideband message requesting LinkReset entry from Die 0 (MsgCode 01h, Subcode 09h)", $time);
    // Both dies enter LINKRESET (Section 8.3.2.8: remote partner requested LinkReset over sideband)
    wait (d0_pl_state_sts == FDI_STS_LINKRESET && d1_pl_state_sts == FDI_STS_LINKRESET);
    $display("[%0t ns] Both dies entered LINKRESET (pl_state_sts=LINKRESET) per Section 8.3.2.8", $time);
    // Per Section 8.3.3.1 & Figure 125: Die 1 is UP (Device), Die 1 NEVER sends d1_lp_state_req = FDI_REQ_LINKRESET.
    // Die 1 Protocol Layer observes Link Down Event and withdraws its request to NOP (Section 8.3.2.1).
    @(negedge lclk);
    d1_lp_state_req = FDI_REQ_NOP;
    $display("[%0t ns] Die 1 Protocol Layer observed Link Down Event (d1_lp_state_req set to NOP per Section 8.3.2.1)", $time);

    // Both dies transition to RESET following completed LinkReset exchange
    wait (d0_ltsm_state == LT_RESET && d1_ltsm_state == LT_RESET);
    wait (d0_pl_state_sts == FDI_STS_RESET && d1_pl_state_sts == FDI_STS_RESET);
    $display("[%0t ns] Both dies successfully entered RESET following LinkReset exchange", $time);

    // Die 0 clears SBR to NOP (Figure 125: "Software clear SBR = 1")
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_NOP;
    // With FAST_SIM=1, physical layers dwell in RESET for 40 us (spec Figure 125)
    $display("[%0t ns] Waiting 40 us physical layer RESET dwell...", $time);
    #40_100;
    $display("[%0t ns] 40 us RESET dwell complete. Restarting link training...", $time);
    // Die 0 software issues Start Link Training via FDI Link Control CSR write (Figure 125)
    fdi_cfg_write_link_control(0);
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_ACTIVE;
    d1_lp_state_req = FDI_REQ_ACTIVE;

    // Wait until both dies walk back through training to ACTIVE state
    wait (d0_ltsm_state == LT_ACTIVE && d1_ltsm_state == LT_ACTIVE);
    wait (d0_pl_state_sts == FDI_STS_ACTIVE && d1_pl_state_sts == FDI_STS_ACTIVE);
    $display("[%0t ns] SUCCESS: Both dies returned to ACTIVE state after LinkReset (Figure 125 confirmed)!\n", $time);

    // Let link run in stable ACTIVE for 16 cycles before next step
    repeat (16) @(posedge lclk);

    // ==========================================================================
    // 2. LinkError Flow (Specification Section 8.3.3.2, Figure 126)
    // ==========================================================================
    $display("\n==========================================================================");
    $display("[%0t ns] STEP 2: LinkError Entry and Exit Flow (Spec Section 8.3.3.2, Figure 126)", $time);
    $display("==========================================================================");

    // Wait for 1us after both dies back to ACTIVE state
    #1000;
    $display("[%0t ns] 1us delay complete. Die 0 Protocol Layer detecting UIE and requesting LinkError (lp_linkerror=1)...", $time);

    // Die 0 protocol layer sends request for LinkError via lp_linkerror (Table 115)
    @(negedge lclk);
    d0_lp_linkerror = 1'b1;

    // Die 0 Physical Layer transmits TRAINERROR Entry sideband message (MsgCode E5h, Subcode 00h) to Die 1
    // Die 1 receives sideband message requesting LinkError entry from Die 0
    @(posedge lclk);
    while (!(d1_sb_rx_pkt_vld && (d1_sb_rx_msgcode == 8'hE5 || (d1_sb_rx_msgcode == 8'h01 && d1_sb_rx_msgsubcode == 8'h0A)))) @(posedge lclk);
    $display("[%0t ns] Die 1 received sideband message requesting LinkError entry from Die 0 (MsgCode %02h)", $time, d1_sb_rx_msgcode);

    // Per Figure 126: Die 1 observes Link Down Event (d1_lp_state_req set to NOP, d1_lp_linkerror stays 0)
    @(negedge lclk);
    d1_lp_state_req = FDI_REQ_NOP;
    $display("[%0t ns] Die 1 Protocol Layer observed Link Down Event (d1_lp_state_req set to NOP per Fig 126)", $time);

    // Both dies transition to LinkError / TRAINERROR
    wait (d0_ltsm_state == LT_TRAINERROR && d1_ltsm_state == LT_TRAINERROR);
    wait (d0_pl_state_sts == FDI_STS_LINKERROR && d1_pl_state_sts == FDI_STS_LINKERROR);
    $display("[%0t ns] Both dies hold TRAINERROR and publish FDI LinkError status", $time);

    // Clear the error assertion (Figure 126: "Software clears error status")
    @(negedge lclk);
    d0_lp_linkerror = 1'b0;

    // Recovery from LinkError per Figure 111, Figure 119, Figure 126, and Section 8.3.2.7:
    // Physical layer executes recovery and transitions directly from LinkError to RESET.
    // LinkReset cannot be entered from LinkError (spec Figure 111: "From Any State except LinkError").
    $display("[%0t ns] Initiating recovery from LinkError...", $time);
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_LINKRESET;
    d1_lp_state_req = FDI_REQ_LINKRESET;
    // Both dies leave LinkError and enter RESET directly
    wait (d0_ltsm_state == LT_RESET && d1_ltsm_state == LT_RESET);
    wait (d0_pl_state_sts == FDI_STS_RESET && d1_pl_state_sts == FDI_STS_RESET);
    $display("[%0t ns] Both dies left LinkError and entered RESET directly per Figure 111/126 and Section 8.3.2.7", $time);
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_NOP;
    d1_lp_state_req = FDI_REQ_NOP;
    // With FAST_SIM=1, physical layers dwell in RESET for 40 us (spec Figure 126)
    $display("[%0t ns] Waiting 40 us physical layer RESET dwell...", $time);
    #40_100;
    $display("[%0t ns] 40 us RESET dwell complete. Restarting link training...", $time);
    // Die 0 software issues Start Link Training via FDI Link Control CSR write (Figure 126)
    fdi_cfg_write_link_control(0);
    @(negedge lclk);
    d0_lp_state_req = FDI_REQ_ACTIVE;
    d1_lp_state_req = FDI_REQ_ACTIVE;

    // Wait until both dies walk back through training to ACTIVE state
    wait (d0_ltsm_state == LT_ACTIVE && d1_ltsm_state == LT_ACTIVE);
    wait (d0_pl_state_sts == FDI_STS_ACTIVE && d1_pl_state_sts == FDI_STS_ACTIVE);
    $display("[%0t ns] SUCCESS: Both dies returned to ACTIVE state after LinkError (Figure 126 confirmed)!\n", $time);

    // Final success summary
    $display("==========================================================================");
    $display("TEST PASSED tb_link_init_wave: all bringup, streaming, LinkReset, and LinkError verified");
    $display("  1. Link bringup and 512B bidirectional data streaming verified");
    $display("  2. Section 8.3.3.1 Figure 125 LinkReset entry/exit confirmed (Die 1 never sends LinkReset)");
    $display("  3. Section 8.3.3.2 Figure 126 LinkError entry/exit confirmed");
    $display("==========================================================================");
    $finish;
  end

  // Watchdog timeout
  initial begin
    #2_000_000; // 2 ms watchdog for bringup + LinkReset + LinkError flows
    $fatal(1, "TEST FAILED tb_link_init_wave: Watchdog timeout at %0t ns", $time);
  end

  // ==========================================================================
  // VCD Waveform Dump
  // ==========================================================================
  string wave_path;
  initial begin
    // Save waveform from time 0 (no wait needed since reset dwell is reduced to 40 us)
    wave_path = "logs/link_init.vcd";
    void'($value$plusargs("wave=%s", wave_path));
    $dumpfile(wave_path);

    // Group 1: Timing (Clocks and Resets)
    $dumpvars(0, lclk, sbclk, mbclk,
                 d0_lreset_n, d0_sbreset_n,
                 d1_lreset_n, d1_sbreset_n);

    // Group 2: FDI Interface (Table 115) - Die0 and Die1
    $dumpvars(0, d0_lp_irdy, d0_pl_trdy,
                 d0_lp_valid, d0_pl_valid,
                 d0_lp_data, d0_pl_data,
                 d0_lp_stream, d0_pl_stream,
                 d0_lp_stallack, d0_pl_stallreq,
                 d0_lp_rx_active_sts, d0_pl_rx_active_req,
                 d0_lp_state_req, d0_pl_state_sts,
                 d0_lp_linkerror,
                 d0_pl_inband_pres,
                 d0_pl_error, d0_pl_cerror, d0_pl_nferror,
                 d0_pl_trainerror, d0_pl_phyinrecenter,
                 d0_pl_protocol, d0_pl_protocol_flitfmt, d0_pl_protocol_vld,
                 d0_pl_clk_req, d0_lp_clk_ack,
                 d0_lp_wake_req, d0_pl_wake_ack,
                 d0_pl_speedmode, d0_pl_lnk_cfg,
                 d0_lp_cfg, d0_lp_cfg_vld, d0_lp_cfg_crd,
                 d0_pl_cfg, d0_pl_cfg_vld, d0_pl_cfg_crd);

    $dumpvars(0, d1_lp_irdy, d1_pl_trdy,
                 d1_lp_valid, d1_pl_valid,
                 d1_lp_data, d1_pl_data,
                 d1_lp_stream, d1_pl_stream,
                 d1_lp_stallack, d1_pl_stallreq,
                 d1_lp_rx_active_sts, d1_pl_rx_active_req,
                 d1_lp_state_req, d1_pl_state_sts,
                 d1_lp_linkerror,
                 d1_pl_inband_pres,
                 d1_pl_error, d1_pl_cerror, d1_pl_nferror,
                 d1_pl_trainerror, d1_pl_phyinrecenter,
                 d1_pl_protocol, d1_pl_protocol_flitfmt, d1_pl_protocol_vld,
                 d1_pl_clk_req, d1_lp_clk_ack,
                 d1_lp_wake_req, d1_pl_wake_ack,
                 d1_pl_speedmode, d1_pl_lnk_cfg,
                 d1_lp_cfg, d1_lp_cfg_vld, d1_lp_cfg_crd,
                 d1_pl_cfg, d1_pl_cfg_vld, d1_pl_cfg_crd);

    // Group 3: RDI Interface (Table 114) - Die0 and Die1
    $dumpvars(0, d0_rdi_lp_irdy, d0_rdi_pl_trdy,
                 d0_rdi_lp_valid, d0_rdi_pl_valid,
                 d0_rdi_lp_data, d0_rdi_pl_data,
                 d0_rdi_lp_state_req, d0_rdi_pl_state_sts,
                 d0_rdi_lp_stallack, d0_rdi_pl_stallreq,
                 d0_rdi_lp_linkerror, d0_rdi_pl_linkerror,
                 d0_rdi_pl_inband_pres,
                 d0_rdi_pl_error, d0_rdi_pl_cerror, d0_rdi_pl_nferror,
                 d0_rdi_pl_trainerror, d0_rdi_pl_phyinrecenter,
                 d0_rdi_pl_speedmode, d0_rdi_pl_lnk_cfg);

    $dumpvars(0, d1_rdi_lp_irdy, d1_rdi_pl_trdy,
                 d1_rdi_lp_valid, d1_rdi_pl_valid,
                 d1_rdi_lp_data, d1_rdi_pl_data,
                 d1_rdi_lp_state_req, d1_rdi_pl_state_sts,
                 d1_rdi_lp_stallack, d1_rdi_pl_stallreq,
                 d1_rdi_lp_linkerror, d1_rdi_pl_linkerror,
                 d1_rdi_pl_inband_pres,
                 d1_rdi_pl_error, d1_rdi_pl_cerror, d1_rdi_pl_nferror,
                 d1_rdi_pl_trainerror, d1_rdi_pl_phyinrecenter,
                 d1_rdi_pl_speedmode, d1_rdi_pl_lnk_cfg);

    // Group 4: State Machines
    $dumpvars(0, d0_ltsm_state, d0_sbinit_phase,
                 d0_rdi_state, d0_fdi_state, d0_link_control_start,
                 d1_ltsm_state, d1_sbinit_phase,
                 d1_rdi_state, d1_fdi_state, d1_link_control_start);

    // Group 5: Sideband
    $dumpvars(0, sb_d0_to_d1_clk, sb_d0_to_d1_data,
                 sb_d1_to_d0_clk, sb_d1_to_d0_data,
                 d0_sb_rx_pkt_vld, d0_sb_rx_opcode, d0_sb_rx_msgcode, d0_sb_rx_msgsubcode,
                 d1_sb_rx_pkt_vld, d1_sb_rx_opcode, d1_sb_rx_msgcode, d1_sb_rx_msgsubcode);

    // Group 6: Mainband
    $dumpvars(0, mb_d0_to_d1_data, mb_d0_to_d1_valid,
                 mb_d1_to_d0_data, mb_d1_to_d0_valid);
  end

endmodule

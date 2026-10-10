// ============================================================================
// Module    : tb_reset_to_sbinit
// Project   : UCIe 1.0 Simplified Endpoint
// File      : tb/sbinit/tb_reset_to_sbinit.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 4.5.3.1 - RESET State (4 ms minimum dwell)
//   UCIe 1.0 Specification, Section 4.5.3.2 - SBINIT State and Raw Waveform
//   UCIe 1.0 Specification, Section 5.13    - Sideband Signaling (800 MHz SDR)
//   UCIe 1.0 Specification, Section 8.1     - Raw Die-to-Die Interface (RDI)
//   UCIe 1.0 Specification, Section 8.2     - Flit-Aware D2D Interface (FDI)
//
// DESCRIPTION
//   Dual-die testbench verifying full RESET-to-SBINIT progression between two
//   communicating endpoints across scalar physical pins.
//   Die 0 acts as initiator triggered by software start. Die 1 has no local start
//   and wakes upon detecting the peer's raw SBINIT waveform. Verifies 4 ms
//   minimum RESET dwell, alternating 64-UI pattern exchange, post-detection tails,
//   and clean transition into packet mode.
//
// DUAL-DIE INITIALIZATION TOPOLOGY
//
//   +----------------------+   Scalar Pins   +----------------------+
//   | Die 0 (Initiator)    |================>| Die 1 (Responder)    |
//   |                      |<================|                      |
//   | software start = 1   |                 | software start = 0   |
//   +----------------------+                 +----------------------+
//
// VERIFICATION SEQUENCE & CHECKS
//   1. Asynchronous Reset: Both dies assert reset at time zero. Die 0 executes
//      4 ms minimum dwell in LT_RESET per Section 4.5.3.1.
//   2. Raw Pattern Transmission: Upon dwell expiration and software start,
//      Die 0 begins transmitting 64-UI alternating patterns with 32-UI gaps.
//   3. Remote Wake-up: Die 1 detects Die 0's raw pattern, exits RESET dwell,
//      and begins transmitting its own raw SBINIT pattern.
//   4. Lock & Handshake: After 2 consecutive matches, both dies enter post-detection
//      tails (4 iterations) and advance into packet mode for SBINIT.Done exchange.
//   5. Transition to MBINIT: Both dies successfully exchange SBINIT.Done request/
//      response messages and transition into MBINIT.PARAM.
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Description
//   ------  ----------  ------------------------------------------------------
//   v0.0.1  2026-09-24  Initial creation of dual-die SBINIT TB.
//   v0.0.2  2026-09-28  Migrate sideband pins to scalar SDR strobe.
//   v0.0.3  2026-10-08  Documentation compliance pass: add detailed
//                       header and per-construct comments.
//   v0.0.4  2026-10-09  Cleanup pass: remove unused table column and add inline
//                       comment for task input argument.
//   v0.0.5  2026-10-10  Migrate shared sbclk to separate d0_sbclk and d1_sbclk
//                       per clock contract and expose both in waveform dump.
// ============================================================================
`ifndef TbResetToSbinit_SV
`define TbResetToSbinit_SV

`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module tb_reset_to_sbinit;

  // --------------------------------------------------------------------------
  // Clocks
  // --------------------------------------------------------------------------
  logic lclk;
  logic d0_sbclk;
  logic d1_sbclk;
  logic d0_mbclk;
  logic d1_mbclk;

  initial begin
    lclk     = 1'b0;
    d0_sbclk = 1'b0;
    d1_sbclk = 1'b0;
    d0_mbclk = 1'b0;
    d1_mbclk = 1'b0;
    #0.125;
    forever #0.250 d1_mbclk = ~d1_mbclk;
  end

  // --------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Generates 500 MHz reference link clock for die-to-die initialization test.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Link Clock Frequency.
  // --------------------------------------------------------------------------
  always #1.000 lclk = ~lclk;       // 500 MHz

  // --------------------------------------------------------------------------
  // initial: Sideband Local Clock Generator (800 MHz) for Die 0
  //
  // Generates 800 MHz free-running sideband clock for Die 0 with 0.1875 ns
  // startup delay and 0.625 ns half-period (1.25 ns period), asynchronous
  // to the link clock domain per the clock contract.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 - Sideband Signaling.
  // --------------------------------------------------------------------------
  initial begin
    #0.1875;
    forever #0.625 d0_sbclk = ~d0_sbclk;
  end

  // --------------------------------------------------------------------------
  // initial: Sideband Local Clock Generator (800 MHz) for Die 1
  //
  // Generates 800 MHz free-running sideband clock for Die 1 with 0.4375 ns
  // startup delay and 0.625 ns half-period (1.25 ns period), providing
  // 0.250 ns phase separation relative to Die 0 per the clock contract.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 - Sideband Signaling.
  // --------------------------------------------------------------------------
  initial begin
    #0.4375;
    forever #0.625 d1_sbclk = ~d1_sbclk;
  end

  // --------------------------------------------------------------------------
  // always: Free-Running Mainband Local Clock Generator (2 GHz) for Die 0
  //
  // Generates 2 GHz free-running local clock source for Die 0 operation.
  // Operates continuously without obsolete LTSM state-gating.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.1.1 - Mainband Clocking.
  // --------------------------------------------------------------------------
  always #0.250 d0_mbclk = ~d0_mbclk;

  // --------------------------------------------------------------------------
  // Forwarded physical clock output enables and crossing wires from DUT outputs
  // --------------------------------------------------------------------------
  logic d0_mb_tx_clk;
  logic d0_mb_tx_clk_oe;
  logic d0_mb_tx_data_oe;
  logic d0_mb_tx_valid_oe;

  logic d1_mb_tx_clk;
  logic d1_mb_tx_clk_oe;
  logic d1_mb_tx_data_oe;
  logic d1_mb_tx_valid_oe;

  wire mb_d0_to_d1_clk = d0_mb_tx_clk_oe ? d0_mb_tx_clk : 1'b0;
  wire mb_d1_to_d0_clk = d1_mb_tx_clk_oe ? d1_mb_tx_clk : 1'b0;

  // --------------------------------------------------------------------------
  // Asynchronous per-die reset pairs
  // --------------------------------------------------------------------------
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

    // Release both dies together off the lclk edge. Die 0 still owns the
    // initiator Start pulse. Die 1 starts only from the received pattern.
    #17.300;
    d0_lreset_n  = 1'b1;
    d0_sbreset_n = 1'b1;
    d1_lreset_n  = 1'b1;
    d1_sbreset_n = 1'b1;
    d0_reset_release_time = $time;
    d1_reset_release_time = $time;
  end

  // --------------------------------------------------------------------------
  // Die-to-die physical wires
  // --------------------------------------------------------------------------
  logic                 sb_d0_to_d1_clk;
  logic                 sb_d0_to_d1_data;
  logic                 sb_d1_to_d0_clk;
  logic                 sb_d1_to_d0_data;
  logic [NLANES_MAX-1:0] mb_d0_to_d1_data;
  logic [NLANES_MAX-1:0] mb_d1_to_d0_data;
  logic                  mb_d0_to_d1_valid;
  logic                  mb_d1_to_d0_valid;

  // --------------------------------------------------------------------------
  // Die 0 FDI inputs and outputs
  // --------------------------------------------------------------------------
  logic                  d0_lp_irdy;
  logic                  d0_lp_valid;
  logic [DATA_W-1:0]     d0_lp_data;
  logic [7:0]            d0_lp_stream;
  logic                  d0_lp_stallack;
  logic                  d0_lp_rx_active_sts;
  logic [3:0]            d0_lp_state_req;
  logic [NC-1:0]         d0_lp_cfg;
  logic                  d0_lp_cfg_vld;
  logic                  d0_lp_cfg_crd;
  logic                  d0_lp_clk_ack;
  logic                  d0_lp_wake_req;

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

  // --------------------------------------------------------------------------
  // Die 1 FDI inputs and outputs
  // --------------------------------------------------------------------------
  logic                  d1_lp_irdy;
  logic                  d1_lp_valid;
  logic [DATA_W-1:0]     d1_lp_data;
  logic [7:0]            d1_lp_stream;
  logic                  d1_lp_stallack;
  logic                  d1_lp_rx_active_sts;
  logic [3:0]            d1_lp_state_req;
  logic [NC-1:0]         d1_lp_cfg;
  logic                  d1_lp_cfg_vld;
  logic                  d1_lp_cfg_crd;
  logic                  d1_lp_clk_ack;
  logic                  d1_lp_wake_req;

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

  // --------------------------------------------------------------------------
  // Internal state and sideband observations exposed in the waveform
  // --------------------------------------------------------------------------
  wire [7:0] d0_ltsm_state = dut_die0.u_lphy.u_ltsm.state_q;
  wire [7:0] d1_ltsm_state = dut_die1.u_lphy.u_ltsm.state_q;
  wire [3:0] d0_rdi_state  = dut_die0.u_lphy.u_rdi_sm.state_q;
  wire [3:0] d1_rdi_state  = dut_die1.u_lphy.u_rdi_sm.state_q;
  wire [1:0] d0_sbinit_phase = dut_die0.u_lphy.u_ltsm.sbinit_phase_q;
  wire [1:0] d1_sbinit_phase = dut_die1.u_lphy.u_ltsm.sbinit_phase_q;
  wire       d0_sb_rx_pkt_vld = dut_die0.u_lphy.sb_rx_pkt_vld;
  wire       d1_sb_rx_pkt_vld = dut_die1.u_lphy.sb_rx_pkt_vld;
  wire [4:0] d0_sb_rx_opcode = dut_die0.u_lphy.sb_rx_opcode;
  wire [4:0] d1_sb_rx_opcode = dut_die1.u_lphy.sb_rx_opcode;
  wire [7:0] d0_sb_rx_msgcode = dut_die0.u_lphy.sb_rx_msgcode;
  wire [7:0] d1_sb_rx_msgcode = dut_die1.u_lphy.sb_rx_msgcode;
  wire [7:0] d0_sb_rx_msgsubcode = dut_die0.u_lphy.sb_rx_msgsubcode;
  wire [7:0] d1_sb_rx_msgsubcode = dut_die1.u_lphy.sb_rx_msgsubcode;
  wire [3:0] d0_fdi_state = dut_die0.u_adapter.u_fdi_sm.fdi_q;
  wire [3:0] d1_fdi_state = dut_die1.u_adapter.u_fdi_sm.fdi_q;

  wire       d0_rdi_lp_linkerror = dut_die0.rdi_lp_linkerror;
  wire       d0_rdi_lp_stallack = dut_die0.rdi_lp_stallack;
  wire       d0_rdi_pl_error = dut_die0.rdi_pl_error;
  wire       d0_rdi_pl_linkerror = dut_die0.rdi_pl_linkerror;
  wire       d0_rdi_pl_phyinrecenter = dut_die0.rdi_pl_phyinrecenter;
  wire       d0_rdi_pl_cerror = dut_die0.rdi_pl_cerror;
  wire       d0_rdi_pl_nferror = dut_die0.rdi_pl_nferror;
  wire       d0_rdi_pl_trainerror = dut_die0.rdi_pl_trainerror;
  wire [2:0] d0_rdi_pl_lnk_cfg = dut_die0.rdi_pl_lnk_cfg;
  wire [2:0] d0_rdi_pl_speedmode = dut_die0.rdi_pl_speedmode;

  wire       d1_rdi_lp_linkerror = dut_die1.rdi_lp_linkerror;
  wire       d1_rdi_lp_stallack = dut_die1.rdi_lp_stallack;
  wire       d1_rdi_pl_error = dut_die1.rdi_pl_error;
  wire       d1_rdi_pl_linkerror = dut_die1.rdi_pl_linkerror;
  wire       d1_rdi_pl_phyinrecenter = dut_die1.rdi_pl_phyinrecenter;
  wire       d1_rdi_pl_cerror = dut_die1.rdi_pl_cerror;
  wire       d1_rdi_pl_nferror = dut_die1.rdi_pl_nferror;
  wire       d1_rdi_pl_trainerror = dut_die1.rdi_pl_trainerror;
  wire [2:0] d1_rdi_pl_lnk_cfg = dut_die1.rdi_pl_lnk_cfg;
  wire [2:0] d1_rdi_pl_speedmode = dut_die1.rdi_pl_speedmode;
  wire [3:0] d0_rdi_pl_state_sts = dut_die0.rdi_pl_state_sts;
  wire [3:0] d1_rdi_pl_state_sts = dut_die1.rdi_pl_state_sts;

  wire [3:0] d0_adapter_sm_state =
    dut_die0.u_adapter.u_fdi_sm.fdi_q;
  wire [3:0] d1_adapter_sm_state =
    dut_die1.u_adapter.u_fdi_sm.fdi_q;
  wire [3:0] d0_adapter_sm_next_state =
    dut_die0.u_adapter.u_fdi_sm.fdi_d;
  wire [3:0] d1_adapter_sm_next_state =
    dut_die1.u_adapter.u_fdi_sm.fdi_d;
  wire [3:0] d0_rdi_sm_state =
    dut_die0.u_lphy.u_rdi_sm.state_q;
  wire [3:0] d1_rdi_sm_state =
    dut_die1.u_lphy.u_rdi_sm.state_q;
  wire [3:0] d0_rdi_sm_next_state =
    dut_die0.u_lphy.u_rdi_sm.state_d;
  wire [3:0] d1_rdi_sm_next_state =
    dut_die1.u_lphy.u_rdi_sm.state_d;
  wire [7:0] d0_ltsm_sm_state =
    dut_die0.u_lphy.u_ltsm.state_q;
  wire [7:0] d1_ltsm_sm_state =
    dut_die1.u_lphy.u_ltsm.state_q;
  wire [7:0] d0_ltsm_sm_next_state =
    dut_die0.u_lphy.u_ltsm.state_d;
  wire [7:0] d1_ltsm_sm_next_state =
    dut_die1.u_lphy.u_ltsm.state_d;

  // RDI signals are internal to ucie_main. The aliases make them visible with
  // stable testbench names in the VCD and in the trace output.
  wire [3:0]      d0_rdi_lp_state_req = dut_die0.rdi_lp_state_req;
  wire            d0_rdi_lp_irdy = dut_die0.rdi_lp_irdy;
  wire            d0_rdi_lp_valid = dut_die0.rdi_lp_valid;
  wire [DATA_W-1:0] d0_rdi_lp_data = dut_die0.rdi_lp_data;
  wire            d0_rdi_pl_trdy = dut_die0.rdi_pl_trdy;
  wire            d0_rdi_pl_valid = dut_die0.rdi_pl_valid;
  wire [DATA_W-1:0] d0_rdi_pl_data = dut_die0.rdi_pl_data;
  wire            d0_rdi_pl_inband_pres = dut_die0.rdi_pl_inband_pres;
  wire            d0_rdi_pl_stallreq = dut_die0.rdi_pl_stallreq;

  wire [3:0]      d1_rdi_lp_state_req = dut_die1.rdi_lp_state_req;
  wire            d1_rdi_lp_irdy = dut_die1.rdi_lp_irdy;
  wire            d1_rdi_lp_valid = dut_die1.rdi_lp_valid;
  wire [DATA_W-1:0] d1_rdi_lp_data = dut_die1.rdi_lp_data;
  wire            d1_rdi_pl_trdy = dut_die1.rdi_pl_trdy;
  wire            d1_rdi_pl_valid = dut_die1.rdi_pl_valid;
  wire [DATA_W-1:0] d1_rdi_pl_data = dut_die1.rdi_pl_data;
  wire            d1_rdi_pl_inband_pres = dut_die1.rdi_pl_inband_pres;
  wire            d1_rdi_pl_stallreq = dut_die1.rdi_pl_stallreq;

  // --------------------------------------------------------------------------
  parameter bit FAST_SIM = 1'b1;
  localparam time C_RESET_MIN_DWELL_NS = FAST_SIM ? 40_000 : 4_000_000;

  // --------------------------------------------------------------------------
  // Module instantiation: ucie_main dut_die0 (Die 0 initiator)
  //
  // Die 0 is the SBINIT initiator. After its 4 ms RESET dwell and a software
  // Start pulse it begins raw pattern transmission. Its sideband and mainband
  // pins are cross-wired to dut_die1, so the pair forms one complete link.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.1 and Section 4.5.3.2.
  // --------------------------------------------------------------------------
  ucie_main #(.FAST_SIM(FAST_SIM)) dut_die0 (
    .lclk(lclk), .lreset_n(d0_lreset_n), .mbclk(d0_mbclk),
    .mb_tx_clk(d0_mb_tx_clk), .mb_tx_clk_oe(d0_mb_tx_clk_oe),
    .mb_tx_data_oe(d0_mb_tx_data_oe), .mb_tx_valid_oe(d0_mb_tx_valid_oe),
    .mb_rx_clk(mb_d1_to_d0_clk), .sbclk(d0_sbclk),
    .sbreset_n(d0_sbreset_n),
    .lp_irdy(d0_lp_irdy), .lp_valid(d0_lp_valid), .lp_data(d0_lp_data),
    .lp_stream(d0_lp_stream), .lp_stallack(d0_lp_stallack),
    .lp_rx_active_sts(d0_lp_rx_active_sts), .pl_trdy(d0_pl_trdy),
    .pl_valid(d0_pl_valid), .pl_data(d0_pl_data), .pl_stream(d0_pl_stream),
    .pl_error(d0_pl_error), .pl_cerror(d0_pl_cerror),
    .pl_nferror(d0_pl_nferror), .pl_trainerror(d0_pl_trainerror),
    .pl_phyinrecenter(d0_pl_phyinrecenter), .pl_protocol(d0_pl_protocol),
    .pl_protocol_flitfmt(d0_pl_protocol_flitfmt),
    .pl_protocol_vld(d0_pl_protocol_vld), .pl_clk_req(d0_pl_clk_req),
    .lp_clk_ack(d0_lp_clk_ack), .lp_wake_req(d0_lp_wake_req),
    .pl_wake_ack(d0_pl_wake_ack), .pl_speedmode(d0_pl_speedmode),
    .pl_lnk_cfg(d0_pl_lnk_cfg), .pl_rx_active_req(d0_pl_rx_active_req),
    .lp_state_req(d0_lp_state_req), .pl_state_sts(d0_pl_state_sts),
    .pl_inband_pres(d0_pl_inband_pres), .pl_stallreq(d0_pl_stallreq),
    .lp_cfg(d0_lp_cfg), .lp_cfg_vld(d0_lp_cfg_vld), .lp_cfg_crd(d0_lp_cfg_crd),
    .pl_cfg(d0_pl_cfg), .pl_cfg_vld(d0_pl_cfg_vld), .pl_cfg_crd(d0_pl_cfg_crd),
    .sb_tx_clk(sb_d0_to_d1_clk), .sb_tx_data(sb_d0_to_d1_data),
    .sb_rx_clk(sb_d1_to_d0_clk), .sb_rx_data(sb_d1_to_d0_data),
    .mb_tx_data(mb_d0_to_d1_data), .mb_tx_valid(mb_d0_to_d1_valid),
    .mb_rx_data(mb_d1_to_d0_data), .mb_rx_valid(mb_d1_to_d0_valid)
  );

  // --------------------------------------------------------------------------
  // Module instantiation: ucie_main dut_die1 (Die 1 endpoint)
  //
  // Die 1 is the responder. It receives no local Start pulse and leaves RESET
  // only after detecting Die 0's raw SBINIT pattern, which exercises the
  // remote-wake path of Section 4.5.3.2.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.2 - SBINIT.
  // --------------------------------------------------------------------------
  ucie_main #(.FAST_SIM(FAST_SIM)) dut_die1 (
    .lclk(lclk), .lreset_n(d1_lreset_n), .mbclk(d1_mbclk),
    .mb_tx_clk(d1_mb_tx_clk), .mb_tx_clk_oe(d1_mb_tx_clk_oe),
    .mb_tx_data_oe(d1_mb_tx_data_oe), .mb_tx_valid_oe(d1_mb_tx_valid_oe),
    .mb_rx_clk(mb_d0_to_d1_clk), .sbclk(d1_sbclk),
    .sbreset_n(d1_sbreset_n),
    .lp_irdy(d1_lp_irdy), .lp_valid(d1_lp_valid), .lp_data(d1_lp_data),
    .lp_stream(d1_lp_stream), .lp_stallack(d1_lp_stallack),
    .lp_rx_active_sts(d1_lp_rx_active_sts), .pl_trdy(d1_pl_trdy),
    .pl_valid(d1_pl_valid), .pl_data(d1_pl_data), .pl_stream(d1_pl_stream),
    .pl_error(d1_pl_error), .pl_cerror(d1_pl_cerror),
    .pl_nferror(d1_pl_nferror), .pl_trainerror(d1_pl_trainerror),
    .pl_phyinrecenter(d1_pl_phyinrecenter), .pl_protocol(d1_pl_protocol),
    .pl_protocol_flitfmt(d1_pl_protocol_flitfmt),
    .pl_protocol_vld(d1_pl_protocol_vld), .pl_clk_req(d1_pl_clk_req),
    .lp_clk_ack(d1_lp_clk_ack), .lp_wake_req(d1_lp_wake_req),
    .pl_wake_ack(d1_pl_wake_ack), .pl_speedmode(d1_pl_speedmode),
    .pl_lnk_cfg(d1_pl_lnk_cfg), .pl_rx_active_req(d1_pl_rx_active_req),
    .lp_state_req(d1_lp_state_req), .pl_state_sts(d1_pl_state_sts),
    .pl_inband_pres(d1_pl_inband_pres), .pl_stallreq(d1_pl_stallreq),
    .lp_cfg(d1_lp_cfg), .lp_cfg_vld(d1_lp_cfg_vld), .lp_cfg_crd(d1_lp_cfg_crd),
    .pl_cfg(d1_pl_cfg), .pl_cfg_vld(d1_pl_cfg_vld), .pl_cfg_crd(d1_pl_cfg_crd),
    .sb_tx_clk(sb_d1_to_d0_clk), .sb_tx_data(sb_d1_to_d0_data),
    .sb_rx_clk(sb_d0_to_d1_clk), .sb_rx_data(sb_d0_to_d1_data),
    .mb_tx_data(mb_d1_to_d0_data), .mb_tx_valid(mb_d1_to_d0_valid),
    .mb_rx_data(mb_d0_to_d1_data), .mb_rx_valid(mb_d0_to_d1_valid)
  );

  // --------------------------------------------------------------------------
  // Protocol-layer stimulus
  // --------------------------------------------------------------------------
  task automatic fdi_cfg_write_link_control(
    input int die_sel // Die index selector: 0 for die 0, 1 for die 1
  );
    ucie_pkg::sb_packet_t req;
    logic [63:0] hdr;
    logic [63:0] pld;
    begin
      req = '0;
      req.opcode = ucie_pkg::SB_OP_CFG_WRITE64;
      req.src_id = ucie_pkg::FDI_SRCID_STACK0;
      req.dst_id = ucie_pkg::FDI_DSTID_ADAPTER;
      req.addr   = 27'h0000000;  // 0x00: UCIe Link Control Register
      req.data   = 64'h0000_0000_0000_0001;  // Bit 0 = 1b: Start UCIe Link Training
      req.be     = 8'hFF;
      req.tag    = (die_sel == 0) ? 5'h01 : 5'h02;
      hdr = ucie_pkg::sb_encode_header(req);
      pld = 64'h0000_0000_0000_0001;

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

  initial begin
    d0_lp_irdy = 1'b0;
    d0_lp_valid = 1'b0;
    d0_lp_data = '0;
    d0_lp_stream = STREAM_ID_S0_STREAMING;
    d0_lp_stallack = 1'b0;
    d0_lp_rx_active_sts = 1'b1;
    d0_lp_state_req = FDI_REQ_ACTIVE;
    d0_lp_cfg = '0;
    d0_lp_cfg_vld = 1'b0;
    d0_lp_cfg_crd = 1'b0;
    d0_lp_clk_ack = 1'b1;
    d0_lp_wake_req = 1'b0;

    d1_lp_irdy = 1'b0;
    d1_lp_valid = 1'b0;
    d1_lp_data = '0;
    d1_lp_stream = STREAM_ID_S0_STREAMING;
    d1_lp_stallack = 1'b0;
    d1_lp_rx_active_sts = 1'b1;
    d1_lp_state_req = FDI_REQ_ACTIVE;
    d1_lp_cfg = '0;
    d1_lp_cfg_vld = 1'b0;
    d1_lp_cfg_crd = 1'b0;
    d1_lp_clk_ack = 1'b1;
    d1_lp_wake_req = 1'b0;

    @(posedge d0_lreset_n);
    #0.700;
    fdi_cfg_write_link_control(0);
  end
  // --------------------------------------------------------------------------
  // Waveform dump
  // --------------------------------------------------------------------------
  string wave_path;
  initial begin
    wave_path = "logs/sbinit.vcd";
    void'($value$plusargs("wave=%s", wave_path));
    $dumpfile(wave_path);

    // Keep the low-rate reset, state, FDI, and RDI probes active from time
    // zero. Expose both local sideband clock sources (d0_sbclk, d1_sbclk) so the
    // parent can measure periods and phase separation. The external scalar
    // sideband clock/data pins remain in the dump.
    $dumpvars(0, lclk, d0_sbclk, d1_sbclk, d0_mbclk, d1_mbclk,
                 d0_mb_tx_clk, d0_mb_tx_clk_oe, d0_mb_tx_data_oe, d0_mb_tx_valid_oe,
                 d1_mb_tx_clk, d1_mb_tx_clk_oe, d1_mb_tx_data_oe, d1_mb_tx_valid_oe,
                 mb_d0_to_d1_clk, mb_d1_to_d0_clk,
                 d0_lreset_n, d0_sbreset_n, d1_lreset_n, d1_sbreset_n,
                 sb_d0_to_d1_clk, sb_d0_to_d1_data,
                 sb_d1_to_d0_clk, sb_d1_to_d0_data,
                 mb_d0_to_d1_data, mb_d0_to_d1_valid,
                 mb_d1_to_d0_data, mb_d1_to_d0_valid);

    $dumpvars(0, d0_lp_irdy, d0_lp_valid, d0_lp_data, d0_lp_stream,
                 d0_lp_stallack, d0_lp_rx_active_sts, d0_lp_state_req,
                 d0_lp_cfg, d0_lp_cfg_vld, d0_lp_cfg_crd,
                 d0_lp_clk_ack, d0_lp_wake_req,
                 d1_lp_irdy, d1_lp_valid, d1_lp_data, d1_lp_stream,
                 d1_lp_stallack, d1_lp_rx_active_sts, d1_lp_state_req,
                 d1_lp_cfg, d1_lp_cfg_vld, d1_lp_cfg_crd,
                 d1_lp_clk_ack, d1_lp_wake_req);

    $dumpvars(0, d0_pl_trdy, d0_pl_valid, d0_pl_data, d0_pl_stream,
                 d0_pl_error, d0_pl_cerror, d0_pl_nferror,
                 d0_pl_trainerror, d0_pl_phyinrecenter, d0_pl_protocol,
                 d0_pl_protocol_flitfmt, d0_pl_protocol_vld, d0_pl_clk_req,
                 d0_pl_wake_ack, d0_pl_speedmode, d0_pl_lnk_cfg,
                 d0_pl_rx_active_req, d0_pl_state_sts, d0_pl_inband_pres,
                 d0_pl_stallreq, d0_pl_cfg, d0_pl_cfg_vld, d0_pl_cfg_crd,
                 d1_pl_trdy, d1_pl_valid, d1_pl_data, d1_pl_stream,
                 d1_pl_error, d1_pl_cerror, d1_pl_nferror,
                 d1_pl_trainerror, d1_pl_phyinrecenter, d1_pl_protocol,
                 d1_pl_protocol_flitfmt, d1_pl_protocol_vld, d1_pl_clk_req,
                 d1_pl_wake_ack, d1_pl_speedmode, d1_pl_lnk_cfg,
                 d1_pl_rx_active_req, d1_pl_state_sts, d1_pl_inband_pres,
                 d1_pl_stallreq, d1_pl_cfg, d1_pl_cfg_vld, d1_pl_cfg_crd);

    $dumpvars(0, d0_rdi_lp_state_req, d0_rdi_lp_linkerror,
                 d0_rdi_lp_stallack, d0_rdi_lp_irdy, d0_rdi_lp_valid,
                 d0_rdi_lp_data, d0_rdi_pl_state_sts, d0_rdi_pl_trdy,
                 d0_rdi_pl_valid, d0_rdi_pl_data, d0_rdi_pl_inband_pres,
                 d0_rdi_pl_stallreq, d0_rdi_pl_error,
                 d0_rdi_pl_linkerror, d0_rdi_pl_phyinrecenter,
                 d0_rdi_pl_cerror, d0_rdi_pl_nferror,
                 d0_rdi_pl_trainerror, d0_rdi_pl_lnk_cfg,
                 d0_rdi_pl_speedmode,
                 d1_rdi_lp_state_req, d1_rdi_lp_linkerror,
                 d1_rdi_lp_stallack, d1_rdi_lp_irdy, d1_rdi_lp_valid,
                 d1_rdi_lp_data, d1_rdi_pl_state_sts, d1_rdi_pl_trdy,
                 d1_rdi_pl_valid, d1_rdi_pl_data, d1_rdi_pl_inband_pres,
                 d1_rdi_pl_stallreq, d1_rdi_pl_error,
                 d1_rdi_pl_linkerror, d1_rdi_pl_phyinrecenter,
                 d1_rdi_pl_cerror, d1_rdi_pl_nferror,
                 d1_rdi_pl_trainerror, d1_rdi_pl_lnk_cfg,
                 d1_rdi_pl_speedmode);

    $dumpvars(0, d0_fdi_state, d1_fdi_state,
                 d0_adapter_sm_state, d1_adapter_sm_state,
                 d0_adapter_sm_next_state, d1_adapter_sm_next_state,
                 d0_rdi_state, d1_rdi_state,
                 d0_rdi_sm_state, d1_rdi_sm_state,
                 d0_rdi_sm_next_state, d1_rdi_sm_next_state,
                 d0_ltsm_state, d1_ltsm_state,
                 d0_ltsm_sm_state, d1_ltsm_sm_state,
                 d0_ltsm_sm_next_state, d1_ltsm_sm_next_state,
                 d0_sbinit_phase, d1_sbinit_phase,
                 d0_sb_rx_pkt_vld, d1_sb_rx_pkt_vld,
                 d0_sb_rx_opcode, d1_sb_rx_opcode,
                 d0_sb_rx_msgcode, d1_sb_rx_msgcode,
                 d0_sb_rx_msgsubcode, d1_sb_rx_msgsubcode);

  end

  // --------------------------------------------------------------------------
  // Trace and completion checks
  // --------------------------------------------------------------------------
  integer errors;
  logic d0_sbinit_done;
  logic d1_sbinit_done;
  logic d0_seen_sbinit;
  logic d1_seen_sbinit;
  logic [7:0] d0_prev_ltsm_state;
  logic [7:0] d1_prev_ltsm_state;

  initial begin
    errors = 0;
    d0_sbinit_done = 1'b0;
    d1_sbinit_done = 1'b0;
    d0_seen_sbinit = 1'b0;
    d1_seen_sbinit = 1'b0;
    d0_prev_ltsm_state = LT_RESET;
    d1_prev_ltsm_state = LT_RESET;
  end

  // --------------------------------------------------------------------------
  // always: State Transition Trace Logger
  //
  // Logs LTSM, RDI, FDI, and sideband phase transitions for both dies to stdout
  // for cycle-accurate initialization debug.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3 - Link Training.
  // --------------------------------------------------------------------------
  always @(posedge lclk) begin
    if (d0_ltsm_state !== d0_prev_ltsm_state) begin
      $display("TRACE %0t DIE0 LTSM=%02h RDI=%01h FDI=%01h FDI_PUB=%01h SBPH=%01h",
               $time, d0_ltsm_state, d0_rdi_state, d0_fdi_state,
               d0_pl_state_sts, d0_sbinit_phase);
      d0_prev_ltsm_state = d0_ltsm_state;
    end
    if (d1_ltsm_state !== d1_prev_ltsm_state) begin
      $display("TRACE %0t DIE1 LTSM=%02h RDI=%01h FDI=%01h FDI_PUB=%01h SBPH=%01h",
               $time, d1_ltsm_state, d1_rdi_state, d1_fdi_state,
               d1_pl_state_sts, d1_sbinit_phase);
      d1_prev_ltsm_state = d1_ltsm_state;
    end

    if (!d0_seen_sbinit && (d0_ltsm_state == LT_SBINIT)) begin
      d0_seen_sbinit = 1'b1;
      if (($time - d0_reset_release_time) < C_RESET_MIN_DWELL_NS) begin
        $display("FAIL tb_reset_to_sbinit: Die0 RESET dwell was %0t ns", $time - d0_reset_release_time);
        errors = errors + 1;
      end
    end
    if (!d1_seen_sbinit && (d1_ltsm_state == LT_SBINIT)) begin
      d1_seen_sbinit = 1'b1;
      if (($time - d1_reset_release_time) < C_RESET_MIN_DWELL_NS) begin
        $display("FAIL tb_reset_to_sbinit: Die1 RESET dwell was %0t ns", $time - d1_reset_release_time);
        errors = errors + 1;
      end
    end

    if ((d0_ltsm_state == LT_MBINIT_PARAM) && d0_seen_sbinit)
      d0_sbinit_done = 1'b1;
    if ((d1_ltsm_state == LT_MBINIT_PARAM) && d1_seen_sbinit)
      d1_sbinit_done = 1'b1;

    if (!d0_sbinit_done && !d1_sbinit_done &&
        (mb_d0_to_d1_valid || mb_d1_to_d0_valid)) begin
      $display("FAIL tb_reset_to_sbinit: mainband valid asserted before SBINIT completion");
      errors = errors + 1;
    end
    if (!d0_sbinit_done && d0_rdi_pl_inband_pres) begin
      $display("FAIL tb_reset_to_sbinit: Die0 pl_inband_pres asserted before SBINIT completion");
      errors = errors + 1;
    end
    if (!d1_sbinit_done && d1_rdi_pl_inband_pres) begin
      $display("FAIL tb_reset_to_sbinit: Die1 pl_inband_pres asserted before SBINIT completion");
      errors = errors + 1;
    end
    if (d0_lreset_n && (d0_ltsm_state <= LT_MBINIT_CAL)) begin
      if ({d0_mb_tx_clk_oe, d0_mb_tx_data_oe, d0_mb_tx_valid_oe} !== 3'b000) begin
        $display("FAIL tb_reset_to_sbinit: Die 0 clock, data, or Valid output enable is active before RPCLK");
        errors = errors + 1;
      end
      if (mb_d0_to_d1_clk !== 1'b0) begin
        $display("FAIL tb_reset_to_sbinit: Die 0 forwarded clock active during early states");
        errors = errors + 1;
      end
    end
    if (d1_lreset_n && (d1_ltsm_state <= LT_MBINIT_CAL)) begin
      if ({d1_mb_tx_clk_oe, d1_mb_tx_data_oe, d1_mb_tx_valid_oe} !== 3'b000) begin
        $display("FAIL tb_reset_to_sbinit: Die 1 clock, data, or Valid output enable is active before RPCLK");
        errors = errors + 1;
      end
      if (mb_d1_to_d0_clk !== 1'b0) begin
        $display("FAIL tb_reset_to_sbinit: Die 1 forwarded clock active during early states");
        errors = errors + 1;
      end
    end
  end

  initial begin
    wait (d0_sbinit_done && d1_sbinit_done);
    repeat (4) @(posedge lclk);
    if (errors == 0) begin
      $display("SBINIT COMPLETED: Die0 and Die1 entered MBINIT.PARAM");
      $display("TEST PASSED tb_reset_to_sbinit");
    end else begin
      $fatal(1, "TEST FAILED tb_reset_to_sbinit: %0d errors", errors);
    end
    $finish;
  end

  initial begin
    #(30_000_000);
    $fatal(1, "TEST FAILED tb_reset_to_sbinit: watchdog at %0t", $time);
  end

endmodule
`endif

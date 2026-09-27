// ============================================================================
// File        : cov_monitor.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Coverage monitor for the two-die loopback testbench.
//
// This module is a passive, synthesisable-style coverage collector designed
// to run alongside the two-die loopback testbench.  It taps the observable
// signals of both Die 0 and Die 1 and maintains explicit counter arrays
// that record which states, opcodes, message codes, and functional events
// have been exercised during a simulation run.
//
// -------------------------------------------------------------------------
// Why explicit counters instead of covergroups?
// -------------------------------------------------------------------------
// Icarus Verilog 12.0 (our primary open-source simulation target) does not
// implement SystemVerilog covergroups, coverpoints, or crosses.  To keep
// the design portable across Icarus, Verilator, and commercial simulators
// the monitor uses plain integer/logic counters in place of covergroups.
// Each counter is incremented (or set to 1 for "hit" bitmasks) when the
// associated condition is observed on the relevant clock edge.  The result
// is functionally equivalent to a covergroup with auto_bin_max sampling.
//
// -------------------------------------------------------------------------
// What is observed?
// -------------------------------------------------------------------------
// The monitor observes four broad categories of activity:
//
//   1. LTSM state histogram  – Records which Link Training State Machine
//      states have been visited by either die.  A one-hot bitmask
//      (ltsm_state_hits) is indexed by the 8-bit state encoding from
//      ucie_pkg.  The NSTATES parameter (default LT_NUM_STATES) sets the
//      upper bound so out-of-range indices are ignored. Per-die SBINIT phase
//      masks and ordered progress record Pattern, Out-of-Reset, and Done.
//      Spec ref: Section 4.5.3 - Link Training State Machine.
//
//   2. Sideband packet histograms – On every valid sideband packet, the
//      opcode and message code update shared histograms. Each die also has a
//      message-subcode histogram for SBINIT evidence.
//      Because both dies' RX paths are monitored, traffic in both
//      directions of the sideband crossing is captured.
//      Spec ref: Section 6.1.1 - Packet Types (opcode and msgcode
//                encoding).
//
//   3. RDI state histogram – The 4-bit rdi_state_sts from each die is
//      used to index a 16-entry counter array, recording which RDI states
//      have been entered.
//      Spec ref: Section 8.1 - Raw Die-to-Die Interface (RDI), Table 114.
//
//   4. Functional event counters – Miscellaneous signals of interest
//      (transfer completion, 4-phase stalls, width degradation, lane
//      reversal, Raw Mode advertisement, CRC-off advertisement) are each
//      counted in a dedicated 32-bit register on the lclk edge.
//      Spec ref: Section 4.5 - Link Initialization and Training (events),
//                Section 8.1.5 - RDI State Status Machine (link_active).
//
//   5. Phase F functional event counters – Explicit event counters for the
//      Phase F coverage model covering:
//        - MBINIT.PARAM request and response roles (Section 4.5.3.3.1, Table 56)
//        - Phase B training and Phase C management transaction classes
//          (Section 4.5.3, Table 53, Table 56; PLAN.md Section 15.3)
//        - Transmit priority arbitration (Section 6.1.3; PLAN.md Section 15.3)
//        - Fatal causes and triggers (Section 4.5.3.8; PLAN.md Section 15.4)
//        - TRAINERROR state and entry exchange (Section 4.5.3.8)
//        - LinkReset recovery exchange and dwell (Section 4.5.3.1, 8.1.5, 8.3.2.8)
//        - Disabled recovery exchange and dwell (Section 4.5.3.1, 8.1.5)
//        - PMNAK status on unsupported PM requests (Section 8.1.5, Table 114)
//        - Active Entry sequence completion (Section 8.1.6; PLAN.md Section 15.4)
//        - Pre-Active user data blocking verification (Section 8.1.6; PLAN.md 15.6)
//        - Active data scrambling and descrambling (Section 4.4.1; PLAN.md 15.6)
//        - Mainband framing boundary fault detection (Section 4.1.2; PLAN.md 15.6)
//      Each event uses robust one-shot / edge-detection sampling on posedge lclk
//      so verified functional behaviors record non-zero counts without
//      inflating denominator semantics into multi-cycle dwell times.
// -------------------------------------------------------------------------
// JSON export
// -------------------------------------------------------------------------
// When the testbench is finished it calls the export_json task with a file
// path.  The task opens the file, serialises all counter arrays and scalar
// counters into a human-readable JSON object, and closes the file.  This
// JSON can then be consumed by post-simulation scripts for coverage
// merging, regression tracking, or CI gating.
//
// -------------------------------------------------------------------------
// Parameters
// -------------------------------------------------------------------------
//   NSTATES (int unsigned, default = LT_NUM_STATES)
//       Width of the LTSM state bitmask.  Must be >= the largest state
//       encoding emitted by the LTSM under test.  Out-of-range state
//       values are silently discarded (guarded by an if-check).
//
// -------------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------------
//   lclk          – Main link clock (500 MHz for 4 GT/s). LTSM, RDI, event,
//                   and mailbox-delivered sideband packet counters sample on
//                   posedge lclk.
//   sbclk         – Sideband clock (800 MHz). The monitor retains it for the
//                   testbench interface, but packet coverage uses the
//                   coherent lclk-domain mailbox outputs.
//   lreset_n      – Active-low reset. State coverage sampling is gated by
//                   lreset_n to avoid recording the reset-state artefact at
//                   time zero.
//
//   Per-die observables (suffix _0 for Die 0, _1 for Die 1):
//     ltsm_state_N      [7:0]  – Current LTSM state encoding.
//     sbinit_phase_N     [1:0]  – Private SBINIT phase for ordered evidence.
//     link_active_N             – Asserted when the die's RDI is ACTIVE.
//     sb_rx_opcode_N    [4:0]  – Received sideband packet opcode.
//     sb_rx_msgcode_N   [7:0]  – Received sideband message code.
//     sb_rx_msgsubcode_N[7:0]  – Received sideband message subcode.
//     sb_rx_pkt_vld_N           – Pulse indicating a valid SB packet RX.
//     rdi_state_sts_N   [3:0]  – RDI pl_state_sts from the PHY layer.
//
//   Directional / functional observables:
//     xfer_done_0               – Streaming block completed on Die 0.
//     xfer_done_1               – Streaming block completed on Die 1.
//     stall_4phase              – 4-phase stall handshake observed.
//     width_degrade             – x8 width degrade configuration seen.
//     lane_reversal             – Byte-lane reversal detected by mapper.
//     raw_mode_adv              – Raw Mode bit set in advertised caps.
//     crc_off_adv               – No-CRC advertisement observed.
//
//   Phase F event observables:
//     param_roles               – PARAM request and response roles exercised.
//     transaction_classes       – Phase B training and Phase C management seen.
//     arbitration               – Transmit priority arbitration observed.
//     fatal_causes              – Fatal error trigger event observed.
//     trainerror                – TRAINERROR state or exchange observed.
//     linkreset                 – LinkReset recovery exchange observed.
//     disabled                  – Disabled recovery exchange observed.
//     pmnak                     – PMNAK status observed upon unsupported PM req.
//     active_entry              – Active Entry sequence completion observed.
//     pre_active_block          – Pre-Active user-data blocking verified.
//     scrambling                – Active user-data scrambler/descrambler active.
//     framing_fault             – Mainband framing boundary fault observed.
// -------------------------------------------------------------------------
// Block diagram – signal tapping
// -------------------------------------------------------------------------
//
//   +================+                       +================+
//   |    Die 0       |   UCIe Link (x16)     |    Die 1       |
//   |                |<=====================>|                |
//   |  +---------+   |    SB (800 MHz)       |   +---------+  |
//   |  |  LTSM   |---|---+               +---|---|  LTSM   |  |
//   |  +---------+   |   |               |   |   +---------+  |
//   |  +---------+   |   |               |   |   +---------+  |
//   |  |  RDI    |---|---|---+       +----|---|---|  RDI    |  |
//   |  +---------+   |   |   |       |   |   |   +---------+  |
//   |  +---------+   |   |   |       |   |   |   +---------+  |
//   |  |  SB RX  |---|---|---|---+   |   |---|---|  SB RX  |  |
//   |  +---------+   |   |   |   |   |   |   |   +---------+  |
//   +================+   |   |   |   |   |   +================+
//                        |   |   |   |   |
//                        v   v   v   v   v
//                   +----------------------------+
//                   |       cov_monitor           |
//                   |                             |
//                   |  ltsm_state_hits [NSTATES]  |
//                   |  sb_opcode_hits  [0:31]     |
//                   |  sb_msgcode_hits [0:255]    |
//                   |  rdi_state_hits  [0:15]     |
//                   |  c_rdi_active_entry_done    |
//                   |  c_stall_4phase_done        |
//                   |  c_width_degrade_done       |
//                   |  c_lane_reversal_detected   |
//                   |  c_raw_transfer_fwd/rev     |
//                   |  c_raw_mode_adv             |
//                   |  c_crc_off_adv              |
//                   |  c_param_roles              |
//                   |  c_transaction_classes      |
//                   |  c_arbitration              |
//                   |  c_fatal_causes             |
//                   |  c_trainerror               |
//                   |  c_linkreset                |
//                   |  c_disabled                 |
//                   |  c_pmnak                    |
//                   |  c_active_entry             |
//                   |  c_pre_active_block         |
//                   |  c_scrambling               |
//                   |  c_framing_fault            |
//                   +----------------------------+
//                               |
//                               v
//                        export_json(path)
//                               |
//                               v
//                       coverage.json
//
// -------------------------------------------------------------------------
// Revision History
// -------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2025-XX-XX  -           Initial creation.
//   0.0.2 2026-09-23  -           Documentation: expand header, add
//                                 per-block comments.
//   0.0.3 2026-09-23  -           Documentation: correct citations. 6.1.1 is
//                                 Packet Types, so the msgcode reference no
//                                 longer claims a "Message Codes" section.
//                                 8.2.3.2 is the pl_clk_req/lp_clk_ack
//                                 handshake, not the RDI Active state, so the
//                                 link_active events now cite 8.1.5 (RDI
//                                 State Status Machine) and 4.5.
//   0.0.4 2026-09-23  -           Documentation: correct the Section 8.1
//                                 title to Raw Die-to-Die Interface (RDI).
//   0.0.5 2026-09-23  -           Req.3: sample mailbox-delivered sideband
//                                 packet fields and valid strobes on lclk.
//   0.0.6 2026-09-23  -           Req.3: remove stale sbclk-domain coverage
//                                 sampling text from the port documentation.
//   0.0.7 2026-09-24  -           Add per-die SBINIT phase/order and received
//                                 message-subcode evidence.
//   0.0.8 2026-09-25  -           Phase F: add explicit event inputs and
//                                 counters for Phase F contract keys
//                                 (param_roles, transaction_classes, arbitration,
//                                 fatal_causes, trainerror, linkreset, disabled,
//                                 pmnak, active_entry, pre_active_block,
//                                 scrambling, framing_fault); implement robust
//                                 one-shot lclk sampling and export all keys
//                                 to coverage JSON.
// ============================================================================
`ifndef CovMonitor_SV
`define CovMonitor_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module cov_monitor #(
  parameter int unsigned NSTATES = LT_NUM_STATES
) (
  input logic        lclk,
  input logic        lreset_n,
  input logic        sbclk,

  // Die 0 observables
  input logic [7:0]  ltsm_state_0,
  input logic [1:0]  sbinit_phase_0,
  input logic        link_active_0,
  input logic [4:0]  sb_rx_opcode_0,
  input logic [7:0]  sb_rx_msgcode_0,
  input logic [7:0]  sb_rx_msgsubcode_0,
  input logic        sb_rx_pkt_vld_0,
  input logic [3:0]  rdi_state_sts_0,

  // Die 1 observables
  input logic [7:0]  ltsm_state_1,
  input logic [1:0]  sbinit_phase_1,
  input logic        link_active_1,
  input logic [4:0]  sb_rx_opcode_1,
  input logic [7:0]  sb_rx_msgcode_1,
  input logic [7:0]  sb_rx_msgsubcode_1,
  input logic        sb_rx_pkt_vld_1,
  input logic [3:0]  rdi_state_sts_1,

  // Directional data observables
  input logic        xfer_done_0,   // streaming block completed on die 0
  input logic        xfer_done_1,   // streaming block completed on die 1
  input logic        stall_4phase,  // req -> ack -> data-stop -> deassert
  input logic        width_degrade, // lnk_cfg observed x8
  input logic        lane_reversal, // byte reversal observed on the mapper
  input logic        raw_mode_adv,  // Raw_Mode bit seen in advertised caps
  input logic        crc_off_adv,   // no-CRC advertisement seen

  // Phase F event observables (spec 4.4.1, 4.5.3, 6.1.3, 8.1.5, 8.1.6; PLAN.md 15.7, 15.9)
  input logic        param_roles,         // PARAM request and response roles seen
  input logic        transaction_classes, // Phase B and Phase C transaction classes seen
  input logic        arbitration,         // Response-over-request arbitration seen
  input logic        fatal_causes,        // Fatal error trigger event seen
  input logic        trainerror,          // TRAINERROR state/exchange seen
  input logic        linkreset,           // LinkReset recovery exchange seen
  input logic        disabled,            // Disabled recovery exchange seen
  input logic        pmnak,               // PMNAK status/response seen
  input logic        active_entry,        // Active Entry handshake completion seen
  input logic        pre_active_block,    // Pre-Active user-data blocking verified
  input logic        scrambling,          // Active user-data scrambling/descrambling seen
  input logic        framing_fault        // Mainband framing boundary fault seen
);

  // ------------------------------------------------------- counters
  logic [NSTATES-1:0] ltsm_state_hits;
  logic [3:0] sbinit_phase_hits_0;
  logic [3:0] sbinit_phase_hits_1;
  logic [1:0] sbinit_phase_order_0;
  logic [1:0] sbinit_phase_order_1;
  logic [31:0] sb_opcode_hits      [0:31];
  logic [31:0] sb_msgcode_hits     [0:255];
  logic [31:0] sb_msgsubcode_hits_0[0:255];
  logic [31:0] sb_msgsubcode_hits_1[0:255];
  logic [31:0] rdi_state_hits      [0:15];

  logic [31:0] c_rdi_active_entry_done;
  logic [31:0] c_stall_4phase_done;
  logic [31:0] c_width_degrade_done;
  logic [31:0] c_lane_reversal_detected;
  logic [31:0] c_raw_transfer_fwd;
  logic [31:0] c_raw_transfer_rev;
  logic [31:0] c_raw_mode_adv;
  logic [31:0] c_crc_off_adv;
  logic [31:0] c_param_roles;
  logic [31:0] c_transaction_classes;
  logic [31:0] c_arbitration;
  logic [31:0] c_fatal_causes;
  logic [31:0] c_trainerror;
  logic [31:0] c_linkreset;
  logic [31:0] c_disabled;
  logic [31:0] c_pmnak;
  logic [31:0] c_active_entry;
  logic [31:0] c_pre_active_block;
  logic [31:0] c_scrambling;
  logic [31:0] c_framing_fault;

  logic        param_roles_q;
  logic        transaction_classes_q;
  logic        arbitration_q;
  logic        fatal_causes_q;
  logic        trainerror_q;
  logic        linkreset_q;
  logic        disabled_q;
  logic        pmnak_q;
  logic        active_entry_q;
  logic        pre_active_block_q;
  logic        scrambling_q;
  logic        framing_fault_q;
  initial begin
    ltsm_state_hits      = '0;
    sbinit_phase_hits_0  = '0;
    sbinit_phase_hits_1  = '0;
    sbinit_phase_order_0 = 2'd0;
    sbinit_phase_order_1 = 2'd0;
    for (int i = 0; i < 32; i = i + 1)
      sb_opcode_hits[i] = 32'd0;
    for (int i = 0; i < 256; i = i + 1) begin
      sb_msgcode_hits[i]      = 32'd0;
      sb_msgsubcode_hits_0[i] = 32'd0;
      sb_msgsubcode_hits_1[i] = 32'd0;
    end
    for (int i = 0; i < 16; i = i + 1)
      rdi_state_hits[i] = 32'd0;
    c_rdi_active_entry_done  = 32'd0;
    c_stall_4phase_done      = 32'd0;
    c_width_degrade_done     = 32'd0;
    c_lane_reversal_detected = 32'd0;
    c_raw_transfer_fwd       = 32'd0;
    c_raw_transfer_rev       = 32'd0;
    c_raw_mode_adv           = 32'd0;
    c_crc_off_adv            = 32'd0;
    c_param_roles            = 32'd0;
    c_transaction_classes    = 32'd0;
    c_arbitration            = 32'd0;
    c_fatal_causes           = 32'd0;
    c_trainerror             = 32'd0;
    c_linkreset              = 32'd0;
    c_disabled               = 32'd0;
    c_pmnak                  = 32'd0;
    c_active_entry           = 32'd0;
    c_pre_active_block       = 32'd0;
    c_scrambling             = 32'd0;
    c_framing_fault          = 32'd0;
    param_roles_q            = 1'b0;
    transaction_classes_q    = 1'b0;
    arbitration_q            = 1'b0;
    fatal_causes_q           = 1'b0;
    trainerror_q             = 1'b0;
    linkreset_q              = 1'b0;
    disabled_q               = 1'b0;
    pmnak_q                  = 1'b0;
    active_entry_q           = 1'b0;
    pre_active_block_q       = 1'b0;
    scrambling_q             = 1'b0;
    framing_fault_q          = 1'b0;
  end

// -----------------------------------------------------------------------
// LTSM & RDI State Coverage Sampling
// -----------------------------------------------------------------------
// This always block runs on the positive edge of lclk (500 MHz) and is
// responsible for recording which Link Training State Machine (LTSM)
// states and which RDI (Raw Die-to-Die Interface) states have been visited
// during the simulation.
//
// LTSM state coverage:
//   Both dies' ltsm_state ports carry the 8-bit state encoding defined
//   in ucie_pkg (e.g., LT_RESET = 8'h00, LT_SBINIT = 8'h01, etc.).
//   If the state value is within the NSTATES range, the corresponding
//   bit in the ltsm_state_hits bitmask is set to 1'b1.  Because this
//   is a one-hot "has been visited" flag (not a counter), re-visiting
//   a state simply re-writes the same 1'b1 — no overflow is possible.
//   Spec ref: Section 4.5.3 - Link Training State Machine.
//
// RDI state coverage:
//   The 4-bit rdi_state_sts from each die (Table 114 encoding) directly
//   indexes a 16-entry array.  Again, a hit flag of 1'b1 is written.
//   Spec ref: Section 8.1 - Raw Die-to-Die Interface (RDI), Table 114.
//
// Reset gating:
//   Sampling is gated by lreset_n so that the all-zero reset state
//   present before the testbench de-asserts reset is not spuriously
//   recorded as a "visited" state.
//
// Sampled on the lclk edge so a single-cycle state still lands in the
// histogram.
  always @(posedge lclk) begin
    if (lreset_n) begin
      if (ltsm_state_0 < NSTATES) ltsm_state_hits[ltsm_state_0] <= 1'b1;
      if (ltsm_state_1 < NSTATES) ltsm_state_hits[ltsm_state_1] <= 1'b1;
      rdi_state_hits[rdi_state_sts_0] <= 1'b1;
      rdi_state_hits[rdi_state_sts_1] <= 1'b1;

      if (ltsm_state_0 == LT_SBINIT) begin
        sbinit_phase_hits_0[sbinit_phase_0] <= 1'b1;
        case (sbinit_phase_order_0)
          2'd0: if (sbinit_phase_0 == 2'd0) sbinit_phase_order_0 <= 2'd1;
          2'd1: if (sbinit_phase_0 == 2'd2) sbinit_phase_order_0 <= 2'd2;
          2'd2: if (sbinit_phase_0 == 2'd3) sbinit_phase_order_0 <= 2'd3;
          default: sbinit_phase_order_0 <= sbinit_phase_order_0;
        endcase
      end
      if (ltsm_state_1 == LT_SBINIT) begin
        sbinit_phase_hits_1[sbinit_phase_1] <= 1'b1;
        case (sbinit_phase_order_1)
          2'd0: if (sbinit_phase_1 == 2'd0) sbinit_phase_order_1 <= 2'd1;
          2'd1: if (sbinit_phase_1 == 2'd2) sbinit_phase_order_1 <= 2'd2;
          2'd2: if (sbinit_phase_1 == 2'd3) sbinit_phase_order_1 <= 2'd3;
          default: sbinit_phase_order_1 <= sbinit_phase_order_1;
        endcase
      end
    end
  end

// -----------------------------------------------------------------------
// Sideband Opcode & Message-Code Coverage Sampling
// -----------------------------------------------------------------------
// This always block runs on the positive edge of lclk (500 MHz). The logical
// PHY delivers each complete sideband packet through an sbclk-to-lclk mailbox,
// so sb_rx_pkt_vld_N and its fields are coherent in this domain.
//   - sb_rx_opcode_N  [4:0] : 5-bit opcode  → indexes sb_opcode_hits[0:31]
//   - sb_rx_msgcode_N [7:0] : 8-bit msgcode → indexes sb_msgcode_hits[0:255]
//
// Both arrays are 32-bit saturating-style counters (practical saturation
// is unreachable in any reasonable simulation length).  Monitoring RX on
// *both* dies means we observe traffic in both directions of the sideband
// crossing — Die 0→Die 1 packets appear on sb_rx_pkt_vld_1 and vice
// versa — giving full bidirectional opcode/msgcode coverage.
//
// Spec ref: Section 6.1.1 - Packet Types (5-bit opcode field and 8-bit
//           msgcode field).
  always @(posedge lclk) begin
    if (sb_rx_pkt_vld_0) begin
      sb_opcode_hits[sb_rx_opcode_0]   <= sb_opcode_hits[sb_rx_opcode_0]   + 1'b1;
      sb_msgcode_hits[sb_rx_msgcode_0] <= sb_msgcode_hits[sb_rx_msgcode_0] + 1'b1;
      sb_msgsubcode_hits_0[sb_rx_msgsubcode_0] <=
        sb_msgsubcode_hits_0[sb_rx_msgsubcode_0] + 1'b1;
    end
    if (sb_rx_pkt_vld_1) begin
      sb_opcode_hits[sb_rx_opcode_1]   <= sb_opcode_hits[sb_rx_opcode_1]   + 1'b1;
      sb_msgcode_hits[sb_rx_msgcode_1] <= sb_msgcode_hits[sb_rx_msgcode_1] + 1'b1;
      sb_msgsubcode_hits_1[sb_rx_msgsubcode_1] <=
        sb_msgsubcode_hits_1[sb_rx_msgsubcode_1] + 1'b1;
    end
  end

// -----------------------------------------------------------------------
// Functional Event Coverage Counters
// -----------------------------------------------------------------------
// This always block increments dedicated 32-bit counters for a set of
// interesting functional events observed on the lclk domain.  Each event
// is independently guarded by its own qualification signal.
//
//   c_rdi_active_entry_done  – Both dies simultaneously in RDI Active;
//                              counts every lclk cycle in that state.
//   c_stall_4phase_done      – 4-phase stall handshake completion.
//   c_width_degrade_done     – Width degradation to x8 observed.
//   c_lane_reversal_detected – Byte-lane reversal detected in mapper.
//   c_raw_transfer_fwd       – Streaming block transfer completed on
//                              Die 0 (forward direction).
//   c_raw_transfer_rev       – Streaming block transfer completed on
//                              Die 1 (reverse direction).
//   c_raw_mode_adv           – Raw Mode bit asserted in advertised
//                              capabilities.
//   c_crc_off_adv            – No-CRC advertisement observed.
//
// These counters are never reset during a simulation run; they accumulate
// monotonically and are exported to JSON at the end.
//
// Spec ref: Section 8.1.5 - RDI State Status Machine (link_active events),
//           Section 4.5 - Link Initialization and Training (events).
  always @(posedge lclk) begin
    if (link_active_0 && link_active_1)
      c_rdi_active_entry_done <= c_rdi_active_entry_done + 1'b1;
    if (stall_4phase)      c_stall_4phase_done      <= c_stall_4phase_done     + 1'b1;
    if (width_degrade)     c_width_degrade_done     <= c_width_degrade_done    + 1'b1;
    if (lane_reversal)     c_lane_reversal_detected <= c_lane_reversal_detected+ 1'b1;
    if (xfer_done_0)       c_raw_transfer_fwd       <= c_raw_transfer_fwd      + 1'b1;
    if (xfer_done_1)       c_raw_transfer_rev       <= c_raw_transfer_rev      + 1'b1;
    if (raw_mode_adv)      c_raw_mode_adv           <= c_raw_mode_adv          + 1'b1;
    if (crc_off_adv)       c_crc_off_adv            <= c_crc_off_adv           + 1'b1;
  end

// -----------------------------------------------------------------------
// Phase F Functional Event Coverage Sampling
// -----------------------------------------------------------------------
// This always block runs on the positive edge of lclk (500 MHz) and samples
// the Phase F event observables using robust one-shot (rising-edge) behavior.
// Edge detection prevents level-sensitive signals (such as sticky recovery
// evidence or persistent holds) from incrementing continuously on every
// clock cycle, ensuring each verified functional event registers as a
// non-zero count without inflating denominator semantics.
//
// Spec ref: UCIe 1.0 Section 4.4.1 (Scrambling), Section 4.5.3 (LTSM),
//           Section 4.5.3.3.1 (MBINIT.PARAM), Section 4.5.3.8 (TRAINERROR),
//           Section 6.1.3 (Arbitration), Section 8.1.5 (RDI States & PMNAK),
//           Section 8.1.6 (Active Entry & Gating);
//           PLAN.md Sections 15.3, 15.4, 15.6, 15.7, 15.9 Phase F.
// -----------------------------------------------------------------------
  always @(posedge lclk) begin
    param_roles_q         <= param_roles;
    transaction_classes_q <= transaction_classes;
    arbitration_q         <= arbitration;
    fatal_causes_q        <= fatal_causes;
    trainerror_q          <= trainerror;
    linkreset_q           <= linkreset;
    disabled_q            <= disabled;
    pmnak_q               <= pmnak;
    active_entry_q        <= active_entry;
    pre_active_block_q    <= pre_active_block;
    scrambling_q          <= scrambling;
    framing_fault_q       <= framing_fault;

    if (param_roles && !param_roles_q)
      c_param_roles <= c_param_roles + 1'b1;
    if (transaction_classes && !transaction_classes_q)
      c_transaction_classes <= c_transaction_classes + 1'b1;
    if (arbitration && !arbitration_q)
      c_arbitration <= c_arbitration + 1'b1;
    if (fatal_causes && !fatal_causes_q)
      c_fatal_causes <= c_fatal_causes + 1'b1;
    if (trainerror && !trainerror_q)
      c_trainerror <= c_trainerror + 1'b1;
    if (linkreset && !linkreset_q)
      c_linkreset <= c_linkreset + 1'b1;
    if (disabled && !disabled_q)
      c_disabled <= c_disabled + 1'b1;
    if (pmnak && !pmnak_q)
      c_pmnak <= c_pmnak + 1'b1;
    if (active_entry && !active_entry_q)
      c_active_entry <= c_active_entry + 1'b1;
    if (pre_active_block && !pre_active_block_q)
      c_pre_active_block <= c_pre_active_block + 1'b1;
    if (scrambling && !scrambling_q)
      c_scrambling <= c_scrambling + 1'b1;
    if (framing_fault && !framing_fault_q)
      c_framing_fault <= c_framing_fault + 1'b1;
  end

  // ------------------------------------------------------- JSON export
  // Written once, when the testbench decides to stop.
  task export_json;
    input [1024*8-1:0] path;
    integer fd;
    int i;
    begin
      fd = $fopen(path, "w");
      if (fd == 0) begin
        $display("cov_monitor: cannot open %0s", path);
        $finish;
      end
      $fwrite(fd, "{\n");
      $fwrite(fd, "  \"ltsm_state_hits\": [");
      for (i = 0; i < NSTATES; i = i + 1) begin
        $fwrite(fd, "%0d", ltsm_state_hits[i]);
        if (i != NSTATES-1) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sbinit_phase_hits_0\": [");
      for (i = 0; i < 4; i = i + 1) begin
        $fwrite(fd, "%0d", sbinit_phase_hits_0[i]);
        if (i != 3) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sbinit_phase_hits_1\": [");
      for (i = 0; i < 4; i = i + 1) begin
        $fwrite(fd, "%0d", sbinit_phase_hits_1[i]);
        if (i != 3) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sbinit_phase_order_0\": %0d,\n",
              sbinit_phase_order_0);
      $fwrite(fd, "  \"sbinit_phase_order_1\": %0d,\n",
              sbinit_phase_order_1);
      $fwrite(fd, "  \"sb_opcode_hits\": [");
      for (i = 0; i < 32; i = i + 1) begin
        $fwrite(fd, "%0d", sb_opcode_hits[i]);
        if (i != 31) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sb_msgcode_hits\": [");
      for (i = 0; i < 256; i = i + 1) begin
        $fwrite(fd, "%0d", sb_msgcode_hits[i]);
        if (i != 255) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sb_msgsubcode_hits_0\": [");
      for (i = 0; i < 256; i = i + 1) begin
        $fwrite(fd, "%0d", sb_msgsubcode_hits_0[i]);
        if (i != 255) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"sb_msgsubcode_hits_1\": [");
      for (i = 0; i < 256; i = i + 1) begin
        $fwrite(fd, "%0d", sb_msgsubcode_hits_1[i]);
        if (i != 255) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"rdi_state_hits\": [");
      for (i = 0; i < 16; i = i + 1) begin
        $fwrite(fd, "%0d", rdi_state_hits[i]);
        if (i != 15) $fwrite(fd, ", ");
      end
      $fwrite(fd, "],\n");
      $fwrite(fd, "  \"rdi_active_entry_done\": %0d,\n", c_rdi_active_entry_done);
      $fwrite(fd, "  \"stall_4phase_done\": %0d,\n", c_stall_4phase_done);
      $fwrite(fd, "  \"width_degrade_done\": %0d,\n", c_width_degrade_done);
      $fwrite(fd, "  \"lane_reversal_detected\": %0d,\n", c_lane_reversal_detected);
      $fwrite(fd, "  \"raw_transfer_fwd\": %0d,\n", c_raw_transfer_fwd);
      $fwrite(fd, "  \"raw_transfer_rev\": %0d,\n", c_raw_transfer_rev);
      $fwrite(fd, "  \"raw_mode_adv\": %0d,\n", c_raw_mode_adv);
      $fwrite(fd, "  \"crc_off_adv\": %0d,\n", c_crc_off_adv);
      $fwrite(fd, "  \"param_roles\": %0d,\n", c_param_roles);
      $fwrite(fd, "  \"param_roles_done\": %0d,\n", c_param_roles);
      $fwrite(fd, "  \"transaction_classes\": %0d,\n", c_transaction_classes);
      $fwrite(fd, "  \"transaction_classes_done\": %0d,\n", c_transaction_classes);
      $fwrite(fd, "  \"arbitration\": %0d,\n", c_arbitration);
      $fwrite(fd, "  \"arbitration_done\": %0d,\n", c_arbitration);
      $fwrite(fd, "  \"fatal_causes\": %0d,\n", c_fatal_causes);
      $fwrite(fd, "  \"fatal_causes_done\": %0d,\n", c_fatal_causes);
      $fwrite(fd, "  \"trainerror\": %0d,\n", c_trainerror);
      $fwrite(fd, "  \"trainerror_done\": %0d,\n", c_trainerror);
      $fwrite(fd, "  \"linkreset\": %0d,\n", c_linkreset);
      $fwrite(fd, "  \"linkreset_done\": %0d,\n", c_linkreset);
      $fwrite(fd, "  \"disabled\": %0d,\n", c_disabled);
      $fwrite(fd, "  \"disabled_done\": %0d,\n", c_disabled);
      $fwrite(fd, "  \"pmnak\": %0d,\n", c_pmnak);
      $fwrite(fd, "  \"pmnak_done\": %0d,\n", c_pmnak);
      $fwrite(fd, "  \"active_entry\": %0d,\n", c_active_entry);
      $fwrite(fd, "  \"active_entry_done\": %0d,\n", c_active_entry);
      $fwrite(fd, "  \"pre_active_block\": %0d,\n", c_pre_active_block);
      $fwrite(fd, "  \"pre_active_block_done\": %0d,\n", c_pre_active_block);
      $fwrite(fd, "  \"scrambling\": %0d,\n", c_scrambling);
      $fwrite(fd, "  \"scrambling_done\": %0d,\n", c_scrambling);
      $fwrite(fd, "  \"framing_fault\": %0d,\n", c_framing_fault);
      $fwrite(fd, "  \"framing_fault_done\": %0d\n", c_framing_fault);
      $fwrite(fd, "}\n");
      $fclose(fd);
    end
  endtask

endmodule

`endif

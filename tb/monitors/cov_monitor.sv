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
// The monitor observes three broad categories of activity:
//
//   1. LTSM state histogram  – Records which Link Training State Machine
//      states have been visited by either die.  A one-hot bitmask
//      (ltsm_state_hits) is indexed by the 8-bit state encoding from
//      ucie_pkg.  The NSTATES parameter (default LT_NUM_STATES) sets the
//      upper bound so out-of-range indices are ignored.
//      Spec ref: Section 4.5.3 - Link Training State Machine.
//
//   2. Sideband opcode & msgcode histograms – On every valid sideband
//      packet reception (sb_rx_pkt_vld asserted), the 5-bit opcode and
//      8-bit message code are used to index 32-bit counter arrays.
//      Because both dies' RX paths are monitored, traffic in both
//      directions of the sideband crossing is captured.
//      Spec ref: Section 6.1.1 - Packet Types (opcode encoding),
//                Section 6.1.1 - Message Codes (msgcode encoding).
//
//   3. RDI state histogram – The 4-bit rdi_state_sts from each die is
//      used to index a 16-entry counter array, recording which RDI states
//      have been entered.
//      Spec ref: Section 8.1 - Raw D2D Interface, Table 114.
//
//   4. Functional event counters – Miscellaneous signals of interest
//      (transfer completion, 4-phase stalls, width degradation, lane
//      reversal, Raw Mode advertisement, CRC-off advertisement) are each
//      counted in a dedicated 32-bit register on the lclk edge.
//      Spec ref: Section 4.5 - Link Training Overview (events),
//                Section 8.2.3.2 - RDI Active State.
//
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
//   lclk          – Main link clock (500 MHz for 4 GT/s).  LTSM, RDI,
//                   and event counters are sampled on posedge lclk.
//   sbclk         – Sideband clock (800 MHz).  Sideband opcode/msgcode
//                   counters are sampled on posedge sbclk.
//   lreset_n      – Active-low reset.  State-coverage sampling is gated
//                   by lreset_n to avoid recording the reset-state
//                   artefact at time zero.
//
//   Per-die observables (suffix _0 for Die 0, _1 for Die 1):
//     ltsm_state_N      [7:0]  – Current LTSM state encoding.
//     link_active_N             – Asserted when the die's RDI is ACTIVE.
//     sb_rx_opcode_N    [4:0]  – Received sideband packet opcode.
//     sb_rx_msgcode_N   [7:0]  – Received sideband message code.
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
//
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
  input logic        link_active_0,
  input logic [4:0]  sb_rx_opcode_0,
  input logic [7:0]  sb_rx_msgcode_0,
  input logic        sb_rx_pkt_vld_0,
  input logic [3:0]  rdi_state_sts_0,

  // Die 1 observables
  input logic [7:0]  ltsm_state_1,
  input logic        link_active_1,
  input logic [4:0]  sb_rx_opcode_1,
  input logic [7:0]  sb_rx_msgcode_1,
  input logic        sb_rx_pkt_vld_1,
  input logic [3:0]  rdi_state_sts_1,

  // Directional data observables
  input logic        xfer_done_0,   // streaming block completed on die 0
  input logic        xfer_done_1,   // streaming block completed on die 1
  input logic        stall_4phase,  // req -> ack -> data-stop -> deassert
  input logic        width_degrade, // lnk_cfg observed x8
  input logic        lane_reversal, // byte reversal observed on the mapper
  input logic        raw_mode_adv,  // Raw_Mode bit seen in advertised caps
  input logic        crc_off_adv    // no-CRC advertisement seen
);

  // ------------------------------------------------------- counters
  logic [NSTATES-1:0] ltsm_state_hits;
  logic [31:0] sb_opcode_hits  [0:31];
  logic [31:0] sb_msgcode_hits [0:255];
  logic [31:0] rdi_state_hits  [0:15];

  logic [31:0] c_rdi_active_entry_done;
  logic [31:0] c_stall_4phase_done;
  logic [31:0] c_width_degrade_done;
  logic [31:0] c_lane_reversal_detected;
  logic [31:0] c_raw_transfer_fwd;
  logic [31:0] c_raw_transfer_rev;
  logic [31:0] c_raw_mode_adv;
  logic [31:0] c_crc_off_adv;

  initial begin
    ltsm_state_hits = '0;
    for (int i = 0; i < 32;  i = i + 1) sb_opcode_hits[i]  = 32'd0;
    for (int i = 0; i < 256; i = i + 1) sb_msgcode_hits[i] = 32'd0;
    for (int i = 0; i < 16;  i = i + 1) rdi_state_hits[i]  = 32'd0;
    c_rdi_active_entry_done  = 32'd0;
    c_stall_4phase_done      = 32'd0;
    c_width_degrade_done     = 32'd0;
    c_lane_reversal_detected = 32'd0;
    c_raw_transfer_fwd       = 32'd0;
    c_raw_transfer_rev       = 32'd0;
    c_raw_mode_adv           = 32'd0;
    c_crc_off_adv            = 32'd0;
  end

// -----------------------------------------------------------------------
// LTSM & RDI State Coverage Sampling
// -----------------------------------------------------------------------
// This always block runs on the positive edge of lclk (500 MHz) and is
// responsible for recording which Link Training State Machine (LTSM)
// states and which RDI (Raw D2D Interface) states have been visited
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
//   Spec ref: Section 8.1 - Raw D2D Interface, Table 114.
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
    end
  end

// -----------------------------------------------------------------------
// Sideband Opcode & Message-Code Coverage Sampling
// -----------------------------------------------------------------------
// This always block runs on the positive edge of sbclk (800 MHz) and
// captures every valid sideband packet received by either die.
//
// When sb_rx_pkt_vld_N is asserted the corresponding die has latched a
// complete 64-bit sideband packet.  The monitor extracts:
//   - sb_rx_opcode_N  [4:0] : 5-bit opcode  → indexes sb_opcode_hits[0:31]
//   - sb_rx_msgcode_N [7:0] : 8-bit msgcode → indexes sb_msgcode_hits[0:255]
//
// Both arrays are 32-bit saturating-style counters (practical saturation
// is unreachable in any reasonable simulation length).  Monitoring RX on
// *both* dies means we observe traffic in both directions of the sideband
// crossing — Die 0→Die 1 packets appear on sb_rx_pkt_vld_1 and vice
// versa — giving full bidirectional opcode/msgcode coverage.
//
// Spec ref: Section 6.1.1 - Packet Types (5-bit opcode field),
//           Section 6.1.1 - Message Codes (8-bit msgcode field).
  always @(posedge sbclk) begin
    if (sb_rx_pkt_vld_0) begin
      sb_opcode_hits[sb_rx_opcode_0]   <= sb_opcode_hits[sb_rx_opcode_0]   + 1'b1;
      sb_msgcode_hits[sb_rx_msgcode_0] <= sb_msgcode_hits[sb_rx_msgcode_0] + 1'b1;
    end
    if (sb_rx_pkt_vld_1) begin
      sb_opcode_hits[sb_rx_opcode_1]   <= sb_opcode_hits[sb_rx_opcode_1]   + 1'b1;
      sb_msgcode_hits[sb_rx_msgcode_1] <= sb_msgcode_hits[sb_rx_msgcode_1] + 1'b1;
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
// Spec ref: Section 8.2.3.2 - RDI Active State (link_active events),
//           Section 4.5 - Link Training Overview (functional events).
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
      $fwrite(fd, "  \"crc_off_adv\": %0d\n", c_crc_off_adv);
      $fwrite(fd, "}\n");
      $fclose(fd);
    end
  endtask

endmodule

`endif

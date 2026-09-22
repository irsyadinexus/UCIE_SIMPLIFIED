// UCIe 1.0 Simplified Endpoint - coverage monitor.
//
// Icarus Verilog 12.0 has no covergroup support, so coverage is a set of
// explicit counters. The monitor samples the two-die loopback and writes the
// accumulated counts to a JSON file at $finish.
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

  // ------------------------------------------------------- state coverage
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

  // Sideband coverage on the receive side of each die: both directions of the
  // crossing are observable this way.
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

  // ------------------------------------------------------- event coverage
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

// ============================================================================
// File        : sb_init_raw.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : SBINIT raw waveform primitive for the Standard Package.
//
// This module owns only sbclk-rate waveform generation and candidate sampling.
// The LTSM owns all SBINIT phases, retries, timers, match streaks, and state
// transitions in lclk. logical_phy owns the event mailboxes that transfer the
// raw results between clock domains.
//
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-09-24  -           Extract raw waveform primitive from
//                                    logical_phy. Preserve LTSM policy and
//                                    logical_phy CDC ownership.
// ============================================================================
`ifndef SbInitRaw_SV
`define SbInitRaw_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module sb_init_raw (
  input  logic          sbclk,
  input  logic          sbreset_n,
  input  logic          pattern_run_enable,
  input  logic          sbinit_raw_mode,
  input  logic [NC-1:0] sb_rx_data,
  input  logic          sb_rx_valid,
  input  logic          raw_rx_result_busy,
  output logic [NC-1:0] sb_tx_data,
  output logic          sb_tx_valid,
  output logic          raw_mode_active,
  output logic          raw_rx_low_sample,
  output logic          raw_tx_idle,
  output logic          raw_tx_iter_done,
  output logic          raw_rx_iter_vld,
  output logic          raw_rx_iter_match
);
  import ucie_pkg::*;

  typedef enum logic [1:0] {
    RAW_TX_IDLE   = 2'd0,
    RAW_TX_ACTIVE = 2'd1,
    RAW_TX_LOW    = 2'd2
  } raw_tx_state_t;

  typedef enum logic [1:0] {
    RAW_RX_WAIT_LOW    = 2'd0,
    RAW_RX_WAIT_ACTIVE = 2'd1,
    RAW_RX_ACTIVE      = 2'd2,
    RAW_RX_LOW         = 2'd3
  } raw_rx_state_t;

  raw_tx_state_t raw_tx_state_q;
  raw_rx_state_t raw_rx_state_q;
  logic [6:0] raw_tx_ui_q;
  logic [6:0] raw_rx_active_ui_q;
  logic [5:0] raw_rx_low_ui_q;
  logic       raw_rx_expected_q;
  logic       raw_rx_match_q;
  logic       raw_rx_force_mismatch_q;
  logic       pattern_run_meta_q;
  logic       pattern_run_sync_q;
  logic       raw_mode_meta_q;
  logic       raw_mode_sync_q;

  // Synchronize stable LTSM controls into sbclk. Raw mode resets asserted so
  // the packet codec stays quiescent until the LTSM selects packet mode.
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      pattern_run_meta_q <= 1'b0;
      pattern_run_sync_q <= 1'b0;
      raw_mode_meta_q    <= 1'b1;
      raw_mode_sync_q    <= 1'b1;
    end else begin
      pattern_run_meta_q <= pattern_run_enable;
      pattern_run_sync_q <= pattern_run_meta_q;
      raw_mode_meta_q    <= sbinit_raw_mode;
      raw_mode_sync_q    <= raw_mode_meta_q;
    end
  end

  // Repeat complete 64-UI active and 32-UI low primitives without a CDC
  // round trip. A falling run level stops only after the low boundary.
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      raw_tx_state_q    <= RAW_TX_IDLE;
      raw_tx_ui_q       <= 7'd0;
      raw_tx_iter_done  <= 1'b0;
    end else begin
      raw_tx_iter_done <= 1'b0;
      case (raw_tx_state_q)
        RAW_TX_IDLE: begin
          raw_tx_ui_q <= 7'd0;
          if (pattern_run_sync_q) raw_tx_state_q <= RAW_TX_ACTIVE;
        end
        RAW_TX_ACTIVE: begin
          if (raw_tx_ui_q == (SBINIT_PATTERN_UI - 1)) begin
            raw_tx_state_q <= RAW_TX_LOW;
            raw_tx_ui_q    <= 7'd0;
          end else begin
            raw_tx_ui_q <= raw_tx_ui_q + 1'b1;
          end
        end
        RAW_TX_LOW: begin
          if (raw_tx_ui_q == (SBINIT_LOW_UI - 1)) begin
            raw_tx_iter_done <= 1'b1;
            raw_tx_ui_q      <= 7'd0;
            if (pattern_run_sync_q) raw_tx_state_q <= RAW_TX_ACTIVE;
            else                    raw_tx_state_q <= RAW_TX_IDLE;
          end else begin
            raw_tx_ui_q <= raw_tx_ui_q + 1'b1;
          end
        end
        default: raw_tx_state_q <= RAW_TX_IDLE;
      endcase
    end
  end

  assign sb_tx_valid       = (raw_tx_state_q == RAW_TX_ACTIVE);
  assign sb_tx_data        = sb_tx_valid ? {NC{~raw_tx_ui_q[0]}} : {NC{1'b0}};
  assign raw_tx_idle       = (raw_tx_state_q == RAW_TX_IDLE);
  assign raw_mode_active   = raw_mode_sync_q;
  assign raw_rx_low_sample = !sb_rx_valid && (sb_rx_data == {NC{1'b0}});

  wire raw_rx_replicated = (sb_rx_data == {NC{sb_rx_data[0]}});

  // Parse only candidates that start after an observed low boundary. If the
  // result mailbox is busy, preserve a conservative mismatch before parsing
  // further candidates. This prevents a missing mismatch from creating a
  // false two-consecutive-match trigger in LTSM.
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      raw_rx_state_q          <= RAW_RX_WAIT_LOW;
      raw_rx_active_ui_q      <= 7'd0;
      raw_rx_low_ui_q         <= 6'd0;
      raw_rx_expected_q       <= 1'b0;
      raw_rx_match_q          <= 1'b0;
      raw_rx_iter_vld         <= 1'b0;
      raw_rx_iter_match       <= 1'b0;
      raw_rx_force_mismatch_q <= 1'b0;
    end else if (!raw_mode_sync_q) begin
      raw_rx_state_q          <= RAW_RX_WAIT_LOW;
      raw_rx_active_ui_q      <= 7'd0;
      raw_rx_low_ui_q         <= 6'd0;
      raw_rx_expected_q       <= 1'b0;
      raw_rx_match_q          <= 1'b0;
      raw_rx_iter_vld         <= 1'b0;
      raw_rx_iter_match       <= 1'b0;
      raw_rx_force_mismatch_q <= 1'b0;
    end else begin
      raw_rx_iter_vld <= 1'b0;
      if (raw_rx_force_mismatch_q) begin
        raw_rx_state_q     <= RAW_RX_WAIT_LOW;
        raw_rx_active_ui_q <= 7'd0;
        raw_rx_low_ui_q    <= 6'd0;
        raw_rx_match_q     <= 1'b0;
        if (!raw_rx_result_busy) begin
          raw_rx_iter_match       <= 1'b0;
          raw_rx_iter_vld         <= 1'b1;
          raw_rx_force_mismatch_q <= 1'b0;
        end
      end else begin
        case (raw_rx_state_q)
          RAW_RX_WAIT_LOW: begin
            if (raw_rx_low_sample) raw_rx_state_q <= RAW_RX_WAIT_ACTIVE;
          end
          RAW_RX_WAIT_ACTIVE: begin
            if (sb_rx_valid) begin
              raw_rx_state_q     <= RAW_RX_ACTIVE;
              raw_rx_active_ui_q <= 7'd1;
              raw_rx_expected_q  <= ~sb_rx_data[0];
              raw_rx_match_q     <= raw_rx_replicated;
            end
          end
          RAW_RX_ACTIVE: begin
            if (sb_rx_valid) begin
              if (!raw_rx_replicated || (sb_rx_data[0] != raw_rx_expected_q))
                raw_rx_match_q <= 1'b0;
              raw_rx_expected_q <= ~raw_rx_expected_q;
              if (raw_rx_active_ui_q == (SBINIT_PATTERN_UI - 1)) begin
                raw_rx_state_q  <= RAW_RX_LOW;
                raw_rx_low_ui_q <= 6'd0;
              end else begin
                raw_rx_active_ui_q <= raw_rx_active_ui_q + 1'b1;
              end
            end else begin
              raw_rx_state_q  <= RAW_RX_LOW;
              raw_rx_low_ui_q <= raw_rx_low_sample ? 6'd1 : 6'd0;
              raw_rx_match_q  <= 1'b0;
            end
          end
          RAW_RX_LOW: begin
            if (raw_rx_low_sample) begin
              if (raw_rx_low_ui_q == (SBINIT_LOW_UI - 1)) begin
                raw_rx_state_q  <= RAW_RX_WAIT_ACTIVE;
                raw_rx_low_ui_q <= 6'd0;
                if (!raw_rx_result_busy) begin
                  raw_rx_iter_match <= raw_rx_match_q;
                  raw_rx_iter_vld   <= 1'b1;
                end else begin
                  raw_rx_force_mismatch_q <= 1'b1;
                end
              end else begin
                raw_rx_low_ui_q <= raw_rx_low_ui_q + 1'b1;
              end
            end else if (sb_rx_valid) begin
              raw_rx_state_q <= RAW_RX_WAIT_LOW;
              if (!raw_rx_result_busy) begin
                raw_rx_iter_match <= 1'b0;
                raw_rx_iter_vld   <= 1'b1;
              end else begin
                raw_rx_force_mismatch_q <= 1'b1;
              end
            end else begin
              raw_rx_match_q  <= 1'b0;
              raw_rx_low_ui_q <= 6'd0;
            end
          end
          default: raw_rx_state_q <= RAW_RX_WAIT_LOW;
        endcase
      end
    end
  end
endmodule
`endif

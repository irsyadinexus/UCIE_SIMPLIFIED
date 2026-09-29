// ============================================================================
// File        : sb_init_raw.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : SBINIT raw waveform primitive for the Standard Package.
//
// This module owns only sbclk-rate waveform generation and candidate sampling
// over scalar physical pins (sb_tx_clk, sb_tx_data, sb_rx_clk, sb_rx_data).
// The LTSM owns all SBINIT phases, retries, timers, match streaks, and state
// transitions in lclk. logical_phy owns the event mailboxes that transfer the
// raw results between clock domains.
//
// Spec References:
//   - UCIe 1.0, Section 4.1.5: Sideband transmission (serial data and clock
//     pin pair, 64-bit serial packet, 32-bit low separation, 800 MT/s SDR).
//   - UCIe 1.0, Section 4.5.3.2: Sideband initialization (SBINIT) raw waveform
//     and iteration timing (64 active alternating UIs, 32 low UIs, 2-iteration
//     detection threshold, 4-iteration post-detection tail).
//   - UCIe 1.0, Section 5.13: Sideband signaling (800 MHz SDR, data edge-aligned
//     with strobe, negedge strobe sampling, parked clock/data low).
//   - UCIe 1.0, Section 6.1: Sideband protocol specification and timing.
//
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-09-24  -           Extract raw waveform primitive from
//                                    logical_phy. Preserve LTSM policy and
//                                    logical_phy CDC ownership.
//   v0.0.2  2026-09-28  -           Migrate to scalar physical pins sb_tx_clk /
//                                    sb_tx_data and sb_rx_clk / sb_rx_data per
//                                    UCIe 1.0 Sections 4.1.5, 4.5.3.2, 5.13, and
//                                    6.1. Add negedge sb_rx_clk sampling front-end
//                                    for 64-UI alternating data, missing-strobe
//                                    drift tolerance (>16 sbclk cycles) in sbclk,
//                                    and 32-UI low gap validation with parked
//                                    clock/data check.
// ============================================================================
`ifndef SbInitRaw_SV
`define SbInitRaw_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module sb_init_raw (
  input  logic        sbclk,
  input  logic        sbreset_n,
  input  logic        pattern_run_enable,
  input  logic        sbinit_raw_mode,
  input  logic        sb_rx_clk,
  input  logic        sb_rx_data,
  input  logic        raw_rx_result_busy,
  output logic        sb_tx_clk,
  output logic        sb_tx_data,
  output logic        raw_mode_active,
  output logic        raw_rx_low_sample,
  output logic        raw_tx_idle,
  output logic        raw_tx_iter_done,
  output logic        raw_rx_iter_vld,
  output logic        raw_rx_iter_match
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
  logic [6:0]    raw_tx_ui_q;
  logic [5:0]    rx_low_cnt_q;
  logic [5:0]    missing_strobe_cnt_q;
  logic          rx_active_match_q;
  logic          rx_gap_error_q;
  logic          raw_rx_force_mismatch_q;
  logic          pattern_run_meta_q;
  logic          pattern_run_sync_q;
  logic          raw_mode_meta_q;
  logic          raw_mode_sync_q;

  // Strobe loss threshold in sbclk cycles (>16 cycles to tolerate CDC phase drift)
  localparam logic [5:0] STROBE_LOSS_THRESHOLD = 6'd20;

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

  // =========================================================================
  // TRANSMIT DATAPATH AND FORWARDED STROBE GENERATION
  // =========================================================================
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

  // Glitch-free clock gating cell for forwarded TX strobe (sb_tx_clk).
  // Clock enable is latched on negedge sbclk so that sb_tx_clk transitions
  // occur cleanly edge-aligned with posedge sbclk, and park low when disabled.
  // Spec ref: UCIe 1.0 Section 5.13 and Figure 99.
  logic raw_tx_clk_en_neg_q;
  logic raw_tx_bit_q;

  always_ff @(negedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      raw_tx_clk_en_neg_q <= 1'b0;
      raw_tx_bit_q        <= 1'b0;
    end else begin
      raw_tx_clk_en_neg_q <= (raw_tx_state_q == RAW_TX_ACTIVE);
      if (raw_tx_state_q == RAW_TX_ACTIVE)
        raw_tx_bit_q <= ~raw_tx_ui_q[0];
      else
        raw_tx_bit_q <= 1'b0;
    end
  end

  assign sb_tx_clk         = raw_tx_clk_en_neg_q & sbclk;
  assign sb_tx_data        = raw_tx_clk_en_neg_q ? raw_tx_bit_q : 1'b0;
  assign raw_tx_idle       = (raw_tx_state_q == RAW_TX_IDLE);
  assign raw_mode_active   = raw_mode_sync_q;

  // =========================================================================
  // RECEIVE FRONT-END: PHYSICAL SAMPLING ON NEGEDGE SB_RX_CLK
  // =========================================================================
  // Per UCIe 1.0 Section 5.13 and Figure 99:
  // Incoming data is edge-aligned with sb_rx_clk rising edges. The receiver
  // samples serial data on the falling edge of the strobe (negedge sb_rx_clk),
  // providing 50% UI eye setup and hold margin.
  // The front-end checks alternating data throughout all 64 active UIs.
  // =========================================================================
  logic        rx_fe_rst_n;
  logic        rx_fe_abort_rst_q;
  logic [5:0]  rx_fe_bit_cnt_q       = 6'd0;
  logic        rx_fe_expected_q      = 1'b0;
  logic        rx_fe_pattern_ok_q    = 1'b1;
  logic        rx_fe_match_latched_q = 1'b0;
  logic        rx_fe_done_tog_q      = 1'b0;
  logic        rx_fe_strobe_tog_q    = 1'b0;

  assign rx_fe_rst_n = sbreset_n && !rx_fe_abort_rst_q;

  always_ff @(negedge sb_rx_clk or negedge rx_fe_rst_n) begin
    if (!rx_fe_rst_n) begin
      rx_fe_bit_cnt_q       <= 6'd0;
      rx_fe_expected_q      <= 1'b0;
      rx_fe_pattern_ok_q    <= 1'b1;
      rx_fe_match_latched_q <= 1'b0;
      rx_fe_done_tog_q      <= 1'b0;
      rx_fe_strobe_tog_q    <= 1'b0;
    end else begin
      rx_fe_strobe_tog_q <= ~rx_fe_strobe_tog_q;

      if (rx_fe_bit_cnt_q == 6'd0) begin
        // First active bit received: establish expectation for alternating sequence
        rx_fe_expected_q   <= ~sb_rx_data;
        rx_fe_pattern_ok_q <= 1'b1;
        rx_fe_bit_cnt_q    <= 6'd1;
      end else begin
        if (sb_rx_data != rx_fe_expected_q) begin
          rx_fe_pattern_ok_q <= 1'b0;
        end
        rx_fe_expected_q <= ~rx_fe_expected_q;

        if (rx_fe_bit_cnt_q == 6'd63) begin
          // 64th active UI received
          rx_fe_match_latched_q <= rx_fe_pattern_ok_q && (sb_rx_data == rx_fe_expected_q);
          rx_fe_done_tog_q      <= ~rx_fe_done_tog_q;
          rx_fe_bit_cnt_q       <= 6'd0;
        end else begin
          rx_fe_bit_cnt_q <= rx_fe_bit_cnt_q + 1'b1;
        end
      end
    end
  end

  // =========================================================================
  // SYNCHRONIZATION AND STROBE MONITORING INTO SBCLK
  // =========================================================================
  logic [1:0] strobe_sync_q;
  logic [1:0] done_sync_q;
  logic [1:0] rx_clk_sync_q;
  logic [1:0] rx_data_sync_q;

  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      strobe_sync_q  <= 2'b00;
      done_sync_q    <= 2'b00;
      rx_clk_sync_q  <= 2'b00;
      rx_data_sync_q <= 2'b00;
    end else begin
      strobe_sync_q  <= {strobe_sync_q[0], rx_fe_strobe_tog_q};
      done_sync_q    <= {done_sync_q[0], rx_fe_done_tog_q};
      rx_clk_sync_q  <= {rx_clk_sync_q[0], sb_rx_clk};
      rx_data_sync_q <= {rx_data_sync_q[0], sb_rx_data};
    end
  end

  wire strobe_event  = strobe_sync_q[1] ^ strobe_sync_q[0];
  wire done_event    = done_sync_q[1]   ^ done_sync_q[0];
  wire rx_clk_level  = rx_clk_sync_q[1];
  wire rx_data_level = rx_data_sync_q[1];

  // Observed low boundary: clock parked low, data low, and no active strobe
  assign raw_rx_low_sample = !rx_clk_level && !rx_data_level && !strobe_event;

  // =========================================================================
  // RECEIVE PROTOCOL FSM AND LOW INTERVAL VERIFICATION IN SBCLK
  // =========================================================================
  // Parse only candidates that start after an observed low boundary. If the
  // result mailbox is busy, preserve a conservative mismatch before parsing
  // further candidates. This prevents a missing mismatch from creating a
  // false two-consecutive-match trigger in LTSM.
  // =========================================================================
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      raw_rx_state_q          <= RAW_RX_WAIT_LOW;
      missing_strobe_cnt_q    <= 6'd0;
      rx_low_cnt_q            <= 6'd0;
      rx_active_match_q       <= 1'b0;
      rx_gap_error_q          <= 1'b0;
      rx_fe_abort_rst_q       <= 1'b0;
      raw_rx_iter_vld         <= 1'b0;
      raw_rx_iter_match       <= 1'b0;
      raw_rx_force_mismatch_q <= 1'b0;
    end else if (!raw_mode_sync_q) begin
      raw_rx_state_q          <= RAW_RX_WAIT_LOW;
      missing_strobe_cnt_q    <= 6'd0;
      rx_low_cnt_q            <= 6'd0;
      rx_active_match_q       <= 1'b0;
      rx_gap_error_q          <= 1'b0;
      rx_fe_abort_rst_q       <= 1'b0;
      raw_rx_iter_vld         <= 1'b0;
      raw_rx_iter_match       <= 1'b0;
      raw_rx_force_mismatch_q <= 1'b0;
    end else begin
      raw_rx_iter_vld   <= 1'b0;
      rx_fe_abort_rst_q <= 1'b0;

      if (raw_rx_force_mismatch_q) begin
        raw_rx_state_q       <= RAW_RX_WAIT_LOW;
        missing_strobe_cnt_q <= 6'd0;
        rx_low_cnt_q         <= 6'd0;
        rx_active_match_q    <= 1'b0;
        rx_gap_error_q       <= 1'b0;
        if (!raw_rx_result_busy) begin
          raw_rx_iter_match       <= 1'b0;
          raw_rx_iter_vld         <= 1'b1;
          raw_rx_force_mismatch_q <= 1'b0;
        end
      end else begin
        case (raw_rx_state_q)
          RAW_RX_WAIT_LOW: begin
            missing_strobe_cnt_q <= 6'd0;
            rx_low_cnt_q         <= 6'd0;
            rx_gap_error_q       <= 1'b0;
            if (raw_rx_low_sample) begin
              raw_rx_state_q <= RAW_RX_WAIT_ACTIVE;
            end
          end

          RAW_RX_WAIT_ACTIVE: begin
            missing_strobe_cnt_q <= 6'd0;
            rx_low_cnt_q         <= 6'd0;
            rx_gap_error_q       <= 1'b0;
            if (strobe_event) begin
              raw_rx_state_q <= RAW_RX_ACTIVE;
            end
          end

          RAW_RX_ACTIVE: begin
            if (done_event) begin
              // 64 active UIs completed cleanly by the front-end
              rx_active_match_q    <= rx_fe_match_latched_q;
              rx_gap_error_q       <= 1'b0;
              rx_low_cnt_q         <= 6'd0;
              missing_strobe_cnt_q <= 6'd0;
              raw_rx_state_q       <= RAW_RX_LOW;
            end else if (strobe_event) begin
              missing_strobe_cnt_q <= 6'd0;
            end else begin
              // Strobe edge missing this sbclk cycle: count consecutive missing cycles
              // to tolerate CDC phase drift. Threshold > 16 cycles avoids mistaking
              // occasional missing strobe samples for the inter-burst gap.
              if (missing_strobe_cnt_q >= STROBE_LOSS_THRESHOLD) begin
                // Early strobe cessation before 64 bits completed
                rx_active_match_q    <= 1'b0;
                rx_fe_abort_rst_q    <= 1'b1; // Reset front-end bit count
                rx_gap_error_q       <= 1'b1;
                rx_low_cnt_q         <= 6'd0;
                missing_strobe_cnt_q <= 6'd0;
                raw_rx_state_q       <= RAW_RX_LOW;
              end else begin
                missing_strobe_cnt_q <= missing_strobe_cnt_q + 1'b1;
              end
            end
          end

          RAW_RX_LOW: begin
            // 32-UI low interval check: clock parked low and data low
            if (strobe_event || rx_clk_level || rx_data_level) begin
              rx_gap_error_q <= 1'b1;
            end

            if (rx_low_cnt_q == (SBINIT_LOW_UI - 1)) begin
              rx_low_cnt_q         <= 6'd0;
              missing_strobe_cnt_q <= 6'd0;
              raw_rx_state_q       <= RAW_RX_WAIT_ACTIVE;

              if (!raw_rx_result_busy) begin
                raw_rx_iter_match <= rx_active_match_q && !rx_gap_error_q &&
                                     !strobe_event && !rx_clk_level && !rx_data_level;
                raw_rx_iter_vld   <= 1'b1;
              end else begin
                raw_rx_force_mismatch_q <= 1'b1;
              end
            end else begin
              rx_low_cnt_q <= rx_low_cnt_q + 1'b1;
            end
          end

          default: raw_rx_state_q <= RAW_RX_WAIT_LOW;
        endcase
      end
    end
  end

endmodule
`endif

// ============================================================================
// File        : sb_codec.sv
// Module      : sb_codec
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Self-contained scalar physical sideband codec.
//
// Serializes outgoing sideband transactions onto scalar physical pins
// (sb_tx_clk, sb_tx_data) and deserializes incoming transactions from scalar
// physical pins (sb_rx_clk, sb_rx_data) using Single Data Rate (SDR) strobe
// signaling per the UCIe 1.0 specification.
//
// Handshake:
//   TX: Accept exactly one packet when tx_valid && tx_ready.
//       tx_busy asserts upon packet acceptance and remains held through
//       all 64 UIs of header, 32 UIs of header gap, optional 64 UIs of
//       padded payload, and 32 UIs of final payload gap.
//   RX: Deserializes packets into an internal two-entry packet-event queue.
//       rx_valid asserts while the queue is non-empty and holds the
//       decoded rx_packet, rx_format_error, rx_cp_error, and rx_dp_error
//       stable until acknowledged and popped by rx_ready.
//       Sticky rx_overflow asserts if a packet arrives while the two-entry
//       queue is full and not popping.
//
// Spec References:
//   - UCIe 1.0, Section 4.1.5: Sideband transmission (serial data and clock pin
//     pair, 64-bit serial packet, 32-bit low separation, 800 MT/s SDR).
//   - UCIe 1.0, Section 5.13: Sideband signaling (800 MHz SDR, data edge-aligned
//     with strobe, negedge strobe sampling, parked clock/data low).
//   - UCIe 1.0, Section 5.13.1, Table 46: Sideband electrical parameters.
//   - UCIe 1.0, Section 6.1.1, Table 47: Opcode encodings mapped to Packet Types.
//   - UCIe 1.0, Section 6.1.1, Tables 48/49: FDI and RDI srcid / dstid encodings.
//   - UCIe 1.0, Section 6.1.2, Figures 100-103: Packet layouts (Register Access
//     Request, Register Access Completion, Sideband Message).
//   - UCIe 1.0, Section 6.1.2.1, Table 50: Parity and field definitions.
//   - UCIe 1.0, Section 6.1.2.1, Table 52: Completion Status encodings.
//   - UCIe 1.0, Section 6.1.3: Flow Control and Data Integrity (fatal UIE on
//     parity failure, 32-UI inter-packet gap).
//   - UCIe 1.0, Figures 46 & 47: Sideband serial packet timing and back-to-back
//     packet transmission (64 UI packet, 32 UI low separation).
//   - UCIe 1.0, Figure 99: Sideband signaling and negedge strobe sample point.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2025-XX-XX  -           Initial PoC sideband codec.
//   0.0.2 2026-09-23  -           Documentation pass on parity rules.
//   0.0.3 2026-09-23  -           Document sbclk-only operation.
//   0.0.4 2026-09-24  -           Phase A: validate DATA64 DP parity for both values.
//   0.0.5 2026-09-28  -           Rewrite as self-contained scalar physical sideband
//                                 codec. Added scalar sb_tx_clk / sb_tx_data and
//                                 sb_rx_clk / sb_rx_data physical pins with SDR
//                                 strobe clocking per UCIe 1.0 Section 4.1.5 and 5.13.
//                                 Adopted sb_packet_t handshake (tx_valid/tx_ready,
//                                 rx_valid/rx_ready) with a 2-entry packet-event
//                                 queue, deterministic 64 UI packet / 32 UI low
//                                 gap timing, strict header/payload gap validation,
//                                 sb_rx_clk sampling, opcode-driven payload handling,
//                                 detection of early strobe loss, unexpected gap
//                                 strobes, reserved opcodes/fields, CP/DP parity,
//                                 upper 32-bit payload validation, and sticky overflow.
//   0.0.6 2026-10-08  -           Documentation compliance pass: add detailed
//                                 construct comments (5-30 lines) with UCIe 1.0
//                                 spec citations across all always/assign/
//                                 instantiation blocks.
// ============================================================================
`ifndef SbCodec_SV
`define SbCodec_SV

`include "ucie_pkg.sv"

`timescale 1ns/1ps

module sb_codec (
  // -------------------------------------------------------------------------
  // Core Clock and Reset
  // -------------------------------------------------------------------------
  input  logic        sbclk,            // 800 MHz internal sideband clock
  input  logic        sbreset_n,        // Active-low reset

  // -------------------------------------------------------------------------
  // Transmit Parallel Interface (Handshake)
  // -------------------------------------------------------------------------
  input  logic        tx_valid,         // Packet transmission request from local agent
  output logic        tx_ready,         // Codec ready to accept next packet (idle)
  input  ucie_pkg::sb_packet_t tx_packet, // Packed sideband transaction to transmit
  output logic        tx_busy,          // TX busy (packet active or trailing inter-packet gap)

  // -------------------------------------------------------------------------
  // Sideband Physical Interface (Scalar SDR)
  // -------------------------------------------------------------------------
  output logic        sb_tx_clk,        // Forwarded TX strobe/clock (800 MHz SDR, gated)
  output logic        sb_tx_data,       // Serial TX data (edge-aligned with sb_tx_clk)
  input  logic        sb_rx_clk,        // Incoming RX strobe/clock (gated)
  input  logic        sb_rx_data,       // Incoming RX serial data

  // -------------------------------------------------------------------------
  // Receive Parallel Interface (Queue / Handshake)
  // -------------------------------------------------------------------------
  output logic        rx_valid,         // Valid packet available at head of queue
  input  logic        rx_ready,         // Consumer acknowledges and pops current packet
  output ucie_pkg::sb_packet_t rx_packet, // Decoded sideband packet at head of queue
  output logic        rx_format_error,  // Format error (early strobe loss, bad gap, reserved fields)
  output logic        rx_cp_error,      // Control Parity mismatch flag for current packet
  output logic        rx_dp_error,      // Data Parity mismatch flag for current packet
  output logic        rx_overflow       // Sticky receive queue overflow indication
);

  import ucie_pkg::*;

  // =========================================================================
  // TRANSMIT DATAPATH AND SERIALIZER FSM
  // =========================================================================
  // States:
  //   TX_IDLE     : Waiting for tx_valid && tx_ready.
  //   TX_HDR      : Emitting 64 header bits (1 bit/UI), toggling sb_tx_clk.
  //   TX_HDR_GAP  : Emitting 32 UI low gap with sb_tx_clk parked low.
  //   TX_PAYLOAD  : Emitting 64 padded payload bits, toggling sb_tx_clk.
  //   TX_PLD_GAP  : Emitting 32 UI low gap with sb_tx_clk parked low.
  // =========================================================================
  typedef enum logic [2:0] {
    TX_IDLE     = 3'd0,
    TX_HDR      = 3'd1,
    TX_HDR_GAP  = 3'd2,
    TX_PAYLOAD  = 3'd3,
    TX_PLD_GAP  = 3'd4
  } tx_state_t;

  tx_state_t   tx_state_q;
  logic [5:0]  tx_bit_cnt_q;
  logic [4:0]  tx_gap_cnt_q;
  logic [63:0] tx_hdr_shift_q;
  logic [63:0] tx_pld_shift_q;
  logic        tx_has_pld_q;
  logic        tx_clk_en_q;
  logic        tx_clk_en_neg_q;

  // -------------------------------------------------------------------------
  // always_ff: TX Strobe Gating Cell (Negedge Retiming)
  //
  // Latches tx_clk_en_q on the falling edge of sbclk so that sb_tx_clk
  // transitions occur cleanly edge-aligned with rising sbclk edges and park
  // stably low during inter-packet gaps, preventing runt pulses.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 and Section 4.1.5.
  // -------------------------------------------------------------------------
  always_ff @(negedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      tx_clk_en_neg_q <= 1'b0;
    end else begin
      tx_clk_en_neg_q <= tx_clk_en_q;
    end
  end

  // -------------------------------------------------------------------------
  // assign: sb_tx_clk - Physical Transmit Strobe Pin Driver
  //
  // Gates the 800 MHz SDR forwarded strobe to the physical link pin.
  // Toggles only during 64-UI active packet windows and remains parked low
  // during 32-UI inter-packet gaps per Section 5.13.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Section 5.13.
  // -------------------------------------------------------------------------
  assign sb_tx_clk = tx_clk_en_neg_q & sbclk;

  // -------------------------------------------------------------------------
  // assign: sb_tx_data - Physical Transmit Serial Data Pin Driver
  //
  // Drives the serial LSB bit of header or payload shift register onto the
  // physical data pin. Parks low during inter-packet gaps per Section 5.13.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Figure 46.
  // -------------------------------------------------------------------------
  assign sb_tx_data = (tx_state_q == TX_HDR) ||
                      ((tx_state_q == TX_HDR_GAP) && (tx_gap_cnt_q == 5'd0)) ?
                      tx_hdr_shift_q[0] :
                      (tx_state_q == TX_PAYLOAD) ||
                      ((tx_state_q == TX_PLD_GAP) && (tx_gap_cnt_q == 5'd0)) ?
                      tx_pld_shift_q[0] :
                      1'b0;

  // -------------------------------------------------------------------------
  // assign: tx_ready - Transmit Interface Ready Status
  //
  // Asserted while the transmit serializer FSM is in TX_IDLE, indicating the
  // codec is ready to accept a new sideband packet transmission request.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Section 6.1.
  // -------------------------------------------------------------------------
  assign tx_ready = (tx_state_q == TX_IDLE);

  // -------------------------------------------------------------------------
  // assign: tx_busy - Transmit Interface Busy Indication
  //
  // Asserted whenever the transmitter is actively serializing a packet or
  // executing the mandatory 32-UI trailing inter-packet gap.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Section 6.1.3.
  // -------------------------------------------------------------------------
  assign tx_busy  = (tx_state_q != TX_IDLE);

  // -------------------------------------------------------------------------
  // always_ff: Transmit Serializer Protocol FSM
  //
  // Sequences packet serialization through TX_IDLE, TX_HDR (64 UIs),
  // TX_HDR_GAP (32 UIs), optional TX_PAYLOAD (64 UIs), and TX_PLD_GAP (32 UIs).
  // LSB-first transmission per Section 6.1.2.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Section 6.1.2.
  // -------------------------------------------------------------------------
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      tx_state_q      <= TX_IDLE;
      tx_bit_cnt_q    <= 6'd0;
      tx_gap_cnt_q    <= 5'd0;
      tx_hdr_shift_q  <= 64'h0;
      tx_pld_shift_q  <= 64'h0;
      tx_has_pld_q    <= 1'b0;
      tx_clk_en_q     <= 1'b0;
    end else begin
      case (tx_state_q)
        TX_IDLE: begin
          tx_bit_cnt_q <= 6'd0;
          tx_gap_cnt_q <= 5'd0;
          if (tx_valid && tx_ready) begin
            // Encode header with package helper (handles opcode, IDs, tags, addr, CP, DP)
            tx_hdr_shift_q <= sb_encode_header(tx_packet);
            // Pad 32-bit payload upper bits with zero; 64-bit unpadded; 0-byte zeroed
            tx_pld_shift_q <= sb_pad_data(tx_packet.opcode, tx_packet.data);
            tx_has_pld_q   <= (sb_payload_bytes(tx_packet.opcode) > 0);
            tx_clk_en_q    <= 1'b1;
            tx_state_q     <= TX_HDR;
          end else begin
            tx_clk_en_q    <= 1'b0;
          end
        end

        TX_HDR: begin
          // Hold the first bit through the first forwarded rising edge.
          if (tx_bit_cnt_q != 6'd0) begin
            tx_hdr_shift_q <= {1'b0, tx_hdr_shift_q[63:1]};
          end
          if (tx_bit_cnt_q == 6'd63) begin
            // 64th bit transmitted; park clock and enter 32-UI header gap
            tx_clk_en_q  <= 1'b0;
            tx_gap_cnt_q <= 5'd0;
            tx_state_q   <= TX_HDR_GAP;
          end else begin
            tx_bit_cnt_q <= tx_bit_cnt_q + 1'b1;
            tx_clk_en_q  <= 1'b1;
          end
        end

        TX_HDR_GAP: begin
          // Count exactly 32 UI low separation (SB_GAP_UI)
          if (tx_gap_cnt_q == 5'd31) begin
            tx_gap_cnt_q <= 5'd0;
            if (tx_has_pld_q) begin
              // Advance to payload serialization phase
              tx_bit_cnt_q <= 6'd0;
              tx_clk_en_q  <= 1'b1;
              tx_state_q   <= TX_PAYLOAD;
            end else begin
              // No payload; transaction complete after header gap
              tx_clk_en_q  <= 1'b0;
              tx_state_q   <= TX_IDLE;
            end
          end else begin
            tx_gap_cnt_q <= tx_gap_cnt_q + 1'b1;
            tx_clk_en_q  <= 1'b0;
          end
        end

        TX_PAYLOAD: begin
          // Hold the first payload bit through the first forwarded edge.
          if (tx_bit_cnt_q != 6'd0) begin
            tx_pld_shift_q <= {1'b0, tx_pld_shift_q[63:1]};
          end
          if (tx_bit_cnt_q == 6'd63) begin
            // 64th bit transmitted; park clock and enter 32-UI final gap
            tx_clk_en_q  <= 1'b0;
            tx_gap_cnt_q <= 5'd0;
            tx_state_q   <= TX_PLD_GAP;
          end else begin
            tx_bit_cnt_q <= tx_bit_cnt_q + 1'b1;
            tx_clk_en_q  <= 1'b1;
          end
        end

        TX_PLD_GAP: begin
          // Count exactly 32 UI low separation before declaring idle
          if (tx_gap_cnt_q == 5'd31) begin
            tx_gap_cnt_q <= 5'd0;
            tx_clk_en_q  <= 1'b0;
            tx_state_q   <= TX_IDLE;
          end else begin
            tx_gap_cnt_q <= tx_gap_cnt_q + 1'b1;
            tx_clk_en_q  <= 1'b0;
          end
        end

        default: tx_state_q <= TX_IDLE;
      endcase
    end
  end

  // =========================================================================
  // RECEIVE FRONT-END: PHYSICAL SAMPLING ON NEGEDGE SB_RX_CLK
  // =========================================================================
  // Per UCIe 1.0 Section 5.13 and Figure 99:
  // Incoming data is edge-aligned with sb_rx_clk rising edges. The receiver
  // samples serial data on the falling edge of the strobe (negedge sb_rx_clk),
  // providing 50% UI eye setup and hold margin.
  // =========================================================================
  logic rx_fe_rst_n;
  logic rx_abort_rst_q;

  // -------------------------------------------------------------------------
  // assign: rx_fe_rst_n - Receive Front-End Asynchronous Reset
  //
  // Generates reset for the negedge sb_rx_clk front-end sampler from global
  // sbreset_n qualified with synchronous abort resets triggered on protocol errors.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 - Sideband Signaling.
  // -------------------------------------------------------------------------
  assign rx_fe_rst_n = sbreset_n && !rx_abort_rst_q;

  logic [63:0] rx_shift_reg_q;
  logic [5:0]  rx_fe_bit_cnt_q;
  logic [63:0] rx_hdr_buf_q;
  logic [63:0] rx_pld_buf_q;
  logic        rx_hdr_done_tog_q;
  logic        rx_pld_done_tog_q;
  logic        rx_strobe_tog_q;
  logic        rx_expect_pld_q;

  // -------------------------------------------------------------------------
  // always_ff: Receive Physical Front-End Strobe Sampler
  //
  // Samples serial data on negedge sb_rx_clk (strobe center per Section 5.13),
  // shifts incoming bits LSB-first into rx_shift_reg_q, and transfers completed
  // 64-bit words to header/payload holding buffers with completion toggle flags.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 and Figure 99.
  // -------------------------------------------------------------------------
  always_ff @(negedge sb_rx_clk or negedge rx_fe_rst_n) begin
    if (!rx_fe_rst_n) begin
      rx_shift_reg_q    <= 64'h0;
      rx_fe_bit_cnt_q   <= 6'd0;
      rx_hdr_buf_q      <= 64'h0;
      rx_pld_buf_q      <= 64'h0;
      rx_hdr_done_tog_q <= 1'b0;
      rx_pld_done_tog_q <= 1'b0;
      rx_strobe_tog_q   <= 1'b0;
    end else begin
      rx_strobe_tog_q <= ~rx_strobe_tog_q;
      rx_shift_reg_q  <= {sb_rx_data, rx_shift_reg_q[63:1]};

      if (rx_fe_bit_cnt_q == 6'd63) begin
        rx_fe_bit_cnt_q <= 6'd0;
        if (!rx_expect_pld_q) begin
          rx_hdr_buf_q      <= {sb_rx_data, rx_shift_reg_q[63:1]};
          rx_hdr_done_tog_q <= ~rx_hdr_done_tog_q;
        end else begin
          rx_pld_buf_q      <= {sb_rx_data, rx_shift_reg_q[63:1]};
          rx_pld_done_tog_q <= ~rx_pld_done_tog_q;
        end
      end else begin
        rx_fe_bit_cnt_q <= rx_fe_bit_cnt_q + 1'b1;
      end
    end
  end

  // =========================================================================
  // SYNCHRONIZATION AND STROBE MONITORING INTO SBCLK
  // =========================================================================
  logic [1:0] strobe_tog_sync_q;
  logic [1:0] hdr_done_sync_q;
  logic [1:0] pld_done_sync_q;
  logic [1:0] rx_clk_level_sync_q;

  // -------------------------------------------------------------------------
  // always_ff: Strobe Toggle and Front-End Event Synchronizers
  //
  // 2-stage synchronizers bringing front-end toggle pulses and strobe level
  // into the local sbclk domain to monitor reception progress and detect
  // early strobe loss or unexpected gap activity.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.13 and Section 6.1.3.
  // -------------------------------------------------------------------------
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      strobe_tog_sync_q   <= 2'b00;
      hdr_done_sync_q     <= 2'b00;
      pld_done_sync_q     <= 2'b00;
      rx_clk_level_sync_q <= 2'b00;
    end else begin
      strobe_tog_sync_q   <= {strobe_tog_sync_q[0], rx_strobe_tog_q};
      hdr_done_sync_q     <= {hdr_done_sync_q[0], rx_hdr_done_tog_q};
      pld_done_sync_q     <= {pld_done_sync_q[0], rx_pld_done_tog_q};
      rx_clk_level_sync_q <= {rx_clk_level_sync_q[0], sb_rx_clk};
    end
  end

  wire strobe_event   = strobe_tog_sync_q[1] ^ strobe_tog_sync_q[0];
  wire hdr_done_event = hdr_done_sync_q[1]   ^ hdr_done_sync_q[0];
  wire pld_done_event = pld_done_sync_q[1]   ^ pld_done_sync_q[0];
  wire rx_clk_is_high = rx_clk_level_sync_q[1];

  // =========================================================================
  // RECEIVE PROTOCOL FSM AND ERROR CHECKING IN SBCLK
  // =========================================================================
  // States:
  //   RX_IDLE         : Waiting for first strobe of incoming packet.
  //   RX_HDR_ACTIVE   : Assembling 64-bit header, monitoring for strobe loss.
  //   RX_HDR_GAP      : Enforcing 32-UI header gap, checking for unexpected strobes.
  //   RX_PLD_ACTIVE   : Assembling 64-bit payload, monitoring for strobe loss.
  //   RX_PLD_GAP      : Enforcing 32-UI payload gap, checking for unexpected strobes.
  //   RX_EVAL_DONE    : Evaluating parity, opcode, upper-32b, pushing to queue.
  //   RX_ABORT_WAIT   : Clearing front-end after early strobe loss.
  // =========================================================================
  typedef enum logic [2:0] {
    RX_IDLE         = 3'd0,
    RX_HDR_ACTIVE   = 3'd1,
    RX_HDR_GAP      = 3'd2,
    RX_PLD_ACTIVE   = 3'd3,
    RX_PLD_GAP      = 3'd4,
    RX_EVAL_DONE    = 3'd5,
    RX_ABORT_WAIT   = 3'd6
  } rx_state_t;

  rx_state_t   rx_state_q;
  logic [4:0]  rx_gap_cnt_q;
  logic [5:0]  rx_strobe_timeout_cnt_q;
  logic        rx_pld_started_q;
  logic [63:0] rx_hdr_latched_q;
  logic [63:0] rx_pld_latched_q;
  logic        rx_gap_strobe_err_q;
  logic        rx_strobe_loss_err_q;

  // Packet-event queue entry definition
  typedef struct packed {
    sb_packet_t packet;
    logic       format_error;
    logic       cp_error;
    logic       dp_error;
  } rx_queue_entry_t;

  rx_queue_entry_t new_rx_entry;
  logic            rx_push_req;

  // Strobe timeout threshold in sbclk cycles for declaring early strobe loss
  localparam logic [5:0] STROBE_LOSS_TIMEOUT = 6'd16;
  // Maximum timeout waiting for payload strobe to commence after header gap
  localparam logic [5:0] PLD_START_TIMEOUT   = 6'd63;

  // -------------------------------------------------------------------------
  // always_ff: Receive Protocol State Machine and Gap Monitor
  //
  // Tracks receive packet phases: RX_IDLE, RX_HDR, RX_HDR_GAP (32 UI validation),
  // RX_PAYLOAD, RX_PLD_GAP, and RX_DISPATCH. Validates 32-UI inter-packet gaps
  // and detects early strobe termination or illegal gap strobes per Section 6.1.3.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5, Section 5.13, and Section 6.1.3.
  // -------------------------------------------------------------------------
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      rx_state_q              <= RX_IDLE;
      rx_gap_cnt_q            <= 5'd0;
      rx_strobe_timeout_cnt_q <= 6'd0;
      rx_pld_started_q        <= 1'b0;
      rx_hdr_latched_q        <= 64'h0;
      rx_pld_latched_q        <= 64'h0;
      rx_gap_strobe_err_q     <= 1'b0;
      rx_strobe_loss_err_q    <= 1'b0;
      rx_expect_pld_q         <= 1'b0;
      rx_abort_rst_q          <= 1'b0;
      rx_push_req             <= 1'b0;
    end else begin
      rx_push_req    <= 1'b0;
      rx_abort_rst_q <= 1'b0;

      case (rx_state_q)
        RX_IDLE: begin
          rx_gap_cnt_q            <= 5'd0;
          rx_strobe_timeout_cnt_q <= 6'd0;
          rx_pld_started_q        <= 1'b0;
          rx_gap_strobe_err_q     <= 1'b0;
          rx_strobe_loss_err_q    <= 1'b0;
          rx_expect_pld_q         <= 1'b0;
          // Recognize a packet only from active scalar strobe
          if (strobe_event) begin
            rx_state_q <= RX_HDR_ACTIVE;
          end
        end

        RX_HDR_ACTIVE: begin
          if (hdr_done_event) begin
            // Arm payload capture as soon as the header completes. The
            // serialized payload starts during the physical header gap,
            // before the synchronized protocol FSM leaves RX_HDR_GAP.
            rx_expect_pld_q  <= (sb_payload_bytes(rx_hdr_buf_q[4:0]) > 0);
            rx_hdr_latched_q <= rx_hdr_buf_q;
            rx_gap_cnt_q     <= 5'd0;
            rx_state_q       <= RX_HDR_GAP;
          end else begin
            // Monitor for early strobe loss
            if (strobe_event) begin
              rx_strobe_timeout_cnt_q <= 6'd0;
            end else begin
              if (rx_strobe_timeout_cnt_q == STROBE_LOSS_TIMEOUT) begin
                // Strobe stopped before 64 bits received
                rx_strobe_loss_err_q <= 1'b1;
                rx_abort_rst_q       <= 1'b1;
                rx_push_req          <= 1'b1; // Push error event
                rx_state_q           <= RX_ABORT_WAIT;
              end else begin
                rx_strobe_timeout_cnt_q <= rx_strobe_timeout_cnt_q + 1'b1;
              end
            end
          end
        end

        RX_HDR_GAP: begin
          // Require header gap of 32 UIs before optional payload phase
          if (strobe_event || rx_clk_is_high) begin
            // Unexpected strobe in gap detected
            rx_gap_strobe_err_q <= 1'b1;
          end

          if (rx_gap_cnt_q == 5'd31) begin
            rx_gap_cnt_q            <= 5'd0;
            rx_strobe_timeout_cnt_q <= 6'd0;
            rx_pld_started_q        <= 1'b0;
            // Decode opcode to decide whether a payload follows
            if (sb_payload_bytes(rx_hdr_latched_q[4:0]) > 0) begin
              rx_expect_pld_q <= 1'b1;
              rx_state_q      <= RX_PLD_ACTIVE;
            end else begin
              rx_expect_pld_q <= 1'b0;
              rx_state_q      <= RX_EVAL_DONE;
            end
          end else begin
            rx_gap_cnt_q <= rx_gap_cnt_q + 1'b1;
          end
        end

        RX_PLD_ACTIVE: begin
          if (pld_done_event) begin
            // 64 payload bits assembled cleanly
            rx_pld_latched_q <= rx_pld_buf_q;
            rx_expect_pld_q  <= 1'b0;
            rx_gap_cnt_q     <= 5'd0;
            rx_state_q       <= RX_PLD_GAP;
          end else if (!rx_pld_started_q) begin
            if (strobe_event) begin
              rx_pld_started_q        <= 1'b1;
              rx_strobe_timeout_cnt_q <= 6'd0;
            end else if (rx_strobe_timeout_cnt_q == PLD_START_TIMEOUT) begin
              // Payload strobe never started after gap
              rx_strobe_loss_err_q <= 1'b1;
              rx_abort_rst_q       <= 1'b1;
              rx_push_req          <= 1'b1;
              rx_state_q           <= RX_ABORT_WAIT;
            end else begin
              rx_strobe_timeout_cnt_q <= rx_strobe_timeout_cnt_q + 1'b1;
            end
          end else begin
            if (strobe_event) begin
              rx_strobe_timeout_cnt_q <= 6'd0;
            end else if (rx_strobe_timeout_cnt_q == STROBE_LOSS_TIMEOUT) begin
              // Payload strobe stopped prematurely
              rx_strobe_loss_err_q <= 1'b1;
              rx_abort_rst_q       <= 1'b1;
              rx_push_req          <= 1'b1;
              rx_state_q           <= RX_ABORT_WAIT;
            end else begin
              rx_strobe_timeout_cnt_q <= rx_strobe_timeout_cnt_q + 1'b1;
            end
          end
        end

        RX_PLD_GAP: begin
          // Require payload gap of 32 UIs before completion
          if (strobe_event || rx_clk_is_high) begin
            // Unexpected strobe in gap detected
            rx_gap_strobe_err_q <= 1'b1;
          end

          if (rx_gap_cnt_q == 5'd31) begin
            rx_gap_cnt_q <= 5'd0;
            rx_state_q   <= RX_EVAL_DONE;
          end else begin
            rx_gap_cnt_q <= rx_gap_cnt_q + 1'b1;
          end
        end

        RX_EVAL_DONE: begin
          // Commit the packet and error assessment into the packet-event queue.
          rx_push_req <= 1'b1;
          rx_state_q  <= RX_IDLE;
        end

        RX_ABORT_WAIT: begin
          // Front-end reset settling cycle before returning to idle
          rx_expect_pld_q <= 1'b0;
          rx_state_q      <= RX_IDLE;
        end

        default: rx_state_q <= RX_IDLE;
      endcase
    end
  end

  // =========================================================================
  // ERROR EVALUATION AND PACKET ASSEMBLY
  // =========================================================================
  sb_packet_t     dec_pkt;
  sb_decode_err_t dec_hdr_err;
  logic           rsvd_opcode_err;
  logic           cp_mismatch_err;
  logic           dp_mismatch_err;
  logic           upper32_err;
  logic           format_err_comb;

  // -------------------------------------------------------------------------
  // always_comb: Combinational Packet Decoder and Error Check Matrix
  //
  // Unpacks received 64-bit header into typed sb_packet_t, decodes payload,
  // validates opcode against Table 47, checks Control Parity (CP, bit 31),
  // checks Data Parity (DP, bit 30), and verifies upper 32-bit zero-padding.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.1 (Table 47) and Section 6.1.2.1 (Table 50).
  // -------------------------------------------------------------------------
  always @* begin
    // Unpack 64-bit header into typed sb_packet_t
    dec_pkt = sb_decode_header(rx_hdr_latched_q);
    // Pad received payload into packet data field
    if (sb_payload_bytes(dec_pkt.opcode) > 0) begin
      dec_pkt.data = sb_pad_data(dec_pkt.opcode, rx_pld_latched_q);
    end else begin
      dec_pkt.data = 64'h0;
    end

    // Opcode validation against Table 47
    rsvd_opcode_err = !sb_opcode_supported(dec_pkt.opcode);

    // Structural header checks (reserved bits, CP, illegal payload)
    dec_hdr_err = sb_decode_error(rx_hdr_latched_q);

    // CP parity check: even parity of header bits excluding DP (bit 30)
    cp_mismatch_err = dec_hdr_err.cp_err;

    // DP parity check: even parity of data payload (only for packets with data)
    if (sb_payload_bytes(dec_pkt.opcode) > 0) begin
      dp_mismatch_err = sb_check_dp_err(dec_pkt.opcode, rx_hdr_latched_q[30], rx_pld_latched_q);
    end else begin
      dp_mismatch_err = 1'b0;
    end

    // Check for nonzero upper 32 bits on 32-bit payload transfers
    if ((sb_payload_bytes(dec_pkt.opcode) == 4) && (rx_pld_latched_q[63:32] != 32'h0)) begin
      upper32_err = 1'b1;
    end else begin
      upper32_err = 1'b0;
    end

    // Format error rollup:
    //   - Early strobe loss
    //   - Unexpected strobe during header/payload gap
    //   - Reserved opcode
    //   - Nonzero upper 32 bits for 32-bit payload
    //   - Nonzero reserved header fields
    //   - Illegal payload combination (DP asserted with 0B payload)
    format_err_comb = rx_strobe_loss_err_q
                    | rx_gap_strobe_err_q
                    | rsvd_opcode_err
                    | upper32_err
                    | dec_hdr_err.rsvd_field
                    | dec_hdr_err.illegal_payload;
  end

  // -------------------------------------------------------------------------
  // assign: new_rx_entry.packet - Decoded Queue Entry Packet Field
  //
  // Drives unpacked packet structure into candidate queue insertion entry.
  // Cleared to zero if an unrecoverable early strobe loss occurred.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Layouts.
  // -------------------------------------------------------------------------
  assign new_rx_entry.packet       = rx_strobe_loss_err_q ? '0 : dec_pkt;

  // -------------------------------------------------------------------------
  // assign: new_rx_entry.format_error - Candidate Entry Format Error Flag
  //
  // Rolls up all structural formatting and gap timing violations.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data Integrity.
  // -------------------------------------------------------------------------
  assign new_rx_entry.format_error = format_err_comb;

  // -------------------------------------------------------------------------
  // assign: new_rx_entry.cp_error - Candidate Entry Control Parity Error Flag
  //
  // Driven from even-parity check across header bits [63:31, 29:0].
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 50).
  // -------------------------------------------------------------------------
  assign new_rx_entry.cp_error     = rx_strobe_loss_err_q ? 1'b0 : cp_mismatch_err;

  // -------------------------------------------------------------------------
  // assign: new_rx_entry.dp_error - Candidate Entry Data Parity Error Flag
  //
  // Driven from even-parity check across payload data bits.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 50).
  // -------------------------------------------------------------------------
  assign new_rx_entry.dp_error     = rx_strobe_loss_err_q ? 1'b0 : dp_mismatch_err;

  // =========================================================================
  // TWO-ENTRY PACKET-EVENT QUEUE AND HANDSHAKE INTERFACE
  // =========================================================================
  // Holds up to 2 received packet events.
  // Produces one retained packet event on {rx_valid, rx_packet, error flags}
  // until acknowledged and popped by rx_ready.
  // Asserts sticky rx_overflow if an incoming event arrives when full.
  // =========================================================================
  sb_packet_t rx_packet0_q, rx_packet1_q;
  logic       rx_format0_q, rx_format1_q;
  logic       rx_cp0_q, rx_cp1_q;
  logic       rx_dp0_q, rx_dp1_q;
  logic [1:0] rx_q_count_q;
  logic       rx_q_rd_ptr_q;
  logic       rx_q_wr_ptr_q;
  logic       rx_overflow_q;

  wire rx_pop  = rx_valid && rx_ready;
  wire rx_push = rx_push_req;

  // -------------------------------------------------------------------------
  // always_ff: 2-Entry Packet Event Queue Register File
  //
  // Implements FIFO storage for up to 2 received packet events and associated
  // error flags. Sets sticky rx_overflow_q if a push occurs when count is 2.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // -------------------------------------------------------------------------
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      rx_q_count_q  <= 2'd0;
      rx_q_rd_ptr_q <= 1'b0;
      rx_q_wr_ptr_q <= 1'b0;
      rx_overflow_q <= 1'b0;
      rx_packet0_q  <= '0;
      rx_packet1_q  <= '0;
      rx_format0_q  <= 1'b0;
      rx_format1_q  <= 1'b0;
      rx_cp0_q      <= 1'b0;
      rx_cp1_q      <= 1'b0;
      rx_dp0_q      <= 1'b0;
      rx_dp1_q      <= 1'b0;
    end else begin
      case ({rx_push, rx_pop})
        2'b10: begin
          if (rx_q_count_q == 2'd2) begin
            rx_overflow_q <= 1'b1;
          end else if (!rx_q_wr_ptr_q) begin
            rx_packet0_q <= new_rx_entry.packet;
            rx_format0_q <= new_rx_entry.format_error;
            rx_cp0_q     <= new_rx_entry.cp_error;
            rx_dp0_q     <= new_rx_entry.dp_error;
            rx_q_wr_ptr_q <= 1'b1;
            rx_q_count_q <= rx_q_count_q + 1'b1;
          end else begin
            rx_packet1_q <= new_rx_entry.packet;
            rx_format1_q <= new_rx_entry.format_error;
            rx_cp1_q     <= new_rx_entry.cp_error;
            rx_dp1_q     <= new_rx_entry.dp_error;
            rx_q_wr_ptr_q <= 1'b0;
            rx_q_count_q <= rx_q_count_q + 1'b1;
          end
        end
        2'b01: begin
          rx_q_rd_ptr_q <= ~rx_q_rd_ptr_q;
          rx_q_count_q  <= rx_q_count_q - 1'b1;
        end
        2'b11: begin
          if (!rx_q_wr_ptr_q) begin
            rx_packet0_q <= new_rx_entry.packet;
            rx_format0_q <= new_rx_entry.format_error;
            rx_cp0_q     <= new_rx_entry.cp_error;
            rx_dp0_q     <= new_rx_entry.dp_error;
            rx_q_wr_ptr_q <= 1'b1;
          end else begin
            rx_packet1_q <= new_rx_entry.packet;
            rx_format1_q <= new_rx_entry.format_error;
            rx_cp1_q     <= new_rx_entry.cp_error;
            rx_dp1_q     <= new_rx_entry.dp_error;
            rx_q_wr_ptr_q <= 1'b0;
          end
          rx_q_rd_ptr_q <= ~rx_q_rd_ptr_q;
        end
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // assign: rx_valid - Receive Event Available Flag
  //
  // Asserts while the 2-entry queue holds at least one packet event.
  // Held steady until acknowledged and popped by rx_ready.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.5 and Section 6.1.
  // -------------------------------------------------------------------------
  assign rx_valid = (rx_q_count_q != 2'd0);

  // -------------------------------------------------------------------------
  // assign: rx_packet - Read Head Packet Output Multiplexer
  //
  // Drives the decoded packet at the read pointer head of the 2-entry queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2 - Packet Layouts.
  // -------------------------------------------------------------------------
  assign rx_packet = rx_q_rd_ptr_q ? rx_packet1_q : rx_packet0_q;

  // -------------------------------------------------------------------------
  // assign: rx_format_error - Read Head Format Error Flag Multiplexer
  //
  // Drives format error status for the packet at the read head of the queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Data Integrity.
  // -------------------------------------------------------------------------
  assign rx_format_error = rx_valid ? (rx_q_rd_ptr_q ? rx_format1_q : rx_format0_q) : 1'b0;

  // -------------------------------------------------------------------------
  // assign: rx_cp_error - Read Head Control Parity Error Flag Multiplexer
  //
  // Drives CP mismatch error status for the packet at the read head of the queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 50).
  // -------------------------------------------------------------------------
  assign rx_cp_error = rx_valid ? (rx_q_rd_ptr_q ? rx_cp1_q : rx_cp0_q) : 1'b0;

  // -------------------------------------------------------------------------
  // assign: rx_dp_error - Read Head Data Parity Error Flag Multiplexer
  //
  // Drives DP mismatch error status for the packet at the read head of the queue.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.2.1 (Table 50).
  // -------------------------------------------------------------------------
  assign rx_dp_error = rx_valid ? (rx_q_rd_ptr_q ? rx_dp1_q : rx_dp0_q) : 1'b0;

  // -------------------------------------------------------------------------
  // assign: rx_overflow - Sticky Receive Queue Overflow Flag Driver
  //
  // Asserted sticky when incoming packets arrive faster than consumed.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1.3 - Flow Control.
  // -------------------------------------------------------------------------
  assign rx_overflow = rx_overflow_q;

endmodule

`endif

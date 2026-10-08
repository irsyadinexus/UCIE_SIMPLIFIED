// ============================================================================
// File        : sb_cdc_mailbox.sv
// Module      : sb_cdc_mailbox
// Project     : UCIe 1.0 Simplified Endpoint
// Description : One-entry asynchronous mailbox for sideband control packets.
//
// The source registers a complete payload and toggles src_req_q. The request
// toggle crosses into dst_clk through two synchronizer stages. The destination
// captures the payload only after the synchronized toggle changes, then returns
// the acknowledged toggle through two source-clock synchronizer stages.
//
// The source must hold src_data stable while src_busy is high. This module does
// that internally, so a source uses src_send for one cycle only when src_busy is
// low. The destination sees exactly one dst_valid pulse for each accepted send.
//
// This is a generic parameterizable one-entry asynchronous mailbox, not a
// streaming FIFO. It is used for transferring discrete typed payloads (such
// as complete sideband packets or status words) across asynchronous clock
// domains (e.g. between 500 MHz lclk and 800 MHz sbclk in Logical PHY). It
// prevents a one-clock-domain valid pulse from being lost in the other clock
// domain and keeps each payload stable during synchronization.
//
// CDC ARCHITECTURE & TOGGLE SYNCHRONIZATION DIAGRAM
//
//    Source Domain (src_clk)                     Destination Domain (dst_clk)
//   +-----------------------+                   +--------------------------+
//   | src_data -> [src_data_q] (held stable)--> | dst_data (sampled)       |
//   |                       |                   |                          |
//   | src_send -> src_req_q | --(2-stage sync)->| src_req_sync -> dst_valid|
//   |                       |                   |                 |        |
//   | src_busy <- dst_ack   | <--(2-stage sync)-| dst_ack_q <-----+        |
//   +-----------------------+                   +--------------------------+
//
// RESET CONTRACT
//   Both domain resets must assert together before traffic begins. Reset
//   aborts an in-flight mailbox entry. Sources must not send until both resets
//   have deasserted, which prevents a reset epoch from being mistaken for a
//   request toggle.
//
// SPECIFICATION REFERENCES
//   - UCIe 1.0 Specification, Section 4.1.5 - Sideband transmission.
//   - UCIe 1.0 Specification, Section 6.1 - Sideband Protocol.
//
// REVISION HISTORY
//   v0.0.1  2026-09-23  Req.3: add the toggle-handshake CDC boundary for
//                        complete sideband packet payloads.
//   v0.0.2  2026-09-23  Req.3: document the common-reset contract.
//   v0.0.3  2026-10-08  Documentation compliance pass: expand header with ASCII
//                        CDC architecture diagram and per-construct comment blocks.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef SbCdcMailbox_SV
`define SbCdcMailbox_SV

`timescale 1ns/1ps
module sb_cdc_mailbox #(
  parameter int unsigned WIDTH = 1
) (
  input  logic             src_clk,
  input  logic             src_reset_n,
  input  logic [WIDTH-1:0] src_data,
  input  logic             src_send,
  output logic             src_busy,

  input  logic             dst_clk,
  input  logic             dst_reset_n,
  output logic [WIDTH-1:0] dst_data,
  output logic             dst_valid
);

  // Source-domain request storage. src_data_q remains unchanged until the
  // destination has acknowledged the associated request toggle.
  logic [WIDTH-1:0] src_data_q;
  logic             src_req_q;
  logic             dst_ack_meta_q;
  logic             dst_ack_sync_q;

  // Destination-domain request synchronizer and acknowledgement toggle.
  logic src_req_meta_q;
  logic src_req_sync_q;
  logic dst_ack_q;

  // -------------------------------------------------------------------------
  // Source-domain storage and acknowledgement synchronizer
  // -------------------------------------------------------------------------
  // The source accepts only one payload while the mailbox is empty. The
  // two-flop acknowledgement synchronizer returns ownership after dst_valid.
  always_ff @(posedge src_clk or negedge src_reset_n) begin
    if (!src_reset_n) begin
      src_data_q    <= '0;
      src_req_q     <= 1'b0;
      dst_ack_meta_q<= 1'b0;
      dst_ack_sync_q<= 1'b0;
    end else begin
      dst_ack_meta_q <= dst_ack_q;
      dst_ack_sync_q <= dst_ack_meta_q;
      if (src_send && !src_busy) begin
        src_data_q <= src_data;
        src_req_q  <= ~src_req_q;
      end
    end
  end

  // -------------------------------------------------------------------------
  // assign: src_busy - source domain busy indication
  //
  // Asserted while a request toggle is outstanding and has not yet been
  // acknowledged by the destination domain through the 2-stage synchronizer.
  // Backpressures the source to guarantee payload stability during CDC crossing.
  //
  // Spec ref: UCIe 1.0 Specification, Section 6.1 - Sideband Protocol.
  // -------------------------------------------------------------------------
  assign src_busy = (src_req_q != dst_ack_sync_q);

  // -------------------------------------------------------------------------
  // Destination-domain request synchronizer and payload delivery
  // -------------------------------------------------------------------------
  // src_data_q becomes stable before src_req_sync_q changes. It remains stable
  // until the acknowledgement returns, so sampling the bundled data here is
  // safe after the two-flop request synchronization delay.
  always_ff @(posedge dst_clk or negedge dst_reset_n) begin
    if (!dst_reset_n) begin
      src_req_meta_q <= 1'b0;
      src_req_sync_q <= 1'b0;
      dst_ack_q      <= 1'b0;
      dst_data       <= '0;
      dst_valid      <= 1'b0;
    end else begin
      src_req_meta_q <= src_req_q;
      src_req_sync_q <= src_req_meta_q;
      dst_valid      <= 1'b0;
      if (src_req_sync_q != dst_ack_q) begin
        dst_data  <= src_data_q;
        dst_valid <= 1'b1;
        dst_ack_q <= src_req_sync_q;
      end
    end
  end
endmodule

`endif

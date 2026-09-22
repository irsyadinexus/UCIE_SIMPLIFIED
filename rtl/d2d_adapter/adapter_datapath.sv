// ============================================================================
// Module    : adapter_datapath
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_datapath.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 2.1 - Architecture Overview
//   UCIe 1.0 Specification, Section 4.1.x - Byte / Valid Framing
//   UCIe 1.0 Specification, Section 8.1 - RDI Pipeline Stage Requirement
//   UCIe 1.0 Specification, Section 4.3.4 - Width Degrade (x8 mode)
//   UCIe 1.0 Specification, Section 8.3.1 - Stall Protocol
//   UCIe 1.0 Specification, Table 114 - RDI Signal List
//   UCIe 1.0 Specification, Table 115 - FDI Signal List
//
// DESCRIPTION
//   Pure Streaming pass-through datapath implementing Raw Mode Format 1 only.
//   In this mode, lp_data on the FDI maps directly onto lp_data on the RDI
//   with a single registered pipeline stage in each direction. The register
//   stage satisfies the "Stage 1+" latency requirement of spec 8.1.
//
//   SCOPE EXCLUSIONS (by design, confirmed in project scope):
//     - NO CRC engine: Raw Mode Format 1 does not carry CRC fields.
//     - NO retry buffer: 4 GT/s operation does not require Retry (spec 5.x).
//     - NO sequence-number logic: no flit sequencing in Raw Mode.
//     - NO flit-header insertion: Format 1 carries raw data without headers.
//     - NO DLLP path: Data Link Layer Packets are not part of the Streaming
//       protocol (spec 4.x).
//
//   DATA FLOW
//     FDI -> RDI (Transmit direction):
//       lp_data/lp_valid/lp_irdy from the Protocol Layer are registered into
//       tx_data_q/tx_valid_q, then driven onto rdi_lp_data/rdi_lp_valid/
//       rdi_lp_irdy. The valid qualify is gated by stall_active: while the
//       stall handshake is in progress, no new data enters the pipeline.
//       When the link has degraded to x8 (rdi_lnk_is_x8), the upper half
//       of rdi_lp_data (bytes 8-15, bits [127:64]) is zeroed so that only
//       lanes 0-7 carry data. This keeps the scoreboard's byte-for-byte
//       comparison clean.
//
//     RDI -> FDI (Receive direction):
//       rdi_pl_data/rdi_pl_valid from the Logical PHY are registered into
//       rx_data_q/rx_valid_q, then driven onto pl_data/pl_valid.
//       pl_trdy reflects rdi_pl_trdy gated by stall_active.
//       pl_stream is a pass-through of lp_stream (the Protocol Layer's
//       stream identifier).
//
//   BYTE / VALID FRAMING (spec 4.1.x):
//     In Raw Mode Format 1, the entire NBYTES*8-bit data bus is valid when
//     lp_valid is asserted. There is no per-byte valid mask; the data bus
//     width is fixed at NBYTES bytes (default 16 = 128 bits for x16
//     Standard Package). The lp_irdy / pl_trdy handshake gates data
//     transfer: a beat is transferred when irdy && trdy && valid.
//
// PARAMETERS
//   NBYTES - Data bus width in bytes. Defaults to ucie_pkg::NBYTES (16).
//            Determines the width of lp_data / pl_data / rdi_lp_data /
//            rdi_pl_data as NBYTES*8 bits. For x16 Standard Package this
//            is 128 bits per UI.
//
// CLOCK / RESET
//   lclk      - Main link clock (1 GHz at 4 GT/s).
//   lreset_n  - Active-low asynchronous reset. Clears all pipeline
//               registers to zero.
//
// PORT NOTES
//   lp_stallack      - Consumed by the stall logic in d2d_adapter.sv, not
//                      by this datapath. The port is kept here so the
//                      wiring matches Table 115. An internal unused_stallack
//                      assignment prevents lint warnings.
//   lp_rx_active_sts - Present on the port list for Table 115 compliance;
//                      not consumed by the datapath (used by FDI SM).
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef AdapterDatapath_SV
`define AdapterDatapath_SV
`include "ucie_pkg.sv"

module adapter_datapath #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,
  input  logic                  lreset_n,

  // Protocol Layer side (FDI)
  input  logic                  lp_irdy,
  input  logic                  lp_valid,
  input  logic [NBYTES*8-1:0]   lp_data,
  input  logic [7:0]            lp_stream,
  input  logic                  lp_stallack,
  input  logic                  lp_rx_active_sts,
  output logic                  pl_trdy,
  output logic                  pl_valid,
  output logic [NBYTES*8-1:0]   pl_data,
  output logic [7:0]            pl_stream,

  // Physical Layer side (RDI)
  output logic                  rdi_lp_irdy,
  output logic                  rdi_lp_valid,
  output logic [NBYTES*8-1:0]   rdi_lp_data,
  input  logic                  rdi_pl_trdy,
  input  logic                  rdi_pl_valid,
  input  logic [NBYTES*8-1:0]   rdi_pl_data,
  input  logic                  rdi_lnk_is_x8,
  input  logic                  stall_active
);

  import ucie_pkg::*;

  // --------------------------------------------------------------------------
  // Pipeline Registers
  // --------------------------------------------------------------------------
  // tx_data_q / tx_valid_q : FDI -> RDI direction. Registered for timing;
  //   the single register stage satisfies the Stage 1+ requirement of
  //   spec 8.1. tx_valid_q captures the conjunction of lp_valid, lp_irdy,
  //   and !stall_active so that a valid beat is only forwarded when the
  //   handshake is complete and the link is not stalled.
  //
  // rx_data_q / rx_valid_q : RDI -> FDI direction. Registered. Captures
  //   rdi_pl_data and rdi_pl_valid unconditionally (the PHY controls when
  //   valid data appears on the RDI).
  // --------------------------------------------------------------------------
  logic [NBYTES*8-1:0] tx_data_q;
  logic                tx_valid_q;

  logic [NBYTES*8-1:0] rx_data_q;
  logic                rx_valid_q;

  // -------------------------------------------------------------------------
  // always_ff: Tx/Rx Pipeline Registers
  //
  // Registers the FDI-to-RDI (Tx) and RDI-to-FDI (Rx) data paths on every
  // rising edge of lclk. On asynchronous reset, all registers are cleared
  // to zero, ensuring no spurious data is driven onto either interface
  // during reset.
  //
  // Tx path (FDI -> RDI):
  //   tx_data_q  <= lp_data (Protocol Layer transmit data).
  //   tx_valid_q <= lp_valid && lp_irdy && !stall_active. The conjunction
  //     ensures that:
  //     (a) The Protocol Layer has valid data (lp_valid).
  //     (b) The Protocol Layer is ready to transfer (lp_irdy).
  //     (c) The stall handshake is not active (datapath unfrozen).
  //   While the PHY is stalled, lp_valid and lp_irdy are held low by the
  //   Protocol Layer (per spec 8.3.1), so the register simply stops moving.
  //
  // Rx path (RDI -> FDI):
  //   rx_data_q  <= rdi_pl_data (Logical PHY receive data).
  //   rx_valid_q <= rdi_pl_valid (Logical PHY receive valid).
  //
  // Spec ref: UCIe 1.0, Section 8.1 (pipeline stage), Section 4.1.x
  //           (byte/valid framing), Section 8.3.1 (stall behaviour).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_data_q  <= '0;
      tx_valid_q <= 1'b0;
      rx_data_q  <= '0;
      rx_valid_q <= 1'b0;
    end else begin
      // While the PHY is stalled, lp_valid and lp_irdy are held low by the
      // Protocol Layer, so the register simply stops moving.
      tx_data_q  <= lp_data;
      tx_valid_q <= lp_valid && lp_irdy && !stall_active;
      rx_data_q  <= rdi_pl_data;
      rx_valid_q <= rdi_pl_valid;
    end
  end

  // -------------------------------------------------------------------------
  // always_comb: Output Multiplexing and x8 Width Degrade
  //
  // Single combinational block driving all datapath outputs. Ensures no
  // multi-driver conflicts.
  //
  // FDI -> RDI outputs:
  //   rdi_lp_irdy  = lp_irdy gated by !stall_active. When stall_active is
  //                  high, the PHY must not see irdy.
  //   rdi_lp_valid = tx_valid_q (registered from FDI handshake).
  //   rdi_lp_data  = tx_data_q (registered FDI transmit data).
  //
  //   x8 width degrade (spec 4.3.4): when rdi_lnk_is_x8 is asserted, the
  //   upper half of the data bus (NBYTES*8-1 downto NBYTES*4, i.e. bits
  //   [127:64] for NBYTES=16) is driven to zero. Only lanes 0-7 (bytes
  //   0-7) carry valid data in x8 mode. The zeroing ensures a clean
  //   byte-for-byte comparison in the verification scoreboard.
  //
  // RDI -> FDI outputs:
  //   pl_valid  = rx_valid_q (registered from RDI).
  //   pl_data   = rx_data_q (registered from RDI).
  //   pl_trdy   = rdi_pl_trdy gated by !stall_active. The Protocol Layer
  //               must not see trdy during a stall.
  //   pl_stream = pass-through of lp_stream (stream identifier is set by
  //               the Protocol Layer and returned unchanged).
  //
  // Spec ref: UCIe 1.0, Section 4.1.x (byte/valid framing), Section 4.3.4
  //           (width degrade), Section 8.3.1 (stall gating).
  // -------------------------------------------------------------------------
  always_comb begin
    // FDI -> RDI
    rdi_lp_irdy  = lp_irdy && !stall_active;
    rdi_lp_valid = tx_valid_q;
    rdi_lp_data  = tx_data_q;

    // x8 width degrade narrows the usable byte field to lanes 0-7 (bytes 0-7).
    // Bytes 8-15 carry no data in that mode and are driven to zero so the
    // scoreboard can verify a clean byte-for-byte compare.
    if (rdi_lnk_is_x8) begin
      rdi_lp_data[NBYTES*8-1:NBYTES*4] = '0;
    end

    // RDI -> FDI
    pl_valid     = rx_valid_q;
    pl_data      = rx_data_q;
    pl_trdy      = rdi_pl_trdy && !stall_active;
    pl_stream    = lp_stream;
  end

  // -------------------------------------------------------------------------
  // assign: Unused lp_stallack Lint Suppression
  //
  // lp_stallack is consumed by the stall handshake logic in d2d_adapter.sv,
  // not by this datapath module. The port is present here so that the
  // wiring matches FDI Table 115. This assign keeps the signal visible to
  // lint tools without generating an unused-port warning.
  //
  // Spec ref: UCIe 1.0, Table 115 - lp_stallack definition.
  // -------------------------------------------------------------------------
  logic unused_stallack;
  assign unused_stallack = lp_stallack;

endmodule

`endif

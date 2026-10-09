// ============================================================================
// Module    : adapter_datapath
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_datapath.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 2.0 - Protocol Layer
//   UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping
//   UCIe 1.0 Specification, Section 4.1.2 - Valid Framing
//   UCIe 1.0 Specification, Section 8.1 - Raw Die-to-Die Interface (RDI)
//   UCIe 1.0 Specification, Section 4.3.7 - Width Degrade in Standard
//                                            Package Interfaces
//   UCIe 1.0 Specification, Section 8.3.1 - Stallreq/Ack Mechanism
//   UCIe 1.0 Specification, Table 114 - RDI signal list
//   UCIe 1.0 Specification, Table 115 - FDI signal list
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
//       rdi_lp_irdy. Valid and ready are gated by stall_active so no buffered
//       beat is visible during ACKED or RELEASED stall phases.
//       When the link has degraded to x8 (rdi_lnk_is_x8), the upper half
//       of rdi_lp_data (bytes 8-15, bits [127:64]) is zeroed so that only
//       lanes 0-7 carry data.
//
//     RDI -> FDI (Receive direction):
//       rdi_pl_data/rdi_pl_valid from the Logical PHY are registered into
//       rx_data_q/rx_valid_q, then driven onto pl_data/pl_valid.
//       pl_trdy is gated by stall_active, and pl_stream passes through.
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
//   lclk      - Main link clock (500 MHz at 4 GT/s).
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
//   v0.0.2  2026-09-22  Update lclk documentation to 500 MHz.
//   v0.0.3  2026-09-23  Documentation: add per-construct comment blocks with
//                        spec references for streaming datapath and stall
//                        handshake gating.
//   v0.0.4  2026-09-23  Documentation: correct header citations. Section 2.1
//                        is "PCIe 6.0", not an architecture overview, so the
//                        reference now points to Section 2.0 Protocol Layer.
//                        Width degrade is Section 4.3.7, not 4.3.4 (which is
//                        Clock and Track Lane remapping).
//   v0.0.5  2026-09-23  Documentation: use the canonical Table 115 title
//   v0.0.6  2026-09-25  Phase D: gate the registered transmit valid output
//                        during both acknowledged and release stall phases.
//   v0.0.7  2026-09-25  Clarify that data registers continue to capture while
//                        output valid and ready gates block stalled transfers.
//   v0.0.8  2026-10-08  Documentation compliance pass: expand construct comment
//                        blocks for elastic registers, multiplexing, and lint
//                        suppression assigns with spec subsection references.
//   v0.0.9  2026-10-09  Documentation and hygiene pass: remove Author column,
//                        add per-port inline comments, and split multi-signal
//                        declarations into one declaration per line.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef AdapterDatapath_SV
`define AdapterDatapath_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module adapter_datapath #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,                  // 500 MHz main link clock
  input  logic                  lreset_n,              // Active-low asynchronous reset

  // Protocol Layer side (FDI)
  input  logic                  lp_irdy,               // Protocol Layer initiator ready (FDI)
  input  logic                  lp_valid,              // Protocol Layer transmit valid (FDI)
  input  logic [NBYTES*8-1:0]   lp_data,               // Protocol Layer transmit data bus (FDI)
  input  logic [7:0]            lp_stream,             // Protocol Layer transmit stream ID (FDI)
  input  logic                  lp_stallack,           // Protocol Layer stall acknowledge (FDI)
  input  logic                  lp_rx_active_sts,      // Protocol Layer RX active status (FDI)
  output logic                  pl_trdy,               // Adapter target ready to Protocol Layer (FDI)
  output logic                  pl_valid,              // Adapter receive valid to Protocol Layer (FDI)
  output logic [NBYTES*8-1:0]   pl_data,               // Adapter receive data bus to Protocol Layer (FDI)
  output logic [7:0]            pl_stream,             // Adapter receive stream ID to Protocol Layer (FDI)

  // Physical Layer side (RDI)
  output logic                  rdi_lp_irdy,           // Adapter initiator ready to Physical Layer (RDI)
  output logic                  rdi_lp_valid,          // Adapter transmit valid to Physical Layer (RDI)
  output logic [NBYTES*8-1:0]   rdi_lp_data,           // Adapter transmit data bus to Physical Layer (RDI)
  input  logic                  rdi_pl_trdy,           // Physical Layer target ready (RDI)
  input  logic                  rdi_pl_valid,          // Physical Layer receive valid (RDI)
  input  logic [NBYTES*8-1:0]   rdi_pl_data,           // Physical Layer receive data bus (RDI)
  input  logic                  rdi_lnk_is_x8,         // Degraded x8 width configuration indicator
  input  logic                  stall_active           // Active stall gating indicator from adapter wrapper
);

  import ucie_pkg::*;

  // --------------------------------------------------------------------------
  // Pipeline Registers
  // --------------------------------------------------------------------------
  // tx_data_q / tx_valid_q : FDI -> RDI direction one-entry elastic stage.
  // Holds data and valid together. While the transfer is blocked (rdi_pl_trdy=0
  // or stall_active=1), the stored tuple is held stable and pl_trdy is de-asserted.
  // A new transfer is accepted from FDI only when empty or simultaneously draining.
  //
  // rx_data_q / rx_valid_q : RDI -> FDI direction registered pipeline stage.
  // --------------------------------------------------------------------------
  logic [NBYTES*8-1:0] tx_data_q;
  logic                tx_valid_q;

  logic [NBYTES*8-1:0] rx_data_q;
  logic                rx_valid_q;

  wire rdi_tx_transfer = rdi_lp_valid && rdi_lp_irdy && rdi_pl_trdy;
  wire tx_ready        = (!tx_valid_q || rdi_tx_transfer) && !stall_active;
  wire fdi_tx_transfer = lp_valid && lp_irdy && pl_trdy;

  // -------------------------------------------------------------------------
  // always_ff: One-entry Elastic Stage & RX Pipeline Register
  //
  // Captures inbound Protocol Layer transmit data into a 1-entry elastic
  // buffer stage (tx_data_q, tx_valid_q) when an FDI transfer occurs, and
  // registers inbound RDI physical receive data (rx_data_q, rx_valid_q).
  // On asynchronous reset (lreset_n == 0), both pipeline registers are
  // cleared to prevent transmitting invalid data.
  //
  // Spec ref: UCIe 1.0 Specification, Section 3.2.1 - Raw Mode Operation;
  //           Section 8.2 - Flit-Aware Die-to-Die Interface (FDI).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_data_q  <= {NBYTES*8{1'b0}};
      tx_valid_q <= 1'b0;
      rx_data_q  <= {NBYTES*8{1'b0}};
      rx_valid_q <= 1'b0;
    end else begin
      if (fdi_tx_transfer) begin
        tx_valid_q <= 1'b1;
        tx_data_q  <= lp_data;
      end else if (rdi_tx_transfer) begin
        tx_valid_q <= 1'b0;
      end

      rx_data_q  <= rdi_pl_data;
      rx_valid_q <= rdi_pl_valid;
    end
  end

  // -------------------------------------------------------------------------
  // always_comb: Output Multiplexing, Degrade Masking, and Stall Gating
  //
  // Drives the RDI transmit data path and FDI receive data path.
  // In the transmit direction, valid and irdy are gated by !stall_active
  // to enforce data quiescing during physical stall handshakes (Section 8.3.1).
  // In x8 width degrade mode, the upper half of the transmit word is masked
  // to zero per Section 4.3.7. In the receive direction, ready is derived
  // from elastic buffer vacancy.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.3.7 - Width Degrade;
  //           Section 8.1 - Raw Die-to-Die Interface (RDI);
  //           Section 8.3.1 - Stall Handshake.
  // -------------------------------------------------------------------------
  always_comb begin
    // FDI -> RDI
    rdi_lp_valid = tx_valid_q && !stall_active;
    rdi_lp_irdy  = tx_valid_q && !stall_active;
    rdi_lp_data  = tx_data_q;

    // x8 width degrade narrows the usable byte field to lanes 0-7.
    if (rdi_lnk_is_x8) begin
      rdi_lp_data[NBYTES*8-1:NBYTES*4] = {NBYTES*4{1'b0}};
    end

    // RDI -> FDI
    pl_trdy      = tx_ready;
    pl_valid     = rx_valid_q;
    pl_data      = rx_data_q;
    pl_stream    = STREAM_ID_S0_STREAMING;
  end

  logic unused_stallack;
  logic [7:0] unused_lp_stream;
  logic unused_rx_active_sts;

  // -------------------------------------------------------------------------
  // assign: Unused lp_stallack Lint Suppression
  //
  // lp_stallack is consumed by the stall handshake logic in d2d_adapter.sv,
  // not by this datapath module. The port is present here so that the
  // wiring matches FDI Table 115. This assign keeps the signal visible to
  // lint tools without generating an unused-port warning.
  //
  // Spec ref: UCIe 1.0, Table 115 - FDI Signal List (lp_stallack definition).
  // -------------------------------------------------------------------------
  assign unused_stallack = lp_stallack;

  // -------------------------------------------------------------------------
  // assign: Unused lp_stream Lint Suppression
  //
  // Stream routing is fixed to STREAM_ID_S0_STREAMING for the single-stack
  // streaming endpoint. This assign consumes the FDI lp_stream input
  // to prevent synthesis and lint tool unused-port warnings.
  //
  // Spec ref: UCIe 1.0, Table 115 - FDI Signal List (lp_stream definition).
  // -------------------------------------------------------------------------
  assign unused_lp_stream = lp_stream;

  // -------------------------------------------------------------------------
  // assign: Unused lp_rx_active_sts Lint Suppression
  //
  // lp_rx_active_sts is consumed by the FDI state machine (fdi_state_machine.sv)
  // for the 4-way Active handshake. This assign consumes the signal in the
  // datapath module to prevent unused-port warnings while maintaining interface parity.
  //
  // Spec ref: UCIe 1.0, Table 115 - FDI Signal List (lp_rx_active_sts definition).
  // -------------------------------------------------------------------------
  assign unused_rx_active_sts = lp_rx_active_sts;

endmodule

`endif

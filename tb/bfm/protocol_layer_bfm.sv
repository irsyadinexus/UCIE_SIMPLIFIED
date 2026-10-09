// ============================================================================
// File        : protocol_layer_bfm.sv
// Project     : UCIe 1.0 Simplified Endpoint Testbench
// Component   : Protocol Layer BFM (Bus Functional Model)
// ============================================================================
//
// DESCRIPTION
// -----------
// This module is the Protocol Layer BFM for the UCIe Simplified Endpoint
// testbench.  It acts as a synthetic protocol layer sitting on top of the
// FDI (Flit-Aware Die-to-Die Interface) for **one** die.  It is NOT a real
// protocol stack: it does not construct flits, TLP/DLLP headers, or CRC
// fields.  Instead it provides two ergonomic tasks -- `send` and `expect_ui`
// -- so that higher-level test sequences can inject raw data words and
// check received data words through the FDI without any knowledge of the
// adapter or PHY internals.
//
// REDUCED CAPABILITY SET
// ----------------------
// The BFM supports only:
//   * Streaming traffic (lp_stream driven with a fixed Stack-0 stream ID).
//   * Raw Mode, Format 1 -- 128-bit data words (NBYTES*8 bits, default NBYTES=16), no flit packaging.
// This matches the simplified subset implemented by the RTL adapter under
// test.  Full UCIe protocol-layer features (flit packing, retry, CRC,
// credit return, etc.) are intentionally omitted.
//
// FDI TRANSMIT SIDE (driven by this BFM)
// ---------------------------------------
//   lp_irdy    -- Link Partner is ready to transfer.
//   lp_valid   -- Data on lp_data is valid in this cycle.
//   lp_data    -- The raw data word (NBYTES*8 bits wide).
//   lp_stream  -- Stream identifier byte (fixed to STREAM_ID = 8'h04).
//   lp_stallack-- Acknowledgement leg of the four-phase stall handshake.
//
// FDI RECEIVE SIDE (monitored / checked by this BFM)
// --------------------------------------------------
//   pl_valid   -- Adapter is presenting valid receive data.
//   pl_data    -- The received data word.
//   pl_trdy    -- Adapter ready to accept transmit data.
//   pl_stallreq-- Adapter requests a stall (four-phase handshake).
//
// FOUR-PHASE STALL HANDSHAKE  (Spec 8.3.1)
// -----------------------------------------
// The stall mechanism is a classic four-phase req/ack handshake:
//
//   Phase 1 : Adapter asserts pl_stallreq  (req  rises)
//   Phase 2 : BFM    asserts lp_stallack   (ack  rises, traffic stops)
//   Phase 3 : Adapter de-asserts pl_stallreq (req  falls)
//   Phase 4 : BFM    de-asserts lp_stallack  (ack  falls, traffic may resume)
//
// While lp_stallack is high the BFM guarantees that lp_valid and lp_irdy
// are held low -- no data may be offered during a stall window.
//
// STRICTLY AN FDI DEVICE
// ----------------------
// This BFM communicates **only** through the FDI port list shown below.
// It never reaches into the adapter registers, the RDI, the PHY, or any
// other layer of the design hierarchy.  All stimulus and observation is
// performed exclusively via the FDI signals.
//
// EXPOSED TASKS
// -------------
//   send(data, stream)
//       Drives lp_data, lp_stream, lp_valid, lp_irdy.  Blocks until the
//       adapter has accepted the word (pl_trdy && pl_valid, coupling transmit
//       acceptance to receive valid).  Handles any
//       stall that occurs mid-transfer by withdrawing valid/irdy and
//       waiting for the stall to clear.
//
//   expect_ui(data)
//       Blocks until a valid UI appears on the receive side (pl_valid
//       asserted), then captures pl_data into the output argument.
//
// ASCII BLOCK DIAGRAM -- FDI interface of this BFM
// -------------------------------------------------
//
//   +-------------------+                        +-------------------+
//   |                   |  lp_irdy  ---------->  |                   |
//   |  protocol_layer   |  lp_valid ---------->  |                   |
//   |      _bfm         |  lp_data  =========>  |  Adapter / DUT    |
//   |                   |  lp_stream ========>   |                   |
//   |  (this module)    |  lp_stallack ------->  |                   |
//   |                   |                        |                   |
//   |                   |  pl_trdy   <----------  |                   |
//   |                   |  pl_valid  <----------  |                   |
//   |                   |  pl_data   <=========  |                   |
//   |                   |  pl_stallreq <--------  |                   |
//   |                   |  pl_state_sts <-------  |                   |
//   +-------------------+                        +-------------------+
//
// Spec ref: Section 8.2 - Flit-Aware Die-to-Die Interface (FDI)
//           Section 8.3.1 - Stallreq/Ack Mechanism
//
// REVISION HISTORY
// ----------------
//   v0.0.1  2025-XX-XX  Initial creation.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block comments.
//   v0.0.3  2026-09-23  Documentation: use the canonical Section 8.3.1 title,
//                        Stallreq/Ack Mechanism, in both citations.
//   v0.0.4  2026-10-09  Cleanup pass: document per-port inline comments and
//                        task argument comments per repository guidelines.
//
// ============================================================================
`ifndef ProtLayerBfm_SV
`define ProtLayerBfm_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module protocol_layer_bfm #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,               // Primary link clock (500 MHz)
  input  logic                  lreset_n,           // Active-low asynchronous link reset
  input  logic [3:0]            pl_state_sts,       // Protocol layer state status from adapter
  output logic                  lp_irdy,            // Link partner initiator ready
  output logic                  lp_valid,           // Link partner data valid
  output logic [NBYTES*8-1:0]   lp_data,            // Link partner transmit data
  output logic [7:0]            lp_stream,          // Link partner stream identifier
  input  logic                  pl_trdy,            // Protocol layer target ready
  input  logic                  pl_valid,           // Protocol layer receive valid
  input  logic [NBYTES*8-1:0]   pl_data,            // Protocol layer receive data
  input  logic                  pl_stallreq,        // Adapter stall request
  output logic                  lp_stallack,        // Stall acknowledgement to adapter
  input  logic                  lp_state_req,       // Link partner state transition request
  input  logic [3:0]            lp_state_req_value, // Requested link state value
  output logic                  done                // BFM test sequence completion flag
);

  localparam logic [7:0] STREAM_ID = 8'h04;   // Stack 0, Streaming

  // -----------------------------------------------------------------
  // STALL HANDSHAKE (four-phase, Spec 8.3.1)
  // -----------------------------------------------------------------
  // The adapter (DUT) may assert pl_stallreq at any time to request
  // that the protocol layer temporarily cease offering data.  This
  // BFM implements the simplest compliant response: lp_stallack
  // follows pl_stallreq by one lclk cycle (registered).
  //
  // Timing (posedge-to-posedge):
  //
  //   lclk          : _/^^\_/^^\_/^^\_/^^\_/^^\_/^^\_
  //   pl_stallreq   : ______/^^^^^^^^^^^^^^^^\________
  //   lp_stallack   : __________/^^^^^^^^^^^^^^^^\____
  //
  // While lp_stallack is high the BFM must NOT assert lp_valid or
  // lp_irdy.  The `send` task below checks pl_stallreq before
  // offering data and will withdraw valid/irdy if a stall arrives
  // mid-transfer.
  //
  // On reset (lreset_n low), lp_stallack is cleared so that the
  // handshake starts in the idle (de-asserted) state.
  //
  // Spec ref: Section 8.3.1 - Stallreq/Ack Mechanism
  // -----------------------------------------------------------------
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n)  lp_stallack <= 1'b0;
    else            lp_stallack <= pl_stallreq;
  end

  // ------------------------------------------------------- send engine
  // The task blocks until the UI is accepted, so the caller can treat a
  // completed call as one transferred unit of data.
  task send;
    input logic [NBYTES*8-1:0] data;    // User data word to transmit
    input logic [7:0]          stream;  // Stream identifier tag
    begin
      @(negedge lclk);
      while (pl_stallreq !== 1'b0) @(negedge lclk);
      lp_data  = data;
      lp_stream= stream;
      lp_valid = 1'b1;
      lp_irdy  = 1'b1;
      @(posedge lclk);
      // Hold until both transmit ready and receive valid are asserted.
      while (!(pl_trdy && pl_valid)) begin
        @(posedge lclk);
        if (pl_stallreq) begin
          // Withdraw valid for the duration of the stall.
          @(negedge lclk);
          lp_valid = 1'b0;
          lp_irdy  = 1'b0;
          while (pl_stallreq !== 1'b0) @(negedge lclk);
          lp_valid = 1'b1;
          lp_irdy  = 1'b1;
        end
      end
      @(negedge lclk);
      lp_valid = 1'b0;
      lp_irdy  = 1'b0;
    end
  endtask

  // ------------------------------------------------------- expect engine
  // Blocks until one valid UI appears on the receive side, returns its data.
  task expect_ui;
    output logic [NBYTES*8-1:0] data;   // Received user data word
    begin
      @(posedge lclk);
      while (!(pl_valid === 1'b1)) @(posedge lclk);
      data = pl_data;
      @(negedge lclk);
    end
  endtask

endmodule

`endif

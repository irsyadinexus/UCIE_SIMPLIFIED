// ============================================================================
// File        : mb_ddr_io.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Scalar mainband DDR launch and capture cell model.
//
// PURPOSE
// ~~~~~~~
// This module is the physical DDR boundary used by both mainband gearboxes.
// One instance represents one data lane or the scalar Valid signal.
// A source clock cycle carries an even UI and an odd UI.
// At 2 GHz, each UI lasts 250 ps and each source cycle lasts 500 ps.
// The module has separate transmit and receive pins.
// It does not infer a receive source from a transmit pad value.
// The caller connects the receive pin to the peer physical channel.
//
// TRANSMIT CONTRACT
// ~~~~~~~~~~~~~~~~~
// The caller presents an even and an odd sample before the rising edge.
// The rising edge captures the odd sample for the following falling edge.
// The rising edge launches the even sample onto the transmit pin.
// The falling edge launches the captured odd sample onto the transmit pin.
// Both launches use nonblocking updates after edge-triggered receive sampling.
// The odd sample therefore survives serializer state changes at the rising edge.
// No combinational clock-phase mux changes a pin before receive sampling.
// tx_oe controls the physical driver, not the internal source clock.
// The pin is high impedance when the driver is disabled.
// The gearboxes export separate pad enables and drive their internal cells.
//
// RECEIVE CONTRACT
// ~~~~~~~~~~~~~~~~
// The falling edge captures the even UI that just ended.
// The next rising edge captures the odd UI that just ended.
// That rising edge also aligns the saved even UI with the odd UI.
// rx_data_hi and rx_data_lo then describe one complete source clock cycle.
// rx_pair_valid marks a pair only after an even UI has been captured.
// A rising-edge consumer reads that pair on its next rising edge.
// This fixed pipeline delay does not alter the word rate or the UI order.
// A stopped receive clock cannot create new pairs.
// Reset invalidates any partial pair even when the receive clock stops.
// The caller supplies a locally synchronized reset release.
//
// CHANNEL TIMING
// ~~~~~~~~~~~~~~
// The simplified digital channel samples each UI at its ending clock edge.
// Transmit updates occur after that edge, so a zero-delay crossed channel is safe.
// Physical implementations must place the sample point inside the data eye.
// This model does not implement delay calibration or duty-cycle correction.
// The accepted environment keeps source rate stable throughout operation.
// Independent die clock phase does not replace the peer forwarded receive clock.
//
// TARGET CELL BOUNDARY
// ~~~~~~~~~~~~~~~~~~~~
// The two-edge transmit process models a dedicated DDR output cell.
// It is not a claim that a generic fabric flip-flop supports two clock edges.
// A silicon implementation must map this boundary to characterized DDR cells.
// The receive registers model a same-edge-pipelined DDR input cell.
// The gearbox state and Gray FIFO remain ordinary single-edge logic.
// No arbitrary simulation delay substitutes for physical clock or data capture.
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
// UCIe 1.0 Section 4.1.1 defines lane bytes and least-significant-bit-first order.
// UCIe 1.0 Section 4.1.2 defines the four-high, four-low Valid pattern.
// UCIe 1.0 Section 5.2 defines the forwarded mainband clock.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-10-09  Initial scalar DDR wrapper.
//   v0.0.2  2026-10-09  Use registered edge launches and real paired captures.
//                       Remove the bidirectional receive fallback.
// ============================================================================

`timescale 1ns/1ps
module mb_ddr_io (
  input  logic clk,           // Local TX clock or physical peer RX clock
  input  logic rst_n,         // Common assertion with local synchronized release
  input  logic tx_data_hi,    // Even UI prepared before the rising edge
  input  logic tx_data_lo,    // Odd UI prepared before the rising edge
  input  logic tx_oe,         // Physical transmit driver enable
  output logic rx_data_hi,    // Captured even UI of the completed pair
  output logic rx_data_lo,    // Captured odd UI of the completed pair
  output logic rx_pair_valid, // A complete captured pair exists
  output wire  pad_tx,        // Observable dedicated transmit pin
  input  logic pad_rx         // Observable dedicated receive pin
);
  logic tx_odd_q;             // Odd UI held across the rising-edge state update
  logic tx_pin_q;             // Dedicated DDR output-cell sample
  logic rx_even_q;            // Even UI captured at the ending falling edge
  logic rx_even_valid_q;      // An even UI exists after reset release

  // Save the odd UI before the serializer advances its state.
  // This register loads with the even UI launch at the rising edge.
  // The following falling edge uses this saved value.
  // The next serializer pair cannot alter the current odd UI.
  // Reset discards any pending transmit half-cycle sample.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) tx_odd_q <= 1'b0;
    else tx_odd_q <= tx_data_lo;
  end

  // Model the dedicated DDR output cell with one owner for the pin register.
  // Each clock edge launches exactly one new physical UI.
  // Nonblocking updates preserve the ending UI during receive edge sampling.
  // The falling edge uses the pair captured at the prior rising edge.
  // Target silicon must replace this cell model with a characterized DDR cell.
  always @(posedge clk or negedge clk or negedge rst_n) begin
    if (!rst_n) tx_pin_q <= 1'b0;
    else if (clk) tx_pin_q <= tx_data_hi;
    else tx_pin_q <= tx_odd_q;
  end

  // Apply the independent physical driver enable to the saved pin sample.
  // The serializer never gates its internal source clock with this enable.
  // A disabled driver presents high impedance on the observable pin.
  // Gearbox output-enable ports control the final external pad drivers.
  // No receive input uses this output as an implicit fallback.
  assign pad_tx = tx_oe ? tx_pin_q : 1'bz;

  // Capture the even UI at the edge that ends its high clock phase.
  // The transmitter changes its pin only after this edge samples the old UI.
  // This rule removes zero-delay clock-phase mux races.
  // The validity register excludes a reset-time partial pair.
  // Reset assertion works even when the physical receive clock stops.
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_even_q <= 1'b0;
      rx_even_valid_q <= 1'b0;
    end else begin
      rx_even_q <= pad_rx;
      rx_even_valid_q <= 1'b1;
    end
  end

  // Capture the odd UI at the edge that ends its low clock phase.
  // Align the previous even sample with this odd sample.
  // A rising-edge gearbox consumes the registered pair one edge later.
  // Pair validity stays a source-domain qualifier, not an lclk output pulse.
  // The RX FIFO converts completed words into exactly-once lclk transfers.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_data_hi <= 1'b0;
      rx_data_lo <= 1'b0;
      rx_pair_valid <= 1'b0;
    end else begin
      rx_data_hi <= rx_even_q;
      rx_data_lo <= pad_rx;
      rx_pair_valid <= rx_even_valid_q;
    end
  end
endmodule

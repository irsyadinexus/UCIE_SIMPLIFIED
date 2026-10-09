// ============================================================================
// File        : mb_tx_clock_ctrl.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Coherent scalar mainband clock and pad controller.
//
// PUBLIC CONTRACT
// ~~~~~~~~~~~~~~~
// lclk carries the LTSM pad-enable and continuous-clock requests.
// mbclk is the independent local 2 GHz source and never stops internally.
// The source must be stable before hardware reset release and remain stable.
// source_ready acknowledges source-domain reset release back into lclk.
// It does not measure frequency, lock, jitter, or source-clock health.
// clock_running acknowledges physical run state back into lclk.
// The output clock does not depend on data or Valid.
// All three physical output-enable ports are scalar.
//
// COHERENT REQUEST MAILBOX
// ~~~~~~~~~~~~~~~~~~~~~~~~
// The lclk domain captures enable and run into one two-bit payload.
// A toggle publishes the stable payload to the source domain.
// Two source-domain registers synchronize the request toggle.
// The source captures the payload only after the synchronized toggle arrives.
// The payload stays unchanged until the source acknowledges physical commitment.
// Two lclk registers synchronize the acknowledgment toggle.
// A later request replaces the payload only after the prior request commits.
// Changes while a request is pending remain visible as the latest input levels.
// The lclk domain publishes those latest levels after acknowledgment.
// run_req cannot enable pads when enable_req is low.
// The LTSM must hold a calibration request until clock_running commits it.
//
// PHYSICAL STATES
// ~~~~~~~~~~~~~~~
// DISABLED parks the clock low and disables clock, data, and Valid drivers.
// PARK parks the clock low and enables clock, data, and Valid drivers.
// RUN enables the same drivers and forwards the continuous source clock.
// The serializer must drive electrical-idle data and Valid while parked.
// A DISABLED-to-RUN request first enters PARK.
// A PARK-to-RUN transition occurs at a later source falling edge.
// The clock and enabled pads therefore stay parked for at least one full cycle.
// One 2 GHz cycle equals the required two-UI precondition.
// A stopped RUN first becomes PARK or DISABLED at a falling edge.
// No request creates a shortened positive pulse.
//
// SAFE RESET AND CLOCK GATE
// ~~~~~~~~~~~~~~~~~~~~~~~~~
// Reset asserts the domain-release synchronizers asynchronously.
// Gate and pad controls change only at source falling edges, including reset.
// A reset during a high pulse lets that pulse reach its natural falling edge.
// The source-clock prerequisite bounds reset shutdown to at most one UI.
// The gate has no asynchronous clear that can cut a high pulse short.
// Source reset release uses two rising edges before normal state changes.
// The clock gate is the source AND a falling-edge gate register.
// A target implementation must map this boundary to a safe clock-gate cell.
//
// ACKNOWLEDGMENT ORDER
// ~~~~~~~~~~~~~~~~~~~~
// A source rising edge observes the committed gate state.
// A running acknowledgment cannot precede the first physical rising pulse.
// A stopped acknowledgment follows the final physical falling pulse.
// Mailbox acknowledgment also waits for this physical run observation.
// Enabled PARK does not pretend that the clock runs.
// Source readiness is independent of all pad and run requests.
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
// UCIe 1.0 Section 5.2 defines the scalar forwarded clock and idle precondition.
// UCIe 1.0 Section 4.1.2 separates Valid framing from clock control.
// UCIe 1.0 Section 8.1.2 defines mainband source and link clock rates.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-10-09  Initial mainband clock controller.
//   v0.0.2  2026-10-09  Implement lclk mailbox, readiness, and scalar pad enables.
//                       Keep PARK enabled and complete reset-time clock pulses.
// ============================================================================

`timescale 1ns/1ps
module mb_tx_clock_ctrl (
  input  logic lclk,           // Link-domain request clock
  input  logic lreset_n,       // Common hardware reset
  input  logic mbclk,          // Stable free-running local 2 GHz source
  input  logic enable_req,     // lclk pad-enable request
  input  logic run_req,        // lclk continuous-clock request
  output logic source_ready,   // lclk source reset-release acknowledgment
  output logic clock_running,  // lclk physical run-state acknowledgment
  output logic mb_tx_clk,      // Scalar forwarded physical clock
  output logic mb_tx_clk_oe,   // Scalar clock pad enable
  output logic mb_tx_data_oe,  // Scalar data pad enable
  output logic mb_tx_valid_oe  // Scalar Valid pad enable
);
  typedef enum logic [1:0] {DISABLED, PARK, RUN} ctrl_state_t;
  (* async_reg = "true" *) logic [1:0] lrelease_q; // Link reset release
  (* async_reg = "true" *) logic [1:0] mbrelease_q; // Source reset release
  logic ldomain_reset_n;                           // Released link-domain reset
  logic mbdomain_reset_n;                          // Released source-domain reset
  logic [1:0] request_payload_q;                   // Bundled enable/run payload
  logic request_toggle_q;                          // Published request token
  (* async_reg = "true" *) logic [1:0] ack_sync_q; // Link acknowledgment ranks
  (* async_reg = "true" *) logic [1:0] request_sync_q; // Source request ranks
  logic [1:0] target_q;                            // Source-owned coherent target
  logic request_seen_q;                            // Captured request token
  logic ack_toggle_q;                              // Physically committed token
  ctrl_state_t state_q;                            // Physical controller state
  logic gate_q;                                   // Falling-edge clock gate
  logic pads_q;                                   // Falling-edge scalar pad enable
  logic physical_running_q;                       // First-pulse/last-stop observation
  (* async_reg = "true" *) logic [1:0] ready_sync_q; // Link readiness ranks
  (* async_reg = "true" *) logic [1:0] running_sync_q; // Link run-state ranks

  // Release link-domain mailbox state after two lclk edges.
  // Hardware reset clears both ranks asynchronously.
  // Source readiness does not substitute for local reset release.
  // All link-domain mailbox registers use the released reset below.
  // This domain remains separate from the physical source clock.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) lrelease_q <= 2'b00;
    else lrelease_q <= {lrelease_q[0], 1'b1};
  end

  // Release source-domain state after two source rising edges.
  // The local source never depends on the forwarded clock gate.
  // A parked or disabled transmitter still completes this release.
  // Hardware reset asserts both ranks without a source edge.
  // The acknowledgment crosses back into lclk independently of run policy.
  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) mbrelease_q <= 2'b00;
    else mbrelease_q <= {mbrelease_q[0], 1'b1};
  end

  // Select the synchronized local link reset.
  // It asserts immediately from hardware reset.
  // It releases on a local rising edge.
  // Mailbox data and toggle state share this reset.
  // No caller-visible source acknowledgment bypasses this release.
  assign ldomain_reset_n = lrelease_q[1];

  // Select the synchronized local source reset.
  // It asserts immediately from hardware reset.
  // It releases after two source rising edges.
  // Physical gate reset still waits for the next safe falling edge.
  // This signal is also the source-ready acknowledgment origin.
  assign mbdomain_reset_n = mbrelease_q[1];

  // Synchronize source acknowledgments into the link domain.
  // Source readiness acknowledges release, not a measured frequency.
  // Physical run state comes from the actual committed clock gate.
  // The mailbox token returns only after the requested state commits.
  // Every crossing has two metastability-containment ranks.
  always_ff @(posedge lclk or negedge ldomain_reset_n) begin
    if (!ldomain_reset_n) begin
      ready_sync_q <= 2'b00;
      running_sync_q <= 2'b00;
      ack_sync_q <= 2'b00;
    end else begin
      ready_sync_q <= {ready_sync_q[0], mbdomain_reset_n};
      running_sync_q <= {running_sync_q[0], physical_running_q};
      ack_sync_q <= {ack_sync_q[0], ack_toggle_q};
    end
  end

  // Publish one coherent request payload at a time.
  // A pending token prevents payload changes before source capture and commit.
  // The latest request levels publish after the current acknowledgment.
  // A disabled pad request always clears the bundled run bit.
  // Initial DISABLED needs no transaction because both domains reset there.
  always_ff @(posedge lclk or negedge ldomain_reset_n) begin
    if (!ldomain_reset_n) begin
      request_payload_q <= 2'b00;
      request_toggle_q <= 1'b0;
    end else if (source_ready && (request_toggle_q == ack_sync_q[1]) &&
                 (request_payload_q != {enable_req, enable_req && run_req})) begin
      request_payload_q <= {enable_req, enable_req && run_req};
      request_toggle_q <= !request_toggle_q;
    end
  end

  // Synchronize the publication token into the free-running source domain.
  // The payload remains stable throughout token synchronization.
  // Capture occurs only after the second token rank changes.
  // This mailbox avoids separate enable and run synchronizer interpretations.
  // Hardware reset discards any in-flight mailbox transaction.
  always_ff @(posedge mbclk or negedge mbdomain_reset_n) begin
    if (!mbdomain_reset_n) begin
      request_sync_q <= 2'b00;
      target_q <= 2'b00;
      request_seen_q <= 1'b0;
    end else begin
      request_sync_q <= {request_sync_q[0], request_toggle_q};
      if (request_sync_q[1] != request_seen_q) begin
        target_q <= request_payload_q;
        request_seen_q <= request_sync_q[1];
      end
    end
  end

  // Observe the gate only at a physical source rising edge.
  // A high observation coincides with a real forwarded rising pulse.
  // A low observation follows the safe falling-edge gate shutdown.
  // The link-domain acknowledgment synchronizes this physical observation.
  // Reset clears the observation but does not truncate the physical gate pulse.
  always_ff @(posedge mbclk or negedge mbdomain_reset_n) begin
    if (!mbdomain_reset_n) physical_running_q <= 1'b0;
    else physical_running_q <= gate_q;
  end

  // Commit pad and gate changes only at source falling edges.
  // A full source cycle separates initial PARK from RUN.
  // PARK keeps every output driver enabled with the clock held low.
  // Reset also waits for this edge, so a high pulse always finishes.
  // Acknowledge a mailbox token only after physical run state matches its target.
  always_ff @(negedge mbclk) begin
    if (!mbdomain_reset_n) begin
      state_q <= DISABLED;
      gate_q <= 1'b0;
      pads_q <= 1'b0;
      ack_toggle_q <= 1'b0;
    end else begin
      if (!target_q[1]) begin
        state_q <= DISABLED;
        gate_q <= 1'b0;
        pads_q <= 1'b0;
      end else begin
        pads_q <= 1'b1;
        case (state_q)
          DISABLED: begin
            state_q <= PARK;
            gate_q <= 1'b0;
          end
          PARK: begin
            gate_q <= target_q[0];
            if (target_q[0]) state_q <= RUN;
          end
          RUN: begin
            gate_q <= target_q[0];
            if (!target_q[0]) state_q <= PARK;
          end
          default: begin
            state_q <= PARK;
            gate_q <= 1'b0;
          end
        endcase
      end
      if ((!target_q[1] && (state_q == DISABLED) && !physical_running_q) ||
          (target_q[1] && !target_q[0] && (state_q == PARK) && !physical_running_q) ||
          (target_q[1] && target_q[0] && (state_q == RUN) && physical_running_q)) begin
        ack_toggle_q <= request_seen_q;
      end
    end
  end

  // Forward the source through the falling-edge gate register.
  // The register stays constant throughout every source high phase.
  // Pad and data-valid request logic never enters this clock expression.
  // Reset cannot asynchronously shorten a forwarded high pulse.
  // Every emitted high pulse has the complete source high half-cycle.
  assign mb_tx_clk = mbclk && gate_q;

  // Expose source reset-release acknowledgment in lclk.
  // The source domain must receive its two release edges first.
  // Two link-domain ranks then contain crossing metastability.
  // This output remains independent of enabled or parked pads.
  // The environment, not this signal, guarantees stable source timing.
  assign source_ready = ready_sync_q[1];

  // Expose acknowledged physical clock run state in lclk.
  // A high value follows the first forwarded source rising pulse.
  // A low value follows safe gate shutdown at a falling edge.
  // Enabled PARK correctly acknowledges a stopped clock.
  // Requesters must wait for this output before calibration responses.
  assign clock_running = running_sync_q[1];

  // The scalar clock driver stays enabled throughout PARK and RUN.
  // DISABLED clears the driver at a safe falling edge.
  // Initial enable precedes RUN by the two-UI parked precondition.
  // The controller never infers clock-driver state from data Valid.
  // A separate physical pin carries the parked or running clock level.
  assign mb_tx_clk_oe = pads_q;

  // The scalar data driver shares the physical pad state.
  // PARK is enabled electrical idle, not high impedance.
  // DISABLED turns the data driver off with the clock driver.
  // The serializer supplies zero data while its permission is low.
  // No per-lane compatibility output-enable vector remains.
  assign mb_tx_data_oe = pads_q;

  // The scalar Valid driver shares the physical pad state.
  // PARK keeps this driver enabled at the electrical-idle level.
  // DISABLED turns it off with the other physical drivers.
  // Valid framing never controls the forwarded clock gate.
  // The serializer must hold Valid low until clock-running acknowledgment.
  assign mb_tx_valid_oe = pads_q;
endmodule

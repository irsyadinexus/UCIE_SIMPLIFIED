// ============================================================================
// File        : ut_mb_clock.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : External-pin tests for mainband clock control and DDR cells.
//
// PURPOSE
// ~~~~~~~
// The controller receives coherent link-domain enable and run requests.
// Its local source runs at 2 GHz and its link clock runs at 500 MHz.
// The test gives these clocks unequal phases.
// Source readiness acknowledges source-domain reset release.
// It does not measure analog lock or clock quality.
// DISABLED must hold all pad enables low.
// PARK must hold the physical clock low with all pad enables high.
// RUN must forward full source pulses with the same pad enables high.
//
// OBSERVABLE CHECKS
// ~~~~~~~~~~~~~~~~~
// The pulse monitor reads only the physical forwarded clock.
// It checks every high pulse, including a reset-time final pulse.
// It checks every low interval against the minimum source half-period.
// A new first pulse must follow at least two UIs of enabled parking.
// A running acknowledgment must follow an observed physical pulse.
// A stopped acknowledgment must correspond to a parked physical clock.
// A disable request must eventually turn off every pad enable.
// The test also restarts the clock after enabled parking.
//
// DDR CELL CHECKS
// ~~~~~~~~~~~~~~~
// A separate scalar cell uses a manually driven physical clock.
// Its transmit pin feeds its receive pin through an ideal physical wire.
// A rising edge launches the even sample and saves the odd sample.
// The test changes the input odd sample before the falling edge.
// The physical pin must still launch the saved odd sample.
// The receive pair must preserve the ending even and odd UIs.
// A disabled driver must present high impedance.
// These checks do not inspect private DDR or controller registers.
//
// LIMITS
// ~~~~~~
// This scalar simulation cannot prove analog eye margin or PLL lock.
// Hardware must map the DDR boundary to characterized physical cells.
// A source must continue through reset so safe shutdown can finish its pulse.
// The clock controller unit test does not claim full electrical training.
// Gearbox and link tests cover complete-word transfer and recovery.
// The watchdog makes every wait bounded in simulation.
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
// UCIe 1.0 Section 4.1.2 defines mainband Valid framing.
// UCIe 1.0 Section 5.2 defines the mainband forwarded clock.
// UCIe 1.0 Section 8.1.2 defines the source and link clock rates.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-10-09  Initial clock and scalar DDR unit test.
//   v0.0.2  2026-10-09  Test coherent requests, enabled PARK, and physical edges.
//                       Remove the obsolete bidirectional pad interface.
//   v0.0.3  2026-10-09  Sweep request-domain phase at exact nominal clock rates.
// ============================================================================
`timescale 1ps/1ps
module ut_mb_clock #(
  parameter integer LCLK_PHASE_PS = 75 // Link phase relative to the nominal source
);
  logic lclk = 1'b0;             // 500 MHz link clock
  logic mbclk = 1'b0;            // 2 GHz local source
  logic lreset_n = 1'b0;         // Common hardware reset
  logic enable_req = 1'b0;       // Pad-enable request
  logic run_req = 1'b0;          // Continuous clock request
  wire source_ready;            // Source reset-release acknowledgment
  wire clock_running;           // Physical run acknowledgment
  wire mb_tx_clk;               // Forwarded physical clock
  wire mb_tx_clk_oe;            // Clock pad enable
  wire mb_tx_data_oe;           // Data pad enable
  wire mb_tx_valid_oe;          // Valid pad enable
  logic io_clk = 1'b0;           // Manual DDR clock
  logic io_reset_n = 1'b0;       // DDR cell reset
  logic io_hi = 1'b0;            // Prepared even UI
  logic io_lo = 1'b0;            // Prepared odd UI
  logic io_oe = 1'b0;            // DDR pad enable
  wire io_pin;                  // Physical loopback data pin
  wire rx_hi;                   // Captured even UI
  wire rx_lo;                   // Captured odd UI
  wire rx_pair_valid;           // Complete receive pair
  integer errors = 0;           // Failed behavioral assertions
  integer rising_pulses = 0;    // Observed physical rising edges
  realtime rise_time = 0;        // Last physical rising edge
  realtime fall_time = 0;        // Last physical falling edge
  realtime pad_enable_time = 0;  // Start of enabled precondition
  logic pulse_open = 1'b0;       // A physical high pulse awaits its falling edge
  logic first_pulse = 1'b1;      // Next physical pulse follows enable

  // Generate the stable local source independently of forwarding policy.
  // Every source high and low phase lasts 250 ps.
  // The source continues through hardware reset and enabled PARK.
  // A safe controller can always finish its final pulse.
  // Spec ref: UCIe 1.0 Section 8.1.2.
  always #250 mbclk = !mbclk;

  // Generate the link clock with a distinct source-relative phase.
  // Requests publish on this clock, not on physical forwarded edges.
  // Each link cycle lasts 2000 ps.
  // The source domain must cross requests and acknowledgments coherently.
  // Spec ref: UCIe 1.0 Section 8.1.2.
  initial begin
    #(LCLK_PHASE_PS);
    forever #1000 lclk = !lclk;
  end

  // Exercise the actual controller interface without response echo logic.
  // All clock assertions inspect the exported physical clock and pad enables.
  // The returned status has the controller's real crossing latency.
  // No private state controls the test's expected pulse widths.
  // Spec ref: UCIe 1.0 Section 5.2.
  mb_tx_clock_ctrl u_ctrl (
    .lclk(lclk), .lreset_n(lreset_n), .mbclk(mbclk),
    .enable_req(enable_req), .run_req(run_req),
    .source_ready(source_ready), .clock_running(clock_running),
    .mb_tx_clk(mb_tx_clk), .mb_tx_clk_oe(mb_tx_clk_oe),
    .mb_tx_data_oe(mb_tx_data_oe), .mb_tx_valid_oe(mb_tx_valid_oe)
  );

  // Use one real scalar DDR cell with an ideal physical loopback wire.
  // The receive pin samples the previously launched physical UI.
  // A manual source gives precise stimulus control before each launch edge.
  // The cell still supplies its own capture and pair-valid pipeline.
  // Spec ref: UCIe 1.0 Sections 4.1.1 and 5.2.
  mb_ddr_io u_io (
    .clk(io_clk), .rst_n(io_reset_n),
    .tx_data_hi(io_hi), .tx_data_lo(io_lo), .tx_oe(io_oe),
    .rx_data_hi(rx_hi), .rx_data_lo(rx_lo), .rx_pair_valid(rx_pair_valid),
    .pad_tx(io_pin), .pad_rx(io_pin)
  );

  // Measure the actual enabled precondition before a first physical pulse.
  // This time begins when the clock pad enable becomes active.
  // A separate new enable starts a fresh first-pulse check.
  // Enabled PARK does not require toggles before a later RUN request.
  // Spec ref: UCIe 1.0 Section 5.2.
  always @(posedge mb_tx_clk_oe) begin
    pad_enable_time = $realtime;
    first_pulse = 1'b1;
  end

  // Check each physical rising edge against pad state and precondition.
  // The next falling edge must complete a full positive half-cycle.
  // A stopped or reset request cannot create a shortened low phase.
  // Pulse counts also prove that run acknowledgment follows real activity.
  // Spec ref: UCIe 1.0 Section 5.2.
  always @(posedge mb_tx_clk) begin
    if (mb_tx_clk === 1'b1) begin
      if (mb_tx_clk_oe !== 1'b1) begin
        $display("FAIL ut_mb_clock: physical pulse has no clock driver enable");
        errors = errors + 1;
      end
      if (first_pulse && ($realtime-pad_enable_time < 500)) begin
        $display("FAIL ut_mb_clock: enabled precondition is shorter than two UIs");
        errors = errors + 1;
      end
      if ((rising_pulses != 0) && ($realtime-fall_time < 250)) begin
        $display("FAIL ut_mb_clock: shortened physical low half-cycle");
        errors = errors + 1;
      end
      first_pulse = 1'b0;
      rise_time = $realtime;
      pulse_open = 1'b1;
      rising_pulses = rising_pulses + 1;
    end
  end

  // Check every natural or reset-time physical falling edge.
  // A high pulse must last exactly one source half-period.
  // Initial X-to-zero parking is not an emitted pulse.
  // The monitor does not disable its checks during reset assertion.
  // Spec ref: UCIe 1.0 Section 5.2.
  always @(negedge mb_tx_clk) begin
    if (pulse_open && ($realtime-rise_time != 250)) begin
      $display("FAIL ut_mb_clock: shortened physical high half-cycle");
      errors = errors + 1;
    end
    pulse_open = 1'b0;
    fall_time = $realtime;
  end

  task automatic check_pads(input logic expected); // Scalar pad-state expectation
    if ({mb_tx_clk_oe, mb_tx_data_oe, mb_tx_valid_oe} !== {3{expected}}) begin
      $display("FAIL ut_mb_clock: scalar pad enables disagree with expected state");
      errors = errors + 1;
    end
  endtask

  initial begin
    repeat (4) @(negedge lclk);
    check_pads(1'b0);
    if ((source_ready !== 1'b0) || (clock_running !== 1'b0)) begin
      $display("FAIL ut_mb_clock: reset exposed a ready or running acknowledgment");
      errors = errors + 1;
    end
    lreset_n = 1'b1;
    wait (source_ready);
    @(negedge lclk);
    enable_req = 1'b1;
    wait (mb_tx_clk_oe);
    repeat (8) @(negedge lclk);
    check_pads(1'b1);
    if ((mb_tx_clk !== 1'b0) || (clock_running !== 1'b0)) begin
      $display("FAIL ut_mb_clock: enabled PARK did not keep its clock stopped");
      errors = errors + 1;
    end
    run_req = 1'b1;
    wait (clock_running);
    if (rising_pulses == 0) begin
      $display("FAIL ut_mb_clock: running acknowledgment preceded physical activity");
      errors = errors + 1;
    end
    repeat (8) @(negedge lclk);
    check_pads(1'b1);
    #89;
    run_req = 1'b0;
    wait (!clock_running);
    #10;
    check_pads(1'b1);
    if (mb_tx_clk !== 1'b0) begin
      $display("FAIL ut_mb_clock: stopped acknowledgment preceded physical parking");
      errors = errors + 1;
    end
    @(negedge lclk);
    run_req = 1'b1;
    wait (clock_running);
    @(posedge mb_tx_clk);
    #37;
    lreset_n = 1'b0;
    @(negedge mbclk);
    #10;
    check_pads(1'b0);
    if (mb_tx_clk !== 1'b0) begin
      $display("FAIL ut_mb_clock: reset failed to stop after the complete final pulse");
      errors = errors + 1;
    end
    repeat (4) @(negedge lclk);
    lreset_n = 1'b1;
    enable_req = 1'b0;
    run_req = 1'b0;
    wait (source_ready);
    repeat (8) @(negedge lclk);
    check_pads(1'b0);

    io_reset_n = 1'b1;
    io_oe = 1'b1;
    io_hi = 1'b1;
    io_lo = 1'b1;
    #100;
    io_clk = 1'b1;
    #10;
    if (io_pin !== 1'b1) begin
      $display("FAIL ut_mb_clock: DDR even UI did not launch");
      errors = errors + 1;
    end
    io_hi = 1'b0;
    io_lo = 1'b0;
    #240;
    io_clk = 1'b0;
    #10;
    if (io_pin !== 1'b1) begin
      $display("FAIL ut_mb_clock: serializer input change corrupted the saved odd UI");
      errors = errors + 1;
    end
    #240;
    io_clk = 1'b1;
    #10;
    if ({rx_pair_valid, rx_hi, rx_lo} !== 3'b111) begin
      $display("FAIL ut_mb_clock: DDR pair did not preserve physical even/odd samples");
      errors = errors + 1;
    end
    io_oe = 1'b0;
    #10;
    if (io_pin !== 1'bz) begin
      $display("FAIL ut_mb_clock: disabled DDR driver did not present high impedance");
      errors = errors + 1;
    end
    if (errors == 0) $display("TEST PASSED ut_mb_clock");
    else $fatal(1, "ut_mb_clock: %0d behavioral failures", errors);
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "ut_mb_clock: bounded clock-state wait expired");
  end
endmodule

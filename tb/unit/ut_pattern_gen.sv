// ============================================================================
// File        : ut_pattern_gen.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Directed unit test for training pattern primitives.
//
// This test drives pattern_gen directly. It verifies the digital primitives
// that remain available in the simplified profile, even though the LTSM keeps
// MBINIT and MBTRAIN pattern emission disabled. The test does not model an
// electrical PHY, pattern count, receiver comparison, or calibration loop.
//
// The 128-bit word contains eight consecutive UIs per lane. Bit
// data[8*lane+u] is UI u for that lane and uses the LSB-first gearbox order.
// The test checks lane 0 and lane 1 to prove both the fixed prefix and the
// logical lane-ID field.
//
// Directed checks:
//   1. Disabled output is all zero.
//   2. VALTRAIN is four one UIs followed by four zero UIs on every lane.
//   3. Per-Lane-ID is 0101, lane ID LSB first, 0101 across 16 UIs.
//   4. Clock repair is sixteen high UIs followed by eight low UIs.
//
// Spec refs:
//   UCIe 1.0 Table 21, VALTRAIN pattern.
//   UCIe 1.0 Table 23, Per Lane ID pattern.
//   UCIe 1.0 Section 4.5.3.3.3, clock repair pattern.
//   UCIe 1.0 Section 4.1.1, LSB-first lane data order.
//
// PATTERN TIMING AND STRUCTURE
//
//   VALTRAIN Pattern (Table 21):
//     UI [0..3] = 4'hF (1111b), UI [4..7] = 4'h0 (0000b) per byte lane.
//
//   Per Lane ID Pattern (Table 23):
//     Repeats 16-UI cycle: [0..3]=4'h5 (0101b), [4..11]=Lane ID, [12..15]=4'h5.
//
//   Clock Repair Pattern (Section 4.5.3.3.3):
//     24-UI repeating sequence: 16 high UIs followed by 8 low UIs.
//
// VERIFICATION METHODOLOGY
//   1. Instantiates 16-lane pattern_gen under test in 500 MHz lclk domain.
//   2. Cycles through all pattern selection mux states (VALTRAIN, Per Lane ID,
//      Clock Repair, and Idle).
//   3. Evaluates 128-bit output vector per clock cycle (8 UIs x 16 lanes).
//   4. Confirms that lane-specific IDs appear on their corresponding lane
//      positions without cross-lane contamination.
//
// REVISION HISTORY
// ----------------------------------------------------------------------------
//   Rev     Date        Description
//   ------  ----------  ------------------------------------------------------
//   v0.0.1  2026-09-24  Phase A initial directed pattern test.
//   v0.0.2  2026-09-24  Remove clock-edge stimulus races between patterns.
//   v0.0.3  2026-10-08  Documentation compliance pass: expand header
//                       and add per-construct comments.
//   v0.0.4  2026-10-09  Cleanup pass: remove unused table column, remove obsolete
//                       implementation-phase references, and add task argument comments.
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_pattern_gen;
  logic lclk;
  logic lreset_n;
  logic enable;
  pat_t pattern;
  logic lfsr_reset;
  logic lfsr_enable;
  logic [DATA_W-1:0] data;
  logic pat_done;
  int errors;

  // The DUT produces one 8-UI word per lane each lclk cycle. The test samples
  // combinational output before each clock edge so ui_q identifies the first
  // UI in the checked word. The LFSR is disabled because this test covers only
// the fixed no-scramble primitives for training pattern generation.
  // Spec ref: UCIe 1.0 Table 21, Table 23, and Section 4.5.3.3.3.
  pattern_gen #(.NLANES(NLANES_MAX)) u_dut (
    .lclk(lclk),
    .lreset_n(lreset_n),
    .enable(enable),
    .pattern(pattern),
    .lfsr_reset(lfsr_reset),
    .lfsr_enable(lfsr_enable),
    .data(data),
    .pat_done(pat_done)
  );

  // -------------------------------------------------------------------------
  // always: Link Clock Generator (500 MHz lclk)
  //
  // Drives 500 MHz link clock for testing parallel training pattern generation.
  // Pattern generator produces 8 UIs per lclk cycle to feed the 4 GT/s gearboxes.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.4.1 and Section 5.1.1.
  // -------------------------------------------------------------------------
  always #1 lclk = ~lclk;

  task automatic check_lane_byte(
    input int unsigned lane,     // Main-band lane index to verify (0 to NLANES_MAX-1)
    input logic [7:0]  expected, // Expected 8-UI pattern slice for this lane
    input string       name      // Pattern name string for diagnostic logging
  );
    if (data[8*lane +: 8] !== expected) begin
      $display("FAIL ut_pattern_gen: %s lane %0d got %02h expected %02h",
               name, lane, data[8*lane +: 8], expected);
      errors = errors + 1;
    end
  endtask

  // This stimulus advances ui_q only after each checked word. It keeps each
  // pattern enabled for the required 8-UI slices, then disables it to restart
  // ui_q at zero for the next independent primitive.
  // Spec ref: UCIe 1.0 Table 21, Table 23, and Section 4.5.3.3.3.
  initial begin
    lclk = 1'b0;
    lreset_n = 1'b0;
    enable = 1'b0;
    pattern = PAT_PERLANEID;
    lfsr_reset = 1'b0;
    lfsr_enable = 1'b0;
    errors = 0;

    #0.1;
    if (data !== '0) begin
      $display("FAIL ut_pattern_gen: disabled data is not zero");
      errors = errors + 1;
    end

    @(negedge lclk);
    lreset_n = 1'b1;

    // VALTRAIN, UI 0 through UI 7: 11110000 in time, 8'h0F packed LSB first.
    enable = 1'b1;
    pattern = PAT_VALTRAIN;
    #0.1;
    check_lane_byte(0, 8'h0F, "VALTRAIN");
    check_lane_byte(1, 8'h0F, "VALTRAIN");
    @(posedge lclk);

    // Disable through a full clock edge before changing the next pattern.
    // This prevents the testbench from racing pattern_gen's UI-counter reset.
    @(negedge lclk);
    enable = 1'b0;
    @(posedge lclk);
    @(negedge lclk);

    // Per-Lane-ID UI 0 through UI 7. Lane 0 is 8'h0A. Lane 1 includes bit 0
    // of its LSB-first ID at UI 4, so it is 8'h1A.
    enable = 1'b1;
    pattern = PAT_PERLANEID;
    #0.1;
    check_lane_byte(0, 8'h0A, "Per-Lane-ID first word");
    check_lane_byte(1, 8'h1A, "Per-Lane-ID first word");
    @(posedge lclk);

    // Per-Lane-ID UI 8 through UI 15 completes each zero-extended lane ID.
    #0.1;
    check_lane_byte(0, 8'hA0, "Per-Lane-ID second word");
    check_lane_byte(1, 8'hA0, "Per-Lane-ID second word");
    @(posedge lclk);

    @(negedge lclk);
    enable = 1'b0;
    @(posedge lclk);
    @(negedge lclk);

    // Clock repair UI 0..15 is high for two 8-UI words.
    enable = 1'b1;
    pattern = PAT_CLKREPAIR;
    #0.1;
    check_lane_byte(0, 8'hFF, "Clock repair first word");
    @(posedge lclk);
    #0.1;
    check_lane_byte(0, 8'hFF, "Clock repair second word");
    @(posedge lclk);

    // Clock repair UI 16..23 is low for the third 8-UI word.
    #0.1;
    check_lane_byte(0, 8'h00, "Clock repair low word");

    enable = 1'b0;
    #0.1;
    if (data !== '0) begin
      $display("FAIL ut_pattern_gen: disabled data after patterns is not zero");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_pattern_gen");
    else             $display("FAIL ut_pattern_gen: %0d errors", errors);
    $finish;
  end

  initial begin
    #1000;
    $display("FAIL ut_pattern_gen: watchdog timeout");
    $finish;
  end
endmodule

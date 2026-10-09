// ============================================================================
// File        : ut_mb_async_fifo.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit Test for Main-Band Asynchronous Clock Crossing FIFO
//               (mb_async_fifo).
//
// PURPOSE
// ~~~~~~~
// This testbench provides deterministic, external-pin-based verification of
// the mb_async_fifo module. It operates strictly through top-level DUT pins
// to verify:
//   1. Common reset assertion and per-domain release across asynchronous clock
//      domains (wclk at 500 MHz and rclk at 800 MHz), including reset write
//      rejection.
//   2. Depth-eight full rejection without overwriting the FIFO head, followed
//      by ordered head-to-tail reads.
//   3. Underflow detection after the FIFO becomes empty.
//   4. Pointer flush after reset assertion, with stale queued words discarded.
//   5. Forty asynchronous wrap words transferred with scoreboard verification.
//
// TESTBENCH ARCHITECTURE
// ~~~~~~~~~~~~~~~~~~~~~~
// The testbench instantiates one mb_async_fifo DUT (128-bit word, depth 8)
// with two asynchronous clock generators (wclk = 500 MHz, rclk = 800 MHz).
// All stimuli are applied and verified on synchronous clock edges with small
// non-zero settling delays.
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
//   UCIe 1.0 Section 4.1.2 - Valid Framing and Word Datapath
//   UCIe 1.0 Section 5.2   - Forwarded Clock (fCK) Signaling
//   UCIe 1.0 Section 8.1.2 - Interface Clocking and CDC Requirements
//
// VERIFICATION ENVIRONMENT NOTES
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Deterministic stimulus and edge synchronization checks.
// Clocks are phase-independent and frequency-asymmetric.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-10-09  Initial creation of external-pin based unit test for
//                       depth-8 Gray asynchronous FIFO with coordinated reset
//                       assertion, per-domain release, and edge behavior tests.
//   v0.0.2  2026-10-09  Documentation compliance pass: expand header length
//                       and add dedicated construct comments for clock drivers.
//   v0.0.3  2026-10-09  Drive requests away from the acceptance edge.
//                       Compare the readable head before each accepted read.
//                       Cover reset write rejection, full order, and wrap.
// ============================================================================

`include "ucie_pkg.sv"
`timescale 1ns/1ps

module ut_mb_async_fifo;
  import ucie_pkg::*;

  localparam int unsigned DATA_W = 128;              // 128-bit mainband word width
  localparam int unsigned DEPTH  = 8;                // 8-entry buffer depth

  // -------------------------------------------------------------------------
  // Signal declarations (one per line with inline comments)
  // -------------------------------------------------------------------------
  logic              wclk;                           // 500 MHz write domain clock
  logic              wrst_n;                         // Write domain active-low reset
  logic              winc;                           // Write push strobe
  logic [DATA_W-1:0] wdata;                          // Write payload data
  wire               wfull;                          // FIFO full indicator
  wire               walmost_full;                   // Almost full indicator
  wire               woverflow;                      // Sticky overflow error flag
  wire               woverflow_pulse;                // Single-cycle overflow strobe

  logic              rclk;                           // 800 MHz read domain clock
  logic              rrst_n;                         // Read domain active-low reset
  logic              rinc;                           // Read pop strobe
  wire [DATA_W-1:0]  rdata;                          // Read payload data
  wire               rempty;                         // FIFO empty indicator
  wire               rvalid;                         // Read valid indicator
  wire               runderflow;                     // Single-cycle underflow strobe

  int                errors;                         // Shared error counter
  int                tc_errors;                      // Test-case error counter

  // -------------------------------------------------------------------------
  // initial: Initial Value Assignment for wclk
  //
  // Sets initial phase of the 500 MHz link clock to logic zero at simulation
  // time zero before free-running oscillation starts.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2 - Interface clocking.
  // -------------------------------------------------------------------------
  initial begin
    wclk = 1'b0;
  end

  // -------------------------------------------------------------------------
  // always: wclk 500 MHz Square Wave Generator
  //
  // Inverts clock state every 1.00 ns to produce a 50 % duty-cycle 500 MHz
  // square-wave link clock for parallel word write operations.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2 - Interface Clocking.
  // -------------------------------------------------------------------------
  always #1.00 wclk = ~wclk;

  // -------------------------------------------------------------------------
  // initial: Initial Value Assignment for rclk
  //
  // Sets initial phase of the 800 MHz read clock to logic zero at simulation
  // time zero before free-running oscillation starts.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded clock CDC.
  // -------------------------------------------------------------------------
  initial begin
    rclk = 1'b0;
  end

  // -------------------------------------------------------------------------
  // always: rclk 800 MHz Square Wave Generator
  //
  // Inverts clock state every 0.625 ns to produce a 50 % duty-cycle 800 MHz
  // square-wave clock for asynchronous FIFO read verification.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded Clock CDC.
  // -------------------------------------------------------------------------
  always #0.625 rclk = ~rclk;

  // -------------------------------------------------------------------------
  // Module instantiation: mb_async_fifo u_dut (Device Under Test)
  //
  // Instantiates the 8-entry conventional Gray asynchronous FIFO under test.
  // Bridges 128-bit words across 500 MHz wclk and 800 MHz rclk.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Datapath.
  // -------------------------------------------------------------------------
  mb_async_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(DEPTH)
  ) u_dut (
    .wclk            (wclk),
    .wrst_n          (wrst_n),
    .winc            (winc),
    .wdata           (wdata),
    .wfull           (wfull),
    .walmost_full    (walmost_full),
    .woverflow       (woverflow),
    .woverflow_pulse (woverflow_pulse),
    .rclk            (rclk),
    .rrst_n          (rrst_n),
    .rinc            (rinc),
    .rdata           (rdata),
    .rempty          (rempty),
    .rvalid          (rvalid),
    .runderflow      (runderflow)
  );

  // -------------------------------------------------------------------------
  // Helper function to generate unique 128-bit test patterns
  // -------------------------------------------------------------------------
  function automatic logic [DATA_W-1:0] mk_word(
    input int unsigned id                           // Pattern sequence identifier
  );
    logic [DATA_W-1:0] val;                         // Computed test word
    begin
      val = '0;
      for (int i = 0; i < 16; i = i + 1) begin
        val[i*8 +: 8] = 8'hA0 + i[7:0] + id[7:0];
      end
      mk_word = val;
    end
  endfunction

  task automatic push_word(input int id); // Unique payload identifier
    @(negedge wclk);
    while (wfull) @(negedge wclk);
    wdata = mk_word(id);
    winc = 1'b1;
    @(negedge wclk);
    winc = 1'b0;
  endtask

  task automatic pop_word(input int id); // Expected head payload identifier
    @(negedge rclk);
    while (!rvalid) @(negedge rclk);
    if (rdata !== mk_word(id)) begin
      $display("FAIL ut_mb_async_fifo: head %0d got %032h expected %032h",id,rdata,mk_word(id));
      errors = errors+1;
    end
    rinc = 1'b1;
    @(negedge rclk);
    rinc = 1'b0;
  endtask

  initial begin
    errors = 0;
    wrst_n = 1'b0;
    rrst_n = 1'b0;
    winc = 1'b0;
    rinc = 1'b0;
    wdata = '0;
    repeat (4) @(negedge wclk);
    wrst_n = 1'b1;
    // One asserted domain reset must hold both pointers and reject writes.
    push_word(900);
    repeat (4) @(negedge rclk);
    if (rvalid || !rempty || wfull) begin
      $display("FAIL ut_mb_async_fifo: independent reset release exposed a word");
      errors = errors+1;
    end
    rrst_n = 1'b1;
    repeat (4) @(negedge wclk);
    push_word(1);
    pop_word(1);
    if (rvalid || !rempty) begin
      $display("FAIL ut_mb_async_fifo: isolated word repeated after its consume edge");
      errors = errors+1;
    end

    // Fill the queue and prove a rejected write cannot overwrite its head.
    for (int k = 0; k < DEPTH; k = k+1) push_word(20+k);
    @(negedge wclk);
    if (!wfull) begin
      $display("FAIL ut_mb_async_fifo: eight accepted words did not fill the queue");
      errors = errors+1;
    end
    wdata = mk_word(999);
    winc = 1'b1;
    @(negedge wclk);
    winc = 1'b0;
    if (!woverflow || !woverflow_pulse) begin
      $display("FAIL ut_mb_async_fifo: full write did not report rejection");
      errors = errors+1;
    end
    for (int k = 0; k < DEPTH; k = k+1) pop_word(20+k);
    @(negedge rclk);
    rinc = 1'b1;
    @(negedge rclk);
    rinc = 1'b0;
    if (!runderflow || rvalid) begin
      $display("FAIL ut_mb_async_fifo: empty read did not report rejection");
      errors = errors+1;
    end

    // Assertion from only one reset pin discards both-domain queued words.
    repeat (4) @(negedge wclk);
    push_word(50);
    push_word(51);
    wrst_n = 1'b0;
    #0.010;
    if (rvalid || !rempty) begin
      $display("FAIL ut_mb_async_fifo: coordinated assertion retained a stale head");
      errors = errors+1;
    end
    repeat (4) @(negedge wclk);
    wrst_n = 1'b1;
    repeat (4) @(negedge wclk);
    push_word(52);
    pop_word(52);

    // Concurrent asynchronous transfers wrap both pointers several times.
    fork
      begin
        for (int k = 0; k < 40; k = k+1) push_word(100+k);
      end
      begin
        for (int k = 0; k < 40; k = k+1) pop_word(100+k);
      end
    join
    repeat (4) @(negedge rclk);
    if (rvalid || !rempty || woverflow) begin
      $display("FAIL ut_mb_async_fifo: asynchronous wrap left a duplicate or overflow");
      errors = errors+1;
    end
    if (errors == 0) $display("TEST PASSED ut_mb_async_fifo");
    else $fatal(1,"ut_mb_async_fifo: %0d behavioral failures",errors);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1,"ut_mb_async_fifo: bounded transfer wait expired");
  end
endmodule

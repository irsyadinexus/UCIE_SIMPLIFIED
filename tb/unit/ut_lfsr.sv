// Unit test: scrambler (per-lane LFSR) and ucie_timer.
// Directed checks against a software reference model.
`timescale 1ns/1ps
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ut_lfsr;
  logic        lclk, lreset_n;
  logic        data_out;
  logic [22:0] state_obs;
  logic        lfsr_reset, enable;

  logic        tclk, treset_n, tstart, trun, texpired;
  int          errors;
  logic [22:0] ref_state;
  logic        ref_bit;

  logic        exp_data_bit;

  scrambler #(.LANE_ID(3)) u_dut (
    .lclk      (lclk),
    .lreset_n  (lreset_n),
    .lfsr_reset(lfsr_reset),
    .enable    (enable),
    .data_in   (1'b0),
    .data_out  (data_out),
    .state_obs (state_obs)
  );

  initial lclk = 1'b0;
  always #1 lclk = ~lclk;

  // LIMIT_CYCLES = 8 ticks, DIV = 4, so one tick per 4 tclk edges: expiry is
  // at the 32nd edge after a clean start.
  ucie_timer #(.LIMIT_CYCLES(8), .DIV(4)) u_timer (
    .clk     (tclk),
    .reset_n (treset_n),
    .start   (tstart),
    .running (trun),
    .expired (texpired)
  );

  initial tclk = 1'b0;
  always #2 tclk = ~tclk;

  // Reference: G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1.
  task step_ref;
    begin
      ref_bit   = ^(ref_state & LFSR_TAPS);
      ref_state = {ref_bit, ref_state[22:1]};
    end
  endtask

  initial begin
    errors     = 0;
    lfsr_reset = 1'b1;
    enable     = 1'b0;
    treset_n   = 1'b0;
    tstart     = 1'b0;
    trun       = 1'b0;
    lreset_n   = 1'b0;
    #2;
    lreset_n   = 1'b1;
    treset_n   = 1'b1;

    // 1. Seed reload yields the documented lane-3 seed.
    @(negedge lclk);
    lfsr_reset = 1'b0;
    @(posedge lclk); #0.1;
    if (state_obs !== ucie_pkg::lfsr_seed(3)) begin
      $display("FAIL ut_lfsr: seed mismatch, got %h exp %h",
               state_obs, ucie_pkg::lfsr_seed(3));
      errors = errors + 1;
    end

    // 2. Twenty steps match the reference polynomial. The DUT advances on the
    // edge, so the reference steps after it and is then compared.
    ref_state = state_obs;
    enable    = 1'b1;
    repeat (20) begin
      // data_out is registered: it shows the bit that sat at lfsr_q[0]
      exp_data_bit = ref_state[0];
      @(posedge lclk);
      #0.1;
      step_ref;
      if (state_obs !== ref_state) begin
        $display("FAIL ut_lfsr: state step mismatch, got %h exp %h",
                 state_obs, ref_state);
        errors = errors + 1;
      end
      if (data_out !== exp_data_bit) begin
        $display("FAIL ut_lfsr: data_out mismatch, got %b exp %b",
                 data_out, exp_data_bit);
        errors = errors + 1;
      end
    end

    // 3. Disabled: the state holds.
    enable = 1'b0;
    @(negedge lclk);
    ref_state = state_obs;
    repeat (5) @(posedge lclk);
    #0.1;
    if (state_obs !== ref_state) begin
      $display("FAIL ut_lfsr: state moved while disabled");
      errors = errors + 1;
    end

    // 4. Timer: 8 ticks of 4 edges. Expired must stay 0 through 31 edges and
    // pulse on the 32nd.
    @(negedge tclk);
    tstart = 1'b1;
    trun   = 1'b1;
    @(posedge tclk);                 // edge 0: start is sampled
    @(negedge tclk);
    tstart = 1'b0;                   // deassert between edges: no race
    repeat (31) @(posedge tclk);     // edges 1..31
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: timer expired early");
      errors = errors + 1;
    end
    @(posedge tclk);                 // edge 32
    #0.1;
    if (texpired !== 1'b1) begin
      $display("FAIL ut_lfsr: timer did not expire at LIMIT_CYCLES");
      errors = errors + 1;
    end

    // 5. Not running holds the count; a restart reloads it.
    @(negedge tclk);
    trun   = 1'b0;
    repeat (4) @(posedge tclk);
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: expired held while not running");
      errors = errors + 1;
    end
    @(negedge tclk);
    tstart = 1'b1;
    @(posedge tclk);
    @(negedge tclk);
    tstart = 1'b0;
    trun   = 1'b1;
    repeat (31) @(posedge tclk);
    #0.1;
    if (texpired !== 1'b0) begin
      $display("FAIL ut_lfsr: restart did not reload the count");
      errors = errors + 1;
    end
    @(posedge tclk);
    #0.1;
    if (texpired !== 1'b1) begin
      $display("FAIL ut_lfsr: restart did not expire on time");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_lfsr");
    else             $display("FAIL ut_lfsr: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL ut_lfsr: watchdog timeout");
    $finish;
  end

endmodule

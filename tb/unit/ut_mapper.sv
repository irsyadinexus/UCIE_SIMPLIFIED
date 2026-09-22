// Unit test: byte_lane_mapper. Exercises x16, both x8-degrade halves, the
// inactive-half zeroing, byte reversal, and the enable gate.
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_mapper;
  logic        lclk, lreset_n;
  logic        enable;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;
  logic        byte_reversal;
  logic [NBYTES-1:0][7:0] bytes_in;
  logic [NLANES_MAX-1:0][7:0] data_out;
  int          errors;
  integer fd;

  byte_lane_mapper #(.NLANES(NLANES_MAX)) u_dut (
    .lclk(lclk), .lreset_n(lreset_n), .enable(enable),
    .lnk_is_x8(lnk_is_x8), .degrade_lanes(degrade_lanes),
    .byte_reversal(byte_reversal),
    .bytes_in(bytes_in), .data_out(data_out)
  );

  initial lclk = 1'b0;
  always #1.0 lclk = ~lclk;

  task chk_lane;
    input int        lane;
    input [7:0]      exp;
    input [64*8-1:0] label;
    begin
      if (data_out[lane] !== exp) begin
        $display("FAIL ut_mapper: %s lane %0d: got %02h want %02h",
                 label, lane, data_out[lane], exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    lreset_n     = 1'b0;
    enable       = 1'b0;
    lnk_is_x8    = 1'b0;
    degrade_lanes= 2'b00;
    byte_reversal= 1'b0;
    bytes_in     = '0;

    #5 lreset_n = 1'b1;
    @(negedge lclk);

    // Disabled: every lane reads zero.
    enable = 1'b0;
    for (int i = 0; i < NLANES_MAX; i = i + 1)
      bytes_in[i] = 8'hFF;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'h00, "disabled");

    // x16: lane l carries byte l.
    enable = 1'b1;
    lnk_is_x8 = 1'b0;
    for (int i = 0; i < NBYTES; i = i + 1)
      bytes_in[i] = 8'hA0 + i;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'hA0 + i, "x16");

    // x16 with byte reversal: lane l carries byte NBYTES-1-l.
    byte_reversal = 1'b1;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'hA0 + (NBYTES-1-i), "x16 rev");
    byte_reversal = 1'b0;

    // x8 degrade to lanes 0-7: lower half keeps bytes 0-7, upper half zeros.
    lnk_is_x8 = 1'b1;
    degrade_lanes = DEGRADE_LANES_0_7;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_X8; i = i + 1)
      chk_lane(i, 8'hA0 + i, "x8 lo");
    for (int i = NLANES_X8; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'h00, "x8 lo zero");

    // x8 degrade to lanes 8-15: upper half carries bytes 0-7, lower zeros.
    degrade_lanes = DEGRADE_LANES_8_15;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_X8; i = i + 1)
      chk_lane(i, 8'h00, "x8 hi zero");
    for (int i = NLANES_X8; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'hA0 + (i - NLANES_X8), "x8 hi");

    // x8 with byte reversal on the surviving half.
    degrade_lanes = DEGRADE_LANES_0_7;
    byte_reversal = 1'b1;
    repeat (2) @(posedge lclk);
    for (int i = 0; i < NLANES_X8; i = i + 1)
      chk_lane(i, 8'hA0 + (NBYTES-1-i), "x8 lo rev");
    byte_reversal = 1'b0;

    // An undefined degrade select must not produce active lanes in the
    // upper half: the reserved code leaves the lower half selected only.
    degrade_lanes = 2'b11;
    repeat (2) @(posedge lclk);
    for (int i = NLANES_X8; i < NLANES_MAX; i = i + 1)
      chk_lane(i, 8'h00, "x8 reserved upper zero");
    // The loopback is x16-only and never degrades, so this test is the only
    // place the degrade halves and byte reversal run. Write the evidence
    // file the coverage report merges with the loopback JSON.
    if (errors == 0) begin
      fd = $fopen("logs/mapper_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{ \"width_degrade\": 2, \"lane_reversal\": 2 }\n");
        $fclose(fd);
      end
    end
    if (errors == 0) $display("TEST PASSED ut_mapper");
    else             $display("FAIL ut_mapper: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_mapper: watchdog");
    $finish;
  end

endmodule

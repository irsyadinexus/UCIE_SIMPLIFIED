// UCIe 1.0 Simplified Endpoint - spec timer
// True to spec: 8 ms residency, 4 ms RESET minimum, 8 ms message timeout.
// README forbids faster simulation timers. The DIV parameter is testbench-only:
// unit tests divide the clock to exercise the timeout path without editing the
// spec interval. RTL instantiations use the default 1.
`ifndef UcieTimer_SV
`define UcieTimer_SV
`include "ucie_pkg.sv"

module ucie_timer #(
  parameter int unsigned LIMIT_CYCLES = ucie_pkg::C_RESIDENCY,  // 8 ms
  parameter int unsigned DIV          = 1                      // testbench-only
) (
  input  logic   clk,
  input  logic   reset_n,
  input  logic   start,      // (re)start the interval
  input  logic   running,    // 1 while the interval is active
  output logic   expired     // 1 in the cycle LIMIT_CYCLES elapses
);

  import ucie_pkg::*;

  localparam int unsigned DIV_W = 32;

  logic [DIV_W-1:0] div_q;
  logic [DIV_W-1:0] cnt_q;
  logic             tick;

  // Clock divider; DIV = 1 means every edge is a tick.
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n)        div_q <= '0;
    else if (start)      div_q <= '0;
    else if (tick)       div_q <= '0;
    else if (DIV > 1)    div_q <= div_q + 1'b1;
  end

  assign tick = (DIV <= 1) || (div_q == (DIV - 1));

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      cnt_q    <= '0;
      expired  <= 1'b0;
    end else if (start) begin
      cnt_q    <= '0;
      expired  <= 1'b0;
    end else if (!running) begin
      // Spec 4.5.3: Stall resets the requester timer. Holding the count while
      // the interval is inactive implements that without clearing the count,
      // because start reloads it explicitly on every entry.
      expired  <= 1'b0;
    end else if (tick) begin
      if (cnt_q == (LIMIT_CYCLES - 1)) begin
        cnt_q   <= cnt_q;           // saturate
        expired <= 1'b1;            // pulse in the cycle of expiry
      end else begin
        cnt_q   <= cnt_q + 1'b1;
        expired <= 1'b0;
      end
    end else begin
      expired <= 1'b0;
    end
  end

endmodule

`endif

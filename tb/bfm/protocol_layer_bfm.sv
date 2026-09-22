// UCIe 1.0 Simplified Endpoint - Protocol Layer BFM.
//
// Reduced capability set: Streaming only, Raw Mode (Format 1). The BFM plays
// the protocol layer for one die. It drives the FDI transmit side and checks
// the FDI receive side. It is a loopback partner, not a real protocol stack:
// it does not build flits or headers.
//
// The BFM is strictly an FDI device. It never reaches into the adapter or the
// PHY. Stall is honoured by waiting for pl_stallreq to fall before offering
// the next UI, per spec 8.3.1.
`ifndef ProtLayerBfm_SV
`define ProtLayerBfm_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module protocol_layer_bfm #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,
  input  logic                  lreset_n,
  input  logic [3:0]            pl_state_sts,
  output logic                  lp_irdy,
  output logic                  lp_valid,
  output logic [NBYTES*8-1:0]   lp_data,
  output logic [7:0]            lp_stream,
  input  logic                  pl_trdy,
  input  logic                  pl_valid,
  input  logic [NBYTES*8-1:0]   pl_data,
  input  logic                  pl_stallreq,
  output logic                  lp_stallack,
  input  logic                  lp_state_req,
  input  logic [3:0]            lp_state_req_value,
  output logic                  done
);

  localparam logic [7:0] STREAM_ID = 8'h04;   // Stack 0, Streaming

  // ------------------------------------------------------- stall handshake
  // Spec 8.3.1 four-phase. pl_stallreq may only rise while lp_stallack is low;
  // while lp_stallack is high the protocol layer must keep lp_valid and
  // lp_irdy low.
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n)  lp_stallack <= 1'b0;
    else            lp_stallack <= pl_stallreq;
  end

  // ------------------------------------------------------- send engine
  // The task blocks until the UI is accepted, so the caller can treat a
  // completed call as one transferred unit of data.
  task send;
    input [NBYTES*8-1:0] data;
    input [7:0]          stream;
    begin
      @(negedge lclk);
      while (pl_stallreq !== 1'b0) @(negedge lclk);
      lp_data  = data;
      lp_stream= stream;
      lp_valid = 1'b1;
      lp_irdy  = 1'b1;
      @(posedge lclk);
      // Hold until the adapter accepts.
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
    output [NBYTES*8-1:0] data;
    begin
      @(posedge lclk);
      while (!(pl_valid === 1'b1)) @(posedge lclk);
      data = pl_data;
      @(negedge lclk);
    end
  endtask

endmodule

`endif

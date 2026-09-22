// UCIe 1.0 Simplified Endpoint - logical PHY CSR block
// Spec 7.1: electrical-parameter registers advertised to the partner during
// MBINIT.PARAM. Per the README these are parameter registers only; there is
// no analog/AFE implementation.
//
// The CSR set holds the local electrical parameters, the negotiated link
// width, and the training status the adapter reads through the sideband
// register access path.
`ifndef PhyCsr_SV
`define PhyCsr_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module phy_csr (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        csr_wr,
  input  logic        csr_rd,
  input  logic [26:0] csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,
  output logic        csr_rdata_vld,

  input  logic [7:0]  ltsm_state,
  input  logic        lnk_is_x8,
  input  logic [1:0]  degrade_lanes,
  input  logic        train_error,
  output logic        start_link_train
);

  // ---------------------------------------------------------- addresses
  localparam logic [26:0] CSR_TRAIN_CTL  = 27'h0; // start training
  localparam logic [26:0] CSR_ELEC_PARAM = 27'h8; // electrical params
  localparam logic [26:0] CSR_LINK_STS   = 27'h10; // LTSM status
  localparam logic [26:0] CSR_TRAIN_STS  = 27'h18; // training status

  // ---------------------------------------------------------- storage
  // Electrical parameters. Fixed values for this reduced-capability set.
  // Fields: [15:0] supply voltage mV, [31:16] termination, [63:32] reserved.
  logic [63:0] elec_param_q;
  logic        start_train_q;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      elec_param_q <= 64'h0000_0C80_0000_0834; // 1.0 V, 2104 ohm placeholder
      start_train_q<= 1'b0;
    end else if (csr_wr) begin
      case (csr_addr)
        CSR_TRAIN_CTL : start_train_q <= csr_wdata[0];
        CSR_ELEC_PARAM: elec_param_q  <= csr_wdata;
        default       : ;
      endcase
    end
  end

  assign start_link_train = start_train_q;

  // ---------------------------------------------------------- read path
  // Reads return the addressed register one cycle later.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      csr_rdata     <= '0;
      csr_rdata_vld <= 1'b0;
    end else begin
      csr_rdata_vld <= csr_rd;
      case (csr_addr)
        CSR_TRAIN_CTL : csr_rdata <= {63'b0, start_train_q};
        CSR_ELEC_PARAM: csr_rdata <= elec_param_q;
        CSR_LINK_STS  : csr_rdata <= {48'b0, ltsm_state, 7'b0, lnk_is_x8};
        CSR_TRAIN_STS : csr_rdata <= {61'b0, degrade_lanes, train_error};
        default       : csr_rdata <= '0;
      endcase
    end
  end

  logic unused;
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

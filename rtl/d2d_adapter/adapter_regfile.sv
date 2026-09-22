// UCIe 1.0 Simplified Endpoint - adapter register file
// UCIe Link Control, UCIe Link Status, Error Log 0/1, Electrical Parameter CSRs.
// Per spec 7.1: configuration register access via sideband is supported, but no
// analog/AFE circuits are implemented - parameters exist as CSR fields only.
`ifndef AdapterRegfile_SV
`define AdapterRegfile_SV
`include "ucie_pkg.sv"

module adapter_regfile (
  input  logic        lclk,
  input  logic        lreset_n,

  // CSR access from the Adapter's own sideband slave path.
  input  logic        csr_wr,
  input  logic [26:0] csr_addr,
  input  logic [63:0] csr_wdata,
  input  logic        csr_rd,
  output logic [63:0] csr_rdata,
  output logic        csr_rdata_vld,

  // Hardware write side.
  input  logic        start_link_train_wr,   // UCIe Link Control bit 0
  input  logic        in_band_pres,          // sticky copy from RDI
  input  logic [3:0]  rdi_state_sts,
  input  logic [7:0]  ltsm_state,            // Error Log 0 State N
  input  logic        trainerror,
  input  logic        phyinrecenter,

  // Software read side.
  output logic        start_link_train,
  output logic        link_status_active
);

  import ucie_pkg::*;

  // --- register offsets (byte offsets within the Adapter CSR block) ---------
  localparam logic [26:0] A_LINK_CTRL  = 27'h0;
  localparam logic [26:0] A_LINK_STAT  = 27'h8;
  localparam logic [26:0] A_ERR_LOG0   = 27'h10;
  localparam logic [26:0] A_ERR_LOG1   = 27'h18;
  localparam logic [26:0] A_EL_PARAM   = 27'h20;   // electrical parameters
  localparam logic [26:0] A_EL_PARAM2  = 27'h28;

  // Error Log 0 bits [7:0] = State N; the high bits are for local errors.
  logic [63:0] reg_link_ctrl;
  logic [63:0] reg_link_stat;
  logic [63:0] reg_err_log0;
  logic [63:0] reg_err_log1;
  logic [63:0] reg_el_param;
  logic [63:0] reg_el_param2;

  // Electrical parameters, CSR fields only (no analog).
  // [3:0] max IO link speed, [8:4] voltage swing, [9] clock mode,
  // [12:11] clock phase, [17:13] module id, [19:18] lane map 0/1
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_el_param  <= 64'h0000_0000_0000_001F; // speed 4 GT/s only (0001b)
      reg_el_param2 <= 64'h0000_0000_0000_0000;
    end else if (csr_wr && csr_addr == A_EL_PARAM) begin
      reg_el_param  <= csr_wdata;
    end else if (csr_wr && csr_addr == A_EL_PARAM2) begin
      reg_el_param2 <= csr_wdata;
    end
  end

  // Error Log 0: State N in [7:0]. [63:8] hold local error indications.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_err_log0 <= 64'h0;
      reg_err_log1 <= 64'h0;
    end else begin
      reg_err_log0[7:0] <= ltsm_state;
      reg_err_log1[8]   <= trainerror;
      reg_err_log1[9]   <= phyinrecenter;
      // Additional error indications are write-only-by-error and preserved.
      if (trainerror)   reg_err_log1[8] <= 1'b1;
      if (csr_wr && csr_addr == A_ERR_LOG1) reg_err_log1 <= 64'h0; // RW1C
    end
  end

  // Link Control: bit 0 start UCIe link training, RW.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_ctrl <= 64'h0;
    end else if (csr_wr && csr_addr == A_LINK_CTRL) begin
      reg_link_ctrl <= csr_wdata;
    end else if (start_link_train_wr) begin
      reg_link_ctrl[0] <= 1'b1;
    end
  end

  // Link Status: bit 0 in-band presence, [3:1] PHY state, [5:4] link width.
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_stat <= 64'h0;
    end else begin
      reg_link_stat[0]  <= in_band_pres;
      reg_link_stat[4:1] <= rdi_state_sts;
      reg_link_stat[6:5] <= 2'b10;          // x16
    end
  end

  assign start_link_train    = reg_link_ctrl[0];
  assign link_status_active  = (rdi_state_sts == RDI_STS_ACTIVE);

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      csr_rdata     <= 64'h0;
      csr_rdata_vld <= 1'b0;
    end else begin
      csr_rdata_vld <= csr_rd;
      case (csr_addr)
        A_LINK_CTRL : csr_rdata <= reg_link_ctrl;
        A_LINK_STAT : csr_rdata <= reg_link_stat;
        A_ERR_LOG0  : csr_rdata <= reg_err_log0;
        A_ERR_LOG1  : csr_rdata <= reg_err_log1;
        A_EL_PARAM  : csr_rdata <= reg_el_param;
        A_EL_PARAM2 : csr_rdata <= reg_el_param2;
        default     : csr_rdata <= 64'h0;
      endcase
    end
  end

endmodule

`endif

// UCIe 1.0 Simplified Endpoint - Streaming pass-through datapath
// Spec 2.1 / Table 115. Raw Mode Format 1 only.
//
// The datapath is intentionally minimal: lp_data on FDI maps directly onto
// lp_data on RDI. Per the confirmed scope there is no flit-header insertion,
// no CRC engine, no retry buffer, no sequence-number logic, and no DLLP path.
// 4 GT/s does not require Retry, and Raw Mode (Format 1) is the only format.
`ifndef AdapterDatapath_SV
`define AdapterDatapath_SV
`include "ucie_pkg.sv"

module adapter_datapath #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES
) (
  input  logic                  lclk,
  input  logic                  lreset_n,

  // Protocol Layer side (FDI)
  input  logic                  lp_irdy,
  input  logic                  lp_valid,
  input  logic [NBYTES*8-1:0]   lp_data,
  input  logic [7:0]            lp_stream,
  input  logic                  lp_stallack,
  input  logic                  lp_rx_active_sts,
  output logic                  pl_trdy,
  output logic                  pl_valid,
  output logic [NBYTES*8-1:0]   pl_data,
  output logic [7:0]            pl_stream,

  // Physical Layer side (RDI)
  output logic                  rdi_lp_irdy,
  output logic                  rdi_lp_valid,
  output logic [NBYTES*8-1:0]   rdi_lp_data,
  input  logic                  rdi_pl_trdy,
  input  logic                  rdi_pl_valid,
  input  logic [NBYTES*8-1:0]   rdi_pl_data,
  input  logic                  rdi_lnk_is_x8,
  input  logic                  stall_active
);

  import ucie_pkg::*;

  // FDI -> RDI direction. Registered for timing; the single register stage
  // satisfies the Stage 1+ requirement of spec 8.1.
  logic [NBYTES*8-1:0] tx_data_q;
  logic                tx_valid_q;

  // RDI -> FDI direction. Registered.
  logic [NBYTES*8-1:0] rx_data_q;
  logic                rx_valid_q;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      tx_data_q  <= '0;
      tx_valid_q <= 1'b0;
      rx_data_q  <= '0;
      rx_valid_q <= 1'b0;
    end else begin
      // While the PHY is stalled, lp_valid and lp_irdy are held low by the
      // Protocol Layer, so the register simply stops moving.
      tx_data_q  <= lp_data;
      tx_valid_q <= lp_valid && lp_irdy && !stall_active;
      rx_data_q  <= rdi_pl_data;
      rx_valid_q <= rdi_pl_valid;
    end
  end

  // Single comb block for every output.
  always_comb begin
    // FDI -> RDI
    rdi_lp_irdy  = lp_irdy && !stall_active;
    rdi_lp_valid = tx_valid_q;
    rdi_lp_data  = tx_data_q;

    // x8 width degrade narrows the usable byte field to lanes 0-7 (bytes 0-7).
    // Bytes 8-15 carry no data in that mode and are driven to zero so the
    // scoreboard can verify a clean byte-for-byte compare.
    if (rdi_lnk_is_x8) begin
      rdi_lp_data[NBYTES*8-1:NBYTES*4] = '0;
    end

    // RDI -> FDI
    pl_valid     = rx_valid_q;
    pl_data      = rx_data_q;
    pl_trdy      = rdi_pl_trdy && !stall_active;
    pl_stream    = lp_stream;
  end

  // lp_stallack is consumed by the adapter stall logic, not by this datapath.
  // The reference keeps the port visible so the wiring matches Table 115.
  logic unused_stallack;
  assign unused_stallack = lp_stallack;

endmodule

`endif

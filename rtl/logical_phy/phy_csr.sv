// ============================================================================
// File        : phy_csr.sv
// Module      : phy_csr
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Logical PHY Control and Status Register (CSR) block.
//               Holds electrical parameter registers, negotiated link width,
//               and training status. These registers are advertised to the
//               partner during MBINIT.PARAM and are readable by the adapter
//               through the sideband register access path.
//
//               NOTE: These are electrical *parameter* registers ONLY. There
//               is NO analog front-end (AFE) implementation. The register
//               values are fixed defaults or software-written placeholders
//               used during the sideband parameter exchange. No analog
//               calibration, no DFE/CTLE coefficients, no voltage/current
//               DAC control — all of that is outside the scope of this
//               proof-of-concept.
//
// Spec refs   : UCIe 1.0 spec section 7.1 (PHY electrical-parameter
//               registers), section 4.5.3.3 MBINIT.PARAM (parameter
//               exchange during link training), section 8.1 Table 114
//               (RDI CSR access).
//
// --------------------------------------------------------------------------
// Register map
// --------------------------------------------------------------------------
//
//   Offset   Name          Access   Description
//   ------   ----          ------   -----------
//   0x00     TRAIN_CTL     RW       Training control. Bit [0]: writing 1
//                                   starts link training (LTSM exits RESET).
//                                   Spec 4.5.3.1.
//
//   0x08     ELEC_PARAM    RW       Electrical parameters (spec 7.1).
//                                   [15:0]  Supply voltage in mV.
//                                   [31:16] Termination impedance value.
//                                   [63:32] Reserved (reads as written).
//                                   Reset default: 0x0000_0C80_0000_0834
//                                   (1.0 V supply, 2104 ohm placeholder).
//                                   No analog — values are placeholders.
//
//   0x10     LINK_STS      RO       Link status (spec 7.1).
//                                   [0]     lnk_is_x8 (0 = x16, 1 = x8).
//                                   [7:1]   Reserved.
//                                   [15:8]  ltsm_state (8-bit LTSM encoding).
//                                   [63:16] Reserved (reads 0).
//
//   0x18     TRAIN_STS     RO       Training status (spec 7.1).
//                                   [0]     train_error.
//                                   [2:1]   degrade_lanes[1:0].
//                                   [63:3]  Reserved (reads 0).
//
// --------------------------------------------------------------------------
// Write path
// --------------------------------------------------------------------------
//   On csr_wr, the addressed register is updated from csr_wdata on the next
//   rising lclk edge. Only TRAIN_CTL and ELEC_PARAM are writable; writes to
//   other addresses are silently ignored.
//
// --------------------------------------------------------------------------
// Read path
// --------------------------------------------------------------------------
//   On csr_rd, csr_rdata is loaded with the addressed register's value and
//   csr_rdata_vld is asserted one cycle later. If the address does not match
//   a defined register, csr_rdata returns all zeros.
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   Write : csr_wr, csr_addr[26:0], csr_wdata[63:0].
//   Read  : csr_rd, csr_addr[26:0] -> csr_rdata[63:0], csr_rdata_vld.
//   Status: ltsm_state[7:0], lnk_is_x8, degrade_lanes[1:0], train_error.
//   Output: start_link_train (from TRAIN_CTL bit 0).
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The CSR address space uses a 27-bit address (matching the sideband
//      register access path width). Only the lowest bits are decoded; the
//      upper bits are don't-care.
//   2. The ELEC_PARAM reset default encodes 1.0 V supply (0x0834 = 2100 mV
//      — placeholder) and 2104 ohm termination (0x0C80 — placeholder).
//      These are NOT real analog values; they exist solely for the parameter
//      exchange protocol.
//   3. lclk and lreset_n are used by the sequential logic. The unused
//      always_comb block at the end suppresses lint warnings for the
//      combinational reference to these signals (which may appear unused
//      to some tools due to the generate-free structure).
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Four-register CSR block with
//                        write/read paths and training control output.
// ============================================================================
`ifndef PhyCsr_SV
`define PhyCsr_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
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

  // =========================================================================
  // Address decode constants  (spec 7.1 – PHY register offsets)
  // =========================================================================
  // Each register is 64 bits wide (8-byte aligned). The offsets are local
  // to the PHY CSR aperture.
  // =========================================================================
  localparam logic [26:0] CSR_TRAIN_CTL  = 27'h0; // start training
  localparam logic [26:0] CSR_ELEC_PARAM = 27'h8; // electrical params
  localparam logic [26:0] CSR_LINK_STS   = 27'h10; // LTSM status
  localparam logic [26:0] CSR_TRAIN_STS  = 27'h18; // training status

  // =========================================================================
  // Register storage  (spec 7.1 – electrical parameters, no analog)
  // =========================================================================
  // elec_param_q : Electrical parameter register. Fixed placeholder values
  //                for this reduced-capability set. Fields:
  //                  [15:0]  Supply voltage in mV (default 0x0834 = 2100 mV).
  //                  [31:16] Termination impedance (default 0x0C80 = 3200).
  //                  [63:32] Reserved.
  //                NOTE: No analog implementation. These are register values
  //                only, used during the MBINIT.PARAM sideband exchange.
  //
  // start_train_q: Training start bit. Writing 1 to TRAIN_CTL[0] pulses
  //                start_link_train, which causes the LTSM to exit RESET
  //                (spec 4.5.3.1).
  // =========================================================================
  logic [63:0] elec_param_q;
  logic        start_train_q;

  // =========================================================================
  // Write path  (spec 7.1 – CSR write, electrical params only, no analog)
  // =========================================================================
  // On csr_wr, the addressed register is updated from csr_wdata. Only
  // TRAIN_CTL and ELEC_PARAM are writable; writes to LINK_STS and
  // TRAIN_STS (read-only status) are silently ignored (default case).
  //
  // Reset initialises elec_param_q to the placeholder defaults and clears
  // start_train_q.
  // =========================================================================
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

  // =========================================================================
  // start_link_train output  (spec 4.5.3.1 – RESET exit trigger)
  // =========================================================================
  // Directly reflects TRAIN_CTL bit 0. When asserted, the LTSM exits RESET
  // and begins the link training sequence. This output is OR'd with the
  // top-level start_link_train pin in logical_phy.sv.
  // =========================================================================
  assign start_link_train = start_train_q;

  // =========================================================================
  // Read path  (spec 7.1 – CSR read, one-cycle latency)
  // =========================================================================
  // On csr_rd, csr_rdata is loaded with the addressed register's value and
  // csr_rdata_vld is asserted one cycle later. The case statement selects
  // the register content:
  //   TRAIN_CTL  : Bit 0 = start_train_q, bits [63:1] = 0.
  //   ELEC_PARAM : Full 64-bit electrical parameter register.
  //   LINK_STS   : Bit 0 = lnk_is_x8, bits [15:8] = ltsm_state, rest = 0.
  //   TRAIN_STS  : Bit 0 = train_error, bits [2:1] = degrade_lanes, rest = 0.
  //   default    : All zeros for undefined addresses.
  //
  // csr_rdata_vld tracks csr_rd with a one-cycle delay (pipeline stage).
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      csr_rdata     <= 64'h0;
      csr_rdata_vld <= 1'b0;
    end else begin
      csr_rdata_vld <= csr_rd;
      case (csr_addr)
        CSR_TRAIN_CTL : csr_rdata <= {63'b0, start_train_q};
        CSR_ELEC_PARAM: csr_rdata <= elec_param_q;
        CSR_LINK_STS  : csr_rdata <= {48'b0, ltsm_state, 7'b0, lnk_is_x8};
        CSR_TRAIN_STS : csr_rdata <= {61'b0, degrade_lanes, train_error};
        default       : csr_rdata <= 64'h0;
      endcase
    end
  end

  // =========================================================================
  // Unused signal suppression
  // =========================================================================
  // lclk and lreset_n are consumed by the always_ff blocks above, but some
  // lint tools may flag them as combinationally unused. This explicit
  // always_comb reference silences those warnings.
  // =========================================================================
  logic unused;
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

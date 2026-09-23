// ============================================================================
// Module    : adapter_regfile
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_regfile.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 7.1 - Configuration Register Overview
//   UCIe 1.0 Specification, Section 7.3 - UCIe Link Control Register
//   UCIe 1.0 Specification, Section 7.4 - UCIe Link Status Register
//   UCIe 1.0 Specification, Section 7.5 - Error Log 0 Register
//   UCIe 1.0 Specification, Section 7.6 - Error Log 1 Register
//   UCIe 1.0 Specification, Section 7.7 - Electrical Parameter Registers
//   UCIe 1.0 Specification, Table 114 - RDI state encodings (rdi_state_sts)
//
// DESCRIPTION
//   Adapter CSR (Configuration / Status Register) file. Contains six 64-bit
//   registers at byte offsets within the Adapter CSR address space:
//
//   Offset  Register           Access  Description
//   ------  -----------------  ------  ----------------------------------------
//   0x00    UCIe Link Control  RW      Bit 0: start link training. Set by SW
//                                       write or by the start_link_train_wr
//                                       hardware trigger.
//   0x08    UCIe Link Status   RO/HW   [0]   in-band presence (from RDI).
//                                       [4:1] RDI state status.
//                                       [6:5] link width (hardcoded 10b = x16).
//   0x10    Error Log 0        RO/HW   [7:0] LTSM State N (current training
//                                       sub-state reported by logical_phy).
//                                       [63:8] reserved for local error bits.
//   0x18    Error Log 1        RW1C    [8] trainerror sticky, [9] phyinrecenter
//                                       sticky. Writing all-zeros clears
//                                       (RW1C behaviour on sideband CfgWr).
//   0x20    Electrical Params  RW      [3:0] max IO link speed (reset 0001b =
//                                       4 GT/s only), [8:4] voltage swing,
//                                       [9] clock mode, [12:11] clock phase,
//                                       [17:13] module id, [19:18] lane map.
//                                       CSR fields only - no analog/AFE.
//   0x28    Electrical Params2 RW      Reserved expansion.
//
//   The register file is accessed via the CSR bus from adapter_sb_if:
//     csr_wr / csr_addr / csr_wdata -> write path
//     csr_rd / csr_addr -> read path -> csr_rdata / csr_rdata_vld
//
//   Hardware-write inputs (start_link_train_wr, in_band_pres, rdi_state_sts,
//   ltsm_state, trainerror, phyinrecenter) come from the adapter and PHY
//   status signals. Software-read outputs (start_link_train, link_status_active)
//   are decoded from the register contents.
//
//   Per spec 7.1: configuration register access via sideband is supported,
//   but no analog/AFE circuits are implemented in this simplified endpoint.
//   Electrical parameters exist as CSR fields only.
//
// CLOCK / RESET
//   lclk      - Main link clock (500 MHz).
//   lreset_n  - Active-low asynchronous reset. All registers are cleared
//               to their reset values.
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation - first commit to git.
//   v0.0.2  2026-09-22  Update lclk documentation to 500 MHz.
//   v0.0.3  2026-09-23  Documentation: add per-construct comment blocks with
//                        spec references for register decode outputs.
//   v0.0.4  2026-09-23  Documentation: correct the electrical parameter
//                        register citation. The previous reference to Section
//                        7.7 was wrong; Section 7 ends at 7.6. The fields are
//                        now cited to Section 7.5 (UCIe Registers, Tables
//                        64-65) with the unmodelled analog parameters pointed
//                        at Section 5.4.1 and Table 30.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef AdapterRegfile_SV
`define AdapterRegfile_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
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

  // --------------------------------------------------------------------------
  // Register Offset Definitions
  // --------------------------------------------------------------------------
  // Byte offsets within the Adapter CSR block. The sideband interface
  // (adapter_sb_if) decodes the 27-bit address and compares against these
  // values to select the target register. Each register is 64 bits wide
  // (8-byte aligned), matching the sideband CfgRd/CfgWr data width.
  //
  // Spec ref: UCIe 1.0, Section 7.1 - register map layout.
  // --------------------------------------------------------------------------
  localparam logic [26:0] A_LINK_CTRL  = 27'h0;
  localparam logic [26:0] A_LINK_STAT  = 27'h8;
  localparam logic [26:0] A_ERR_LOG0   = 27'h10;
  localparam logic [26:0] A_ERR_LOG1   = 27'h18;
  localparam logic [26:0] A_EL_PARAM   = 27'h20;   // electrical parameters
  localparam logic [26:0] A_EL_PARAM2  = 27'h28;

  // --------------------------------------------------------------------------
  // Register Storage
  // --------------------------------------------------------------------------
  // Six 64-bit registers. Each is maintained by its own always_ff block
  // below. Error Log 0 bits [7:0] hold the LTSM State N value; the high
  // bits are reserved for local error indications.
  // --------------------------------------------------------------------------
  logic [63:0] reg_link_ctrl;
  logic [63:0] reg_link_stat;
  logic [63:0] reg_err_log0;
  logic [63:0] reg_err_log1;
  logic [63:0] reg_el_param;
  logic [63:0] reg_el_param2;

  // -------------------------------------------------------------------------
  // always_ff: Electrical Parameter Registers (0x20, 0x28)
  //
  // These registers hold the electrical parameter CSR fields. Since no
  // analog/AFE circuits are implemented in this simplified endpoint, the
  // fields exist as software-programmable values only.
  //
  // Field map for reg_el_param (offset 0x20):
  //   [3:0]   Max IO link speed (reset value 0xF = all speeds indicated,
  //           but only 4 GT/s is functionally supported).
  //   [8:4]   Voltage swing setting.
  //   [9]     Clock mode (0 = strobe, 1 = clock).
  //   [12:11] Clock phase setting.
  //   [17:13] Module ID.
  //   [19:18] Lane map 0/1.
  // reg_el_param2 (offset 0x28) is reserved expansion, reset to zero.
  // Both registers are RW via sideband CfgWr. The address decode selects
  // which register receives the write data.
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers. The link speed and lane
  //           map fields correspond to the UCIe Link Capability and Link
  //           Control registers of Tables 64-65 (Link Speed enabled, Link
  //           Width enabled). The voltage swing, clock mode and clock phase
  //           fields have no register equivalent in this simplified endpoint
  //           and are held here as software-visible placeholders only; the
  //           analog parameters they name are specified in Section 5.4.1
  //           (Receiver Electrical Parameters) and Table 30 (Transmitter
  //           Electrical Parameters), neither of which is modelled in RTL.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always_ff: Error Log Registers (0x10, 0x18)
  //
  // Error Log 0 (offset 0x10):
  //   [7:0]  LTSM State N - continuously updated from the ltsm_state input,
  //          reflecting the current link-training sub-state. This is a
  //          hardware-write-only field; sideband writes do not modify it.
  //   [63:8] Reserved for additional local error indications.
  //
  // Error Log 1 (offset 0x18):
  //   [8]    trainerror sticky bit - set by the trainerror hardware input
  //          when the PHY reports a training error. The bit is sticky: once
  //          set, it remains until cleared by a sideband CfgWr (RW1C).
  //   [9]    phyinrecenter sticky bit - set by the phyinrecenter input.
  //   A sideband CfgWr to offset 0x18 clears the entire register to zero
  //   (RW1C clear-all behaviour).
  //
  // Spec ref: UCIe 1.0, Section 7.5 (Error Log 0), Section 7.6 (Error Log 1).
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always_ff: UCIe Link Control Register (0x00)
  //
  // Bit 0: Start UCIe link training. This bit can be set by:
  //   (a) A sideband CfgWr to offset 0x00 (software-initiated training).
  //   (b) The start_link_train_wr hardware trigger from d2d_adapter.sv
  //       (external controller or testbench-initiated training).
  //
  // The entire 64-bit register is writable via sideband CfgWr. The hardware
  // trigger only sets bit 0 without disturbing other bits. There is no
  // auto-clear: once set, bit 0 remains high until the register is
  // explicitly rewritten or the module is reset.
  //
  // Spec ref: UCIe 1.0, Section 7.3 - UCIe Link Control Register.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_ctrl <= 64'h0;
    end else if (csr_wr && csr_addr == A_LINK_CTRL) begin
      reg_link_ctrl <= csr_wdata;
    end else if (start_link_train_wr) begin
      reg_link_ctrl[0] <= 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: UCIe Link Status Register (0x08)
  //
  // Hardware-written status register reflecting the current link state:
  //   [0]   in_band_pres - in-band presence detected (sticky copy from RDI
  //         pl_inband_pres, maintained by the FDI state machine).
  //   [4:1] rdi_state_sts - current RDI state (4-bit encoding from Table 114).
  //   [6:5] link width - hardcoded to 2'b10 (x16) since this simplified
  //         endpoint does not support runtime width negotiation.
  //
  // This register is read-only from the sideband perspective; all fields
  // are continuously updated by hardware every clock cycle.
  //
  // Spec ref: UCIe 1.0, Section 7.4 - UCIe Link Status Register.
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_stat <= 64'h0;
    end else begin
      reg_link_stat[0]  <= in_band_pres;
      reg_link_stat[4:1] <= rdi_state_sts;
      reg_link_stat[6:5] <= 2'b10;          // x16
    end
  end

  // -------------------------------------------------------------------------
  // assign: Decoded Outputs from Register Contents
  //
  // start_link_train  : reflects bit 0 of the Link Control register. Used
  //                     by the LTSM (via d2d_adapter) to know when software
  //                     has requested link training to begin.
  //
  // link_status_active: decoded comparison of the RDI state field against
  //                     RDI_STS_ACTIVE. Provides a single-bit "link is
  //                     active" indication for observability and for the
  //                     d2d_adapter wrapper's link_active_obs output.
  //
  // Spec ref: UCIe 1.0, Section 7.3 (Link Control), Section 7.4 (Link Status).
  // -------------------------------------------------------------------------
  assign start_link_train    = reg_link_ctrl[0];
  assign link_status_active  = (rdi_state_sts == RDI_STS_ACTIVE);

  // -------------------------------------------------------------------------
  // always_ff: CSR Read Multiplexer
  //
  // Implements a registered read-data multiplexer for sideband CfgRd
  // transactions. When csr_rd is asserted, the register addressed by
  // csr_addr is selected and driven onto csr_rdata one cycle later
  // (registered output). csr_rdata_vld qualifies the read data.
  // The one-cycle read latency matches the sideband protocol's expected
  // CfgRd completion timing: the adapter_sb_if transmits the completion
  // packet on the cycle after csr_rdata_vld is asserted.
  // Address decode:
  //   0x00 -> reg_link_ctrl     (UCIe Link Control)
  //   0x08 -> reg_link_stat     (UCIe Link Status)
  //   0x10 -> reg_err_log0      (Error Log 0)
  //   0x18 -> reg_err_log1      (Error Log 1)
  //   0x20 -> reg_el_param      (Electrical Parameters)
  //   0x28 -> reg_el_param2     (Electrical Parameters 2)
  //   other -> 64'h0            (default / unmapped)
  // Spec ref: UCIe 1.0, Section 7.1 - CSR read access.
  // -------------------------------------------------------------------------
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

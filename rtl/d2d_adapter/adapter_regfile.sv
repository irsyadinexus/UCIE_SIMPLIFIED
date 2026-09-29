// ============================================================================
// Module    : adapter_regfile
// Project   : UCIe 1.0 Simplified Endpoint
// File      : rtl/d2d_adapter/adapter_regfile.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 7.5 - UCIe Registers
//   UCIe 1.0 Specification, Table 64 - UCIe Link DVSEC - UCIe Link Capability
//   UCIe 1.0 Specification, Table 65 - UCIe Link DVSEC - UCIe Link Control
//   UCIe 1.0 Specification, Table 66 - UCIe Link DVSEC - UCIe Link Status
//   UCIe 1.0 Specification, Table 60 - Register Attributes
//   UCIe 1.0 Specification, Table 114 - RDI signal list
//   UCIe 1.0 Specification, Section 5.4.1 - Receiver Electrical Parameters
//   UCIe 1.0 Specification, Table 30 - Transmitter Electrical Parameters
//
// DESCRIPTION
//   Adapter CSR (Configuration / Status Register) file. Contains six 64-bit
//   registers at byte offsets within the Adapter CSR address space:
//
//   Offset  Register           Access  Description
//   ------  -----------------  ------  ----------------------------------------
//   0x00    UCIe Link Control  RW      Bit 0: start link training. Set by SW
//                                       write or by the start_link_train_wr
//                                       hardware trigger. Cleared by the
//                                       private clear_start_link_train input
//                                       after a successful Active Entry; the
//                                       clear wins over the SW write and the
//                                       hardware trigger (PLAN.md 15.9
//                                       Phase C).
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
//   Private input: clear_start_link_train. Driven by d2d_adapter.sv from the
//   private training event path, not a public top-level port. It clears
//   bit 0 of the Link Control register after the LTSM completes Active Entry,
//   and has priority over a concurrent CfgWr to 0x00 and over
//   start_link_train_wr (PLAN.md section 15.9 Phase C).
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
//   v0.0.5  2026-09-23  Documentation: correct the header and remaining body
//                        citations. The header invented per-register sections
//                        (7.3 Link Control, 7.4 Link Status, 7.5 Error Log 0,
//                        7.6 Error Log 1) that do not match the real titles.
//                        All now cite Section 7.5, with Link Capability,
//                        Control and Status as Tables 64, 65 and 66, and the
//                        error logs as Sections 7.5.3.30/.31 (Tables 108/109).
//   v0.0.6  2026-09-25  Phase C private clear. Add the private input
//                        clear_start_link_train. It clears bit 0 of
//                        reg_link_ctrl (UCIe Link Control, offset 0x00) after
//                        a successful Active Entry. The clear has priority
//                        over a concurrent sideband CfgWr to 0x00 and over
//                        the start_link_train_wr hardware set event, and it
//                        leaves bits [63:1] unchanged. All other registers
//                        keep their existing behaviour. Comments for the
//                        header, interface, Link Control storage and the
//                        decoded start_link_train output now cite PLAN.md
//                        section 15.9 Phase C and UCIe 1.0 section 7.5.
//   v0.0.7  2026-09-28  Sideband protocol remediation:
//                        - Add csr_be[7:0] port and merge enabled bytes on writes (Section 7.5).
//                        - Preserve hardware-set and private-clear priority (Section 7.5).
//                        - Add Table 70-73 Sideband Mailbox Index (0x30), Data (0x38),
//                          Control (0x40), and Status (0x48) registers (Section 7.5).
//                        - Add rem_req_vld/rdy/pkt and rem_cpl_vld/pkt internal mailbox
//                          channel to adapter_sb_if (Sections 6.1, 7.5).
//                        - Preserve one-cycle read latency.
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`ifndef AdapterRegfile_SV
`define AdapterRegfile_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module adapter_regfile (
  input  logic        lclk,
  input  logic        lreset_n,

  // CSR access from the Adapter's own sideband slave path.
  input  logic        csr_wr,
  input  logic [26:0] csr_addr,
  input  logic [63:0] csr_wdata,
  input  logic [7:0]  csr_be,
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

  // ------------------------------------------------------------------------
  // Private Active Entry clear (PLAN.md section 15.9 Phase C;
  // UCIe 1.0 section 7.5 - UCIe Registers).
  // ------------------------------------------------------------------------
  // clear_start_link_train is a private input driven by the Adapter wrapper
  // d2d_adapter.sv, which receives it from the private training event path.
  // It is NOT a public top-level port.
  //
  // The LTSM asserts this input after a successful Active Entry. The clear
  // retires the Adapter sticky Start copy, so an accepted Start level cannot
  // request training a second time (PLAN.md section 15.9 Phase C, fresh
  // software Start event requirement).
  //
  // The clear forces bit 0 of reg_link_ctrl to 0 and leaves bits [63:1]
  // unchanged. It has priority over a concurrent sideband CfgWr to offset
  // 0x00 and over the start_link_train_wr hardware set event.
  // ------------------------------------------------------------------------
  input  logic        clear_start_link_train,

  // Software read side.
  output logic        start_link_train,
  output logic        link_status_active,

  // ------------------------------------------------------------------------
  // Remote Register Access Mailbox Channel (to/from adapter_sb_if)
  // UCIe 1.0 Section 6.1, Section 7.5 (Tables 70-73)
  // ------------------------------------------------------------------------
  output logic        rem_req_vld,
  input  logic        rem_req_rdy,
  output sb_packet_t  rem_req_pkt,
  input  logic        rem_cpl_vld,
  input  sb_packet_t  rem_cpl_pkt
);


  // --------------------------------------------------------------------------
  // Register Offset Definitions
  // --------------------------------------------------------------------------
  // Byte offsets within the Adapter CSR block. The sideband interface
  // (adapter_sb_if) decodes the 27-bit address and compares against these
  // values to select the target register. Each register is 64 bits wide
  // (8-byte aligned), matching the sideband CfgRd/CfgWr data width.
  //
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (register map layout).
  // --------------------------------------------------------------------------
  localparam logic [26:0] A_LINK_CTRL  = 27'h0;
  localparam logic [26:0] A_LINK_STAT  = 27'h8;
  localparam logic [26:0] A_ERR_LOG0   = 27'h10;
  localparam logic [26:0] A_ERR_LOG1   = 27'h18;
  localparam logic [26:0] A_EL_PARAM   = 27'h20;   // electrical parameters
  localparam logic [26:0] A_EL_PARAM2  = 27'h28;
  localparam logic [26:0] A_MB_INDEX   = 27'h30;   // Table 70: Sideband Mailbox Index
  localparam logic [26:0] A_MB_DATA    = 27'h38;   // Table 71: Sideband Mailbox Data
  localparam logic [26:0] A_MB_CTRL    = 27'h40;   // Table 72: Sideband Mailbox Control
  localparam logic [26:0] A_MB_STAT    = 27'h48;   // Table 73: Sideband Mailbox Status
  // --------------------------------------------------------------------------
  // Register Storage
  // --------------------------------------------------------------------------
  // Six 64-bit registers. Each is maintained by its own always_ff block
  // below. Error Log 0 bits [7:0] hold the LTSM State N value; the high
  // bits are reserved for local error indications.
  //
  // reg_link_ctrl (offset 0x00) is the Adapter Start copy. Bit 0 is sticky:
  // it is set by a sideband CfgWr or by start_link_train_wr, and it is
  // cleared by the private input clear_start_link_train after a successful
  // Active Entry. That clear owns bit 0 with the highest priority
  // (PLAN.md section 15.9 Phase C; UCIe 1.0 section 7.5).
  // --------------------------------------------------------------------------
  logic [63:0] reg_link_ctrl;
  logic [63:0] reg_link_stat;
  logic [63:0] reg_err_log0;
  logic [63:0] reg_err_log1;
  logic [63:0] reg_el_param;
  logic [63:0] reg_el_param2;
  logic [63:0] reg_mb_index;
  logic [63:0] reg_mb_data;
  logic [63:0] reg_mb_ctrl;
  logic [63:0] reg_mb_stat;
  logic        mb_pending_q;
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
      for (int b = 0; b < 8; b++) begin
        if (csr_be[b]) reg_el_param[b*8 +: 8] <= csr_wdata[b*8 +: 8];
      end
    end else if (csr_wr && csr_addr == A_EL_PARAM2) begin
      for (int b = 0; b < 8; b++) begin
        if (csr_be[b]) reg_el_param2[b*8 +: 8] <= csr_wdata[b*8 +: 8];
      end
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
  // Spec ref: UCIe 1.0, Section 7.5.3.30 - Error Log 0 (Table 108 - Error Log
  //           0 Register); Section 7.5.3.31 - Error Log 1 (Table 109 - Error
  //           Log 1 Register).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_err_log0 <= 64'h0;
      reg_err_log1 <= 64'h0;
    end else begin
      reg_err_log0[7:0] <= ltsm_state;
      if (csr_wr && csr_addr == A_ERR_LOG1) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) reg_err_log1[b*8 +: 8] <= 8'h0; // RW1C clear
        end
      end
      // Hardware-set priority for error sticky bits:
      if (trainerror)    reg_err_log1[8] <= 1'b1;
      if (phyinrecenter) reg_err_log1[9] <= 1'b1;
    end
  end
  // -------------------------------------------------------------------------
  // always_ff: UCIe Link Control Register (0x00)
  // (PLAN.md section 15.9 Phase C; UCIe 1.0 section 7.5 - UCIe Registers)
  //
  // Bit 0: Start UCIe link training. This bit can be set by:
  //   (a) A sideband CfgWr to offset 0x00 (software-initiated training).
  //   (b) The start_link_train_wr hardware trigger from d2d_adapter.sv
  //       (external controller or testbench-initiated training).
  //
  // The entire 64-bit register is writable via sideband CfgWr. The hardware
  // trigger only sets bit 0 without disturbing other bits.
  //
  // -------------------------------------------------------------------------
  // Private Active Entry clear and its priority
  // -------------------------------------------------------------------------
  // clear_start_link_train is tested FIRST in the if/else chain, so the clear
  // wins over a concurrent sideband write and over the start_link_train_wr
  // hardware set event. Bit 0 of the register falls on the lclk edge that
  // follows the clear assertion, which is the edge on which the LTSM reports
  // a successful Active Entry.
  //
  // The clear writes bit 0 only. Bits [63:1] hold their previous value, so
  // any other Link Control field programmed by software is preserved.
  // A sideband CfgWr to offset 0x00 during the clear is dropped, including
  // its effect on bits [63:1]: the LTSM owns Start policy after Active Entry
  // and a stale Start request must not re-arm link training.
  //
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (Table 65 - UCIe Link
  //           DVSEC - UCIe Link Control).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_ctrl <= 64'h0;
    end else if (clear_start_link_train) begin
      // Private Active Entry clear. Highest priority for bit 0.
      reg_link_ctrl[0] <= 1'b0;
    end else begin
      if (csr_wr && csr_addr == A_LINK_CTRL) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) reg_link_ctrl[b*8 +: 8] <= csr_wdata[b*8 +: 8];
        end
      end
      // Hardware-set priority over software write for bit 0
      if (start_link_train_wr) begin
        reg_link_ctrl[0] <= 1'b1;
      end
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
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (Table 66 - UCIe Link
  //           DVSEC - UCIe Link Status).
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_link_stat <= 64'h0;
    end else begin
      reg_link_stat[0]    <= in_band_pres;
      reg_link_stat[4:1]  <= rdi_state_sts;
      reg_link_stat[6:5]  <= 2'b10;          // x16
      reg_link_stat[63:7] <= 57'h0;
    end
  end

  // -------------------------------------------------------------------------
  // assign: Decoded Outputs from Register Contents
  //
  // start_link_train  : reflects bit 0 of the Link Control register. Used
  //                     by the LTSM (via d2d_adapter) to know when software
  //                     has requested link training to begin.
  //                     The value falls on reset, on a sideband CfgWr that
  //                     writes 0, or on the private Active Entry clear
  //                     clear_start_link_train. The clear path consumes the
  //                     Adapter Start request once, so the LTSM sees a low
  //                     level after Active Entry rather than a held request
  //                     (PLAN.md section 15.9 Phase C).
  //
  // link_status_active: decoded comparison of the RDI state field against
  //                     RDI_STS_ACTIVE. Provides a single-bit "link is
  //                     active" indication for observability and for the
  //                     d2d_adapter wrapper's link_active_obs output.
  //
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (Table 65 - Link
  //           Control, Table 66 - Link Status).
  // -------------------------------------------------------------------------
  assign start_link_train    = reg_link_ctrl[0];
  assign link_status_active  = (rdi_state_sts == RDI_STS_ACTIVE);


  // -------------------------------------------------------------------------
  // always_ff: Sideband Mailbox Registers (Tables 70-73, Section 7.5)
  //
  // Offset 0x30: Sideband Mailbox Index (Table 70)
  //   [4:0]   Opcode (RW, default 00100b = 32b Cfg Read)
  //   [12:5]  BE (RW, default 0x0F)
  //   [39:13] Address (RW, default 27'h0)
  //   [63:40] Reserved
  // Offset 0x38: Sideband Mailbox Data (Table 71)
  //   [63:0]  Data (RW, write data to remote or read data from completion)
  // Offset 0x40: Sideband Mailbox Control (Table 72)
  //   [0]     Write/Read trigger (RW, auto-clearing when operation completes)
  // Offset 0x48: Sideband Mailbox Status (Table 73)
  //   [1:0]   Status (RW1C / HW update on completion):
  //           00b = CA, 01b = UR, 11b = Success
  // -------------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      reg_mb_index <= 64'h0000_0000_0000_01E4; // Opcode 00100b, BE 0x0F
      reg_mb_data  <= 64'h0;
      reg_mb_ctrl  <= 64'h0;
      reg_mb_stat  <= 64'h0;
      mb_pending_q <= 1'b0;
    end else begin
      // Mailbox Index write
      if (csr_wr && (csr_addr == A_MB_INDEX)) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) reg_mb_index[b*8 +: 8] <= csr_wdata[b*8 +: 8];
        end
        reg_mb_index[63:40] <= 24'h0;
      end

      // Mailbox Data write
      if (csr_wr && (csr_addr == A_MB_DATA)) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) reg_mb_data[b*8 +: 8] <= csr_wdata[b*8 +: 8];
        end
      end

      // Mailbox Control write (trigger)
      if (csr_wr && (csr_addr == A_MB_CTRL) && csr_be[0] && csr_wdata[0]) begin
        reg_mb_ctrl[0] <= 1'b1;
        mb_pending_q   <= 1'b1;
      end else if (rem_req_vld && rem_req_rdy) begin
        mb_pending_q   <= 1'b0;
      end

      // Mailbox Status write (RW1C)
      if (csr_wr && (csr_addr == A_MB_STAT) && csr_be[0]) begin
        reg_mb_stat[1:0] <= reg_mb_stat[1:0] & ~csr_wdata[1:0];
      end

      // Hardware completion handling (priority over software write)
      if (rem_cpl_vld) begin
        reg_mb_ctrl[0] <= 1'b0; // Auto-clear trigger bit
        case (rem_cpl_pkt.status)
          SB_STS_SC: begin
            reg_mb_stat[1:0] <= 2'b11; // Success
            reg_mb_data      <= rem_cpl_pkt.data;
          end
          SB_STS_UR: begin
            reg_mb_stat[1:0] <= 2'b01; // Unsupported Request
          end
          SB_STS_CA: begin
            reg_mb_stat[1:0] <= 2'b00; // Completer Abort
          end
          default: begin
            reg_mb_stat[1:0] <= 2'b01; // Default UR
          end
        endcase
      end
    end
  end

  // Drive typed remote request packet to adapter_sb_if (Sections 6.1, 7.5)
  always @* begin
    rem_req_pkt              = '0;
    rem_req_pkt.opcode       = reg_mb_index[4:0];
    rem_req_pkt.src_id       = RDI_SRCID_ADAPTER;
    rem_req_pkt.dst_id       = RDI_DSTID_REMOTE_ADAPT;
    rem_req_pkt.be           = reg_mb_index[12:5];
    rem_req_pkt.addr         = reg_mb_index[39:13];
    rem_req_pkt.data         = reg_mb_data;
    rem_req_pkt.status       = SB_STS_SC;
    rem_req_vld              = mb_pending_q;
  end
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
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (CSR read access).
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
        A_MB_INDEX  : csr_rdata <= reg_mb_index;
        A_MB_DATA   : csr_rdata <= reg_mb_data;
        A_MB_CTRL   : csr_rdata <= reg_mb_ctrl;
        A_MB_STAT   : csr_rdata <= reg_mb_stat;
        default     : csr_rdata <= 64'h0;
      endcase
    end
  end

endmodule

`endif

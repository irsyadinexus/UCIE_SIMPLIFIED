// ============================================================================
// File        : phy_csr.sv
// Module      : phy_csr
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Logical PHY Control and Status Register (CSR) block.
//               Holds electrical parameter registers, negotiated link width,
//               training status, and standards-aligned physical layer capability,
//               control, and status registers (UCIe 1.0 Section 7.5.3).
//
//               NOTE: These are electrical *parameter* and configuration
//               registers ONLY. There is NO analog front-end (AFE) implementation.
//               The register values are fixed defaults or software-written
//               placeholders used during the sideband parameter exchange.
//               No analog calibration, no DFE/CTLE coefficients, no voltage/current
//               DAC control — all of that is outside the scope of this
//               proof-of-concept.
//
// Spec refs   : UCIe 1.0 spec section 7.5 (UCIe Registers - the link
//               configuration and status registers), section 4.5.3.3
//               MBINIT.PARAM (parameter exchange during link training),
//               section 8.1 (Raw Die-to-Die Interface, Table 114 - RDI
//               signal list), section 7.5.3.18 (PHY Capability, Offset 1000h),
//               section 7.5.3.19 (PHY Control, Offset 1004h), section 7.5.3.20
//               (PHY Status, Offset 1008h).
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
//   0x1000   PHY_CAP       RO       Physical Layer Capability (spec 7.5.3.18).
//                                   [12:11] Clock Mode Support: 2'h2 (Free
//                                           running mode only).
//                                   [14:13] Clock Phase Support: 2'h0 (Differential).
//                                   [15]    Package Type: 1'b1 (Standard Package).
//                                   All other fields read 0. No analog fields exist.
//
//   0x1004   PHY_CTRL      RO       Fixed profile control (spec 7.5.3.19).
//                                   [5]     Clock Mode Select: 1'b1 (Free running mode).
//                                           Writes cannot select strobe mode.
//                                   [31:6]  Reserved / unsupported fields (0).
//
//   0x1008   PHY_STS       RO       Physical Layer Status (spec 7.5.3.20).
//                                   [5]     Clock Mode Status: 1'b1 (Free running mode).
//                                   [31:6]  Reserved / unsupported fields (0).
//
// --------------------------------------------------------------------------
// Write path
// --------------------------------------------------------------------------
//   Writes update TRAIN_CTL and ELEC_PARAM with the enabled bytes.
//   Writes to read-only or unmapped addresses have no effect.
//   PHY_CTRL stays in continuous mode. Unsupported selections have no effect.
//
//   A private input, clear_start_link_train, clears the sticky TRAIN_CTL bit
//   0 value after a successful Active Entry. The clear has priority over a
//   concurrent csr_wr (LinkMgmt.RDI Active clear policy).
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
//   Write : csr_wr, csr_byte_en[7:0], csr_addr[26:0], csr_wdata[63:0].
//   Read  : csr_rd, csr_addr[26:0] -> csr_rdata[63:0], csr_rdata_vld.
//   Status: ltsm_state[7:0], lnk_is_x8, degrade_lanes[1:0], train_error.
//   Output: start_link_train (from TRAIN_CTL bit 0).
//   Private input: clear_start_link_train. Driven by logical_phy.sv, not a
//                  public top-level port. Clears the sticky Start copy when
//                  the LTSM completes LinkMgmt.RDI Active Entry.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The CSR address space uses a 27-bit address (matching the sideband
//      register access path width).
//   2. The ELEC_PARAM reset default encodes 1.0 V supply (0x0834 = 2100 mV
//      — placeholder) and 2104 ohm termination (0x0C80 — placeholder).
//      These are NOT real analog values; they exist solely for the parameter
//      exchange protocol.
//   3. lclk and lreset_n are used by the sequential logic.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Four-register CSR block with
//                        write/read paths and training control output.
//   v0.0.2  2026-09-23  Documentation pass: per-construct comment blocks for
//                        the register write path, read decode and the
//                        unused-signal suppression, citing UCIe 1.0 Section
//                        7.5 (UCIe Registers).
//   v0.0.3  2026-09-23  Documentation: correct two fabricated citations. The
//                        header and the unused-signal block cited "Section
//                        8.3 - Register Interface"; 8.3 is "Common rules for
//                        FDI and RDI". Both now cite Section 7.5.
//   v0.0.4  2026-09-25  Phase C private clear. Add the private input
//                        clear_start_link_train. It clears start_train_q, the
//                        sticky TRAIN_CTL bit 0 Start copy, after a successful
//                        Active Entry. The clear has priority over a
//                        concurrent csr_wr for bit 0 only; elec_param_q and
//                        all status registers keep their existing behaviour.
//   v0.0.5  2026-09-28  Sideband protocol remediation:
//                        - Add csr_be[7:0] port and merge enabled bytes on writes (Section 7.5).
//                        - Preserve private-clear priority over CSR write (Section 7.5).
//                        - Preserve one-cycle read latency.
//   v0.0.6  2026-10-08  Documentation compliance pass: adjust construct comments
//                        for lint suppression block.
//   v0.0.7  2026-10-09  Documentation compliance pass: remove obsolete implementation-phase
//                        references outside revision history and add per-port inline comments.
//   v0.0.8  2026-10-09  Add explicit free-running-only capability (0x1000), control (0x1004),
//                        and status (0x1008) registers per UCIe 1.0 Section 7.5.3;
//                        add continuous-only physical register fields.
//   v0.0.9  2026-10-09  Keep unsupported writes inert. Remove the CSR fatal port.
//                        Use named profile constants and address-relative reads.
// ============================================================================
`ifndef PhyCsr_SV
`define PhyCsr_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module phy_csr (
  input  logic        lclk,                   // Link clock (500 MHz)
  input  logic        lreset_n,               // Active-low asynchronous reset
  input  logic        csr_wr,                 // CSR write strobe
  input  logic        csr_rd,                 // CSR read strobe
  input  logic [26:0] csr_addr,               // CSR register byte address
  input  logic [63:0] csr_wdata,              // CSR write data word
  input  logic [7:0]  csr_be,                 // CSR byte enable mask
  output logic [63:0] csr_rdata,              // CSR read data word
  output logic        csr_rdata_vld,          // CSR read data valid strobe

  input  logic [7:0]  ltsm_state,             // Current LTSM state vector
  input  logic        lnk_is_x8,              // Negotiated x8 degraded width status
  input  logic [1:0]  degrade_lanes,          // Negotiated degrade lane selection
  input  logic        train_error,            // LTSM unrecoverable training error
  output logic        start_link_train,       // Start link training command output

  // -----------------------------------------------------------------------
  // Private Active Entry clear input
  // (LinkMgmt.RDI Active Entry clear; UCIe 1.0 section 7.5 - UCIe Registers)
  // -----------------------------------------------------------------------
  // clear_start_link_train is a private input driven by logical_phy.sv. It
  // is NOT a public top-level port: the parent module wires it internally.
  //
  // The LTSM asserts this input after a successful Active Entry. The clear
  // retires the local sticky software Start copy, so a Start level that was
  // already accepted cannot request training a second time
  // (LinkMgmt.RDI Active fresh-Start-event requirement).
  //
  // While clear_start_link_train is high, start_train_q is forced to 0 and
  // the TRAIN_CTL decode of bit 0 reads 0. The clear does not touch
  // elec_param_q or any status register. See the write-path block below.
  // -----------------------------------------------------------------------
  input  logic        clear_start_link_train  // Active Entry clear strobe for start bit
);

  // =========================================================================
  // Address decode constants  (spec 7.1 and 7.5.3 – PHY register offsets)
  // =========================================================================
  // Legacy / simplified register offsets:
  localparam logic [26:0] CSR_TRAIN_CTL  = 27'h0;    // start training (0x00)
  localparam logic [26:0] CSR_ELEC_PARAM = 27'h8;    // electrical params (0x08)
  localparam logic [26:0] CSR_LINK_STS   = 27'h10;   // LTSM status (0x10)
  localparam logic [26:0] CSR_TRAIN_STS  = 27'h18;   // training status (0x18)

  // Standards-aligned physical layer register offsets (UCIe 1.0 Section 7.5.3):
  localparam logic [26:0] CSR_PHY_CAP    = 27'h1000; // Table 96: PHY Capability
  localparam logic [26:0] CSR_PHY_CTRL   = 27'h1004; // Table 97: PHY Control
  localparam logic [26:0] CSR_PHY_STS    = 27'h1008; // Table 98: PHY Status

  // Fixed fields from UCIe 1.0 Tables 96 through 98.
  // CAP: mode support [12:11] = 2, differential phase [14:13] = 0.
  // CAP: Standard Package [15] = 1. Unsupported analog fields read 0.
  // CONTROL and STATUS: mode [5] = 1, differential phase [6] = 0.
  // The approved continuous-only profile does not implement writable modes.
  localparam logic [31:0] PHY_CAP_CONTINUOUS_ONLY = 32'h0000_9000;
  localparam logic [31:0] PHY_CONTROL_CONTINUOUS = 32'h0000_0020;
  localparam logic [31:0] PHY_STATUS_CONTINUOUS = 32'h0000_0020;

  // =========================================================================
  // Register storage  (spec 7.1 and 7.5.3 – parameters and control)
  // =========================================================================
  // elec_param_q : Electrical parameter register. Fixed placeholder values
  //                for this reduced-capability set. Fields:
  //                  [15:0]  Supply voltage in mV (default 0x0834 = 2100 mV).
  //                  [31:16] Termination impedance (default 0x0C80 = 3200).
  //                  [63:32] Reserved.
  //
  // start_train_q: Training start bit. Writing 1 to TRAIN_CTL[0] asserts
  //                start_link_train, which causes the LTSM to exit RESET
  //                (spec 4.5.3.1).
  // =========================================================================
  logic [63:0] elec_param_q;
  logic        start_train_q;

  // =========================================================================
  // always_ff: Byte-enabled writes and private Start clear
  //
  // Only the simplified TRAIN_CTL and ELEC_PARAM registers hold writable state.
  // The Active Entry clear has priority over a concurrent Start write.
  // An electrical-parameter write still takes effect during that clear.
  // All other writes have no effect, as in the existing simplified CSR map.
  // Spec ref: UCIe 1.0 Section 7.5 and the approved continuous-only profile.
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      elec_param_q <= 64'h0000_0C80_0000_0834;
      start_train_q <= 1'b0;
    end else begin
      if (clear_start_link_train) begin
        start_train_q <= 1'b0;
      end else if (csr_wr && (csr_addr == CSR_TRAIN_CTL) && csr_be[0]) begin
        start_train_q <= csr_wdata[0];
      end
      if (csr_wr && (csr_addr == CSR_ELEC_PARAM)) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) elec_param_q[b*8 +: 8] <= csr_wdata[b*8 +: 8];
        end
      end
    end
  end

  // =========================================================================
  // assign: start_link_train - Start Link Training Trigger Driver
  //
  // Directly reflects TRAIN_CTL bit 0. When asserted, the LTSM exits RESET
  // and begins the link training sequence per Section 4.5.3.1.
  // Cleared asynchronously on reset or synchronously by clear_start_link_train.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.1 - RESET State.
  // =========================================================================
  assign start_link_train = start_train_q;

  // =========================================================================
  // always_ff: Read Path Decoding and Staging
  //
  // On csr_rd, csr_rdata is loaded with the addressed register's value and
  // csr_rdata_vld is asserted one cycle later. Standard offsets return
  // explicit free-running-only capability and status without pretending
  // complete unsupported PHY fields per UCIe 1.0 Section 7.5.3.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers;
  //           Section 7.5.3.18 - Physical Layer Capability;
  //           Section 7.5.3.19 - Physical Layer Control;
  //           Section 7.5.3.20 - Physical Layer Status.
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      csr_rdata     <= 64'h0;
      csr_rdata_vld <= 1'b0;
    end else begin
      csr_rdata_vld <= csr_rd;
      if (csr_rd) begin
        case (csr_addr)
          CSR_TRAIN_CTL : csr_rdata <= {63'b0, start_train_q};
          CSR_ELEC_PARAM: csr_rdata <= elec_param_q;
          CSR_LINK_STS  : csr_rdata <= {48'b0, ltsm_state, 7'b0, lnk_is_x8};
          CSR_TRAIN_STS : csr_rdata <= {61'b0, degrade_lanes, train_error};
          // A 64-bit read at 1000h includes the adjacent 1004h control DWORD.
          CSR_PHY_CAP   : csr_rdata <= {PHY_CONTROL_CONTINUOUS, PHY_CAP_CONTINUOUS_ONLY};
          // A 32-bit request at 1004h consumes the low DWORD, without replication.
          CSR_PHY_CTRL  : csr_rdata <= {32'h0, PHY_CONTROL_CONTINUOUS};
          CSR_PHY_STS   : csr_rdata <= {32'h0, PHY_STATUS_CONTINUOUS};
          default       : csr_rdata <= 64'h0;
        endcase
      end
    end
  end

  // =========================================================================
  // always_comb: Unused Signal Suppression
  //
  // lclk and lreset_n are consumed by the always_ff blocks above, but some
  // lint tools may flag them as combinationally unused. This explicit
  // always_comb reference silences those warnings.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // =========================================================================
  logic unused;

  // -------------------------------------------------------------------------
  // always_comb: Combinational Lint Suppression Block
  //
  // References lclk and lreset_n combinationally to satisfy linters and
  // prevent unused port warnings on tools that judge usage combinationally.
  // The assigned value is never read, so synthesis discards this block.
  //
  // Spec ref: UCIe 1.0 Specification, Section 7.5 - UCIe Registers.
  // -------------------------------------------------------------------------
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

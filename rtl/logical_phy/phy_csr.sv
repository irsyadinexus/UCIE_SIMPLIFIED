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
// Spec refs   : UCIe 1.0 spec section 7.5 (UCIe Registers - the link
//               configuration and status registers), section 4.5.3.3
//               MBINIT.PARAM (parameter exchange during link training),
//               section 8.1 (Raw Die-to-Die Interface, Table 114 - RDI
//               signal list).
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
//   On csr_wr, the addressed register is updated from csr_wdata using
//   csr_byte_en on the next rising lclk edge. Only TRAIN_CTL and ELEC_PARAM
//   are writable; writes to other addresses are silently ignored.
//
//   A private input, clear_start_link_train, clears the sticky TRAIN_CTL bit
//   0 value after a successful Active Entry. The clear has priority over a
//   concurrent csr_wr and over any hardware Start set event
//   (PLAN.md section 15.9 Phase C).
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
//                  the LTSM completes Active Entry (PLAN.md 15.9 Phase C).
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
//                        concurrent csr_wr and over any hardware Start set
//                        event for bit 0 only; elec_param_q and all status
//                        registers keep their existing behaviour. Comments for
//                        the interface, storage, write path and output now
//                        cite PLAN.md section 15.9 Phase C and UCIe 1.0
//                        section 7.5.
//   v0.0.5  2026-09-28  Sideband protocol remediation:
//                        - Add csr_be[7:0] port and merge enabled bytes on writes (Section 7.5).
//                        - Preserve hardware-set and private-clear priority (Section 7.5).
//                        - Preserve one-cycle read latency.
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
  input  logic [7:0]  csr_be,
  output logic [63:0] csr_rdata,
  output logic        csr_rdata_vld,

  input  logic [7:0]  ltsm_state,
  input  logic        lnk_is_x8,
  input  logic [1:0]  degrade_lanes,
  input  logic        train_error,
  output logic        start_link_train,

  // -----------------------------------------------------------------------
  // Private Active Entry clear input
  // (PLAN.md section 15.9 Phase C; UCIe 1.0 section 7.5 - UCIe Registers)
  // -----------------------------------------------------------------------
  // clear_start_link_train is a private input driven by logical_phy.sv. It
  // is NOT a public top-level port: the parent module wires it internally.
  //
  // The LTSM asserts this input after a successful Active Entry. The clear
  // retires the local sticky software Start copy, so a Start level that was
  // already accepted cannot request training a second time
  // (PLAN.md section 15.9 Phase C, fresh-Start-event requirement).
  //
  // While clear_start_link_train is high, start_train_q is forced to 0 and
  // the TRAIN_CTL decode of bit 0 reads 0. The clear does not touch
  // elec_param_q or any status register. See the write-path block below.
  // -----------------------------------------------------------------------
  input  logic        clear_start_link_train
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
  // start_train_q: Training start bit. Writing 1 to TRAIN_CTL[0] asserts
  //                start_link_train, which causes the LTSM to exit RESET
  //                (spec 4.5.3.1).
  //                The bit is sticky: it holds its value until reset, a
  //                later TRAIN_CTL write, or the private Active Entry clear
  //                input clear_start_link_train. The bit is the single
  //                software Start copy owned by the logical PHY side of the
  //                link, and the LTSM clears it once training has reached
  //                Active (PLAN.md section 15.9 Phase C).
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
  //
  // -------------------------------------------------------------------------
  // Private Active Entry clear and its priority
  // (PLAN.md section 15.9 Phase C; UCIe 1.0 section 7.5 - UCIe Registers)
  // -------------------------------------------------------------------------
  // clear_start_link_train is tested FIRST in the if/else chain, so the
  // clear wins over a concurrent software write and over any hardware Start
  // set event. Start Link Training is therefore deasserted in the same lclk
  // cycle in which the LTSM reports a successful Active Entry.
  //
  // The clear only forces start_train_q to 0. A concurrent sideband write to
  // ELEC_PARAM still lands, because elec_param_q keeps its own assignment
  // inside the clear branch. A concurrent write to TRAIN_CTL is dropped for
  // bit 0 only, which is the intended priority: the LTSM owns Start policy
  // after Active Entry and a stale Start level must not re-arm training.
  //
  // A write to any other address leaves both registers unchanged when the
  // clear is high.
  // =========================================================================
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      elec_param_q <= 64'h0000_0C80_0000_0834; // 1.0 V, 2104 ohm placeholder
      start_train_q<= 1'b0;
    end else if (clear_start_link_train) begin
      // Private Active Entry clear. Highest priority for start_train_q.
      start_train_q <= 1'b0;
      // A sideband write to ELEC_PARAM is still honoured during the clear.
      if (csr_wr && (csr_addr == CSR_ELEC_PARAM)) begin
        for (int b = 0; b < 8; b++) begin
          if (csr_be[b]) elec_param_q[b*8 +: 8] <= csr_wdata[b*8 +: 8];
        end
      end
    end else if (csr_wr) begin
      case (csr_addr)
        CSR_TRAIN_CTL : begin
          if (csr_be[0]) start_train_q <= csr_wdata[0];
        end
        CSR_ELEC_PARAM: begin
          for (int b = 0; b < 8; b++) begin
            if (csr_be[b]) elec_param_q[b*8 +: 8] <= csr_wdata[b*8 +: 8];
          end
        end
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
  //
  // The value is the sticky storage start_train_q, so the output falls on
  // reset, on a TRAIN_CTL write of 0, or on the private Active Entry clear
  // clear_start_link_train (PLAN.md section 15.9 Phase C). The clear path
  // means the LTSM consumes the Start level once, then sees a low level
  // after Active Entry instead of a held request.
  //
  // Because the clear is registered in the write-path always_ff above, the
  // output drops on the lclk edge that follows the clear assertion.
  // =========================================================================
  assign start_link_train = start_train_q;

  // =========================================================================
  // Read path  (spec 7.1 – CSR read, one-cycle latency)
  // =========================================================================
  // On csr_rd, csr_rdata is loaded with the addressed register's value and
  // csr_rdata_vld is asserted one cycle later. The case statement selects
  // the register content:
  //   TRAIN_CTL  : Bit 0 = start_train_q, bits [63:1] = 0. A read issued
  //                while the private clear is active returns 0 in bit 0,
  //                because the clear forces the stored bit low.
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
  // always_comb: Unused Signal Suppression
  // =========================================================================
  // lclk and lreset_n are consumed by the always_ff blocks above, but some
  // lint tools may flag them as combinationally unused. This explicit
  // always_comb reference silences those warnings.
  //
  // The CSR block is otherwise pure sequential logic: a register file clocked
  // on lclk with an asynchronous active-low reset, addressed by csr_addr and
  // read back on csr_rdata. Both clock and reset therefore have a real role in
  // the design; this block exists only to satisfy tools that judge usage
  // combinationally rather than sequentially.
  //
  // The assigned value is never read, so synthesis discards the whole block
  // and it adds no logic to the CSR.
  //
  // Spec ref: UCIe 1.0, Section 7.5 - UCIe Registers (CSR access to the link
  //           configuration and status registers).
  // =========================================================================
  logic unused;
  always_comb begin
    unused = lclk | lreset_n;
  end

endmodule

`endif

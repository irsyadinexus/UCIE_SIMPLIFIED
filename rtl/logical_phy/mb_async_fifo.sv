// ============================================================================
// File        : mb_async_fifo.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Asynchronous Clock Crossing FIFO for Main-Band Datapath
//               (500 MHz lclk <-> 2 GHz mbclk / peer fCK).
//
// ARCHITECTURAL OVERVIEW
// ~~~~~~~~~~~~~~~~~~~~~~
// This module implements an 8-entry asynchronous FIFO using conventional Gray
// code read and write pointers, dual-rank synchronizers, and coordinated reset
// assertion with independent per-domain reset release. It bridges the 128-bit
// main-band parallel word datapath across asynchronous or plesiochronous clock
// domains:
//   1. Transmit Gearbox : 500 MHz lclk (write) -> 2 GHz mbclk (read)
//   2. Receive Gearbox  : 2 GHz peer mbclk (write) -> 500 MHz lclk (read)
//
// CONVENTIONAL GRAY POINTER ARCHITECTURE
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The FIFO uses depth 8 with a 3-bit binary address space (ADDR_W = 3) and a
// 4-bit pointer space (PTR_W = 4). Binary pointers are converted to Gray code
// before crossing clock domains:
//   gray = bin ^ (bin >> 1)
// Each Gray pointer is synchronized into the opposite clock domain using a
// two-stage flip-flop synchronizer.
//
// Full and Empty detection are computed as follows:
//   - Empty : In read domain, rptr_gray == wptr_gray_sync
//   - Full  : In write domain, wptr_gray == {~rptr_gray_sync[3:2], rptr_gray_sync[1:0]}
//
// COORDINATED RESET ASSERTION AND PER-DOMAIN RELEASE
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Reset assertion is coordinated across clock domains: if either wrst_n or
// rrst_n is asserted low, both domains immediately enter reset asynchronously,
// preventing partial state updates. Reset release is performed independently
// and synchronously within each domain using dual-rank reset release
// synchronizers, ensuring recovery without glitch or metastability.
//
// ISOLATED AND BURST WORD CONSUMPTION
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The FIFO is designed to consume isolated single words boundedly without
// requiring any multi-word or 2-word pre-charge threshold. When an isolated
// word is written, the write pointer Gray code is immediately synchronized
// across the domain boundary, deasserting rempty within bounded synchronization
// latency. Back-to-back burst transfers stream continuously at full line rate.
//
// EXACTLY-ONCE OUTPUT AND OVERFLOW REJECTION
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// In the read domain, each pushed word is presented at the output and popped
// exactly once per transfer cycle. If a write is attempted when the FIFO is
// full (winc && wfull), the write is rejected to preserve memory contents,
// and a sticky overflow error flag is asserted until reset.
//
// Spec References
// ~~~~~~~~~~~~~~~
//   UCIe 1.0 Section 4.1.2 - Valid Framing and Transfer Windows
//   UCIe 1.0 Section 5.2   - Main-Band Signalling and Forwarded Clock
//   UCIe 1.0 Section 8.1.2 - Interface Clocking Requirements
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-10-09  Initial contract implementation of depth-8 Gray
//                       asynchronous FIFO with coordinated reset assertion,
//                       per-domain release, and exactly-once output.
//   v0.0.2  2026-10-09  Gate reset-time memory writes and define read-head timing.
//                       Derive widths from power-of-two DEPTH, at least two.
//                       Register full and empty to avoid combinational loops.
// ============================================================================

`ifndef MbAsyncFifo_SV
`define MbAsyncFifo_SV
`include "ucie_pkg.sv"

`timescale 1ns/1ps
module mb_async_fifo #(
  parameter int unsigned DATA_W = 128,               // Data word payload width
  parameter int unsigned DEPTH  = 8                  // FIFO buffer depth (entries)
) (
  // Write clock domain ports
  input  logic              wclk,                    // Write domain clock
  input  logic              wrst_n,                  // Write domain active-low reset
  input  logic              winc,                    // Write increment / push strobe
  input  logic [DATA_W-1:0] wdata,                   // Write payload data
  output logic              wfull,                   // FIFO full flag (write domain)
  output logic              walmost_full,            // Almost full flag (write domain)
  output logic              woverflow,               // Sticky overflow error flag
  output logic              woverflow_pulse,         // Single-cycle overflow pulse

  // Read clock domain ports
  input  logic              rclk,                    // Read domain clock
  input  logic              rrst_n,                  // Read domain active-low reset
  input  logic              rinc,                    // Read increment / pop strobe
  output logic [DATA_W-1:0] rdata,                   // Read payload data
  output logic              rempty,                  // FIFO empty flag (read domain)
  output logic              rvalid,                  // Read valid flag (head is valid)
  output logic              runderflow               // Single-cycle underflow pulse
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);      // Power-of-two address width
  localparam int unsigned PTR_W = ADDR_W + 1;        // Address plus wrap bit
  localparam logic [PTR_W-1:0] FULL_MASK =
      (PTR_W'(1) << ADDR_W) | (PTR_W'(1) << (ADDR_W-1));

  // -------------------------------------------------------------------------
  // Internal signal declarations
  // -------------------------------------------------------------------------
  logic              coordinated_rst_n;              // Combined asynchronous reset
  logic [1:0]        wrst_sync_q;                    // Write reset synchronizer flops
  logic              wreset_n_eff;                   // Effective write domain reset
  logic [1:0]        rrst_sync_q;                    // Read reset synchronizer flops
  logic              rreset_n_eff;                   // Effective read domain reset

  logic [DATA_W-1:0] mem [0:DEPTH-1];                // Memory storage array
  logic [PTR_W-1:0]  wptr_bin_q;                     // Write binary pointer register
  logic [PTR_W-1:0]  wptr_gray_q;                    // Write Gray pointer register
  logic [PTR_W-1:0]  rptr_bin_q;                     // Read binary pointer register
  logic [PTR_W-1:0]  rptr_gray_q;                    // Read Gray pointer register
  logic [PTR_W-1:0]  wptr_gray_sync1_q;              // Write Gray sync rank 1
  logic [PTR_W-1:0]  wptr_gray_sync2_q;              // Write Gray sync rank 2
  logic [PTR_W-1:0]  rptr_gray_sync1_q;              // Read Gray sync rank 1
  logic [PTR_W-1:0]  rptr_gray_sync2_q;              // Read Gray sync rank 2

  logic [ADDR_W-1:0] waddr;                          // Write array address
  logic [ADDR_W-1:0] raddr;                          // Read array address

  logic [PTR_W-1:0]  wptr_bin_next;                  // Next write binary pointer
  logic [PTR_W-1:0]  wptr_gray_next;                 // Next write Gray pointer
  logic [PTR_W-1:0]  rptr_bin_next;                  // Next read binary pointer
  logic [PTR_W-1:0]  rptr_gray_next;                 // Next read Gray pointer

  logic              wfull_val;                      // Next write full value
  logic              rempty_val;                     // Next read empty value
  logic [PTR_W-1:0]  rptr_bin_synced;                // Read pointer converted to binary
  logic [PTR_W-1:0]  woccupancy;                     // Estimated FIFO occupancy count

  // -------------------------------------------------------------------------
  // assign: coordinated_rst_n - Coordinated Reset Assertion
  //
  // Coordinates reset assertion across both write and read domains. If either
  // wrst_n or rrst_n is pulled low, coordinated_rst_n immediately asserts low
  // asynchronously, forcing all internal storage and synchronizers into reset.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2 - Interface clocking.
  // -------------------------------------------------------------------------
  assign coordinated_rst_n = wrst_n & rrst_n;

  // -------------------------------------------------------------------------
  // always_ff: Write Domain Reset Release Synchronizer
  //
  // Releases reset synchronously to wclk using a two-stage synchronizer.
  // Ensures clean deassertion without metastability in the write domain.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2 - Clock domains.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk or negedge coordinated_rst_n) begin
    if (!coordinated_rst_n) begin
      wrst_sync_q <= 2'b00;
    end else begin
      wrst_sync_q <= {wrst_sync_q[0], 1'b1};
    end
  end

  // -------------------------------------------------------------------------
  // assign: wreset_n_eff - Effective Write Domain Reset
  //
  // Active-low synchronized reset signal for all write-domain registers.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2.
  // -------------------------------------------------------------------------
  assign wreset_n_eff = wrst_sync_q[1];

  // -------------------------------------------------------------------------
  // always_ff: Read Domain Reset Release Synchronizer
  //
  // Releases reset synchronously to rclk using a two-stage synchronizer.
  // Ensures clean deassertion without metastability in the read domain.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2 - Clock domains.
  // -------------------------------------------------------------------------
  always_ff @(posedge rclk or negedge coordinated_rst_n) begin
    if (!coordinated_rst_n) begin
      rrst_sync_q <= 2'b00;
    end else begin
      rrst_sync_q <= {rrst_sync_q[0], 1'b1};
    end
  end

  // -------------------------------------------------------------------------
  // assign: rreset_n_eff - Effective Read Domain Reset
  //
  // Active-low synchronized reset signal for all read-domain registers.
  //
  // Spec ref: UCIe 1.0 Specification, Section 8.1.2.
  // -------------------------------------------------------------------------
  assign rreset_n_eff = rrst_sync_q[1];

  // -------------------------------------------------------------------------
  // assign: waddr - Write Buffer Address Index
  //
  // Derives the memory write slot address from the lower bits of wptr_bin_q.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Datapath.
  // -------------------------------------------------------------------------
  assign waddr = wptr_bin_q[ADDR_W-1:0];

  // -------------------------------------------------------------------------
  // assign: raddr - Read Buffer Address Index
  //
  // Derives the memory read slot address from the lower bits of rptr_bin_q.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Datapath.
  // -------------------------------------------------------------------------
  assign raddr = rptr_bin_q[ADDR_W-1:0];

  // -------------------------------------------------------------------------
  // always_ff: FIFO Dual-Port RAM Write Operation
  //
  // Stores write data word at waddr when write increment is enabled and the
  // FIFO is not full. Rejects write if full to prevent buffer corruption.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk) begin
    if (wreset_n_eff && winc && !wfull) begin
      mem[waddr] <= wdata;
    end
  end

  // -------------------------------------------------------------------------
  // assign: wptr_bin_next - Next Write Binary Pointer
  //
  // Increments write binary pointer when winc is asserted and not full.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2.
  // -------------------------------------------------------------------------
  assign wptr_bin_next  = wptr_bin_q + PTR_W'(wreset_n_eff && winc && !wfull);

  // -------------------------------------------------------------------------
  // assign: wptr_gray_next - Next Write Gray Pointer
  //
  // Converts next write binary pointer to conventional Gray code.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded Clock CDC.
  // -------------------------------------------------------------------------
  assign wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;

  // -------------------------------------------------------------------------
  // always_ff: Write Domain Binary and Gray Pointer Registers
  //
  // Advances write binary and Gray code pointers on each rising wclk edge.
  // Resets both pointers to zero synchronously to wreset_n_eff.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Transfers.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk or negedge wreset_n_eff) begin
    if (!wreset_n_eff) begin
      wptr_bin_q  <= {PTR_W{1'b0}};
      wptr_gray_q <= {PTR_W{1'b0}};
    end else begin
      wptr_bin_q  <= wptr_bin_next;
      wptr_gray_q <= wptr_gray_next;
    end
  end

  // -------------------------------------------------------------------------
  // assign: rptr_bin_next - Next Read Binary Pointer
  //
  // Increments read binary pointer when rinc is asserted and not empty.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2.
  // -------------------------------------------------------------------------
  assign rptr_bin_next  = rptr_bin_q + PTR_W'(rreset_n_eff && rinc && !rempty);

  // -------------------------------------------------------------------------
  // assign: rptr_gray_next - Next Read Gray Pointer
  //
  // Converts next read binary pointer to conventional Gray code.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded Clock CDC.
  // -------------------------------------------------------------------------
  assign rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

  // -------------------------------------------------------------------------
  // always_ff: Read Domain Binary and Gray Pointer Registers
  //
  // Advances read binary and Gray code pointers on each rising rclk edge.
  // Resets both pointers to zero synchronously to rreset_n_eff.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Transfers.
  // -------------------------------------------------------------------------
  always_ff @(posedge rclk or negedge rreset_n_eff) begin
    if (!rreset_n_eff) begin
      rptr_bin_q  <= {PTR_W{1'b0}};
      rptr_gray_q <= {PTR_W{1'b0}};
    end else begin
      rptr_bin_q  <= rptr_bin_next;
      rptr_gray_q <= rptr_gray_next;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: Synchronize Read Pointer into Write Clock Domain
  //
  // Two-stage synchronizer passing rptr_gray_q into wclk domain.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded clock CDC.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk or negedge wreset_n_eff) begin
    if (!wreset_n_eff) begin
      rptr_gray_sync1_q <= {PTR_W{1'b0}};
      rptr_gray_sync2_q <= {PTR_W{1'b0}};
    end else begin
      rptr_gray_sync1_q <= rptr_gray_q;
      rptr_gray_sync2_q <= rptr_gray_sync1_q;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: Synchronize Write Pointer into Read Clock Domain
  //
  // Two-stage synchronizer passing wptr_gray_q into rclk domain.
  //
  // Spec ref: UCIe 1.0 Specification, Section 5.2 - Forwarded clock CDC.
  // -------------------------------------------------------------------------
  always_ff @(posedge rclk or negedge rreset_n_eff) begin
    if (!rreset_n_eff) begin
      wptr_gray_sync1_q <= {PTR_W{1'b0}};
      wptr_gray_sync2_q <= {PTR_W{1'b0}};
    end else begin
      wptr_gray_sync1_q <= wptr_gray_q;
      wptr_gray_sync2_q <= wptr_gray_sync1_q;
    end
  end

  // -------------------------------------------------------------------------
  // assign: wfull_val - Conventional Gray Code Full Condition Evaluation
  //
  // Conventional Gray full check: MSB and MSB-1 inverted, lower bits match.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Flow Control.
  // -------------------------------------------------------------------------
  assign wfull_val = (wptr_gray_next == (rptr_gray_sync2_q ^ FULL_MASK));

  // -------------------------------------------------------------------------
  // always_ff: Write Domain Full Flag Register
  //
  // Evaluates and flops full flag on wclk posedge to provide glitch-free flag.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Flow Control.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk or negedge wreset_n_eff) begin
    if (!wreset_n_eff) begin
      wfull <= 1'b0;
    end else begin
      wfull <= wfull_val;
    end
  end

  // -------------------------------------------------------------------------
  // Gray-to-Binary Conversion Function for Occupancy Calculation
  // -------------------------------------------------------------------------
  function automatic logic [PTR_W-1:0] gray_to_bin(
    input logic [PTR_W-1:0] g                       // Gray code input pointer
  );
    logic [PTR_W-1:0] b;                            // Converted binary pointer
    begin
      b[PTR_W-1] = g[PTR_W-1];
      for (int bit_idx = PTR_W-2; bit_idx >= 0; bit_idx = bit_idx-1) begin
        b[bit_idx] = b[bit_idx+1] ^ g[bit_idx];
      end
      gray_to_bin = b;
    end
  endfunction

  // -------------------------------------------------------------------------
  // assign: rptr_bin_synced - Read Gray Pointer Converted to Binary
  //
  // Recovers binary read pointer in write clock domain for occupancy tracking.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Flow Control.
  // -------------------------------------------------------------------------
  assign rptr_bin_synced = gray_to_bin(rptr_gray_sync2_q);

  // -------------------------------------------------------------------------
  // assign: woccupancy - Write Domain Buffer Occupancy Depth
  //
  // Calculates estimated word count currently present in the buffer.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Flow Control.
  // -------------------------------------------------------------------------
  assign woccupancy = wptr_bin_q - rptr_bin_synced;

  // -------------------------------------------------------------------------
  // assign: walmost_full - Almost Full Flag Evaluation
  //
  // Asserts after local release when occupancy reaches DEPTH minus two entries.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Flow Control.
  // -------------------------------------------------------------------------
  assign walmost_full = wreset_n_eff && (woccupancy >= PTR_W'(DEPTH-2));

  // -------------------------------------------------------------------------
  // always_ff: Write Domain Overflow Error Detection
  //
  // Asserts woverflow_pulse on write when full, and latches sticky woverflow.
  // Common FIFO reset clears this history, including an epoch flush.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.5.3.8 - Fatal containment.
  // -------------------------------------------------------------------------
  always_ff @(posedge wclk or negedge wreset_n_eff) begin
    if (!wreset_n_eff) begin
      woverflow       <= 1'b0;
      woverflow_pulse <= 1'b0;
    end else begin
      woverflow_pulse <= winc && wfull;
      if (winc && wfull) begin
        woverflow <= 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // assign: rempty_val - Conventional Gray Code Empty Condition Evaluation
  //
  // Empty check: read Gray pointer matches synchronized write Gray pointer.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2.
  // -------------------------------------------------------------------------
  assign rempty_val = (rptr_gray_next == wptr_gray_sync2_q);

  // -------------------------------------------------------------------------
  // always_ff: Read Domain Empty Flag Register
  //
  // Evaluates and flops empty flag on rclk posedge to provide glitch-free flag.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2.
  // -------------------------------------------------------------------------
  always_ff @(posedge rclk or negedge rreset_n_eff) begin
    if (!rreset_n_eff) begin
      rempty <= 1'b1;
    end else begin
      rempty <= rempty_val;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff: Read Domain Underflow Error Strobe
  //
  // Asserts single-cycle underflow pulse when rinc is asserted while empty.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2.
  // -------------------------------------------------------------------------
  always_ff @(posedge rclk or negedge rreset_n_eff) begin
    if (!rreset_n_eff) begin
      runderflow <= 1'b0;
    end else begin
      runderflow <= rinc && rempty;
    end
  end

  // -------------------------------------------------------------------------
  // assign: rdata - FIFO Output Data Word Bus
  //
  // Presents the current head before the edge that accepts rinc.
  // The output is zero when rvalid is low. It is not a completed-pop register.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Word Datapath.
  // -------------------------------------------------------------------------
  assign rdata  = rvalid ? mem[raddr] : '0;

  // -------------------------------------------------------------------------
  // assign: rvalid - FIFO Output Data Valid Qualifier
  //
  // High after local reset release when a readable memory head exists.
  //
  // Spec ref: UCIe 1.0 Specification, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  assign rvalid = rreset_n_eff && !rempty;

endmodule

`endif

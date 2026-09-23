// ============================================================================
// File        : mb_gearbox.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Main-band DDR serialiser / deserialiser (gearbox) for the
//               4 GT/s physical interface (Req.2).
//
// PHYSICAL LAYER MODEL (spec 4.1.1, 5.2)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// At 4 GT/s the main band runs at fCK = 2 GHz with DDR (double data rate)
// transfer: one bit per lane per clock edge, giving 4 GT/s per lane. The RDI
// side runs on lclk = 500 MHz with a 128-bit data bus (NBYTES = 16). Both
// sides carry the same payload expressed two ways:
//
//   128 b @ 500 MHz (single-edge lclk) = 64 Gbps
//    32 b @ 2 GHz   (per mbclk cycle)  = 32 b x 2 GHz   = 64 Gbps
//
// A DDR clock cycle moves 32 bits: 16 bits (one per lane) on the rising
// (high) phase and 16 bits on the falling (low) phase. One lclk word is
// therefore four mbclk cycles = eight UIs, and each lane carries eight bits
// (one byte) per word.
//
// LANE MAPPING (spec 4.1.1 - byte k on lane k, bit 0 first)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// A UI is one DDR edge. At UI u (u = 0..7) lane L carries bit
// `sample_word[8*L + u]`: byte L of the word is transported on lane L, one
// bit per UI, least-significant bit first. Equivalently, over the eight UIs
// of a word, lane L carries the byte sample_word[8*L +: 8].
//
// The serializer therefore GATHERS one bit from each lane byte per UI; it is
// not a contiguous slice of the word. A contiguous-slice serializer happens
// to round-trip in a loopback because transmitter and receiver transpose
// identically, so the unit test checks the wire directly against the
// per-lane equation above.
//
// CLOCK RELATIONSHIP (explicit phase contract)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// mbclk (fCK, 2 GHz) is exactly 4x lclk (500 MHz) and phase-locked to it
// (fCK is the forwarded clock from the same PLL in this model). One lclk
// cycle contains four mbclk cycles and eight mbclk edges. The contract is:
//
//   cycle c spans [cT, (c+1)T) with posedge at cT and negedge at cT + T/2.
//   rising  (high) phase carries UI 2c   (bit 2c   of every lane byte)
//   falling (low)  phase carries UI 2c+1 (bit 2c+1 of every lane byte)
//
// SYNTHESIS DISCIPLINE
// ~~~~~~~~~~~~~~~~~~~~
// Every flop below is a single-edge flop. There is deliberately NO
// `always @(a or b)` two-edge construct, which would not be a portable
// synthesizable flip-flop. DDR behaviour is expressed as follows:
//
//   TX : registered `ser_q` word, cycle counter and framing snapshot; the
//        pin is a combinational per-lane gather selected by the mbclk level
//        in an explicit I/O wrapper region.
//   RX : a `negedge mbclk` register captures the high-phase lane vector; the
//        `posedge mbclk` assembler scatters it plus the low-phase lane vector
//        into the word. Both are single-edge flops.
//
// Port Summary
// ~~~~~~~~~~~~
//   tx_gearbox : lclk, lreset_n, mbclk, tx_word[127:0], tx_valid, tx_load,
//                mb_tx_data[15:0], mb_tx_valid
//   rx_gearbox : lclk, lreset_n, mbclk, mb_rx_data[15:0], mb_rx_valid,
//                rx_word[127:0], rx_word_vld
//
// Spec References
// ~~~~~~~~~~~~~~~
//   4.1.1  - lane and width definitions, byte-to-lane mapping, DDR transfer
//   5.2    - main band signalling, forwarded clock (fCK)
//   8.1.2  - lclk = fCK/4 at 4 GT/s with NBYTES = 16
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ---------------  ----------  -------------------------------------------
//   0.0.1 2026-09-23  -           First commit to git. TX/RX DDR gearboxes
//                                     for the 4 GT/s main band with the
//   0.0.2 2026-09-23  Req.2: collapse the per-lane phase gather into one
//                                    always @* with a case on cyc_q, and use
//                                    an NBA on the DDR pin mux, so Icarus
//                                    keeps the 2 GHz event queue small.
// ============================================================================
`ifndef MbGearbox_SV
`define MbGearbox_SV
`include "ucie_pkg.sv"

// ===========================================================================
// tx_gearbox: parallel 128-bit lclk word -> per-lane DDR slices on mbclk.
// ===========================================================================
`timescale 1ns/1ps
module tx_gearbox #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,  // 16 bytes = 128-bit word
  parameter int unsigned NLANES = ucie_pkg::NLANES_MAX, // 16 lanes
  parameter int unsigned NSLICE = 8                  // UI slices per word
) (
  input  logic                 lclk,
  input  logic                 lreset_n,
  input  logic                 mbclk,       // 2 GHz forwarded clock (fCK)
  input  logic [NBYTES*8-1:0]  tx_word,     // one word per lclk
  input  logic                 tx_valid,    // current word is a real beat
  input  logic                 tx_load,     // 1-cycle strobe: sample word
  output logic [NLANES-1:0]    mb_tx_data,  // DDR output, 1 bit/lane/edge
  output logic                 mb_tx_valid  // framing bit, per mbclk edge
);

  localparam int unsigned NCYC  = NSLICE / 2;   // 4 mbclk cycles per word
  localparam int unsigned CYC_W = 2;            // 0..3 cycle counter
  localparam logic [CYC_W-1:0] LAST_CYC = CYC_W'(NCYC-1);

  // -----------------------------------------------------------------------
  // lclk domain: word and framing registers. Single writer each. valid_q
  // clears whenever no word is loaded, so an idle lclk deasserts framing.
  // -----------------------------------------------------------------------
  logic [NBYTES*8-1:0] word_q;
  logic                valid_q;

  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      word_q  <= {NBYTES*8{1'b0}};
      valid_q <= 1'b0;
    end else begin
      valid_q <= tx_load && tx_valid;
      if (tx_load) word_q <= tx_word;
    end
  end

  // -----------------------------------------------------------------------
  // mbclk domain: word snapshot, framing snapshot and cycle counter. Single
  // writer for each. The snapshot is preloaded at the last cycle so all four
  // cycles of the next word read one stable copy (no tearing).
  // -----------------------------------------------------------------------
  logic [NBYTES*8-1:0] ser_q;
  logic                ser_val_q;
  logic [CYC_W-1:0]    cyc_q;

  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) begin
      ser_q     <= {NBYTES*8{1'b0}};
      ser_val_q <= 1'b0;
      cyc_q     <= {CYC_W{1'b0}};
    end else begin
      if (cyc_q == LAST_CYC) begin
        ser_q     <= word_q;      // preload next word data ...
        ser_val_q <= valid_q;     // ... and its framing together
      end
      cyc_q <= (cyc_q == LAST_CYC) ? {CYC_W{1'b0}} : cyc_q + 1'b1;
    end
  end

  // -----------------------------------------------------------------------
  // I/O wrapper region: per-lane gather for the two phases. At UI u lane L
  // drives bit (8*L + u) of the word snapshot. Constant bit indices per
  // cycle keep the selectors synthesizable.
  // -----------------------------------------------------------------------
  logic [NLANES-1:0] hi_w, lo_w;

  always @* begin
    case (cyc_q)
      2'd0: begin
        for (int l = 0; l < NLANES; l = l + 1) begin
          hi_w[l] = ser_q[8*l+0];
          lo_w[l] = ser_q[8*l+1];
        end
      end
      2'd1: begin
        for (int l = 0; l < NLANES; l = l + 1) begin
          hi_w[l] = ser_q[8*l+2];
          lo_w[l] = ser_q[8*l+3];
        end
      end
      2'd2: begin
        for (int l = 0; l < NLANES; l = l + 1) begin
          hi_w[l] = ser_q[8*l+4];
          lo_w[l] = ser_q[8*l+5];
        end
      end
      default: begin
        for (int l = 0; l < NLANES; l = l + 1) begin
          hi_w[l] = ser_q[8*l+6];
          lo_w[l] = ser_q[8*l+7];
        end
      end
    endcase
  end
  // Uses NBA so output transitions cleanly in the inactive region of the edge.
  logic [NLANES-1:0] tx_mux;
  always @(mbclk or hi_w or lo_w) tx_mux <= mbclk ? hi_w : lo_w;
  assign mb_tx_data  = tx_mux;
  assign mb_tx_valid = ser_val_q;
endmodule

// ===========================================================================
// rx_gearbox: per-lane DDR slices on mbclk -> parallel 128-bit lclk word.
// ===========================================================================
`timescale 1ns/1ps
module rx_gearbox #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NLANES = ucie_pkg::NLANES_MAX,
  parameter int unsigned NSLICE = 8
) (
  input  logic                 lclk,
  input  logic                 lreset_n,
  input  logic                 mbclk,
  input  logic [NLANES-1:0]    mb_rx_data,  // DDR input, 1 bit/lane/edge
  input  logic                 mb_rx_valid, // framing bit, per mbclk edge
  output logic [NBYTES*8-1:0]  rx_word,     // assembled word, lclk domain
  output logic                 rx_word_vld  // 1-cycle strobe: rx_word valid
);

  localparam int unsigned NCYC  = NSLICE / 2;
  localparam int unsigned CYC_W = 2;
  localparam logic [CYC_W-1:0] LAST_CYC = CYC_W'(NCYC-1);

  // -----------------------------------------------------------------------
  // negedge mbclk: capture the high-phase lane vector. The pin carries the
  // even UI for the whole high phase, so this register takes bit 2c of every
  // lane. Single writer.
  // -----------------------------------------------------------------------
  logic [NLANES-1:0] even_cap_q;

  always_ff @(negedge mbclk or negedge lreset_n) begin
    if (!lreset_n) even_cap_q <= {NLANES{1'b0}};
    else           even_cap_q <= mb_rx_data;
  end

  // -----------------------------------------------------------------------
  // posedge mbclk: scatter one UI pair per cycle. Just before this edge the
  // pin carries the odd UI, so lane L supplies bit 2c+1 from mb_rx_data and
  // bit 2c from even_cap_q. A completed word is copied whole into
  // word_hold_q on the last cycle so the lclk domain never reads a partially
  // assembled buffer.
  // -----------------------------------------------------------------------
  logic [NBYTES*8-1:0] asm_q;
  logic [NBYTES*8-1:0] word_hold_q;
  logic [CYC_W-1:0]    cyc_q;
  logic                asm_val_q;

  // One single-edge process owns asm_q, word_hold_q, cyc_q and asm_val_q, so
  // no two blocks write slices of the same vector.
  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) begin
      asm_q       <= {NBYTES*8{1'b0}};
      word_hold_q <= {NBYTES*8{1'b0}};
      cyc_q       <= {CYC_W{1'b0}};   // phase 0: matches the TX phase
      asm_val_q   <= 1'b0;
    end else begin
      for (int l = 0; l < NLANES; l = l + 1) begin
        case (cyc_q)
          2'd0: begin asm_q[8*l+0] <= even_cap_q[l];
                      asm_q[8*l+1] <= mb_rx_data[l]; end
          2'd1: begin asm_q[8*l+2] <= even_cap_q[l];
                      asm_q[8*l+3] <= mb_rx_data[l]; end
          2'd2: begin asm_q[8*l+4] <= even_cap_q[l];
                      asm_q[8*l+5] <= mb_rx_data[l]; end
          default: begin asm_q[8*l+6] <= even_cap_q[l];
                         asm_q[8*l+7] <= mb_rx_data[l]; end
        endcase
        if (cyc_q == LAST_CYC) begin
          // Build the held byte explicitly from the current pair plus the
          // prior six bits: bit 7 = mb_rx_data[l], bit 6 = even_cap_q[l]
          word_hold_q[8*l +: 8] <= {mb_rx_data[l], even_cap_q[l],
                                    asm_q[8*l +: 6]};
        end
      end
      if (cyc_q == LAST_CYC) asm_val_q <= mb_rx_valid;
      cyc_q <= (cyc_q == LAST_CYC) ? {CYC_W{1'b0}} : cyc_q + 1'b1;
    end
  end
  // lclk domain: present the completed, stable word and its framing strobe.
  // -----------------------------------------------------------------------
  always_ff @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n) begin
      rx_word     <= {NBYTES*8{1'b0}};
      rx_word_vld <= 1'b0;
    end else begin
      rx_word     <= word_hold_q;
      rx_word_vld <= asm_val_q;
    end
  end

endmodule

`endif

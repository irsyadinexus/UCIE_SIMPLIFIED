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
// VALID FRAMING AND THE PRIVATE FAULT (spec 4.1.2, PLAN.md 6.2)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Valid is asserted for the FIRST FOUR UI of each eight-UI transfer. One
// mbclk cycle carries two UI (high phase = UI 2c, low phase = UI 2c+1), so
// the legal per-cycle framing pattern of a transfer window is
//
//   mbclk cycle : 0    1    2    3
//   UI          : 0,1  2,3  4,5  6,7
//   valid       : 1    1    0    0      (word in flight)
//   valid       : 0    0    0    0      (idle)
//
// The transmitter asserts mb_tx_valid only in cycles 0 and 1 of a window that
// carries a real beat. rx_gearbox checks the same pattern: it latches the
// qualifier level of cycle 0 as the window reference and requires cycles 1, 2
// and 3 to carry 1, 0 and 0. Any other level is a framing violation - an
// early transition (the qualifier falls inside the valid window or rises in
// the middle of an idle window), a late transition (the qualifier is still
// high after the fourth UI), or a receive window that is not a transfer
// window at all. The receiver then rejects the assembled word, so no
// rx_word_vld pulse is produced, and the sticky `framing_fault` output records
// the condition. It is private: only the logical PHY reads it, it holds until
// lreset_n, and no public port exposes it.
//
// Port Summary
// ~~~~~~~~~~~~
//   tx_gearbox : lclk, lreset_n, mbclk, tx_word[127:0], tx_valid, tx_load,
//                mb_tx_data[15:0], mb_tx_valid
//   rx_gearbox : lclk, lreset_n, mbclk, mb_rx_data[15:0], mb_rx_valid,
//                rx_word[127:0], rx_word_vld, framing_fault
//
// Spec References
// ~~~~~~~~~~~~~~~
//   4.1.1  - lane and width definitions, byte-to-lane mapping, DDR transfer
//   4.1.2  - valid framing: valid asserted for the first four UI of each
//            eight-UI transfer
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
//   0.0.3 2026-09-23  -           Documentation: add per-construct comment
//                                    blocks with spec references.
//   0.0.4 2026-09-25  Phase E: add the private sticky `framing_fault`
//                                    output to rx_gearbox and its four-cycle
//                                    valid-framing boundary monitor. No
//                                    public port changes.
//   0.0.5 2026-09-25  Phase E: assert mb_tx_valid in mbclk cycles 0 and 1
//                                    only, that is the first four UI of the
//                                    eight-UI transfer (PLAN.md 6.2), and
//                                    require the same 1100 pattern in the
//                                    rx boundary monitor. The monitor now
//                                    rejects early, late, or malformed
//                                    framing, suppresses the word strobe for
//                                    a rejected window, and keeps the fault
//                                    sticky until lreset_n. No public port
//                                    changes.
// ============================================================================
`ifndef MbGearbox_SV
`define MbGearbox_SV
`include "ucie_pkg.sv"

// ===========================================================================
// tx_gearbox: parallel 128-bit lclk word -> per-lane DDR slices on mbclk,
//             with the four-UI valid-framing qualifier.
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
  output logic                 mb_tx_valid  // framing qualifier: high in
                                            // mbclk cycles 0 and 1, low in
                                            // cycles 2 and 3 (first four UI)
);

  localparam int unsigned NCYC  = NSLICE / 2;   // 4 mbclk cycles per word
  localparam int unsigned CYC_W = 2;            // 0..3 cycle counter
  localparam logic [CYC_W-1:0] LAST_CYC = CYC_W'(NCYC-1);
  // Last mbclk cycle whose two UI lie inside the four-UI valid window
  // (spec 4.1.2, PLAN.md 6.2): UI 0..3 of an eight-UI transfer are the two UI
  // of cycle 0 and the two UI of cycle 1, so valid is high for cycles 0 and 1.
  localparam logic [CYC_W-1:0] LAST_VALID_CYC = CYC_W'(NSLICE/4 - 1);

  // -------------------------------------------------------------------------
  // always_ff: lclk Domain Word and Framing Registers
  //
  // Captures the 128-bit TX word and its valid qualifier from the RDI /
  // logical-PHY datapath on each posedge lclk.  word_q holds the data
  // and valid_q holds the framing flag.  Both are single-writer
  // registers in the lclk domain.
  //
  // valid_q is set only when both tx_load and tx_valid are asserted in
  // the same cycle; otherwise it clears, ensuring the framing bit on
  // the mainband deasserts during idle lclk cycles. The mbclk framing
  // generator below additionally limits the qualifier to the first four UI
  // of the transfer (spec 4.1.2, PLAN.md 6.2).
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always_ff: mbclk Domain Snapshot and Cycle Counter
  //
  // Runs on posedge mbclk (2 GHz forwarded clock, spec Section 5.2).
  // Maintains three registers:
  //   ser_q     — 128-bit word snapshot used by the phase-gather mux.
  //   ser_val_q — framing-valid snapshot; mb_tx_valid gates it with the
  //               four-UI valid window of the mbclk cycle counter.
  //   cyc_q     — 2-bit cycle counter (0..3), one count per mbclk cycle.
  //
  // Single-edge-flop snapshot discipline: ser_q and ser_val_q are
  // PRELOADED on the last cycle (cyc_q == LAST_CYC) from the lclk-
  // domain registers word_q and valid_q.  This ensures the snapshot is
  // stable for all four mbclk cycles of the next word — no tearing is
  // possible because the lclk register is written only once per four
  // mbclk cycles and the snapshot is taken at a deterministic phase.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview (forwarded clock);
  //           Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always @*: Per-Lane Phase-Gather Combinational Mux
  //
  // Implements the spec 4.1.1 equation:  mb_tx_data[lane] = word[8*lane + u]
  //
  // At each mbclk cycle c (c = cyc_q = 0..3), two UIs are transmitted
  // per lane:
  //   hi_w[L] = ser_q[8*L + 2*c]     (rising / high phase, even UI)
  //   lo_w[L] = ser_q[8*L + 2*c + 1] (falling / low phase, odd UI)
  //
  // The case statement selects constant bit indices per cycle so the
  // gather is a pure wiring mux with no barrel shifter, keeping the
  // combinational depth minimal.  Each lane independently picks one
  // bit from its own byte — this is the GATHER operation (not a
  // contiguous-slice shift).
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // always: DDR Pin Mux — Level-Sensitive Output Selection
  //
  // Selects hi_w (rising-phase data) when mbclk is high and lo_w
  // (falling-phase data) when mbclk is low.  Uses a non-blocking
  // assignment (NBA) so the output transitions cleanly in the inactive
  // region of the simulation event queue, avoiding glitches in Icarus
  // Verilog's 2 GHz scheduler.  This is NOT a registered flop — it is
  // an event-driven latch-like construct that models the DDR output
  // buffer behaviour on the forwarded clock.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview (forwarded clock DDR).
  // -------------------------------------------------------------------------
  // Uses NBA so output transitions cleanly in the inactive region of the edge.
  logic [NLANES-1:0] tx_mux;
  always @(mbclk or hi_w or lo_w) tx_mux <= mbclk ? hi_w : lo_w;

  // -------------------------------------------------------------------------
  // assign: Main-Band TX Data Output
  //
  // Drives the 16-lane main-band transmit data bus from the DDR pin
  // mux (tx_mux).  This is a direct wire alias with no additional
  // logic — the per-lane bit selection is handled entirely by the
  // phase-gather combinational mux and the DDR pin mux above.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  assign mb_tx_data  = tx_mux;

  // -------------------------------------------------------------------------
  // assign: Main-Band TX Valid / Framing Output
  //
  // Drives the framing qualifier of the main-band transmit bus from the mbclk
  // cycle counter and the valid snapshot for the word in ser_q:
  //
  //   cyc_q       : 0    1    2    3
  //   UI          : 0,1  2,3  4,5  6,7
  //   mb_tx_valid : 1    1    0    0      (ser_val_q = 1)
  //   mb_tx_valid : 0    0    0    0      (ser_val_q = 0, idle)
  //
  // Valid framing asserts the qualifier for the FIRST FOUR UI of each eight-UI
  // transfer (spec 4.1.2, PLAN.md 6.2), and one mbclk cycle carries two UI, so
  // the AND with `cyc_q <= LAST_VALID_CYC` produces the legal pattern for a
  // real beat and a constant low while idle. The level changes only at the
  // half-transfer boundary or at a word boundary, never inside a phase, so the
  // receiver sees one unchanged level per mbclk cycle.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Section 6.2 - Valid framing.
  // -------------------------------------------------------------------------
  assign mb_tx_valid = ser_val_q && (cyc_q <= LAST_VALID_CYC);
endmodule

// ===========================================================================
// rx_gearbox: per-lane DDR slices on mbclk -> parallel 128-bit lclk word,
//             with the private sticky framing-pattern fault monitor.
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
  input  logic                 mb_rx_valid, // framing qualifier: 1,1,0,0 per
                                            // eight-UI transfer window
  output logic [NBYTES*8-1:0]  rx_word,     // assembled word, lclk domain
  output logic                 rx_word_vld, // 1-cycle strobe: rx_word valid
  output logic                 framing_fault // private sticky boundary fault
);

  localparam int unsigned NCYC  = NSLICE / 2;
  localparam int unsigned CYC_W = 2;
  localparam logic [CYC_W-1:0] LAST_CYC = CYC_W'(NCYC-1);
  // Last mbclk cycle whose two UI lie inside the four-UI valid window
  // (spec 4.1.2, PLAN.md 6.2): the legal framing pattern of a transfer window
  // is high in cycles 0 and 1 and low in cycles 2 and 3.
  localparam logic [CYC_W-1:0] LAST_VALID_CYC = CYC_W'(NSLICE/4 - 1);

  // -------------------------------------------------------------------------
  // always_ff (negedge mbclk): High-Phase Lane Capture Register
  //
  // Samples the mainband receive data on the falling edge of mbclk.
  // During the high phase of each mbclk cycle the DDR pins carry the
  // even UI (bit 2c of every lane byte).  The negedge captures this
  // value into even_cap_q so it is available to the posedge assembler
  // below alongside the odd UI.
  //
  // This is a single-edge flop (negedge mbclk) — not a dual-edge
  // construct — consistent with the synthesis discipline described in
  // the file header.
  //
  // Spec ref: UCIe 1.0, Section 5.2 - Overview (forwarded clock DDR);
  //           Section 4.1.1 - Byte to Lane Mapping.
  // -------------------------------------------------------------------------
  logic [NLANES-1:0] even_cap_q;

  always_ff @(negedge mbclk or negedge lreset_n) begin
    if (!lreset_n) even_cap_q <= {NLANES{1'b0}};
    else           even_cap_q <= mb_rx_data;
  end

  // -------------------------------------------------------------------------
  // always_ff (posedge mbclk): Word Assembler and Cycle Counter
  //
  // On each posedge mbclk, scatters one UI pair (even from even_cap_q,
  // odd from mb_rx_data) into the correct bit positions of the 128-bit
  // assembly register asm_q.  The scatter follows the spec 4.1.1
  // byte-to-lane mapping:
  //   asm_q[8*L + 2*c]   <= even_cap_q[L]   (even UI)
  //   asm_q[8*L + 2*c+1] <= mb_rx_data[L]   (odd UI)
  //
  // On the last cycle (cyc_q == LAST_CYC = 3), the fully assembled
  // word is copied into word_hold_q.  The word-valid strobe asm_val_q is
  // produced by the framing monitor below, which decides whether the window
  // carried the legal framing pattern.  word_hold_q is a complete,
  // non-tearing snapshot: it
  // explicitly builds each byte from the current pair (bits 7:6) plus
  // the six bits already accumulated in asm_q, so the lclk domain
  // never reads a partially assembled buffer.
  //
  // Spec ref: UCIe 1.0, Section 4.1.1 - Byte to Lane Mapping;
  //           Section 4.1.2 - Valid Framing.
  // -------------------------------------------------------------------------
  logic [NBYTES*8-1:0] asm_q;
  logic [NBYTES*8-1:0] word_hold_q;
  logic [CYC_W-1:0]    cyc_q;
  logic                asm_val_q;   // written by the framing monitor below

  // One single-edge process owns asm_q, word_hold_q and cyc_q, so no two
  // blocks write slices of the same vector. asm_val_q keeps a single writer
  // as well: the framing monitor below. It is declared here because the lclk
  // output register samples it together with word_hold_q.
  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) begin
      asm_q       <= {NBYTES*8{1'b0}};
      word_hold_q <= {NBYTES*8{1'b0}};
      cyc_q       <= {CYC_W{1'b0}};   // phase 0: matches the TX phase
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
      cyc_q <= (cyc_q == LAST_CYC) ? {CYC_W{1'b0}} : cyc_q + 1'b1;
    end
  end

  // -------------------------------------------------------------------------
  // always_ff (posedge mbclk): Word-Boundary Framing Monitor and Word Strobe
  //
  // Valid framing (spec 4.1.2, PLAN.md 6.2) asserts the qualifier for the
  // first four UI of an eight-UI transfer. One mbclk cycle carries two UI
  // (high phase = UI 2c, low phase = UI 2c+1), so the legal per-cycle pattern
  // of a transfer window is
  //
  //   cyc_q       : 0    1    2    3
  //   UI          : 0,1  2,3  4,5  6,7
  //   mb_rx_valid : 1    1    0    0     (word in flight)
  //   mb_rx_valid : 0    0    0    0     (idle)
  //
  // A posedge reads the level that was stable during the cycle that ends at
  // that edge, so the capture at the cycle 0 edge is the window reference.
  // frame_ref_q holds that reference; on the cycle 1, 2 and 3 edges the level
  // must be frame_ref_q, 0 and 0, which frame_exp_w states as one equation.
  // Any mismatch is a framing violation:
  //
  //   - an early transition: the qualifier falls inside the valid window, or
  //     rises in the middle of an idle window, so the receive boundary is not
  //     the transfer boundary;
  //   - a late transition: the qualifier is still high after the fourth UI;
  //   - a malformed pattern: the level changes and returns inside one window,
  //     which is caught because every cycle is compared, not just the last.
  //
  // frame_ok_q carries the verdict of the window so far, so a rejected window
  // cannot produce a word strobe. framing_fault is sticky: the first violation
  // sets it and it holds until lreset_n, because after a bad boundary the
  // assembled words can no longer be trusted. The comparison uses the raw pin
  // level rather than a snapshot, so it does not miss a level that changes and
  // returns inside the window.
  //
  // This process keeps a single writer for every register it drives:
  // frame_ref_q, frame_ok_q, asm_val_q and framing_fault. asm_val_q is the
  // word-valid strobe - a window carries a word only when its reference was
  // high, cycles 1 and 2 matched, and cycle 3 is the fourth low UI - so an
  // idle or rejected window never strobes. framing_fault is private to the
  // logical PHY, which synchronises it into lclk and forwards it to the LTSM
  // fatal policy.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           PLAN.md Sections 6.2, 15.6 and 15.9 Phase E.
  // -------------------------------------------------------------------------
  logic frame_ref_q;    // cycle-0 qualifier level of the window in progress
  logic frame_ok_q;     // window matches the legal pattern so far

  // Level that the cycle ending at this mbclk edge must carry. frame_ref_q is
  // the cycle-0 level, so a window with a word requires 1, 1, 0, 0 and an
  // idle window requires 0, 0, 0, 0.
  logic frame_exp_w;
  assign frame_exp_w = frame_ref_q && (cyc_q <= LAST_VALID_CYC);

  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) begin
      frame_ref_q   <= 1'b0;
      frame_ok_q    <= 1'b0;
      asm_val_q     <= 1'b0;
      framing_fault <= 1'b0;
    end else if (cyc_q == {CYC_W{1'b0}}) begin
      frame_ref_q <= mb_rx_valid;         // cycle 0 sets the window reference
      frame_ok_q  <= 1'b1;                // legal pattern so far
    end else begin
      if (mb_rx_valid != frame_exp_w) begin
        frame_ok_q    <= 1'b0;            // reject the word of this window
        framing_fault <= 1'b1;            // sticky until lreset_n
      end
      if (cyc_q == LAST_CYC) begin
        // Window complete: cycle 0 was high, cycles 1 and 2 matched, and
        // cycle 3 must be low for the word to be valid.
        asm_val_q <= frame_ref_q && frame_ok_q && !mb_rx_valid;
      end
    end
  end

  // -------------------------------------------------------------------------
  // always_ff (posedge lclk): RX Output Registers — lclk Domain Transfer
  //
  // Captures word_hold_q and asm_val_q from the mbclk domain into the
  // lclk domain on each posedge lclk.  Because word_hold_q is a
  // complete non-tearing snapshot (written only on the last mbclk cycle
  // of each word), and lclk is phase-locked at fCK/4, this register
  // always samples a fully assembled 128-bit word.
  //
  // rx_word_vld acts as a one-cycle strobe indicating that rx_word
  // contains a valid received beat.  It follows asm_val_q, which the framing
  // monitor sets at the end of a window that carried the legal 1100 pattern,
  // so an idle window or a window rejected for bad framing produces no beat.
  // Downstream RDI logic uses this as the rdi_pl_valid qualifier.
  //
  // Spec ref: UCIe 1.0, Section 4.1.2 - Valid Framing;
  //           Section 8.1.2 - Interface clocking requirements.
  // -------------------------------------------------------------------------
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

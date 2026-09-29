// ============================================================================
// File        : ucie_pkg.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Global constants, types, and enumerations package.
//
// This package is the single source of truth for every compile-time constant
// and shared type used across the UCIe Simplified Endpoint RTL.  It covers:
//
//   1. Clock frequencies       – Sideband (800 MHz), main-band fCK (2 GHz),
//                                and RDI / adapter lclk (500 MHz for 4 GT/s).
//   2. Data-path geometry      – Number of bytes (NBYTES = 16 for x16
//                                Standard Package), data width (128 b),
//                                and sideband configuration width (8 b).
//   3. Timer intervals         – Spec-compliant residency timeout (8 ms
//                                per sub-state), RESET minimum (4 ms),
//                                sideband message timeout (8 ms), stall
//                                interval (4 ms), and SBINIT active/idle
//                                windows (1 ms each).
//   4. Sideband framing        – Header and payload phase width (64 b), optional
//                                64-bit payload, and inter-packet gap (32 UI).
//   5. Training pattern sizes  – SBINIT waveform, detection, and tail limits;
//                                VALTRAIN iteration count and threshold; and
//                                the LFSR pattern length in UI.
//   6. Pattern selectors       – 3-bit identifiers for Per-Lane-ID,
//                                VALTRAIN, Clock Repair, and LFSR patterns.
//   7. Lane geometry           – Maximum lane counts for x16 and x8
//                                configurations.
//   8. LFSR parameters         – Width (23 b), tap mask, and per-lane seed
//                                look-up function.  The tap-mask derivation
//                                from the spec 4.4.1 polynomial is detailed
//                                in the LFSR section below.
//   9. RDI / FDI state codes   – Request and status encodings (Tables 114,
//                                115 of the UCIe 1.0 specification).
//  10. Speed / width / protocol– Speed mode (4 GT/s only), link config
//                                (x8 / x16), protocol (Streaming), flit
//                                format (Raw Mode Format 1), and stream ID.
//  11. Sideband opcodes & IDs  – Table 47 opcodes, Table 48/49 IDs, packet
//                                types & struct, Figure 100-103 helpers.
//  12. LTSM state encodings    – 8-bit state values for every Link Training
//                                State Machine state (Error Log 0 "State N").
//  13. Sideband message codes  – {code, subcode} pairs for SBINIT, MBINIT,
//                                MBTRAIN, PHYRETRAIN, TRAINERROR, link
//                                management, and adapter-capability exchange
//                                (Tables 53, 54, 56).
//  14. Width-degrade lane map  – Apply-degrade request MsgInfo bit
//                                definitions.
//  15. Sideband credit limits  – Maximum outstanding remote credits
//                                (spec 6.1.3).
//  16. MBINIT.PARAM constants  – Immutable request and response 64-bit
//                                payload values, field masks, accepted
//                                Vswing range, and named packet roles from
//                                Table 56.
//
// Targeting : Standard Package x16, Streaming / Raw Mode (Format 1),
//             4 GT/s only.
// Tool reqs : Compatible with Icarus Verilog ≥ 12, Verilator, and all
//             major commercial simulators.
//
// LFSR Tap-Mask Derivation (spec 4.4.1)
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The UCIe 1.0 specification (section 4.4.1) defines the scrambler
// polynomial as:
//
//     G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1
//
// The hardware realisation is a 23-bit Fibonacci LFSR that shifts right
// with feedback injected into bit [22] (the MSB) and the output taken
// from bit [0] (the LSB).
//
// Under this convention, register bit k at time step t corresponds to
// LFSR output o(t+k).  The feedback equation is:
//
//     o(t+23)  =  o(t+21) XOR o(t+16) XOR o(t+8) XOR o(t+5)
//                 XOR o(t+2) XOR o(t+0)
//
// Which is equivalent to:
//
//     fb  =  lfsr[21] XOR lfsr[16] XOR lfsr[8] XOR lfsr[5]
//            XOR lfsr[2] XOR lfsr[0]
//
// The x^23 term in the polynomial corresponds to the shift itself
// (i.e., the one-cycle delay) and has NO corresponding bit in the
// 23-bit tap mask.  Therefore the tap mask is the bitwise OR of bit
// positions {21, 16, 8, 5, 2, 0}:
//
//   Bit 21 → 0x20_0000     Bit 16 → 0x01_0000     Bit 8 → 0x00_0100
//   Bit  5 → 0x00_0020     Bit  2 → 0x00_0004     Bit 0 → 0x00_0001
//
//   Sum:   0x21_0125   →   23'h210125
//
// The tap mask is applied in the RTL as:  fb = ^(lfsr_q & LFSR_TAPS)
// which computes XOR-reduction over exactly the tapped bit positions.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   Rev   Date        Author      Description
//   ----- ----------  ----------  ------------------------------------------
//   0.0.1 2026-09-22  -           First commit to git.
//   0.0.2 2026-09-22  -           Re-anchor lclk to 500 MHz, recalibrate timers, and update spec refs.
//   0.0.3 2026-09-24  -           Add the Section 4.5.3.2 SBINIT waveform,
//                                timing, message-subcode, and PHY-ID constants.
//   0.0.4 2026-09-24  -           Phase A: add immutable MBINIT.PARAM
//                                request and response 64-bit payloads,
//                                field masks, accepted Vswing range, and
//                                named role constants.
//   0.0.5 2026-09-24  -           Correct PARAM fields and payloads to
//                                Table 56. Remove unrelated capability
//                                fields and define request/response roles.
//
//   0.0.6 2026-09-28  -           Add Table 47 opcodes, Table 48 FDI IDs,
//                                 Table 49 RDI IDs, UCIe Link IDs, packet-kind
//                                 and completion-status types, sb_packet_t
//                                 packed struct, Figure 100-103 encode/decode
//                                 helpers, CP/DP rules, and structural decode
//                                 error checking.
// ============================================================================
`ifndef UciePkg_SV
`define UciePkg_SV

`timescale 1ns/1ps
package ucie_pkg;

  // ========================================================================
  // Clock Frequencies
  // ========================================================================
  // Spec mandates an 800 MHz sideband clock and, for 4 GT/s operation,
  // a 2 GHz main-band clock (fCK). With a 16-byte RDI bus, lclk is set
  // to 500 MHz for an exact bandwidth match (16 B * 500 MHz = 64 Gbps).
  // (UCIe 1.0 spec, Table 4, section 3.2, section 8.1.2.)
  localparam int unsigned CLK_SB_HZ    = 32'd800_000_000;
  localparam int unsigned LCLK_HZ      = 32'd500_000_000;

  // ========================================================================
  // Data Bus Widths
  // ========================================================================
  // NBYTES: number of bytes per flit per direction; 16 bytes for the x16
  //         Standard Package (UCIe 1.0, section 3.1, Table 3).
  // DATA_W: total data width in bits = NBYTES × 8 = 128 b.
  // NC:     sideband configuration interface width (8 bits) for FDI lp_cfg/pl_cfg
  //         (distinct from scalar physical sideband pins).
  localparam int unsigned NBYTES    = 16;
  localparam int unsigned DATA_W    = NBYTES * 8;
  localparam int unsigned NC        = 8;   // sideband cfg interface width

  // ========================================================================
  // Timer Intervals (nanoseconds)
  // ========================================================================
  // All timer values are true to the UCIe 1.0 specification.
  // Fast-testing shortcuts and artificial simulation timers are prohibited;
  // all timers run true to spec.
  //
  // T_RESET_MIN_NS  : 4 ms – minimum time in RESET before exiting
  //                   (spec 4.5.3.1, "RESET state").
  // T_RESIDENCY_NS  : 8 ms – sub-state residency timeout window
  //                   (spec 4.5, general training state timeout).
  // T_SB_MSG_NS     : 8 ms – sideband message timeout; requests expecting
  //                   a response time out after 8 ms (spec 6.1).
  // T_STALL_NS      : 4 ms – stall interval; when stalling to prevent
  //                   timeout, stall response cadence is 4 ms (spec 6.1).
  localparam int unsigned T_RESET_MIN_NS = 32'd4_000_000;   // 4 ms
  localparam int unsigned T_RESIDENCY_NS = 32'd8_000_000;   // 8 ms per sub-state
  localparam int unsigned T_SB_MSG_NS    = 32'd8_000_000;   // 8 ms message timeout
  localparam int unsigned T_STALL_NS     = 32'd4_000_000;   // stall every 4 ms

  // ========================================================================
  // Timer Intervals (lclk cycle counts)
  // ========================================================================
  // Calibrated to LCLK_HZ using 64-bit arithmetic to prevent truncation:
  //   cycles = T_ns * LCLK_HZ / 1_000_000_000
  // At lclk = 500 MHz (period 2 ns), 4 ms = 2,000,000 cycles and
  // 8 ms = 4,000,000 cycles.
  localparam int unsigned C_RESET_MIN = int'(longint'(T_RESET_MIN_NS) * LCLK_HZ / 32'd1_000_000_000);
  localparam int unsigned C_RESIDENCY = int'(longint'(T_RESIDENCY_NS) * LCLK_HZ / 32'd1_000_000_000);
  localparam int unsigned C_SB_MSG    = int'(longint'(T_SB_MSG_NS)    * LCLK_HZ / 32'd1_000_000_000);
  localparam int unsigned C_STALL     = int'(longint'(T_STALL_NS)     * LCLK_HZ / 32'd1_000_000_000);

  // SBINIT alternates a 1 ms pattern-active window with a 1 ms idle window
  // until the receiver detects two consecutive remote iterations. These
  // counts are in lclk cycles because the LTSM owns the retry policy.
  localparam int unsigned SBINIT_ACTIVE_LCLK_CYCLES = LCLK_HZ / 32'd1_000;
  localparam int unsigned SBINIT_IDLE_LCLK_CYCLES   = LCLK_HZ / 32'd1_000;

  // ========================================================================
  // Sideband Framing
  // ========================================================================
  // SB_PKT_BITS : 64 – sideband header/payload phase width in bits (spec 6.1.1).
  // SB_GAP_UI   : 32 – minimum inter-packet gap in UI (spec 6.1.2).
  localparam int unsigned SB_PKT_BITS  = 64;
  localparam int unsigned SB_GAP_UI    = 32;

  // Standard Package SBINIT raw waveform (spec 4.5.3.2). One iteration is
  // 64 alternating UIs followed by 32 low UIs. Detection needs two
  // consecutive matching iterations. The transmitter then sends four more
  // complete iterations before it changes to packet mode.
  localparam int unsigned SBINIT_PATTERN_UI        = 64;
  localparam int unsigned SBINIT_LOW_UI            = 32;
  localparam int unsigned SBINIT_DETECT_ITERS      = 2;
  localparam int unsigned SBINIT_POST_DETECT_ITERS = 4;
  localparam logic [7:0] SBINIT_RESULT_PRIMARY     = 8'h01;

  // ========================================================================
  // Training Pattern Sizes
  // ========================================================================
  // VALTRAIN_ITER   : 128 – number of VALTRAIN iterations per sub-state
  //                   (spec 4.3.5, MBTRAIN.VALVREF).
  // VALTRAIN_DETECT : 16 – detection threshold: receiver declares valid
  //                   after receiving 16 consecutive good patterns.
  // LFSR_PATTERN_UI : 4096 – length of the LFSR pattern in UI per
  //                   training exchange (spec 4.3.5).
  localparam int unsigned VALTRAIN_ITER   = 128;
  localparam int unsigned VALTRAIN_DETECT = 16;
  localparam int unsigned LFSR_PATTERN_UI = 4096;

  // ========================================================================
  // Pattern Selectors (pat_t)
  // ========================================================================
  // 3-bit selector identifying which training pattern the TX data-path
  // should emit.  Used by the pattern generator mux.
  //   PAT_PERLANEID : Per-lane identification pattern (spec 4.3.2).
  //   PAT_VALTRAIN  : VALTRAIN pattern for valid / Vref training (4.3.5).
  //   PAT_CLKREPAIR : Clock-repair pattern (4.3.3).
  //   PAT_LFSR      : LFSR-scrambled data (4.3.5 / 4.4.1).
  typedef logic [2:0] pat_t;
  localparam pat_t PAT_PERLANEID = 3'd0;
  localparam pat_t PAT_VALTRAIN  = 3'd1;
  localparam pat_t PAT_CLKREPAIR = 3'd2;
  localparam pat_t PAT_LFSR      = 3'd3;

  // ========================================================================
  // Lane Geometry
  // ========================================================================
  // NLANES_MAX : 16 – maximum number of data lanes in the full-width
  //              x16 configuration.
  // NLANES_X8  : 8  – lane count for the half-width x8 configuration.
  localparam int unsigned NLANES_MAX = 16;
  localparam int unsigned NLANES_X8  = 8;

  // ========================================================================
  // LFSR Parameters (spec 4.4.1)
  // ========================================================================
  // See the file header for the full derivation of LFSR_TAPS from the spec
  // polynomial G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1.
  //
  // LFSR_W    : 23  – register width (23-bit Fibonacci LFSR).
  // LFSR_TAPS : 23'h210125 – XOR-feedback tap mask selecting register
  //             bits {21, 16, 8, 5, 2, 0}.  The x^23 term is implicit
  //             in the one-bit shift and is NOT represented in the mask.
  //
  // The scrambler module (scrambler.sv) implements:
  //     fb      = ^(lfsr_q & LFSR_TAPS)     // XOR-reduction over taps
  //     lfsr_d  = {fb, lfsr_q[22:1]}         // right-shift, fb → bit 22
  //     output  = lfsr_q[0]                  // output from LSB
  localparam int unsigned LFSR_W   = 23;
  localparam logic [LFSR_W-1:0] LFSR_TAPS = 23'h210125;

  // ========================================================================
  // Per-Lane LFSR Seed Function
  // ========================================================================
  // Each lane's LFSR is seeded with a lane-specific value on reset and on
  // entry to LINKINIT (spec 4.4.1).  The seed values repeat modulo 8.
  //
  // Icarus Verilog (≤ v12) does not support array assignment patterns in
  // localparam declarations, so the look-up is implemented as a function
  // instead of a constant array.
  function automatic logic [LFSR_W-1:0] lfsr_seed(input int unsigned lane);
    case (lane % 8)
      8'd0: lfsr_seed = 23'h1DBFBC;
      8'd1: lfsr_seed = 23'h0607BB;
      8'd2: lfsr_seed = 23'h1EC760;
      8'd3: lfsr_seed = 23'h18C0DB;
      8'd4: lfsr_seed = 23'h010F12;
      8'd5: lfsr_seed = 23'h19CFC9;
      8'd6: lfsr_seed = 23'h0277CE;
      8'd7: lfsr_seed = 23'h1BB807;
      default: lfsr_seed = 23'h1DBFBC;
    endcase
  endfunction

  // ========================================================================
  // RDI State Encodings (spec Table 114)
  // ========================================================================
  // rdi_req_t – lp_state_req : 4-bit request codes from the logical PHY
  //             layer (LP) towards the physical layer (PL).
  // Each value matches the encoding specified in UCIe 1.0, Table 114.
  typedef logic [3:0] rdi_req_t;
  localparam rdi_req_t RDI_REQ_NOP      = 4'h0;  // No operation
  localparam rdi_req_t RDI_REQ_ACTIVE   = 4'h1;  // Request Active state
  localparam rdi_req_t RDI_REQ_L1       = 4'h4;  // Request L1 power state
  localparam rdi_req_t RDI_REQ_L2       = 4'h8;  // Request L2 power state
  localparam rdi_req_t RDI_REQ_LINKRESET= 4'h9;  // Request link reset
  localparam rdi_req_t RDI_REQ_RETRAIN  = 4'hB;  // Request retraining
  localparam rdi_req_t RDI_REQ_DISABLED = 4'hC;  // Request disabled state

  // rdi_sts_t – pl_state_sts : 4-bit status codes from the physical layer
  //             (PL) towards the logical PHY layer (LP).
  // (UCIe 1.0, Table 114, pl_state_sts column.)
  typedef logic [3:0] rdi_sts_t;
  localparam rdi_sts_t RDI_STS_RESET    = 4'h0;  // PHY in RESET
  localparam rdi_sts_t RDI_STS_ACTIVE   = 4'h1;  // PHY Active
  localparam rdi_sts_t RDI_STS_PMNAK    = 4'h3;  // PM NAK (power mgmt rejected)
  localparam rdi_sts_t RDI_STS_L1       = 4'h4;  // PHY in L1
  localparam rdi_sts_t RDI_STS_L2       = 4'h8;  // PHY in L2
  localparam rdi_sts_t RDI_STS_LINKRESET= 4'h9;  // PHY performing link reset
  localparam rdi_sts_t RDI_STS_LINKERROR= 4'hA;  // PHY detected link error
  localparam rdi_sts_t RDI_STS_RETRAIN  = 4'hB;  // PHY retraining
  localparam rdi_sts_t RDI_STS_DISABLED = 4'hC;  // PHY disabled

  // ========================================================================
  // FDI State Encodings (spec Table 115)
  // ========================================================================
  // The FDI (Flit-aware D2D Interface) uses identical encodings to RDI
  // (Table 115 states: "identical encodings as defined in Table 114").
  // These aliases exist for readability in adapter/protocol-layer code.
  //
  // FDI request codes (lp_state_req towards the D2D adapter).
  localparam rdi_req_t FDI_REQ_NOP      = RDI_REQ_NOP;
  localparam rdi_req_t FDI_REQ_ACTIVE   = RDI_REQ_ACTIVE;
  localparam rdi_req_t FDI_REQ_L1       = RDI_REQ_L1;
  localparam rdi_req_t FDI_REQ_L2       = RDI_REQ_L2;
  localparam rdi_req_t FDI_REQ_LINKRESET= RDI_REQ_LINKRESET;
  localparam rdi_req_t FDI_REQ_RETRAIN  = RDI_REQ_RETRAIN;
  localparam rdi_req_t FDI_REQ_DISABLED = RDI_REQ_DISABLED;

  // FDI status codes (pl_state_sts from the D2D adapter).
  localparam rdi_sts_t FDI_STS_RESET    = RDI_STS_RESET;
  localparam rdi_sts_t FDI_STS_ACTIVE   = RDI_STS_ACTIVE;
  localparam rdi_sts_t FDI_STS_PMNAK    = RDI_STS_PMNAK;
  localparam rdi_sts_t FDI_STS_L1       = RDI_STS_L1;
  localparam rdi_sts_t FDI_STS_L2       = RDI_STS_L2;
  localparam rdi_sts_t FDI_STS_LINKRESET= RDI_STS_LINKRESET;
  localparam rdi_sts_t FDI_STS_LINKERROR= RDI_STS_LINKERROR;
  localparam rdi_sts_t FDI_STS_RETRAIN  = RDI_STS_RETRAIN;
  localparam rdi_sts_t FDI_STS_DISABLED = RDI_STS_DISABLED;

  // ========================================================================
  // Speed / Width / Protocol Negotiation
  // ========================================================================

  // pl_speedmode (spec Table 114): 3-bit speed encoding.
  // Only 4 GT/s (000) is supported in this simplified endpoint.
  typedef logic [2:0] speed_t;
  localparam speed_t SPEED_4GT = 3'b000;

  // pl_lnk_cfg (spec Table 114): 3-bit link-width encoding.
  //   001 = x8  (half-width Standard Package)
  //   010 = x16 (full-width Standard Package)
  typedef logic [2:0] lnkcfg_t;
  localparam lnkcfg_t LNKCFG_X8  = 3'b001;
  localparam lnkcfg_t LNKCFG_X16 = 3'b010;

  // pl_protocol (spec Table 114): 3-bit protocol selector.
  //   111 = Streaming Protocol.
  typedef logic [2:0] proto_t;
  localparam proto_t PROTO_STREAMING = 3'b111;

  // pl_protocol_flitfmt (spec Table 114): 4-bit flit format.
  //   0001 = Format 1 Raw Mode.
  typedef logic [3:0] flitfmt_t;
  localparam flitfmt_t FMT_RAW = 4'b0001;

  // lp_stream / pl_stream: stream identifier for Stack 0 Streaming.
  //   04h as defined in the streaming protocol section.
  localparam logic [7:0] STREAM_ID_S0_STREAMING = 8'h04;

  // ========================================================================
  // Sideband Opcodes (UCIe 1.0, Section 6.1.1, Table 47)
  // ========================================================================
  // sb_opcode_t – 5-bit opcode field in the sideband packet header.
  // Every packet carries a 5-bit opcode indicating the transaction type
  // and whether it carries 0, 32, or 64 bits of data payload.
  //
  // Spec ref: UCIe 1.0, Section 6.1.1, Table 47 - Opcode encodings mapped to Packet Types.
  typedef logic [4:0] sb_opcode_t;
  localparam sb_opcode_t SB_OP_MEM_READ32   = 5'b00000; // 32b Memory Read (0B payload)
  localparam sb_opcode_t SB_OP_MEM_WRITE32  = 5'b00001; // 32b Memory Write (4B payload)
  localparam sb_opcode_t SB_OP_CFG_READ32   = 5'b00100; // 32b Configuration Read (0B payload)
  localparam sb_opcode_t SB_OP_CFG_WRITE32  = 5'b00101; // 32b Configuration Write (4B payload)
  localparam sb_opcode_t SB_OP_MEM_READ64   = 5'b01000; // 64b Memory Read (0B payload)
  localparam sb_opcode_t SB_OP_MEM_WRITE64  = 5'b01001; // 64b Memory Write (8B payload)
  localparam sb_opcode_t SB_OP_CFG_READ64   = 5'b01100; // 64b Configuration Read (0B payload)
  localparam sb_opcode_t SB_OP_CFG_WRITE64  = 5'b01101; // 64b Configuration Write (8B payload)
  localparam sb_opcode_t SB_OP_CPL_NODATA   = 5'b10000; // Completion without Data (0B payload)
  localparam sb_opcode_t SB_OP_CPL_DATA32   = 5'b10001; // Completion with 32b Data (4B payload)
  localparam sb_opcode_t SB_OP_CPL_DATA64   = 5'b11001; // Completion with 64b Data (8B payload)
  localparam sb_opcode_t SB_OP_MSG_NODATA   = 5'b10010; // Message without Data (0B payload)
  localparam sb_opcode_t SB_OP_MSG_DATA64   = 5'b11011; // Message with 64b Data (8B payload)

  // ========================================================================
  // Sideband Packet Kind (UCIe 1.0, Section 6.1.1, Section 6.1.2)
  // ========================================================================
  // Distinguishes the three architectural header layouts:
  //   SB_PKT_REG_REQ    : Register Access Request (Figure 100: Addr, BE, Tag)
  //   SB_PKT_COMPLETION : Register Access Completion (Figure 101: Status, BE, Tag)
  //   SB_PKT_MESSAGE    : Sideband Message (Figures 102/103: MsgInfo, MsgCode, MsgSubcode)
  typedef logic [2:0] sb_packet_kind_t;
  localparam sb_packet_kind_t SB_PKT_UNKNOWN    = 3'b000; // Reserved / unknown format
  localparam sb_packet_kind_t SB_PKT_REG_REQ    = 3'b001; // Register Access Request (Fig 100)
  localparam sb_packet_kind_t SB_PKT_COMPLETION = 3'b010; // Register Access Completion (Fig 101)
  localparam sb_packet_kind_t SB_PKT_MESSAGE    = 3'b011; // Message with/without data (Fig 102/103)
  // Named aliases
  localparam sb_packet_kind_t SB_PKT_REQ        = SB_PKT_REG_REQ;
  localparam sb_packet_kind_t SB_PKT_CPL        = SB_PKT_COMPLETION;
  localparam sb_packet_kind_t SB_PKT_MSG        = SB_PKT_MESSAGE;
  localparam sb_packet_kind_t SB_PKT_INVALID    = SB_PKT_UNKNOWN;

  // ========================================================================
  // Completion Status Types (UCIe 1.0, Section 6.1.2.1, Table 52)
  // ========================================================================
  // 3-bit status codes carried in Phase 1 [2:0] (header[34:32]) of completions.
  // Other encodings are reserved.
  typedef logic [2:0] sb_completion_status_t;
  typedef sb_completion_status_t sb_status_t;
  localparam sb_status_t SB_STS_SC    = 3'b000; // Successful Completion (SC)
  localparam sb_status_t SB_STS_UR    = 3'b001; // Unsupported Request (UR)
  localparam sb_status_t SB_STS_CA    = 3'b100; // Completer Abort (CA)
  localparam sb_status_t SB_STS_STALL = 3'b111; // Stall response (4 ms cadence)

  // ========================================================================
  // Context-Specific Sideband Identifiers (UCIe 1.0, Section 6.1.1)
  // ========================================================================
  // Preserved legacy endpoint identifiers (retained for backward compatibility).
  typedef logic [2:0] sb_srcid_t;
  localparam sb_srcid_t SRCID_STACK0      = 3'b000;
  localparam sb_srcid_t SRCID_ADAPT       = 3'b001;
  localparam sb_srcid_t SRCID_PHY         = 3'b010;
  localparam sb_srcid_t DSTID_REMOTE_PHY  = 3'b110;

  // FDI Sideband: srcid and dstid encodings (UCIe 1.0, Table 48)
  // Note: srcid and dstid are reserved for completions transferred over FDI.
  localparam logic [2:0] FDI_SRCID_STACK0       = 3'b000; // Stack 0 Protocol Layer
  localparam logic [2:0] FDI_SRCID_STACK1       = 3'b100; // Stack 1 Protocol Layer
  localparam logic [2:0] FDI_DSTID_ADAPTER      = 3'b001; // D2D Adapter
  localparam logic [2:0] FDI_DSTID_PHY          = 3'b010; // Physical Layer

  // RDI Sideband: srcid and dstid encodings (UCIe 1.0, Table 49)
  localparam logic [2:0] RDI_SRCID_STACK0       = 3'b000; // Stack 0 Protocol Layer
  localparam logic [2:0] RDI_SRCID_ADAPTER      = 3'b001; // D2D Adapter
  localparam logic [2:0] RDI_SRCID_STACK1       = 3'b100; // Stack 1 Protocol Layer
  localparam logic [2:0] RDI_DSTID_LOCAL_PHY    = 3'b010; // Local die terminated: Physical Layer
  localparam logic [2:0] RDI_DSTID_REMOTE_ADAPT = 3'b101; // Remote die terminated: D2D Adapter
  localparam logic [2:0] RDI_DSTID_REMOTE_PHY   = 3'b110; // Remote die terminated: Physical Layer

  // UCIe Link Sideband: srcid and dstid encodings (UCIe 1.0, Table 49)
  localparam logic [2:0] LINK_SRCID_ADAPTER     = 3'b001; // D2D Adapter
  localparam logic [2:0] LINK_SRCID_PHY         = 3'b010; // Physical Layer
  localparam logic [2:0] LINK_DSTID_REMOTE_ADAPT= 3'b101; // Remote die terminated: D2D Adapter
  localparam logic [2:0] LINK_DSTID_REMOTE_PHY  = 3'b110; // Remote die terminated: Physical Layer

  // ========================================================================
  // Sideband Packet Structure (sb_packet_t)
  // ========================================================================
  // Project packed-struct style sideband packet container.
  // Field order and bit widths are exact:
  //   opcode[4:0], src_id[2:0], dst_id[2:0], msg_info[15:0], msg_code[7:0],
  //   msg_subcode[7:0], cr, addr[26:0], be[7:0], tag[4:0], ep, status[2:0],
  //   data[63:0].
  // Total width: 152 bits.
  typedef struct packed {
    logic [4:0]  opcode;
    logic [2:0]  src_id;
    logic [2:0]  dst_id;
    logic [15:0] msg_info;
    logic [7:0]  msg_code;
    logic [7:0]  msg_subcode;
    logic        cr;
    logic [26:0] addr;
    logic [7:0]  be;
    logic [4:0]  tag;
    logic        ep;
    logic [2:0]  status;
    logic [63:0] data;
  } sb_packet_t;

  // ========================================================================
  // Structural Decode Error Result (sb_decode_err_t)
  // ========================================================================
  // Synthesis-friendly packed-struct reporting decode anomaly flags.
  typedef struct packed {
    logic any_err;          // 1 if any decode anomaly is detected
    logic rsvd_opcode;      // Opcode not defined in Table 47
    logic rsvd_field;       // Non-zero bits in reserved fields (Figures 100-103)
    logic illegal_payload;  // Illegal opcode/payload combination (DP set with 0B payload)
    logic cp_err;           // Control Parity mismatch across 64-bit header
  } sb_decode_err_t;

  // ========================================================================
  // Pure Helpers (UCIe 1.0, Sections 6.1.1, 6.1.2, 6.1.3; Figures 100-103)
  // ========================================================================

  // sb_packet_kind: maps Table 47 opcode to architectural format category.
  function automatic sb_packet_kind_t sb_packet_kind(input logic [4:0] opcode);
    case (opcode)
      SB_OP_MEM_READ32,
      SB_OP_MEM_WRITE32,
      SB_OP_CFG_READ32,
      SB_OP_CFG_WRITE32,
      SB_OP_MEM_READ64,
      SB_OP_MEM_WRITE64,
      SB_OP_CFG_READ64,
      SB_OP_CFG_WRITE64:  sb_packet_kind = SB_PKT_REG_REQ;
      SB_OP_CPL_NODATA,
      SB_OP_CPL_DATA32,
      SB_OP_CPL_DATA64:   sb_packet_kind = SB_PKT_COMPLETION;
      SB_OP_MSG_NODATA,
      SB_OP_MSG_DATA64:   sb_packet_kind = SB_PKT_MESSAGE;
      default:            sb_packet_kind = SB_PKT_UNKNOWN;
    endcase
  endfunction

  // sb_payload_bytes: returns payload byte count (0, 4, or 8) directly from opcode.
  // Read requests, Cpl-without-data, and Msg-without-data carry 0B payload.
  function automatic int unsigned sb_payload_bytes(input logic [4:0] opcode);
    case (opcode)
      SB_OP_MEM_WRITE32,
      SB_OP_CFG_WRITE32,
      SB_OP_CPL_DATA32:  sb_payload_bytes = 4;
      SB_OP_MEM_WRITE64,
      SB_OP_CFG_WRITE64,
      SB_OP_CPL_DATA64,
      SB_OP_MSG_DATA64:  sb_payload_bytes = 8;
      default:           sb_payload_bytes = 0;
    endcase
  endfunction

  // sb_opcode_supported: returns 1'b1 for valid Table 47 opcodes; 1'b0 for reserved.
  function automatic logic sb_opcode_supported(input logic [4:0] opcode);
    case (opcode)
      SB_OP_MEM_READ32,
      SB_OP_MEM_WRITE32,
      SB_OP_CFG_READ32,
      SB_OP_CFG_WRITE32,
      SB_OP_MEM_READ64,
      SB_OP_MEM_WRITE64,
      SB_OP_CFG_READ64,
      SB_OP_CFG_WRITE64,
      SB_OP_CPL_NODATA,
      SB_OP_CPL_DATA32,
      SB_OP_CPL_DATA64,
      SB_OP_MSG_NODATA,
      SB_OP_MSG_DATA64:  sb_opcode_supported = 1'b1;
      default:           sb_opcode_supported = 1'b0;
    endcase
  endfunction

  // sb_pad_data: pads 32-bit payload upper bits [63:32] to zero; clears 0B payload.
  function automatic logic [63:0] sb_pad_data(
    input logic [4:0]  opcode,
    input logic [63:0] raw_data
  );
    case (sb_payload_bytes(opcode))
      4:       sb_pad_data = {32'h0, raw_data[31:0]};
      8:       sb_pad_data = raw_data;
      default: sb_pad_data = 64'h0;
    endcase
  endfunction

  // sb_calc_dp: calculates Data Parity (even parity over payload; 0 if no payload).
  // Spec ref: Table 50 ("If there is no data payload, this bit is set to 0b").
  function automatic logic sb_calc_dp(
    input logic [4:0]  opcode,
    input logic [63:0] data
  );
    case (sb_payload_bytes(opcode))
      4:       sb_calc_dp = ^data[31:0];
      8:       sb_calc_dp = ^data[63:0];
      default: sb_calc_dp = 1'b0;
    endcase
  endfunction

  // sb_calc_cp: calculates Control Parity (even parity of header bits excluding DP).
  // Spec ref: Table 50, Table 52 ("even parity of all the header bits excluding DP").
  function automatic logic sb_calc_cp(input logic [63:0] header);
    sb_calc_cp = ^({header[63:32], 1'b0, 1'b0, header[29:0]});
  endfunction

  // sb_check_dp_err: validates received DP bit against received payload.
  function automatic logic sb_check_dp_err(
    input logic [4:0]  opcode,
    input logic        dp_bit,
    input logic [63:0] data
  );
    sb_check_dp_err = (dp_bit !== sb_calc_dp(opcode, data));
  endfunction

  // sb_encode_header: packs sb_packet_t into exact 64-bit header per Figures 100-103.
  // Handles 32-bit data padding and CP/DP calculation deterministically.
  function automatic logic [63:0] sb_encode_header(input sb_packet_t packet);
    logic [63:0] hdr;

    hdr = 64'h0;

    // Phase 0 common fields (Figures 100-103)
    hdr[4:0]  = packet.opcode;
    hdr[7:5]  = packet.src_id;
    hdr[10:8] = packet.dst_id;
    hdr[16]   = packet.ep;
    hdr[17]   = packet.cr;

    case (sb_packet_kind(packet.opcode))
      SB_PKT_REG_REQ: begin
        // Figure 100: Register Access Request
        hdr[15:11] = packet.tag;
        if (sb_payload_bytes(packet.opcode) == 4 ||
            packet.opcode == SB_OP_MEM_READ32 ||
            packet.opcode == SB_OP_CFG_READ32) begin
          hdr[28:21] = {4'b0000, packet.be[3:0]}; // BE[7:4] reserved for 32b
        end else begin
          hdr[28:21] = packet.be;
        end
        hdr[58:32] = packet.addr;
      end

      SB_PKT_COMPLETION: begin
        // Figure 101: Register Access Completion
        hdr[15:11] = packet.tag;
        if (packet.opcode == SB_OP_CPL_DATA32) begin
          hdr[28:21] = {4'b0000, packet.be[3:0]}; // BE[7:4] reserved for 32b
        end else begin
          hdr[28:21] = packet.be;
        end
        hdr[34:32] = packet.status;
      end

      SB_PKT_MESSAGE: begin
        // Figures 102/103: Message without/with data
        hdr[15:11] = 5'b00000; // Reserved
        hdr[28:21] = 8'h00;    // Reserved
        hdr[39:32] = packet.msg_subcode;
        hdr[47:40] = packet.msg_code;
        hdr[63:48] = packet.msg_info;
      end

      default: begin
        hdr[63:32] = 32'h0;
      end
    endcase

    // Data parity in bit 30
    hdr[30] = sb_calc_dp(packet.opcode, packet.data);

    // Control parity in bit 31
    hdr[31] = sb_calc_cp(hdr);

    return hdr;
  endfunction

  // sb_decode_header: unpacks 64-bit header into sb_packet_t per Figures 100-103.
  function automatic sb_packet_t sb_decode_header(input logic [63:0] header);
    sb_packet_t pkt;

    pkt = '0;
    pkt.opcode = header[4:0];
    pkt.src_id = header[7:5];
    pkt.dst_id = header[10:8];
    pkt.ep     = header[16];
    pkt.cr     = header[17];
    pkt.data   = 64'h0;

    case (sb_packet_kind(header[4:0]))
      SB_PKT_REG_REQ: begin
        // Figure 100
        pkt.tag         = header[15:11];
        pkt.be          = header[28:21];
        pkt.addr        = header[58:32];
        pkt.status      = 3'b000;
        pkt.msg_info    = 16'h0000;
        pkt.msg_code    = 8'h00;
        pkt.msg_subcode = 8'h00;
      end

      SB_PKT_COMPLETION: begin
        // Figure 101
        pkt.tag         = header[15:11];
        pkt.be          = header[28:21];
        pkt.addr        = 27'h0;
        pkt.status      = header[34:32];
        pkt.msg_info    = 16'h0000;
        pkt.msg_code    = 8'h00;
        pkt.msg_subcode = 8'h00;
      end

      SB_PKT_MESSAGE: begin
        // Figures 102/103
        pkt.tag         = 5'b00000;
        pkt.be          = 8'h00;
        pkt.addr        = 27'h0;
        pkt.status      = 3'b000;
        pkt.msg_subcode = header[39:32];
        pkt.msg_code    = header[47:40];
        pkt.msg_info    = header[63:48];
      end

      default: begin
        pkt.tag         = 5'b00000;
        pkt.be          = 8'h00;
        pkt.addr        = 27'h0;
        pkt.status      = 3'b000;
        pkt.msg_info    = 16'h0000;
        pkt.msg_code    = 8'h00;
        pkt.msg_subcode = 8'h00;
      end
    endcase

    return pkt;
  endfunction

  // sb_decode_header_task: output-argument helper for simulators requiring procedural output ports.
  task automatic sb_decode_header_task(
    input  logic [63:0] header,
    output sb_packet_t  packet
  );
    packet = sb_decode_header(header);
  endtask

  // sb_decode_error: evaluates reserved opcodes, reserved fields, illegal payload, and CP errors.
  function automatic sb_decode_err_t sb_decode_error(input logic [63:0] header);
    sb_decode_err_t err;
    logic [4:0] op;
    logic       rsvd_f;

    err = '0;
    op = header[4:0];
    rsvd_f = 1'b0;

    // Reserved opcode check (Table 47)
    if (!sb_opcode_supported(op)) begin
      err.rsvd_opcode = 1'b1;
    end

    // Reserved fields check (Figures 100-103)
    if (header[29] != 1'b0 || header[20:18] != 3'b000) begin
      rsvd_f = 1'b1;
    end

    case (sb_packet_kind(op))
      SB_PKT_REG_REQ: begin
        if (header[63:59] != 5'b00000) begin
          rsvd_f = 1'b1;
        end
        // Table 50 address/BE alignment rules
        if (op == SB_OP_MEM_READ64 || op == SB_OP_MEM_WRITE64 ||
            op == SB_OP_CFG_READ64 || op == SB_OP_CFG_WRITE64) begin
          if (header[34:32] != 3'b000) rsvd_f = 1'b1; // Addr[2:0] reserved
        end
        if (op == SB_OP_MEM_READ32 || op == SB_OP_MEM_WRITE32 ||
            op == SB_OP_CFG_READ32 || op == SB_OP_CFG_WRITE32) begin
          if (header[33:32] != 2'b00)   rsvd_f = 1'b1; // Addr[1:0] reserved
          if (header[28:25] != 4'b0000) rsvd_f = 1'b1; // BE[7:4] reserved
        end
      end

      SB_PKT_COMPLETION: begin
        if (header[63:35] != 29'h0) begin
          rsvd_f = 1'b1;
        end
        if (op == SB_OP_CPL_DATA32) begin
          if (header[28:25] != 4'b0000) rsvd_f = 1'b1; // BE[7:4] reserved
        end
        // Table 52 status encodings
        case (header[34:32])
          SB_STS_SC,
          SB_STS_UR,
          SB_STS_CA,
          SB_STS_STALL: /* valid status */ ;
          default:      rsvd_f = 1'b1;
        endcase
      end

      SB_PKT_MESSAGE: begin
        if (header[15:11] != 5'b00000 || header[28:21] != 8'h00) begin
          rsvd_f = 1'b1; // Tag and BE reserved in messages
        end
      end

      default: ;
    endcase

    err.rsvd_field = rsvd_f;

    // Illegal payload rule (Table 50: DP=0 when no data payload)
    if ((sb_payload_bytes(op) == 0) && (header[30] != 1'b0)) begin
      err.illegal_payload = 1'b1;
    end

    // Control Parity (CP) rule (Table 50, 52: even parity over header excl DP)
    if (^({header[63:31], 1'b0, header[29:0]}) !== 1'b0) begin
      err.cp_err = 1'b1;
    end

    err.any_err = err.rsvd_opcode | err.rsvd_field | err.illegal_payload | err.cp_err;
    return err;
  endfunction

  // sb_decode_error_task: output-argument helper for decode error check.
  task automatic sb_decode_error_task(
    input  logic [63:0]     header,
    output sb_decode_err_t  err
  );
    err = sb_decode_error(header);
  endtask

  // ========================================================================
  // LTSM State Encodings (Error Log 0, "State N")
  // ========================================================================
  // 8-bit state values for every Link Training State Machine state.
  // These are logged to the error register and used for debug/observability
  // across the PHY and adapter layers.
  typedef logic [7:0] ltsm_state_t;
  localparam ltsm_state_t LT_RESET          = 8'h00;  // Power-on / link reset
  localparam ltsm_state_t LT_SBINIT         = 8'h01;  // Sideband initialisation
  localparam ltsm_state_t LT_MBINIT_PARAM   = 8'h02;  // MBINIT.PARAMETER
  localparam ltsm_state_t LT_MBINIT_CAL     = 8'h03;  // MBINIT.CAL
  localparam ltsm_state_t LT_MBINIT_RPCLK   = 8'h04;  // MBINIT.REPAIRCLK
  localparam ltsm_state_t LT_MBINIT_RPVAL   = 8'h05;  // MBINIT.REPAIRVAL
  localparam ltsm_state_t LT_MBINIT_REVMB   = 8'h06;  // MBINIT.REVERSALMB
  localparam ltsm_state_t LT_MBINIT_RPMB    = 8'h07;  // MBINIT.REPAIRMB
  localparam ltsm_state_t LT_MB_VALVREF     = 8'h08;  // MBTRAIN.VALVREF
  localparam ltsm_state_t LT_MB_DATAVREF    = 8'h09;  // MBTRAIN.DATAVREF
  localparam ltsm_state_t LT_MB_SPEEDIDLE   = 8'h0A;  // MBTRAIN.SPEEDIDLE
  localparam ltsm_state_t LT_MB_TXSELFCAL   = 8'h0B;  // MBTRAIN.TXSELFCAL
  localparam ltsm_state_t LT_MB_RXCLKCAL    = 8'h0C;  // MBTRAIN.RXCLKCAL
  localparam ltsm_state_t LT_MB_VTCENTER    = 8'h0D;  // MBTRAIN.DATACENTER1(VT)
  localparam ltsm_state_t LT_MB_DTVREF1     = 8'h0E;  // MBTRAIN.DATAVREF1
  localparam ltsm_state_t LT_MB_RXDESKEW    = 8'h0F;  // MBTRAIN.RXDESKEW
  localparam ltsm_state_t LT_MB_DTCENTER2   = 8'h10;  // MBTRAIN.DATACENTER2
  localparam ltsm_state_t LT_MB_LINKSPEED   = 8'h11;  // MBTRAIN.LINKSPEED
  localparam ltsm_state_t LT_MB_REPAIR      = 8'h12;  // MBTRAIN.REPAIR
  localparam ltsm_state_t LT_PHYRETRAIN     = 8'h13;  // PHYRETRAIN
  localparam ltsm_state_t LT_LINKINIT       = 8'h14;  // LINKINIT
  localparam ltsm_state_t LT_ACTIVE         = 8'h15;  // ACTIVE (link up)
  localparam ltsm_state_t LT_TRAINERROR     = 8'h16;  // TRAINERROR
  localparam ltsm_state_t LT_L1L2           = 8'h17;  // L1/L2 power states
  localparam int unsigned LT_NUM_STATES     = 24;

  // ========================================================================
  // Sideband Message Codes (Tables 53, 54, 56)
  // ========================================================================
  // {code, subcode} pairs used throughout the LTSM handshake sequences.
  // Grouped by training phase.

  // --- Link Management ---------------------------------------------------
  // MC_NOP_CRD         : Credit-return NOP (no subcode).
  // MC_LM_RDI_REQ/RSP  : LinkMgmt.RDI request / response pair used to
  //                       coordinate RDI state transitions between the two
  //                       link partners.
  // MC_ADVCAP_ADAPTER   : AdvCap.Adapter – advertise adapter capabilities.
  // MC_FINCAP_ADAPTER   : FinCap.Adapter – finalise capability negotiation.
  // MC_ERRMSG           : Error message (training error notification).
  localparam logic [7:0] MC_NOP_CRD        = 8'h00;
  localparam logic [7:0] MC_LM_RDI_REQ     = 8'h01;
  localparam logic [7:0] MC_LM_RDI_RSP     = 8'h02;
  localparam logic [7:0] MC_ADVCAP_ADAPTER = 8'h01;
  localparam logic [7:0] MC_FINCAP_ADAPTER = 8'h02;
  localparam logic [7:0] MC_ERRMSG         = 8'h09;

  // --- LinkMgmt.RDI Subcodes (state value in subcode field) ---------------
  // These correspond 1:1 to the RDI pl_state_sts values, carried in the
  // subcode field of MC_LM_RDI_REQ / MC_LM_RDI_RSP messages.
  localparam logic [7:0] MS_LM_ACTIVE      = 8'h01;
  localparam logic [7:0] MS_LM_PMNAK       = 8'h02;
  localparam logic [7:0] MS_LM_L1          = 8'h04;
  localparam logic [7:0] MS_LM_L2          = 8'h08;
  localparam logic [7:0] MS_LM_LINKRESET   = 8'h09;
  localparam logic [7:0] MS_LM_LINKERROR   = 8'h0A;
  localparam logic [7:0] MS_LM_RETRAIN     = 8'h0B;
  localparam logic [7:0] MS_LM_DISABLE     = 8'h0C;

  // --- SBINIT Phase (sideband initialisation) ----------------------------
  // MC_SB_OOB_RESET : Out-of-band reset detection.
  // MC_SB_DONE_REQ  : SBINIT completion request.
  // MC_SB_DONE_RSP  : SBINIT completion response.
  // MS_SB_OOB_RESET : Out-of-Reset message subcode.
  // MS_SB_DONE      : Done request and response subcode.
  localparam logic [7:0] MC_SB_OOB_RESET   = 8'h91;
  localparam logic [7:0] MC_SB_DONE_REQ    = 8'h95;
  localparam logic [7:0] MC_SB_DONE_RSP    = 8'h9A;
  localparam logic [7:0] MS_SB_OOB_RESET   = 8'h00;
  localparam logic [7:0] MS_SB_DONE        = 8'h01;

  // --- MBINIT Phase (main-band initialisation): req A5h / resp AAh -------
  // MC_MBINIT_REQ/RSP are the code bytes; subcodes below identify the
  // specific MBINIT sub-state handshake.
  localparam logic [7:0] MC_MBINIT_REQ     = 8'hA5;
  localparam logic [7:0] MC_MBINIT_RSP     = 8'hAA;
  localparam logic [7:0] MS_PARAM_CFG      = 8'h00;  // PARAMETER exchange
  localparam logic [7:0] MS_CAL_DONE       = 8'h02;  // CAL complete
  localparam logic [7:0] MS_RPCLK_INIT     = 8'h03;  // REPAIRCLK init
  localparam logic [7:0] MS_RPCLK_RESULT   = 8'h04;  // REPAIRCLK result
  localparam logic [7:0] MS_RPCLK_APPLY    = 8'h05;  // REPAIRCLK apply
  localparam logic [7:0] MS_RPCLK_CHKINI   = 8'h06;  // REPAIRCLK check init
  localparam logic [7:0] MS_RPCLK_CHKRES   = 8'h07;  // REPAIRCLK check result
  localparam logic [7:0] MS_RPCLK_DONE     = 8'h08;  // REPAIRCLK done
  localparam logic [7:0] MS_RPVAL_INIT     = 8'h09;  // REPAIRVAL init
  localparam logic [7:0] MS_RPVAL_RESULT   = 8'h0A;  // REPAIRVAL result
  localparam logic [7:0] MS_RPVAL_APPLY    = 8'h0B;  // REPAIRVAL apply
  localparam logic [7:0] MS_RPVAL_DONE     = 8'h0C;  // REPAIRVAL done
  localparam logic [7:0] MS_REVMB_INIT     = 8'h0D;  // REVERSALMB init
  localparam logic [7:0] MS_REVMB_CLRERR   = 8'h0E;  // REVERSALMB clear errors
  localparam logic [7:0] MS_REVMB_RESULT   = 8'h0F;  // REVERSALMB result
  localparam logic [7:0] MS_REVMB_DONE     = 8'h10;  // REVERSALMB done
  localparam logic [7:0] MS_RPMB_START     = 8'h11;  // REPAIRMB start
  localparam logic [7:0] MS_RPMB_APPLY     = 8'h12;  // REPAIRMB apply
  localparam logic [7:0] MS_RPMB_END       = 8'h13;  // REPAIRMB end
  localparam logic [7:0] MS_RPMB_END2      = 8'h14;  // REPAIRMB end phase 2

  // --- MBTRAIN Phase (main-band training): req B5h / resp BAh ------------
  // MC_MBTRAIN_REQ/RSP are the code bytes; subcodes below cover all
  // MBTRAIN sub-states from VALVREF through REPAIR.
  localparam logic [7:0] MC_MBTRAIN_REQ    = 8'hB5;
  localparam logic [7:0] MC_MBTRAIN_RSP    = 8'hBA;
  localparam logic [7:0] MS_VALVREF_START  = 8'h00;  // VALVREF start
  localparam logic [7:0] MS_VALVREF_END    = 8'h01;  // VALVREF end
  localparam logic [7:0] MS_DATAVREF_START = 8'h02;  // DATAVREF start
  localparam logic [7:0] MS_DATAVREF_END   = 8'h03;  // DATAVREF end
  localparam logic [7:0] MS_SPEEDIDLE_DONE = 8'h04;  // SPEEDIDLE done
  localparam logic [7:0] MS_TXSELFCAL_DONE = 8'h05;  // TXSELFCAL done
  localparam logic [7:0] MS_RXCLKCAL_START = 8'h06;  // RXCLKCAL start
  localparam logic [7:0] MS_RXCLKCAL_DONE  = 8'h07;  // RXCLKCAL done
  localparam logic [7:0] MS_VTC_START      = 8'h08;  // DATACENTER1(VT) start
  localparam logic [7:0] MS_VTC_DONE       = 8'h09;  // DATACENTER1(VT) done
  localparam logic [7:0] MS_VTV_START      = 8'h0A;  // DATAVREF1(VT) start
  localparam logic [7:0] MS_VTV_END        = 8'h0B;  // DATAVREF1(VT) end
  localparam logic [7:0] MS_DTC1_START     = 8'h0C;  // DATACENTER1 start
  localparam logic [7:0] MS_DTC1_END       = 8'h0D;  // DATACENTER1 end
  localparam logic [7:0] MS_DTV_START      = 8'h0E;  // DATAVREF start
  localparam logic [7:0] MS_DTV_END        = 8'h10;  // DATAVREF end
  localparam logic [7:0] MS_DESKEW_START   = 8'h11;  // RXDESKEW start
  localparam logic [7:0] MS_DESKEW_END     = 8'h12;  // RXDESKEW end
  localparam logic [7:0] MS_DTC2_START     = 8'h13;  // DATACENTER2 start
  localparam logic [7:0] MS_DTC2_END       = 8'h14;  // DATACENTER2 end
  localparam logic [7:0] MS_LKS_START      = 8'h15;  // LINKSPEED start
  localparam logic [7:0] MS_LKS_ERROR      = 8'h16;  // LINKSPEED error
  localparam logic [7:0] MS_LKS_EXIT_REP   = 8'h17;  // LINKSPEED → repair
  localparam logic [7:0] MS_LKS_EXIT_DEG   = 8'h18;  // LINKSPEED → degrade
  localparam logic [7:0] MS_LKS_DONE       = 8'h19;  // LINKSPEED done
  localparam logic [7:0] MS_LKS_MM_DIS     = 8'h1A;  // LINKSPEED mismatch disable
  localparam logic [7:0] MS_LKS_EXIT_PHY   = 8'h1F;  // LINKSPEED → PHYRETRAIN
  localparam logic [7:0] MS_REPAIR_INIT    = 8'h1B;  // REPAIR init
  localparam logic [7:0] MS_REPAIR_APPLY   = 8'h1C;  // REPAIR apply
  localparam logic [7:0] MS_REPAIR_END     = 8'h1D;  // REPAIR end
  localparam logic [7:0] MS_REPAIR_DEGRADE = 8'h1E;  // REPAIR degrade

  // --- PHYRETRAIN Phase: req C5h / resp CAh ------------------------------
  // MC_PHYR_REQ/RSP : code bytes for PHYRETRAIN handshake.
  // MS_PHYR_INIT    : initialisation subcode.
  // MS_PHYR_START   : start-of-retrain subcode.
  localparam logic [7:0] MC_PHYR_REQ       = 8'hC5;
  localparam logic [7:0] MC_PHYR_RSP       = 8'hCA;
  localparam logic [7:0] MS_PHYR_INIT      = 8'h00;
  localparam logic [7:0] MS_PHYR_START     = 8'h01;

  // --- TRAINERROR Phase: req E5h / resp EAh ------------------------------
  // MC_TE_REQ/RSP : code bytes for TRAINERROR handshake.
  // MS_TE_ENTRY   : subcode indicating entry into TRAINERROR.
  localparam logic [7:0] MC_TE_REQ         = 8'hE5;
  localparam logic [7:0] MC_TE_RSP         = 8'hEA;
  localparam logic [7:0] MS_TE_ENTRY       = 8'h00;

  // ========================================================================
  // AdvCap.Adapter Data Payload Bit Positions
  // ========================================================================
  // Bit positions within the 64-bit data payload of an AdvCap.Adapter
  // sideband message (spec, adapter capability exchange).
  localparam int unsigned ADV_RAW_MODE     = 0;   // Raw Mode support
  localparam int unsigned ADV_STREAMING    = 4;   // Streaming support
  localparam int unsigned ADV_STACK0_EN    = 7;   // Stack 0 enable
  localparam int unsigned ADV_RETIMER      = 11;  // Retimer present
  localparam int unsigned ADV_RTM_CRD_LO   = 12;  // Retimer credit low bit
  localparam int unsigned ADV_RTM_CRD_HI   = 20;  // Retimer credit high bit
  localparam int unsigned ADV_DP           = 21;  // Downstream Port
  localparam int unsigned ADV_UP           = 22;  // Upstream Port

  // ========================================================================
  // Width-Degrade Lane Map
  // ========================================================================
  // Apply-degrade request MsgInfo [1:0] values indicating which half of
  // the x16 link to keep when degrading to x8.
  localparam logic [1:0] DEGRADE_LANES_0_7  = 2'b01;  // Keep lanes 0–7
  localparam logic [1:0] DEGRADE_LANES_8_15 = 2'b10;  // Keep lanes 8–15

  // ========================================================================
  // Sideband Credit Limits (spec 6.1.3)
  // ========================================================================
  // SB_CRD_MAX : Maximum number of outstanding remote sideband credits.
  //              Each partner may have up to 4 messages in flight.
  localparam int unsigned SB_CRD_MAX = 4;

  // ========================================================================
  // MBINIT.PARAM Constants  (spec Table 56)
  // ========================================================================
  // Table 56 defines the DATA64 configuration request and response. The
  // request carries Module ID, clock phase, clock mode, voltage swing, and
  // maximum I/O speed. The response retains clock phase, clock mode, and
  // maximum I/O speed. All other response bits are reserved.
  //
  // The fixed profile sends Module 0, differential clock, continuous clock,
  // Vswing 01h, and 4 GT/s. The immutable values below are the only PARAM
  // payload source. PHY CSR values remain observability-only.
  //
  // Spec ref: UCIe 1.0, Table 56; Section 4.5.3.3.1 MBINIT.PARAM.
  // -----------------------------------------------------------------------
  // Request and response payload masks
  // -----------------------------------------------------------------------
  // The request Module ID occupies [12:11]. Clock phase is bit [10], clock
  // mode is bit [9], Vswing is [8:4], and maximum I/O speed is [3:0].
  // The response uses bits [10], [9], and [3:0]; response bits [8:4] are
  // reserved. Each mask is 64 bits because the DATA64 payload is 64 bits.
  localparam logic [63:0] PARAM_MASK_MODULE_ID   = 64'h0000_0000_0000_1800;
  localparam logic [63:0] PARAM_MASK_CLOCK_PHASE = 64'h0000_0000_0000_0400;
  localparam logic [63:0] PARAM_MASK_CLOCK_MODE  = 64'h0000_0000_0000_0200;
  localparam logic [63:0] PARAM_MASK_VSWING      = 64'h0000_0000_0000_01F0;
  localparam logic [63:0] PARAM_MASK_MAX_SPEED   = 64'h0000_0000_0000_000F;

  // -----------------------------------------------------------------------
  // Fixed profile request and response values
  // -----------------------------------------------------------------------
  // Module 0 and differential clock encode as zero. Continuous clock sets
  // bit [9]. Vswing 01h sets bit [4]. 4 GT/s encodes as zero in [3:0].
  // The response has continuous differential clock at 4 GT/s.
  localparam logic [63:0] PARAM_REQ_DATA = 64'h0000_0000_0000_0210;
  localparam logic [63:0] PARAM_RSP_DATA = 64'h0000_0000_0000_0200;

  // -----------------------------------------------------------------------
  // Accepted request Vswing range
  // -----------------------------------------------------------------------
  // The fixed profile accepts every defined request Vswing encoding from
  // 01h through 10h. Zero and values above 10h are reserved and fatal.
  localparam logic [4:0] PARAM_VSWING_MIN = 5'h01;
  localparam logic [4:0] PARAM_VSWING_MAX = 5'h10;

  // -----------------------------------------------------------------------
  // Named packet roles
  // -----------------------------------------------------------------------
  // The LTSM uses these request/response role values with the existing
  // MBINIT, MBTRAIN, LinkMgmt, and TRAINERROR code constants. The codec and
  // CDC transport remain role-free.
  typedef enum logic {SB_ROLE_REQUEST, SB_ROLE_RESPONSE} sb_msg_role_t;
  localparam sb_msg_role_t ROLE_MBINIT_REQUEST     = SB_ROLE_REQUEST;
  localparam sb_msg_role_t ROLE_MBINIT_RESPONSE    = SB_ROLE_RESPONSE;
  localparam sb_msg_role_t ROLE_MBTRAIN_REQUEST    = SB_ROLE_REQUEST;
  localparam sb_msg_role_t ROLE_MBTRAIN_RESPONSE   = SB_ROLE_RESPONSE;
  localparam sb_msg_role_t ROLE_LINKMGMT_REQUEST   = SB_ROLE_REQUEST;
  localparam sb_msg_role_t ROLE_LINKMGMT_RESPONSE  = SB_ROLE_RESPONSE;
  localparam sb_msg_role_t ROLE_TRAINERROR_REQUEST = SB_ROLE_REQUEST;
  localparam sb_msg_role_t ROLE_TRAINERROR_RESPONSE= SB_ROLE_RESPONSE;

endpackage

`endif

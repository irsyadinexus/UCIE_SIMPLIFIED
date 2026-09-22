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
//                                sideband message timeout (8 ms), and stall
//                                interval (4 ms).  These are expressed in both
//                                nanoseconds and lclk cycle counts.
//   4. Sideband framing        – Packet width (64 b) and inter-packet gap
//                                (32 UI).
//   5. Training pattern sizes  – VALTRAIN iteration count (128) and
//                                detection threshold (16), plus LFSR
//                                pattern length in UI (4096).
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
//  11. Sideband opcodes & IDs  – Table 47 opcodes, Table 49 source/dest IDs.
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
//
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
  // NC:     sideband configuration interface width (8 bits), matching the
  //         SB channel physical width.
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

  // ========================================================================
  // Sideband Framing
  // ========================================================================
  // SB_PKT_BITS : 64 – each sideband packet is 64 bits (spec 6.1.1).
  // SB_GAP_UI   : 32 – minimum inter-packet gap in UI (spec 6.1.2).
  localparam int unsigned SB_PKT_BITS  = 64;
  localparam int unsigned SB_GAP_UI    = 32;

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
  // Sideband Opcodes (spec Table 47)
  // ========================================================================
  // sb_opcode_t – 5-bit opcode field in the sideband packet header.
  //   SB_OP_MSG_NODATA : message without data payload (10010).
  //   SB_OP_MSG_DATA64 : message with 64-bit data payload (11011).
  typedef logic [4:0] sb_opcode_t;
  localparam sb_opcode_t SB_OP_MSG_NODATA = 5'b10010; // message without data
  localparam sb_opcode_t SB_OP_MSG_DATA64 = 5'b11011; // message with 64b data

  // ========================================================================
  // Sideband Source / Destination IDs (spec Table 49)
  // ========================================================================
  // sb_srcid_t – 3-bit source/destination identifier.
  //   SRCID_STACK0 : Stack 0 (protocol layer).
  //   SRCID_ADAPT  : D2D adapter layer.
  typedef logic [2:0] sb_srcid_t;
  localparam sb_srcid_t SRCID_STACK0 = 3'b000;
  localparam sb_srcid_t SRCID_ADAPT  = 3'b001;

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
  localparam logic [7:0] MC_SB_OOB_RESET   = 8'h91;
  localparam logic [7:0] MC_SB_DONE_REQ    = 8'h95;
  localparam logic [7:0] MC_SB_DONE_RSP    = 8'h9A;

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

endpackage

`endif

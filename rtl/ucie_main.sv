// ============================================================================
// File        : ucie_main.sv
// Project     : UCIe 1.0 Simplified Endpoint (Proof of Concept)
// Description : Top-level integration module for a single-die UCIe endpoint.
//
// This is the chip-top for the reduced-capability UCIe 1.0 implementation.
// It instantiates exactly two major blocks  --  the Die-to-Die (D2D) Adapter
// and the Logical PHY  --  and wires them together across the Raw Die-to-Die
// Interface (RDI, spec section 8.1, Table 114).  The Flit-Aware Die-to-Die
// Interface (FDI, spec section 8.2, Table 115) is exposed at the module
// boundary for the protocol layer to connect to.  The sideband serial pins
// and the main-band data lanes are also presented at the boundary for the
// physical interconnect to the partner die.
//
// ============================================================================
//
//                        REDUCED CAPABILITY SET
// ============================================================================
//
// This design intentionally omits several features of the full UCIe 1.0 spec
// to keep the proof-of-concept scope tractable:
//
//   * Single module only          -- no multi-module PHY (spec 4.7).
//   * Single D2D Adapter          -- one adapter, one logical PHY instance.
//   * Single protocol layer       -- Stack 0 only; stream ID 04h.
//   * Streaming protocol          -- Raw Mode (Format 1, spec 3.2.1).
//   * No retimer support          -- spec 1.3 retimer path not implemented.
//   * No analog / electrical PHY  -- the Logical PHY negotiates parameters
//                                    but does not model analog circuits.
//   * No CXL, no PCIe             -- only the Streaming protocol is wired.
//   * Standard Package x16 only   -- width degrade is not negotiated on the
//                                    main line; the byte-to-lane mapper does
//                                    implement both x8 degrade halves for
//                                    unit-test coverage.
//   * 4 GT/s main-band rate       -- higher data rates not supported.
//   * No CRC / retry / replay     -- legal at 4 GT/s per spec 5.10.
//   * 800 MHz sideband clock.
//   * 500 MHz lclk (2 GHz main-band fCK).
//
// The source of truth for all spec references is UCIE.md at the repo root,
// which is the markdown rendition of UCIE.pdf (UCIe Specification Rev 1.0,
// February 24, 2022).
//
// ============================================================================
//
//                   TWO-BLOCK TOPOLOGY: OVERVIEW
// ============================================================================
//
// The strict two-module topology is mandated by the README and follows the
// spec's layering model (spec Figure 7, Figure 8, section 1.1):
//
//   1. D2D Adapter (d2d_adapter.sv)  --  owns the FDI toward the protocol
//      layer and the adapter-side half of the RDI.  It runs the FDI state
//      machine, the streaming pass-through datapath, the adapter register
//      file (Link Control/Status, Error Log 0/1), and the adapter sideband
//      interface (lp_cfg / pl_cfg).  Critically, the Link Training and
//      Status Machine (LTSM) is NOT in this block; it is entirely opaque
//      to the adapter.  The adapter sees only the RDI status signals that
//      the logical PHY publishes; it never sees LTSM sub-states.
//
//   2. Logical PHY (logical_phy.sv)  --  owns the PHY-side half of the RDI
//      and the external sideband and main-band pins to the partner die.
//      It contains the RDI state machine (spec 8.1.5, Figure 111), the
//      LTSM (spec 4.5.3, Figure 69  --  all 24 state encodings, 21
//      reachable in this reduced scope), the sideband codec (64-bit header
//      with CP/DP parity, spec 6.1), the training pattern generator
//      (Per-Lane-ID, VALTRAIN, clock repair, LFSR  --  spec 4.4), the
//      byte-to-lane mapper (spec 4.1.1), and the PHY CSR block (spec 7.5.3,
//      electrical parameter registers only; no analog modelling).
//
// No other blocks exist at this level or anywhere else in the hierarchy.
// There is no retimer, no protocol layer RTL, and no analog PHY model.
//
// ============================================================================
//
//                        ASCII BLOCK DIAGRAM
// ============================================================================
//
//  Protocol Layer                                             Partner Die
//  (external,                                                 (external,
//   FDI pins)                                                  bumps)
//      |                                                         |
//      |  FDI (Table 115)                                        |
//      |  lp_irdy/valid/data ---+                                |
//      |  lp_state_req ---------+                                |
//      |  lp_stallack ----------+                                |
//      |  lp_stream/rx_active --+                                |
//      |  lp_cfg/pl_cfg <------->                                |
//      |  lp_clk_ack/pl_clk_req -+                                |
//      |  lp_wake_req/pl_wake_ack                                |
//      |  lp_linkerror --------->                                |
//      |                        |                                |
//      |  pl_trdy/valid/data <--+                                |
//      |  pl_state_sts <--------+                                |
//      |  pl_protocol* <--------+                                |
//      |  pl_stallreq <---------+                                |
//      |  pl_error/cerror/nf <--+                                |
//      |  pl_phyinrecenter <----+                                |
//      |  pl_inband_pres <------+                                |
//      |  pl_speed/lnk_cfg <----+                                |
//      v                        v                                v
//  +================================================================+
//  |                        ucie_main (this module)                 |
//  |                                                                |
//  |  +---------------------------+  RDI (Tbl 114)  +------------+ |
//  |  |      D2D Adapter          |<================>| Logical    | |
//  |  |      (u_adapter)          | rdi_lp_state_req | PHY        | |
//  |  |                           | rdi_lp_stallack  | (u_lphy)   | |
//  |  |  +---------------------+  | rdi_lp_irdy      |            | |
//  |  |  | FDI State Machine   |  | rdi_lp_valid     | +--------+ | |
//  |  |  | (spec 8.2.5)        |  | rdi_lp_data      | | RDI SM | | |
//  |  |  | Mirrors RDI sts to  |  |                   | |(8.1.5) | | |
//  |  |  | FDI pl_state_sts    |  | rdi_pl_state_sts  | +--------+ | |
//  |  |  +---------------------+  | rdi_pl_inband_pres|            | |
//  |  |                           | rdi_pl_error      | +--------+ | |
//  |  |  +---------------------+  | rdi_pl_cerror     | | LTSM   | | |
//  |  |  | Streaming Datapath  |  | rdi_pl_nferror    | |(4.5.3) | | |
//  |  |  | Raw Mode pass-thru  |  | rdi_pl_trainerror | |24 state| | |
//  |  |  | FDI <-> RDI data    |  | rdi_pl_phyinrectr | |encodngs| | |
//  |  |  +---------------------+  | rdi_pl_trdy       | +--------+ | |
//  |  |                           | rdi_pl_valid      |            | |
//  |  |  +---------------------+  | rdi_pl_data       | +--------+ | |
//  |  |  | Adapter Regfile     |  | rdi_pl_lnk_cfg    | | SB     | | |
//  |  |  | Link Ctl/Sts,      |  | rdi_pl_speedmode   | | Codec  | | |
//  |  |  | Error Log 0/1      |  | rdi_pl_stallreq    | |(6.1)   | | |
//  |  |  +---------------------+  | rdi_pl_linkerror   | +--------+ | |
//  |  |                           |                   |            | |
//  |  |  +---------------------+  | adapter_sb_* pkt  | +--------+ | |
//  |  |  | Adapter SB IF       |  | phy_csr_* channel | |PatGen  | | |
//  |  |  | (lp_cfg / pl_cfg)  |  | rdi_lp_linkerror  | |(4.4)   | | |
//  |  |  +---------------------+  |                   | +--------+ | |
//  |  |  Start copies -------->| private event wiring  | |ByteLane| | |
//  |  |  (Adapter and PHY CSR) | clear after Active    | | Mapper | | |
//  |  +------------------------+ Entry, spec 8.1.6     | |(4.1.1) | | |
//  |                                                  | +--------+ | |
//  |                                                  |            | |
//  |                                                  | +--------+ | |
//  |                                                  | |PHY CSR | | |
//  |                                                  | |(7.5.3) | | |
//  |                                                  | +--------+ | |
//  |                                                  |            | |
//  |                                                  | sb_tx_clk  |==> SB TX
//  |                                                  | sb_tx_data |==> to
//  |                                                  | sb_rx_clk  |<== partner
//  |                                                  | sb_rx_data |<== die
//  |                                                  |            | |
//  |                                                  | mb_tx_data |==> MB TX
//  |                                                  | mb_rx_data |<== MB RX
//  |                                                  +------------+ |
//  +================================================================+
//
//  Key observations from the diagram:
//
//  (a) The LTSM (Link Training & Status Machine) lives entirely within the
//      Logical PHY.  The D2D Adapter never sees LTSM sub-states; it only
//      observes the RDI state_sts signal that the RDI SM publishes after
//      the LTSM reaches a phase boundary (e.g. ACTIVE, RETRAIN, LINKERROR).
//      This opacity is by design (spec 3.4, Figure 34).
//
//  (b) Sideband and main-band physical pins exit only from the Logical PHY.
//      The adapter communicates with the partner die through private typed
//      packet client ports (adapter_sb_*) arbitrated and routed through
//      the Logical PHY's typed CDC mailbox and scalar sideband codec.
//
//  (c) The LTSM owns the PHY-side LinkMgmt.RDI Active exchange. The Adapter
//      and PHY CSR Start copies cross only as private edge-triggered events.
//      The completed Active Entry result clears both sticky copies.
//  (d) Adapter CSR Start and PHY CSR Start use private internal wiring,
//      allowing link training initiation via software CSR writes without
//      a dedicated top-level pin.
// ============================================================================
//
//                       RDI / FDI SIGNAL NAMING
// ============================================================================
//
// Naming follows the spec convention:
//   lp_*  = Link Partner (protocol layer) side of FDI -- inputs to this die.
//   pl_*  = Physical Layer side of FDI -- outputs from the adapter.
//   rdi_lp_*  = adapter (LP) side of RDI -- from adapter toward PHY.
//   rdi_pl_*  = PHY (PL) side of RDI -- from PHY toward adapter.
//
// All RDI signals are internal nets declared in this module and connected
// by name to the two sub-module instantiations.
//
// ============================================================================
//
//                       CLOCK DOMAINS
// ============================================================================
//
//   lclk       -- 500 MHz link clock.  Drives all RDI/FDI transfers and both
//                 the adapter and the PHY's data-path logic.  Spec 8.1.2.
//   sbclk      -- 800 MHz sideband clock.  Drives only the sideband codec
//                 inside the Logical PHY.  Spec 5.13.
//   lreset_n   -- active-low asynchronous reset for downstream lclk-domain state.
//   sbreset_n  -- active-low asynchronous reset for downstream sbclk-domain state.
//
// ============================================================================
//
//                       PARAMETERS
// ============================================================================
//
//   NBYTES -- Number of bytes per beat on both the FDI and the RDI data buses.
//             Default 16 (= 128-bit data bus for x16 Standard Package).
//             The value propagates to both sub-modules unchanged.
//
//   NLANES -- Number of main-band data lanes toward the partner die.
//             Default NLANES_MAX (16).  Propagated to the Logical PHY only;
//             the adapter is lane-agnostic.
//
// ============================================================================
//
//                        REVISION HISTORY
// ============================================================================
//
//   Version   Date        Description
//   -------   ----------  ----------------------------------------------------
//   v0.0.1    2026-09-22  First commit to git. Contains the complete two-block
//                         topology with full RDI wiring between the D2D
//                         Adapter and the Logical PHY, FDI pin-out toward the
//                         protocol layer, and sideband + main-band pin-out
//                         toward the partner die. Reduced capability set:
//                         single module, single adapter, Streaming Raw Mode,
//                         x16 Standard Package, 4 GT/s, no retimer, no analog
//                         PHY, no CXL/PCIe protocol layer.
//   v0.0.2    2026-09-22  Update lclk documentation to 500 MHz.
//   v0.0.3    2026-09-23  Add 2 GHz mbclk and DDR main-band framing (Req.2).
//   v0.0.4    2026-09-23  Req.2: thread mb_tx_valid / mb_rx_valid framing to both dies.
//   v0.0.5    2026-09-23  Documentation: replace the fabricated "Table 68 - Sideband
//                         and Configuration signal list" citation. Table 68 is the
//                         UCIe Link DVSEC - Error Notification Control. The
//                         configuration sideband signals are now cited to
//                         Table 115 and Section 5.13.
//   v0.0.6    2026-09-25  Phase C: wire the private LTSM Active-entry Start
//                         clear from logical_phy to the Adapter register copy.
//   v0.0.7    2026-09-25  Phase D: route Adapter Start as a private event
//                         and remove stale peer-Active feedback.
//   v0.0.8    2026-09-25  Preserve the public adapter_active_req input
//                         with a low policy-inert tie-off.
//   v0.0.9    2026-09-28  Sideband protocol remediation:
//                         Expose scalar sb_tx_clk/sb_tx_data and
//                         sb_rx_clk/sb_rx_data (Sections 4.1.5, 5.13).
//                         Expose public FDI cfg sideband (lp_cfg/pl_cfg)
//                         and Stage 3 clock/wake/protocol ports
//                         (Sections 6.1, 7.5, 8.2). Make lp_linkerror
//                         an input (Section 8.2). Cross-connect typed
//                         Adapter packet channels and PHY CSR channel
//                         between u_adapter and u_lphy (Sections 6.1, 7.5, 8.1).
//   v0.0.10   2026-10-08  UCIe 1.0 Section 8.3.2.7 LinkError remediation:
//                         Implement unscaled 8 ms LinkError residency dwell,
//                         sideband LinkError handshake dwell bypass, and direct
//                         transition to RESET without LinkReset per Figures 111,
//                         119, and 126.
//   v0.0.11   2026-10-08  Documentation compliance pass: expand the header and the
//                         per-construct comment blocks, including every module
//                         instantiation.
//   v0.0.12   2026-10-09  Documentation and hygiene pass: remove Author column
//                         and add per-port inline comments.
`ifndef UcieMain_SV
`define UcieMain_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;
`timescale 1ns/1ps
module ucie_main #(
  parameter int unsigned NBYTES   = ucie_pkg::NBYTES,
  parameter int unsigned NLANES   = NLANES_MAX,
  parameter int unsigned NC       = ucie_pkg::NC,
  parameter bit          FAST_SIM = 1'b1
) (
  input  logic        lclk,                 // 500 MHz main link clock
  input  logic        lreset_n,             // Active-low asynchronous reset for downstream lclk-domain state
  input  logic        mbclk,                // 2 GHz forwarded clock fCK (Req.2)
  input  logic        sbclk,                // 800 MHz sideband clock
  input  logic        sbreset_n,            // Active-low sideband reset
  // ---------------------------------------------------------- FDI (Table 115)
  input  logic        lp_irdy,              // Protocol Layer initiator ready (FDI)
  input  logic        lp_valid,             // Protocol Layer transmit valid (FDI)
  input  logic [DATA_W-1:0] lp_data,        // Protocol Layer transmit data bus (FDI)
  input  logic [7:0]  lp_stream,            // Protocol Layer transmit stream ID (FDI)
  input  logic        lp_stallack,          // Protocol Layer stall acknowledge (FDI)
  input  logic        lp_rx_active_sts,     // Protocol Layer RX active status indication (FDI)
  output logic        pl_trdy,              // Adapter target ready to Protocol Layer (FDI)
  output logic        pl_valid,             // Adapter receive valid to Protocol Layer (FDI)
  output logic [DATA_W-1:0] pl_data,        // Adapter receive data bus to Protocol Layer (FDI)
  output logic [7:0]  pl_stream,            // Adapter receive stream ID to Protocol Layer (FDI)
  output logic        pl_error,             // Link error status to Protocol Layer (FDI)
  output logic        pl_cerror,            // Correctable error status to Protocol Layer (FDI)
  output logic        pl_nferror,           // Non-fatal error status to Protocol Layer (FDI)
  output logic        pl_trainerror,        // Training error status to Protocol Layer (FDI)
  output logic        pl_phyinrecenter,     // PHY in recenter status to Protocol Layer (FDI)
  output logic [2:0]  pl_protocol,          // Negotiated protocol mode (fixed Streaming)
  output logic [3:0]  pl_protocol_flitfmt,  // Negotiated flit format (fixed Raw Mode Format 1)
  output logic        pl_rx_active_req,     // Adapter receiver active request to Protocol Layer (FDI)
  input  logic [3:0]  lp_state_req,         // FDI link state request from Protocol Layer
  output logic [3:0]  pl_state_sts,         // FDI link state status to Protocol Layer
  output logic        pl_inband_pres,       // In-band presence indication to Protocol Layer
  output logic        pl_stallreq,          // Adapter stall request to Protocol Layer (FDI)
  input  logic        lp_linkerror = 1'b0,  // Protocol Layer LinkError request trigger (FDI)

  // FDI Configuration Sideband (UCIe 1.0 Section 8.2.3, Table 115)
  input  logic [NC-1:0] lp_cfg = '0,        // Inbound FDI configuration byte from Protocol Layer
  input  logic        lp_cfg_vld = 1'b0,    // Inbound FDI configuration valid qualifier
  input  logic        lp_cfg_crd = 1'b0,    // Inbound FDI configuration credit return
  output logic [NC-1:0] pl_cfg,             // Outbound FDI configuration byte to Protocol Layer
  output logic        pl_cfg_vld,           // Outbound FDI configuration valid qualifier
  output logic        pl_cfg_crd,           // Outbound FDI configuration credit return

  // FDI Stage 3 Clock / Wake / Protocol Status (UCIe 1.0 Section 8.2, Table 115)
  output logic        pl_protocol_vld,      // Protocol identification valid qualifier
  output logic        pl_clk_req,           // Main clock request to Protocol Layer
  input  logic        lp_clk_ack = 1'b1,    // Main clock acknowledge from Protocol Layer
  input  logic        lp_wake_req = 1'b0,   // Wake request from Protocol Layer
  output logic        pl_wake_ack,          // Wake acknowledge to Protocol Layer
  output logic [2:0]  pl_speedmode,         // Current negotiated speed mode (4 GT/s)
  output logic [2:0]  pl_lnk_cfg,           // Link width configuration status (x16 / x8)

  // ------------------------------------------------- sideband to partner (scalar)
  output logic        sb_tx_clk,            // Physical sideband forwarded clock/strobe to peer die
  output logic        sb_tx_data,           // Physical sideband serialized data to peer die
  input  logic        sb_rx_clk,            // Physical sideband forwarded clock/strobe from peer die
  input  logic        sb_rx_data,           // Physical sideband serialized data from peer die
  // ------------------------------------------------- main band to partner
  output logic [NLANES-1:0] mb_tx_data,     // Physical main-band transmit data lanes to peer die
  output logic        mb_tx_valid,          // Main-band transmit framing valid (Req.2)
  input  logic [NLANES-1:0] mb_rx_data,     // Physical main-band receive data lanes from peer die
  input  logic        mb_rx_valid           // Main-band receive framing valid (Req.2)
);

  // ==========================================================================
  // RDI (Raw Die-to-Die Interface) Internal Nets -- Spec 8.1, Table 114
  // ==========================================================================
  //
  // Every signal below is a point-to-point wire between u_adapter and u_lphy.
  // They implement the RDI as defined in UCIe spec section 8.1, Table 114.
  //
  // Naming follows the spec convention: signals prefixed "rdi_lp_" originate
  // from the adapter (Link Partner side of RDI) and are driven toward the
  // Logical PHY.  Signals prefixed "rdi_pl_" originate from the Logical PHY
  // (Physical Layer side of RDI) and are driven toward the adapter.
  //
  // The RDI carries:
  //   - State request / status handshake (rdi_lp_state_req / rdi_pl_state_sts)
  //     for coordinating link state transitions (RESET, ACTIVE, L1, L2,
  //     LINKRESET, RETRAIN, DISABLED) per the RDI state machine (spec 8.1.5,
  //     Figure 111).
  //   - Data path signals (rdi_lp_irdy, rdi_lp_valid, rdi_lp_data for TX;
  //     rdi_pl_trdy, rdi_pl_valid, rdi_pl_data for RX) following the
  //     handshake rules in spec 8.1.4.
  //   - Error / status indicators (pl_error, pl_cerror, pl_nferror,
  //     pl_trainerror, pl_linkerror, pl_phyinrecenter, pl_inband_pres)
  //     reported by the PHY to the adapter.
  //   - Link configuration outputs (pl_lnk_cfg, pl_speedmode) advertised
  //     by the PHY after training completes.
  //   - Stall handshake (rdi_pl_stallreq / rdi_lp_stallack) per spec 8.3.1.
  //   - Dedicated PHY CSR channel (phy_csr_*) and typed sideband packet ports
  //     (adapter_sb_*) between Adapter and Logical PHY for configuration and
  //     packet routing (Sections 6.1, 7.5).
  // ==========================================================================
  rdi_req_t    rdi_lp_state_req;
  logic        rdi_lp_stallack;
  rdi_sts_t    rdi_pl_state_sts;
  logic        rdi_pl_inband_pres;
  logic        rdi_pl_linkerror;
  logic        rdi_pl_error;
  logic        rdi_pl_phyinrecenter;
  logic        rdi_pl_cerror;
  logic        rdi_pl_nferror;
  logic        rdi_pl_trainerror;
  logic        rdi_lp_irdy;
  logic        rdi_lp_valid;
  logic [DATA_W-1:0] rdi_lp_data;
  logic        rdi_pl_trdy;
  logic        rdi_pl_valid;
  logic [DATA_W-1:0] rdi_pl_data;
  logic [2:0]  rdi_pl_lnk_cfg;
  logic [2:0]  rdi_pl_speedmode;
  logic        rdi_pl_stallreq;
  logic        rdi_lp_linkerror;

  // ==========================================================================
  // Private Typed Adapter Packet Client Channel -- Spec 6.1
  // ==========================================================================
  logic        adapter_sb_tx_valid;
  logic        adapter_sb_tx_ready;
  sb_packet_t  adapter_sb_tx_packet;
  logic        adapter_sb_rx_valid;
  logic        adapter_sb_rx_ready;
  sb_packet_t  adapter_sb_rx_packet;
  logic        adapter_sb_rx_cp_error;
  logic        adapter_sb_rx_dp_error;
  logic        adapter_sb_rx_format_error;

  // ==========================================================================
  // Separate PHY CSR Access Channel -- Spec 7.5
  // ==========================================================================
  logic        phy_csr_wr;
  logic        phy_csr_rd;
  logic [26:0] phy_csr_addr;
  logic [63:0] phy_csr_wdata;
  logic [7:0]  phy_csr_be;
  logic [63:0] phy_csr_rdata;
  logic        phy_csr_rdata_vld;
  // ==========================================================================
  // Private Start-event wiring -- PLAN.md Sections 15.5 and 15.9
  // ==========================================================================
  // The Adapter and PHY CSR each own a sticky Start copy. The Adapter output
  // below is an internal level, not a public port. logical_phy edge-detects
  // both copies before sending one training event to the LTSM.
  //
  // The completed Active Entry result clears both copies through the existing
  // private clear path. No peer-Active feedback crosses this boundary because
  // the LTSM owns the PHY-side LinkMgmt.RDI Active exchange.
  //
  // Spec refs: UCIe 1.0 Sections 7.5 and 8.1.6; PLAN.md Section 15.5.
  // ==========================================================================
  logic        adapter_start_link_train;
  logic        clear_start_link_train;

  // ==========================================================================
  // D2D Adapter Instantiation  --  Spec 1.1.2, Chapter 3, Sections 8.1 / 8.2
  // ==========================================================================
  // Bridge between protocol FDI (spec 8.2, Table 115) and PHY RDI (spec 8.1,
  // Table 114). Sub-blocks inside d2d_adapter.sv:
  //   - fdi_state_machine (spec 8.2.5): mirrors RDI states onto FDI.
  //   - adapter_datapath (spec 3.2.1): Raw Mode 1:1 pass-through datapath.
  //   - adapter_regfile (spec 7.5.3): link control, status, and error CSRs.
  //   - adapter_sb_if (spec 6.1): FDI configuration sideband interface.
  //
  // LTSM lives entirely in Logical PHY and is opaque to the adapter (spec 3.4).
  //
  // Ports:
  //   Clocks/reset (lclk, lreset_n), FDI (lp_*/pl_*), RDI (rdi_lp_*/rdi_pl_*),
  //   sideband config (lp_cfg/pl_cfg), and trigger/active status signals.
  // ==========================================================================
  d2d_adapter #(
    .NBYTES(NBYTES),
    .NC(NC)
  ) u_adapter (
    .lclk                  (lclk),
    .lreset_n              (lreset_n),
    // FDI
    .lp_irdy               (lp_irdy),
    .lp_valid              (lp_valid),
    .lp_data               (lp_data),
    .lp_stream             (lp_stream),
    .lp_stallack           (lp_stallack),
    .lp_rx_active_sts      (lp_rx_active_sts),
    .pl_trdy               (pl_trdy),
    .pl_valid              (pl_valid),
    .pl_data               (pl_data),
    .pl_stream             (pl_stream),
    .pl_error              (pl_error),
    .pl_cerror             (pl_cerror),
    .pl_nferror            (pl_nferror),
    .pl_trainerror         (pl_trainerror),
    .pl_phyinrecenter      (pl_phyinrecenter),
    .pl_protocol           (pl_protocol),
    .pl_protocol_flitfmt   (pl_protocol_flitfmt),
    .pl_protocol_vld       (pl_protocol_vld),
    .pl_clk_req            (pl_clk_req),
    .lp_clk_ack            (lp_clk_ack),
    .lp_wake_req           (lp_wake_req),
    .pl_wake_ack           (pl_wake_ack),
    .pl_speedmode          (pl_speedmode),
    .pl_lnk_cfg            (pl_lnk_cfg),
    .pl_rx_active_req      (pl_rx_active_req),
    .lp_state_req          (lp_state_req),
    .pl_state_sts          (pl_state_sts),
    .pl_inband_pres        (pl_inband_pres),
    .pl_stallreq           (pl_stallreq),
    .lp_cfg                (lp_cfg),
    .lp_cfg_vld            (lp_cfg_vld),
    .lp_cfg_crd            (lp_cfg_crd),
    .pl_cfg                (pl_cfg),
    .pl_cfg_vld            (pl_cfg_vld),
    .pl_cfg_crd            (pl_cfg_crd),
    .lp_linkerror          (lp_linkerror),
    // RDI
    .rdi_lp_state_req      (rdi_lp_state_req),
    .rdi_lp_stallack       (rdi_lp_stallack),
    .rdi_lp_linkerror      (rdi_lp_linkerror),
    .rdi_pl_state_sts      (rdi_pl_state_sts),
    .rdi_pl_inband_pres    (rdi_pl_inband_pres),
    .rdi_pl_error          (rdi_pl_error),
    .rdi_pl_phyinrecenter  (rdi_pl_phyinrecenter),
    .rdi_pl_cerror         (rdi_pl_cerror),
    .rdi_pl_nferror        (rdi_pl_nferror),
    .rdi_pl_trainerror     (rdi_pl_trainerror),
    .rdi_lp_irdy           (rdi_lp_irdy),
    .rdi_lp_valid          (rdi_lp_valid),
    .rdi_lp_data           (rdi_lp_data),
    .rdi_pl_trdy           (rdi_pl_trdy),
    .rdi_pl_valid          (rdi_pl_valid),
    .rdi_pl_data           (rdi_pl_data),
    .rdi_pl_lnk_cfg        (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode      (rdi_pl_speedmode),
    .rdi_pl_stallreq       (rdi_pl_stallreq),
    // Private Adapter sideband packet client interface
    .adapter_sb_tx_valid       (adapter_sb_tx_valid),
    .adapter_sb_tx_ready       (adapter_sb_tx_ready),
    .adapter_sb_tx_packet      (adapter_sb_tx_packet),
    .adapter_sb_rx_valid       (adapter_sb_rx_valid),
    .adapter_sb_rx_ready       (adapter_sb_rx_ready),
    .adapter_sb_rx_packet      (adapter_sb_rx_packet),
    .adapter_sb_rx_cp_error    (adapter_sb_rx_cp_error),
    .adapter_sb_rx_dp_error    (adapter_sb_rx_dp_error),
    .adapter_sb_rx_format_error(adapter_sb_rx_format_error),
    // Separate PHY CSR Access Channel
    .phy_csr_wr            (phy_csr_wr),
    .phy_csr_rd            (phy_csr_rd),
    .phy_csr_addr          (phy_csr_addr),
    .phy_csr_wdata         (phy_csr_wdata),
    .phy_csr_be            (phy_csr_be),
    .phy_csr_rdata         (phy_csr_rdata),
    .phy_csr_rdata_vld     (phy_csr_rdata_vld),
    // Training Start
    .clear_start_link_train(clear_start_link_train),
    .adapter_start_link_train(adapter_start_link_train),
    .ltsm_state_obs        (),
    .link_active_obs       ()
  );

  // ==========================================================================
  // Logical PHY Instantiation  --  Spec 1.1.3, Chapter 4, Section 8.1
  // ==========================================================================
  // Implements the PHY half of the RDI (Table 114) and drives external bump pins.
  // Sub-blocks inside logical_phy.sv:
  //   - rdi_state_machine (spec 8.1.5): manages RDI state transitions.
  //   - ltsm (spec 4.5.3): link training sequencer across 24 spec states.
  //   - sb_codec (spec 6.1): 800 MHz sideband codec (64-bit header, optional payload) with CP/DP.
  //   - pattern_gen (spec 4.4): training patterns (Lane-ID, VALTRAIN, LFSR).
  //   - byte_lane_mapper (spec 4.1.1): byte-to-lane mapping and degrade modes.
  //   - phy_csr (spec 7.5.3): electrical parameters and training control CSRs.
  //
  // Ports:
  //   Clocks/reset, local and Adapter Start events, RDI bus, external
  //   sideband/mainband, and configuration sideband. Start events remain
  //   internal to the existing two-block topology.
  // ==========================================================================
  logical_phy #(.NBYTES(NBYTES), .NLANES(NLANES), .FAST_SIM(FAST_SIM)) u_lphy (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .mbclk           (mbclk),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .adapter_start_link_train(adapter_start_link_train),
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack       (rdi_lp_stallack),
    .rdi_lp_linkerror      (rdi_lp_linkerror),
    .rdi_pl_state_sts      (rdi_pl_state_sts),
    .rdi_pl_inband_pres    (rdi_pl_inband_pres),
    .rdi_pl_linkerror      (rdi_pl_linkerror),
    .rdi_pl_phyinrecenter  (rdi_pl_phyinrecenter),
    .rdi_pl_cerror         (rdi_pl_cerror),
    .rdi_pl_nferror        (rdi_pl_nferror),
    .rdi_pl_trainerror     (rdi_pl_trainerror),
    .rdi_lp_irdy           (rdi_lp_irdy),
    .rdi_lp_valid          (rdi_lp_valid),
    .rdi_lp_data           (rdi_lp_data),
    .rdi_pl_trdy           (rdi_pl_trdy),
    .rdi_pl_valid          (rdi_pl_valid),
    .rdi_pl_data           (rdi_pl_data),
    .rdi_pl_lnk_cfg        (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode      (rdi_pl_speedmode),
    .rdi_pl_stallreq       (rdi_pl_stallreq),
    .clear_start_link_train(clear_start_link_train),
    .adapter_active_req    (1'b0),
    // Scalar sideband to partner
    .sb_tx_clk             (sb_tx_clk),
    .sb_tx_data            (sb_tx_data),
    .sb_rx_clk             (sb_rx_clk),
    .sb_rx_data            (sb_rx_data),
    // Typed Adapter packet client interface
    .adapter_sb_tx_valid       (adapter_sb_tx_valid),
    .adapter_sb_tx_ready       (adapter_sb_tx_ready),
    .adapter_sb_tx_packet      (adapter_sb_tx_packet),
    .adapter_sb_rx_valid       (adapter_sb_rx_valid),
    .adapter_sb_rx_ready       (adapter_sb_rx_ready),
    .adapter_sb_rx_packet      (adapter_sb_rx_packet),
    .adapter_sb_rx_cp_error    (adapter_sb_rx_cp_error),
    .adapter_sb_rx_dp_error    (adapter_sb_rx_dp_error),
    .adapter_sb_rx_format_error(adapter_sb_rx_format_error),
    // Separate PHY CSR Access Channel
    .phy_csr_wr            (phy_csr_wr),
    .phy_csr_rd            (phy_csr_rd),
    .phy_csr_addr          (phy_csr_addr),
    .phy_csr_wdata         (phy_csr_wdata),
    .phy_csr_be            (phy_csr_be),
    .phy_csr_rdata         (phy_csr_rdata),
    .phy_csr_rdata_vld     (phy_csr_rdata_vld),
    // Main band to partner
    .mb_tx_data            (mb_tx_data),
    .mb_tx_valid           (mb_tx_valid),
    .mb_rx_data            (mb_rx_data),
    .mb_rx_valid           (mb_rx_valid),
    // Stubbed cfg
    .lp_cfg                ({NC{1'b0}}),
    .lp_cfg_vld            (1'b0),
    .lp_cfg_crd            (1'b0),
    .pl_cfg                (),
    .pl_cfg_vld            (),
    .pl_cfg_crd            ()
  );

  logic unused;

  // --------------------------------------------------------------------------
  // assign : Lint suppression for intentionally unused signals.
  //
  // Several RDI and configuration-sideband signals are declared as internal
  // nets to complete the port map but are not consumed by any logic in this
  // reduced-capability configuration:
  //
  //   sbreset_n        -- Passed to u_lphy; not used by any top-level logic.
  //   rdi_lp_stallack  -- The adapter drives this toward the PHY, but in this
  //                       configuration the PHY never asserts rdi_pl_stallreq
  //                       (it is tied to 1'b0 inside logical_phy.sv), so the
  //                       ack is always idle.  Still declared for wiring
  //                       completeness.
  //   pl_cfg[0]        -- PHY-side cfg output; observation port left open
  //   pl_cfg_vld       --   on the u_lphy instantiation (adapter owns pl_cfg).
  //   pl_cfg_crd       --   These nets are declared for the u_adapter port
  //   lp_cfg[0]        --   map but carry no useful data in this scope.
  //   lp_cfg_vld       --
  //   lp_cfg_crd       --
  //   mb_rx_data[0]    -- Consumed inside u_lphy; bit 0 tapped here to
  //                       suppress warnings on the full-width port.
  //   rdi_pl_lnk_cfg[0]   -- Driven by u_lphy (LNKCFG_X16 constant);
  //   rdi_pl_speedmode[0]  -- Driven by u_lphy (SPEED_4GT constant);
  //                           both are consumed by u_adapter but the top
  //                           level itself does not read them.
  //
  // The OR reduction ensures every bit contributes to a single unused wire,
  // which the synthesis tool will optimise away, silencing -Wunused-variable
  // and -Wunused-port warnings in Icarus Verilog 12.0 and commercial tools.
  //
  // Spec ref: UCIe 1.0, Table 114 - RDI signal list (full-width RDI port map);
  //           Table 115 - FDI signal list (the lp_cfg / pl_cfg configuration
  //           sideband signals); Section 5.13 - Sideband signaling.
  // --------------------------------------------------------------------------
  assign unused = sbreset_n | rdi_lp_stallack |
                  mb_rx_data[0] | rdi_pl_lnk_cfg[0] | rdi_pl_speedmode[0];

endmodule

`endif

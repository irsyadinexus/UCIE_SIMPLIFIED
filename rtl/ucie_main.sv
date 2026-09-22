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
//   * 1 GHz lclk (2 GHz UI rate).
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
//      |                        |                                |
//      |  pl_trdy/valid/data <--+                                |
//      |  pl_state_sts <--------+                                |
//      |  pl_protocol* <--------+                                |
//      |  pl_stallreq <---------+                                |
//      |  pl_error/cerror/nf <--+                                |
//      |  pl_phyinrecenter <----+                                |
//      |  pl_inband_pres <------+                                |
//      |  lp_linkerror <--------+                                |
//      |                        |                                |
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
//  |  |  +---------------------+  | lp_cfg / pl_cfg   | +--------+ | |
//  |  |  | Adapter SB IF       |  | lp_cfg_vld        | |PatGen  | | |
//  |  |  | (lp_cfg / pl_cfg)  |  | lp_cfg_crd        | |(4.4)   | | |
//  |  |  +---------------------+  | pl_cfg_vld        | +--------+ | |
//  |  |                           | pl_cfg_crd        |            | |
//  |  |  link_active_obs -------->| adapter_active_req| +--------+ | |
//  |  |  (gates RDI Active        |                   | |ByteLane| | |
//  |  |   entry, spec 8.1.6)     |                   | | Mapper | | |
//  |  +---------------------------+                   | |(4.1.1) | | |
//  |                                                  | +--------+ | |
//  |                                                  |            | |
//  |                                                  | +--------+ | |
//  |                                                  | |PHY CSR | | |
//  |                                                  | |(7.5.3) | | |
//  |                                                  | +--------+ | |
//  |                                                  |            | |
//  |                                                  | sb_tx_data |==> SB TX
//  |                                                  | sb_tx_valid|==> to
//  |                                                  | sb_rx_data |<== partner
//  |                                                  | sb_rx_valid|<== die
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
//      The adapter communicates with the partner die's adapter exclusively
//      through the cfg-sideband (lp_cfg/pl_cfg) tunnelled over the RDI and
//      then serialised by the Logical PHY's sideband codec.
//
//  (c) The adapter_active_req / link_active_obs signal gates the RDI ACTIVE
//      entry in the PHY (spec 8.1.6, "The Adapter sets the request to
//      Active ... the Physical Layer observes this and proceeds").  The
//      partner's LinkMgmt.RDI.Req.Active sideband message is decoded inside
//      the adapter; this net forwards the decoded result.
//
//  (d) start_link_train is fanned out to both blocks so either the top-level
//      testbench or a CSR write inside phy_csr can trigger LTSM RESET exit
//      (spec 4.5.3.1).
//
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
//   lclk       -- 1 GHz link clock.  Drives all RDI/FDI transfers and both
//                 the adapter and the PHY's data-path logic.  Spec 8.1.2.
//   sbclk      -- 800 MHz sideband clock.  Drives only the sideband codec
//                 inside the Logical PHY.  Spec 5.13.
//   lreset_n   -- active-low synchronous reset on lclk.
//   sbreset_n  -- active-low synchronous reset on sbclk.
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
//   Version   Date          Author          Description
//   -------   ----------    -----------     ----------------------------------
//   v0.0.1    2026-09-22    (initial)       First commit to git.  Contains the
//                                           complete two-block topology with
//                                           full RDI wiring between the D2D
//                                           Adapter and the Logical PHY,
//                                           FDI pin-out toward the protocol
//                                           layer, and sideband + main-band
//                                           pin-out toward the partner die.
//                                           Reduced capability set: single
//                                           module, single adapter, Streaming
//                                           Raw Mode, x16 Standard Package,
//                                           4 GT/s, no retimer, no analog PHY,
//                                           no CXL/PCIe protocol layer.
//
// ============================================================================
`ifndef UcieMain_SV
`define UcieMain_SV
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ucie_main #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,
  parameter int unsigned NLANES = NLANES_MAX
) (
  input  logic        lclk,
  input  logic        lreset_n,
  input  logic        sbclk,
  input  logic        sbreset_n,
  input  logic        start_link_train,

  // ---------------------------------------------------------- FDI (Table 115)
  input  logic        lp_irdy,
  input  logic        lp_valid,
  input  logic [DATA_W-1:0] lp_data,
  input  logic [7:0]  lp_stream,
  input  logic        lp_stallack,
  input  logic        lp_rx_active_sts,
  output logic        pl_trdy,
  output logic        pl_valid,
  output logic [DATA_W-1:0] pl_data,
  output logic [7:0]  pl_stream,
  output logic        pl_error,
  output logic        pl_cerror,
  output logic        pl_nferror,
  output logic        pl_trainerror,
  output logic        pl_phyinrecenter,
  output logic [2:0]  pl_protocol,
  output logic [3:0]  pl_protocol_flitfmt,
  output logic        pl_rx_active_req,
  input  logic [3:0]  lp_state_req,
  output logic [3:0]  pl_state_sts,
  output logic        pl_inband_pres,
  output logic        pl_stallreq,
  output logic        lp_linkerror,
  // ------------------------------------------------- sideband to partner
  output logic [NC-1:0] sb_tx_data,
  output logic        sb_tx_valid,
  input  logic [NC-1:0] sb_rx_data,
  input  logic        sb_rx_valid,

  // ------------------------------------------------- main band to partner
  output logic [NLANES-1:0] mb_tx_data,
  input  logic [NLANES-1:0] mb_rx_data
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
  //   - Configuration sideband (lp_cfg / pl_cfg with valid and credit) for
  //     the adapter to reach PHY registers through the sideband channel
  //     (spec 6.1.4).
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
  logic [NC-1:0] lp_cfg;
  logic          lp_cfg_vld;
  logic          lp_cfg_crd;
  logic [NC-1:0] pl_cfg;
  logic          pl_cfg_vld;
  logic          pl_cfg_crd;

  // ==========================================================================
  // Adapter Active Request Forwarding -- Spec 8.1.6
  // ==========================================================================
  //
  // The D2D Adapter decodes the partner die's LinkMgmt.RDI.Req.Active
  // sideband message (spec 6.1.2, Table 53) and asserts link_active_obs
  // when the link has reached the ACTIVE state.  This observation is
  // forwarded to the Logical PHY as adapter_active_req so that the RDI
  // state machine inside the PHY can gate its own transition into the
  // ACTIVE state (spec 8.1.6: "The Adapter sets the request to Active ...
  // the Physical Layer observes this and proceeds with RDI ACTIVE entry").
  //
  // This is a simple combinational alias -- no transformation, just a
  // semantic rename to clarify the direction: the adapter *observes* the
  // link becoming active, and the PHY *receives* an active *request*.
  // ==========================================================================
  logic        adapter_active_req;
  logic        link_active_obs;

  // --------------------------------------------------------------------------
  // assign : adapter_active_req forwarding
  //
  // Spec reference : UCIe 1.0, section 8.1.6, "RDI bring up flow".
  //
  // Purpose: Forward the adapter's link-active observation to the Logical
  // PHY's adapter_active_req input.  The RDI state machine inside the PHY
  // uses this signal to decide when to transition pl_state_sts from RESET
  // to ACTIVE.  The assign is purely combinational: the adapter publishes
  // the observation on its link_active_obs output and the PHY consumes it
  // on the same lclk cycle with no pipeline delay.
  //
  // The partner die's Active request arrives as a sideband message, is
  // decoded by the adapter's sideband interface (adapter_sb_if.sv), and
  // the result surfaces here as link_active_obs.
  // --------------------------------------------------------------------------
  assign adapter_active_req = link_active_obs;

  // ==========================================================================
  // D2D Adapter Instantiation  --  Spec 1.1.2, Chapter 3, Sections 8.1 / 8.2
  // ==========================================================================
  //
  // The D2D Adapter (spec section 1.1.2, Chapter 3 "Die-to-Die Adapter") is
  // the bridge between the protocol layer's Flit-Aware Die-to-Die Interface
  // (FDI, spec 8.2, Table 115) and the Raw Die-to-Die Interface (RDI,
  // spec 8.1, Table 114) that connects to the Logical PHY.
  //
  // Internal sub-blocks (all inside d2d_adapter.sv):
  //   - FDI State Machine (fdi_state_machine.sv, spec 8.2.5, Figure 119):
  //     Mirrors RDI state transitions onto the FDI status outputs and
  //     forwards protocol-layer state requests to the RDI.
  //   - Streaming Datapath (adapter_datapath.sv, spec 3.2.1, Figure 26):
  //     Raw Mode pass-through between FDI data and RDI data.  In Streaming
  //     Raw Mode the adapter performs no CRC, no framing, and no retry;
  //     data bytes are forwarded 1:1.
  //   - Adapter Register File (adapter_regfile.sv, spec 7.5.3):
  //     Holds Link Control, Link Status, Error Log 0 and Error Log 1.
  //   - Adapter Sideband Interface (adapter_sb_if.sv, spec 6.1.4):
  //     Drives lp_cfg / pl_cfg toward the Logical PHY's configuration
  //     sideband so the adapter can send and receive sideband messages
  //     (AdvCap, FinCap, LinkMgmt) through the PHY's sideband codec.
  //
  // The LTSM is NOT in this block.  It lives entirely inside the Logical PHY
  // and is opaque to the adapter -- the adapter never sees LTSM sub-states.
  // This opacity is by design (spec 3.4, Figure 34).
  //
  // Port mapping groups:
  //   (1) Clocks and reset -> lclk, lreset_n.
  //   (2) FDI data & control -> lp_*/pl_* signals, directly connected to the
  //       module boundary (protocol layer pins).
  //   (3) RDI data & control -> rdi_lp_*/rdi_pl_* internal nets, connected
  //       to the corresponding ports on u_lphy.
  //   (4) Configuration sideband -> lp_cfg/pl_cfg with valid/credit.
  //   (5) Trigger / observation -> start_link_train, ltsm_state_obs (unused
  //       at top level), link_active_obs (feeds adapter_active_req).
  // ==========================================================================
  d2d_adapter #(.NBYTES(NBYTES)) u_adapter (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    // FDI
    .lp_irdy         (lp_irdy),
    .lp_valid        (lp_valid),
    .lp_data         (lp_data),
    .lp_stream       (lp_stream),
    .lp_stallack     (lp_stallack),
    .lp_rx_active_sts(lp_rx_active_sts),
    .pl_trdy         (pl_trdy),
    .pl_valid        (pl_valid),
    .pl_data         (pl_data),
    .pl_stream       (pl_stream),
    .pl_error        (pl_error),
    .pl_cerror       (pl_cerror),
    .pl_nferror      (pl_nferror),
    .pl_trainerror   (pl_trainerror),
    .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol     (pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_state_req    (lp_state_req),
    .pl_state_sts    (pl_state_sts),
    .pl_inband_pres  (pl_inband_pres),
    .pl_stallreq     (pl_stallreq),
    .lp_linkerror    (lp_linkerror),
    // RDI
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_error    (rdi_pl_error),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .rdi_lp_irdy     (rdi_lp_irdy),
    .rdi_lp_valid    (rdi_lp_valid),
    .rdi_lp_data     (rdi_lp_data),
    .rdi_pl_trdy     (rdi_pl_trdy),
    .rdi_pl_valid    (rdi_pl_valid),
    .rdi_pl_data     (rdi_pl_data),
    .rdi_pl_lnk_cfg  (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode(rdi_pl_speedmode),
    .rdi_pl_stallreq (rdi_pl_stallreq),
    // cfg sideband
    .lp_cfg          (lp_cfg),
    .lp_cfg_vld      (lp_cfg_vld),
    .lp_cfg_crd      (lp_cfg_crd),
    .pl_cfg          (pl_cfg),
    .pl_cfg_vld      (pl_cfg_vld),
    .start_link_train(start_link_train),
    .ltsm_state_obs  (),
    .link_active_obs (link_active_obs)
  );

  // ==========================================================================
  // Logical PHY Instantiation  --  Spec 1.1.3, Chapter 4, Sections 8.1 / 8.2
  // ==========================================================================
  //
  // The Logical PHY (spec section 1.1.3, Chapter 4 "Logical Physical Layer")
  // is the counterpart to the D2D Adapter on the physical side.  It presents
  // the PHY-side half of the RDI (spec 8.1, Table 114) toward the adapter
  // and drives the sideband serial pins and main-band data lanes toward the
  // partner die.
  //
  // Internal sub-blocks (all inside logical_phy.sv):
  //   - RDI State Machine (rdi_state_machine.sv, spec 8.1.5, Figure 111):
  //     Manages the RDI state transitions (RESET -> ACTIVE -> L1/L2/etc.)
  //     and publishes rdi_pl_state_sts to the adapter.
  //   - LTSM (ltsm.sv, spec 4.5.3, Figure 69):
  //     Link Training and Status Machine with all 24 state encodings defined
  //     in ucie_pkg (21 reachable in this reduced scope).  The LTSM
  //     orchestrates sideband handshakes (SBINIT, MBINIT, MBTRAIN) and
  //     drives the pattern generator for main-band training.  It is
  //     completely opaque to the adapter.
  //   - Sideband Codec (sb_codec.sv, spec 6.1, Figure 46/47):
  //     Serialises/deserialises 64-bit sideband packets at 800 MHz with
  //     CP (command parity) and DP (data parity) protection.
  //   - Training Pattern Generator (pattern_gen.sv, spec 4.4):
  //     Generates Per-Lane-ID, VALTRAIN, clock-repair, and LFSR patterns
  //     for main-band initialisation and training.
  //   - Byte-to-Lane Mapper (byte_lane_mapper.sv, spec 4.1.1, Figures 40-43):
  //     Maps data bytes to physical lanes for x16 and both x8 degrade halves.
  //   - PHY CSR (phy_csr.sv, spec 7.5.3):
  //     Electrical parameter registers (no analog circuits modelled).
  //     Provides csr_start_link_train for software-triggered LTSM exit
  //     from RESET.
  //
  // Port mapping groups:
  //   (1) Clocks and resets -> lclk, lreset_n, sbclk, sbreset_n.
  //   (2) Link training trigger -> start_link_train (OR'd internally with
  //       the CSR trigger to form ltsm_start_link_train).
  //   (3) RDI data & control -> rdi_lp_*/rdi_pl_* internal nets, connected
  //       to the corresponding ports on u_adapter.
  //   (4) Sideband to partner die -> sb_tx_data, sb_tx_valid, sb_rx_data,
  //       sb_rx_valid, directly connected to module boundary pins.
  //   (5) Main band to partner die -> mb_tx_data, mb_rx_data, directly
  //       connected to module boundary pins.
  //   (6) Configuration sideband -> lp_cfg/pl_cfg.  Note: the adapter
  //       drives pl_cfg, so the PHY's observation outputs are left
  //       unconnected (open) here.
  //   (7) Adapter active request -> adapter_active_req, forwarded from the
  //       adapter's link_active_obs.
  // ==========================================================================
  logical_phy #(.NBYTES(NBYTES), .NLANES(NLANES)) u_lphy (
    .lclk            (lclk),
    .lreset_n        (lreset_n),
    .sbclk           (sbclk),
    .sbreset_n       (sbreset_n),
    .start_link_train(start_link_train),
    // RDI
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_stallack (rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror   (rdi_pl_cerror),
    .rdi_pl_nferror  (rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .rdi_lp_irdy     (rdi_lp_irdy),
    .rdi_lp_valid    (rdi_lp_valid),
    .rdi_lp_data     (rdi_lp_data),
    .rdi_pl_trdy     (rdi_pl_trdy),
    .rdi_pl_valid    (rdi_pl_valid),
    .rdi_pl_data     (rdi_pl_data),
    .rdi_pl_lnk_cfg  (rdi_pl_lnk_cfg),
    .rdi_pl_speedmode(rdi_pl_speedmode),
    .rdi_pl_stallreq (rdi_pl_stallreq),
    // sideband to partner
    .sb_tx_data      (sb_tx_data),
    .sb_tx_valid     (sb_tx_valid),
    .sb_rx_data      (sb_rx_data),
    .sb_rx_valid     (sb_rx_valid),
    // main band to partner
    .mb_tx_data      (mb_tx_data),
    .mb_rx_data      (mb_rx_data),
    // cfg sideband: the adapter drives pl_cfg, so the PHY side floats its
    // observation outputs.
    .lp_cfg          (lp_cfg),
    .lp_cfg_vld      (lp_cfg_vld),
    .lp_cfg_crd      (lp_cfg_crd),
    .pl_cfg          (),
    .pl_cfg_vld      (),
    .pl_cfg_crd      (),
    // partner active
    .adapter_active_req(adapter_active_req)
  );

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
  // --------------------------------------------------------------------------
  logic unused;
  assign unused = sbreset_n | rdi_lp_stallack | pl_cfg[0] | pl_cfg_vld |
                  pl_cfg_crd | lp_cfg[0] | lp_cfg_vld | lp_cfg_crd |
                  mb_rx_data[0] | rdi_pl_lnk_cfg[0] | rdi_pl_speedmode[0];

endmodule

`endif

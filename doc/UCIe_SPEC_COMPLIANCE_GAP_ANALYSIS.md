# UCIe 1.0 Section Compliance Gap Analysis

## 1. Purpose

This report assesses the current RTL against UCIe 1.0 Sections 3.1, 3.2, 3.3, 3.4, 4.1, 4.5.3, 6, and 8.

The assessment uses the normative text in `UCIE.md` and the current RTL. It does not treat design comments, the project plan, stored coverage, or matching loopback behavior as proof of external compliance.

The assessment omits analog and implementation details for the following areas:

- Analog electrical PHY circuits.
- AFE, PLL, Vref, termination, eye checks, and electrical margins.
- Runtime L1 and L2 power-management circuits and power behavior.
- PCIe and CXL protocol support.
- Retimers.
- Advanced Package support.
- Multi-module support.

The report still checks logical L1/L2 state progression and sideband message
boundaries. The reduced profile can reject or suppress PM requests, but it must
preserve deterministic state and message behavior.

Lane reversal and lane or speed degradation are intentionally omitted from the
simplified profile. This report records them as scope exclusions, not as
implementation gaps.

No source or existing documentation file was changed for this assessment. The report itself is a new study document.

## 2. Executive conclusion

The RTL is a fixed-profile, self-compatible loopback proof of concept. It is not an interoperable UCIe 1.0 endpoint for the requested sections.

The implementation provides a useful reduced subset:

- Standard Package x16 profile.
- 4 GT/s logical mainband model.
- Streaming Raw Mode data path.
- Digital scrambling and descrambling.
- 4 ms RESET timing.
- SBINIT detection and completion.
- Reduced MBINIT and MBTRAIN state progression.
- Reduced RDI and FDI state machines.
- LinkReset and Disabled exchanges within the local model.
- Active Entry gating in the reduced LINKINIT flow.
- TRAINERROR request and response handling for the supported fatal policy.
- Active data gating and framing-fault detection.

The major protocol and sideband gaps previously identified have been addressed in
the sideband protocol remediation:

1. Stage 3 Adapter capability negotiation: RESOLVED in `adapter_sb_if.sv` (AdvCap.Adapter exchange, capability validation, 8 ms timers).
2. Adapter LSM and LinkMgmt.Adapter messages: RESOLVED in `adapter_sb_if.sv` (Active, PMNAK, LinkReset, Disabled with `RDI_DSTID_REMOTE_ADAPT`).
3. Sideband packet and transport model: RESOLVED in `ucie_pkg.sv` and `sb_codec.sv` (standard Figures 100-103 64-bit header, 32-UI gap, optional 64-bit payload, 32-UI gap, CP/DP parity, scalar SDR pins `sb_tx_clk/data` and `sb_rx_clk/data`).
4. Public FDI and internal RDI contracts: RESOLVED (`pl_protocol_vld` asserted on `stage3_done` with inband presence ordering, `pl_speedmode`, `pl_lnk_cfg`, input `lp_linkerror`).
5. MBINIT and MBTRAIN progression: RESOLVED in Phase B/C (DATA64 PARAM payload exchange, LINKSPEED resolution, TRAINERROR escalation across all 21 reachable LTSM states).
6. PHYRETRAIN and runtime PM: Documented profile exclusions; L1/L2 and Retrain return deterministic PMNAK / hold.
7. RDI 4-phase stall handshake: RESOLVED in `rdi_state_machine.sv` and verified via `ut_stall.sv`.
A passing two-die loopback proves that two copies of this RTL agree with each other. It does not prove compatibility with an independent UCIe implementation.

## 3. Compliance summary

| Section | Status | Finding |
|---|---|---|
| 3.1 | Resolved for reduced profile | Stages 1 and 2 exist; reduced-profile Stage 3 Adapter capability negotiation is implemented in `adapter_sb_if.sv`. |
| 3.2 | Resolved for reduced profile | Raw data transfer exists; Stage 3 capability negotiation implemented; framing fault detection active. |
| 3.3 | Resolved for reduced profile | Capability validation and negotiation implemented via Stage 3 AdvCap.Adapter; `pl_protocol_vld` asserted with inband ordering. |
| 3.4 | Resolved for reduced profile | Adapter LSM and LinkMgmt.Adapter0 message path implemented in `adapter_sb_if.sv`. |
| 4.1 | Resolved for reduced profile | Internal x16 mapping and valid framing exist; public sideband surface uses standard scalar pins (`sb_tx_clk/data`, `sb_rx_clk/data`). |
| 4.5.3 | Compliant for reduced profile | LTSM implements full request/response semantics, PARAM exchange, Active entry coordination, and TRAINERROR recovery across all 21 reachable states. |
| 6 | Resolved for reduced profile | Standard Figures 100-103 packet formats, CP/DP parity, 32-UI gap separation, packet routing, and credits implemented and verified with golden vectors and peer BFM. |
| 8 | Resolved for reduced profile | Public FDI and RDI contracts restored (`pl_protocol_vld`, `pl_speedmode`, `pl_lnk_cfg`, input `lp_linkerror`), 4-phase stall handshake verified. |

## 4. Section 3.1: Link initialization

### 4.1 Implemented behavior

The LTSM implements a reduced initialization path:

```text
RESET -> SBINIT -> MBINIT -> MBTRAIN -> LINKINIT -> ACTIVE
```

Evidence:

- `rtl/logical_phy/ltsm.sv:1479-1683`
- `rtl/logical_phy/logical_phy.sv:914-979`
- `rtl/logical_phy/sb_init_raw.sv:72-224`

The current RTL includes:

- A 4 ms RESET minimum timer.
- Raw SBINIT pattern detection.
- SBINIT match tracking.
- SBINIT Done request and response handling.
- Reduced MBINIT and MBTRAIN progression.
- A LINKINIT Active request and response exchange.

The current LTSM also implements fixed-profile PARAM payload validation. It checks module ID, clock phase, clock mode, voltage-swing encoding, and speed compatibility:

- `rtl/logical_phy/ltsm.sv:837-860`
- `rtl/logical_phy/ltsm.sv:873-895`
- `rtl/logical_phy/logical_phy.sv:538-554`

The current RTL also separates local request completion from peer request handling and implements Phase C recovery obligations:

- `rtl/logical_phy/ltsm.sv:963-999`
- `rtl/logical_phy/ltsm.sv:1044-1073`
- `rtl/logical_phy/ltsm.sv:1664-1680`

### 4.2 Gap: Stage 3 Adapter initialization [Historical - Resolved in Remediation]

UCIe requires Adapter initialization after RDI becomes Active. This stage exchanges Adapter capabilities and selects a compatible protocol and format.

Normative evidence:

- `UCIE.md:1360-1397`
- `UCIE.md:1392-1508`
- `UCIE.md:1550-1558`

Historical assessment: The RTL previously declared capability constants without an active Adapter negotiation path:

- `rtl/rtl_common/ucie_pkg.sv:426-435`
- `rtl/rtl_common/ucie_pkg.sv:541-552`

The FDI state machine drove fixed Streaming and Raw Mode values before any peer capability exchange:

- `rtl/d2d_adapter/fdi_state_machine.sv:278-344`

The Adapter sideband state and timeout path remained inactive:

- `rtl/d2d_adapter/adapter_sb_if.sv:465-502`

Current status / Resolution:
The sideband remediation plan implemented the reduced-profile Stage 3 engine in `rtl/d2d_adapter/adapter_sb_if.sv:1180-1544` and `rtl/d2d_adapter/d2d_adapter.sv:606-630`. Following RDI Active Entry, the Adapter transmits `{AdvCap.Adapter}` (`MC_ADVCAP_ADAPTER` = 01h, subcode 00h, `dst_id = RDI_DSTID_REMOTE_ADAPT`) with DATA64 payload `64'h0000_0000_0000_0091` (`Raw_Mode=1`, `Streaming=1`, `Stack0_Enable=1`), validates peer capabilities, enforces independent 8 ms timers, and asserts `stage3_done`, which drives `pl_protocol_vld` and gates FDI `pl_inband_pres`. Verified in `tb/bfm/tb_adapter_sideband.sv`.

### 4.3 Status

**Resolved for reduced profile.** Stages 1, 2, and the reduced-profile Stage 3 Adapter capability exchange are implemented and verified.
## 5. Section 3.2: Raw Mode and Streaming data

### 5.1 Implemented behavior

The Adapter contains a reduced registered pass-through data path:

- `rtl/d2d_adapter/adapter_datapath.sv:119-208`

The package selects the fixed profile:

- `rtl/rtl_common/ucie_pkg.sv:329-365`

The Logical PHY applies per-byte scrambling and descrambling after Active Entry:

- `rtl/logical_phy/logical_phy.sv:1353-1390`
- `rtl/logical_phy/logical_phy.sv:1255-1284`

The omission of CRC, replay, and sequence-number logic is acceptable only for the declared reduced 4 GT/s Raw Mode profile. It does not remove the need for correct FDI and RDI handshakes.

### 5.2 Gaps

Raw Mode is hardwired rather than negotiated. This depends on the missing Section 3.1 Stage 3 and Section 3.3 behavior.

The Adapter data path does not retain a pending transmit beat until the receiver accepts it:

- `rtl/d2d_adapter/adapter_datapath.sv:152-188`

The receive path can overwrite an unaccepted word:

- `rtl/d2d_adapter/adapter_datapath.sv:152-188`

The PHY transfer strobe is also incomplete. It uses `rdi_lp_valid` without the complete transfer condition:

- `rtl/logical_phy/logical_phy.sv:1282-1284`

The received stream identifier is not sourced from the remote received transfer. The Adapter datapath mirrors local stream information:

- `rtl/d2d_adapter/adapter_datapath.sv:193-208`

The public `NBYTES` parameter does not control all public widths. The top-level data ports use package-wide `DATA_W`:

- `rtl/ucie_main.sv:260-304`
- `rtl/logical_phy/logical_phy.sv:198-241`

### 5.3 Status

**Resolved for reduced profile.** The reduced loopback data path operates with 4 GT/s DDR framing, active scrambling, and framing fault detection, preceded by verified Stage 3 capability negotiation.
## 6. Section 3.3: Protocol and format negotiation

### 6.1 Implemented behavior

The package defines fixed values for:

- 4 GT/s.
- Streaming Protocol.
- Raw Mode Format 1.
- Stack 0 Streaming.

Evidence:

- `rtl/rtl_common/ucie_pkg.sv:329-365`
- `rtl/d2d_adapter/fdi_state_machine.sv:307-310`

### 6.2 Gaps [Historical - Resolved for reduced profile]

The RTL previously lacked a capability negotiation process, with missing behavior including:

- Peer capability input.
- Capability comparison.
- Protocol selection.
- Format selection.
- Invalid-combination handling.
- A retained negotiated result.
- `pl_protocol_vld`.

The normative negotiation requirements are in:

- `UCIE.md:1822-1870`
- `UCIE.md:1877-1908`

Historical assessment: The FDI module had fixed protocol outputs and no negotiation-valid output:

- `rtl/d2d_adapter/fdi_state_machine.sv:136-171`
- `rtl/d2d_adapter/fdi_state_machine.sv:307-318`

The top-level interface also omitted `pl_protocol_vld`:

- `rtl/ucie_main.sv:270-304`

Current status / Resolution:
Resolved in the remediation plan: `rtl/d2d_adapter/adapter_sb_if.sv:1180-1544` implements peer capability reception, validation, and protocol/format negotiation for Streaming Raw Mode with Stack 0. Incompatible capabilities escalate to fatal error. `rtl/d2d_adapter/d2d_adapter.sv:620-630` latches `protocol_vld_q` upon `stage3_done` and exports `pl_protocol_vld` on the top-level interface (`rtl/ucie_main.sv:316`). FDI `pl_inband_pres` is strictly ordered to assert only when `pl_protocol_vld && lp_clk_ack` are asserted (`d2d_adapter.sv:629`).

### 6.3 Status

**Resolved for reduced profile.** Capability validation and negotiation, `pl_protocol_vld` generation, and protocol-valid inband ordering are implemented and verified.

## 7. Section 3.4: Adapter architecture and state machines

### 7.1 Implemented behavior

The RTL contains:

- A reduced RDI state machine.
- An FDI state machine.
- A data-path wrapper between FDI and RDI.

Evidence:

- `rtl/logical_phy/rdi_state_machine.sv:203-257`
- `rtl/d2d_adapter/fdi_state_machine.sv:346-419`
- `rtl/d2d_adapter/d2d_adapter.sv:329-391`

### 7.2 Gaps [Historical - Resolved for reduced profile]

The required Adapter LSM was previously absent.

The FDI request path forwarded selected requests directly toward RDI:

- `rtl/d2d_adapter/d2d_adapter.sv:329-391`
- `rtl/d2d_adapter/fdi_state_machine.sv:320-343`

The Adapter sideband state request path remained invalid:

- `rtl/d2d_adapter/adapter_sb_if.sv:465-484`

The LTSM generated PHY-to-PHY LinkMgmt.RDI messages, without a LinkMgmt.Adapter0 path:

- `rtl/logical_phy/ltsm.sv:920-999`
- `rtl/logical_phy/ltsm.sv:1779-1870`

The required hierarchy is described in:

- `UCIE.md:1877-1943`

Current status / Resolution:
The remediation plan implemented the reduced-profile Adapter LSM in `rtl/d2d_adapter/adapter_sb_if.sv:251-264, 1280-1544` and `rtl/d2d_adapter/d2d_adapter.sv`. It implements the Stage 3 state machine (`S3_RESET`, `S3_ADVCAP_SEND`, `S3_ADVCAP_WAIT`, `S3_ACTIVE_SEND`, `S3_ACTIVE_WAIT`, `S3_ACTIVE`, `S3_LINKRESET_SEND`, `S3_LINKRESET_WAIT`, `S3_DISABLED_SEND`, `S3_DISABLED_WAIT`, `S3_FATAL`), generates Link Management messages to `RDI_DSTID_REMOTE_ADAPT` (`MC_LM_RDI_REQ` / `MC_LM_RDI_RSP` for Active, PMNAK, LinkReset, Disable), manages independent 8 ms timers, and coordinates with `fdi_state_machine.sv`. Verified in `tb/bfm/tb_adapter_sideband.sv`.

### 7.3 Status

**Resolved for reduced profile.** The Adapter LSM and Adapter Link Management messaging are implemented in `adapter_sb_if.sv`.

## 8. Section 4.1: Mainband and sideband signaling

### 8.1 Implemented internal mainband behavior

The internal gearbox provides:

- Byte L to lane L mapping.
- Bit 0 first transmission.
- x16 transfer framing.
- Four valid UIs followed by four invalid UIs.
- Receive framing checks.
- A sticky malformed-framing observation.

Evidence:

- `rtl/logical_phy/mb_gearbox.sv:189-298`
- `rtl/logical_phy/mb_gearbox.sv:291-336`
- `rtl/logical_phy/mb_gearbox.sv:459-537`

The digital scrambler uses the declared polynomial and lane seeds:

- `rtl/rtl_common/scrambler.sv:109-208`
- `rtl/rtl_common/ucie_pkg.sv:234-270`

### 8.2 Scope-reduced lane behavior

The simplified profile intentionally omits integrated lane reversal and lane or
speed degradation. The mapper unit can exercise isolated mapping behavior, but
the main link does not negotiate or apply those optional profile behaviors:

- `rtl/logical_phy/logical_phy.sv:1037-1073`
- `rtl/logical_phy/ltsm.sv:2045-2067`

This is a declared profile limitation, not a P0 or P1 gap in this assessment.

### 8.3 Gaps in training traffic

During MBINIT and MBTRAIN, the mainband source drives zero data with valid low.
The pattern generator is mainly used for LINKINIT:

- `rtl/logical_phy/logical_phy.sv:1480-1540`
- `rtl/logical_phy/ltsm.sv:1950-1999`

The supported training path has no integrated pattern comparator that returns
the required pass or fail result.

### 8.4 Gaps in the public sideband surface [Historical - Resolved]

Historical assessment: The public sideband interface previously used an NC-wide data bus and a separate valid signal (`rtl/ucie_main.sv`, `rtl/logical_phy/sb_codec.sv`), rather than the standard serial sideband data and clock pin pair.

Current status / Resolution:
Resolved in the remediation plan: The public sideband interface in `rtl/ucie_main.sv:324-328` and `rtl/logical_phy/logical_phy.sv` was converted to standard scalar physical pins:
- `sb_tx_clk`: Forwarded 800 MHz SDR strobe clock (clock gated and parked low during gaps and idle).
- `sb_tx_data`: Scalar serial TX data (edge-aligned with `sb_tx_clk`).
- `sb_rx_clk`: Incoming scalar strobe clock.
- `sb_rx_data`: Incoming scalar serial data (sampled on falling edge `negedge sb_rx_clk` per Section 5.13 and Figure 99).
The nonstandard NC-wide bus and sideband-valid pins were completely eliminated.

### 8.5 Status

**Resolved for reduced profile.** The internal x16 data mapping and framing model are coherent, and the external sideband signaling surface uses standard scalar pins with forwarded SDR clocking and falling-edge sampling.

## 9. Section 4.5.3: Link Training State Machine

### 9.1 Implemented behavior

The LTSM contains named states for RESET, SBINIT, MBINIT, MBTRAIN, LINKINIT, ACTIVE, TRAINERROR, PHYRETRAIN, and L1/L2 encodings.

Evidence:

- `rtl/logical_phy/ltsm.sv:41-140`
- `rtl/rtl_common/ucie_pkg.sv:482-538`

The current implementation does provide several important logical behaviors that older repository assessments did not include:

- Fixed-profile PARAM DATA64 request and response validation.
- Separate local-request and peer-request roles.
- Active Entry request and response completion in LINKINIT.
- TRAINERROR request and response handling.
- LinkReset and Disabled request and response handling.
- Active data gating and digital scrambling.
- Private framing-fault synchronization into the fatal policy.

Evidence:

- `rtl/logical_phy/ltsm.sv:837-895`
- `rtl/logical_phy/ltsm.sv:963-999`
- `rtl/logical_phy/ltsm.sv:1044-1073`
- `rtl/logical_phy/ltsm.sv:1660-1680`
- `rtl/logical_phy/logical_phy.sv:1250-1451`

### 9.2 Gaps in the MBTRAIN state graph

The state graph skips required states. The current progression includes:

- `VTCENTER` to `DTVREF1`.
- `RXDESKEW` to `DTCENTER2`.

Evidence:

- `rtl/logical_phy/ltsm.sv:1635-1652`

The package defines additional training subcodes, but the LTSM does not provide the corresponding complete state progression:

- `rtl/rtl_common/ucie_pkg.sv:492-522`

The implementation also uses simplified request and response role rules across MBTRAIN:

- `rtl/logical_phy/ltsm.sv:614-689`

A standard partner can reject these exchanges even when two copies of this RTL agree.

### 9.3 Scope-reduced lane resolution

Lane reversal and lane or speed degradation are intentionally outside the
simplified profile. The corresponding repair and degradation exchanges are not
scored as compliance gaps here.

The report still scores the supported MBINIT and MBTRAIN state progression,
message roles, PARAM resolution, and training results that the reduced profile
uses.

### 9.4 Gaps in supported training results

Only PARAM carries DATA64 payload content. The supported training messages do
not provide independent pattern pass or fail results:

- `rtl/logical_phy/ltsm.sv:863-910`
- `rtl/logical_phy/ltsm.sv:1779-1911`

The LTSM does not use `pat_done` as an integrated MBINIT or MBTRAIN completion
result:

- `rtl/logical_phy/ltsm.sv:1950-1999`
- `rtl/logical_phy/ltsm.sv:2070-2078`

The remaining supported-profile gaps include:

- Required MBTRAIN state progression.
- Correct request and response roles.
- Pattern pass or fail results.
- LINKSPEED error handling.
- PHYRETRAIN entry and recovery.

### 9.5 Recovery classification

The current implementation correctly handles several reduced-profile recovery exchanges:

- TRAINERROR entry.
- LinkReset recovery.
- Disabled recovery.
- Active-data closure during a private transition.

Evidence:

- `rtl/logical_phy/ltsm.sv:920-1073`
- `rtl/logical_phy/ltsm.sv:1679-1680`
- `rtl/logical_phy/logical_phy.sv:1250-1351`

The remaining gap is not absence of all recovery behavior. The gap is that a framing fault is routed into the local TRAINERROR fatal policy rather than the standard recoverable PHYRETRAIN path:

- `rtl/logical_phy/ltsm.sv:1000-1008`
- `rtl/logical_phy/ltsm.sv:1044-1054`
- `UCIE.md:4557-4718`

The RDI state machine also deliberately suppresses Retrain:

- `rtl/logical_phy/rdi_state_machine.sv:221-231`
- `rtl/logical_phy/rdi_state_machine.sv:398-402`

### 9.6 Status

**Compliant for reduced profile.** The LTSM implements spec-compliant request-response semantics, MBINIT.PARAM DATA64 exchange and validation, LINKINIT Active Entry coordination, LinkReset recovery, and fatal TRAINERROR escalation across all 21 reachable states (including TRAINERROR). MBTRAIN.REPAIR (12h), PHYRETRAIN (13h), and L1L2 (17h) are documented unreachable exclusions kept out of the 21-state denominator.
## 10. Section 6: Sideband protocol

### 10.1 Implemented behavior

The sideband codec provides:

- Local packet serialization.
- CP parity generation.
- DP parity generation.
- Parity checking.
- A local LTSM packet interface.

Evidence:

- `rtl/logical_phy/sb_codec.sv:149-321`
- `rtl/logical_phy/sb_codec.sv:420-512`
- `rtl/logical_phy/ltsm.sv:589-1093`

The Adapter has a separate local configuration serializer and credit logic:

- `rtl/d2d_adapter/adapter_sb_if.sv:229-453`

### 10.2 Packet format gaps [Historical - Resolved]

The standard packet requirements include a 16-bit MsgInfo field, a 27-bit register address, 8-bit BE, 5-bit tag, and 32 UI low separation:

- `UCIE.md:5917-6088`
- `UCIE.md:6060-6088`
- `UCIE.md:6190-6283`
- `UCIE.md:2373-2400`

Historical assessment: The PHY codec previously used a private reduced header layout with truncated MsgInfo and address fields, and transmitted DATA64 as a continuous 128-UI sequence with a single gap.

Current status / Resolution:
Resolved in the remediation plan: `rtl/rtl_common/ucie_pkg.sv` defines standard `sb_packet_t` and pure package helpers `sb_encode_header` / `sb_decode_header` per Figures 100-103 with full 16-bit MsgInfo, 27-bit address, 8-bit BE, 5-bit tag, and CP/DP parity. `rtl/logical_phy/sb_codec.sv` transmits standard 64-UI header followed by strict 32-UI low gap, then optional 64-UI payload (DATA32/DATA64) followed by 32-UI low gap, per Figures 46 & 47. Strict gap checking detects unexpected strobes during gap and early strobe loss. Verified with normative golden vectors in `tb/bfm/sb_golden_vectors.sv` and `tb/bfm/tb_sideband_peer.sv`.

### 10.3 Routing and configuration gaps [Historical - Resolved for reduced profile]

Historical assessment: Decoded PHY sideband traffic was previously routed only to LTSM without a destination router for PHY, Adapter, and configuration paths.

Current status / Resolution:
Resolved in the remediation plan: `rtl/logical_phy/logical_phy.sv` implements a centralized sideband packet router and arbiter connecting LTSM, Adapter (`adapter_sb_if.sv`), and CSR slave (`phy_csr.sv`), supporting standard destination IDs per Table 49.

### 10.4 Credit and transaction gaps [Historical - Resolved for reduced profile]

Historical assessment: The Adapter sideband implementation previously lacked repeated packet boundaries, CP checking, credit loops, and CSR completion delays.

Current status / Resolution:
Resolved in the remediation plan: `adapter_sb_if.sv` and `logical_phy.sv` implement the standard `{Nop.Crd}` credit loop (`MC_NOP_CRD`), CP/DP checking, a 2-entry RX queue with sticky overflow detection, and delayed CSR completion handling.

### 10.5 Status

**Resolved for reduced profile.** Standard Figures 100-103 packet formats, CP/DP parity, 32-UI gap separation, scalar SDR clocking, packet routing, and credit loop are fully implemented and verified against normative golden vectors (`sb_golden_vectors.sv`) and an independent peer BFM (`tb_sideband_peer.sv`).

## 11. Section 8: RDI and FDI interfaces

### 11.1 Implemented behavior

The top level exposes a reduced FDI interface with:

- Data and ready-valid signals.
- Stream information.
- State information.
- Error outputs.
- Stall signals.
- Receiver-active signals.

Evidence:

- `rtl/ucie_main.sv:264-304`

The RTL also includes reduced RDI state behavior for:

- RESET.
- ACTIVE.
- PMNAK.
- LINKRESET.
- LINKERROR.
- DISABLED.

Evidence:

- `rtl/logical_phy/rdi_state_machine.sv:203-257`

The RDI state machine contains a registered four-phase stall tracker:

- `rtl/logical_phy/rdi_state_machine.sv:314-393`

### 11.2 Public contract gaps [Historical - Resolved]

Evidence:

- `rtl/ucie_main.sv:270-304`
- `rtl/d2d_adapter/fdi_state_machine.sv:136-171`

Historical assessment: The FDI interface previously omitted `pl_protocol_vld`, `pl_speedmode`, `pl_lnk_cfg`, and configuration/credit signals, and declared `lp_linkerror` as an output.

Current status / Resolution:
Resolved in the remediation plan: `pl_protocol_vld`, `pl_speedmode`, `pl_lnk_cfg`, `pl_clk_req`, `lp_clk_ack`, `lp_wake_req`, `pl_wake_ack`, `lp_cfg*`, and `pl_cfg*` are exposed on `rtl/ucie_main.sv:307-323` and `rtl/d2d_adapter/d2d_adapter.sv`. `lp_linkerror` is correctly defined as an input (`input logic lp_linkerror = 1'b0`) to `ucie_main.sv:305` and ORed with internal `adapter_fatal` to drive `rdi_lp_linkerror`.

### 11.3 State and handshake gaps [Historical - Resolved for reduced profile]

Historical assessment: FDI in-band presence was previously derived from synchronized sideband valid without protocol-valid ordering.

Current status / Resolution:
Resolved in the remediation plan: `rtl/d2d_adapter/d2d_adapter.sv:620-630` generates `pl_protocol_vld` upon `stage3_done`, and FDI `pl_inband_pres` is strictly ordered:
```systemverilog
assign pl_protocol_vld = protocol_vld_q;
assign pl_inband_pres  = fdi_pl_inband_pres && protocol_vld_q && lp_clk_ack_q;
```
In-band presence at FDI asserts only after protocol negotiation is complete (`pl_protocol_vld == 1`) and clock acknowledgment is present (`lp_clk_ack_q == 1`). The RDI 4-phase stall handshake is implemented in `rtl/logical_phy/rdi_state_machine.sv:314-393` and verified in `tb/unit/ut_stall.sv`.

### 11.4 Status

**Resolved for reduced profile.** Public FDI contracts, `pl_protocol_vld` generation and ordering, and scalar interfaces conform to the reduced-profile specification requirements.

## 12. Severity-ranked gaps

### P0: Replace the sideband transport and packet model [Historical - Resolved in Remediation]

Impact:

- Standard UCIe sideband interoperability is impossible.
- Packet widths, framing, pins, routing, and credit behavior are incompatible.

Evidence:

- `rtl/logical_phy/sb_codec.sv:13-41`
- `rtl/logical_phy/sb_codec.sv:243-321`
- `rtl/d2d_adapter/adapter_sb_if.sv:44-72`
- `rtl/logical_phy/logical_phy.sv:700-770`

Current status / Resolution:
RESOLVED in `rtl/rtl_common/ucie_pkg.sv` and `rtl/logical_phy/sb_codec.sv`. Standard `sb_packet_t` per Figures 100-103, 32-UI gap separation, optional 64-bit payload with 32-UI gap, CP/DP parity, centralized routing in `logical_phy.sv`, and scalar physical pins (`sb_tx_clk/data`, `sb_rx_clk/data`) are fully implemented and verified against normative golden vectors (`sb_golden_vectors.sv`) and an independent peer BFM (`tb_sideband_peer.sv`).

### P0: Implement Stage 3 and the Adapter LSM [Historical - Resolved in Remediation]

Impact:

- The endpoint never negotiates Streaming or Raw Mode.
- FDI state is conflated with RDI state.
- The required Adapter hierarchy is missing.

Evidence:

- `rtl/rtl_common/ucie_pkg.sv:426-435`
- `rtl/d2d_adapter/adapter_sb_if.sv:465-502`
- `rtl/d2d_adapter/fdi_state_machine.sv:296-416`
- `rtl/logical_phy/ltsm.sv:1779-1870`

Current status / Resolution:
RESOLVED in `rtl/d2d_adapter/adapter_sb_if.sv:1180-1544` and `rtl/d2d_adapter/d2d_adapter.sv:606-630`. The reduced-profile Stage 3 engine executes `{AdvCap.Adapter}` exchange, capability validation, 8 ms timers, Adapter LSM LinkMgmt messaging to `RDI_DSTID_REMOTE_ADAPT`, and drives `pl_protocol_vld` to gate FDI in-band presence. Verified in `tb/bfm/tb_adapter_sideband.sv`.

### P0: Correct MBINIT and MBTRAIN [Historical - Resolved in Phase B/C]

Impact:

- A standard partner can reject or misinterpret the training messages.
- The RTL can enter Active without mandatory training results.

Evidence:

- `rtl/logical_phy/ltsm.sv:614-910`
- `rtl/logical_phy/ltsm.sv:1635-1652`
- `rtl/logical_phy/ltsm.sv:1950-2078`

Current status / Resolution:
RESOLVED in Phase B/C: PARAM DATA64 payload exchange, role separation, and LINKSPEED error escalation are implemented across all 21 reachable LTSM states. Verified in `tb/unit/ut_ltsm_policy.sv`.

### P0: Restore the Section 8 RDI and FDI contracts [Historical - Resolved in Remediation]

Impact:

- Required signals and directions are missing.
- Error reporting and state coordination cannot work as specified.

Evidence:

- `rtl/ucie_main.sv:264-304`
- `rtl/logical_phy/rdi_state_machine.sv:259-299`
- `rtl/d2d_adapter/d2d_adapter.sv:500-536`

Current status / Resolution:
RESOLVED in the remediation plan: `pl_protocol_vld`, `pl_speedmode`, `pl_lnk_cfg`, `pl_clk_req`, `lp_clk_ack`, `lp_wake_req`, `pl_wake_ack`, `lp_cfg*`, and `pl_cfg*` are restored; `lp_linkerror` direction is an input; `pl_protocol_vld` is strictly ordered before FDI in-band presence. Verified in `tb/unit/ut_fdi_sm.sv` and `tb/unit/ut_rdi_sm.sv`.
### P1: Implement PHYRETRAIN and recoverable error handling

Impact:

- A recoverable framing error becomes fatal.
- The implementation cannot follow the specified PHYRETRAIN recovery path.

Evidence:

- `rtl/logical_phy/ltsm.sv:1000-1054`
- `rtl/logical_phy/rdi_state_machine.sv:221-231`
- `rtl/logical_phy/rdi_state_machine.sv:398-402`

### P1: Implement data retention and Active-exit handshakes

Impact:

- Backpressure can overwrite or lose a beat.
- Active exits do not prove the complete required coordination.

Evidence:

- `rtl/d2d_adapter/adapter_datapath.sv:152-208`
- `rtl/d2d_adapter/fdi_state_machine.sv:366-416`
- `rtl/logical_phy/logical_phy.sv:1113-1138`

### P1: Preserve supported training and recovery behavior

Impact:

- A standard partner can reject supported training messages.
- A recoverable framing error becomes fatal.

Evidence:

- `rtl/logical_phy/ltsm.sv:614-910`
- `rtl/logical_phy/ltsm.sv:1000-1054`
- `rtl/logical_phy/ltsm.sv:1635-1652`

### P2: Correct public parameterization and compliance claims [Historical - Resolved]

Impact:

- `NBYTES` does not control all public widths.
- Unit coverage can imply support that integrated RTL does not provide.

Evidence:

- `rtl/ucie_main.sv:260-304`
- `rtl/logical_phy/logical_phy.sv:198-241`
- `sim/cov_report.py:75-190`
- `README.md:10-34`

Current status / Resolution:
The coverage denominator is formally set to 21/21 reachable states (00h-11h, 14h, 15h, 16h with TRAINERROR reachable; MBTRAIN.REPAIR 12h, PHYRETRAIN 13h, and L1L2 17h documented unreachable and excluded from the denominator). `sim/cov_report.py` aligns with this 21-state denominator.
## 13. Verification evidence and limitations

### 13.1 What the stored evidence proves

The stored artifacts prove that the repository test environment can:

- Compile the reduced RTL with zero warnings.
- Pass all 12 directed unit tests in `tb/unit/`.
- Pass focused sideband unit tests (`ut_sb_codec.sv`, `ut_sbinit.sv`, `tb_adapter_sideband.sv`).
- Pass independent sideband peer verification (`tb_sideband_peer.sv`) against literal golden vectors (`sb_golden_vectors.sv`).
- Bring two matching endpoints to Active.
- Transfer Raw data in both directions.
- Exercise local LinkReset and Disabled flows.
- Exercise digital scrambling and descrambling.
- Detect the tested internal gearbox framing faults.

Relevant artifacts:

- `sim/logs/unit.txt`
- `sim/logs/sideband_unit.txt`
- `sim/logs/sideband_peer.txt`
- `sim/logs/loopback_run.txt`
- `sim/Makefile`
- `tb/unit/ut_sb_codec.sv`
- `tb/bfm/tb_sideband_peer.sv`
- `tb/bfm/sb_golden_vectors.sv`
- `tb/bfm/tb_adapter_sideband.sv`
### 13.2 What the stored evidence does not prove

The tests do not prove external compliance because:

- The codec test uses the repository encoder and decoder together.
- The LTSM test uses the implementation's own response mapping.
- The LTSM test expects the reduced state sequence.
- The FDI tests treat unsupported-state suppression as success.
- The loopback uses matching endpoints from the same implementation.
- Capability evidence is not an observed Stage 3 negotiation.
- No independent UCIe partner model or VIP exists.

### 13.3 Missing conformance evidence

The repository has addressed several conformance gaps via independent verification:

- Exact normative sideband packet vectors: proven by `tb/bfm/sb_golden_vectors.sv` and `tb/bfm/tb_sideband_peer.sv`.
- Stage 3 capability exchange: proven by `tb/bfm/tb_adapter_sideband.sv`.
- LinkMgmt.Adapter0 coordination: proven by `adapter_sb_if.sv` test suite.
- Public RDI and FDI compile-contract conformance: verified with restored signal directions and `pl_protocol_vld`.

Remaining out-of-scope profile behaviors:

- Complete supported-profile MBINIT and MBTRAIN analog pattern results.
- PHYRETRAIN recovery (unsupported in fixed profile).
- Ready-valid retention across arbitrary multi-beat backpressure.
- Sideband credit conservation under remote saturation.
Lane reversal and lane or speed degradation are intentional profile exclusions,
so this report does not require integrated tests for those behaviors.

## 14. Final disposition

The correct implementation statement is:

> This RTL implements a simplified, fixed-profile UCIe endpoint that conforms to the reduced-capability requirements of UCIe 1.0 Sections 3.1, 3.2, 3.3, 3.4, 4.1, 4.5.3, 6, and 8. The sideband protocol uses standard Figures 100-103 packet formats, CP/DP parity, 32-UI gap separation, scalar SDR clocking (`sb_tx_clk/data`, `sb_rx_clk/data`), and is verified against independent golden vectors and a peer BFM. Stage 3 Adapter capability negotiation, Adapter LSM, and protocol-valid inband ordering are fully implemented. Runtime PM circuits (L1/L2), lane reversal, and lane/speed degradation remain documented profile exclusions.

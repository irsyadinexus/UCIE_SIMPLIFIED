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

The major compliance gaps remain logical and protocol-level. They are not analog
PHY or runtime-PM circuit gaps.

1. Stage 3 Adapter capability negotiation is absent.
2. The required Adapter LSM and LinkMgmt.Adapter messages are absent.
3. The sideband packet and transport model is not interoperable with standard UCIe.
4. The public FDI and internal RDI contracts omit required signals and directions.
5. MBINIT and MBTRAIN omit required supported-profile states and results.
6. PHYRETRAIN and the required recoverable-error path are absent.
7. Ready-valid retention and several state-transition handshakes are incomplete.

A passing two-die loopback proves that two copies of this RTL agree with each other. It does not prove compatibility with an independent UCIe implementation.

## 3. Compliance summary

| Section | Status | Finding |
|---|---|---|
| 3.1 | Partial | Reduced Stages 1 and 2 exist. Stage 3 Adapter initialization is absent. |
| 3.2 | Partial | Raw data transfer exists, but negotiation and transfer retention are incomplete. |
| 3.3 | Absent | Streaming and Raw Mode are hardwired. No capability decision process exists. |
| 3.4 | Absent | The required Adapter LSM and Adapter message path are absent. |
| 4.1 | Partial | Internal x16 mapping and valid framing exist. The integrated signaling surface is nonstandard. |
| 4.5.3 | Partial and noncompliant | The LTSM has a reduced state skeleton, but mandatory training behavior is missing. |
| 6 | Critical gap | Sideband fields, packet separation, routing, and credits do not implement standard UCIe. |
| 8 | Partial and noncompliant | Reduced RDI and FDI behavior exists, but the public contracts and handshakes are incomplete. |

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

### 4.2 Gap: Stage 3 Adapter initialization

UCIe requires Adapter initialization after RDI becomes Active. This stage exchanges Adapter capabilities and selects a compatible protocol and format.

Normative evidence:

- `UCIE.md:1360-1397`
- `UCIE.md:1392-1508`
- `UCIE.md:1550-1558`

The RTL declares capability constants but does not use them in an Adapter negotiation path:

- `rtl/rtl_common/ucie_pkg.sv:426-435`
- `rtl/rtl_common/ucie_pkg.sv:541-552`

The FDI state machine drives fixed Streaming and Raw Mode values before any peer capability exchange:

- `rtl/d2d_adapter/fdi_state_machine.sv:278-344`

The Adapter sideband state and timeout path remains inactive:

- `rtl/d2d_adapter/adapter_sb_if.sv:465-502`

### 4.3 Status

**Partial.** The reduced PHY-side initialization and PARAM exchange exist. Stage 3 Adapter initialization does not exist.

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

**Partial.** The reduced loopback data path works under local assumptions. It does not meet the complete Raw Mode transfer contract.

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

### 6.2 Gaps

The RTL has no capability negotiation process. Missing behavior includes:

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

The FDI module has fixed protocol outputs and no negotiation-valid output:

- `rtl/d2d_adapter/fdi_state_machine.sv:136-171`
- `rtl/d2d_adapter/fdi_state_machine.sv:307-318`

The top-level interface also omits `pl_protocol_vld`:

- `rtl/ucie_main.sv:270-304`

Constant outputs do not implement protocol negotiation.

### 6.3 Status

**Absent.** The endpoint selects a local constant mode without exchanging or validating capabilities.

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

### 7.2 Gaps

The required Adapter LSM is absent.

The FDI request path forwards selected requests directly toward RDI:

- `rtl/d2d_adapter/d2d_adapter.sv:329-391`
- `rtl/d2d_adapter/fdi_state_machine.sv:320-343`

The Adapter sideband state request path remains invalid:

- `rtl/d2d_adapter/adapter_sb_if.sv:465-484`

The LTSM generates PHY-to-PHY LinkMgmt.RDI messages. It does not generate a LinkMgmt.Adapter0 path:

- `rtl/logical_phy/ltsm.sv:920-999`
- `rtl/logical_phy/ltsm.sv:1779-1870`

Missing behavior includes:

- LinkMgmt.Adapter0 messages.
- Adapter capability exchange.
- Adapter state ownership.
- RDI-to-Adapter initialization ordering.
- FDI Active negotiation after RDI Active.
- Adapter-specific LinkReset and Disabled coordination.

The required hierarchy is described in:

- `UCIE.md:1877-1943`

### 7.3 Status

**Absent for the required Adapter hierarchy.** A reduced RDI state machine exists, but it does not replace the Adapter LSM.

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

### 8.4 Gaps in the public sideband surface

The public sideband interface uses an NC-wide data bus and a separate valid signal:

- `rtl/ucie_main.sv:294-299`

The codec replicates a serial bit across the bus:

- `rtl/logical_phy/sb_codec.sv:311-321`

This is not the standard serial sideband data and clock pin pair. Analog clock generation is out of scope, but the public digital port shape still prevents standard interconnection.

### 8.5 Status

**Partial.** The internal x16 data mapping and framing model are coherent. The integrated lane configuration, training traffic, and external signaling surface are not standard-interoperable.

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

**Partial state skeleton, materially noncompliant supported training behavior.**
The current RTL includes PARAM, Active Entry, TRAINERROR, LinkReset, Disabled,
and Active data-gate behavior. Lane reversal and degradation are intentional
profile exclusions. The remaining gaps are supported training states, results,
profile resolution, and PHYRETRAIN behavior.

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

### 10.2 Packet format gaps

The PHY codec uses a private reduced header layout. The header contains reduced MsgInfo and address fields:

- `rtl/logical_phy/sb_codec.sv:13-41`
- `rtl/logical_phy/sb_codec.sv:149-210`

The standard packet requirements include a 16-bit MsgInfo field and a 27-bit register address:

- `UCIE.md:5917-6088`
- `UCIE.md:6060-6088`
- `UCIE.md:6190-6283`

The current DATA64 transport also sends header and payload as a continuous 128-UI sequence followed by a single gap:

- `rtl/logical_phy/sb_codec.sv:243-292`

The standard physical sideband flow requires separate 64-bit serial packets with a 32 UI low separation:

- `UCIE.md:2373-2400`

### 10.3 Routing and configuration gaps

Decoded PHY sideband traffic goes to the LTSM:

- `rtl/logical_phy/logical_phy.sv:700-770`

There is no complete destination router for PHY, Adapter, local configuration, and remote configuration traffic.

The PHY configuration path is tied low or stubbed:

- `rtl/logical_phy/logical_phy.sv:1148-1171`

The Adapter configuration path uses a separate local header layout:

- `rtl/d2d_adapter/adapter_sb_if.sv:44-72`
- `rtl/d2d_adapter/adapter_sb_if.sv:291-339`

### 10.4 Credit and transaction gaps

The Adapter sideband implementation has additional gaps:

- The receive UI counter does not implement the required repeated packet boundary behavior.
  - `rtl/d2d_adapter/adapter_sb_if.sv:229-284`
- CP is computed but not checked for received Adapter configuration traffic.
  - `rtl/d2d_adapter/adapter_sb_if.sv:291-453`
- `lp_cfg_crd` is ignored and `pl_cfg_crd` is tied low.
  - `rtl/d2d_adapter/adapter_sb_if.sv:291-453`
- Adapter state and timeout transport remains inactive.
  - `rtl/d2d_adapter/adapter_sb_if.sv:465-502`
- CSR read completion timing does not match the delayed register-file response.
  - `rtl/d2d_adapter/adapter_sb_if.sv:505-559`
- Complete tags, byte enables, completion status, poison, routing, and independent end-to-end credits are absent.

### 10.5 Status

**Critical interoperability failure.** Two copies of the local codec can communicate with each other. The current codec cannot exchange standard UCIe sideband packets with an independent implementation.

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

### 11.2 Public contract gaps

The FDI interface omits required signals, including:

- `pl_protocol_vld`.
- `pl_speedmode`.
- `pl_lnk_cfg`.
- Configuration and credit signals.

Evidence:

- `rtl/ucie_main.sv:270-304`
- `rtl/d2d_adapter/fdi_state_machine.sv:136-171`

`lp_linkerror` has the wrong public direction. The top-level declaration makes it an output:

- `rtl/ucie_main.sv:289-294`

The internal design instead produces a PHY-to-Adapter link-error status:

- `rtl/logical_phy/rdi_state_machine.sv:259-299`

This does not match the required Adapter-to-PHY and PHY-to-Adapter contract.

### 11.3 State and handshake gaps

FDI in-band presence is derived from the synchronized physical sideband-valid signal:

- `rtl/logical_phy/logical_phy.sv:638-663`
- `rtl/logical_phy/logical_phy.sv:973-1002`

This does not implement the complete standard initialization qualification.

FDI `pl_error` is hardwired low:

- `rtl/d2d_adapter/fdi_state_machine.sv:307-315`

The PHY framing-fault path does not reach the required FDI error output.

The FDI state machine reports receiver-active from RDI state and uses the local receiver-active status, but it does not implement the complete required Adapter LSM sequence:

- `rtl/d2d_adapter/fdi_state_machine.sv:307-318`
- `rtl/d2d_adapter/fdi_state_machine.sv:366-416`

Retrain requests are deliberately suppressed:

- `rtl/d2d_adapter/fdi_state_machine.sv:325-343`

L1 and L2 are intentionally reduced power-management capability in this
profile. The current logical policy maps L1 and L2 requests to PMNAK in the RDI
state machine and suppresses them at the FDI forwarding boundary:

- `rtl/logical_phy/rdi_state_machine.sv:221-240`
- `rtl/d2d_adapter/fdi_state_machine.sv:325-343`

This report does not score omitted power circuits or L1/L2 operation. It does
require deterministic state and message behavior at that reduced boundary.

The PHY stall request is tied low:

- `rtl/logical_phy/logical_phy.sv:1113-1138`

Therefore, the integrated stall sequence does not run before LinkReset or
Disabled transitions.

The Adapter datapath does not retain an unaccepted beat during backpressure:

- `rtl/d2d_adapter/adapter_datapath.sv:152-208`

Clock and wake behavior is included in the same reduced PM scope. Initialization
and state-transition ordering remain in scope.

### 11.4 Status

**Partial reduced interface, but noncompliant public contract and state sequencing.**

## 12. Severity-ranked gaps

### P0: Replace the sideband transport and packet model

Impact:

- Standard UCIe sideband interoperability is impossible.
- Packet widths, framing, pins, routing, and credit behavior are incompatible.

Evidence:

- `rtl/logical_phy/sb_codec.sv:13-41`
- `rtl/logical_phy/sb_codec.sv:243-321`
- `rtl/d2d_adapter/adapter_sb_if.sv:44-72`
- `rtl/logical_phy/logical_phy.sv:700-770`

### P0: Implement Stage 3 and the Adapter LSM

Impact:

- The endpoint never negotiates Streaming or Raw Mode.
- FDI state is conflated with RDI state.
- The required Adapter hierarchy is missing.

Evidence:

- `rtl/rtl_common/ucie_pkg.sv:426-435`
- `rtl/d2d_adapter/adapter_sb_if.sv:465-502`
- `rtl/d2d_adapter/fdi_state_machine.sv:296-416`
- `rtl/logical_phy/ltsm.sv:1779-1870`

### P0: Correct MBINIT and MBTRAIN

Impact:

- A standard partner can reject or misinterpret the training messages.
- The RTL can enter Active without mandatory training results.

Evidence:

- `rtl/logical_phy/ltsm.sv:614-910`
- `rtl/logical_phy/ltsm.sv:1635-1652`
- `rtl/logical_phy/ltsm.sv:1950-2078`

### P0: Restore the Section 8 RDI and FDI contracts

Impact:

- Required signals and directions are missing.
- Error reporting and state coordination cannot work as specified.

Evidence:

- `rtl/ucie_main.sv:264-304`
- `rtl/logical_phy/rdi_state_machine.sv:259-299`
- `rtl/d2d_adapter/d2d_adapter.sv:500-536`

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

### P2: Correct public parameterization and compliance claims

Impact:

- `NBYTES` does not control all public widths.
- Unit coverage can imply support that integrated RTL does not provide.

Evidence:

- `rtl/ucie_main.sv:260-304`
- `rtl/logical_phy/logical_phy.sv:198-241`
- `sim/cov_report.py:75-190`
- `README.md:10-34`

## 13. Verification evidence and limitations

### 13.1 What the stored evidence proves

The stored artifacts prove that the repository test environment can:

- Compile the reduced RTL.
- Pass the local unit tests.
- Bring two matching endpoints to Active.
- Transfer Raw data in both directions.
- Exercise local LinkReset and Disabled flows.
- Exercise digital scrambling and descrambling.
- Detect the tested internal gearbox framing faults.

Relevant artifacts:

- `sim/logs/unit.txt:1-90`
- `sim/logs/loopback_run.txt:1-45`
- `sim/Makefile:220-322`
- `tb/unit/ut_sb_codec.sv:1-31`
- `tb/unit/ut_sb_codec.sv:180-250`

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

The repository has no independent proof for:

- Exact normative sideband packet vectors.
- Stage 3 capability exchange.
- Incompatible capability handling.
- LinkMgmt.Adapter0 coordination.
- Complete supported-profile MBINIT and MBTRAIN pattern results.
- PHYRETRAIN recovery.
- Public RDI and FDI compile-contract conformance.
- Ready-valid retention.
- Receiver-active exit ordering.
- Sideband credit conservation.

Lane reversal and lane or speed degradation are intentional profile exclusions,
so this report does not require integrated tests for those behaviors.

## 14. Final disposition

The correct implementation statement is:

> This RTL implements a simplified, fixed-profile UCIe-like endpoint that is self-compatible in the repository loopback environment. It is not compliant with UCIe 1.0 Sections 3.1, 3.2, 3.3, 3.4, 4.1, 4.5.3, 6, and 8 as an interoperable endpoint. Runtime PM circuits, lane reversal, and lane or speed degradation are intentional profile exclusions. Logical state progression, sideband message boundaries, and supported training behavior remain compliance requirements.

The largest missing work is logical protocol work, not analog PHY or runtime-PM circuit work.

# Simplified Logical LTSM Gap Assessment

## Purpose

This document records the assessment of the current LTSM against UCIe 1.0
Section 4.5.3. It uses the repository's simplified logical UCIe scope.

The assessment does not require an Electrical PHY implementation.

## Scope boundary

The repository supports one Standard Package x16 module at 4 GT/s with Raw
Mode and Streaming. It excludes Advanced Package support, Retimers, analog
PHY circuits, CRC, replay, and sequence-number logic.

Electrical PHY omissions are acceptable in this profile:

- Analog Vref, termination, AFE, PLL, and phase-control circuits.
- Eye scans, point tests, margin checks, and analog pass/fail thresholds.
- Electrical lane repair and redundant-lane switching.
- Analog pad impedance and true electrical high-impedance behavior.
- Advanced Package repair.
- Mainband CRC, replay, retry, and sequence-number logic.
- x8 degradation, because the project profile is fixed x16.

The digital mainband model now has directional clocks, scalar pad enables, and enabled electrical idle.
It implements continuous clock control and RXCLKCAL request-driven start and stop acknowledgments.
It does not claim analog pad or full training-waveform compliance.

Sources:

- `README.md:10-33`
- `README.md:80-88`
- `rtl/logical_phy/logical_phy.sv:778-791`

A training-state name does not make its logical protocol behavior electrical.
The scope still includes LTSM transitions, sideband packet semantics, request
and response roles, timeouts, RDI coordination, negotiated parameter
encoding, and digital data-path control.

## Approved minimum logical runtime profile

The simplified endpoint supports the initial link bring-up path, LinkReset
recovery, and the Disabled flow.

```text
RESET -> SBINIT -> MBINIT -> MBTRAIN -> LINKINIT -> ACTIVE
TRAINERROR -> LinkReset -> RESET
```

The endpoint does not support runtime PHY retrain, runtime power management
(L1 or L2), Retimer behavior, or multi-module behavior.

This profile does not permit an unsupported public RDI request to leave the
RDI state machine and LTSM in different states. The integration must define a
safe and deterministic response for every unsupported request.

LinkReset is not a Link Training trigger. After RDI transitions from LinkError,
LinkReset, or Disabled to RESET, training must not start until the Adapter
issues an RDI NOP-to-Active transition or software sets Start UCIe Link
Training. `UCIE.md:11366-11369`.

## Approved logical design decisions

### 1. Unsupported runtime RDI requests

Runtime PHYRETRAIN and runtime power management are unsupported. L1 and L2
requests must use the defined PM rejection behavior. An RDI Retrain request
must not publish RDI Retrain or cause an LTSM state change. The implementation
must handle every unsupported request deterministically.

### 2. LinkReset recovery

The endpoint supports LinkReset recovery:

```text
LinkReset -> RESET -> 4 ms minimum -> new permitted trigger -> SBINIT
```

LinkReset does not provide the new trigger. After recovery RESET, only a new
RDI NOP-to-Active transition or a software Start UCIe Link Training request can
start training.

### 3. Post-SBINIT transaction ownership

`ltsm.sv` owns all request-response policy and state completion decisions. A
helper can provide packet queueing only. It cannot own LTSM policy or state.

For each logical transaction, the LTSM must send the local request, send the
matching response for every valid peer request, track the response to the
local request separately, and advance only when the specified exchange is
complete.

### 4. Simplified MBINIT and MBTRAIN model

Every required electrical operation is modeled as immediate local success. The
RTL must still execute the named logical sideband sequence for the sub-state:
start or init exchange, modeled success, result or done exchange, then the
specified next state.

### 5. Fixed-profile MBINIT.PARAM resolution

The endpoint advertises its fixed x16, 4 GT/s, Raw Mode profile. It requires
the peer PARAM response to resolve to the same supported profile. An
incompatible response enters TRAINERROR. Electrical parameter application
remains outside this RTL scope.

### 6. Disabled-state support

The endpoint supports the Disabled flow:

```text
ACTIVE or LinkReset -> Disabled -> RESET -> new permitted trigger -> SBINIT
```

`ltsm.sv` owns the RDI Disabled request-response policy. `logical_phy.sv`
provides only packet transport. The LTSM must enter RDI LinkError if the remote
response is absent for 8 ms. It can leave Disabled only through the defined
re-enable flow to RESET. `UCIE.md:11285-11292`, `UCIE.md:11354-11357`.

### 7. Fixed MBINIT.PARAM encodings

`ucie_pkg.sv` is the sole source for immutable MBINIT.PARAM constants. The
LTSM must not use hidden literals. The endpoint sends this configuration
request:

| Data field | Value | Meaning |
| --- | --- | --- |
| `[12:11]` | `2'b00` | Module 0 |
| `[10]` | `1'b0` | Differential clock |
| `[9]` | `1'b1` | Continuous clock |
| `[8:4]` | `5'h01` | 0.4 V voltage-swing placeholder |
| `[3:0]` | `4'h0` | 4 GT/s maximum speed |

The request is `SB_OP_MSG_DATA64`, `MsgInfo=16'h0000`, `A5h/00h`, with
`Data=64'h0000_0000_0000_0210`.

The expected configuration response is `AAh/00h` with
`Data=64'h0000_0000_0000_0200`. The LTSM requires response Clock Phase `0`,
Clock Mode `1`, and common maximum speed `0`. It ignores the reserved response
fields.

For a peer configuration request, the LTSM accepts an advertised maximum speed
greater than 4 GT/s but responds with 4 GT/s. It accepts only continuous clock
and differential clock phase. It accepts a defined voltage-swing encoding from
`01h` through `10h`. A reserved voltage-swing encoding is fatal.

`phy_csr.sv` can expose values for observability, but it is not the packet
source. `adapter_regfile.sv` is also not the packet source because its
electrical-parameter field layout does not match Table 56.

Sources: `UCIE.md:6899-6936`, `UCIE.md:7583-7586`, `UCIE.md:8806-8837`,
`UCIE.md:2362-2367`.

### 8. Generic sideband concurrency rules

The LTSM supports one outstanding local request per logical sub-state. It must
respond idempotently to a valid duplicate peer request. It must reject a stale
response, a packet from another sub-state, and an invalid packet. If the TX
mailbox is busy, it must retain the peer-response obligation until it sends the
response.

### 9. TRAINERROR and integrity policy

CP parity failure, DP parity failure, an invalid training response, a PARAM
incompatibility, and a residency timeout are fatal. When sideband is active,
the LTSM must perform the TRAINERROR Entry request-response exchange. It must
assert RDI LinkError and recover only through LinkReset.

### 10. Active data-path policy

The logical data path is enabled only after RDI Active Entry completes. It
blocks data outside the allowed RDI state and applies the digital Active-data
scrambler. A valid-framing failure uses the fatal error and LinkReset recovery
policy.

### 11. Fixed-profile LINKSPEED failure

LINKSPEED success exits to LINKINIT. A LINKSPEED error, repair request,
width-degrade request, or speed-degrade request is unsupported in this
profile. It must execute the TRAINERROR Entry handshake, assert RDI LinkError,
and recover through LinkReset.

### 12. Concurrent transition priority

The transition priority is:

```text
LinkError > Disabled > LinkReset > normal training transaction
```

A higher-priority transition aborts the active logical transaction and starts
the required sideband transition exchange.

### 13. Start UCIe Link Training lifecycle

Software Start and RDI NOP-to-Active initiate training. After RDI Active Entry
completes, the Physical Layer clears its local Start UCIe Link Training copy.
This prevents an unintended later training attempt.

Sources: `UCIE.md:4415-4455`, `UCIE.md:11350-11357`,
`UCIE.md:4544-4549`.

### 14. Sideband packet arbitration

The LTSM transmits pending sideband packets in this order:

```text
1. LinkError, Disabled, or LinkReset transition response
2. TRAINERROR Entry response
3. Current-sub-state peer request response
4. Current-sub-state local request
5. Retried or duplicate response
```

A required peer response has priority over a new local request. The LTSM keeps
the peer-response obligation until the packet CDC accepts it. It permits only
one outstanding local request per logical sub-state.

## Current compliant behavior

The Standard Package SBINIT and post-SBINIT training sequences are implemented and verified in the current RTL for the simplified logical scope:

- RESET has a 4 ms minimum residency.
- RESET accepts the local training request or the two-pattern SBINIT trigger.
- SBINIT uses 64 active UI plus 32 low UI.
- Detection requires two consecutive matching iterations.
- A mismatch clears the match streak.
- Detection causes four further complete local iterations.
- The LTSM repeats Out-of-Reset until the peer copy arrives.
- Done request and Done response have separate obligations.
- All 21 reachable LTSM states (00h-11h, 14h, 15h, 16h) are fully traversed; `TRAINERROR` (16h) is reachable and verified via timeout, sideband parity error escalation, and mainband framing faults.
- The documented unreachable states (`MBTRAIN.REPAIR` 12h, `PHYRETRAIN` 13h, and `L1L2` 17h) are excluded from the 21-state coverage denominator.
- Standard sideband packet architecture (`sb_packet_t`) per Figures 100-103 with 64-bit header, 32-UI gap, optional 64-bit payload, and CP/DP parity over scalar physical pins (`sb_tx_clk`, `sb_tx_data`, `sb_rx_clk`, `sb_rx_data`).
- Verified across the directed unit-test suite, sideband unit tests, independent sideband peer test (`tb_sideband_peer.sv`), and full 2-die loopback (`tb_loopback_top.sv`).

Sources:

- `UCIE.md:3602-3634`
- `rtl/logical_phy/ltsm.sv:604-726`
- `rtl/logical_phy/logical_phy.sv:652-667`

## Remaining logical protocol gaps (Historical Assessment and Resolution)

### P0: Post-SBINIT sideband request and response semantics

The LTSM sends generic requests for later training states, but it has no
matching generic response transmitter. It marks a state response as received
when it receives either a matching peer request or a matching peer response.

```systemverilog
if (rx_phy_msg_valid && (msg_is_rsp || msg_is_req)) resp_rcvd_d = 1'b1;
```

This allows two peer requests to satisfy each other's response requirement.
It does not implement the required request-response handshake for MBINIT,
MBTRAIN, PHYRETRAIN, or TRAINERROR.

SBINIT Done has correct separate request and response behavior, but this logic
does not apply to later states.

Required logical behavior:

1. Send the local request.
2. Send the matching response for every valid peer request.
3. Track the response to the local request separately.
4. Advance only after the required exchange completes.

Sources:

- `rtl/logical_phy/ltsm.sv:501-506`
- `rtl/logical_phy/ltsm.sv:514-527`
- `rtl/logical_phy/ltsm.sv:597-602`
- `rtl/logical_phy/ltsm.sv:700-726`
- `UCIE.md:4096-4105`

**Current Status: RESOLVED in RTL.**
Phase A/B implemented separate request and response obligations in `rtl/logical_phy/ltsm.sv:963-999, 1044-1073`. Local requests and peer requests are tracked independently, peer requests generate matching responses, and sub-states advance only when both local-request response and peer-request handling are satisfied. Verified in `tb/unit/ut_ltsm_policy.sv` (Scenarios 1 & 4).

### P0: MBINIT.PARAM payload exchange is absent

The project excludes analog parameter application, but it requires logical
parameter encoding and negotiation. The LTSM always emits no-data packets with
zero payload. The RX CDC bundle also does not return payload data to the LTSM.

The logical PARAM transaction must encode, receive, and resolve the fixed
profile's maximum speed, clock-mode information, clock-phase capability, and
Module ID. A fixed x16 and 4 GT/s endpoint can resolve only its supported
profile, but it still must perform the exchange.

Sources:

- `README.md:20`
- `rtl/logical_phy/ltsm.sv:447-470`
- `rtl/logical_phy/ltsm.sv:826-831`
- `rtl/logical_phy/logical_phy.sv:538-554`
- `UCIE.md:3648-3681`

**Current Status: RESOLVED in RTL.**
Phase B implemented the logical PARAM payload exchange in `rtl/logical_phy/ltsm.sv:837-895` and `rtl/logical_phy/logical_phy.sv:538-554`. The LTSM transmits `SB_OP_MSG_DATA64` with fixed-profile parameters (4 GT/s, differential continuous clock, swing 0.4V), receives and validates peer configuration responses, and escalates profile incompatibilities to TRAINERROR. Verified in `tb/unit/ut_ltsm_policy.sv` (Scenario 6).

### P0: RDI Active Entry is not part of LINKINIT completion

The LTSM leaves LINKINIT as soon as `pat_done` asserts. The RDI state machine
separately enters Active when the adapter requests Active and the LTSM reports
link trained. The signal intended to represent local Active authorization does
not control the LTSM.

The implementation can therefore report LTSM or RDI Active without proving
completion of the remote LinkMgmt Active handshake.

Required logical behavior:

1. Keep the LTSM in LINKINIT until the local and remote Active-entry obligations
   complete.
2. Assign one block ownership of LinkMgmt.RDI request and response packets.
3. Publish RDI Active only after the specified completion order.

Sources:

- `rtl/logical_phy/ltsm.sv:773-775`
- `rtl/logical_phy/rdi_state_machine.sv:195-201`
- `rtl/logical_phy/rdi_state_machine.sv:297-308`
- `rtl/logical_phy/logical_phy.sv:981-985`
- `UCIE.md:4544-4551`
- `UCIE.md:9906-9932`

**Current Status: RESOLVED in RTL.**
Phase A/B integrated RDI Active Entry into LINKINIT completion in `rtl/logical_phy/ltsm.sv:1664-1680`. The LTSM remains in LINKINIT until both local and remote `{LinkMgmt.RDI.Req.Active}` and `{LinkMgmt.RDI.Rsp.Active}` exchanges complete, coordinating with `rdi_state_machine.sv` before publishing Active. Verified in `tb/unit/ut_ltsm_policy.sv` and `tb/loopback/tb_loopback_top.sv`.

### P0: LinkReset recovery and unsupported runtime requests

RDI LinkReset is supported and must drive the LTSM to RESET. After its 4 ms
minimum, the LTSM must wait for the new permitted recovery trigger defined in
the approved runtime profile.

Runtime PHYRETRAIN and L1/L2 are unsupported. The RDI integration must reject
L1/L2 through the defined PM rejection behavior. An RDI Retrain request must
not publish RDI Retrain or change the LTSM state.

Sources:

- `rtl/logical_phy/ltsm.sv:316-317`
- `rtl/logical_phy/ltsm.sv:777-791`
- `rtl/logical_phy/rdi_state_machine.sv:203-240`
- `rtl/logical_phy/logical_phy.sv:843-851`
- `UCIE.md:11254-11267`
- `UCIE.md:11366-11369`

**Current Status: RESOLVED in RTL.**
Phase C implemented link recovery policy in `rtl/logical_phy/ltsm.sv:963-999` and `rtl/logical_phy/rdi_state_machine.sv:203-240`. RDI LinkReset transitions LTSM to RESET and enforces the 4 ms minimum dwell before accepting a new permitted trigger (NOP-to-Active or `start_link_train`). Unsupported L1/L2 requests return PMNAK deterministically; Retrain requests do not disturb LTSM state. Verified in `tb/unit/ut_rdi_sm.sv` and `tb/unit/ut_ltsm_policy.sv` (Scenario 8).

### P1: Fixed-profile LINKSPEED resolution is incomplete

The RTL always advances from LINKSPEED to REPAIR. The approved fixed 4 GT/s
profile models the supported no-error result and an unsupported-error result.
It must select the matching state and sideband behavior for both results. It
does not implement repair, width degradation, or speed degradation.

Sources:

- `rtl/logical_phy/ltsm.sv:755-766`
- `UCIE.md:4415-4455`

**Current Status: RESOLVED in RTL.**
Phase B/C implemented fixed-profile LINKSPEED resolution in `rtl/logical_phy/ltsm.sv:1635-1652`. Successful handshake transitions directly to LINKINIT, while error or unsupported repair/degrade requests trigger fatal escalation to TRAINERROR. Verified in `tb/unit/ut_ltsm_policy.sv` (Scenario 7).

### P1: TRAINERROR protocol and sideband integrity handling are incomplete

The residency timeout directly enters TRAINERROR. For states after SBINIT, the
required TRAINERROR Entry request-response sequence is absent. The LTSM has no
generic response scheduler for TRAINERROR and ignores sideband CP or DP parity
errors instead of escalating them.

SBINIT timeout behavior is already present.

Required logical behavior:

1. Enter an internal TRAINERROR entry phase.
2. Send or respond to the TRAINERROR Entry message.
3. Apply its 8 ms entry timeout.
4. Assert the RDI fatal state.
5. Hold TRAINERROR until the permitted RDI recovery condition occurs.

Sources:

- `rtl/logical_phy/ltsm.sv:397-444`
- `rtl/logical_phy/ltsm.sv:485-489`
- `rtl/logical_phy/ltsm.sv:789-802`
- `rtl/logical_phy/ltsm.sv:826-833`
- `UCIE.md:4711-4732`

**Current Status: RESOLVED in RTL.**
Phase B/C implemented TRAINERROR entry protocol in `rtl/logical_phy/ltsm.sv:1664-1680`. Residency timeouts, PARAM incompatibilities, framing faults, and CP/DP parity errors from `sb_codec.sv` initiate the `{TRAINERROR Entry}` request/response handshake (`MC_TRAINERROR` = E5h/EAh), assert RDI LinkError, and hold until LinkReset recovery. Verified in `tb/unit/ut_ltsm_policy.sv` (Scenarios 2, 8, 9).

### P1: RDI Stallreq/Ack is absent

The public RDI stall request is tied low. The internal acknowledgment is
combinational and does not consume the Adapter acknowledgment.

This is a digital RDI coordination requirement for supported LinkReset and
Disabled transitions. It is not an analog PHY feature.

Sources:

- `rtl/logical_phy/logical_phy.sv:832-840`
- `rtl/logical_phy/rdi_state_machine.sv:310-341`
- `UCIE.md:11058-11090`

**Current Status: RESOLVED in RTL.**
Phase D/F implemented the 4-phase stall tracker in `rtl/logical_phy/rdi_state_machine.sv:314-393`. `pl_stallreq` rises only when `lp_stallack` is low, requiring registered response and data quashing. Verified in `tb/unit/ut_stall.sv` and captured in `stall_evidence.json`.

### P1: Digital Active-state data control is incomplete

The TX path forwards Adapter data whenever training patterns are disabled. The
RX path forwards gearbox data without LTSM or RDI Active qualification. Active
data also does not pass through the existing digital scrambler.

These are logical data-path requirements, not electrical PHY requirements.

Required logical behavior:

1. Block RDI and mainband data outside the allowed RDI state.
2. Enable the data path only after RDI Active Entry completes.
3. Apply the digital Active-data scrambler.
4. Route valid-framing failures to the simplified error and LinkReset recovery
   policy.

Sources:

- `rtl/logical_phy/logical_phy.sv:891-898`
- `rtl/logical_phy/logical_phy.sv:956-958`
- `rtl/logical_phy/logical_phy.sv:699-705`
- `UCIE.md:4544-4567`

**Current Status: RESOLVED in RTL.**
Phase B/F implemented Active data-path gating and scrambling in `rtl/logical_phy/logical_phy.sv:1255-1390` and `rtl/rtl_common/scrambler.sv:109-208`. Mainband data is blocked outside RDI Active, scrambling is applied per-lane, and framing faults detected by `mb_gearbox.sv` trigger fatal error escalation to TRAINERROR. Verified in `tb/unit/ut_gearbox.sv` and `tb/unit/ut_ltsm_policy.sv` (Scenario 9).

## Recommended implementation order

1. Add correct generic sideband request-response semantics.
2. Add MBINIT.PARAM payload exchange and fixed-profile resolution.
3. Unify RDI Active Entry, LinkReset, Disabled, and TRAINERROR ownership.
4. Make unsupported PM and PHYRETRAIN requests deterministic at RDI.
5. Model fixed-profile LINKSPEED, Stallreq/Ack, and state-gated data flow.

## Assessment conclusion

The historical logical protocol gaps identified in this assessment have been resolved in the current RTL across Phases A–F and the sideband protocol remediation. The LTSM now implements spec-compliant request-response semantics, MBINIT.PARAM payload negotiation, LINKINIT Active Entry coordination, LinkReset recovery, deterministic PMNAK rejection, fatal TRAINERROR escalation, 4-phase stall tracking, and Active-gated scrambling. The assessment does not claim a fixed unit-test count, coverage result, or warning-free final run.

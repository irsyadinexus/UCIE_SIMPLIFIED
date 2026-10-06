# Minimal-Invasive UCIe Compliance Fix Plan

## 1. Scope and rules

This plan fixes every remaining P0, P1, and P2 mismatch from the deep dive.

Keep these completed changes unchanged:

- Adapter0 request and response codes.
- Separate `phy_training_done` indication before Active Entry.

Do not change these intentional profile limits:

- One protocol stack.
- Standard Package.
- x16 operation.
- 4 GT/s operation.
- No retimer.
- No Retry or CRC data path.
- No runtime Retrain.
- No runtime L1 or L2 residency.
- Streaming Raw Mode only.

Use existing state machines and signals where possible. Add only narrow status or error signals that the current interfaces cannot provide.

No code changes start until explicit permission is given.

# 2. P0 fixes

## P0-1. Correct Stage 2 and Stage 3 ownership

### Specification

Use:

- `UCIE.md:1392-1397`
- `UCIE.md:9906-9932`
- `UCIE.md:10344-10353`
- `UCIE.md:10425-10438`
- `UCIE.md:10805-10835`

Required order:

1. Physical training completes.
2. RDI `pl_inband_pres` asserts.
3. Adapter completes capability negotiation.
4. Adapter publishes the FDI protocol and in-band indications.
5. Protocol Layer requests FDI Active.
6. Adapter completes Adapter0 Active Entry.
7. FDI publishes Active.
8. Data transfer opens.

### Current problem

The FDI state machine publishes Active from RDI Active and `lp_rx_active_sts`. Adapter Stage 3 completes later.

Relevant files:

- `rtl/d2d_adapter/fdi_state_machine.sv:365-374`
- `rtl/d2d_adapter/adapter_sb_if.sv:1302-1324`
- `rtl/d2d_adapter/adapter_sb_if.sv:1410-1414`
- `rtl/d2d_adapter/d2d_adapter.sv:616-633`

### Minimal fix

1. Keep RDI `pl_inband_pres` driven by `phy_training_done`.
2. Expose one narrow Adapter capability-complete indication.
3. Expose one narrow Adapter0 Active Entry-complete indication.
4. Add one combined `adapter_stage3_ready` condition.
5. Allow FDI protocol-valid and FDI in-band presence only after capability completion.
6. Allow FDI Active only after:
   - The Protocol Layer requested Active.
   - Adapter0 Active Entry completed.
   - RDI remains Active.
7. Keep user-data gating unchanged except for the corrected FDI Active status.

Avoid rewriting either full state machine. Add the smallest missing handshake dependencies.

### Required tests

Add or update:

- A staged bring-up test with delayed Active request.
- A test that holds FDI Active low before Adapter0 completion.
- A test that confirms data remains blocked before FDI Active.
- An independent peer test that waits for RDI in-band presence before requesting Active.

### Acceptance

The test must fail if FDI Active occurs before Adapter0 completion. The test must pass when the complete order occurs.

## P0-2. Connect Adapter LinkError to RDI LinkError

### Specification

Use:

- `UCIE.md:9569-9581`
- `UCIE.md:11291-11329`

### Current problem

The Adapter creates `rdi_lp_linkerror`, but the Logical PHY does not use it to change RDI state.

Relevant files:

- `rtl/d2d_adapter/d2d_adapter.sv:643-645`
- `rtl/ucie_main.sv:556-563`
- `rtl/logical_phy/logical_phy.sv:1794-1800`
- `rtl/logical_phy/rdi_state_machine.sv:208-218`

### Minimal fix

1. Add the existing Adapter LinkError signal as an RDI state-machine input.
2. Pass it through `logical_phy.sv`.
3. Give it priority over normal RDI state transitions.
4. Enter RDI LinkError when the signal asserts.
5. Hold LinkError until the defined LinkReset recovery starts.
6. Do not change the existing `phy_train_error` path.

### Required tests

Add a focused RDI test for:

- Adapter fatal error from Active.
- LinkError persistence.
- LinkReset recovery.
- No data transfer during LinkError.

### Acceptance

A fatal Adapter error must produce:

```text
RDI Active -> RDI LinkError -> RDI LinkReset -> RDI Reset
```

## P0-3. Restore the integrated stall handshake

### Specification

Use:

- `UCIE.md:11056-11100`

### Current problem

The integrated Logical PHY ties the stall request and acknowledgement path low.

Relevant files:

- `rtl/logical_phy/logical_phy.sv:1110-1158`
- `rtl/logical_phy/logical_phy.sv:1269-1277`
- `rtl/logical_phy/rdi_state_machine.sv:223-234`

### Minimal fix

1. Connect the existing RDI stall request into the Logical PHY state machine.
2. Connect the existing stall acknowledgement back to the RDI interface.
3. Preserve the current four-phase tracker.
4. Gate only the state exits that require a stall.
5. Do not change the isolated Adapter stall relay.

Required four-phase sequence:

```text
pl_stallreq = 1
lp_stallack = 1
data transfer stops
pl_stallreq = 0
lp_stallack = 0
```

### Required tests

Add one integrated test for each supported state exit:

- Active to LinkReset.
- Active to Disabled.
- Active to power-management handling if the simplified profile exposes it.

Keep unsupported Retrain, L1, and L2 paths out of the test denominator.

### Acceptance

The state transition must not complete until the four-phase handshake completes.

## P0-4. Enforce Reset request sampling

### Specification

Use:

- `UCIE.md:11143-11173`

### Current problem

The RDI state machine accepts a held Active or Disabled level immediately after Reset.

Relevant file:

- `rtl/logical_phy/rdi_state_machine.sv:214-221`

### Minimal fix

1. Add one Reset request-sampling flag.
2. Clear the flag whenever the state enters Reset.
3. Set the flag only after sampling `lp_state_req = NOP`.
4. Reject Active and Disabled levels until the flag is set.
5. Add the missing Reset-to-LinkReset branch.
6. Preserve the existing reset dwell timer.

Do not add a second reset controller.

### Required tests

Add tests for:

- Active held through reset.
- Disabled held through reset.
- Active after one sampled NOP.
- LinkReset requested from Reset.
- Reset dwell followed by a new Start event.

### Acceptance

A held request must not restart the link. A new request after a sampled NOP must work.

# 3. P1 fixes

## P1-1. Align the RDI data transfer tuple

### Specification

Use:

- `UCIE.md:9533-9553`

### Current problem

The Adapter registers data and valid, but the RDI ready relationship is not held with the tuple.

Relevant files:

- `rtl/d2d_adapter/adapter_datapath.sv:164-210`
- `rtl/logical_phy/logical_phy.sv:1389-1425`

### Minimal fix

1. Add one fixed one-entry elastic stage in the Adapter datapath.
2. Store data and valid together.
3. Hold the stored data while the transfer is not accepted.
4. Advance only when the full valid, ready, and data tuple transfers.
5. Keep the existing datapath width and stream handling.

Do not add a general FIFO.

### Required tests

Cover:

- One-cycle valid pulse.
- Backpressure.
- Data stability while blocked.
- Consecutive accepted transfers.
- Empty-to-full and full-to-empty transitions.

### Acceptance

No data or valid value can move without a complete accepted tuple.

## P1-2. Make all sideband integrity errors fatal before packet effects

### Specification

Use:

- `UCIE.md:7067-7095`

### Current problem

CP and DP errors reach the Adapter, but the Adapter checks them mainly during AdvCap.

Relevant files:

- `rtl/logical_phy/sb_codec.sv:529-589`
- `rtl/d2d_adapter/adapter_sb_if.sv:690-739`
- `rtl/d2d_adapter/adapter_sb_if.sv:921-962`
- `rtl/d2d_adapter/adapter_sb_if.sv:1348-1360`
- `rtl/d2d_adapter/adapter_sb_if.sv:1498-1523`

### Minimal fix

1. Add one packet-integrity condition at the Adapter packet-effect boundary.
2. Reject any packet with CP or DP error.
3. Send the error to the existing fatal error path.
4. Prevent packet effects for:
   - Capability negotiation.
   - Active Entry.
   - LinkReset.
   - Disabled.
   - Adapter register access.
5. Preserve the existing AdvCap checks.

Do not duplicate error checks in every packet handler.

### Required tests

Inject CP and DP errors into each supported packet class. Verify:

- No packet side effect occurs.
- Fatal status asserts.
- LinkError recovery starts.
- No corrupted packet updates a register.

### Acceptance

No corrupted sideband packet can change protocol or Adapter state.

## P1-3. Preserve all 16 `MsgInfo` bits

### Specification

Use:

- `UCIE.md:6476-6485`
- `UCIE.md:6590-6644`

### Current problem

The LTSM message boundary carries only 8 bits.

Relevant files:

- `rtl/logical_phy/ltsm.sv:351-360`
- `rtl/logical_phy/logical_phy.sv:902-913`

### Minimal fix

1. Change the LTSM `MsgInfo` input and internal path to 16 bits.
2. Update the Logical PHY connection.
3. Preserve all packet fields through the sideband path.
4. Keep existing low-byte behavior unchanged.
5. Add upper-byte validation in the packet checker.

### Required tests

Use literal peer packets with non-zero upper `MsgInfo` bits. Verify that the LTSM receives and validates the complete value.

### Acceptance

No `MsgInfo[15:8]` bits are lost or ignored.

## P1-4. Use per-step MBTRAIN message tuples

### Specification

Use:

- `UCIE.md:6574-6644`

### Current problem

The RTL uses broad phase-wide request and response pairs. Table 54 defines step-specific tuples.

Relevant files:

- `rtl/rtl_common/ucie_pkg.sv:905-936`
- `rtl/logical_phy/ltsm.sv:621-662`

### Minimal fix

1. Define one expected request tuple for each supported MBTRAIN step.
2. Define one expected response tuple for each supported MBTRAIN step.
3. Validate request and response direction separately.
4. Keep source and destination validation unchanged.
5. Keep unsupported MBTRAIN.REPAIR behavior unchanged.

Avoid a generic transaction framework. Use a small case statement or table that matches the existing FSM.

### Required tests

Use an independent literal sideband peer to verify every supported MBTRAIN step.

Test:

- Correct request.
- Correct response.
- Reversed request and response.
- Wrong step code.
- Wrong source or destination.
- Wrong `MsgInfo`.

### Acceptance

Two identical endpoints must not hide an incorrect message tuple.

## P1-5. Complete or remove the PMNAK runtime path

### Specification

Use the RDI PMNAK behavior in `UCIE.md:9601-9604` and the RDI state definitions around `UCIE.md:9896-9905`.

### Current problem

The FDI state machine suppresses L1 and L2, and the PMNAK test can pass without proving the real request and response path.

Relevant files:

- `rtl/d2d_adapter/fdi_state_machine.sv:319-338`
- `rtl/d2d_adapter/adapter_sb_if.sv:1418-1426`
- `tb/loopback/tb_loopback_top.sv:1754-1781`

### Minimal fix

Keep the simplified profile unsupported for L1 and L2, but implement the defined PMNAK response:

1. Accept the unsupported state request.
2. Detect that the state is unsupported.
3. Send PMNAK.
4. Keep the current state unchanged.
5. Do not set coverage until the actual PMNAK packet is observed.
6. Add a timeout to the test.

Use separate test conditions for request observed and response observed.

### Acceptance

The PMNAK test must fail if no PMNAK request and response cross the interface.

# 4. P2 fix

## P2-1. Enforce the fixed Stack0 Streaming ID

### Current problem

The datapath echoes the local transmit stream value.

Relevant file:

- `rtl/d2d_adapter/adapter_datapath.sv:205-210`

Existing tests:

- `tb/unit/ut_fdi_sm.sv:456-468`
- `tb/unit/ut_stall.sv:349-390`

### Minimal fix

1. Use the fixed Stack0 Streaming ID on the receive path.
2. Reject or normalize unsupported stream IDs.
3. Update tests to use the required fixed value.
4. Keep the raw data path unchanged.

### Acceptance

A supported Streaming transfer always uses the fixed Stack0 stream ID.

# 5. Implementation order

Use this order to keep each change small and testable.

1. Fix RDI LinkError routing and Reset request sampling.
2. Restore the integrated stall handshake.
3. Correct Stage 2 and Stage 3 ownership.
4. Fix sideband integrity handling and MBTRAIN packet tuples.
5. Fix the RDI data tuple.
6. Complete the PMNAK path.
7. Enforce the fixed stream ID.
8. Run the final integration gate.

The Stage 2 and Stage 3 fix depends on the already completed Adapter0 message-code fix and `phy_training_done` fix.

# 6. Verification plan

Run the smallest relevant check after each change:

```text
wsl.exe make -C sim compile
```

Run focused unit tests for each state-machine or datapath change.

Run the sideband tests after sideband changes:

```text
wsl.exe make -C sim sideband-unit
wsl.exe make -C sim sideband-peer
```

Run the complete unit suite after each P0 or P1 group:

```text
wsl.exe make -C sim unit
```

Run the integrated link and recovery test after each P0 group:

```text
wsl.exe make -C sim loopback
```

Run the final gate only after all changes:

```text
wsl.exe make -C sim all
```

The final gate must prove:

- Correct staged bring-up.
- Correct LinkError recovery.
- Correct stall ordering.
- Correct Reset request sampling.
- Correct sideband integrity handling.
- Correct message tuples.
- Correct PMNAK behavior.
- Correct stream ID.
- Existing bidirectional data and recovery behavior remains passing.

No implementation changes are included in this plan.

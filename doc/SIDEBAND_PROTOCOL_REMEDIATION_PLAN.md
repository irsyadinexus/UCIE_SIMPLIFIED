# Sideband Protocol Remediation Plan

## Context

The current endpoint uses two incompatible reduced sideband formats, drops required packet metadata, leaves Adapter/PHY configuration routing inert, and proves only same-RTL loopback behavior. Replace it with a fixed-profile interoperable Chapter 6 subset: standard no-data and DATA64 messages, 32-bit and 64-bit configuration requests, all three completion forms, full parity/tag/BE/status semantics, and Unsupported Request completions for memory opcodes. Keep analog PHY behavior, runtime PM circuits, lane reversal, and degradation outside this work, while preserving initialization and state progression.

The selected architecture keeps one physical sideband engine, router, CDC boundary, and TX arbiter in `logical_phy`. The Adapter connects through one canonical typed packet client, owns reduced-profile Stage 3, and keeps its CSR and FDI policy. The public physical interface changes cleanly to scalar TX/RX data with forwarded clocks: each die provides its own nominal 800 MHz TX source (`sbclk`) while the physical receive path is peer-clocked by the incoming forwarded strobe (`sb_rx_clk`). Verification uses literal normative golden vectors and an independent peer BFM that does not reuse RTL encode/decode logic.

## Approach

### 1. Establish one normative packet contract

1. Transcribe the exact Figure 100 through Figure 103 header bit maps from the embedded figures in `UCIE.pdf` (the figure images are normative), cross-check field widths and opcode rules against `UCIE.md:5917-6195`, and record the bit positions as package constants. Do not infer positions from the current `sb_codec.sv` layout.
2. Replace the two private packet layouts with one semantic packed type in `rtl/rtl_common/ucie_pkg.sv`:
   - `sb_packet_kind_t`: register request, completion, message without data, message with data.
   - `sb_completion_status_t`: Successful Completion `3'b000`, Unsupported Request `3'b001`, Completer Abort `3'b100`, and Stall `3'b111`.
   - `sb_packet_t`: `opcode[4:0]`, `src_id[2:0]`, `dst_id[2:0]`, `msg_info[15:0]`, `msg_code[7:0]`, `msg_subcode[7:0]`, `cr`, `addr[26:0]`, `be[7:0]`, `tag[4:0]`, `ep`, `status[2:0]`, and `data[63:0]`.
   - `sb_packet_t` has no payload-width member. Every producer and consumer derives the byte count only with `sb_payload_bytes(opcode)`.
3. Add named constants for every Table 47 opcode and the exact Table 48 and Table 49 context-specific IDs. Do not reuse one destination constant across FDI and physical-link contexts. Keep `SB_CRD_MAX = 4` as the fixed-profile remote register capacity.
4. Add pure package helpers `sb_packet_kind(opcode)`, `sb_payload_bytes(opcode)`, `sb_opcode_supported(opcode)`, `sb_encode_header(packet)`, and `sb_decode_header(header)`. Make opcode determine legal payload size. Do not retain a caller-controlled `has_data` override.
5. Define the supported subset exactly:
   - Accept 32-bit and 64-bit configuration reads and writes.
   - Accept no-data and 64-bit messages used by PHY training, RDI LinkMgmt including L1/L2-to-PMNAK rejection, Adapter capability, Adapter0 LinkMgmt including L1/L2-to-PMNAK rejection, and error handling.
   - Accept no-data, 32-bit-data, and 64-bit-data completions.
   - Decode all 32-bit and 64-bit memory request opcodes and return Unsupported Request rather than treating them as malformed packets.
   - Reject reserved opcodes, illegal reserved fields, impossible opcode/payload combinations, and IDs illegal for the packet's ingress context through one explicit decode-error result.
6. Compute CP and DP from the normative type-specific bit layouts. CP excludes only the fields specified by the applicable packet format. A 32-bit payload occupies a 64-bit physical payload packet with bits `[63:32]` zero and DP over the transmitted 64 bits.
7. Remove obsolete reduced-width opcode, address, and MsgInfo aliases after every caller moves to `sb_packet_t`; do not keep compatibility encoders.

If Icarus Verilog 12 rejects a package function that returns `sb_packet_t`, keep `sb_packet_t` at module boundaries and implement the same helpers with package bit-position constants plus output arguments. Do not duplicate bit layouts in multiple modules.

### 2. Replace the physical codec and public pins

1. Refactor `rtl/logical_phy/sb_codec.sv` to accept and produce `sb_packet_t` with `tx_valid/tx_ready` and `rx_valid/rx_ready` semantics. Preserve one accepted transaction until every physical packet and mandatory gap completes.
2. Serialize one scalar bit per sideband UI, least-significant bit first. Send the 64-UI header, then 32 low UIs. If the opcode has data, send one padded 64-UI payload packet, then another 32 low UIs. A no-data transaction ends after the header gap.
3. Decode transaction length only from the opcode. Detect truncated phases, reserved opcodes, CP errors, DP errors, and nonzero upper payload bits for 32-bit data. Return separate `rx_format_error`, `rx_cp_error`, and `rx_dp_error` indications with the decoded packet.
4. Change `rtl/ucie_main.sv` and `rtl/logical_phy/logical_phy.sv` from the NC-wide bus-and-valid interface to:
   - input `sbclk` as the die's own local 800 MHz transmit source clock (not shared across dies).
   - output scalar `sb_tx_clk`.
   - output scalar `sb_tx_data`.
   - input scalar `sb_rx_clk`.
   - input scalar `sb_rx_data`.
   Remove the public sideband-valid pins.
5. Make one strobe owner toggle `sb_tx_clk` only during each 64-UI header or payload packet. Park `sb_tx_clk` and `sb_tx_data` low during every 32-UI gap and while idle. Launch TX data on rising edges and sample RX data on falling edges of `sb_rx_clk`.
6. Keep `sb_init_raw.sv` as the raw SBINIT owner. Use the same scalar strobe/data owner in raw and packet modes, including gated strobe behavior outside active SBINIT data. Preserve the boundary-safe raw-to-packet reset sequence.
7. Run TX serialization from local `sbclk` and RX deserialization from peer-clocked `sb_rx_clk`. Keep independent `sb_cdc_mailbox` crossings from `lclk` to TX and from RX to `lclk`. Dual-die simulation topologies drive each die from independent generators: Die0 startup delay 0.1875 ns, Die1 startup delay 0.4375 ns, half-period 0.625 ns, fixed relative phase 0.250 ns, and no modeled frequency drift.
8. Replace the single RX hold register with a two-entry RX queue before the RX CDC mailbox. If both entries are full when a transaction completes, assert a sticky overflow error and route it to the fatal sideband error policy.
9. Keep one physical codec, one strobe owner, and one gap owner. Delete the Adapter-side imitation of physical serialization.

### 3. Build the Logical PHY packet router and arbiter

1. Replace `SB_TX_W`, `SB_RX_W`, and all flat LTSM codec bundles in `rtl/logical_phy/logical_phy.sv` with `sb_packet_t` channels. Preserve the mailbox acceptance guarantee, but define acceptance as a successful enqueue into the selected TX queue.
2. Add private Adapter-client ports between `d2d_adapter` and `logical_phy` through `ucie_main`:
   - Adapter to PHY: `adapter_sb_tx_valid`, `adapter_sb_tx_ready`, `adapter_sb_tx_packet`.
   - PHY to Adapter: `adapter_sb_rx_valid`, `adapter_sb_rx_ready`, `adapter_sb_rx_packet`.
   - Error/event returns: `adapter_sb_rx_cp_error`, `adapter_sb_rx_dp_error`, and `adapter_sb_rx_format_error` aligned with the received event.
3. Keep the PHY LTSM as the owner of PHY training and LinkMgmt.RDI policy. Convert its existing flat packet fields at the `logical_phy` boundary into `sb_packet_t`. Add exact Req.L1, Req.L2, and Rsp.PMNAK decoding and response obligations, but do not make the LTSM own Adapter capability, mailbox, or CSR policy.
4. Decode packet fields structurally, then validate them by physical-link ingress:
   - Accept physical sources Adapter `001` or PHY `010` only with remote destination indication `dst_id[2]=1`.
   - Route PHY training and LinkMgmt.RDI messages by physical message destination to `ltsm`.
   - Route physical Adapter capability and Adapter0 messages to the Adapter client.
   - Route completion destination `3'b101` to the Adapter client and match it there by Tag.
   - Route every physical register request to the Adapter client for hierarchical address and mailbox handling; physical request destination low bits are reserved and do not select PHY versus Adapter.
   - Route illegal IDs, reserved fields, and invalid message destinations to the sideband fatal-error path.
5. Add one TX arbiter with this non-starving priority:
   1. Required completions and mandatory peer responses.
   2. Pending credit returns.
   3. Existing pending PHY LTSM responses.
   4. Adapter Stage 3 and Adapter0 responses.
   5. New PHY or Adapter requests, alternating between clients after each grant.
   Hold a selected packet until the TX mailbox accepts it. Never clear an obligation on presentation alone.
6. Do not own remote register credits or Tags in `logical_phy`. Forward the Adapter packet and acceptance event unchanged so `adapter_sb_if` remains the single owner of the four-entry remote-request table.
7. Never credit-gate messages or completions. Provision an independent always-sink message path and completion path around the Adapter request slots.
8. Route codec format, CP, DP, RX overflow, and illegal-routing errors into the existing fatal sideband policy and RDI LinkError publication. Preserve valid PARAM, Active Entry, TRAINERROR, LinkReset, and Disabled behavior.
9. Route physical register requests through the Adapter hierarchy. The Adapter terminates Adapter CSR requests or forwards local PHY CSR work through a typed internal CSR request. Hold source, Tag, BE, EP, width, and route metadata until the target returns its result.

### 4. Replace the Adapter sideband endpoint, mailbox, credits, and CSR path

1. Refactor `rtl/d2d_adapter/adapter_sb_if.sv` into three policy boundaries that all use `sb_packet_t`:
   - Public FDI configuration phase endpoint.
   - Private Adapter-to-Logical-PHY packet client.
   - Adapter and PHY CSR request/completion endpoint.
   Remove its physical 32-UI gap logic and private header layout.
2. Expose the fixed NC=8 FDI configuration phase interface on `ucie_main` and `d2d_adapter`:
   - inputs `lp_cfg[7:0]`, `lp_cfg_vld`, `lp_cfg_crd`.
   - outputs `pl_cfg[7:0]`, `pl_cfg_vld`, `pl_cfg_crd`.
   Transmit all eight header phases and every payload phase on consecutive `lclk` cycles. Permit gaps only between complete transactions. Treat an intra-transaction gap as a format error.
3. Decode fields structurally, then validate by FDI ingress:
   - Accept only Stack0 register requests and completions.
   - Route requests with FDI destination `3'b001` to the local Adapter CSR target and `3'b010` to the local PHY CSR target.
   - Route FDI completions by the saved Tag because completion IDs are reserved.
   - Reject FDI messages and every other FDI destination.
4. Implement the Table 70 through Table 73 Sideband Mailbox Index, Data, Control, and Status registers in `adapter_regfile.sv`. FDI cannot directly name a remote destination. A mailbox Control trigger creates the typed remote register request. Its terminal completion updates mailbox Data and Status by Tag and clears the trigger. FDI accesses that program or poll the mailbox receive separate local completions.
5. Initialize independent FDI TX and RX request capacities to four on reset. Reserve and decrement one RX slot only for a register request at phase 0. Return one `pl_cfg_crd` only when that request slot is freed. Increment TX request credits on `lp_cfg_crd`, saturate at four, and provide separate unconditional completion storage.
6. Make `adapter_sb_if` the sole owner of one four-entry table and counter for every remote register request, including memory opcodes. Consume a credit only when `logical_phy` accepts the request into its TX queue. Never charge messages or completions. Forward received Cr and NOP.Crd events to the Adapter and saturate the available count at four.
7. Provision four inbound physical register-request slots plus independent always-sink message and completion paths. Return a freed inbound request slot through one pending Cr bit on an outgoing packet or an explicit NOP.Crd when no packet is pending.
8. Replace the simple CSR pulse bus with held request metadata. Latch address, access width, data, BE, Tag, EP, source, and route until the target returns read data or completes a write.
9. Update `adapter_regfile.sv` and `phy_csr.sv` to accept `csr_be[7:0]` and merge enabled bytes on writes. Preserve hardware-set and private-clear priority. Keep one-cycle reads and return an explicit success/error result.
10. Build completions exactly from the request and result:
   - Copy Tag and BE.
   - Use no-data Successful Completion for writes.
   - Use DATA32 or DATA64 Successful Completion for reads.
   - Use DATA64 with the original request header as payload for Unsupported Request and Completer Abort.
   - Use no data for Stall and timeout Unsupported Request.
   - Set completion EP to zero because local Adapter and PHY CSRs do not produce poisoned data. Do not echo request EP into a completion.
11. A Stall completion resets only its request timer and retains its Tag/table entry. Only Successful Completion, Unsupported Request, Completer Abort, or Reset retires the entry. Report unmatched or duplicate terminal completions as protocol errors.
12. Decode memory requests as valid but unsupported. Remote memory requests consume a remote-request slot and return Unsupported Request without touching a register file.

### 5. Implement reduced-profile Adapter Stage 3 and Adapter0 state messaging

1. Make `adapter_sb_if.sv` own the reduced-profile Adapter LSM because it already owns Adapter sideband policy, timers, and the state-request output. Do not move this policy into `logical_phy`.
2. Start Stage 3 only after RDI reports Active. Build the local AdvCap.Adapter DATA64 payload with `Raw_Mode=1`, `Streaming=1`, and `Stack0_Enable=1`; the resulting selected capability mask is `64'h0000_0000_0000_0091`.
3. Send AdvCap.Adapter independently from both dies. For regular AdvCap.Adapter, require `MsgInfo=16'h0000`, clean CP and DP, `Data[63:23]=0`, `(Data & 64'h91) == 64'h91`, `Data[11]=0`, and `Data[20:12]=0`. Intersect with local `64'h91` and negotiate exactly Streaming, Raw Mode, and Stack0. Treat `MsgInfo=16'hFFFF` only as Stall; it resets the capability timer and does not complete negotiation. Send no FinCap message for this Streaming profile.
4. Use separate true 8 ms timers:
   - Capability timer until a valid AdvCap exchange completes.
   - One timer per outstanding remote register request.
   - Adapter0 timer from Req.Active enqueue until reciprocal Active obligations complete.
   Count Adapter timers only while RDI is Active. A matching Stall resets only its transaction timer. A register timeout returns no-data Unsupported Request to its origin. Capability or Adapter0 timeout asserts Adapter LinkError.
5. Add FDI `pl_protocol_vld`, `pl_clk_req`, `lp_clk_ack`, `lp_wake_req`, `pl_wake_ack`, `pl_speedmode`, and `pl_lnk_cfg` through `ucie_main`, `d2d_adapter`, `fdi_state_machine`, and the BFMs. In always-awake mode, hold `pl_clk_req` high, wait for a registered `lp_clk_ack`, and register `pl_wake_ack` one cycle after `lp_wake_req`.
6. Assert `pl_protocol_vld` with `pl_protocol=PROTO_STREAMING`, `pl_protocol_flitfmt=FMT_RAW`, fixed speed, and fixed x16 configuration only after capability resolution. Hold the result until RDI returns to RESET. Assert `pl_inband_pres` only after capability resolution and the clock acknowledgment.
7. After capability resolution, protocol-valid, in-band presence, and clock acknowledgment, assert `pl_rx_active_req` when either local Active or peer Req.Active is pending. Wait at least one cycle for `lp_rx_active_sts`, then send any owed Rsp.Active. Publish FDI Active only after the local request receives its response and every peer-response obligation completes. On graceful exit, lower `pl_rx_active_req` and wait for `lp_rx_active_sts=0` before publishing the next state.
8. Add private `rdi_lp_linkerror = lp_linkerror | adapter_fatal` and give it priority to enter and hold RDI LinkError. Change public `lp_linkerror` to a Protocol-Layer input and remove the current output tie-off.
9. For local or peer LinkReset and Disabled, complete the FDI Stallreq/Ack and receiver-active exit, retain separate Req/Rsp obligations, and exchange the matching Adapter0 messages with an 8 ms timer. Publish the Adapter state after its obligations complete, then request the same RDI state. Give Disabled priority over LinkReset and enter LinkError on timeout.
10. Preserve reduced PM capability with complete rejection messaging:
   - A local FDI L1 or L2 request sends the matching LinkMgmt.Adapter0 request. The peer responds Rsp.PMNAK, both Adapter LSMs remain Active, and the requester publishes PMNAK until the Protocol Layer withdraws the request.
   - A received Adapter0 L1 or L2 request always creates a retained Rsp.PMNAK obligation.
   - A local RDI L1 or L2 request sends the matching LinkMgmt.RDI request. A received RDI L1 or L2 request always creates a retained Rsp.PMNAK obligation. Neither flow enters `LT_L1L2` or changes the LTSM from Active.
   - Test every local-request and peer-request role. Do not add power-saving circuits.
11. Repeat capability negotiation and Adapter0 Active Entry after every RDI RESET.

### 6. Migrate every caller in one clean cutover

1. Update `rtl/ucie_main.sv` to expose scalar physical sideband pins, public FDI cfg and clock/wake ports, `pl_protocol_vld`, fixed speed/link configuration outputs, and input `lp_linkerror`. Add the private typed Adapter packet channels between `u_adapter` and `u_lphy`.
2. Update `rtl/d2d_adapter/d2d_adapter.sv`, `fdi_state_machine.sv`, `adapter_sb_if.sv`, and `adapter_regfile.sv` to the new ownership and handshakes. Remove dormant timer hooks, dead state-request stubs, old header registers, and old credit counters.
3. Update `rtl/logical_phy/logical_phy.sv`, `sb_codec.sv`, `sb_init_raw.sv`, `ltsm.sv`, `phy_csr.sv`, and `rdi_state_machine.sv` to use the canonical packet boundary, scalar strobe pins, and private Adapter LinkError input. Keep PHY LTSM policy unchanged except for field-width migration and routed packet acceptance.
4. Update all direct instantiations found in the workspace:
   - `ucie_main` instances `dut_a` and `dut_b` in `tb/loopback/tb_loopback_top.sv`.
   - direct `logical_phy` instance in `tb/unit/ut_sbinit.sv`.
   - direct `d2d_adapter` instance in `tb/unit/ut_stall.sv`.
   - direct `fdi_state_machine` instance in `tb/unit/ut_fdi_sm.sv`.
   - direct `rdi_state_machine` instance in `tb/unit/ut_rdi_sm.sv`.
   - every direct `sb_codec` instance in `tb/unit/ut_sb_codec.sv` and `tb/unit/ut_ltsm.sv`.
   - LTSM instances in `tb/unit/ut_ltsm.sv` and `tb/unit/ut_ltsm_policy.sv`.
   - CDC packet bundles in `tb/unit/ut_sb_cdc.sv`; size them from `$bits(sb_packet_t)` plus aligned error bits and remove numeric packet widths.
5. Cross-connect `dut_a.sb_tx_data/sb_tx_clk` to `dut_b.sb_rx_data/sb_rx_clk` and vice versa. Drive each die from its own independent nominal 800 MHz TX generator (Die0 startup delay 0.1875 ns, Die1 startup delay 0.4375 ns, half-period 0.625 ns, fixed relative phase 0.250 ns, no modeled frequency drift) rather than sharing a single local sideband clock source. Remove legacy NC bus and valid wires with no wrapper or compatibility alias.
6. Update each modified RTL and test header revision entry and each affected construct comment with the applicable UCIe subsection. Do not change `doc/PLAN.md` as part of this implementation.

### 7. Add independent conformance verification before changing coverage gates

1. Add `tb/bfm/sideband_golden_pkg.sv` as an independent literal-vector package. It must not import `ucie_pkg` or call RTL helpers. Define `sideband_golden_t` with literal semantic inputs (`opcode`, IDs, MsgInfo, MsgCode, MsgSubcode, Cr, address, BE, Tag, EP, status, data, and payload-byte count) and literal expected outputs (`header[63:0]`, `payload[63:0]`, packet UI count, and decode-error expectation).
2. Populate a constant `SIDEBAND_GOLDEN[]` array from `UCIE.pdf` Figures 100 through 103 and Tables 47 through 56. Include:
   - every supported configuration request and completion opcode.
   - every memory request opcode with expected Unsupported Request behavior.
   - no-data and DATA64 messages for PARAM, AdvCap.Adapter, RDI Active, Adapter0 Active, Adapter0 and RDI L1/L2-to-PMNAK, TRAINERROR, LinkReset, and Disabled.
   - minimum and maximum field values, non-contiguous BE, all Tag bits, EP, Cr, clean and corrupt CP/DP, reserved opcode, and 32-bit zero-padding cases.
3. Rewrite `tb/unit/ut_sb_codec.sv` so its primary scoreboard compares raw scalar TX bits and timing directly with `SIDEBAND_GOLDEN`. Keep a DUT-to-DUT round trip only as a secondary smoke case. Assert the constant array has the expected case count so accidental vector removal fails the test.
4. Add `tb/bfm/sideband_peer_bfm.sv`. Implement independent literal bit extraction/packing from the specification figures. The BFM must not import `ucie_pkg` or any RTL package. Define literal opcodes, IDs, message values, capability payloads, field positions, and timing locally from UCIe. Pass only clocks, reset, and physical pins through ports.
5. Add `tb/loopback/tb_sideband_peer.sv` with one `ucie_main` endpoint and the independent peer BFM. Prove:
   - raw SBINIT to packet-mode transition.
   - PHY PARAM and LinkMgmt.RDI exchanges.
   - AdvCap.Adapter negotiation without FinCap for Streaming.
   - Adapter0 Active Entry and `pl_protocol_vld` ordering.
   - one local Adapter CSR read/write and one local PHY CSR read/write.
   - one remote Adapter configuration read/write with Tag, BE, EP, and completion correlation.
   - memory request Unsupported Request completion.
   - CP, DP, format, invalid-route, unmatched-completion, and RX-overflow escalation.
   - exactly four outstanding remote requests, credit exhaustion, credit return, saturation, completion bypass, and non-starved message progress.
   - local and peer L1/L2 requests at both Adapter0 and RDI boundaries, each completed by PMNAK without entering a PM state.
6. Add `tb/unit/ut_adapter_sb_if.sv` for NC=8 cfg phases. Drive header and payload phases on consecutive cycles, insert gaps only between transactions, and exercise intra-transaction gap rejection, dedicated `lp_cfg_crd/pl_cfg_crd`, partial-byte writes, delayed read response, all completion statuses, and receiver backpressure.
7. Update `tb/loopback/tb_loopback_top.sv` so the two-DUT smoke run waits for observed Stage 3 and Adapter0 completion. Remove constant capability evidence and the comment that LinkMgmt transport is supplied by the testbench.
8. Extend `tb/monitors/cov_monitor.sv` and `sim/cov_report.py` with exact bins for packet kind, each supported opcode, memory-UR handling, route, source/destination class, payload width, CP/DP clean and error, Tag/BE correlation, completion status, Cr, FDI credit return, remote credit exhaustion/return/saturation, Stage 3, Adapter0 Active, protocol-valid ordering, and Adapter0/RDI L1/L2-to-PMNAK request and response roles. Do not count a single coarse transaction flag as sideband conformance.
9. Update `sim/Makefile` with explicit `sideband-unit` and `sideband-peer` targets. Add both to `all` before the existing two-DUT loopback and coverage targets. Keep zero-warning compilation and exact `TEST PASSED <name>` markers.

## Critical files and anchors

- `rtl/rtl_common/ucie_pkg.sv` — sideband opcode/ID constants near the current Sideband Opcodes section and fixed profile constants; this becomes the only packet-layout source.
- `rtl/logical_phy/logical_phy.sv` — `SB_TX_W/SB_RX_W`, CDC mailboxes, `u_sb_codec`, raw/packet pin mux, cfg stubs, and `u_phy_csr`; this becomes the router and arbiter owner.
- `rtl/d2d_adapter/adapter_sb_if.sv` — current private parser, dormant credits/timers, and broken CSR completion builder; replace these with FDI phases, Adapter client policy, and Stage 3.
- `rtl/ucie_main.sv` — public ports plus `u_adapter` and `u_lphy`; this is the clean-cutover boundary for scalar physical pins, public FDI cfg, and private packet channels.
- `tb/unit/ut_sb_codec.sv` — current same-codec round trip; convert it to literal raw-wire vector proof before trusting integration results.

## Verification

Run all commands from the repository root in WSL.

1. Run the packet and Adapter phase units:

```text
wsl.exe make -C sim sideband-unit
```

Expected results:

- Zero compile warnings.
- Exact literal headers, payloads, CP, DP, bit order, and 32-UI gaps pass.
- Configuration requests and all completion forms pass.
- Memory requests produce Unsupported Request.
- NC=8 FDI phases, partial writes, Tags, credits, and delayed CSR responses pass.
- Output contains the exact test markers for the codec and Adapter sideband tests.

2. Run the independent peer scenario:

```text
wsl.exe make -C sim sideband-peer
```

Expected observable sequence:

```text
SBINIT COMPLETE
RDI ACTIVE
ADVCAP ADAPTER COMPLETE
PROTOCOL VALID: STREAMING RAW
ADAPTER0 ACTIVE COMPLETE
FDI ACTIVE
REMOTE ADAPTER CSR PASS
REMOTE PHY CSR PASS
MEMORY REQUEST UR PASS
SIDEBAND CREDIT/ERROR CASES PASS
TEST PASSED tb_sideband_peer
```

The test must fail if it observes FinCap for the selected Streaming profile, data before FDI Active, a completion with the wrong Tag or BE, more than four outstanding remote requests, a message starved behind register traffic, a parity/format error without LinkError escalation, or an L1/L2 request that enters a PM state instead of completing with PMNAK.

3. Run the existing complete regression after the independent proof:

```text
wsl.exe make -C sim clean && make -C sim all
```

Expected results:

- `COMPILE OK` with no warnings.
- `ALL UNIT TESTS PASSED`.
- `SIDEBAND PEER OK`.
- `LOOPBACK OK` after both dies complete Stage 3.
- Coverage reports every required fixed-profile sideband bin and no unsupported-state holes.

4. Inspect `sim/logs/coverage.json` and the sideband peer log. Confirm nonzero evidence for every fixed-profile packet class, all selected opcodes, SC/UR/CA/Stall decode, local and remote routes, CP/DP error paths, four-credit exhaustion and recovery, AdvCap, Adapter0 Active, and `pl_protocol_vld` ordering.

## Assumptions and contingencies

- The fixed profile uses NC=8 on FDI configuration phases. NC=16 and NC=32 are legal standard options but are not required by this endpoint profile.
- Memory accesses are recognized standard packets but unsupported endpoint operations. They always complete with Unsupported Request and never reach a register file.
- The endpoint has no Retimer. It decodes Stall status and capability Stall messages and resets the applicable timeout, but it does not originate Retimer Stall keep-alives.
- Streaming negotiation advertises Raw Mode, Streaming, and Stack0 only. It sends no FinCap message because UCIe 1.0 makes the Streaming Raw result implicit when PCIe, CXL, and vendor extensions are absent.
- `sbclk` remains each die's own nominal 800 MHz TX source rather than a shared local sideband clock across dies. The sideband engine gates it onto `sb_tx_clk` only for active 64-UI packets and parks the strobe low during gaps and idle. `sb_rx_clk` independently clocks the physical receive path from the peer's forwarded strobe. Dual-die simulation generators model Die0 startup delay 0.1875 ns, Die1 startup delay 0.4375 ns, half-period 0.625 ns, fixed relative phase 0.250 ns, and no modeled frequency drift. Analog clock quality is outside scope.
- The typed Adapter packet client is a private implementation channel selected for maintainability. Public FDI cfg phases and physical serial pins remain standard-shaped; no legacy bus-and-valid wrapper remains.
- `doc/PLAN.md:1154-1159` limited new files for the completed A–F project phases. This remediation is a new task. It adds only the independent golden package, peer BFM, peer test, and focused Adapter sideband test needed for the selected verification strategy.

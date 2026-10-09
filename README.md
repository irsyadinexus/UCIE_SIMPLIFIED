# UCIE 1.0 Synthesizable RTL With Reduced Capability for Proof of Concept Implementation

This repository contains a synthesizable SystemVerilog implementation of a Universal Chiplet Interconnect Express (UCIe) 1.0 endpoint with reduced capability for proof of concept implementation.

## Specifications Documentation
- `UCIE.pdf`: The main specification document as the single source of truth (UCIe 1.0 Specification).
- `UCIE_PoC.pdf`: The proof of concept specification document.
- `UCIE.md`: Markdown documentation version of the specification.

## Implementation Scope
- **Raw Mode**: Supported.
- **Streaming Protocol**: Supported (Raw Mode Format 1 direct pass-through without flit headers or sequencing, verified with 512B, 1024B, and 2048B bidirectional streaming transfers carrying incrementing, decrementing, and all-ones payloads).
- **Standard Package**: Supported (x16 single-module).
- **Advanced Package**: Not supported.
- **Module**: Only 1 module supported.
- **Protocol Layer**: Only 1 protocol layer supported.
- **CXL Protocol**: Not supported.
- **PCIe Protocol**: Not supported.
- **Retimer**: Not supported.
- **Runtime PHY Retrain**: Not supported.
- **Runtime Power Management (L1 / L2)**: Not supported.
- **Electrical PHY**: Not supported (implements negotiated parameters and digital logic, no analog circuitry).
- **Sideband Frequency**: 800 MHz SDR (spec accurate). Features asynchronous Clock Domain Crossing (CDC) mailboxes between the 500 MHz `lclk` domain and the 800 MHz `sbclk` physical codec domain.
- **Mainband Frequency**: The continuous-only x16 profile uses a 2 GHz forwarded clock, 4 GT/s DDR transfers, and a 500 MHz `lclk`.
- **Mainband Clock Interface**: Each endpoint keeps one local input, `mbclk`. The source must run at 2 GHz before hardware reset release. It must remain stable throughout operation. The controller returns source-domain reset readiness internally. It does not measure PLL lock or source health.
- **Directional Mainband Pins**: `mb_tx_clk` drives the peer `mb_rx_clk`. Scalar `mb_tx_clk_oe`, `mb_tx_data_oe`, and `mb_tx_valid_oe` describe pad drive permission. RESET, SBINIT, PARAM, and CAL disable the pads. Enabled electrical idle holds the clock, data, and Valid low.
- **Mainband Clock Policy**: RXCLKCAL peer requests control local clock start and stop. Responses wait for physical run-state acknowledgment. LINKSPEED, LINKINIT, and Active use a continuous clock, including Active Valid-low gaps. Strobe mode is not supported.
- **Mainband CDC**: Depth-eight Gray FIFOs cross complete words in both directions. TX full applies RDI backpressure. RX overflow enters the existing fatal policy. LINKINIT prepares a quiet receive epoch before the Active handshake. Ordinary stalls preserve accepted words.
- **Mainband Digital Limits**: Independent source phases are supported at the exact nominal rates. The model does not compensate for indefinite frequency drift. `mb_ddr_io` models dedicated DDR cells. Hardware must map this boundary to characterized DDR and clock-gate cells. Scalar pins and OEs do not prove analog compliance.
- **RDI / Adapter Clock (`lclk`)**: 500 MHz (exact bandwidth match: 16 bytes @ 500 MHz = 64 Gbps for x16 @ 4 GT/s).
- **Standard Package Width**: x16 only (no runtime x8 degrade negotiated on the main line; the byte-to-lane mapper implements both x8 degrade halves and is verified by directed unit test).
- **Data Width**: Parameterized `NBYTES`, default 16 bytes (128 bits), on both FDI and RDI.
- **Data Link**: No CRC, no retry/replay, no sequence numbers (legal at 4 GT/s Raw Mode).
- **Sideband Packet**: Standard 64-bit header (UCIe 1.0 Figures 100–103), 32-UI inter-packet gap, optional 64-bit payload (DATA64 / 32-bit zero-padded) followed by 32-UI gap, serialized over scalar physical pins (`sb_tx_clk`, `sb_tx_data`, `sb_rx_clk`, `sb_rx_data`) with 800 MHz SDR forwarded strobe clocking and falling-edge sampling.
- **Physical Layer RESET**: Physical Layer stays in RESET for a spec-mandated minimum of 4 ms upon every entry to RESET (UCIe 1.0 Section 4.5.3.1).
- **LinkError Remediation (UCIe 1.0 Section 8.3.2.7)**:
  - Minimum residency dwell satisfaction: Dwell is satisfied immediately if a validated sideband LinkError handshake completes; otherwise, an unscaled 8 ms residency timer (`u_linkerror_timer`, `C_RESIDENCY` = 4,000,000 `lclk` cycles) serves as a fallback to satisfy dwell and allow recovery without peer sideband acknowledgment.
  - Direct transition to RESET: LinkError exits directly to RESET without passing through LinkReset (UCIe 1.0 Figures 111, 119, 126).
  - Response draining prior to reset.
- **Timer Constants**: 4 ms RESET minimum, 8 ms residency/message timeouts, and 4 ms stall keep-alive are implemented at true spec physical values in `rtl/rtl_common/timer.sv` calibrated to `lclk` = 500 MHz; no RTL timer constant is divided for simulation speed.

### Continuous-profile PHY registers

The PHY keeps the existing simplified CSR map and adds explicit continuous-only fields at the standard offsets.

| Offset | Register | 64-bit read value |
|---|---|---|
| `1000h` | PHY Capability and adjacent Control | `00000020_00009000h` |
| `1004h` | PHY Control | `00000000_00000020h` |
| `1008h` | PHY Status | `00000000_00000020h` |

Writes cannot select strobe mode. They leave these fixed fields unchanged, consistent with the existing simplified write-ignore policy.
The legacy Start and electrical-parameter registers remain writable.

## Topology & Module Hierarchy

Implemented synthesizable SystemVerilog module tree (compiled with `-g2012 -Wall` and zero warnings under Icarus Verilog 12.0):

```
rtl/ucie_main.sv        (Top-level endpoint)
rtl/rtl_common/         ucie_pkg.sv, scrambler.sv, timer.sv
rtl/d2d_adapter/        d2d_adapter.sv, fdi_state_machine.sv,
                        adapter_datapath.sv, adapter_regfile.sv,
                        adapter_sb_if.sv
rtl/logical_phy/        logical_phy.sv, rdi_state_machine.sv, ltsm.sv,
                        sb_codec.sv, sb_init_raw.sv, sb_cdc_mailbox.sv,
                        pattern_gen.sv, byte_lane_mapper.sv,
                        mb_gearbox.sv, mb_async_fifo.sv,
                        mb_tx_clock_ctrl.sv, mb_ddr_io.sv, phy_csr.sv
```

Structural block hierarchy:

```
UCIE Main (ucie_main.sv)
  |-- D2D Adapter (d2d_adapter.sv)
  |     |-- FDI State Machine (spec 8.2 / Table 115)
  |     |-- Streaming Pass-Through Datapath (adapter_datapath.sv)
  |     |-- Adapter Register File (adapter_regfile.sv: Link Control/Status, Error Log)
  |     `-- Adapter Sideband Interface (adapter_sb_if.sv: lp_cfg/pl_cfg, Stage 3 AdvCap negotiation)
  `-- Logical PHY (logical_phy.sv)
        |-- RDI State Machine (spec 8.1 / Table 114)
        |-- LTSM Sequencer (ltsm.sv: all 24 state encodings; 21 reachable in this scope, including TRAINERROR)
        |-- LinkError Residency Timer (u_linkerror_timer: 8 ms C_RESIDENCY unscaled per Section 8.3.2.7)
        |-- Sideband Codec (sb_codec.sv: 64-bit header, CP/DP parity, scalar physical pins)
        |-- Raw SBINIT Detector & Driver (sb_init_raw.sv: 4.5.3.2 Standard Package SBINIT primitive)
        |-- Sideband CDC Mailboxes (sb_cdc_mailbox.sv: 500 MHz lclk <-> 800 MHz sbclk)
        |-- Training Pattern Generator (pattern_gen.sv: Per-Lane-ID, VALTRAIN, clock repair, LFSR)
        |-- Mainband DDR Gearboxes and Word FIFOs (local TX source / peer RX clock)
        |-- Mainband Clock Controller (coherent requests, scalar OEs, safe full pulses)
        |-- DDR Cell Boundary (mb_ddr_io.sv: physical launch and paired capture)
        |-- Byte-to-Lane Mapper (byte_lane_mapper.sv: x16 and both x8 degrade halves)
        |-- Independent TX/RX Scramblers (scrambler.sv: RX reseed during LINKINIT preparation; TX reseed at local Active entry)
        `-- PHY CSR (phy_csr.sv: electrical parameters, byte enables, no analog)
```

## Verification Suite

Verification environment under Icarus Verilog 12.0 (`make -C sim all`):

```
tb/unit/          Directed unit testbenches for FSMs, datapath blocks, and protocol policy:
                  - ut_fdi_sm.sv        (FDI state machine transitions & LinkError direct RESET exit)
                  - ut_gearbox.sv       (DDR order, singleton recovery, full backpressure, stopped clock, RX overflow)
                  - ut_mb_async_fifo.sv (asynchronous FIFO ordering, wrap, full/empty, coordinated reset)
                  - ut_mb_clock.sv      (physical clock start/stop, precondition, OEs, DDR cell boundary)
                  - ut_lfsr.sv          (PRBS-23 training pattern generator)
                  - ut_ltsm.sv          (LTSM sequencer walk, timeouts, recovery)
                  - ut_ltsm_policy.sv   (protocol policy, LinkError dwell, directional RXCLKCAL, source readiness)
                  - ut_mapper.sv        (x16 / x8 byte lane mapping and lane reversal)
                  - ut_pattern_gen.sv   (Training pattern generator mux and LFSR)
                  - ut_rdi_sm.sv        (RDI state machine transitions & direct RESET exit)
                  - ut_sb_cdc.sv        (Sideband CDC mailbox bidirectional transport)
                  - ut_sb_codec.sv      (Sideband packet serialization / deserialization)
                  - ut_sbinit.sv        (Raw SBINIT waveform primitive & event detection)
                  - ut_stall.sv         (4-phase stall handshake & data gating)
tb/bfm/           Protocol layer BFM (protocol_layer_bfm.sv), independent scalar sideband peer
                  (tb_sideband_peer.sv), literal golden vectors (sb_golden_vectors.sv),
                  and Adapter sideband testbench (tb_adapter_sideband.sv).
tb/loopback/      Dual-die top-level testbench (tb_loopback_top.sv): two real ucie_main instances
                  with crossed sideband and mainband pins, testing end-to-end training,
                  bidirectional Raw Mode streaming, and fault injection recovery.
tb/waveform/      RESET-to-ACTIVE waveform testbench (tb_link_init_wave.sv): 512B random,
                  512B incrementing (after LinkReset), 1024B decrementing (after LinkError),
                  and 2048B all-ones (after Disabled) bidirectional streams, plus Figure 125
                  LinkReset, Figure 126 LinkError, and Section 8.3.2.6/8.3.2.8 Disabled flows
                  (Die 0 via lp_state_req, Die 1 via sideband, Die 1 never requests DISABLED).
tb/sbinit/        RESET-to-SBINIT waveform testbench (tb_reset_to_sbinit.sv).
tb/monitors/      Coverage monitor (cov_monitor.sv) exporting LTSM/RDI states and Phase F events as JSON.
sim/              Makefile test driver and multi-source coverage aggregator (cov_report.py).
scripts/          Automated compliance and construct checking scripts.
```

### Coverage & Pass Criteria
- **100% Reachable State Coverage**: All 21 reachable LTSM states (`00h`–`11h`, `14h`, `15h`, `16h` `TRAINERROR`) are visited and verified. Documented unreachable states (`12h` `MBTRAIN.REPAIR`, `13h` `PHYRETRAIN`, `17h` `L1L2`) are excluded from the denominator.
- **Phase F Functional Event Coverage**: All functional event counters (PARAM roles, arbitration, fatal causes, TRAINERROR, LinkReset, Disabled, PMNAK, Active Entry, pre-Active data block, scrambling, framing faults) are non-zero.
- **Zero Warnings Gate**: RTL elaborates cleanly with `-g2012 -Wall` and zero warnings under Icarus Verilog 12.0.

## Code Quality & Comment Rule Compliance

The SystemVerilog files obey the repository comment and documentation standards:
- **Header Blocks**: 50 to 500 lines per file (actual range: 50–313 lines), complete with ASCII architecture/state machine diagrams, theory of operation, and formal revision history tables.
- **Revision History**: Clean, monotonic revision logs with individual date-stamped entries describing changes.
- **Construct Documentation**: Every `always_ff`, `always_comb`, `always`, `assign` statement, and child module instantiation is immediately preceded by a detailed, spec-cited comment block (minimum 5 lines).
- **Automated Checkers**:
  ```bash
  python3 scripts/check_comment_rule.py   # Verifies headers (50-500 lines), rev history, and >=5-line construct comments
  python3 scripts/check_rtl_constructs.py # Verifies RTL construct comments
  python3 scripts/check_tb_constructs.py  # Verifies testbench construct comments
  ```

## Simulation Quick Start

Prerequisites: Icarus Verilog 12.0 (`iverilog`, `vvp`) and Python 3.

```bash
# Run the complete integration gate (compile + sideband + unit + loopback + coverage):
make -C sim clean && make -C sim all

# Run specific verification targets:
make -C sim compile         # Elaborate RTL with -Wall (zero warnings required)
make -C sim unit            # Run all directed unit testbenches
make -C sim mainband-phase  # Sweep nominal source/request phase across one mainband period
make -C sim sideband-unit   # Run focused sideband codec and SBINIT tests
make -C sim sideband-peer   # Run independent golden-vector peer test
make -C sim loopback        # Run two-die loopback bring-up and streaming test
make -C sim link-init-wave  # Generate full RESET-to-ACTIVE waveform with 512B/1024B/2048B streaming + LinkReset/LinkError/Disabled flows
make -C sim sbinit-wave     # Generate RESET-to-SBINIT waveform

# Run documentation compliance audit:
python3 scripts/check_comment_rule.py
```

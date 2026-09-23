# UCIE 1.0 Synthezisable RTL With Reduced Capability for Proof of Concept Implementation

This repository contains a synthesizable SystemVerilog implementation of a Universal Chiplet Interconnect Express (UCIe) 1.0 endpoint with reduced capability for proof of concept implementation.

## Specifications Documentation
- UCIE.pdf : the main specification document as the single source of truth
- UCIE_PoC.pdf : the proof of concept specification document but not the single source of truth. Still needs to be updated to reflect the implementation scope defined in this repository.
- UCIE.md : the markdown documentation version of the specification

## Implementation Scope
- Raw Mode : Supported
- Streaming Protocol : Supported
- Standard Package : Supported
- Advanced Package : Not supported
- Module : Only 1 module supported
- Protocol Layer : Only 1 protocol layer supported
- CXL Protocol : Not supported
- PCIE Protocol : Not supported
- Retimer : Not supported
- Electrical PHY : Not supported (Implement the negotiated parameters but not the analog circuits)
- **Sideband Frequency** : 800 MHz (spec accurate). Includes method for clock domain crossing (CDC) between lclk and sbclk datapath.
- **Mainband Frequency** : Physical interface operates as a true 4 GT/s DDR link: 2 GHz forwarded clock (fCK), DDR mainband transfer, with lclk set to 500 MHz (slowest IO data rate).
- RDI / Adapter Clock (lclk) : 500 MHz (exact bandwidth match: 16 bytes @ 500 MHz = 64 Gbps for x16 @ 4 GT/s)
- Standard Package width : x16 only (no x8 degrade negotiated on the main line;
  the byte-to-lane mapper implements both x8 degrade halves and is covered by
  a directed unit test)
- Data width : parameterized `NBYTES`, default 16 bytes, on both FDI and RDI
- Data link : no CRC, no retry/replay, no sequence numbers (legal at 4 GT/s)
- Sideband packet : 64-bit header, one bit per UI, 32-UI inter-packet gap
- **Physical Layer RESET** : Physical Layer must stay in RESET for a minimum of 4ms upon every entry to RESET, as mentioned in the spec.
- Timer constants : 4 ms RESET minimum, 8 ms residency/message timeouts, and 4 ms stall keep-alive
  are implemented at their true spec physical values in `rtl/rtl_common/timer.sv` calibrated to lclk = 500 MHz;
  no RTL timer constant is divided for simulation speed
## Topology

Implemented module tree (every file below is synthesizable SystemVerilog,
compiled with `-Wall` and zero warnings under Icarus Verilog 12.0):

```
rtl/ucie_main.sv
rtl/rtl_common/      ucie_pkg.sv, scrambler.sv, timer.sv
rtl/d2d_adapter/     d2d_adapter.sv, fdi_state_machine.sv,
                     adapter_datapath.sv, adapter_regfile.sv,
                     adapter_sb_if.sv
rtl/logical_phy/     logical_phy.sv, rdi_state_machine.sv, ltsm.sv,
                     sb_codec.sv, pattern_gen.sv, byte_lane_mapper.sv,
                     mb_gearbox.sv, phy_csr.sv
```

Verification (Icarus Verilog 12.0, `make -C sim all`):

```
tb/unit/         eight directed unit tests, one per FSM and datapath block
tb/bfm/          protocol layer BFM for the FDI stimulus side
tb/loopback/     two real `ucie_main` instances, sideband and main band both
                 crossed die-to-die
tb/monitors/     coverage counters exported as JSON (no covergroup support in
                 Icarus Verilog 12.0)
sim/             Makefile targets compile / unit / loopback / coverage / all,
                 cov_report.py reads the JSON
```

The loopback reaches LINK ACTIVE on both dies and completes Raw Mode streaming
transfers in both directions. The main band crosses the die boundary as true
DDR at 2 GHz fCK, 1 bit per lane per fCK edge, so 16 lanes move a 128-bit
word every 4 fCK cycles (Req.2). Coverage is reported over the 21 training
states the reduced capability set actually walks; `PHYRETRAIN`, `TRAINERROR`
and `L1L2` have no entry transition in this configuration and are reported as
unreachable rather than counted as holes.

- Strict Topology divided into two big modules. Other modules should be inside these two big modules.

```
UCIE Main
  |-- D2D Adapter
  |     |-- FDI State Machine (spec 8.2 / Table 115)
  |     |-- Streaming pass-through datapath
  |     |-- Adapter register file (Link Control/Status, Error Log 0/1)
  |     `-- Adapter sideband interface (lp_cfg/pl_cfg)
  |-- Logical PHY
  |     |-- RDI State Machine (spec 8.1 / Table 114)
  |     |-- LTSM (all 24 state encodings; 21 reachable in this scope)
  |     |-- Sideband codec (64-bit header, CP/DP parity)
  |     |-- Training pattern generator (Per-Lane-ID, VALTRAIN, clock repair, LFSR)
  |     |-- Main-band DDR gearbox, 500 MHz lclk <-> 2 GHz fCK (Req.2)
  |     |-- Byte-to-lane mapper (x16 and both x8 degrade halves)
  |     `-- PHY CSR (electrical parameter registers only, no analog)
  `-- no other blocks; no retimer, no protocol layer, no analog PHY
```

- Testbench emulates a protocol layer sending a reset flow to initiate link
  initialization, then exchanges data with Raw Mode streaming once the link is
  Active. Implemented in `tb/loopback/tb_loopback_top.sv`: two real `ucie_main`
  instances with the sideband and main band crossed die-to-die. Each die plays
  its own protocol layer by driving the FDI pins directly, and `tb/bfm/`
  holds a compile-clean protocol layer BFM for reuse in directed tests.

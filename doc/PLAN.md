# UCIe 1.0 Simplified Endpoint — Implementation Plan

UCIe 1.0 Rev 1.0 endpoint, reduced capability, Standard Package x16, Streaming / Raw Mode only.
Verification engine: Icarus Verilog 12.0 (`iverilog -g2012`) under WSL Ubuntu-24.04.

---

## 1. Scope and Configuration

| Item | Value | Source |
|---|---|---|
| Package | Standard Package x16 | README |
| Protocol | Streaming only (Stack 0, stream ID `04h`) | README |
| Format | Raw Mode = Format 1 | README |
| Adapter datapath | Streaming pass-through, no CRC / no retry / no DLLP | README |
| Modules | 1 module, 1 D2D Adapter, 1 protocol layer | README |
| Sideband clock | 800 MHz | README |
| Main band | 2 GHz, lclk = 1 GHz, 4 GT/s only | README |
| Timeout timers | True to spec: 8 ms sub-state residency, 4 ms RESET min, 8 ms SB message | README |
| Retimer / CXL / PCIe | Not supported | README |
| RDI/FDI data width | parameterized `NBYTES`, default 16 B | interview |
| Electrical PHY | parameter registers only, no analog | README |

Derived legal consequences (spec rules):

- 4 GT/s does **not** require Retry, so no replay buffer and no CRC engine is legal.
- Raw Mode (Format 1) is the only negotiated format, so no flit-header insertion.
- `Raw_Mode` bit must be advertised because PCIe/CXL are unsupported.
- No Advanced Package repair logic. Resilience = x8 width degrade (lanes 0-7 or 8-15).
- `lp_retimer_crd` / `pl_retimer_crd` must never assert. `Retimer` bit 11 and
  `Retimer_Credits [20:12]` are 0 in advertised capabilities.
- DP/UP bits 21/22 are kept for port identity only (cosmetic, no PCIe).

---

## 2. Module Hierarchy

```
ucie_main
 +-- d2d_adapter                        (rtl/d2d_adapter/)
 |    +-- adapter_regfile               (UCIe Link Control/Status, Error Log 0/1)
 |    +-- fdi_state_machine             (FDI LSM, spec 8.2 / Table 115)
 |    +-- adapter_datapath              (Streaming pass-through, Format 1)
 |    +-- adapter_sb_if                 (lp_cfg/pl_cfg sideband slave to PHY)
 +-- logical_phy                        (rtl/logical_phy/)
      +-- rdi_state_machine             (RDI LSM, spec 8.1 / Table 114)
      +-- ltsm                          (full LTSM, all states + sub-states)
      +-- sb_encoder / sb_decoder       (64-bit packet build/parse, CP/DP)
      +-- sb_arbiter                    (FDI vs RDI credit loops, 32-UI gap)
      +-- pattern_gen                   (Per-Lane-ID, VALTRAIN, LFSR, clock repair)
      +-- scrambler                     (per-lane LFSR, G(x) below)
      +-- byte_lane_mapper              (x16 and x8-degrade mapping, reversal)
      +-- phy_csr                       (electrical parameter registers only)
```

`ucie_pkg` in `rtl/rtl_common/` holds all enumerations, message codes, timers, and the
lane-repair seed table. It is the **single** declaration site for every constant.

Topology constraint: LTSM lives inside `logical_phy` and is **opaque** to `d2d_adapter`.
The Adapter observes training progress only through `pl_state_sts`, `pl_inband_pres`,
`pl_phyinrecenter`, and `pl_trainerror`.

---

## 3. Interface Definitions

### 3.1 RDI (spec Table 114) — Adapter <-> Physical Layer

All signals synchronous to `lclk`. `pl_*` PHY -> Adapter, `lp_*` Adapter -> PHY.

| Signal | Dir | Width | Notes |
|---|---|---|---|
| `lclk` | in | 1 | 1 GHz, SOC supplies both |
| `lp_irdy` | A->P | 1 | must be 0 while status Reset |
| `lp_valid` | A->P | 1 | data valid |
| `lp_data` | A->P | NBYTES*8 | default 128b |
| `lp_retimer_crd` | A->P | 1 | **tie 0** |
| `pl_trdy` | P->A | 1 | accept when trdy & valid & irdy |
| `pl_valid` | P->A | 1 | |
| `pl_data` | P->A | NBYTES*8 | |
| `pl_retimer_crd` | P->A | 1 | **tie 0** |
| `lp_state_req` | A->P | 4 | NOP 0 / Active 1 / L1 4 / L2 8 / LinkReset 9 / Retrain B / Disabled C |
| `lp_linkerror` | A->P | 1 | OR of FDI lp_linkerror and internal |
| `pl_state_sts` | P->A | 4 | Reset 0 / Active 1 / Active.PMNAK 3 / L1 4 / L2 8 / LinkReset 9 / LinkError A / Retrain B / Disabled C |
| `pl_inband_pres` | P->A | 1 | sticky 1 until TrainError or Reset |
| `pl_error` | P->A | 1 | framing error, pipeline-matched |
| `pl_cerror` | P->A | 1 | correctable |
| `pl_nferror` | P->A | 1 | non-fatal |
| `pl_trainerror` | P->A | 1 | fatal, forces LinkError |
| `pl_phyinrecenter` | P->A | 1 | |
| `pl_stallreq` | P->A | 1 | see Stall handshake |
| `lp_stallack` | A->P | 1 | >= 1 flop from stallreq |
| `pl_speedmode` | P->A | 3 | `000` = 4 GT/s (fixed) |
| `pl_lnk_cfg` | P->A | 3 | `010` = x16, `001` = x8 after degrade |
| `pl_clk_req` | P->A | 1 | async; 4-way handshake |
| `lp_clk_ack` | A->P | 1 | stage 1+ cycles if no gating |
| `lp_wake_req` | A->P | 1 | async |
| `pl_wake_ack` | P->A | 1 | |
| `pl_cfg` | P->A | NC | sideband, NC in {8,16,32} |
| `pl_cfg_vld` | P->A | 1 | |
| `pl_cfg_crd` | P->A | 1 | 1 credit = 64b hdr + 64b data |
| `lp_cfg` | A->P | NC | |
| `lp_cfg_vld` | A->P | 1 | |
| `lp_cfg_crd` | A->P | 1 | |

### 3.2 FDI (spec Table 115) — Protocol Layer <-> Adapter

RDI superset. Signals absent from this project are listed as **not driven**:

| Signal | Disposition |
|---|---|
| `lp_dllp`, `lp_dllp_valid`, `lp_dllp_ofc`, `pl_dllp*` | **not driven** (no DLLP path) |
| `lp_corrupt_crc`, `pl_flit_cancel` | **not driven** (no CRC) |
| `lp_nop_flit` | **not driven** (Raw Mode only) |
| `lp_retimer_crd`, `pl_retimer_crd` | **not driven** |
| `lp_stream` / `pl_stream` | driven, constant `04h` (Stack 0 Streaming) |

Used: `lclk`, `lp_irdy`, `lp_valid`, `lp_data`, `pl_trdy`, `pl_valid`, `pl_data`,
`lp_state_req`, `lp_linkerror`, `pl_state_sts`, `pl_inband_pres`, `pl_error`,
`pl_cerror`, `pl_nferror`, `pl_trainerror`, `pl_rx_active_req`, `lp_rx_active_sts`,
`pl_protocol` (driven `111b` Streaming), `pl_protocol_flitfmt` (driven `0001b` Format 1),
`pl_stallreq`, `lp_stallack`, `pl_clk_req`, `lp_clk_ack`, `lp_wake_req`, `pl_wake_ack`,
`pl_cfg*`, `lp_cfg*`, `lp_stream`, `pl_stream`.

---

## 4. Sideband Packet Layer

### 4.1 Opcode (Table 47)

| Opcode | Type |
|---|---|
| `10010b` | Message without data |
| `11011b` | Message with 64b data |

Register-access opcodes are implemented only in the CSR slave path; not used by training.

### 4.2 Packet fields

64-bit header: `CP`, `DP`, `Cr`, `Addr[26:0]` / for messages `MsgInfo[15:0]`,
`MsgCode[7:0]`, `MsgSubcode[7:0]`; plus `BE[7:0]`, `EP`, `Tag[4:0]`; 64b data payload.
CP = even parity over all header bits except DP. DP = even parity over data payload
(0 when no payload). `srcid[2:0]` / `dstid[2:0]` per Table 49.

### 4.3 Message code table (Tables 53, 54, 56) — project subset

Link management:

| Message | Code | Subcode | Notes |
|---|---|---|---|
| `{Nop.Crd}` | `00h` | `00h` | MsgInfo 1-4 = credit count |
| `{LinkMgmt.RDI.Req.*}` | `01h` | `01h` Active, `04h` L1, `08h` L2, `09h` LinkReset, `0Ah` LinkError, `0Bh` Retrain, `0Ch` Disable | |
| `{LinkMgmt.RDI.Rsp.*}` | `02h` | same subcodes; `02h` = PMNAK | |
| `{AdvCap.Adapter}` | `01h` | `00h` | data payload, see 4.4 |
| `{FinCap.Adapter}` | `02h` | `00h` | data payload |
| `{ErrMsg}` | `09h` | `00h`/`01h`/`02h` | correctable / non-fatal / fatal |

SBINIT:

| Message | Code | Subcode |
|---|---|---|
| `{SBINIT out of Reset}` | `91h` | `00h` |
| `{SBINIT done req}` | `95h` | `01h` |
| `{SBINIT done resp}` | `9Ah` | `01h` |

MBINIT (all `A5h` req / `AAh` resp):

| Sub-state | Subcodes |
|---|---|
| PARAM | `00h` (config req/resp, 64b data) |
| CAL | `02h` done |
| REPAIRCLK | `03h` init, `04h` result, `05h` apply, `06h` check init, `07h` check results, `08h` done |
| REPAIRVAL | `09h` init, `0Ah` result, `0Bh` apply, `0Ch` done |
| REVERSALMB | `0Dh` init, `0Eh` clear error, `0Fh` result, `10h` done |
| REPAIRMB | `11h` start, `12h` apply repair, `13h` end, `14h` end |

MBTRAIN (all `B5h` req / `BAh` resp):

| Sub-state | Subcodes |
|---|---|
| VALVREF | `00h` start, `01h` end |
| DATAVREF | `02h` start, `03h` end |
| SPEEDIDLE | `04h` done |
| TXSELFCAL | `05h` done |
| RXCLKCAL | `06h` start, `07h` done |
| VALTRAINCENTER | `08h` start, `09h` done |
| VALTRAINVREF | `0Ah` start, `0Bh` end |
| DATATRAINCENTER1 | `0Ch` start, `0Dh` end |
| DATATRAINVREF | `0Eh` start, `0Fh` start resp, `10h` end |
| RXDESKEW | `11h` start, `12h` end |
| DATATRAINCENTER2 | `13h` start, `14h` end |
| LINKSPEED | `15h` start, `16h` error, `17h` exit to repair, `18h` exit to speed degrade, `19h` done, `1Ah` multimodule, `1Fh` exit to phy retrain |
| REPAIR | `1Bh` init, `1Ch` apply repair, `1Dh` end, `1Eh` apply degrade |

PHYRETRAIN `C5h`/`CAh` subcodes `00h` init, `01h` start.
TRAINERROR `E5h` req / `EAh` resp, subcode `00h`.

### 4.4 AdvCap / FinCap data payload

`{AdvCap.Adapter}` data bits: `[0] Raw_Mode = 1`, `[1] 68B Flit = 0`, `[2] CXL 256B = 0`,
`[3] PCIe Flit = 0`, `[4] Streaming = 1`, `[5] Retry = 0`, `[6] Multi_Protocol = 0`,
`[7] Stack0_Enable = 1`, `[8] Stack1_Enable = 0`, `[9]/[10] LatOpt = 0`, `[11] Retimer = 0`,
`[20:12] Retimer_Credits = 0`, `[21] DP`, `[22] UP`, `[63:23]` reserved.
`MsgInfo` = `0000h` regular, `FFFFh` stall.

---

## 5. Finite State Machines

### 5.1 LTSM (spec 4.5.3) — full, all sub-states

Encoding matches Error Log 0 `State N`:

| Value | State | Exit condition |
|---|---|---|
| `00h` | RESET | min 4 ms residency, supplies stable |
| `01h` | SBINIT | pattern detect + out-of-reset msg + done req/resp |
| `02h` | MBINIT.PARAM | config req sent and resp received |
| `03h` | MBINIT.CAL | done req/resp |
| `04h` | MBINIT.REPAIRCLK | Standard Pkg: no-op pass through handshake |
| `05h` | MBINIT.REPAIRVAL | Standard Pkg: no-op pass through handshake |
| `06h` | MBINIT.REVERSALMB | reversal detect, result, done |
| `07h` | MBINIT.REPAIRMB | Standard Pkg: no-op pass through handshake |
| `08h` | MBTRAIN.VALVREF | start/end, VALTRAIN 128 iterations |
| `09h` | MBTRAIN.DATAVREF | start/end, 4K UI LFSR |
| `0Ah` | MBTRAIN.SPEEDIDLE | done req/resp; rate = highest common = 4 GT/s |
| `0Bh` | MBTRAIN.TXSELFCAL | done req/resp, electrical idle |
| `0Ch` | MBTRAIN.RXCLKCAL | start/done |
| `0Dh` | MBTRAIN.VALTRAINCENTER | start/done, VALTRAIN pattern |
| `0Eh` | MBTRAIN.DATATRAINVREF1 | start/end, 4K UI LFSR |
| `0Fh` | MBTRAIN.RXDESKEW | start/end, 4K UI LFSR |
| `10h` | MBTRAIN.DATATRAINCENTER2 | start/end, 4K UI LFSR |
| `11h` | MBTRAIN.LINKSPEED | start, point test, done/repair/degrade |
| `12h` | MBTRAIN.REPAIR | width degrade (lanes 0-7 or 8-15), then TXSELFCAL |
| `13h` | PHYRETRAIN | retrain init/start |
| `14h` | LINKINIT | LFSR reset; RDI Active-entry handshake |
| `15h` | ACTIVE | data flow, scrambled |
| `16h` | TRAINERROR | entry req/resp, fatal |
| `17h` | L1/L2 | power management |

Sub-state exit rule (spec 4.5.3.4): exit only when the req has been sent **and** the
matching resp received. Loop-backs: SPEEDIDLE -> TXSELFCAL; REPAIR -> TXSELFCAL.

Residency timer: 8 ms per sub-state. Timeout -> TRAINERROR (escalate as fatal,
set Error Log 1 bit 8).

### 5.2 RDI state machine (spec 8.1.5 / Figure 111)

Domain Reset; Exit-Link-Error domain; From Any State -> Reset on reset.
States: Reset, Active, Retrain, LinkReset, L1, L2, LinkError, Disabled.

Active-entry sequence (8.1.6), executed on **every** entry from Reset or Retrain:

1. PHY completes training.
2. `pl_clk_req` / `lp_clk_ack` handshake.
3. PHY asserts `pl_inband_pres`.
4. Adapter requests Active on `lp_state_req`.
5. PHY sends `{LinkMgmt.RDI.Req.Active}`.
6. PHY returns `{LinkMgmt.RDI.Rsp.Active}` only after its **own** Adapter requested Active.
7. `pl_state_sts` = Active.

### 5.3 FDI state machine (spec 8.2)

Mirror of RDI with `pl_rx_active_req` / `lp_rx_active_sts` four-way handshake.
`pl_protocol` = `111b` Streaming, `pl_protocol_flitfmt` = `0001b` Format 1.
`pl_inband_pres` deasserts during LinkReset, Disabled, LinkError.

### 5.4 Stall handshake (spec 8.3.1)

Four-phase. `pl_stallreq` rises only while `lp_stallack` low. While `lp_stallack` high,
both `lp_valid` and `lp_irdy` must be low. At least one flop between `pl_stallreq` and
`lp_stallack`.

---

## 6. Datapath

### 6.1 Byte-to-lane mapping (spec 4.1.1)

Byte k goes on lane k, bit 0 first. x16 = 16 bytes/transfer, 16 transfers per 256 B.
x8 degrade = 8 bytes/transfer, 32 transfers per 256 B.

### 6.2 Valid framing (spec 4.1.2)

Valid asserted for the first 4 UI of each 8 UI transfer.

### 6.3 Clock gating (spec 4.1.3)

Gate after 16 UI postamble unless free-running clock mode negotiated.

### 6.4 Scrambler / LFSR (spec 4.4.1)

`G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1`. Per-lane seed = lane number mod 8:

| Lane mod 8 | Seed |
|---|---|
| 0 | `23'h1DBFBC` |
| 1 | `23'h0607BB` |
| 2 | `23'h1EC760` |
| 3 | `23'h18C0DB` |
| 4 | `23'h010F12` |
| 5 | `23'h19CFC9` |
| 6 | `23'h0277CE` |
| 7 | `23'h1BB807` |

LFSR reset on entry to LINKINIT. No effect in MBINIT.REPAIRMB and MBTRAIN.VALVREF.
Scrambling **off** for Per-Lane-ID, VALTRAIN, and clock repair patterns.
Tap matrix: the LFSR shifts right with feedback into bit 22, so register bit k at
time t is output bit t+k. The realised recurrence is `o(t+23) = XOR of o(t+i)` over
the tapped bits, hence characteristic polynomial `x^23 + SUM(x^tap)`. Taps
`23'h210125` = bits {21,16,8,5,2,0} give exactly `x^23+x^21+x^16+x^8+x^5+x^2+1`.
The `x^23` term is the shift itself, so a 23-bit mask holds no bit 23. Verified against
an independent golden recurrence over 50000 bits and by maximal-length period 2^23-1.

### 6.5 Pattern generation

- Per-Lane-ID: lane ID = binary of logical lane number.
- VALTRAIN: 4 ones then 4 zeros, 128 iterations, detection on 16 consecutive.
- Clock repair pattern per spec 4.4.

### 6.6 Width degrade

If failing lanes are all within 0-7 or all within 8-15, degrade to x8 using that half.
`{MBTRAIN.REPAIR Apply degrade req}` carries lane map `2'b01` (0-7) / `2'b10` (8-15).
`pl_lnk_cfg` drops `010` -> `001`.

### 6.7 Adapter datapath

`lp_data` (FDI) -> `lp_data` (RDI) direct, registered. `pl_data` (RDI) -> `pl_data` (FDI)
direct, registered. `pl_trdy` = FDI `pl_trdy` qualified by Stall and Active states.
No header, no CRC, no retry.

---

## 7. Sideband Credit Model (spec 6.1.3)

Three independent credit loops: FDI, RDI, remote. Max 4 outstanding remote.
1 credit = 64b header + 64b data, consumed even when no data.
8 ms message timeout. Stall every 4 ms resets the requester timer. No retry (BER 1e-27).
32 UI gap between packets.

---

## 8. Build Order (per spec Tables 145-147, simplified)

| Step | Module | Depends on |
|---|---|---|
| 1 | `ucie_pkg` | — |
| 2 | `scrambler`, `pattern_gen` | `ucie_pkg` |
| 3 | `sb_encoder`, `sb_decoder` | `ucie_pkg` |
| 4 | `byte_lane_mapper` | `ucie_pkg` |
| 5 | `ltsm` | 2, 3 |
| 6 | `rdi_state_machine` | `ucie_pkg` |
| 7 | `logical_phy` (integrate) | 2-6 |
| 8 | `adapter_regfile`, `fdi_state_machine`, `adapter_datapath` | `ucie_pkg` |
| 9 | `d2d_adapter` (integrate) | 8 |
| 10 | `ucie_main` | 7, 9 |

---

## 9. Testbench Architecture

```
tb_loopback_top
 +-- dut_die0 : ucie_main
 +-- dut_die1 : ucie_main
 +-- line_model : combinatorial cross-connect, main band + sideband
 +-- bfm0/bfm1 : protocol_layer_bfm  (Stream 0 Streaming master)
 +-- sb_mon0/sb_mon1 : sideband monitor (opcode counters)
 +-- ltsm_mon0/ltsm_mon1 : LTSM state-hit counters
 +-- rdi_fdi_mon : handshake + Stall counters
 +-- scoreboard : Raw Mode byte compare, both directions
 +-- cov_export : writes counters to sim/logs/coverage.json
```

`protocol_layer_bfm` emulates the Protocol Layer: reset flow to initiate link init,
then Raw Mode streaming data once link is Active. Asserts `lp_state_req` = Active,
handles `pl_rx_active_req` / `lp_rx_active_sts`, drives `lp_irdy` / `lp_valid` /
`lp_data`, sinks `pl_valid` / `pl_data`.

Unit tests in `tb/unit/`, one per FSM: `ut_lfsr`, `ut_sb_codec`, `ut_ltsm`,
`ut_rdi_sm`, `ut_fdi_sm`, `ut_stall`, `ut_mapper`. Each is self-contained with its own
reactive partner and prints `TEST PASSED`.

---

## 10. Coverage Model

Icarus Verilog 12.0 has **no** covergroup/`.ucdb` support. Coverage is implemented as
explicit counters in monitor modules, exported as JSON, and reported by a Python script.

Counters (all must be > 0 at `$finish`):

- `ltsm_state_hits[24]` — every state/sub-state encoding `00h`-`17h`
- `sb_opcode_hits[]` — every opcode exercised in both directions
- `sb_msgcode_hits[256]` — per MsgCode
- `rdi_active_entry_done` — full Active-entry handshake
- `stall_4phase_done` — req -> ack -> data-stop -> deassert
- `width_degrade_done` — `pl_lnk_cfg` x16 -> x8
- `lane_reversal_detected`
- `raw_transfer_fwd` / `raw_transfer_rev` — completed 256 B blocks
- `crc_off` advertisement seen, `raw_mode` bit seen

**Two-source model.** The loopback is x16-only, its PHY ties `rdi_pl_stallreq`
low (`logical_phy.sv`), and `byte_lane_mapper`'s `byte_reversal` input is tied
low. So three of the counters above are structurally zero in the loopback and
are collected from the directed unit tests that actually drive those paths:

- `ut_stall` writes `logs/stall_evidence.json` — the one four-phase stall
  sequence plus the x8 upper-half zeroing.
- `ut_mapper` writes `logs/mapper_evidence.json` — both x8 degrade halves and
  both byte-reversal passes.

The Makefile deletes `logs/*_evidence.json` before each unit run, so a fragment
can only exist because its test printed `TEST PASSED` this run. The report
attributes each hit to its source file and fails with a pointer if a fragment
is missing. `LT_PHYRETRAIN`/`TRAINERROR`/`L1L2` are not reachable in this
capability set and are reported `n/a`, not as holes.

Python report reads `sim/logs/coverage.json` plus the evidence fragments, and
prints per-counter hits plus `COVERAGE: 100%` only if every counter is
non-zero.

---

## 11. Simulation Runtime Strategy

True-spec timers are mandatory. At 1 GHz lclk, 4 ms RESET = 4,000,000 cycles and
8 ms residency = 8,000,000 cycles per sub-state. With ~20 sub-states the naive full
run is far beyond a practical budget.

Strategy (legal, does not change RTL timer values):

- **Main-line link-up test** runs each sub-state to *handshake completion*, not to
  timer expiry. Residency timers count but the sub-state exits on its sideband
  done message. This keeps the run in the tens of millions of cycles, not billions.
- **Timeout paths** are verified in **unit tests** on the timer module in isolation,
  with the timer counter width preserved but the clock divided by a testbench-only
  parameter. The RTL itself never sees a divided clock.
- If the main-line run still exceeds ~30 minutes wall clock, escalate per the stop
  condition rather than editing timer constants.

---

## 12. Files

| Path | Purpose |
|---|---|
| `rtl/rtl_common/ucie_pkg.sv` | constants, enums, message codes, seeds |
| `rtl/rtl_common/scrambler.sv` | per-lane LFSR |
| `rtl/rtl_common/timer.sv` | residency / message timers |
| `rtl/d2d_adapter/*.sv` | adapter block |
| `rtl/logical_phy/*.sv` | PHY block incl. LTSM |
| `tb/bfm/protocol_layer_bfm.sv` | Protocol Layer BFM |
| `tb/loopback/tb_loopback_top.sv` | two-end testbench |
| `tb/monitors/*.sv` | coverage counters |
| `tb/unit/*.sv` | directed unit tests |
| `sim/Makefile` | compile / unit / loopback / coverage / all |
| `sim/cov_report.py` | JSON -> coverage report |
| `doc/PLAN.md` | this document |

---

## 13. Verification Gates

| Gate | Command | Pass condition |
|---|---|---|
| Compile | `make -C sim compile` | zero errors, zero warnings |
| Unit | `make -C sim unit` | each prints `TEST PASSED`, aggregate `ALL UNIT TESTS PASSED` |
| Loopback | `make -C sim loopback` | `LINK ACTIVE (die 0)` and `LINK ACTIVE (die 1)` |
| Data | same run | `RAW MODE TRANSFER OK (die0->die1)` and `(die1->die0)` |
| Coverage | `make -C sim coverage` | every counter non-zero; `COVERAGE: 100%` |
| Full | `make -C sim all` | exit 0 |

---

## 14. Approved SBINIT Delayed-Start Plan

### 14.1 Goal

Implement the Standard Package SBINIT procedure so that independent Die 0 and
Die 1 Stage 0 completion times can differ. The first required integration
scenario releases Die 1 from reset 2.5 ms after Die 0 and must complete link
bring-up.

This plan preserves the existing `ucie_main -> d2d_adapter + logical_phy`
topology. It does not change FDI, RDI, or external main-band interface
definitions.

### 14.2 Scope

The implementation changes only:

- `rtl/rtl_common/ucie_pkg.sv`
- `rtl/logical_phy/sb_codec.sv`
- `rtl/logical_phy/ltsm.sv`
- `rtl/logical_phy/logical_phy.sv`
- focused unit tests, loopback checks, coverage, and simulation targets

`d2d_adapter` remains unchanged. The paired lclk/sbclk CDC mailbox inside each
logical PHY remains unchanged. Each die can have an independent reset pair, but
the lclk and sbclk resets inside one die must assert together.

### 14.3 Protocol Requirements

Implement the Standard Package sequence in UCIe 1.0 Section 4.5.3.2:

1. After the local 4 ms RESET minimum, a die can enter SBINIT after either a
   local training trigger or a received SBINIT-pattern trigger.
2. The received-pattern trigger requires two consecutive valid remote
   iterations. Each iteration is 64 UI of the SBINIT clock pattern plus 32 UI
   low.
3. A detected pattern trigger is sticky for the current RESET epoch. It cannot
   bypass the 4 ms minimum.
4. A die sends 64 UI of the SBINIT clock pattern followed by 32 UI low.
5. After detection, it sends exactly four more local iterations.
6. Before detection, it uses 1 ms pattern-active and 1 ms idle windows.
7. It sends `{SBINIT Out of Reset}` (`91h`/`00h`) until it receives the same
   valid peer message.
8. It sends `{SBINIT done req}` (`95h`/`01h`).
9. It sends `{SBINIT done resp}` (`9Ah`/`01h`) for each valid peer Done request.
10. It enters MBINIT only after its Done request and peer Done response complete.

All SBINIT phases share the existing 8 ms residency deadline. A request is not a
response. Invalid parity, IDs, opcode, code, and subcode must not advance state.

### 14.4 RTL Design

`ucie_pkg.sv` becomes the sole definition site for SBINIT constants. Add PHY
source ID `3'b010`, remote-PHY destination ID `3'b110`, SBINIT message
subcodes, and named pattern/retry limits.

`ltsm.sv` owns the complete SBINIT sequence in the 500 MHz `lclk` domain.
It owns the pattern, Out-of-Reset, and Done phases, all retry and timeout
policy, and every state transition. During RESET it maintains a saturating
two-match streak from atomic remote-iteration results. The second consecutive
match latches a pattern training trigger for the RESET epoch.

LT_RESET exits only after its 4 ms minimum and either
`start_link_train` or the latched pattern trigger. Under the existing public
interface, deasserted local reset represents that local Stage 0 no longer holds
the PHY in RESET. No new public readiness port is added. LTSM retains a detected
pattern across RESET-to-SBINIT, counts four local tail-iteration completions,
and schedules `91h`/`00h`, `95h`/`01h`, and `9Ah`/`01h` through the existing
lclk-facing packet interface.

`sb_codec.sv` remains an sbclk-only sideband message codec. It serializes and
parses sideband messages, but it does not contain an SBINIT phase machine,
retry policy, timeout, iteration counter, or LTSM state transition.

`logical_phy.sv` owns the lclk-to-sbclk transport. Its rate-adapter CDC
primitive listens for remote pattern iterations whenever the local reset pair
is released, including while LTSM is in RESET.

LTSM controls transmission with one stable `pattern_run_enable` level. While
the synchronized level is high, the primitive repeats the 64-UI pattern plus
32-UI-low waveform without a CDC round trip between iterations. When LTSM
deasserts the level, the primitive finishes the current waveform and stops at
the following low boundary. The primitive does not choose when to start, stop,
retry, idle, or advance any SBINIT phase.

The primitive sends each remote iteration through an atomic one-bit result
mailbox, where the payload is match or mismatch. It sends each local completed
iteration through a separate event mailbox. LTSM consumes both events in lclk.
It uses local iteration-completion events to enforce the four-tail count and
its own lclk timers to enforce the 1 ms active and 1 ms idle policy.

The primitive cannot store a detected state, count consecutive matches or tail
iterations, report a collapsed `pattern_detected` or `sbinit_complete` level,
or contain training policy. Reset pairs remain aligned within each die so these
CDC mailboxes retain their documented reset contract.

Split RESET-timer restart from general residency-timer restart so the RESET
timer starts only when RESET is entered.

### 14.5 Verification

Add `tb/unit/ut_sbinit.sv` for exact SBINIT pattern, atomic match/mismatch
events, two-consecutive-match triggering during RESET, four tail iterations,
Out-of-Reset, Done ordering, invalid packet, and timeout behavior. Update
`ut_sb_codec.sv` for the three SBINIT message encodings. Update `ut_ltsm.sv`
for the pattern-trigger RESET exit, explicit request/response behavior, and the
true 8 ms timeout.

Update `tb/loopback/tb_loopback_top.sv` to use independent local reset pairs.
Release Die 1 reset 2.5 ms after Die 0. Assert Die 0's local training trigger,
but leave Die 1's trigger low. Require the received SBINIT pattern to start
Die 1 after its own 4 ms RESET minimum. Check reset duration, the Stage 0 skew,
SBINIT order, absence of early main-band activity, both ACTIVE observations,
and both Raw Mode data directions. Use a 20 ms integration watchdog.

Extend `cov_monitor.sv` with per-die SBINIT phase and message-subcode evidence.
The required final gate is:

```text
make -C sim clean && make -C sim all
```

#!/usr/bin/env python3
"""Coverage report for the UCIe 1.0 simplified endpoint.

Icarus Verilog 12.0 has no covergroup support. The loopback testbench
accumulates counters in tb/monitors/cov_monitor.sv and writes them to
sim/logs/coverage.json as JSON. This script reads that file and merges it
with directed unit-test evidence fragments to evaluate overall coverage.

Specification references
------------------------
  UCIe 1.0 Specification, Section 4.5.3   - Link Training State Machine
  UCIe 1.0 Specification, Section 4.5.3.1 - RESET
  UCIe 1.0 Specification, Section 4.5.3.8 - TRAINERROR
  UCIe 1.0 Specification, Section 4.1.1   - Byte to Lane Mapping
  UCIe 1.0 Specification, Section 4.1.2   - Mainband Framing
  UCIe 1.0 Specification, Section 4.3.7   - Width Degrade in Standard Package
  UCIe 1.0 Specification, Section 6.1.1   - Packet Types
  UCIe 1.0 Specification, Section 6.1.2   - Packet Formats
  UCIe 1.0 Specification, Section 6.1.3   - Flow Control and Data Integrity
  UCIe 1.0 Specification, Section 8.1     - Raw Die-to-Die Interface (RDI)
  UCIe 1.0 Specification, Section 8.1.5   - RDI State Status Machine
  UCIe 1.0 Specification, Section 8.1.7   - RDI Power Management Flow (PMNAK)
  UCIe 1.0 Specification, Section 8.2     - Flit-Aware D2D Interface (FDI)
  UCIe 1.0 Specification, Section 8.2.5   - FDI State Status Machine
  UCIe 1.0 Specification, Section 8.3.1   - Stallreq/Ack Mechanism
  UCIe 1.0 Specification, Table 47        - Sideband Opcodes
  UCIe 1.0 Specification, Table 56        - MBINIT.PARAM Data Format
  PLAN.md, Section 15.9 Phase F           - Coverage and Verification Integration

Purpose
-------
Turn raw simulation counters and unit evidence into a single pass/fail
statement about how much of the reduced capability set the test suite
actually exercised. The script exits 0 only when every reachable state is
visited, every planned event counter is non-zero, and every documented
unreachable state is accounted for.

Inputs
------
  sim/logs/coverage.json              written by the loopback monitor at the
                                      end of the run: LTSM state histogram,
                                      RDI state histogram, sideband opcode and
                                      MsgCode histograms, and loopback event
                                      counters.
  sim/logs/stall_evidence.json        written by ut_stall.sv on success.
  sim/logs/mapper_evidence.json       written by ut_mapper.sv on success.
  sim/logs/ltsm_policy_evidence.json  written by ut_ltsm_policy.sv on success.
  sim/logs/sb_codec_evidence.json     written by ut_sb_codec.sv on success.
  sim/logs/gearbox_evidence.json      written by ut_gearbox.sv on success.
  sim/logs/rdi_sm_evidence.json       written by ut_rdi_sm.sv on success.
  sim/logs/fdi_sm_evidence.json       written by ut_fdi_sm.sv on success.

Outputs
-------
A human-readable report on stdout, grouped as LTSM state coverage, RDI state
coverage, sideband MsgCode coverage, and event coverage. The final line is
either

  COVERAGE: 100%  (21/21 reachable states, all event counters non-zero)

or

  COVERAGE: INCOMPLETE (N missing)
    missing: <counter name>

with one `missing:` line per hole. The process exit code is 0 for complete and
1 for incomplete, so the Makefile needs no parsing.

Coverage definition
-------------------
The reduced capability set is x16-only, single module, Streaming / Raw Mode.
Not every enumerated state in ucie_pkg is reachable in this configuration:

  * LT_MB_REPAIR (12h) is unsupported in the fixed profile and has no
    entry transition. A repair request is converted to a fatal event, so the
    state itself is not a reachable coverage bin.
  * LT_PHYRETRAIN (13h) and LT_L1L2 (17h) have no entry transition in
    ltsm.sv. The fixed profile handles retrain and L1/L2 requests through
    explicit error or PMNAK responses, so those states remain outside the
    reachable coverage denominator.
  * TRAINERROR (16h) is reachable and exercised through residency timeout,
    sideband protocol fault escalation, and mainband framing fault recovery.
    It is included in REACHABLE_STATES and verified both in loopback bring-up
    and directed unit testing.

Coverage is therefore reported over the 21 supported states 00h-11h, 14h,
15h, and 16h, plus the active-loopback, sideband, and Phase F functional event
metrics. 100% means every one of those counters is non-zero.

Unreachable states are printed with "n/a (unreachable in this capability set)"
and are kept out of the denominator entirely. They are never counted as holes,
because reporting an unreachable state as a coverage gap would make 100%
impossible to reach by construction and would hide a real regression behind a
permanently red line.

Why multiple sources
--------------------
The loopback runs two real ucie_main instances and therefore exercises the
LTSM, the RDI path, the adapter, and both sideband directions. But it is
x16-only, and its PHY never asserts rdi_pl_stallreq. Paths requiring directed
fault injection or isolated interface stimulus are exercised by the directed
unit tests instead:

  * the stall four-phase handshake        (spec 8.3.1, ut_stall)
  * the x8 width-degrade halves           (spec 4.3.7, ut_stall / ut_mapper)
  * the byte-reversal detection path      (spec 4.1.1, ut_mapper)
  * PARAM role separation and arbitration (spec 4.5.3.3, Table 56, ut_ltsm_policy)
  * fatal causes and TRAINERROR entry     (spec 4.5.3.8, ut_ltsm_policy)
  * PARAM compatibility resolution        (spec Table 56, ut_ltsm_policy)
  * sideband packet transaction classes   (spec Table 47, Section 6.1.1, ut_sb_codec)
  * mainband framing fault detection      (spec 4.1.2, PLAN.md 6.2, ut_gearbox)
  * PMNAK power management rejection      (spec 8.1.7, ut_rdi_sm / ut_fdi_sm)
  * LinkReset and Disabled recovery       (spec 8.1.5, ut_rdi_sm / ut_fdi_sm / ut_ltsm_policy)
  * unsupported L1/L2/retrain exclusions  (spec 8.1.5, 8.2.5, ut_rdi_sm / ut_fdi_sm)

Each directed test writes a small JSON fragment when it passes. The Makefile
deletes stale fragments before running, so a fragment present at report time
can only mean that test passed in this same run.

Flow
----
    coverage.json            (loopback)       --+
    stall_evidence.json      (ut_stall)       --+
    mapper_evidence.json     (ut_mapper)      --+
    ltsm_policy_evidence.json(ut_ltsm_policy) --+--> cov_report.py --> stdout + exit code
    sb_codec_evidence.json   (ut_sb_codec)    --+
    gearbox_evidence.json    (ut_gearbox)     --+
    rdi_sm_evidence.json     (ut_rdi_sm)      --+
    fdi_sm_evidence.json     (ut_fdi_sm)      --+

Design notes
------------
  * REACHABLE_STATES is written as an explicit literal list of 21 states,
    including TRAINERROR (16h).
  * UNREACHABLE_STATES contains MBTRAIN.REPAIR (12h), PHYRETRAIN (13h), and
    L1/L2 (17h).
  * Counter lookups are guarded so a JSON file missing a key reports a
    coverage hole deterministically instead of throwing KeyError or IndexError.
  * Every planned Phase F event key is required to be non-zero.

Revision history
----------------
  v0.0.1  2025-XX-XX  Initial creation - LTSM state and event coverage report.
  v0.0.2  2026-09-22  Add unit-test evidence merge for stall, width degrade
                      and lane reversal.
  v0.0.3  2026-09-23  Documentation: expand header, add revision history.
  v0.0.4  2026-09-25  Phase F: add TRAINERROR to REACHABLE_STATES and keep
                      unsupported MBTRAIN.REPAIR, PHYRETRAIN, and L1L2 out of
                      the denominator. Integrate unit evidence fragments for
                      Phase F contract events and implement deterministic
                      missing-key handling.
  v0.0.5  2026-09-25  Align the state denominator with the fixed-profile
                      MBTRAIN.REPAIR fatal policy and its no-entry transition.

  v0.0.6  2026-09-29  Documentation: align docstring reachable states count
                      (21) and unreachable states list (12h, 13h, 17h) with the
                      active 21-state denominator.
License
-------
  SPDX-License-Identifier: Apache-2.0
"""

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
COV = REPO / "sim" / "logs" / "coverage.json"

# LTSM states in the fixed-profile x16 bring-up and recovery.
REACHABLE_STATES = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x14, 0x15, 0x16,
]

# Documented-unreachable states, kept out of the denominator.
# The fixed profile has no transition into repair, PHYRETRAIN, or L1/L2.
UNREACHABLE_STATES = [0x12, 0x13, 0x17]

STATE_NAMES = {
    0x00: "RESET",          0x01: "SBINIT",        0x02: "MBINIT.PARAM",
    0x03: "MBINIT.CAL",     0x04: "MBINIT.RPCLK",  0x05: "MBINIT.RPVAL",
    0x06: "MBINIT.REVMB",   0x07: "MBINIT.RPMB",   0x08: "MBTRAIN.VALVREF",
    0x09: "MBTRAIN.DATAVREF", 0x0A: "MBTRAIN.SPEEDIDLE",
    0x0B: "MBTRAIN.TXSELFCAL", 0x0C: "MBTRAIN.RXCLKCAL",
    0x0D: "MBTRAIN.VTCENTER", 0x0E: "MBTRAIN.DTVREF1",
    0x0F: "MBTRAIN.RXDESKEW", 0x10: "MBTRAIN.DTCENTER2",
    0x11: "MBTRAIN.LINKSPEED", 0x12: "MBTRAIN.REPAIR",
    0x13: "PHYRETRAIN",     0x14: "LINKINIT",      0x15: "ACTIVE",
    0x16: "TRAINERROR",     0x17: "L1L2",
}


def load():
    if not COV.exists():
        print(f"error: {COV} not found - run the loopback test first")
        return None
    with COV.open(encoding="utf-8") as fh:
        return json.load(fh)


# Unit-test evidence mappings to Phase F contract events.
EVIDENCE = [
    (COV.parent / "stall_evidence.json",
     {"stall_4phase": "stall_4phase_done",
      "width_degrade_x8": "width_degrade_done"}),
    (COV.parent / "mapper_evidence.json",
     {"width_degrade": "width_degrade_done",
      "lane_reversal": "lane_reversal_detected"}),
    (COV.parent / "ltsm_policy_evidence.json",
     {"param_roles": "param_roles",
      "arbitration": "arbitration",
      "fatal_causes": "fatal_causes",
      "trainerror": "trainerror",
      "param_compatibility": "param_compatibility"}),
    (COV.parent / "sb_codec_evidence.json",
     {"transaction_classes": "transaction_classes"}),
    (COV.parent / "gearbox_evidence.json",
     {"framing_fault": "framing_fault"}),
    (COV.parent / "rdi_sm_evidence.json",
     {"rdi_pmnak": "pmnak",
      "rdi_linkreset": "linkreset",
      "rdi_disabled": "disabled",
      "rdi_unsupported_pm_retrain_reject": "unsupported_pm_retrain_reject"}),
    (COV.parent / "fdi_sm_evidence.json",
     {"fdi_pmnak": "pmnak",
      "fdi_linkreset": "linkreset",
      "fdi_disabled": "disabled",
      "fdi_unsupported_pm_retrain_reject": "unsupported_pm_retrain_reject"}),
]

# Planned event keys that must be non-zero in a complete run.
PLANNED_EVENTS = [
    "rdi_active_entry_done",
    "raw_transfer_fwd",
    "raw_transfer_rev",
    "raw_mode_adv",
    "crc_off_adv",
    "stall_4phase_done",
    "width_degrade_done",
    "lane_reversal_detected",
    "param_roles",
    "transaction_classes",
    "arbitration",
    "fatal_causes",
    "trainerror",
    "linkreset",
    "disabled",
    "pmnak",
    "unsupported_pm_retrain_reject",
    "param_compatibility",
    "framing_fault",
]

def main():
    cov = load()
    if cov is None:
        return 1

    misses = []
    hits = cov.get("ltsm_state_hits", [])
    print("LTSM state coverage")
    print(f"  {'state':<22} {'hits':>6}")
    for idx in REACHABLE_STATES:
        n = hits[idx] if idx < len(hits) else 0
        print(f"  {STATE_NAMES[idx]:<22} {n:>6}")
        if n == 0:
            misses.append(f"ltsm_state_hits[{STATE_NAMES[idx]}]")
    for idx in UNREACHABLE_STATES:
        print(f"  {STATE_NAMES[idx]:<22} {'n/a':>6}  (unreachable in this "
              f"capability set)")

    # ---------------------------------------------------------- RDI states
    print("\nRDI state coverage")
    rdi_hits = cov.get("rdi_state_hits", [])
    for idx in (0, 1):
        n = rdi_hits[idx] if idx < len(rdi_hits) else 0
        label = "RESET" if idx == 0 else "ACTIVE"
        print(f"  {label:<8} {n:>6}")
        if n == 0:
            misses.append(f"rdi_state_hits[{label}]")
    for idx in range(2, 16):
        n = rdi_hits[idx] if idx < len(rdi_hits) else 0
        if n:
            print(f"  {idx:04b}     {n:>6}  (unexpected)")
    sb_opcode_hits = cov.get("sb_opcode_hits", [])
    for idx, n in enumerate(sb_opcode_hits):
        if n:
            print(f"  opcode {idx:02b} ({idx:05b})  {n:>6}")
    if sum(sb_opcode_hits) == 0:
        misses.append("sb_opcode_hits")

    print("\nSideband MsgCode coverage")
    sb_msgcode_hits = cov.get("sb_msgcode_hits", [])
    codes = [i for i, n in enumerate(sb_msgcode_hits) if n]
    for idx in codes:
        print(f"  MsgCode {idx:02X}h   {sb_msgcode_hits[idx]:>6}")
    if not codes:
        misses.append("sb_msgcode_hits")

    # ---------------------------------------------------------- events
    print("\nEvent coverage")
    # Loopback-sourced counters.
    events = [
        "rdi_active_entry_done",
        "raw_transfer_fwd",
        "raw_transfer_rev",
        "raw_mode_adv",
        "crc_off_adv",
    ]
    for name in events:
        val = cov.get(name, 0)
        print(f"  {name:<34} {val:>6}")
        if val == 0:
            misses.append(name)

    # Unit-test-sourced counters.
    for path, mapping in EVIDENCE:
        if not path.exists():
            for src, dst in mapping.items():
                misses.append(f"{dst} (missing evidence "
                              f"{path.name}; run make -C sim unit)")
            continue
        try:
            with path.open(encoding="utf-8") as fh:
                frag = json.load(fh)
        except Exception as exc:
            for src, dst in mapping.items():
                misses.append(f"{dst} (invalid JSON in {path.name}: {exc})")
            continue
        for src, dst in mapping.items():
            val = frag.get(src, 0)
            if val == 0 and src.startswith(("rdi_", "fdi_", "sb_", "mb_")):
                val = frag.get(src.split("_", 1)[1], 0)
            if val == 0:
                misses.append(f"{dst} (missing or zero {src} in {path.name})")
                continue
            cov[dst] = max(cov.get(dst, 0), val)
            print(f"  {dst:<34} {cov[dst]:>6}  (unit test {path.name})")

    # Require every planned event key to be nonzero.
    for key in PLANNED_EVENTS:
        if cov.get(key, 0) == 0:
            msg = f"{key} (event counter zero or missing)"
            if not any(key in m for m in misses):
                misses.append(msg)

    # ---------------------------------------------------------- verdict
    print()
    if misses:
        print(f"COVERAGE: INCOMPLETE ({len(misses)} missing)")
        for m in misses:
            print(f"  missing: {m}")
        return 1
    print(f"COVERAGE: 100%  "
          f"({len(REACHABLE_STATES)}/{len(REACHABLE_STATES)} reachable states, "
          f"all event counters non-zero)")
    return 0

if __name__ == "__main__":
    sys.exit(main())

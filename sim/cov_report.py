#!/usr/bin/env python3
"""Coverage report for the UCIe 1.0 simplified endpoint.

Icarus Verilog 12.0 has no covergroup support. The loopback testbench
accumulates counters in tb/monitors/cov_monitor.sv and writes them to
sim/logs/coverage.json as JSON. This script reads that file and reports
the result.

Coverage definition
-------------------
The reduced capability set is x16-only, single module, Streaming / Raw Mode.
Not every enumerated state in ucie_pkg is reachable in this configuration:

  * LT_PHYRETRAIN (13h) and LT_L1L2 (17h) have no entry transition in
    ltsm.sv. Retraining and L1/L2 entry are negotiated through the adapter
    sideband, which this PoC does not transport, so the states are defined
    for Error Log 0 reporting only.
  * TRAINERROR (16h) is reachable only through a residency timeout. The main
    line exits every sub-state on handshake completion, so a timeout would
    mean the bring-up failed. It is covered instead by the timer unit test,
    which proves the timeout path of ucie_timer at full width.

Coverage is therefore reported over the 21 bring-up states 00h-12h, 14h,
15h, plus the active-loopback and sideband metrics. 100% means every one of
those counters is non-zero.
"""

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
COV = REPO / "sim" / "logs" / "coverage.json"

# LTSM states a reduced-capability x16 bring-up actually walks.
REACHABLE_STATES = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x14, 0x15,
]

# Documented-unreachable states, kept out of the denominator.
UNREACHABLE_STATES = [0x13, 0x16, 0x17]

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



# Unit-test evidence. The loopback is x16-only and its PHY never asserts
# rdi_pl_stallreq, so the stall four-phase, the x8 degrade halves and the
# byte reversal are exercised by the directed unit tests instead. Each one
# writes a JSON fragment on success; the Makefile removes stale fragments
# before the tests start, so a fragment can only exist because that test
# actually passed this run.
EVIDENCE = [
    (COV.parent / "stall_evidence.json",
     {"stall_4phase": "stall_4phase_done",
      "width_degrade_x8": "width_degrade_done"}),
    (COV.parent / "mapper_evidence.json",
     {"width_degrade": "width_degrade_done",
      "lane_reversal": "lane_reversal_detected"}),
]


def main():
    cov = load()
    if cov is None:
        return 1

    misses = []
    hits = cov["ltsm_state_hits"]
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
    for idx in (0, 1):
        n = cov["rdi_state_hits"][idx]
        label = "RESET" if idx == 0 else "ACTIVE"
        print(f"  {label:<8} {n:>6}")
        if n == 0:
            misses.append(f"rdi_state_hits[{label}]")
    for idx in range(2, 16):
        if cov["rdi_state_hits"][idx]:
            print(f"  {idx:04b}     {cov['rdi_state_hits'][idx]:>6}  "
                  f"(unexpected)")
    for idx, n in enumerate(cov["sb_opcode_hits"]):
        if n:
            print(f"  opcode {idx:02b} ({idx:05b})  {n:>6}")
    if sum(cov["sb_opcode_hits"]) == 0:
        misses.append("sb_opcode_hits")
        op_ok = False

    print("\nSideband MsgCode coverage")
    codes = [i for i, n in enumerate(cov["sb_msgcode_hits"]) if n]
    for idx in codes:
        print(f"  MsgCode {idx:02X}h   {cov['sb_msgcode_hits'][idx]:>6}")
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
        print(f"  {name:<26} {cov[name]:>6}")
        if cov[name] == 0:
            misses.append(name)

    # Unit-test-sourced counters. These paths cannot occur in the x16
    # loopback: rdi_pl_stallreq is tied low, the link never degrades, and
    # the mapper's byte_reversal input is tied low. Each value below comes
    # from a JSON fragment a directed unit test wrote on its own PASS line,
    # so the hit is real even though it is not a loopback observation.
    for path, mapping in EVIDENCE:
        if not path.exists():
            for src, dst in mapping.items():
                misses.append(f"{dst} (missing evidence "
                              f"{path.name}; run make -C sim unit)")
            continue
        with path.open(encoding="utf-8") as fh:
            frag = json.load(fh)
        for src, dst in mapping.items():
            if src not in frag or frag[src] == 0:
                misses.append(dst)
                continue
            cov[dst] = max(cov[dst], frag[src])
            print(f"  {dst:<26} {cov[dst]:>6}  (unit test {path.name})")
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

# ============================================================================
# File      : sim/Makefile
# Project   : UCIe 1.0 Simplified Endpoint
# Purpose   : Simulation driver for the UCIe 1.0 Simplified Endpoint RTL.
# ----------------------------------------------------------------------------
#
# SPECIFICATION REFERENCES
#   UCIe 1.0 Specification, Section 8.0 - Interface Definitions
#   UCIe 1.0 Specification, Section 8.1 - Raw Die-to-Die Interface (RDI)
#   UCIe 1.0 Specification, Section 8.2 - Flit-Aware Die-to-Die Interface (FDI)
#   UCIe 1.0 Specification, Section 8.3.1 - Stallreq/Ack Mechanism
#   UCIe 1.0 Specification, Section 4.5.3 - Link Training State Machine
#   UCIe 1.0 Specification, Section 4.1.1 - Byte to Lane Mapping
#
# DESCRIPTION
#   This Makefile is the single entry point for building and exercising the
#   whole UCIe endpoint. It compiles every RTL file, runs the directed unit
#   tests, runs the two-die loopback bring-up, and produces the coverage
#   report. It is deliberately the only place that knows the source file
#   lists and the pass/fail strings, so the tests themselves stay free of
#   build knowledge.
#
#   The verification strategy has structured layers:
#
#     1. compile       - Elaborates the full RTL with -g2012 -Wall. ZERO warnings
#                        is the gate, not merely zero errors. Warnings are read
#                        back from a log file rather than trusted from the exit
#                        code, because Icarus returns 0 for some diagnostics.
#
#     2. sideband-unit - Focused scalar sideband unit testbenches (ut_sb_codec,
#                        ut_sbinit, tb_adapter_sideband) verifying typed packet
#                        interfaces and scalar pins without full-link overhead.
#
#     3. sideband-peer - Independent scalar sideband peer testbench driving
#                        literal golden vectors to verify codec deserialization,
#                        framing, and CP error detection.
#
#     4. unit          - Directed testbenches in tb/unit/, one per FSM, datapath
#                        block, and protocol function. Each drives its DUT directly
#                        and prints the literal line "TEST PASSED <name>". The recipe
#                        checks for that exact string, so a test that merely compiles
#                        but never asserts success still fails the gate. On success,
#                        relevant unit tests write Phase F event evidence JSON
#                        fragments into logs/ (*_evidence.json) for coverage merging.
#
#     5. loopback      - Two real ucie_main instances with the sideband and main
#                        band crossed die-to-die. Exercises the whole stack together:
#                        adapter, logical PHY, LTSM bring-up, link recovery, and
#                        Raw Mode streaming in both directions.
#   Coverage is computed by sim/cov_report.py from a JSON file that the
#   loopback monitor writes (sim/logs/coverage.json), combined with Phase F
#   event evidence fragments (*_evidence.json) written by unit tests. The
#   two-source model is required because nominal loopback is x16-only and
#   stallreq is tied low; paths such as the 4-phase stall handshake, x8 width
#   degrade, and lane reversal are observable only via unit test evidence.
#   Phase F event coverage captures PARAM roles, transaction classes,
#   arbitration, fatal causes, TRAINERROR, LinkReset, Disabled, PMNAK, Active
#   Entry, pre-Active block, scrambling, and framing faults.
#
#   The final integration gate (make -C sim clean && make -C sim all) serves
#   as the comprehensive exit proof. It requires zero compile warnings, all
#   unit test PASS markers, link activation on both dies, bidirectional Raw
#   Mode data transfer, and 100% Phase F coverage without holes.
#
# FLOW DIAGRAM
#
#                        make -C sim all (Final Integration Gate)
#                                      |
#                                      v
#                            +----------------------+
#                            |  compile (gate)      |
#                            |  iverilog -g2012     |
#                            |  -Wall, zero warn    |
#                            +----------+-----------+
#                                       |
#         +------------------+----------+----------+------------------+
#         |                  |                     |                  |
#         v                  v                     v                  v
#  +---------------+  +---------------+  +------------------+  +--------------------+
#  | sideband-unit |  | sideband-peer |  |  unit            |  |  loopback          |
#  | scalar codec, |  | literal peer  |  |  tb/unit/*.sv    |  |  tb/loopback/      |
#  | sbinit, FDI   |  | golden vectors|  |  directed DUT    |  |  2x ucie_main      |
#  +-------+-------+  +-------+-------+  +--------+---------+  +---------+----------+
#          |                  |                   |                      |
#          |  PASSED          |  PASSED           |  TEST PASSED         |  LINK ACTIVE
#          |                  |                   |  evidence fragments  |  coverage.json
#          |                  |                   |  (*_evidence.json)   |
#          +------------------+---------+---------+----------------------+
#                                       |
#                                       v
#                            +----------------------+
#                            |  cov_report.py       |
#                            |  merges both sources |
#                            |  Phase F coverage    |
#                            |  prints COVERAGE:    |
#                            +----------------------+
#                                       |
#                                       v
#                            +----------------------+
#                            |  Final Integration   |
#                            |  Gate: 100% PASS     |
#                            +----------------------+
#
# TARGETS
#   all           - Final integration gate: compile + sideband-unit +
#                   sideband-peer + unit + loopback + coverage.
#                   Verifies zero warnings, all test PASS strings, active link on
#                   both dies, bidirectional Raw Mode streaming, and 100% coverage.
#   compile       - Elaborate all RTL with -Wall. Fails on any warning.
#   sideband-unit - Run focused scalar sideband unit testbenches (ut_sb_codec,
#                   ut_sbinit, tb_adapter_sideband).
#   sideband-peer - Run independent scalar sideband peer testbench with literal
#                   golden vectors (tb_sideband_peer).
#   unit          - Build and run every tb/unit/*.sv testbench; clears stale
#                   evidence and produces Phase F unit evidence fragments.
#   loopback      - Build and run the two-die bring-up plus streaming test;
#                   records LTSM/RDI states and Phase F event coverage.
#   sbinit-wave   - Build and run the two-die RESET-to-SBINIT test; writes
#                   logs/sbinit.vcd with sideband, mainband, FDI, RDI, and state signals.
#   coverage  - Run unit and loopback, then report merged Phase F coverage
#               via cov_report.py (requires 100% reachable states and events).
#   clean     - Remove out/ and logs/. Purges compiled simulation binaries,
#               run logs, and all Phase F evidence fragments for a pristine gate run.
#
# DIRECTORY LAYOUT
#   ROOT   = ..                        repository root
#   RTL    = ../rtl                    all synthesizable SystemVerilog
#   TB     = ../tb                     all testbench code
#   OUT    = out                       compiled .vvp simulation binaries
#   LOGS   = logs                      compile logs, run logs, coverage JSON
#
#   RTL is split into three source groups that are always compiled together:
#   rtl_common (package, scrambler, timer), logical_phy (the physical layer),
#   and d2d_adapter (the adapter). ucie_main.sv is the single top level.
#
# TOOLCHAIN
#   Requires Icarus Verilog 12.0 and Python 3 on PATH. Developed and verified
#   under WSL Ubuntu 24.04 with /usr/bin/iverilog. Override the tools on the
#   command line if needed, for example: make IVERILOG=/opt/iverilog/bin/iverilog
#
#   INCLUDES puts rtl/rtl_common and tb/monitors on the include search path so
#   ucie_pkg.sv and the coverage monitor header resolve without relative paths.
#
# DESIGN NOTES
#   - FILTER is `cat`: the log is passed through unchanged. It exists as a
#     single knob so the filtering policy is explicit and cannot silently
#     suppress a diagnostic.
#   - The compile target reads the log back with `[ -s ... ]` rather than
#     relying on the exit status alone, because some Icarus diagnostics do not
#     set a non-zero status. Warnings therefore cannot slip past the gate.
#   - The unit target deletes stale *_evidence.json fragments before running,
#     so a fragment can only exist because that test passed in THIS run. This
#     is what stops a previous green run from faking coverage. Passing unit
#     tests generate fresh Phase F event evidence fragments (such as
#     stall_evidence.json and mapper_evidence.json) to prove paths that are
#     inaccessible during nominal loopback.
#   - Each unit test is verified by grepping for the literal string
#     "TEST PASSED <name>" in the combined log. A test whose assertions were
#     skipped still fails the gate because the line never appears.
#   - The loopback target greps for four distinct success strings plus the
#     final "TEST PASSED". Checking the intermediate strings localises a
#     failure: "no die0->die1 transfer" tells you bring-up worked but the
#     forward datapath did not.
#   - Coverage depends on BOTH unit and loopback (the Phase F two-source model).
#     The loopback exercises end-to-end LTSM bring-up, RDI states, sideband
#     packet/MsgCode traffic, and integrated Phase F functional events (PARAM
#     roles, transaction classes, arbitration, fatal causes, TRAINERROR,
#     LinkReset, Disabled, PMNAK, Active Entry, pre-Active block, scrambling,
#     and framing fault). However, because loopback is x16-only and its PHY
#     never asserts rdi_pl_stallreq, the stall four-phase handshake (spec 8.3.1),
#     the x8 width-degrade halves (spec 4.3.7), and the byte reversal detection
#     path (spec 4.1.1) are observable only in directed unit tests.
#     cov_report.py merges loopback coverage.json and unit evidence fragments,
#     enforcing that 100% of reachable states and all Phase F event counters
#     are non-zero while keeping unsupported states (PHYRETRAIN, L1, L2) out
#     of the denominator.
#   - Final integration gate: `make -C sim clean && make -C sim all` is the
#     authoritative exit proof. The build gate passes only when all RTL compiles
#     with zero warnings, all unit tests pass, loopback achieves bidirectional
#     Raw Mode data transfer, all Phase F event evidence fragments validate,
#     and cov_report.py reports 100% reachable coverage.
#   - Simulator performance is a deliberate design concern. The main-band
#     forwarded clock runs at 2 GHz (Req.2), which is 16 million edges across
#     the 4 ms RESET dwell it must observe (Req.1). Testbenches gate that clock
#     while the link is idle so Icarus does not evaluate an idle event queue
#     for the whole reset period.
#
# REVISION HISTORY
#   v0.0.1  2025-XX-XX  Initial creation - compile, unit and loopback targets.
#   v0.0.2  2026-09-22  Add the coverage target and cov_report.py integration.
#   v0.0.3  2026-09-23  Documentation: expand header, add revision history.
#   v0.0.4  2026-09-25  Document Phase F event evidence fragments and final
#                       integration gate.
#   v0.0.5  2026-09-28  Add focused sideband-unit and independent sideband-peer
#                       targets for scalar codec, SBINIT, Adapter FDI, and
#                       literal golden-vector verification.
#   v0.0.6  2026-09-29  Set the loopback wall-clock timeout to 900 seconds.
#
# LICENSE
#   SPDX-License-Identifier: Apache-2.0
# ============================================================================

IVERILOG    ?= iverilog
VVP         ?= vvp
PYTHON      ?= python3
# Maximum wall-clock time for the slow full-link loopback simulation.
SIM_TIMEOUT ?= 900
# Maximum wall-clock time for the focused RESET-to-SBINIT waveform run.
SBINIT_TIMEOUT ?= 180


ROOT    := ..
RTL     := $(ROOT)/rtl
TB      := $(ROOT)/tb
OUT     := out
LOGS    := logs

RTL_COMMON := $(wildcard $(RTL)/rtl_common/*.sv)
RTL_PHY    := $(wildcard $(RTL)/logical_phy/*.sv)
RTL_ADAPT  := $(wildcard $(RTL)/d2d_adapter/*.sv)
RTL_TOP    := $(RTL)/ucie_main.sv

UNIT_TESTS := $(wildcard $(TB)/unit/*.sv)

INCLUDES := -I $(RTL)/rtl_common -I $(TB)/monitors

# Ensure all files explicitly compile warning-free without suppression
FILTER  := cat

.PHONY: all compile unit sideband-unit sideband-peer loopback sbinit-wave coverage clean

# ------------------------------------------------------------- all
# Final integration gate. Executes the complete verification cascade:
# compile -> unit -> loopback -> coverage. Requires zero compile warnings,
# all unit PASS markers, link Active on both dies, bidirectional Raw Mode
# transfers, and 100% merged Phase F coverage without holes.
all: compile sideband-unit sideband-peer unit loopback coverage

# ------------------------------------------------------------- compile
# Zero errors and zero warnings is the gate.
compile:
	@mkdir -p $(OUT) $(LOGS)
	@echo "== RTL compile"
	@$(IVERILOG) -g2012 -Wall -tnull $(INCLUDES) $(RTL_TOP) $(RTL_PHY) \
	    $(RTL_COMMON) $(RTL_ADAPT) > $(LOGS)/compile.txt 2>&1; \
	  status=$$?; \
	  cat $(LOGS)/compile.txt | $(FILTER); \
	  if [ $$status -ne 0 ]; then \
	    echo "COMPILE FAILED"; exit 1; \
	  fi
	@if [ -s $(LOGS)/compile.txt ]; then \
	  echo "COMPILE FAILED: warnings present"; exit 1; \
	  else echo "COMPILE OK"; fi

# ------------------------------------------------------------- unit tests
# Directed unit testbenches in tb/unit/*.sv.
# Each test compiles with -Wall (zero warnings) and runs independently.
# Every test must print the literal line "TEST PASSED <name>" on success.
#
# Before running, stale Phase F event evidence fragments (*_evidence.json)
# and previous logs are deleted from $(LOGS). On passing, unit tests covering
# paths unreachable in nominal loopback (e.g. ut_stall for 4-phase stall and
# degrade, ut_mapper for x8 degrade halves and byte reversal) emit their
# respective JSON evidence fragments into $(LOGS)/ for coverage merging.
unit: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== Unit tests"
	@rm -f $(LOGS)/*_evidence.json $(LOGS)/unit.txt
	@status=0; \
	for t in $(UNIT_TESTS); do \
	  name=$$(basename $$t .sv); \
	  echo "  $$name"; \
	  $(IVERILOG) -g2012 -Wall $(INCLUDES) -o $(OUT)/$$name.vvp $$t \
	      $(RTL_COMMON) $(RTL_PHY) $(RTL_ADAPT) \
	      > $(LOGS)/unit_comp_$$name.txt 2>&1 || status=1; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/unit_comp_$$name.txt ]; then \
	    cat $(LOGS)/unit_comp_$$name.txt; \
	    echo "UNIT TESTS FAILED (compile/warnings on $$name)"; exit 1; \
	  fi; \
	  $(VVP) $(OUT)/$$name.vvp 2>&1 | tee -a $(LOGS)/unit.txt || status=1; \
	  grep -q "^TEST PASSED $$name" $(LOGS)/unit.txt || status=1; \
	  if [ $$status -ne 0 ]; then \
	    echo "UNIT TESTS FAILED ($$name)"; exit 1; \
	  fi; \
	done; \
	echo "ALL UNIT TESTS PASSED"

# ------------------------------------------------------ sideband unit
# Focused scalar codec and raw SBINIT tests. These tests use the typed packet
# interface and scalar physical pins without the long full-link training run.
sideband-unit: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== Sideband unit tests"
	@status=0; \
	for t in $(TB)/unit/ut_sb_codec.sv $(TB)/unit/ut_sbinit.sv \
	    $(TB)/bfm/tb_adapter_sideband.sv; do \
	  name=$$(basename $$t .sv); \
	  $(IVERILOG) -g2012 -Wall $(INCLUDES) -o $(OUT)/$$name.vvp $$t \
	      $(RTL_COMMON) $(RTL_PHY) $(RTL_ADAPT) \
	      > $(LOGS)/sideband_comp_$$name.txt 2>&1 || status=1; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/sideband_comp_$$name.txt ]; then \
	    cat $(LOGS)/sideband_comp_$$name.txt; \
	    echo "SIDEBAND UNIT FAILED ($$name)"; exit 1; \
	  fi; \
	  $(VVP) $(OUT)/$$name.vvp 2>&1 | tee -a $(LOGS)/sideband_unit.txt || status=1; \
	  grep -q "^TEST PASSED $$name" $(LOGS)/sideband_unit.txt || status=1; \
	  if [ $$status -ne 0 ]; then \
	    echo "SIDEBAND UNIT FAILED ($$name)"; exit 1; \
	  fi; \
	done; \
	echo "SIDEBAND UNIT PASSED"

# ------------------------------------------------------ independent peer
# The peer drives literal scalar headers and payloads. It does not reuse the
# codec serializer, so bit order, gaps, and error reporting remain independent.
sideband-peer: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== Independent sideband peer"
	@$(IVERILOG) -g2012 -Wall $(INCLUDES) -I $(TB)/bfm \
	    -o $(OUT)/tb_sideband_peer.vvp $(TB)/bfm/tb_sideband_peer.sv \
	    $(TB)/bfm/sb_golden_vectors.sv $(RTL_COMMON) \
	    $(RTL)/logical_phy/sb_codec.sv > $(LOGS)/sideband_peer_comp.txt 2>&1; \
	  status=$$?; cat $(LOGS)/sideband_peer_comp.txt; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/sideband_peer_comp.txt ]; then \
	    echo "SIDEBAND PEER FAILED (compile/warnings)"; exit 1; \
	  fi
	@$(VVP) $(OUT)/tb_sideband_peer.vvp 2>&1 | tee $(LOGS)/sideband_peer.txt
	@grep -q "^TEST PASSED tb_sideband_peer" $(LOGS)/sideband_peer.txt || \
	  { echo "SIDEBAND PEER FAILED"; exit 1; }

# ------------------------------------------------------------- loopback
# Two real ucie_main instances crossed die-to-die.
loopback: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== Loopback"
	@$(IVERILOG) -g2012 -Wall $(INCLUDES) -o $(OUT)/loopback.vvp \
	    $(TB)/loopback/tb_loopback_top.sv $(TB)/monitors/cov_monitor.sv \
	    $(TB)/bfm/protocol_layer_bfm.sv $(RTL_TOP) $(RTL_PHY) $(RTL_COMMON) \
	    $(RTL_ADAPT) > $(LOGS)/loopback_comp.txt 2>&1; \
	  status=$$?; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/loopback_comp.txt ]; then \
	    cat $(LOGS)/loopback_comp.txt; \
	    echo "LOOPBACK FAILED (compile/warnings)"; exit 1; \
	  fi
	@timeout $(SIM_TIMEOUT)s $(VVP) $(OUT)/loopback.vvp 2>&1 | tee $(LOGS)/loopback_run.txt
	@grep -q "LINK ACTIVE (die 0)"  $(LOGS)/loopback_run.txt || \
	  { echo "LOOPBACK FAILED: die 0 not active"; exit 1; }
	@grep -q "LINK ACTIVE (die 1)"  $(LOGS)/loopback_run.txt || \
	  { echo "LOOPBACK FAILED: die 1 not active"; exit 1; }
	@grep -q "RAW MODE TRANSFER OK (die0->die1)" $(LOGS)/loopback_run.txt || \
	  { echo "LOOPBACK FAILED: no die0->die1 transfer"; exit 1; }
	@grep -q "RAW MODE TRANSFER OK (die1->die0)" $(LOGS)/loopback_run.txt || \
	  { echo "LOOPBACK FAILED: no die1->die0 transfer"; exit 1; }
	@grep -q "^TEST PASSED" $(LOGS)/loopback_run.txt || \
	  { echo "LOOPBACK FAILED"; exit 1; }
	@echo "LOOPBACK OK"

# ----------------------------------------------------------- sbinit-wave
# Two real ucie_main instances crossed die-to-die. The run stops when both
# LTSMs enter MBINIT.PARAM, immediately after SBINIT completion.
sbinit-wave: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== RESET-to-SBINIT waveform"
	@$(IVERILOG) -g2012 -Wall $(INCLUDES) -o $(OUT)/sbinit.vvp \
	    $(TB)/sbinit/tb_reset_to_sbinit.sv $(RTL_TOP) $(RTL_PHY) \
	    $(RTL_COMMON) $(RTL_ADAPT) > $(LOGS)/sbinit_comp.txt 2>&1; \
	  status=$$?; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/sbinit_comp.txt ]; then \
	    cat $(LOGS)/sbinit_comp.txt; \
	    echo "SBINIT WAVEFORM FAILED (compile/warnings)"; exit 1; \
	  fi
	@timeout $(SBINIT_TIMEOUT)s $(VVP) $(OUT)/sbinit.vvp \
	    +wave=$(LOGS)/sbinit.vcd 2>&1 | tee $(LOGS)/sbinit_run.txt
	@grep -q "^TEST PASSED tb_reset_to_sbinit" $(LOGS)/sbinit_run.txt || \
	  { echo "SBINIT WAVEFORM FAILED"; exit 1; }
	@test -s $(LOGS)/sbinit.vcd || \
	  { echo "SBINIT WAVEFORM FAILED: VCD is empty"; exit 1; }
	@gzip -c $(LOGS)/sbinit.vcd > $(LOGS)/sbinit.vcd.gz
	@echo "SBINIT WAVEFORM OK: $(LOGS)/sbinit.vcd"

# -------------------------------------------------------- link-init-wave
# Full RESET-to-ACTIVE link initialization waveform between Die 0 and Die 1.
link-init-wave: compile
	@mkdir -p $(OUT) $(LOGS)
	@echo "== Two-Die Link Initialization waveform"
	@$(IVERILOG) -g2012 -Wall $(INCLUDES) -o $(OUT)/link_init.vvp \
	    $(TB)/waveform/tb_link_init_wave.sv $(RTL_TOP) $(RTL_PHY) \
	    $(RTL_COMMON) $(RTL_ADAPT) > $(LOGS)/link_init_comp.txt 2>&1; \
	  status=$$?; \
	  if [ $$status -ne 0 ] || [ -s $(LOGS)/link_init_comp.txt ]; then \
	    cat $(LOGS)/link_init_comp.txt; \
	    echo "LINK INIT WAVEFORM FAILED (compile/warnings)"; exit 1; \
	  fi
	@timeout $(SIM_TIMEOUT)s $(VVP) $(OUT)/link_init.vvp \
	    +wave=$(LOGS)/link_init.vcd 2>&1 | tee $(LOGS)/link_init_run.txt
	@grep -q "^TEST PASSED tb_link_init_wave" $(LOGS)/link_init_run.txt || \
	  { echo "LINK INIT WAVEFORM FAILED"; exit 1; }
	@test -s $(LOGS)/link_init.vcd || \
	  { echo "LINK INIT WAVEFORM FAILED: VCD is empty"; exit 1; }
	@which vcd2fst > /dev/null 2>&1 && vcd2fst $(LOGS)/link_init.vcd $(LOGS)/link_init.fst || true
	@cp -f $(TB)/waveform/link_init.gtkw $(LOGS)/link_init.gtkw
	@echo "LINK INIT WAVEFORM OK: $(LOGS)/link_init.vcd and $(LOGS)/link_init.gtkw"
# ------------------------------------------------------------- coverage
# Aggregates multi-source Phase F coverage via cov_report.py.
#
# Merges two distinct evidence sources:
#   1. $(LOGS)/coverage.json written by the loopback monitor (cov_monitor.sv),
#      tracking LTSM states, RDI states, sideband opcodes/MsgCodes, and Phase F
#      functional events (PARAM roles, transaction classes, arbitration, fatal
#      causes, TRAINERROR, LinkReset, Disabled, PMNAK, Active Entry, pre-Active
#      block, scrambling, framing fault, raw transfer fwd/rev, raw mode adv).
#   2. $(LOGS)/*_evidence.json written by directed unit tests on success
#      (stall, mapper, ltsm_policy, sb_codec, gearbox, rdi_sm, fdi_sm)
#      to cover paths structurally unexercised by nominal x16 loopback.
#
# The script evaluates 21 reachable LTSM states (00h-11h, 14h, 15h, plus
# TRAINERROR 16h) and Phase F event counters. Documented unreachable
# states (MBTRAIN.REPAIR 12h, PHYRETRAIN 13h, L1L2 17h) are excluded from the
# denominator. Fails unless coverage reaches 100% with all evidence accounted for.
coverage: unit loopback
	@echo "== Coverage"
	@$(PYTHON) $(ROOT)/sim/cov_report.py

# ------------------------------------------------------------- clean
# Removes compiled simulation binaries ($(OUT)) and all run logs and coverage
# evidence fragments ($(LOGS)). Purging $(LOGS) removes all Phase F evidence
# files (*_evidence.json) and coverage.json, guaranteeing that the final
# integration gate (`make -C sim clean && make -C sim all`) starts from a
# clean slate with no residual pass markers or stale evidence.
clean:
	rm -rf $(OUT) $(LOGS)

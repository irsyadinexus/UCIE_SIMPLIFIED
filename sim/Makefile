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
#   The verification strategy has three independent layers:
#
#     1. compile  - Elaborates the full RTL with -g2012 -Wall. ZERO warnings
#                   is the gate, not merely zero errors. Warnings are read
#                   back from a log file rather than trusted from the exit
#                   code, because Icarus returns 0 for some diagnostics.
#
#     2. unit     - Eight directed testbenches in tb/unit/, one per FSM and
#                   datapath block. Each drives its DUT directly and prints
#                   the literal line "TEST PASSED <name>". The recipe checks
#                   for that exact string, so a test that merely compiles but
#                   never asserts success still fails the gate.
#
#     3. loopback - Two real ucie_main instances with the sideband and main
#                   band crossed die-to-die. This is the only test that
#                   exercises the whole stack together: adapter, logical PHY,
#                   LTSM bring-up, and Raw Mode streaming in both directions.
#
#   Coverage is computed by sim/cov_report.py from a JSON file that the
#   loopback monitor writes, combined with per-test evidence fragments. See
#   the coverage target below for why two sources are required.
#
# FLOW DIAGRAM
#
#                        make -C sim all
#                              |
#                              v
#                   +----------------------+
#                   |  compile (gate)      |
#                   |  iverilog -g2012     |
#                   |  -Wall, zero warn    |
#                   +----------+-----------+
#                              |
#              +---------------+---------------+
#              |                               |
#              v                               v
#     +------------------+           +--------------------+
#     |  unit            |           |  loopback          |
#     |  tb/unit/*.sv    |           |  tb/loopback/      |
#     |  8 directed DUT  |           |  2x ucie_main      |
#     |  testbenches     |           |  crossed die-to-die|
#     +--------+---------+           +---------+----------+
#              |                               |
#              |  TEST PASSED <name>           |  LINK ACTIVE (die 0/1)
#              |  *_evidence.json              |  RAW MODE TRANSFER OK
#              |                               |  coverage.json
#              +---------------+---------------+
#                              |
#                              v
#                   +----------------------+
#                   |  cov_report.py       |
#                   |  merges both sources |
#                   |  prints COVERAGE:    |
#                   +----------------------+
#
# TARGETS
#   all       - compile + unit + loopback + coverage. The full gate.
#   compile   - Elaborate all RTL with -Wall. Fails on any warning.
#   unit      - Build and run every tb/unit/*.sv testbench.
#   loopback  - Build and run the two-die bring-up plus streaming test.
#   coverage  - Run unit and loopback, then report merged coverage.
#   clean     - Remove out/ and logs/.
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
#     is what stops a previous green run from faking coverage.
#   - Each unit test is verified by grepping for the literal string
#     "TEST PASSED <name>" in the combined log. A test whose assertions were
#     skipped still fails the gate because the line never appears.
#   - The loopback target greps for four distinct success strings plus the
#     final "TEST PASSED". Checking the intermediate strings localises a
#     failure: "no die0->die1 transfer" tells you bring-up worked but the
#     forward datapath did not.
#   - Coverage depends on BOTH unit and loopback. The loopback is x16-only and
#     its PHY never asserts rdi_pl_stallreq, so the stall four-phase
#     (spec 8.3.1), the x8 width-degrade halves and the byte reversal
#     (spec 4.1.1) are observable only in the directed unit tests. The report
#     needs both sources to reach 100%.
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
#
# LICENSE
#   SPDX-License-Identifier: Apache-2.0
# ============================================================================

IVERILOG ?= iverilog
VVP     ?= vvp
PYTHON  ?= python3

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

.PHONY: all compile unit loopback coverage clean

all: compile unit loopback coverage

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
# Each test prints TEST PASSED <name> on success.
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
	@$(VVP) $(OUT)/loopback.vvp 2>&1 | tee $(LOGS)/loopback_run.txt
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

# ------------------------------------------------------------- coverage
# Reads the JSON the loopback monitor wrote, plus a per-test evidence file
# each unit test writes on success. The loopback is x16-only and its PHY
# never asserts rdi_pl_stallreq, so the stall four-phase, the x8 degrade
# and the byte reversal paths are observable only in the unit tests; the
# report requires both sources.
coverage: unit loopback
	@echo "== Coverage"
	@$(PYTHON) $(ROOT)/sim/cov_report.py

clean:
	rm -rf $(OUT) $(LOGS)

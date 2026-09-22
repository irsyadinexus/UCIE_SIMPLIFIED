# UCIe 1.0 Simplified Endpoint - simulation driver.
#
# Targets: compile / unit / loopback / coverage / clean / all
#
# Requires Icarus Verilog 12.0 and Python 3 on PATH. Developed and verified
# under WSL Ubuntu 24.04 with /usr/bin/iverilog.

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

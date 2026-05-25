# cocotb Makefile -- runs tb_top.py against project/m3/rtl/top.sv +
# the M3 support blocks + acc_fp32 (fp32_to_bf16 only).
#
# Lives alongside tb_top.py (the cocotb file is named tb_top.py per
# the M2 deviation note that is reproduced in project/m3/README.md;
# the M3 spec lists it as `tb_top.sv`). cocotb 2.0 honors COCOTB_TEST
# filtering so individual tests can be run with COCOTB_TESTCASE=...
#
# Captures into ./artifacts/:
#     artifacts/top_sim.log   -- full cocotb run log
#     artifacts/top.vcd       -- VCD waveform of `top` (ENABLE_VCD=1 only)
#     artifacts/dump_vcd.v    -- auto-generated dump wrapper
#
# Prereq: workspace-root .venv-cocotb (same as M2).
#
# Usage:
#   make                       # default: TEST=top (no VCD at 48x48)
#   make ENABLE_VCD=1            # enable full VCD (very large at 48x48)
#   make m3-log                # regenerate ../sim/cosim_run.log
#   make clean

VENV     ?= $(abspath $(CURDIR)/../../../.venv-cocotb)
VENV_BIN := $(VENV)/bin
export PATH := $(VENV_BIN):$(PATH)

TEST ?= top

M3_RTL_DIR := $(abspath $(CURDIR)/../rtl)
M2_RTL_DIR := $(abspath $(CURDIR)/../../m2/rtl)

SIM            = icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL       = $(TEST)
COCOTB_TEST_MODULES = tb_$(TEST)

# IEEE-1800-2012 dialect for `always_ff` / `always_comb` / `logic` /
# typedef enum / etc.
COMPILE_ARGS += -g2012

# ----------------------------------------------------------------------
# Source list: every .sv under m3/rtl/ + acc_fp32 (fp32_to_bf16 in drain).
# M2 compute_core / pe / mul_bf16 are NOT used; M3 has its own pipelined
# replacements.
# ----------------------------------------------------------------------
M3_SOURCES := $(wildcard $(M3_RTL_DIR)/*.sv)
M2_REUSED  := $(M2_RTL_DIR)/acc_fp32.sv

# ----------------------------------------------------------------------
# Artifacts: VCD + log
# ----------------------------------------------------------------------
ARTIFACTS_DIR := artifacts
LOG_FILE      := $(ARTIFACTS_DIR)/$(TEST)_sim.log
VCD_FILE      := $(ARTIFACTS_DIR)/$(TEST).vcd
DUMP_WRAPPER  := $(ARTIFACTS_DIR)/dump_vcd.v

# Full VCD at 48x48 is multi-GB and slows sim enormously; off by default.
ENABLE_VCD ?= 1

VERILOG_SOURCES = $(M3_SOURCES) $(M2_REUSED)
ifeq ($(ENABLE_VCD),1)
VERILOG_SOURCES += $(DUMP_WRAPPER)
COMPILE_ARGS    += -s dump_vcd
CUSTOM_COMPILE_DEPS += $(DUMP_WRAPPER)
endif

$(ARTIFACTS_DIR):
	mkdir -p $@

$(DUMP_WRAPPER): | $(ARTIFACTS_DIR)
	@echo 'module dump_vcd();'                 >  $@
	@echo 'initial begin'                       >> $@
	@echo '    $$dumpfile("$(VCD_FILE)");'      >> $@
	@echo '    $$dumpvars(0, $(TOPLEVEL));'     >> $@
	@echo 'end'                                 >> $@
	@echo 'endmodule'                           >> $@

.PHONY: run
run: | $(ARTIFACTS_DIR)
	@bash -c 'set -o pipefail; $(MAKE) sim 2>&1 | tee $(LOG_FILE)'

include $(shell $(VENV_BIN)/cocotb-config --makefiles)/Makefile.sim

.DEFAULT_GOAL := run

clean::
	@$(RM) -rf $(ARTIFACTS_DIR)

# ----------------------------------------------------------------------
# M3 deliverable target: regenerate ../sim/cosim_run.log
# ----------------------------------------------------------------------
SIM_DIR := $(abspath $(CURDIR)/../sim)

.PHONY: m3-log
m3-log:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory TEST=top ENABLE_VCD=0
	@mkdir -p $(SIM_DIR)
	@cp $(ARTIFACTS_DIR)/top_sim.log $(SIM_DIR)/cosim_run.log
	@echo "==> $(SIM_DIR)/cosim_run.log updated"
	@grep -E '^[[:space:]]*[0-9]+\.[0-9]+ns[[:space:]]+INFO.*(PASS|FAIL):' \
	    $(SIM_DIR)/cosim_run.log || true

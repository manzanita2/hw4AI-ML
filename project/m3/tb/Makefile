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
#   make                       # default: TEST=top, M=N=16 @ 100 MHz
#   make ENABLE_VCD=0           # disable VCD dump (faster)
#   make m3-log                # regenerate ../sim/cosim_run.log
#   make synth-yosys           # yosys synth/stat at the same M/N
#   make clean

VENV     ?= $(abspath $(CURDIR)/../../../.venv-cocotb)
VENV_BIN := $(VENV)/bin
export PATH := $(VENV_BIN):$(PATH)

TEST ?= top

# ----------------------------------------------------------------------
# Design point -- single-sourced for BOTH the co-sim and `synth-yosys`.
# Icarus 14 cannot override a top-level parameter from the CLI, so the
# elaborated RTL always uses top.sv's `parameter int M/N` defaults.
# These vars MUST equal those defaults (currently 16/16); they are
# exported so tb_top.py reads the same size/clock the RTL was built with
# (a mismatch makes test_gemm_tile_e2e FAIL loudly, never silently pass).
# The same M/N feed `chparam` in the synth-yosys target below.
# ----------------------------------------------------------------------
M ?= 16
N ?= 16
CLK_PERIOD_NS ?= 10              # 10 ns -> 100 MHz
export M
export N
export CLK_PERIOD_NS

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

# At M=N=16 the VCD is small, so it's on by default (needed for the
# cosim_waveform.png deliverable). Set ENABLE_VCD=0 to skip it.
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

# ----------------------------------------------------------------------
# Yosys synth check at the SAME M/N as the co-sim (manual target).
# ----------------------------------------------------------------------
# Icarus can't parameterize top, but yosys can via `chparam`, so the
# sized elaboration / gate-count check lives here rather than in a
# hand-typed command. Source list mirrors synth/config.json: every
# m3/rtl/*.sv (mul_bf16_p2 is an unused predecessor and gets DCE'd by
# `synth -top top`) plus m2/rtl/acc_fp32.sv (for fp32_to_bf16). The full
# OpenLane 2 P&R flow is run by hand per project/m3/README.md.
SYNTH_DIR  := $(abspath $(CURDIR)/../synth)
YOSYS_SRCS := $(M3_SOURCES) $(M2_REUSED)
YOSYS_LOG   = $(SYNTH_DIR)/yosys_$(M)x$(N)_run.log

.PHONY: synth-yosys
synth-yosys:
	@mkdir -p $(SYNTH_DIR)
	yosys -p "read_verilog -sv $(YOSYS_SRCS); \
	          chparam -set M $(M) -set N $(N) top; \
	          synth -top top; stat" 2>&1 | tee $(YOSYS_LOG)
	@echo "==> $(YOSYS_LOG) updated (M=$(M) N=$(N))"

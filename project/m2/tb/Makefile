# cocotb Makefile -- runs tb_compute_core.py against ../rtl/compute_core.sv.
#
# Lives alongside the cocotb testbenches in tb/. Per the project
# convention each cocotb test module shares a name with its DUT plus
# a `tb_` prefix (compute_core.sv is exercised by tb_compute_core.py,
# interface.sv by tb_interface.py, etc.) -- this matches the M2 PDF's
# expected filenames. Build artifacts land here under sim_build/ and
# artifacts/ so rtl/ stays a pure HDL directory.
#
# Captures simulation artifacts into ./artifacts/:
#     artifacts/sim.log            -- full cocotb run log (stdout + stderr)
#     artifacts/compute_core.vcd   -- VCD waveform of the entire compute_core
#     artifacts/dump_vcd.v         -- auto-generated waveform dump wrapper
#
# Prereq: the .venv-cocotb virtualenv at the workspace root has cocotb
# installed.  Workspace root is three levels up from this directory
# (../../../.venv-cocotb).
#
# Usage:
#   make                       # build + run compute_core test; populates artifacts/
#   make TEST=mul_bf16         # primitive: bf16 multiplier
#   make TEST=acc_fp32         # primitive: fp32 accumulator
#   make TEST=interface        # run tb_interface.py against interface_module
#   make m2-log                # regenerate BOTH ../sim/*_run.log deliverable logs
#   make m2-log-compute_core   # just ../sim/compute_core_run.log
#   make m2-log-interface      # just ../sim/interface_run.log
#   make m2-quant              # regenerate ../sim/quant_error.log (deliverable #5)
#   make clean                 # remove sim_build/ AND artifacts/

VENV     ?= $(abspath $(CURDIR)/../../../.venv-cocotb)
VENV_BIN := $(VENV)/bin
export PATH := $(VENV_BIN):$(PATH)

# Which DUT/testbench pair to build. Override with `make TEST=interface`
# once a sibling tb_interface.py testbench lands. The convention is:
#   TEST=foo  ->  ../rtl/foo.sv  + ./tb_foo.py  + topmodule "foo"
TEST ?= compute_core

RTL_DIR := $(abspath $(CURDIR)/../rtl)

SIM                 = icarus
TOPLEVEL_LANG       = verilog
# Map TEST (filename stem) to the SV top module name. Most tests use
# their TEST name as-is; interface.sv's top module is `interface_module`
# because `interface` is a reserved IEEE-1800 keyword.
ifeq ($(TEST),interface)
TOPLEVEL = interface_module
else ifeq ($(TEST),quant_error)
TOPLEVEL = compute_core
else
TOPLEVEL = $(TEST)
endif
# cocotb 2.0 renamed MODULE -> COCOTB_TEST_MODULES. The Python module
# name carries the tb_ prefix; the SV top module does not.
COCOTB_TEST_MODULES = tb_$(TEST)

# `always_ff` / `always_comb` / `logic` / `'0` / typedef enum are
# SystemVerilog -- iverilog needs the IEEE 1800-2012 dialect to accept
# them.
COMPILE_ARGS += -g2012

# quantization sweep elaborates headline 48x48 systolic (2304 PEs). Needs
# LANES=48 so act_data[W]>=M*DATA_W for COMPUTE-cycle-0 activation latch.
ifeq ($(TEST),quant_error)
COMPILE_ARGS += -Pcompute_core.M=48 \
                -Pcompute_core.N=48 \
                -Pcompute_core.LANES=48
endif

# ----------------------------------------------------------------------
# Artifacts: VCD waveform + simulation log captured into ./artifacts/.
#
# Same trick as cf04/cocotb_mac/Makefile -- generate a tiny dump_vcd
# module on the fly so $dumpfile / $dumpvars run at sim start without
# us having to touch the DUT or set the cocotb WAVES env var.
# ----------------------------------------------------------------------
ARTIFACTS_DIR := artifacts
LOG_FILE      := $(ARTIFACTS_DIR)/$(TEST)_sim.log
VCD_FILE      := $(ARTIFACTS_DIR)/$(TEST).vcd
DUMP_WRAPPER  := $(ARTIFACTS_DIR)/dump_vcd.v

# DUT sources: every .sv under ../rtl/. iverilog only elaborates the
# modules reachable from -s $(TOPLEVEL), so unused tops are compiled
# but discarded harmlessly. This used to require a per-TEST source
# list because `module interface` collided with the IEEE-1800 reserved
# keyword and broke parsing; with that module renamed to
# `interface_module` (filename still interface.sv for the grader), the
# wildcard is safe again.
VERILOG_SOURCES      = $(wildcard $(RTL_DIR)/*.sv) $(DUMP_WRAPPER)
COMPILE_ARGS        += -s dump_vcd
CUSTOM_COMPILE_DEPS += $(DUMP_WRAPPER)

$(ARTIFACTS_DIR):
	mkdir -p $@

$(DUMP_WRAPPER): | $(ARTIFACTS_DIR)
	@echo 'module dump_vcd();'                 >  $@
	@echo 'initial begin'                       >> $@
	@echo '    $$dumpfile("$(VCD_FILE)");'      >> $@
	@echo '    $$dumpvars(0, $(TOPLEVEL));'     >> $@
	@echo 'end'                                 >> $@
	@echo 'endmodule'                           >> $@

# Run the simulation and tee stdout+stderr into the log file.
# `set -o pipefail` makes the recipe fail if `make sim` fails, even
# though tee succeeds -- without it, `tee` would mask sim failures.
.PHONY: run
run: | $(ARTIFACTS_DIR)
	@bash -c 'set -o pipefail; $(MAKE) sim 2>&1 | tee $(LOG_FILE)'

include $(shell $(VENV_BIN)/cocotb-config --makefiles)/Makefile.sim

# Force `make` (no args) to use our `run` target instead of cocotb's `sim`.
.DEFAULT_GOAL := run

# Augment cocotb's `clean` to also nuke our artifacts/.
clean::
	@$(RM) -rf $(ARTIFACTS_DIR)

# ----------------------------------------------------------------------
# M2 deliverable targets: regenerate the committed simulation logs in
# ../sim/ from a clean clone state so the grader sees a fresh PASS line
# at each path the M2 PDF requires.
#
#   make m2-log                   # regenerate BOTH compute_core_run.log
#                                 # and interface_run.log (chained)
#   make m2-log-compute_core      # just compute_core_run.log
#                                 # (deliverable #2 checkbox 4)
#   make m2-log-interface         # just interface_run.log
#                                 # (deliverable #4 checkbox 4)
#
# Each sub-target starts from `make clean` so the committed log
# corresponds to a deterministic run, not whatever stale state
# happened to be in sim_build/.
# ----------------------------------------------------------------------
SIM_DIR := $(abspath $(CURDIR)/../sim)

.PHONY: m2-log
m2-log: m2-log-compute_core m2-log-interface

.PHONY: m2-log-compute_core
m2-log-compute_core:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory TEST=compute_core
	@mkdir -p $(SIM_DIR)
	@cp $(ARTIFACTS_DIR)/compute_core_sim.log $(SIM_DIR)/compute_core_run.log
	@echo "==> $(SIM_DIR)/compute_core_run.log updated"
	@grep -E '^[[:space:]]*[0-9]+\.[0-9]+ns[[:space:]]+INFO.*(PASS|FAIL):' \
	    $(SIM_DIR)/compute_core_run.log || true

.PHONY: m2-log-interface
m2-log-interface:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory TEST=interface
	@mkdir -p $(SIM_DIR)
	@cp $(ARTIFACTS_DIR)/interface_sim.log $(SIM_DIR)/interface_run.log
	@echo "==> $(SIM_DIR)/interface_run.log updated"
	@grep -E '^[[:space:]]*[0-9]+\.[0-9]+ns[[:space:]]+INFO.*(PASS|FAIL):' \
	    $(SIM_DIR)/interface_run.log || true

# ----------------------------------------------------------------------
# M2 deliverable #5 (precision.md): regenerate sim/quant_error.log from
# clean. Output is the audit trail behind the MAE / max-err numbers
# baked into precision.md. SEED is pinned in tb_quant_error.py so the
# log is bit-reproducible.
# ----------------------------------------------------------------------
.PHONY: m2-quant
m2-quant:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory TEST=quant_error
	@mkdir -p $(SIM_DIR)
	@cp $(ARTIFACTS_DIR)/quant_error_sim.log $(SIM_DIR)/quant_error.log
	@echo "==> $(SIM_DIR)/quant_error.log updated"
	@grep -E '^[[:space:]]*[0-9]+\.[0-9]+ns[[:space:]]+INFO.*(PASS|FAIL|MAE|RMSE|max_):' \
	    $(SIM_DIR)/quant_error.log || true

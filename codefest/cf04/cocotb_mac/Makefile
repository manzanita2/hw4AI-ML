# cocotb Makefile -- runs mac_tb.py against mac_correct.v.
#
# Captures simulation artifacts into ./artifacts/:
#     artifacts/sim.log   -- full cocotb run log (stdout + stderr)
#     artifacts/mac.vcd   -- VCD waveform of the entire `mac` instance
#     artifacts/dump_vcd.v -- auto-generated waveform dump wrapper
#
# Prereq: the .venv-cocotb virtualenv at the workspace root has cocotb installed.
#
# Usage:
#   make            # build + run; populates artifacts/
#   make clean      # remove sim_build/ AND artifacts/

VENV     ?= $(abspath $(CURDIR)/../../../.venv-cocotb)
VENV_BIN := $(VENV)/bin
export PATH := $(VENV_BIN):$(PATH)

SIM                 = icarus
TOPLEVEL_LANG       = verilog
TOPLEVEL            = mac
# cocotb 2.0 renamed MODULE -> COCOTB_TEST_MODULES.
COCOTB_TEST_MODULES = mac_tb

# `always_ff` / `logic` / `'0` are SystemVerilog -- iverilog needs the
# IEEE 1800-2012 dialect to accept them.
COMPILE_ARGS += -g2012

# ----------------------------------------------------------------------
# Artifacts: VCD waveform + simulation log captured into ./artifacts/.
#
# Strategy:
#   - We auto-generate a tiny dump_vcd module that opens artifacts/mac.vcd
#     at simulation start and dumps the full hierarchy of `mac`.  This
#     mirrors what cocotb does internally when WAVES=1, but emits VCD
#     instead of FST.
#   - `-s dump_vcd` makes iverilog treat that module as an extra top
#     so its `initial` block actually runs.
#   - We DO NOT set the cocotb WAVES variable; that would either install
#     cocotb's own FST wrapper (WAVES=1) or pass `-none` to vvp and
#     suppress all dumps (WAVES=0).
#   - The `run` target below pipes the cocotb sim output through tee so
#     the same text that prints to the terminal lands in artifacts/sim.log.
# ----------------------------------------------------------------------
ARTIFACTS_DIR := artifacts
LOG_FILE      := $(ARTIFACTS_DIR)/sim.log
VCD_FILE      := $(ARTIFACTS_DIR)/mac.vcd
DUMP_WRAPPER  := $(ARTIFACTS_DIR)/dump_vcd.v

# Use relative paths (not $(PWD)/...) so the strings here are
# byte-identical to the targets defined below; make matches by string,
# not by realpath.
VERILOG_SOURCES      = mac_correct.v $(DUMP_WRAPPER)
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

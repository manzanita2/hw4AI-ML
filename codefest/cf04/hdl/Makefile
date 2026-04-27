# cocotb Makefile for the INT8 MAC testbench (mac_tb.py).
#
# Prereqs:
#   The .venv-cocotb virtualenv at the workspace root must exist and have
#   cocotb installed.  To rebuild it from scratch:
#       python -m venv ../../../.venv-cocotb
#       ../../../.venv-cocotb/bin/pip install cocotb
#   iverilog must be on PATH (Icarus Verilog 14.0+).
#
# Pick which DUT to drive against the same testbench:
#   make                # default: DUT=B  (mac_llm_B.v)
#   make DUT=A          # mac_llm_A.v
#   make DUT=correct    # mac_correct.v
#
# Yosys synthesis (one target per LLM):
#   make synth-A        # synthesize mac_llm_A.v
#   make synth-B        # synthesize mac_llm_B.v
#   make synth-correct  # synthesize mac_correct.v
#   make synth          # synthesize whatever DUT= selects (default B)
# Outputs land in synth_build/synth_<DUT>.{log,v,rtlil}.
#
#   make clean          # remove cocotb sim_build/
#   make distclean      # also nuke __pycache__ and synth_build/
#
# Override the venv location if needed:
#   make VENV=/path/to/.venv-cocotb

# ----------------------------------------------------------------------
# Python virtualenv plumbing.
# We *don't* require the user to `source .venv-cocotb/bin/activate` first;
# instead we point cocotb at the venv's interpreter directly and prepend
# its bin/ to PATH so any child process that calls `python` / `python3`
# also finds it.
# ----------------------------------------------------------------------
VENV     ?= $(abspath $(CURDIR)/../../../.venv-cocotb)
VENV_BIN := $(VENV)/bin

ifeq ($(wildcard $(VENV_BIN)/cocotb-config),)
    $(error cocotb venv not found at '$(VENV)'. Create it with: \
        python -m venv $(VENV) && $(VENV_BIN)/pip install cocotb)
endif

PYTHON_BIN  := $(VENV_BIN)/python
export PATH := $(VENV_BIN):$(PATH)

SIM                 ?= icarus
TOPLEVEL_LANG       ?= verilog
TOPLEVEL            := mac
# cocotb 2.0 renamed MODULE -> COCOTB_TEST_MODULES.
COCOTB_TEST_MODULES := mac_tb

DUT ?= B

ifeq ($(DUT),A)
    VERILOG_SOURCES := mac_llm_A.v
else ifeq ($(DUT),B)
    VERILOG_SOURCES := mac_llm_B.v
else ifeq ($(DUT),correct)
    VERILOG_SOURCES := mac_correct.v
else
    $(error Unknown DUT='$(DUT)'. Use one of: A, B, correct)
endif

# `always_ff` is SystemVerilog -- need IEEE 1800-2012 dialect for iverilog.
COMPILE_ARGS += -g2012

# Let cocotb find mac_tb.py in this directory.
export PYTHONPATH := $(CURDIR):$(PYTHONPATH)

# Pull in cocotb's simulator-agnostic build/run rules from the venv.
# This defines the default target (`sim`) plus `clean`.
include $(shell $(VENV_BIN)/cocotb-config --makefiles)/Makefile.sim

# ----------------------------------------------------------------------
# Yosys synthesis targets.
#
# We deliberately re-invoke `$(MAKE) synth DUT=<X>` from each per-LLM
# convenience target instead of duplicating the yosys recipe three times.
# That keeps the DUT->VERILOG_SOURCES mapping above as the single source
# of truth for which file goes with which LLM.
#
# `read_verilog -sv` is required: the SV literal `'0`, `logic`, and
# `always_ff` are all SystemVerilog and the default Verilog frontend
# rejects them.
# ----------------------------------------------------------------------
YOSYS       ?= yosys
SYNTH_BUILD := synth_build
SYNTH_LOG    = $(SYNTH_BUILD)/synth_$(DUT).log
SYNTH_NETLIST = $(SYNTH_BUILD)/synth_$(DUT).v
SYNTH_RTLIL   = $(SYNTH_BUILD)/synth_$(DUT).rtlil

# Use `=` (recursive) so $(VERILOG_SOURCES) etc. resolve at use time --
# this matters because `synth-A` re-makes with DUT=A, which changes them.
YOSYS_SCRIPT = read_verilog -sv $(VERILOG_SOURCES); \
               hierarchy -check -top $(TOPLEVEL); \
               proc; opt; check; stat; \
               write_rtlil $(SYNTH_RTLIL); \
               write_verilog $(SYNTH_NETLIST)

.PHONY: synth synth-A synth-B synth-correct

$(SYNTH_BUILD):
	mkdir -p $@

synth: | $(SYNTH_BUILD)
	$(YOSYS) -l $(SYNTH_LOG) -p "$(YOSYS_SCRIPT)"

synth-A:
	$(MAKE) synth DUT=A

synth-B:
	$(MAKE) synth DUT=B

synth-correct:
	$(MAKE) synth DUT=correct

# Extra cleanup beyond what cocotb's `clean` removes.
.PHONY: distclean
distclean: clean
	rm -rf __pycache__ results.xml $(SYNTH_BUILD)

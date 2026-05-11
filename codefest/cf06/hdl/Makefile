# Codefest 6 CLLM — build and run crossbar_mac self-checking testbench.
# Requires: iverilog (vvp) with SystemVerilog (-g2012).

IVFLAGS ?= -g2012 -Wall

.PHONY: all sim clean

all: sim

sim.vvp: crossbar_mac.sv crossbar_tb.sv
	iverilog $(IVFLAGS) -o sim.vvp crossbar_mac.sv crossbar_tb.sv

sim: sim.vvp
	vvp sim.vvp | tee sim.log

clean:
	rm -f sim.vvp sim.log

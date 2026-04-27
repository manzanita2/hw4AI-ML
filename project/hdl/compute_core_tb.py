"""
cocotb harness for `compute_core` (v0 shell).

This is a smoke test for the bring-up shell -- the goal is just to
confirm the module simulates, that `rst` lands the FSM in IDLE, and
that the testbench can wiggle each external interface without the
simulator falling over.  Real protocol-level tests come later when
the AXIS / AXI-Lite / array subsystems get implemented.

Stimulus (one pass):
    1) hold rst high for a few cycles, confirm `state == IDLE`
    2) release rst, idle for a few cycles
    3) drive one representative AXIS ingress beat (tvalid=1, sample tready)
    4) drive one representative AXI-Lite write request, observe handshake
    5) drain a couple of cycles and finish

Run:
    make            # builds + runs, drops artifacts/ next to this file
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


CLK_PERIOD_NS = 10  # 100 MHz in sim; real target is 300 MHz


# Mirror of the FSM enum in compute_core.v -- keeps the testbench
# readable without depending on the simulator surfacing enum names.
STATE_IDLE    = 0
STATE_LOAD    = 1
STATE_COMPUTE = 2
STATE_DRAIN   = 3


def _zero_all_inputs(dut) -> None:
    """Drive every input port to a deterministic idle value."""
    # ingress AXIS slave
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0
    # egress AXIS master back-pressure
    dut.m_axis_tready.value = 0
    # AXI-Lite write channels
    dut.s_axil_awaddr.value  = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value   = 0
    dut.s_axil_wstrb.value   = 0
    dut.s_axil_wvalid.value  = 0
    dut.s_axil_bready.value  = 0
    # AXI-Lite read channels
    dut.s_axil_araddr.value  = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value  = 0


@cocotb.test()
async def compute_core_smoke(dut):
    """Reset + minimum stimulus on each external bus.  No protocol checks."""

    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # ---------------------------------------------------------------
    # Phase 0 -- everything idle, then synchronous reset for a few
    # cycles to get the FSM register out of X.
    # ---------------------------------------------------------------
    _zero_all_inputs(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    await Timer(1, unit="ns")

    # The only sequential element in the v0 shell is the `state` reg.
    # After a synchronous reset it must be IDLE.
    state_after_rst = int(dut.state.value)
    dut._log.info(f"post-reset state = {state_after_rst} (expect {STATE_IDLE})")
    assert state_after_rst == STATE_IDLE, \
        f"reset did not land FSM in IDLE (got {state_after_rst})"

    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

    # ---------------------------------------------------------------
    # Phase 1 -- one representative ingress AXIS beat.
    # The shell ties s_axis_tready low, so this beat will not be
    # consumed.  We're just confirming the bus can be driven without
    # blowing up the simulation.
    # ---------------------------------------------------------------
    # bf16 pattern: alternating 1.0 (0x3F80) and 2.0 (0x4000) packed
    # into the 256-bit beat -- 16 lanes total.
    beat = 0
    for lane in range(16):
        word = 0x3F80 if (lane % 2 == 0) else 0x4000
        beat |= word << (16 * lane)
    dut.s_axis_tdata.value  = beat
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value  = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut._log.info(
        f"ingress beat: tvalid={int(dut.s_axis_tvalid.value)}, "
        f"tready={int(dut.s_axis_tready.value)} (stub, expect 0)"
    )
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0
    dut.s_axis_tdata.value  = 0

    # ---------------------------------------------------------------
    # Phase 2 -- one representative AXI-Lite write request to the
    # (future) `start` register at offset 0x00.  Stub will hold
    # awready / wready low; we just observe.
    # ---------------------------------------------------------------
    dut.s_axil_awaddr.value  = 0x00
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value   = 0x0000_0001       # imagined "go" bit
    dut.s_axil_wstrb.value   = 0xF                # all 4 bytes valid
    dut.s_axil_wvalid.value  = 1
    dut.s_axil_bready.value  = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut._log.info(
        f"axil write attempt: awready={int(dut.s_axil_awready.value)}, "
        f"wready={int(dut.s_axil_wready.value)}, "
        f"bvalid={int(dut.s_axil_bvalid.value)} (stub, expect 0/0/0)"
    )
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value  = 0
    dut.s_axil_bready.value  = 0

    # ---------------------------------------------------------------
    # Phase 3 -- drain a few cycles and confirm FSM stayed in IDLE.
    # ---------------------------------------------------------------
    await ClockCycles(dut.clk, 4)
    await Timer(1, unit="ns")
    state_final = int(dut.state.value)
    dut._log.info(f"final state = {state_final} (expect {STATE_IDLE})")
    assert state_final == STATE_IDLE, \
        f"FSM drifted out of IDLE without stimulus (got {state_final})"

    dut._log.info("compute_core smoke test passed.")

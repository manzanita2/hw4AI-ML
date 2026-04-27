"""
cocotb testbench for the INT8 MAC (`mac` module).

Stimulus per spec:
    1) apply  a=3,  b=4   for 3 cycles
    2) assert rst         for 1 cycle
    3) apply  a=-5, b=2   for 2 cycles

Run (with iverilog as the simulator):
    SIM=icarus TOPLEVEL_LANG=verilog \
    VERILOG_SOURCES=mac_llm_B.v TOPLEVEL=mac MODULE=mac_tb \
    make -f $(cocotb-config --makefiles)/Makefile.sim
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


CLK_PERIOD_NS = 10


def signed8(x: int) -> int:
    """Mask a Python int into an 8-bit two's-complement bit pattern.

    Some cocotb versions warn when assigning negative ints to a signal,
    even when the HDL signal is declared `signed`. Masking sidesteps that
    while preserving the bit pattern the DUT sees.
    """
    return x & 0xFF


async def step(dut, expected: int, label: str) -> None:
    """Wait one rising edge, then sample `out` and check it."""
    await RisingEdge(dut.clk)
    # Tiny delay so any combinational shadow logic settles before we read.
    await Timer(1, unit="ns")
    actual = dut.out.value.to_signed()
    dut._log.info(f"{label:<14} out = {actual:>6}  (expected {expected})")
    assert actual == expected, f"{label}: expected {expected}, got {actual}"


@cocotb.test()
async def mac_basic_sequence(dut):
    """Apply the spec stimulus and check the accumulator after each posedge."""

    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # ---------------------------------------------------------------
    # Phase 0 -- prime the DUT.
    # `out` is X at t=0 because the register has no power-on value;
    # only the synchronous reset can drive it to a known state.
    # Holding rst high for one edge gets us to a deterministic start.
    # ---------------------------------------------------------------
    dut.rst.value = 1
    dut.a.value = 0
    dut.b.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert dut.out.value.to_signed() == 0, "initial reset failed"
    dut.rst.value = 0

    # ---------------------------------------------------------------
    # Phase 1 -- a=3, b=4 for 3 cycles.  product = 12 each cycle.
    # Expected accumulator after each edge: 12, 24, 36.
    # ---------------------------------------------------------------
    dut.a.value = signed8(3)
    dut.b.value = signed8(4)
    for i in range(3):
        await step(dut, expected=12 * (i + 1), label=f"phase1.c{i}")

    # ---------------------------------------------------------------
    # Phase 2 -- assert rst for 1 cycle.  Inputs irrelevant.
    # Expected accumulator after the edge: 0.
    # ---------------------------------------------------------------
    dut.rst.value = 1
    await step(dut, expected=0, label="reset")
    dut.rst.value = 0

    # ---------------------------------------------------------------
    # Phase 3 -- a=-5, b=2 for 2 cycles.  product = -10 each cycle.
    # Expected accumulator after each edge: -10, -20.
    # ---------------------------------------------------------------
    dut.a.value = signed8(-5)
    dut.b.value = signed8(2)
    for i in range(2):
        await step(dut, expected=-10 * (i + 1), label=f"phase3.c{i}")

    dut._log.info("MAC stimulus sequence passed.")


# ----------------------------------------------------------------------
# 32-bit signed accumulator constants.
# ----------------------------------------------------------------------
INT32_MAX = (1 << 31) - 1   # +2147483647
INT32_MIN = -(1 << 31)      # -2147483648


@cocotb.test()
async def test_mac_overflow(dut):
    """Push the accumulator past 2**31 - 1 to observe wrap vs saturation.

    Strategy:
        - Use the largest possible INT8 product: (-128) * (-128) = +16384.
        - 2**31 / 16384 = 131072 cycles, so cycle N = 131072 hits the
          boundary exactly (math value = 2**31, which is one past INT32_MAX).
        - Sample the accumulator at N-1, N, and N+1.  The pattern of
          values uniquely distinguishes wraparound from saturation.

    The current `mac` design has no saturation logic -- it should wrap.
    The test logs which behavior was observed; it only fails if neither
    pattern matches (e.g. truncation, X propagation, or a stuck output).
    """

    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # Synchronous reset to a known zero state.
    dut.rst.value = 1
    dut.a.value = 0
    dut.b.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert dut.out.value.to_signed() == 0, "initial reset failed"
    dut.rst.value = 0

    # Worst-case (largest absolute) INT8 signed product.
    P = -128 * -128                 # = 16384
    N = (1 << 31) // P              # = 131072  (math accum == 2**31 here)
    assert P * N == (1 << 31)       # sanity: clean power-of-2 boundary

    dut.a.value = signed8(-128)
    dut.b.value = signed8(-128)

    # Skip ahead to one cycle before the boundary, no per-cycle Python.
    await ClockCycles(dut.clk, N - 1)
    await Timer(1, unit="ns")
    out_pre = dut.out.value.to_signed()
    expected_pre = (N - 1) * P                          # = 2**31 - 16384
    dut._log.info(f"cycle {N-1:>6}: out = {out_pre:>12}  (expected {expected_pre})")
    assert out_pre == expected_pre, \
        f"pre-overflow mismatch at cycle {N-1}: out={out_pre}"

    # The boundary cycle: math value is exactly 2**31, which doesn't fit
    # in a 32-bit signed.  Wrap -> -2**31; saturate -> +2**31 - 1.
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    out_at = dut.out.value.to_signed()
    dut._log.info(f"cycle {N:>6}: out = {out_at:>12}  (boundary)")

    # One cycle past the boundary -- distinguishes wrap from sat.
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    out_post = dut.out.value.to_signed()
    dut._log.info(f"cycle {N+1:>6}: out = {out_post:>12}  (post-boundary)")

    if out_at == INT32_MIN and out_post == INT32_MIN + P:
        dut._log.warning(
            f"DESIGN WRAPS: 2's-complement overflow.  "
            f"out[N]={out_at}, out[N+1]={out_post}."
        )
    elif out_at == INT32_MAX and out_post == INT32_MAX:
        dut._log.warning(
            f"DESIGN SATURATES: pinned at INT32_MAX={INT32_MAX}."
        )
    else:
        raise AssertionError(
            f"Unexpected overflow behavior: "
            f"out[N-1]={out_pre}, out[N]={out_at}, out[N+1]={out_post}"
        )

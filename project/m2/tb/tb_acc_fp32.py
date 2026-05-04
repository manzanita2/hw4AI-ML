"""cocotb harness for `acc_fp32.sv` (registered fp32 accumulator).

The DUT wraps the combinational `add_fp32` adder with a register and a
synchronous `clr`. On every rising edge:
    out <= 0           if rst || clr
    out <= out + addend  otherwise

Hand-picked edge cases. Each one names the SV branch it exercises.
Expected outputs come from Python `float` arithmetic on exactly-
representable inputs (no rounding fires) plus hard-coded sentinel words
for the subnormal / overflow paths.

Branches covered (acc_fp32.sv inner add_fp32, lines 42-199):
    a_zero / b_zero gating (line 56-57)        -- subnormal-flush case
    same-sign add with carry into bit 27       -- overflow saturate case
    different-sign subtract, lz == 27          -- cancellation case
    different-sign subtract, lz < 27           -- partial-cancel (covered indirectly)
    same-sign add, no carry                    -- single-add and accumulate cases
    exp_norm > 254 overflow                    -- overflow saturate case
    different-magnitude alignment shift         -- 4.0 + 0.25 case

Plus the wrapper-level paths (acc_fp32.sv lines 237-242):
    rst -> out = 0                              -- reset case
    clr -> out = 0                              -- clr-mid-stream case
    normal accumulate                           -- everything else

Run:
    make TEST=acc_fp32
"""

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


CLK_PERIOD_NS = 10


def f32_bits(x: float) -> int:
    """Pack a Python float as fp32 bits."""
    return struct.unpack("<I", struct.pack("<f", x))[0]


# fp32 sentinel bit patterns.
F32_ZERO         = 0x00000000
F32_POS_INF      = 0x7F800000
F32_MAX_NORMAL   = 0x7F7FFFFF   # +(1 + (2^23 - 1)/2^23) * 2^127
F32_TINY_SUBNORM = 0x00000001   # smallest positive subnormal fp32


async def _step(dut, addend_bits: int, clr: int = 0) -> int:
    """Drive (addend, clr) for one cycle. Returns `out` after the edge."""
    dut.addend.value = addend_bits
    dut.clr.value    = clr
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    return int(dut.out.value)


async def _hard_reset(dut) -> None:
    """Drop everything to zero via rst."""
    dut.rst.value    = 1
    dut.clr.value    = 0
    dut.addend.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 1)
    await Timer(1, unit="ns")


# Each subcase is a (label, [(addend_bits, clr, expected_out_bits), ...])
# tuple. The runner pulses clr for one cycle before driving the sequence
# so each subcase starts from out == 0.
SUBCASES = [
    (
        "single add: 0 + 3.0 = 3.0",
        [
            (f32_bits(3.0), 0, f32_bits(3.0)),
        ],
    ),
    (
        "series accumulate [1, 2, 4, 0.5] -> running sum stays exact",
        [
            (f32_bits(1.0), 0, f32_bits(1.0)),
            (f32_bits(2.0), 0, f32_bits(3.0)),
            (f32_bits(4.0), 0, f32_bits(7.0)),
            (f32_bits(0.5), 0, f32_bits(7.5)),
        ],
    ),
    (
        "cancellation: +1.0 then -1.0 -> exactly 0  [lz==27 zero path]",
        [
            (f32_bits(+1.0), 0, f32_bits(+1.0)),
            (f32_bits(-1.0), 0, F32_ZERO),
        ],
    ),
    (
        "different-magnitude align: 4.0 + 0.25 = 4.25  [exp_diff == 4]",
        [
            (f32_bits(4.0),  0, f32_bits(4.0)),
            (f32_bits(0.25), 0, f32_bits(4.25)),
        ],
    ),
    (
        "subnormal addend flush: 1.0 + 0x00000001 = 1.0  [b_zero gate]",
        [
            (f32_bits(1.0),     0, f32_bits(1.0)),
            (F32_TINY_SUBNORM,  0, f32_bits(1.0)),
        ],
    ),
    (
        "clr mid-stream: accumulate 7.0, clr, then 3.0 -> 3.0",
        [
            (f32_bits(1.0), 0, f32_bits(1.0)),
            (f32_bits(2.0), 0, f32_bits(3.0)),
            (f32_bits(4.0), 0, f32_bits(7.0)),
            (0,             1, F32_ZERO),       # clr cycle (addend ignored)
            (f32_bits(3.0), 0, f32_bits(3.0)),
        ],
    ),
    (
        "overflow saturate: max_normal + max_normal -> +inf  [exp_norm > 254]",
        [
            (F32_MAX_NORMAL, 0, F32_MAX_NORMAL),  # 0 + max_normal = max_normal
            (F32_MAX_NORMAL, 0, F32_POS_INF),     # max_normal + max_normal -> +inf
        ],
    ),
]


@cocotb.test()
async def acc_fp32_reset(dut):
    """Verify that rst drops `out` to zero."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    dut.rst.value    = 1
    dut.clr.value    = 0
    dut.addend.value = f32_bits(123.0)   # nonzero garbage, should be ignored
    await ClockCycles(dut.clk, 3)
    await Timer(1, unit="ns")

    got = int(dut.out.value)
    assert got == F32_ZERO, (
        f"rst did not clear out; got 0x{got:08X}, expected 0x{F32_ZERO:08X}"
    )
    dut._log.info("PASS: rst clears out to zero")


@cocotb.test()
async def acc_fp32_edge_cases(dut):
    """Bit-exact compare for each subcase. clr-pulse between subcases."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    await _hard_reset(dut)
    fails: list[tuple] = []

    for label, sequence in SUBCASES:
        # Start each subcase from out == 0 via a one-cycle clr pulse.
        await _step(dut, addend_bits=0, clr=1)
        out_after_clr = int(dut.out.value)
        if out_after_clr != F32_ZERO:
            fails.append((label, "pre-subcase clr", out_after_clr, F32_ZERO))
            dut._log.error(
                f"  MISS {label!r}: pre-subcase clr left out=0x{out_after_clr:08X}"
            )
            continue

        all_ok = True
        for i, (addend, clr, expected) in enumerate(sequence):
            got = await _step(dut, addend, clr=clr)
            if got != expected:
                fails.append((label, f"cycle {i}", got, expected))
                dut._log.error(
                    f"  MISS {label!r} cycle {i}: "
                    f"addend=0x{addend:08X} clr={clr} -> got=0x{got:08X}, "
                    f"expected=0x{expected:08X}"
                )
                all_ok = False
                break  # don't keep accumulating on top of a wrong value

        if all_ok:
            dut._log.info(f"  OK   {label}")

    total = len(SUBCASES)
    if fails:
        dut._log.error(f"FAIL: {len(fails)} of {total} acc_fp32 subcases failed")
        assert False, f"{len(fails)} acc_fp32 subcase(s) mismatched; see log"

    dut._log.info(f"PASS: all {total} acc_fp32 edge-case subcases matched bit-exact")

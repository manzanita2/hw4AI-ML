"""cocotb harness for `compute_core` (post-Part-1 v1 datapath).

Two tests:

  compute_core_smoke
      Reset + idle stimulus on the internal API. No protocol checks.
      Verifies the FSM sits in IDLE without cfg_start.

  compute_core_gemm
      Drives one 4x4 GEMM tile through LOAD -> COMPUTE -> DRAIN, captures
      the four bf16 outputs, and compares each against a Python `float`
      reference. Inputs are chosen so every product and partial sum is
      exactly representable in fp32, which means the SV's RTZ rounding
      never fires and Python's left-fold-in-K-order matches the SV's
      column-K systolic accumulation BIT-EXACTLY.

Filename mirrors the DUT with a `tb_` prefix (compute_core.sv ->
tb_compute_core.py).

Run:
    make                    # default: TEST=compute_core
"""

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


CLK_PERIOD_NS = 10  # 100 MHz in sim; real target is 300 MHz

DATA_W = 16
OUT_W  = 16
M = 4
N = 4
LANES = 16

OUT_MASK = (1 << OUT_W) - 1
ACT_MASK = (1 << (DATA_W * LANES)) - 1


# Mirror of the FSM enum in compute_core.sv.
STATE_IDLE    = 0
STATE_LOAD    = 1
STATE_COMPUTE = 2
STATE_DRAIN   = 3


def f32_bits(x: float) -> int:
    """Pack a Python float as fp32 bits."""
    return struct.unpack("<I", struct.pack("<f", x))[0]


def bf16_bits(x: float) -> int:
    """bf16 = upper 16 bits of fp32 (truncation, matches DUT's fp32_to_bf16)."""
    return f32_bits(x) >> 16


def _zero_all_inputs(dut) -> None:
    """Drive every input port to a deterministic idle value."""
    dut.act_data.value  = 0
    dut.act_valid.value = 0
    dut.act_last.value  = 0
    dut.res_ready.value = 0
    dut.cfg_start.value = 0


# ============================================================================
# Smoke test: reset + idle, FSM sits in IDLE.
# ============================================================================
@cocotb.test()
async def compute_core_smoke(dut):
    """Reset + idle stimulus on the internal API. No protocol checks."""

    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    _zero_all_inputs(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    await Timer(1, unit="ns")

    state_after_rst = int(dut.state.value)
    dut._log.info(f"post-reset state = {state_after_rst} (expect {STATE_IDLE})")
    assert state_after_rst == STATE_IDLE, \
        f"reset did not land FSM in IDLE (got {state_after_rst})"

    dut.rst.value = 0
    await ClockCycles(dut.clk, 8)
    await Timer(1, unit="ns")

    state_final = int(dut.state.value)
    dut._log.info(
        f"post-idle state = {state_final} "
        f"(expect {STATE_IDLE}; FSM only leaves IDLE on cfg_start)"
    )
    assert state_final == STATE_IDLE, \
        f"FSM left IDLE without cfg_start (got {state_final})"

    dut._log.info("compute_core smoke test passed.")


# ============================================================================
# GEMM test: one 4x4 weight-stationary tile.
# ============================================================================
async def _drive_load(dut, B: list[list[float]]) -> None:
    """Drive 16 weights, one per cycle in row-major order.

    The SV gates wt_load[i][j] on (state == LOAD) && (wt_count == i*N + j),
    so as long as we feed bf16(B[i][j]) on act_data[15:0] in row-major order
    starting from the cycle state enters LOAD, every PE latches its weight.
    """
    for i in range(M):
        for j in range(N):
            dut.act_data.value  = bf16_bits(B[i][j])
            dut.act_valid.value = 1
            await RisingEdge(dut.clk)


async def _drive_activations(dut, x: list[float]) -> None:
    """On the first COMPUTE cycle, present x[0..M-1] in low M*DATA_W bits.

    Layout: x[i] occupies bits [i*DATA_W +: DATA_W]. Upper lanes are zero.
    The SV latches act_buf when state==COMPUTE && compute_cycle==0, which
    is exactly the cycle we drive here.
    """
    word = 0
    for i in range(M):
        word |= (bf16_bits(x[i]) & ((1 << DATA_W) - 1)) << (i * DATA_W)
    dut.act_data.value  = word & ACT_MASK
    dut.act_valid.value = 1
    await RisingEdge(dut.clk)


async def _wait_for_state(dut, target: int, max_cycles: int = 64) -> int:
    """Step the clock until dut.state == target. Returns cycle count."""
    for cyc in range(max_cycles):
        await Timer(1, unit="ns")
        if int(dut.state.value) == target:
            return cyc
        await RisingEdge(dut.clk)
    raise TimeoutError(
        f"FSM did not reach state {target} in {max_cycles} cycles "
        f"(stuck in state={int(dut.state.value)})"
    )


async def _capture_drain(dut, n_outputs: int) -> list[int]:
    """Capture n_outputs bf16 words from res_data, one per cycle.

    Caller must have already entered DRAIN with res_ready high. drain_cycle
    advances each cycle while res_ready stays high, so on cycle k we read
    bf16(y[k]) from res_data[OUT_W-1:0].
    """
    captured: list[int] = []
    for _ in range(n_outputs):
        await Timer(1, unit="ns")
        assert int(dut.state.value) == STATE_DRAIN, \
            f"left DRAIN early at capture index {len(captured)}"
        assert int(dut.res_valid.value) == 1, \
            f"res_valid low during DRAIN at capture index {len(captured)}"
        captured.append(int(dut.res_data.value) & OUT_MASK)
        await RisingEdge(dut.clk)
    return captured


@cocotb.test()
async def compute_core_gemm(dut):
    """Drive one weight-stationary 4x4 GEMM tile and verify all outputs.

    Inputs (all powers of 2 / sums of powers of 2 -> exactly representable
    in fp32, so the SV's RTZ rounding never fires and Python `float` is
    a bit-exact reference):

        x = [1.0, 2.0, -1.0, 0.5]
        B = [[ 1.0,  0.5,  2.0, -1.0],
             [ 0.5,  1.0, -0.5,  2.0],
             [ 2.0, -1.0,  1.0,  0.5],
             [-0.5,  2.0,  0.5,  1.0]]

    Expected y[n] for n in 0..3:
        y[0] = 1*1   + 2*0.5  + -1*2   + 0.5*-0.5 = -0.25
        y[1] = 1*0.5 + 2*1    + -1*-1  + 0.5*2    =  4.5
        y[2] = 1*2   + 2*-0.5 + -1*1   + 0.5*0.5  =  0.25
        y[3] = 1*-1  + 2*2    + -1*0.5 + 0.5*1    =  3.0
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # --- Inputs --------------------------------------------------------
    x = [1.0, 2.0, -1.0, 0.5]
    B = [
        [ 1.0,  0.5,  2.0, -1.0],
        [ 0.5,  1.0, -0.5,  2.0],
        [ 2.0, -1.0,  1.0,  0.5],
        [-0.5,  2.0,  0.5,  1.0],
    ]
    # Reference: column-K-order left-fold to mirror the SV's per-column
    # systolic accumulation. All values are exact in fp32, so Python's
    # native `float` left-fold matches the SV bitwise.
    y_ref_bf16 = []
    for n in range(N):
        acc = 0.0
        for k in range(M):
            acc = acc + x[k] * B[k][n]
        y_ref_bf16.append(bf16_bits(acc))

    dut._log.info(
        "expected y_bf16 = [" +
        ", ".join(f"0x{w:04X}" for w in y_ref_bf16) +
        "]"
    )

    # --- Reset ---------------------------------------------------------
    _zero_all_inputs(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_IDLE

    # --- Pulse cfg_start -> FSM enters LOAD next cycle ----------------
    dut.cfg_start.value = 1
    await RisingEdge(dut.clk)
    dut.cfg_start.value = 0
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_LOAD, \
        f"FSM did not enter LOAD after cfg_start (state={int(dut.state.value)})"

    # --- LOAD: 16 weights, one per cycle, row-major --------------------
    await _drive_load(dut, B)
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_COMPUTE, \
        f"FSM did not enter COMPUTE after 16 LOAD cycles " \
        f"(state={int(dut.state.value)})"

    # --- COMPUTE cycle 0: drive activation tile -----------------------
    await _drive_activations(dut, x)

    # --- Idle: no input needed for the rest of COMPUTE ----------------
    dut.act_data.value  = 0
    dut.act_valid.value = 0

    # Hold res_ready high so DRAIN advances every cycle. Set this BEFORE
    # the FSM enters DRAIN so drain_cycle starts incrementing immediately.
    dut.res_ready.value = 1

    # --- Wait for FSM to enter DRAIN ----------------------------------
    cycles_to_drain = await _wait_for_state(dut, STATE_DRAIN, max_cycles=32)
    dut._log.info(f"FSM reached DRAIN after {cycles_to_drain} cycles in COMPUTE")

    # --- DRAIN: capture N bf16 outputs --------------------------------
    y_dut_bf16 = await _capture_drain(dut, N)

    dut._log.info(
        "captured y_bf16 = [" +
        ", ".join(f"0x{w:04X}" for w in y_dut_bf16) +
        "]"
    )

    # --- Wait for status_done / FSM back to IDLE ----------------------
    # status_done pulses on the cycle DRAIN accepts its last word, which
    # was the last cycle of _capture_drain. The FSM should be back in
    # IDLE one cycle after that.
    await Timer(1, unit="ns")
    final_state = int(dut.state.value)
    assert final_state == STATE_IDLE, \
        f"FSM did not return to IDLE after DRAIN (state={final_state})"

    # --- Compare ------------------------------------------------------
    fails = []
    for n in range(N):
        if y_dut_bf16[n] != y_ref_bf16[n]:
            fails.append((n, y_dut_bf16[n], y_ref_bf16[n]))
            dut._log.error(
                f"  MISS y[{n}]: got 0x{y_dut_bf16[n]:04X}, "
                f"expected 0x{y_ref_bf16[n]:04X}"
            )
        else:
            dut._log.info(
                f"  OK   y[{n}] = 0x{y_dut_bf16[n]:04X} "
                f"(reference float = {x[0]*B[0][n] + x[1]*B[1][n] + x[2]*B[2][n] + x[3]*B[3][n]})"
            )

    if fails:
        dut._log.error(f"FAIL: {len(fails)} of {N} GEMM outputs mismatched")
        assert False, f"{len(fails)} GEMM output(s) mismatched; see log"

    dut._log.info(f"PASS: all {N} GEMM outputs matched bit-exact")

"""cocotb harness for deliverable #5 quantization-error sweep.

[`make m2-quant`](../Makefile) elaborates [`compute_core`](../rtl/compute_core.sv)
with parameters **M=N=LANES=48** (architecture headline array). GEMM mapping is
:y:`[n] += x[k]*B[k][n]` along K=M=48, one bf16 drain per column.

Stdout log copy: [`sim/quant_error.log`](../sim/quant_error.log).
"""

import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


# ----------------------------------------------------------------------------
# Compile-time knobs (must match Makefile -P overrides for compute_core)
# ----------------------------------------------------------------------------
SEED           = 42
N_TILES        = 30          # >= 100 outputs: 30 * 48 = 1440
THRESHOLD_MAE  = 2.0         # bf16 accumulation over K=48; generous gate

CLK_PERIOD_NS  = 10
DATA_W         = 16
OUT_W          = 16
M              = 48          # reduction K
N              = 48          # outputs per tile
LANES          = 48          # DATA_W bus width lanes (M*DATA_W fit)

OUT_MASK       = (1 << OUT_W) - 1
ACT_MASK       = (1 << (DATA_W * LANES)) - 1

STATE_IDLE     = 0
STATE_LOAD     = 1
STATE_COMPUTE  = 2
STATE_DRAIN    = 3

def f32_bits(x: float) -> int:
    return struct.unpack("<I", struct.pack("<f", x))[0]


def bf16_bits(x: float) -> int:
    return f32_bits(x) >> 16


def fp32_quantize(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bf16_to_fp32(b: int) -> float:
    return struct.unpack("<f", struct.pack("<I", (b & 0xFFFF) << 16))[0]


def _zero_all_inputs(dut) -> None:
    dut.act_data.value  = 0
    dut.act_valid.value = 0
    dut.act_last.value  = 0
    dut.res_ready.value = 0
    dut.cfg_start.value = 0


async def _drive_load(dut, B: list[list[float]]) -> None:
    for i in range(M):
        for j in range(N):
            dut.act_data.value  = bf16_bits(B[i][j])
            dut.act_valid.value = 1
            await RisingEdge(dut.clk)


async def _drive_activations(dut, x: list[float]) -> None:
    word = 0
    for i in range(M):
        word |= (bf16_bits(x[i]) & ((1 << DATA_W) - 1)) << (i * DATA_W)
    dut.act_data.value  = word & ACT_MASK
    dut.act_valid.value = 1
    await RisingEdge(dut.clk)


async def _wait_for_state(dut, target: int, max_cycles: int) -> int:
    for cyc in range(max_cycles):
        await Timer(1, unit="ns")
        if int(dut.state.value) == target:
            return cyc
        await RisingEdge(dut.clk)
    raise TimeoutError(
        f"FSM stuck: did not reach state {target} in {max_cycles} cycles "
        f"(now state={int(dut.state.value)})"
    )


async def _capture_drain(dut, n_outputs: int) -> list[int]:
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


async def _run_one_tile(dut, x: list[float], B: list[list[float]]) -> list[int]:
    """cfg_start pulse -> LOAD (M*N) -> COMPUTE -> DRAIN -> IDLE."""
    dut.cfg_start.value = 1
    await RisingEdge(dut.clk)
    dut.cfg_start.value = 0
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_LOAD

    await _drive_load(dut, B)
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_COMPUTE

    await _drive_activations(dut, x)
    dut.act_data.value  = 0
    dut.act_valid.value = 0

    await _wait_for_state(dut, STATE_DRAIN, M + N + 256)
    y = await _capture_drain(dut, N)

    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_IDLE

    return y


def _fp32_ref_tile(x: list[float], B: list[list[float]]) -> list[float]:
    """Column-K left-fold, fp32 quantized each op (RNE-ish via struct)."""
    y_out: list[float] = []
    for n_col in range(N):
        acc = 0.0
        for k in range(M):
            prod = fp32_quantize(x[k] * B[k][n_col])
            acc  = fp32_quantize(acc + prod)
        y_out.append(acc)
    return y_out


@cocotb.test()
async def compute_core_quant_error(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    _zero_all_inputs(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await Timer(1, unit="ns")
    assert int(dut.state.value) == STATE_IDLE

    dut.res_ready.value = 1
    rng = random.Random(SEED)

    abs_errs: list[float] = []
    rel_errs: list[float] = []
    REL_EPS = 1e-3

    n_out_tot = N_TILES * N
    dut._log.info(
        f"quant sweep: M=N=K={M}, LANES={LANES}, SEED={SEED}, "
        f"N_TILES={N_TILES} -> N_OUT={n_out_tot}; MAE thr {THRESHOLD_MAE:g}"
    )

    for _ in range(N_TILES):
        x = [fp32_quantize(rng.gauss(0.0, 1.0)) for _ in range(M)]
        B = [[fp32_quantize(rng.gauss(0.0, 1.0)) for _ in range(N)]
             for _ in range(M)]

        y_ref_fp32 = _fp32_ref_tile(x, B)
        y_bits     = await _run_one_tile(dut, x, B)

        await Timer(1, unit="ns")
        assert int(dut.state.value) == STATE_IDLE

        assert len(y_bits) == N
        for r, wb in zip(y_ref_fp32, y_bits):
            d   = bf16_to_fp32(wb)
            err = abs(r - d)
            abs_errs.append(err)
            if abs(r) > REL_EPS:
                rel_errs.append(err / abs(r))

    n_sample = len(abs_errs)
    mae      = sum(abs_errs) / n_sample
    rmse     = (sum(e * e for e in abs_errs) / n_sample) ** 0.5
    max_abs  = max(abs_errs)
    max_rel  = max(rel_errs) if rel_errs else 0.0

    bin_edges  = [1e-3, 1e-2, 1e-1, 0.25, 0.5]
    bin_labels = ["<1e-3", "1e-3..1e-2", "1e-2..1e-1", "0.1..0.25",
                  "0.25..0.5", ">=0.5"]
    hist = [0] * (len(bin_edges) + 1)
    for e in abs_errs:
        for idx, edge in enumerate(bin_edges):
            if e < edge:
                hist[idx] += 1
                break
        else:
            hist[-1] += 1

    p1e2 = 100.0 * sum(1 for e in abs_errs if e < 1e-2) / n_sample

    mc = max(hist) or 1

    dut._log.info(f"N_OUT={n_sample} MAE={mae:.6e} RMSE={rmse:.6e} "
                  f"max_abs={max_abs:.6e} max_rel={max_rel:.6e}")
    dut._log.info(f"pct |err|<1e-2={p1e2:.2f}%")
    dut._log.info("HIST |err|:")
    for lab, ct in zip(bin_labels, hist):
        dut._log.info(f"  {lab:12s}{ct:6d}  {'#' * int(40 * ct / mc)}")

    if mae < THRESHOLD_MAE:
        dut._log.info(
            f"PASS: MAE {mae:.3e} < {THRESHOLD_MAE:g}  "
            f"(max_abs {max_abs:.3e}, max_rel {max_rel:.3e})"
        )
    else:
        dut._log.error(f"FAIL: MAE {mae:.3e} >= {THRESHOLD_MAE:g}")
        assert False

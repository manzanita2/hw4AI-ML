#!/usr/bin/env python3
"""M4 benchmark: extrapolate measured per-tile cycle costs to a RAFT-scale
convolution and emit the deliverable CSVs.

Pipeline
--------
    tb/tb_top.py::test_benchmark  (make -C ../tb bench-measure)
        -> bench_measured.csv      (real RTL cycles for load / stream_hold /
                                    stream_full at block sizes B=1 and B=PIX_BLOCK)
    this script
        -> benchmark_data.csv      (throughput / speedup / energy, long form)
        -> roofline_data.csv       (bandwidth-aware roofline points + roofs)

Nothing here is hand-counted: the per-phase cycle costs come from the
simulator clock, and everything else is closed-form arithmetic over the
target layer's tile schedule. Two schedules are modeled, both of which the
RTL actually implements (see tb_top.py):

  * BASELINE (B=1, the M3 reload pathology): for every output pixel, sweep
    the N-tiles, and within each sweep the K-tiles accumulating on chip --
    RELOADING the M*N weight slab on every K-tile to serve ONE pixel. Zero
    pixel reuse -> effective AI ~0.9 FLOP/byte, ~0.2% of peak.

  * STREAMING (B=PIX_BLOCK, the M4 core): stream a block of B pixel columns
    through the resident weights, so one weight reload + one pipeline fill
    serve B pixels. The weight slab is reloaded NT*ceil(P/B)*KT times instead
    of NT*P*KT times -- B-fold less weight traffic, the AI shifts toward the
    ridge, and the cycle count drops by ~B (minus the fixed drain/fill).

The reported headline is the STREAMING design point plus its speedup over
the baseline. Run:
    python benchmark.py            # reads ./bench_measured.csv
All inputs are cited inline so every number traces back to a source.
"""

from __future__ import annotations

import csv
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent

# =======================================================================
# Constants (every value cites its source file)
# =======================================================================
# --- Hardware design point (project/m4/README.md, synth/config.json) ---
M = N = 16                       # systolic array dimensions
MACS_PER_CYCLE = M * N           # 256 MACs/cycle at full utilization
FLOPS_PER_MAC = 2                # 1 multiply + 1 add (ai_calculation.md)
CLK_HZ = 100e6                   # 100 MHz achieved (synth/timing_report.txt)
AXIS_BITS = 256                  # AXI4-Stream data width (tb_top.py)
BYTES_PER_BEAT = AXIS_BITS // 8  # 32 B/beat
WEIGHT_BEATS = (M * N) // 16     # 16 beats per MxN bf16 weight slab

# Compute roof: every MAC is 2 FLOPs, all 256 MACs busy every cycle.
PEAK_FLOPS = MACS_PER_CYCLE * FLOPS_PER_MAC * CLK_HZ          # 51.2 GFLOP/s
# The accelerator's binding memory roof is its own AXIS pin bandwidth:
# one 256-bit beat per cycle at 100 MHz.
PIN_BW_BYTES = (AXIS_BITS / 8) * CLK_HZ                       # 3.2 GB/s

# --- Accelerator power (synth/power_report.txt, static estimate) -------
ACCEL_POWER_W = 0.834

# --- Target conv layer: Conv2d 5-1 (codefest/.../ai_calculation.md) ----
CIN, COUT, KH, KW = 64, 64, 3, 3
BATCH, HOUT, WOUT = 4, 260, 480
LAYER_MACS = 18_434_457_600                  # torchinfo Mult-Adds
LAYER_FLOPS = FLOPS_PER_MAC * LAYER_MACS     # 36.868e9
IDEAL_AI = 144.17                            # FLOP/byte, fp32 no-reuse

# Tile schedule derived from the layer dims (mirrors the RTL loop).
K = CIN * KH * KW          # 576 reduction depth
KT = K // M               # 36 K-tiles
NT = COUT // N            # 4 N-tiles
P = BATCH * HOUT * WOUT   # 499,200 output pixels
assert K % M == 0 and COUT % N == 0

# --- CPU / software baseline (project/m1/sw_baseline.md) ---------------
CPU_FWD_TIME_S = 4.145            # median raft_large forward
CONV_FRACTION = 0.5302            # aten::mkldnn_convolution self CPU %
CPU_TOTAL_FLOPS = 2 * 788.14e9    # whole forward (788.14 GMAC)
# CPU sustained conv throughput: conv FLOPs / conv wall time. The conv
# fraction cancels, leaving the overall effective rate ~380 GFLOP/s.
CPU_CONV_FLOPS = CONV_FRACTION * CPU_TOTAL_FLOPS
CPU_CONV_TIME_S = CONV_FRACTION * CPU_FWD_TIME_S
CPU_CONV_THROUGHPUT = CPU_CONV_FLOPS / CPU_CONV_TIME_S        # ~3.8e11
CPU_PEAK_FLOPS = 1.02e12          # Zen 4 base-clock theoretical peak
CPU_DRAM_BW_BYTES = 89.5e9        # DDR5-5600 max throughput
CPU_TDP_W = 45.0                  # Ryzen 9 7940HS configurable TDP (rough)


# =======================================================================
# Read measured per-phase cycles -> {(phase, block): cycles}
# =======================================================================
def read_measured(path: Path) -> dict[tuple[str, int], float]:
    cyc: dict[tuple[str, int], float] = {}
    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            cyc[(row["phase"], int(row["block"]))] = float(row["cycles"])
    if ("load", 0) not in cyc:
        raise SystemExit(f"{path} missing 'load'; run "
                         f"`make -C ../tb bench-measure` first.")
    for need in (("stream_hold", 1), ("stream_full", 1)):
        if need not in cyc:
            raise SystemExit(f"{path} missing {need}; re-run bench-measure "
                             f"with the streaming test_benchmark.")
    return cyc


# =======================================================================
# Schedule model -- one weight-reload group per (block, N-tile)
# =======================================================================
def model_schedule(block: int, load_c: float, hold_c: float, full_c: float) -> dict:
    """Cycle + bandwidth model for streaming `block` pixels per reload.

    Per group (one pixel-block x one N-tile): KT weight LOADs, (KT-1) held
    COMPUTEs (stream_hold), and 1 draining COMPUTE (stream_full). block=1 is
    the M3 baseline; block=PIX_BLOCK is the M4 streaming design point.
    """
    groups = NT * math.ceil(P / block)
    cyc_per_group = KT * load_c + (KT - 1) * hold_c + full_c
    total_cycles = groups * cyc_per_group
    time_s = total_cycles / CLK_HZ
    sustained = LAYER_FLOPS / time_s
    util = sustained / PEAK_FLOPS

    # Pin traffic at this operating point (bytes actually moved over AXIS):
    #   weights : WEIGHT_BEATS beats reloaded every K-tile of every group
    #   acts    : `block` activation columns pushed every COMPUTE (KT/group)
    #   results : block*N result beats drained once per group (last K-tile)
    weight_beats = groups * KT * WEIGHT_BEATS
    act_beats = groups * KT * block
    result_beats = groups * block * N
    pin_bytes = (weight_beats + act_beats + result_beats) * BYTES_PER_BEAT
    eff_ai = LAYER_FLOPS / pin_bytes
    bw_ceiling = eff_ai * PIN_BW_BYTES

    return dict(
        block=block, groups=groups, cyc_per_group=cyc_per_group,
        total_cycles=total_cycles, time_s=time_s, sustained=sustained,
        util=util, weight_beats=weight_beats, act_beats=act_beats,
        result_beats=result_beats, pin_bytes=pin_bytes, eff_ai=eff_ai,
        bw_ceiling=bw_ceiling,
    )


# =======================================================================
# Extrapolation
# =======================================================================
def main() -> None:
    cyc = read_measured(HERE / "bench_measured.csv")
    load_c = cyc[("load", 0)]

    # Streaming block size = largest measured block (PIX_BLOCK).
    blocks = sorted({b for (ph, b) in cyc if ph == "stream_hold"})
    B = blocks[-1]
    if ("stream_hold", B) not in cyc or ("stream_full", B) not in cyc:
        raise SystemExit(f"bench_measured.csv lacks B={B} streaming rows.")

    base = model_schedule(1, load_c, cyc[("stream_hold", 1)], cyc[("stream_full", 1)])
    strm = model_schedule(B, load_c, cyc[("stream_hold", B)], cyc[("stream_full", B)])

    # Streaming gain over the M3 single-pixel reload schedule.
    stream_speedup = base["total_cycles"] / strm["total_cycles"]

    # Headline numbers are the STREAMING design point.
    accel_time_s = strm["time_s"]
    sustained_flops = strm["sustained"]
    utilization = strm["util"]
    effective_ai = strm["eff_ai"]
    bw_limited_flops = strm["bw_ceiling"]

    # Speedups vs the CPU software baseline.
    cpu_layer_time_s = LAYER_FLOPS / CPU_CONV_THROUGHPUT
    kernel_speedup = cpu_layer_time_s / accel_time_s
    amdahl_speedup = 1.0 / ((1 - CONV_FRACTION) + CONV_FRACTION / kernel_speedup)

    # Energy.
    accel_energy_j = ACCEL_POWER_W * accel_time_s
    accel_j_per_flop = accel_energy_j / LAYER_FLOPS
    cpu_energy_j = CPU_TDP_W * cpu_layer_time_s
    cpu_j_per_flop = cpu_energy_j / LAYER_FLOPS

    # Marginal per-pixel stream cost -- should be ~2 cyc (1 act-load + 1
    # stream column) since the load is non-overlapped (load-then-stream).
    per_pixel_stream = (cyc[("stream_hold", B)] - cyc[("stream_hold", 1)]) / max(B - 1, 1)

    # ---------------- benchmark_data.csv (long form) ----------------
    rows = [
        # metric, value, unit, source/derivation
        ("array_dim", f"{M}x{N}", "", "synth/config.json"),
        ("clock_freq", CLK_HZ, "Hz", "synth/timing_report.txt"),
        ("pix_block", B, "", "rtl PIX_BLOCK (streaming block depth)"),
        ("peak_throughput", PEAK_FLOPS, "FLOP/s", "M*N*2*clk"),
        ("pin_bandwidth", PIN_BW_BYTES, "B/s", "256bit*clk"),
        ("layer", "Conv2d 5-1", "", "ai_calculation.md"),
        ("layer_flops", LAYER_FLOPS, "FLOP", "2*MACs"),
        ("k_tiles", KT, "", "K=Cin*KH*KW=576 /16"),
        ("n_tiles", NT, "", "Cout=64 /16"),
        ("output_pixels", P, "", "batch*Hout*Wout"),
        ("cyc_load", load_c, "cycles", "bench_measured.csv"),
        # --- baseline (B=1, M3 reload pathology) ---
        ("base_cyc_stream_hold", cyc[("stream_hold", 1)], "cycles", "bench_measured.csv B=1"),
        ("base_cyc_stream_full", cyc[("stream_full", 1)], "cycles", "bench_measured.csv B=1"),
        ("base_total_cycles", base["total_cycles"], "cycles", "NT*P*(KT*load+(KT-1)*hold+full)"),
        ("base_time", base["time_s"], "s", "base_total_cycles/clk"),
        ("base_sustained", base["sustained"], "FLOP/s", "layer_flops/base_time"),
        ("base_utilization", base["util"], "frac", "base_sustained/peak"),
        ("base_effective_ai", base["eff_ai"], "FLOP/B", "layer_flops/base_pin_bytes"),
        # --- streaming (B=PIX_BLOCK, M4 design point) ---
        ("stream_cyc_hold", cyc[("stream_hold", B)], "cycles", f"bench_measured.csv B={B}"),
        ("stream_cyc_full", cyc[("stream_full", B)], "cycles", f"bench_measured.csv B={B}"),
        ("stream_per_pixel_cyc", per_pixel_stream, "cycles", "(holdB-hold1)/(B-1)"),
        ("stream_cyc_per_group", strm["cyc_per_group"], "cycles", "KT*load+(KT-1)*hold+full"),
        ("stream_total_cycles", strm["total_cycles"], "cycles", "NT*ceil(P/B)*cyc_per_group"),
        ("accel_time", accel_time_s, "s", "stream_total_cycles/clk"),
        ("sustained_throughput", sustained_flops, "FLOP/s", "layer_flops/accel_time"),
        ("utilization", utilization, "frac", "sustained/peak"),
        ("stream_speedup_vs_baseline", stream_speedup, "x", "base_total/stream_total"),
        ("pin_bytes_moved", strm["pin_bytes"], "B", "weight+act+result beats"),
        ("effective_ai", effective_ai, "FLOP/B", "layer_flops/pin_bytes"),
        ("ideal_ai", IDEAL_AI, "FLOP/B", "ai_calculation.md (fp32, no reuse)"),
        ("ridge_ai", PEAK_FLOPS / PIN_BW_BYTES, "FLOP/B", "peak/pin_bw"),
        ("bw_limited_throughput", bw_limited_flops, "FLOP/s", "effective_ai*pin_bw"),
        # --- vs CPU ---
        ("cpu_conv_throughput", CPU_CONV_THROUGHPUT, "FLOP/s", "sw_baseline.md"),
        ("cpu_layer_time", cpu_layer_time_s, "s", "layer_flops/cpu_conv_throughput"),
        ("kernel_speedup", kernel_speedup, "x", "cpu_layer_time/accel_time"),
        ("amdahl_system_speedup", amdahl_speedup, "x", "1/((1-f)+f/kernel), f=0.5302"),
        ("accel_energy", accel_energy_j, "J", "0.834W*accel_time (static est)"),
        ("accel_energy_per_flop", accel_j_per_flop, "J/FLOP", "accel_energy/layer_flops"),
        ("cpu_energy", cpu_energy_j, "J", "45W TDP*cpu_layer_time (ref)"),
        ("cpu_energy_per_flop", cpu_j_per_flop, "J/FLOP", "cpu_energy/layer_flops"),
    ]
    with (HERE / "benchmark_data.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["metric", "value", "unit", "source"])
        for metric, value, unit, src in rows:
            if isinstance(value, float):
                value = f"{value:.6g}"
            w.writerow([metric, value, unit, src])

    # ---------------- roofline_data.csv (plot-ready) ----------------
    # Two roofs (accelerator + CPU) sampled across a log AI sweep, plus the
    # discrete operating points. perf is in GFLOP/s for readability. The two
    # accel operating points (baseline vs streaming) show the AI shift.
    GIGA = 1e9
    ai_sweep = [10 ** (i / 4 - 1) for i in range(int((3 - (-1)) * 4) + 1)]  # 0.1 .. 1000
    roof_rows: list[tuple[str, float, float, str]] = []
    for ai in ai_sweep:
        accel = min(PEAK_FLOPS, ai * PIN_BW_BYTES) / GIGA
        cpu = min(CPU_PEAK_FLOPS, ai * CPU_DRAM_BW_BYTES) / GIGA
        roof_rows.append(("accel_roof", ai, accel, ""))
        roof_rows.append(("cpu_roof", ai, cpu, ""))

    point_rows = [
        ("accel_baseline", base["eff_ai"], base["sustained"] / GIGA,
         "B=1 reload pathology (M3)"),
        ("accel_streaming", effective_ai, sustained_flops / GIGA,
         f"B={B} streaming (M4 design point)"),
        ("accel_stream_bw_ceiling", effective_ai, bw_limited_flops / GIGA,
         "pin-BW ceiling at streaming AI"),
        ("accel_ideal_reuse", IDEAL_AI, PEAK_FLOPS / GIGA,
         "if perfect reuse -> compute bound"),
        ("cpu_baseline", IDEAL_AI, CPU_CONV_THROUGHPUT / GIGA,
         "measured CPU conv effective rate"),
        ("accel_ridge", PEAK_FLOPS / PIN_BW_BYTES, PEAK_FLOPS / GIGA,
         "accel ridge point AI*=peak/pin_bw"),
    ]
    with (HERE / "roofline_data.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["series", "ai_flop_per_byte", "perf_gflops", "label"])
        for series, ai, perf, label in roof_rows + point_rows:
            w.writerow([series, f"{ai:.6g}", f"{perf:.6g}", label])

    # ---------------- console summary ----------------
    print(f"M4 benchmark -- Conv2d 5-1 on the {M}x{N} @ 100 MHz array "
          f"(streaming B={B})")
    print(f"  baseline (B=1)   : {base['total_cycles']:,.0f} cyc "
          f"-> {base['time_s']:.2f} s, {base['sustained']/1e9:.4f} GFLOP/s "
          f"({base['util']*100:.3f}% peak), AI={base['eff_ai']:.3f}")
    print(f"  streaming (B={B}) : {strm['total_cycles']:,.0f} cyc "
          f"-> {accel_time_s:.2f} s, {sustained_flops/1e9:.4f} GFLOP/s "
          f"({utilization*100:.3f}% peak), AI={effective_ai:.3f}")
    print(f"  stream speedup   : {stream_speedup:.2f}x over the B=1 reload "
          f"baseline ({per_pixel_stream:.2f} cyc/extra pixel)")
    print(f"  AI shift         : {base['eff_ai']:.3f} -> {effective_ai:.3f} "
          f"FLOP/B (ridge={PEAK_FLOPS/PIN_BW_BYTES:.1f}, ideal={IDEAL_AI})")
    print(f"  vs CPU           : {kernel_speedup:.4f}x kernel, "
          f"{amdahl_speedup:.4f}x system (Amdahl, f={CONV_FRACTION})")
    print(f"  energy           : {accel_energy_j:.2f} J "
          f"({accel_j_per_flop*1e12:.3f} pJ/FLOP, static est)")
    print(f"  wrote benchmark_data.csv, roofline_data.csv")


if __name__ == "__main__":
    main()

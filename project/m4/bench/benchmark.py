#!/usr/bin/env python3
"""M4 benchmark: extrapolate measured per-tile cycle costs to a RAFT-scale
convolution and emit the deliverable CSVs.

Pipeline
--------
    tb/tb_top.py::test_benchmark  (make -C ../tb bench-measure)
        -> bench_measured.csv      (real RTL cycles per LOAD/COMPUTE/DRAIN)
    this script
        -> benchmark_data.csv      (throughput / speedup / energy, long form)
        -> roofline_data.csv       (bandwidth-aware roofline points + roofs)

Nothing here is hand-counted: the per-phase cycle costs come from the
simulator clock, and everything else is closed-form arithmetic over the
target layer's tile schedule. The schedule modeled is the one the RTL
actually implements (see tb_top.py::test_conv_raft_dims_e2e): for every
output pixel, sweep the N-tiles, and within each sweep the K-tiles
accumulating on chip -- which RELOADS the weight slab on every K-tile.
That zero-pixel-reuse schedule is the honest operating point and is what
drives the (low) effective arithmetic intensity reported here.

Run:
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
# Read measured per-phase cycles
# =======================================================================
def read_measured(path: Path) -> dict[str, float]:
    cyc: dict[str, float] = {}
    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            cyc[row["phase"]] = float(row["cycles"])
    for need in ("load", "compute_hold", "drain", "tile_full"):
        if need not in cyc:
            raise SystemExit(f"{path} missing phase '{need}'; run "
                             f"`make -C ../tb bench-measure` first.")
    return cyc


# =======================================================================
# Extrapolation
# =======================================================================
def main() -> None:
    cyc = read_measured(HERE / "bench_measured.csv")
    load_c = cyc["load"]
    hold_c = cyc["compute_hold"]
    full_c = cyc["tile_full"]           # COMPUTE + drain (the K=last tile)

    # Per (pixel, N-tile): KT LOADs, (KT-1) held COMPUTEs, 1 draining tile.
    tiles = P * NT                       # weight-reload groups
    cyc_per_group = KT * load_c + (KT - 1) * hold_c + full_c
    total_cycles = tiles * cyc_per_group
    accel_time_s = total_cycles / CLK_HZ

    sustained_flops = LAYER_FLOPS / accel_time_s
    utilization = sustained_flops / PEAK_FLOPS

    # Bandwidth at the operating point: bytes actually pushed over the pins.
    load_bytes = tiles * KT * BYTES_PER_BEAT * 16   # 16 weight beats/slab
    act_bytes = tiles * KT * BYTES_PER_BEAT * 1     # 1 activation beat/tile
    result_bytes = tiles * N * BYTES_PER_BEAT       # N result beats/drain
    pin_bytes = load_bytes + act_bytes + result_bytes
    effective_ai = LAYER_FLOPS / pin_bytes
    bw_limited_flops = effective_ai * PIN_BW_BYTES  # roofline ceiling @ AI

    # Speedups.
    cpu_layer_time_s = LAYER_FLOPS / CPU_CONV_THROUGHPUT
    kernel_speedup = cpu_layer_time_s / accel_time_s
    amdahl_speedup = 1.0 / ((1 - CONV_FRACTION) + CONV_FRACTION / kernel_speedup)

    # Energy.
    accel_energy_j = ACCEL_POWER_W * accel_time_s
    accel_j_per_flop = accel_energy_j / LAYER_FLOPS
    cpu_energy_j = CPU_TDP_W * cpu_layer_time_s
    cpu_j_per_flop = cpu_energy_j / LAYER_FLOPS

    # ---------------- benchmark_data.csv (long form) ----------------
    rows = [
        # metric, value, unit, source/derivation
        ("array_dim", f"{M}x{N}", "", "synth/config.json"),
        ("clock_freq", CLK_HZ, "Hz", "synth/timing_report.txt"),
        ("peak_throughput", PEAK_FLOPS, "FLOP/s", "M*N*2*clk"),
        ("pin_bandwidth", PIN_BW_BYTES, "B/s", "256bit*clk"),
        ("layer", "Conv2d 5-1", "", "ai_calculation.md"),
        ("layer_flops", LAYER_FLOPS, "FLOP", "2*MACs"),
        ("k_tiles", KT, "", "K=Cin*KH*KW=576 /16"),
        ("n_tiles", NT, "", "Cout=64 /16"),
        ("output_pixels", P, "", "batch*Hout*Wout"),
        ("cyc_load", load_c, "cycles", "bench_measured.csv"),
        ("cyc_compute_hold", hold_c, "cycles", "bench_measured.csv"),
        ("cyc_tile_full", full_c, "cycles", "bench_measured.csv"),
        ("cyc_per_reload_group", cyc_per_group, "cycles", "KT*load+(KT-1)*hold+full"),
        ("total_cycles", total_cycles, "cycles", "P*NT*cyc_per_group"),
        ("accel_time", accel_time_s, "s", "total_cycles/clk"),
        ("sustained_throughput", sustained_flops, "FLOP/s", "layer_flops/accel_time"),
        ("utilization", utilization, "frac", "sustained/peak"),
        ("pin_bytes_moved", pin_bytes, "B", "load+act+result beats"),
        ("effective_ai", effective_ai, "FLOP/B", "layer_flops/pin_bytes"),
        ("ideal_ai", IDEAL_AI, "FLOP/B", "ai_calculation.md (fp32, no reuse)"),
        ("bw_limited_throughput", bw_limited_flops, "FLOP/s", "effective_ai*pin_bw"),
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
    # discrete operating points. perf is in GFLOP/s for readability.
    GIGA = 1e9
    ai_sweep = [10 ** (i / 4 - 1) for i in range(int((3 - (-1)) * 4) + 1)]  # 0.1 .. 1000
    roof_rows: list[tuple[str, float, float, str]] = []
    for ai in ai_sweep:
        accel = min(PEAK_FLOPS, ai * PIN_BW_BYTES) / GIGA
        cpu = min(CPU_PEAK_FLOPS, ai * CPU_DRAM_BW_BYTES) / GIGA
        roof_rows.append(("accel_roof", ai, accel, ""))
        roof_rows.append(("cpu_roof", ai, cpu, ""))

    point_rows = [
        ("accel_operating", effective_ai, sustained_flops / GIGA,
         "measured: weight-reload schedule"),
        ("accel_bw_ceiling", effective_ai, bw_limited_flops / GIGA,
         "pin-BW ceiling at operating AI"),
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
    print("M4 benchmark -- Conv2d 5-1 on the 16x16 @ 100 MHz array")
    print(f"  per-reload-group : {cyc_per_group:,.0f} cycles "
          f"({KT} load + {KT-1} hold + 1 drain)")
    print(f"  total            : {total_cycles:,.0f} cycles "
          f"-> {accel_time_s:.3f} s")
    print(f"  sustained        : {sustained_flops/1e9:.4f} GFLOP/s "
          f"({utilization*100:.3f}% of {PEAK_FLOPS/1e9:.1f} GFLOP/s peak)")
    print(f"  effective AI     : {effective_ai:.3f} FLOP/B "
          f"(ridge={PEAK_FLOPS/PIN_BW_BYTES:.1f}; ideal={IDEAL_AI}) "
          f"-> memory/reload bound")
    print(f"  kernel speedup   : {kernel_speedup:.4f}x vs CPU "
          f"({cpu_layer_time_s*1e3:.1f} ms layer)")
    print(f"  system (Amdahl)  : {amdahl_speedup:.4f}x")
    print(f"  energy           : {accel_energy_j:.2f} J "
          f"({accel_j_per_flop*1e12:.3f} pJ/FLOP, static est)")
    print(f"  wrote benchmark_data.csv, roofline_data.csv")


if __name__ == "__main__":
    main()

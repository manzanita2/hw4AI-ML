# CF09 Benchmark results: SW baseline vs HW accelerator

Path used for the accelerator: **fallback / PROJECTED** (no end-to-end cocotb run yet;
the most recent place-and-route failed timing and global routing). Every accelerator
number below is therefore labeled **PROJECTED** and must stay labeled as such in M4.

## Platform

- Hardware (both M1 and this re-run): **AMD Ryzen 9 7940HS** (8c/16t, Zen 4), CPU execution.
- Re-run env: `.venv`, Python 3.14.5, **torch 2.11.0+cu130** (exact match to M1), torchvision 0.26.0 (CPU run).
- Workload: `raft_large` forward, batch `[2,3,520,960]`, synthetic frames, 10 timed forwards (1 warmup).
- Re-run harness: `codefest/cf09/benchmarks/bench_sw_baseline.py`; raw log `sw_baseline_run.txt`.

## Results

| Row | Source | Exec time / forward | Throughput | Memory | Power |
| --- | --- | --- | --- | --- | --- |
| **SW baseline (MEASURED, this re-run)** | `bench_sw_baseline.py` + GNU `time -v` | 5214 ms (median; mean 5313 ms) | 302.3 GFLOP/s | peak RSS 2.76 GiB (2,894,000 KiB) | not measured |
| SW baseline (M1 reference) | `project/m1/sw_baseline.md` | 4150 ms | 380 GFLOP/s | peak RSS 2.41 GiB | not measured |
| **HW accelerator (PROJECTED)** | C1 `cman_ai_analysis.md` + synth | n/a (no runnable sim) | **112.64 GFLOP/s (PROJECTED)** | BW 9.6 GB/s (AXI4-Stream, PROJECTED) | 4.01 W (PROJECTED, see caveat) |

### Projection assumptions (HW row)
- Peak throughput = clock x useful ops/cycle = **220 MHz x 512 FLOP/cycle = 112.64 GFLOP/s** (16x16 MAC array, 256 MAC/cyc, bf16). 220 MHz is a Yosys pre-layout estimate.
- Memory bandwidth = AXI4-Stream interface spec, 256-bit @ 300 MHz = **9.6 GB/s** (`project/m1/interface_selection.md`).
- Power 4.01 W is from `project/m3/synth/runs/RUN_2026-05-31_00-33-25/38-openroad-stamidpnr-2/power.rpt`. **Caveat:** that report is the **20x20** core at a 300 MHz target that **failed setup timing (WNS -4.01 ns) and failed global routing (congestion)** — it does not correspond to the 16x16 / 220 MHz design used for the throughput projection. Treat the energy figures as order-of-magnitude only.

## Speedup (throughput ratio, accelerator / SW)

$$
\text{Speedup}_{vs\ re\text{-}run} = \frac{112.64}{302.3} = \mathbf{0.37\times\ (PROJECTED)}
$$

$$
\text{Speedup}_{vs\ M1} = \frac{112.64}{380} = \mathbf{0.30\times\ (PROJECTED)}
$$

The PROJECTED accelerator is **slower** than the CPU baseline: a 16x16 Sky130 array at
~220 MHz cannot match a 16-thread Zen 4 CPU running an optimized convolution backend.

## Replication of the original M1 timing method

The original M1 number (4.145 ms... i.e. 4.145 s/forward, 380 GFLOP/s) was obtained with
`line_profiler`/`kernprof` timing only the `model(...)` line. That exact method was
reproduced on this hardware with the exact torch build (2.11.0+cu130):

- `bench_sw_kernprof.py` (`@profile main()`, 10 model() calls) → model() line: **10 hits,
  54,652,398 us total → 5.465 s/forward → 288.4 GFLOP/s** (raw: `sw_baseline_kernprof.txt`).

This agrees with the `perf_counter` harness (302 GFLOP/s) within profiler overhead, so the
gap to the original 380 GFLOP/s is **not** a measurement-method or torch-version artifact.
The most likely cause is machine state at M1 time (CPU thermal headroom / power governor /
background load). The re-run figures above are the current, reproducible baseline.

## Energy efficiency

| Metric | Value | Notes |
| --- | --- | --- |
| HW accelerator efficiency | **28.1 GFLOP/s/W (PROJECTED)** | 112.64 GFLOP/s / 4.01 W; mismatched-design caveat above |
| SW baseline efficiency | not available | no CPU power/energy measurement taken |
| Energy efficiency improvement | **not computable** | one-sided: CPU energy not measured |

Energy-efficiency improvement cannot be computed because no CPU power measurement exists;
only the PROJECTED accelerator efficiency is reported, with the design-mismatch caveat.

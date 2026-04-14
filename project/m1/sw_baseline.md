# Software baseline (RAFT `raft_large` forward)

## Platform and configuration

| Item | Value |
|------|--------|
| **CPU** | AMD Ryzen 9 7940HS (8 cores / 16 threads, Zen 4, Phoenix); max boost up to 5.2 GHz, base 4.0 GHz ([AMD product page](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-9-7940hs.html)) |
| **OS** | Linux 6.19.11-100.fc42.x86_64 (Fedora 42, x86_64) |
| **Python** | 3.13.12 |
| **PyTorch** | 2.11.0+cu130 |
| **Workload script** | `algorithms/pytorch-RAFT/plot_optical_flow.py` |
| **Model** | `torchvision.models.optical_flow.raft_large` with `Raft_Large_Weights.DEFAULT` |
| **Input resolution** | `520 x 960` after `F.resize` |
| **Batch size** | **N = 2** image pairs (`img1_batch`, `img2_batch` shaped `[2, 3, 520, 960]` after preprocess; see `codefest/cf02/profiling/torch_results.txt` / `line_prof_results.txt`) |

## How to reproduce profiling (and where results live)

### Line-level timing (10 runs of `main()`, wall time on hot line)

1. Install: `pip install line_profiler`
2. In `plot_optical_flow.py`, keep `@profile` on `main()` and the `kernprof` entry pattern you used.
3. Run from repo root:

   ```bash
   kernprof -l -v algorithms/pytorch-RAFT/plot_optical_flow.py
   ```

4. Redirect or copy output to: `codefest/cf02/profiling/line_prof_results.txt`  
   Binary profile: `plot_optical_flow.py.lprof` (next to the script when run from that directory).

### `torch.profiler` (op-level CPU summary)

1. Wrap `model(...)` in `torch.profiler.profile` with `activities=[ProfilerActivity.CPU]`
2. Save `prof.key_averages().table(...)` to: `codefest/cf02/profiling/torch_results.txt`  
   Combined human log: `codefest/cf02/profiling/project_profile.txt`

### FLOP / layer accounting (`torchinfo`)

1. `pip install torchinfo`
2. `summary(model, input_size=...)` matching your tensor shapes; save stdout to: `codefest/cf02/profiling/torchinfo_results.txt`

### Roofline / arithmetic intensity write-ups

- `codefest/cf02/analysis/ai_calculation.md`
- `codefest/cf02/analysis/partition_rational.md`

### Peak RSS (GNU `time`, 10× `model(...)`)

1. From repo root:

   ```bash
   /usr/bin/time -v python project/m1/bench_raft_10_runs.py
   ```

2. Read **Maximum resident set size (kbytes)** (Linux: KiB units).

3. Full `time -v` capture: `codefest/cf02/profiling/gnu_time_rss_bench.txt`

The harness `project/m1/bench_raft_10_runs.py` runs **10** `raft_large` forwards with batch shape `[2, 3, 520, 960]` after the same resize + `Raft_Large_Weights.DEFAULT.transforms()` as the baseline. It uses **synthetic** RGB tensors so it does not depend on TorchCodec/video decode (decode buffers would add extra RSS on top of the model).

---

## Execution time (wall clock), median over 10 runs

**Scope:** time spent in `list_of_flows = model(img1_batch.to(device), img2_batch.to(device))` only (one full forward per run of `main()`).

**Source:** `codefest/cf02/profiling/line_prof_results.txt` — `kernprof` / `line_profiler` reports `Timer unit: 1e-06 s` (microseconds). For the `model(...)` line: **10 hits**, **total Time = 41,451,320.6** (µs).

- **Mean per forward:**

$$
41{,}451{,}320.6 / 10 = 4{,}145{,}132.06\ \mu\text{s} \approx 4.15\ \text{s}
$$

---

## Throughput (FLOP/s)

**Source:** `codefest/cf02/profiling/torchinfo_results.txt` — **Total mult-adds: 788.14** in torchinfo’s “G multiply-adds” style summary line (`Units.GIGABYTES` label is torchinfo’s unit name; interpret as **788.14 × 10⁹ MACs** per forward for this input).

**FLOP model (same as `ai_calculation.md`):** 1 multiply-add ≈ **2 FLOPs** (mul + add).

- **FLOPs per forward:**

$$
2 \times 788.14 \times 10^9 \approx 1.576 \times 10^{12}\ \text{FLOPs}
$$

- **Effective FLOP/s (using mean wall time 4.145 s):**

$$
\frac{1.576 \times 10^{12}}{4.145} \approx 3.8 \times 10^{11}\ \text{FLOP/s} \approx 380\ \text{GFLOP/s}
$$
---

## Memory usage

### Peak RSS (10 forward passes, measured)

**Method:** GNU `/usr/bin/time -v` on `project/m1/bench_raft_10_runs.py` (10× `model(...)` in a loop; same tensor shapes and preprocessing as the baseline; synthetic frames—see script header).

**Result (this run):**

- **Maximum resident set size:** **2,530,612** KiB (field label `kbytes` on Linux)
- **≈ 2.41 GiB** (convert KiB → GiB):

$$
\frac{2530612}{1024^3} \approx 2.41\ \text{GiB}
$$

**Wall time for that process:** ~52.3 s elapsed (`time -v`).

Raw output: `codefest/cf02/profiling/gnu_time_rss_bench.txt`

### Other references (not RSS)

**From profiler:** `codefest/cf02/profiling/torch_results.txt` lists allocator-related **CPU Mem** peaks during the trace (e.g. `aten::empty` **Self CPU Mem** **6.83 GB**); that reflects **profiled allocation activity**, not resident set size.

**From torchinfo:** `torchinfo_results.txt` gives **Estimated Total Size (MB): 7904.40** for forward-mode accounting (activations + params style estimate).


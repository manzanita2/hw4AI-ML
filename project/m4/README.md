# Milestone 4 — Final Deliverable Package (RAFT GEMM accelerator)

This directory is the M4 submission for the RAFT optical-flow compute
core: the final synthesized RTL, its self-contained cocotb co-simulation,
the regenerated simulation outputs, and the harvested synthesis/PnR
results from the run that produced the M4 numbers, and the
benchmark (`bench/`) that extrapolates measured per-tile cycle costs to a
RAFT-scale convolution. The 9-section design justification report
(`report/`) is scaffolded but not yet populated.

The M4 RTL adds **streaming GEMM**: a block of up to `PIX_BLOCK` pixel
columns is streamed through the resident weights in one COMPUTE, so the
256-cycle weight reload and the systolic pipeline fill amortize over `B`
pixels instead of one. This recovers ~27x of the efficiency the M3
single-pixel core lost to per-pixel weight reloads (see *Benchmark
headline*), using only synthesizable registers (no SRAM macro). The PE
array and arithmetic are bit-for-bit the M3 design, and the `B = 1` path
reduces exactly to M3 behavior (the regression firewall).

## Design point (the real, synthesized design)

| Metric        | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| Array         | **16 x 16 (256 PEs)**, weight-stationary systolic                  |
| Clock         | **100 MHz (10 ns)** — setup closes with +0.667 ns of margin (M3 baseline run) |
| Numerics      | bf16 multiply, fp32 accumulate, bf16 round-out (round-toward-zero) |
| MAC pipeline  | **MAC_LATENCY = 5** (`mul_bf16_p2` 2-stage + `add_fp32_p2` 2-stage)|
| Streaming     | **PIX_BLOCK = 32** pixel columns/COMPUTE (runtime `PIX_COUNT` 1..32); `B=1` = M3 behavior |
| Data plane    | AXI4-Stream, 256-bit (16 bf16 lanes/beat)                          |
| Control plane | AXI4-Lite register file (CTRL.MODE/ACCUM/HOLD, STATUS, **PIX_COUNT @ 0x14**) |
| On-chip cache | `weight_store` (M*N bf16 RAM); per-pixel cross-tile fp32 accumulation in `result_buf[PIX_BLOCK][N]` |
| Co-sim        | **8 PASS + 2 opt-in SKIP**, end-to-end through the bus pins only    |
| PDK / flow    | sky130_fd_sc_hd via LibreLane / OpenLane 2. The committed `synth/*` reports are the **M3 pre-streaming baseline** (run reached step 43 / detailed routing; SLURM-cancelled at the time limit, see `synth/openlane_run.err.txt`). The streaming RTL goes to PnR next; refresh `synth/{timing,area,power}_report.txt` from that run. |

This is the design the committed RTL actually describes. **The RTL is
the source of truth.** Note in particular that the MAC pipeline is the
SHALLOW one (MAC_LATENCY = 5): the deeper MAC_LATENCY = 8 pipeline
(`mul_bf16_p3` + `add_fp32_p4`) that the M3 `synthesis_notes.md`
narrative builds up to was subsequently shallowed back once the 100 MHz
target left timing slack. `synthesis_notes.md` is useful history but is
NOT authoritative for the current shape of the design.

## Relationship to M3

The RTL is the M3 RTL with the pipeline shallowed (p3/p4 -> p2), stale
dimension/latency comments corrected, and the **M4 streaming extension**
added to the compute core + control plane. M1/M2/M3 directories are
unchanged. Diffs vs M3:

- `compute_core_pipelined.sv`: adds `PIX_BLOCK` parameter + `cfg_pix_count`
  input; `act_buf[M]` -> `act_block[PIX_BLOCK][M]`, `result_buf[N]` ->
  `result_buf[PIX_BLOCK][N]`; the single-shot row feed / single capture
  cycle become a per-column stream indexed off `compute_cycle`. The PE
  array, arithmetic, FSM shape, and LOAD-broadcast staging are unchanged;
  `cfg_pix_count = 1` reduces bit-exactly to M3.
- `interface.sv`: adds the `PIX_COUNT` register (0x14, R/W, reset 1) and
  the `cfg_pix_count` output.
- `top.sv`: threads `PIX_BLOCK` (default 32) into the core and wires
  `cfg_pix_count`. No FIFO deepening (streaming is flow-controlled).
- `pe_pipelined.sv`: default `MAC_LATENCY` and depth localparams describe
  the MAC_LATENCY = 5 pipeline; comments/worked examples updated.
- `config.json` lists `mul_bf16_p2.sv` + `add_fp32_p2.sv` (the
  instantiated arithmetic), not the p3/p4 variants; no new module/macro
  for streaming (registers only). See `comment_streaming`.
- The committed `synth/*` reports are the M3 pre-streaming baseline run
  (`RUN_2026-06-04_17-46-11`); the streaming RTL is re-synthesized next.

## File catalog

| File                          | Supports (M4 checklist)        | Contents |
| ----------------------------- | ------------------------------ | -------- |
| `README.md`                   | M4 README                      | This catalog + the authoritative design-point table. |
| `rtl/top.sv`                  | Source code (top module)       | Bus-pin-only top. Instantiates `interface_module`, ingress/egress `fifo_sync`, `weight_store`, `load_seq`, `compute_core_pipelined` (`.MAC_LATENCY(5)`, `.PIX_BLOCK(32)`), egress `skid_buffer`. Wires `cfg_pix_count`. |
| `rtl/interface.sv`            | Source code (interface)        | AXI4-Lite control/status register file (`interface_module`): CTRL.MODE/ACCUM/HOLD, STATUS.WEIGHTS_LOADED/LOAD_ERR, and the M4 **PIX_COUNT** register (0x14) -> `cfg_pix_count`. |
| `rtl/compute_core_pipelined.sv` | Source code (compute core)   | Pipelined systolic FSM + 256 PEs + N result-stage `add_fp32_p2` accumulators. **M4 streaming**: streams up to `PIX_BLOCK` pixel columns/COMPUTE from `act_block[PIX_BLOCK][M]` into `result_buf[PIX_BLOCK][N]` with per-pixel cross-tile fp32 accumulation. (Spec names this `compute_core.sv`; see Deviations.) |
| `rtl/pe_pipelined.sv`         | Source code                    | Pipelined PE: `MUL_STAGES=2`, `ADD_STAGES=2`, `MAC_LATENCY=5`, `ACT_CHAIN_LEN=4`, `PSUM_CHAIN_LEN=3`. Instantiates `mul_bf16_p2` + `add_fp32_p2`. |
| `rtl/mul_bf16_p2.sv`          | Source code                    | 2-stage bf16*bf16 -> fp32 multiplier (instantiated). |
| `rtl/add_fp32_p2.sv`          | Source code                    | 2-stage fp32 adder (instantiated, both in-PE and result-stage). |
| `rtl/mul_bf16_p3.sv`          | Source code (reference only)   | 3-stage radix-4 multiplier. NOT instantiated; kept for reference (the deeper 300 MHz-era pipeline). Not in `config.json`. |
| `rtl/add_fp32_p4.sv`          | Source code (reference only)   | 4-stage fp32 adder. NOT instantiated; kept for reference. Not in `config.json`. |
| `rtl/weight_store.sv`         | Source code                    | M*N-entry bf16 weight RAM, registered read for `load_seq`. |
| `rtl/load_seq.sv`             | Source code                    | FSM that replays `weight_store` into the PE `wt_load` handshake each COMPUTE. |
| `rtl/fifo_sync.sv`            | Source code                    | Parameterized synchronous FIFO (ingress + egress). |
| `rtl/skid_buffer.sv`          | Source code                    | Single-stage AXI4-Stream skid buffer on the egress path. |
| `tb/tb_top.py`                | Final testbench                | cocotb harness, 8 graded tests + 2 opt-in (RAFT-dims conv, benchmark measurement), driven through AXI4-Lite + AXI4-Stream pins only. Includes `test_stream_block` + `test_conv_stream_e2e` (streaming, B>1) and keeps the B=1 GEMM/conv tests as the bit-exact regression. (Spec names this `tb_top.sv`; see Deviations.) |
| `tb/Makefile`                 | Final testbench (driver)       | cocotb/Icarus driver; single-sources `M=N=16`, `PIX_BLOCK=32`, `CLK_PERIOD_NS=10`. `make m3-log` regenerates `../sim/cosim_run.log`; `make synth-yosys` for the gate-count check; `make bench-measure` for the benchmark cycles. |
| `sim/cosim_run.log`           | Final simulation log (PASS)    | Fresh `make m3-log` capture: 8 PASS + 2 SKIP (the 2 opt-in tests). |
| `sim/cosim_waveform.png`      | Final waveform                 | Regenerated 4-panel end-to-end waveform of one LOAD + COMPUTE tile (`test_gemm_tile_e2e`). |
| `sim/render_waveform.py`      | (waveform generator)           | Headless VCD-to-PNG renderer. |
| `synth/config.json`           | OpenLane 2 configuration       | Exact config for `RUN_2026-06-04_17-46-11`: 100 MHz, FP_CORE_UTIL 45, `mul_bf16_p2`/`add_fp32_p2` source list. |
| `synth/openlane_run.log.xz`   | OpenLane run log (stdout)      | xz-compressed stdout of the run (202 MB -> ~0.9 MB), incl. LibreLane's INFO/WARNING/ERROR console lines. `xz -d` to read. |
| `synth/openlane_run.err.txt`  | OpenLane run log (stderr)      | The run's stderr (154 B). Records why PnR stopped: the SLURM job was **cancelled at the wall-clock time limit** during TritonRoute detailed routing (2026-06-05T13:43:19), not a tool crash. |
| `synth/timing_report.txt`     | Timing report                  | Post-route STA (step 42): setup MET (+0.667 ns), 0 setup violations; hold violations are IO-port-only. |
| `synth/area_report.txt`       | Area report                    | Die 16.38 mm^2, std-cell area 8.43M um^2, dominant contributor = combinational (bf16 mul / fp32 add) at ~54%. |
| `synth/power_report.txt`      | Power report                   | 834 mW total (sequential 48.8%, clock 36.6%, comb 14.6%). OpenROAD static estimate, not VCD-back-annotated. |
| `synth/runs/RUN_2026-06-04_17-46-11/` | (source of harvested reports) | The full 13 GB LibreLane run tree. **Git-ignored** (`project/*/synth/runs/`); harvested reports above are committed instead. |
| `bench/benchmark.py`          | Benchmark (driver)             | Reads `bench_measured.csv`, models BOTH the B=1 reload schedule and the B=`PIX_BLOCK` streaming schedule for `Conv2d 5-1`, and emits the two CSVs below. Pure stdlib; every constant cites its source. |
| `bench/bench_measured.csv`    | Benchmark (raw measured data)  | Steady-state per-phase cycle counts measured by `tb/tb_top.py::test_benchmark` over the real RTL: `load=23`; B=1 `stream_hold=424`/`stream_full=440`; B=32 `stream_hold=486`/`stream_full=998`. |
| `bench/benchmark_data.csv`    | Benchmark comparison           | Long-form `metric,value,unit,source`: baseline vs streaming throughput/utilization/effective-AI, streaming speedup, kernel + Amdahl speedup vs CPU, energy. |
| `bench/roofline_data.csv`     | Benchmark (roofline data)      | Plot-ready `series,ai,perf` for the accelerator + CPU roofs (pin BW 3.2 GB/s, DRAM 89.5 GB/s) and the operating points: `accel_baseline` (B=1), `accel_streaming` (B=32, the AI shift), BW-ceiling, ideal-reuse, CPU baseline, ridge. |
| `bench/bench_measure.log`     | Benchmark (measurement log)    | cocotb log of the `test_benchmark` run that produced `bench_measured.csv`. |
| `report/`                     | Design justification (deferred)| Empty (`figures/` stub) — 9-section PDF + LaTeX to be populated. |

## Reproducing the M4 results

```bash
# co-simulation (regenerates sim/cosim_run.log; 8 PASS + 2 SKIP)
cd project/m4/tb
make m3-log

# waveform PNG (needs a VCD; filter to one tile to keep it small)
COCOTB_TEST_FILTER=test_gemm_tile_e2e ENABLE_VCD=1 make
cd ../sim && ../../../.venv-cocotb/bin/python render_waveform.py

# synthesis + PnR (regenerates the run under synth/runs/)
cd ../synth
nix-shell /home/hx3d/opt/librelane --run "librelane config.json" 2>&1 | tee openlane_run.log

# benchmark (two steps)
cd ../tb && make bench-measure        # measure per-phase cycles -> bench/bench_measured.csv
cd ../bench && ../../../.venv-cocotb/bin/python benchmark.py   # -> benchmark_data.csv + roofline_data.csv
```

### Benchmark headline

The benchmark models both schedules the RTL implements, extrapolated to
`Conv2d 5-1` (K=576 -> 36 K-tiles, Cout=64 -> 4 N-tiles, 499,200 pixels):

- **Baseline (B=1, the M3 reload pathology):** cross-K accumulation pins
  ONE output pixel in `result_buf` and **reloads the M*N weight slab on
  every K-tile**, reusing the resident weights across zero extra pixels.
  Effective AI **~0.92 FLOP/byte**, sustained **~0.11 GFLOP/s**
  (**0.22%** of the 51.2 GFLOP/s compute roof) — deep in the
  memory/reload-bound region of the roofline.
- **Streaming (B=32, the M4 design point):** a 32-pixel block streams
  through the resident weights per COMPUTE, so the weight slab is reloaded
  `NT*ceil(P/32)*KT` times instead of `NT*P*KT` — **32x less weight
  traffic**. Effective AI rises to **~8.2 FLOP/byte** (toward the 16.0
  pin-BW ridge), sustained **~3.14 GFLOP/s** (**6.1%** of peak): a
  **~27x speedup** over the B=1 baseline (`stream_speedup_vs_baseline`).

The residual gap to peak is now activation re-streaming + drain bandwidth
(every pixel still streams `KT` activation pushes per N-tile and drains
`N` results), not the weight reload — the operating point has crossed from
reload-bound toward the pin-bandwidth roof. The marginal cost of an extra
pixel in a block is ~2 cycles (1 activation-load + 1 stream column; the
load is not overlapped with the stream). The array remains far below the
CPU's measured ~380 GFLOP/s conv rate (a 16x16 @ 100 MHz array peaks at
51.2 GFLOP/s), so the headline is the **27x streaming gain over the broken
baseline and the AI shift**, not a CPU win. See `report/` for the full
discussion.

Toolchain versions are listed in [`../m3/README.md`](../m3/README.md)
(Icarus 14, cocotb 2.0.1, Yosys 0.63, LibreLane/OpenLane 2 3.0.3).

## Deviations the grader should know about

- **`tb_top.py`, not `tb_top.sv`** — the cocotb harness is Python, per
  the M2 PDF's "your file extensions may be different" carve-out.
- **`compute_core_pipelined.sv`, not `compute_core.sv`** — the module
  is the pipelined replacement; the name is kept to match the RTL and
  `config.json` rather than renamed. Functionally it is the compute core.
- **Two non-instantiated reference files** (`mul_bf16_p3.sv`,
  `add_fp32_p4.sv`) are kept in `rtl/` for history; they are not in
  `config.json` and yosys DCEs them.
- **The 13 GB run tree is git-ignored**; the spec-required reports are
  harvested into `synth/*.txt` and `synth/openlane_run.log.xz`.
- **Hold violations** in the timing report are all on unconstrained
  AXI I/O ports (no `set_input_delay`); reg-to-reg hold is clean.

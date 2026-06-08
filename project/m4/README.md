# Milestone 4 — Final Deliverable Package (RAFT GEMM accelerator)

This directory is the M4 submission for the RAFT optical-flow compute
core: the final synthesized RTL, its self-contained cocotb co-simulation,
the regenerated simulation outputs, and the harvested synthesis/PnR
results from the run that produced the M4 numbers, and the
benchmark (`bench/`) that extrapolates measured per-tile cycle costs to a
RAFT-scale convolution. The 9-section design justification report
(`report/`) is written in LaTeX (`design_justification.tex` + `Makefile`);
all sections are filled in and it builds to the committed
`design_justification.pdf` (9 pages, ~3k words).

## Design point (the real, synthesized design)

| Metric        | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| Array         | **16 x 16 (256 PEs)**, weight-stationary systolic                  |
| Clock         | **100 MHz (10 ns)** — setup closes with +0.667 ns of margin        |
| Numerics      | bf16 multiply, fp32 accumulate, bf16 round-out (round-toward-zero) |
| MAC pipeline  | **MAC_LATENCY = 5** (`mul_bf16_p2` 2-stage + `add_fp32_p2` 2-stage)|
| Data plane    | AXI4-Stream, 256-bit (16 bf16 lanes/beat)                          |
| Control plane | AXI4-Lite register file (CTRL.MODE/ACCUM/HOLD, STATUS)             |
| On-chip cache | `weight_store` (M*N bf16 RAM); cross-tile fp32 accumulation        |
| Co-sim        | 6 PASS + 2 opt-in SKIP, end-to-end through the bus pins only       |
| PDK / flow    | sky130_fd_sc_hd via LibreLane / OpenLane 2, run reached step 43 (detailed routing); SLURM-cancelled at the time limit mid-route (see `synth/openlane_run.err.txt`) |

This is the design the committed RTL actually describes. **The RTL is
the source of truth.** Note in particular that the MAC pipeline is the
SHALLOW one (MAC_LATENCY = 5): the deeper MAC_LATENCY = 8 pipeline
(`mul_bf16_p3` + `add_fp32_p4`) that the M3 `synthesis_notes.md`
narrative builds up to was subsequently shallowed back once the 100 MHz
target left timing slack. `synthesis_notes.md` is useful history but is
NOT authoritative for the current shape of the design.

## Relationship to M3

The RTL is the M3 RTL with the pipeline shallowed (p3/p4 -> p2) and
stale dimension/latency comments corrected to match the current design.
M1/M2/M3 directories are unchanged. Diffs vs M3:

- `compute_core_pipelined.sv` / `pe_pipelined.sv`: default `MAC_LATENCY`
  and depth localparams describe the MAC_LATENCY = 5 pipeline; header
  comments and worked cycle examples updated.
- `config.json` lists `mul_bf16_p2.sv` + `add_fp32_p2.sv` (the
  instantiated arithmetic), not the p3/p4 variants.
- Synthesis/timing/area/power numbers come from a NEW post-M3 run
  (`RUN_2026-06-04_17-46-11`), not the M3-committed 4x4 @ 300 MHz reports.

## File catalog

| File                          | Supports (M4 checklist)        | Contents |
| ----------------------------- | ------------------------------ | -------- |
| `README.md`                   | M4 README                      | This catalog + the authoritative design-point table. |
| `rtl/top.sv`                  | Source code (top module)       | Bus-pin-only top. Instantiates `interface_module`, ingress/egress `fifo_sync`, `weight_store`, `load_seq`, `compute_core_pipelined` (`.MAC_LATENCY(5)`), egress `skid_buffer`. |
| `rtl/interface.sv`            | Source code (interface)        | AXI4-Lite control/status register file (`interface_module`): CTRL.MODE/ACCUM/HOLD, STATUS.WEIGHTS_LOADED/LOAD_ERR. |
| `rtl/compute_core_pipelined.sv` | Source code (compute core)   | Pipelined systolic FSM + 256 PEs + N result-stage `add_fp32_p2` accumulators for cross-tile fp32 accumulation. (Spec names this `compute_core.sv`; see Deviations.) |
| `rtl/pe_pipelined.sv`         | Source code                    | Pipelined PE: `MUL_STAGES=2`, `ADD_STAGES=2`, `MAC_LATENCY=5`, `ACT_CHAIN_LEN=4`, `PSUM_CHAIN_LEN=3`. Instantiates `mul_bf16_p2` + `add_fp32_p2`. |
| `rtl/mul_bf16_p2.sv`          | Source code                    | 2-stage bf16*bf16 -> fp32 multiplier (instantiated). |
| `rtl/add_fp32_p2.sv`          | Source code                    | 2-stage fp32 adder (instantiated, both in-PE and result-stage). |
| `rtl/mul_bf16_p3.sv`          | Source code (reference only)   | 3-stage radix-4 multiplier. NOT instantiated; kept for reference (the deeper 300 MHz-era pipeline). Not in `config.json`. |
| `rtl/add_fp32_p4.sv`          | Source code (reference only)   | 4-stage fp32 adder. NOT instantiated; kept for reference. Not in `config.json`. |
| `rtl/weight_store.sv`         | Source code                    | M*N-entry bf16 weight RAM, registered read for `load_seq`. |
| `rtl/load_seq.sv`             | Source code                    | FSM that replays `weight_store` into the PE `wt_load` handshake each COMPUTE. |
| `rtl/fifo_sync.sv`            | Source code                    | Parameterized synchronous FIFO (ingress + egress). |
| `rtl/skid_buffer.sv`          | Source code                    | Single-stage AXI4-Stream skid buffer on the egress path. |
| `tb/tb_top.py`                | Final testbench                | cocotb harness, 6 graded tests + 2 opt-in (RAFT-dims conv, benchmark measurement), driven through AXI4-Lite + AXI4-Stream pins only. (Spec names this `tb_top.sv`; see Deviations.) |
| `tb/Makefile`                 | Final testbench (driver)       | cocotb/Icarus driver; single-sources `M=N=16`, `CLK_PERIOD_NS=10`. `make m3-log` regenerates `../sim/cosim_run.log`; `make synth-yosys` for the gate-count check. |
| `sim/cosim_run.log`           | Final simulation log (PASS)    | Fresh `make m3-log` capture: 6 PASS + 2 SKIP (the 2 opt-in tests). |
| `sim/cosim_waveform.png`      | Final waveform                 | Regenerated 4-panel end-to-end waveform of one LOAD + COMPUTE tile (`test_gemm_tile_e2e`). |
| `sim/render_waveform.py`      | (waveform generator)           | Headless VCD-to-PNG renderer. |
| `synth/config.json`           | OpenLane 2 configuration       | Exact config for `RUN_2026-06-04_17-46-11`: 100 MHz, FP_CORE_UTIL 45, `mul_bf16_p2`/`add_fp32_p2` source list. |
| `synth/openlane_run.log.xz`   | OpenLane run log (stdout)      | xz-compressed stdout of the run (202 MB -> ~0.9 MB), incl. LibreLane's INFO/WARNING/ERROR console lines. `xz -d` to read. |
| `synth/openlane_run.err.txt`  | OpenLane run log (stderr)      | The run's stderr (154 B). Records why PnR stopped: the SLURM job was **cancelled at the wall-clock time limit** during TritonRoute detailed routing (2026-06-05T13:43:19), not a tool crash. |
| `synth/timing_report.txt`     | Timing report                  | Post-route STA (step 42): setup MET (+0.667 ns), 0 setup violations; hold violations are IO-port-only. |
| `synth/area_report.txt`       | Area report                    | Die 16.38 mm^2, std-cell area 8.43M um^2, dominant contributor = combinational (bf16 mul / fp32 add) at ~54%. |
| `synth/power_report.txt`      | Power report                   | 834 mW total (sequential 48.8%, clock 36.6%, comb 14.6%). OpenROAD static estimate, not VCD-back-annotated. |
| `synth/runs/RUN_2026-06-04_17-46-11/` | (source of harvested reports) | The full 13 GB LibreLane run tree. **Git-ignored** (`project/*/synth/runs/`); harvested reports above are committed instead. |
| `bench/benchmark.md`          | Benchmark comparison (writeup) | Section-4 writeup: measured throughput (0.115 GFLOP/s), speedup vs M1 (0.0003x — honestly slower, with cause), energy, roofline reference, and the streaming ~8.2 FLOP/B out-of-scope note. |
| `bench/benchmark.py`          | Benchmark (driver)             | Reads `bench_measured.csv`, models the RTL's per-(pixel,N-tile) weight-reload schedule for `Conv2d 5-1`, and emits the two CSVs below. Pure stdlib; every constant cites its source. |
| `bench/bench_measured.csv`    | Benchmark (raw measured data)  | Steady-state per-phase cycle counts measured by `tb/tb_top.py::test_benchmark` over the real RTL: load=23, compute_hold=422, drain=16 cycles. |
| `bench/benchmark_data.csv`    | Benchmark comparison           | Long-form `metric,value,unit,source`: throughput, utilization, effective AI, kernel + Amdahl speedup, energy. |
| `bench/roofline_data.csv`     | Benchmark (roofline data)      | Plot-ready `series,ai,perf` for the accelerator + CPU roofs (pin BW 3.2 GB/s, DRAM 89.5 GB/s) and the operating points (measured, BW-ceiling, ideal-reuse, CPU baseline, ridge). |
| `bench/roofline_final.yml`    | Benchmark (roofline config)    | Input to the shared `tools/roofplot/roofplot.py` generator: accelerator roof (51.2 GFLOP/s, 3.2 GB/s) + the plotted points (measured, SW baseline, ideal-reuse, streaming projection). Every value cites `benchmark_data.csv`. |
| `bench/roofline_final.png`    | Final roofline plot            | The required Section-4 plot, generated by `tools/roofplot/roofplot.py` from `roofline_final.yml`: HW roofline, SW baseline point, and the **measured** accelerator point (AI 0.92, 0.115 GFLOP/s); streaming AI ~8.2 shown as a not-built projection. |
| `bench/bench_measure.log`     | Benchmark (measurement log)    | cocotb log of the `test_benchmark` run that produced `bench_measured.csv`. |
| `report/design_justification.tex` | Design justification (LaTeX) | Complete 9-section report. PSU-logo title page; all sections written (motivation, roofline, precision, dataflow/architecture, interface, verification, synthesis, benchmark, "what did not work"). Builds to the committed `design_justification.pdf` (9 pages, ~3k words). |
| `report/Makefile`             | Design justification (build)   | `make` -> `design_justification.pdf` (runs `pdflatex` twice for refs); `make clean` / `make cleanall`. |
| `report/design_justification.md` | Design justification (draft)| Markdown draft of the 9-section report; content source for the `.tex`. "What did not work" written out (reuse blindspot, streaming attempt, PnR non-convergence, revert). |
| `report/figures/`             | Design justification (figures) | All figures the report references, kept together per the rubric tree. `make_block_diagram.py` -> `block_diagram.png` (top.sv module graph), `make_dataflow_diagram.py` -> `dataflow_diagram.png` (weight-stationary dataflow + phase timeline), `psu_logo.png` (title page), and report-local copies of `roofline_final.png` (from `bench/`) and `cosim_waveform.png` (from `sim/`). |

## Reproducing the M4 results

```bash
# co-simulation (regenerates sim/cosim_run.log; 6 PASS + 1 SKIP)
cd project/m4/tb
make m3-log

# waveform PNG (needs a VCD; filter to one tile to keep it small)
COCOTB_TEST_FILTER=test_gemm_tile_e2e ENABLE_VCD=1 make
cd ../sim && ../../../.venv-cocotb/bin/python render_waveform.py

# synthesis + PnR (regenerates the run under synth/runs/)
cd ../synth
nix-shell /home/hx3d/opt/librelane --run "librelane config.json" 2>&1 | tee openlane_run.log

# benchmark (three steps)
cd ../tb && make bench-measure        # measure per-phase cycles -> bench/bench_measured.csv
cd ../bench && ../../../.venv-cocotb/bin/python benchmark.py        # -> benchmark_data.csv + roofline_data.csv
# roofline PNG via the shared tool (needs PyYAML; run from repo root)
cd ../../.. && python3 tools/roofplot/roofplot.py --config project/m4/bench/roofline_final.yml  # -> roofline_final.png

# report figures (block + dataflow diagrams; waveform script is in sim/)
cd project/m4/report/figures
../../../../.venv-cocotb/bin/python make_block_diagram.py      # -> block_diagram.png
../../../../.venv-cocotb/bin/python make_dataflow_diagram.py   # -> dataflow_diagram.png
# refresh the report-local copies of the bench/sim figures
cp ../../bench/roofline_final.png ../../sim/cosim_waveform.png .

# design justification report (-> report/design_justification.pdf)
cd .. && make                            # runs pdflatex twice for refs
```

### Benchmark headline

The measured per-tile costs feed the schedule the RTL actually runs
(`tb_top.py::test_conv_raft_dims_e2e`): cross-K accumulation pins one
output pixel in `result_buf` and **reloads the weight slab on every
K-tile**, so the resident weights are reused across zero extra pixels.
Extrapolated to `Conv2d 5-1` this gives an effective arithmetic intensity
of **~0.92 FLOP/byte** (vs the algorithm's intrinsic 144 and the array's
ridge of 16), i.e. the operating point sits deep in the memory/reload-
bound region of the roofline — sustained **~0.12 GFLOP/s** against a
**51.2 GFLOP/s** compute roof, i.e. ~3,300x slower than the CPU baseline on
this layer. Pixel-batched (streaming) weight reuse would lift effective AI to
**~8.2 FLOP/byte** (~9x), but it was out of scope for the final submission: the
trial streaming build could not close timing in the one remaining PnR window
and was reverted (see [`bench/benchmark.md`](bench/benchmark.md) and the "What
did not work" section of
[`report/design_justification.md`](report/design_justification.md)).

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

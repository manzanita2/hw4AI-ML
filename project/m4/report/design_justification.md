# Design Justification Report -- M4

Markdown draft for `design_justification.pdf`. Sections 1-8 are stubs to be
expanded; the nine required sections are kept distinct and in spec order (the
grader counts them separately). Section 9 ("What did not work") is written out
because the streaming attempt and its PnR failure are the central engineering
lesson of this milestone.

Target: 2,000-5,000 words in the final PDF.

---

## 1. Problem and motivation

TODO. What kernel is accelerated and why custom hardware.
- Kernel: `Conv2d 5-1` in RAFT `raft_large`; dominant `aten::mkldnn_convolution`
  at 53.02% forward self-CPU (`codefest/cf02/profiling/torch_results.txt`).
- Cite M1 profiling numbers: 4.145 s mean forward, 788.14 GMAC, ~380 GFLOP/s
  effective conv rate (`project/m1/sw_baseline.md`).

## 2. Roofline analysis

TODO. Arithmetic intensity of the target kernel; compute- vs memory-bound; how
it shaped the architecture.
- Algorithm intrinsic AI ~144 FLOP/B; accelerator ridge AI = 16; measured
  operating AI = 0.92 FLOP/B (memory/reload bound).
- Figure: `../bench/roofline_final.png`.

## 3. Precision and data format

TODO. bf16 multiply, fp32 accumulate, bf16 round-out (RTZ); why; reference the
M2 precision document. Error analysis / acceptability.

## 4. Dataflow and architecture

TODO. Weight-stationary 16x16 systolic array; compute core, memory hierarchy,
data path. Why weight-stationary fits the kernel. Pipeline latency (MAC_LATENCY)
and the LOAD/COMPUTE/DRAIN FSM.

## 5. Hardware interface

TODO. AXI4-Stream data plane + AXI4-Lite control plane; why; effective
bandwidth at target throughput (256-bit AXIS @ 100 MHz = 3.2 GB/s); whether
interface-bound and the quantified answer.

## 6. Verification

TODO. cocotb co-simulation (`tb/tb_top.py`), the graded tests and what each
covers (GEMM tile, tiled convolution, RAFT-dims e2e, benchmark measurement);
reference M2/M3 testbenches; PASS contract (`sim/cosim_run.log`).

## 7. Synthesis results

TODO. Area, timing, power with numbers and dominant contributors.
- Timing: closes at 100 MHz (`../synth/timing_report.txt`); state WNS/setup/hold.
- Area: total um^2 and dominant module (`../synth/area_report.txt`).
- Power: static estimate 0.834 W (`../synth/power_report.txt`).

## 8. Benchmark results

TODO. Throughput and energy vs software baseline; explain the gap between
measured and theoretical. Summarize from `../bench/benchmark.md`:
- Sustained 0.115 GFLOP/s (0.22% of 51.2 GFLOP/s peak); kernel speedup 0.0003x
  (accelerator is ~3,300x slower than CPU on this layer).
- Gap cause: weight-reload schedule, zero pixel reuse, AI 0.92 << ridge 16.

## 9. What did not work

Two related setbacks define this milestone: a **design-process blindspot** in
the original schedule, and a **failed attempt to fix it** under the one-shot PnR
constraint.

### 9.1 The blindspot: no pixel reuse

The shipped M3 architecture accumulates a convolution output across K-tiles by
pinning a single output pixel in the N-wide `result_buf` and **reloading the
entire weight slab on every K-tile**. Each resident weight set is therefore
reused across exactly one pixel. I did not recognize how severely this capped
performance until the per-tile cycle costs were extrapolated to RAFT scale in
the benchmark: the effective arithmetic intensity collapses to ~0.92 FLOP/byte
(against an algorithmic 144 and an array ridge of 16), the array runs at 0.22%
utilization, and the accelerator ends up ~3,300x slower than the CPU baseline on
this layer. The lesson: I optimized the compute datapath (pipelined MACs,
timing closure) before validating the *dataflow*'s reuse against the roofline.
The roofline analysis should have gated the schedule choice up front, not
surfaced as a post-hoc benchmark result.

### 9.2 The attempted fix: streaming GEMM

The natural remedy is to keep weights resident and stream a block of `B`
pixel-columns through them, amortizing one weight load and one pipeline fill
over `B` pixels. Modeling showed this would raise effective AI from ~0.92 to
**~8.2 FLOP/byte** (~9x) and move the operating point up the bandwidth roof
(still memory-bound at 8.2 < ridge 16, but roughly an order of magnitude
faster). I implemented a register-based version: widen `act_buf` -> `act_block`
`[B][M]` and `result_buf` -> `[B][N]`, add a `PIX_BLOCK` parameter and a runtime
`cfg_pix_count`, and generalize the skewed activation feed and result-capture
indexing so the `B=1` path stays bit-exact with M3. Co-simulation passed
(8 PASS + 2 opt-in SKIP) and the `B=1` regression remained bit-exact.

### 9.3 Why it was reverted

The streaming netlist did not close timing, and there was only one PnR window
left:

- **Pre-PnR (ideal clock, zero parasitics):** register-to-register setup worst
  slack was already **-71.5 ns** across ~30,000 violating paths. Place-and-route
  can only add delay, never remove logic levels, so this is unrecoverable by
  tuning.
- **Post-CTS:** worst negative slack settled at **-10.4 ns** on a 10 ns period
  (true critical path ~20 ns, ~50 MHz). For comparison, the shipped M3 design
  reached only **-1.86 ns** post-CTS and the resizer drove it to **0.0 (met)**,
  then completed detailed routing.
- **Critical path:** started at the streaming pixel counter
  `compute_cycle[4]` (fanout 1,127), fed a deep buffer tree, then ~30 levels of
  combinational index/decode logic into the 32-deep `act_block`/`result_buf`
  selection -- the mux-cone pathology of indexing register arrays by a counter.
- The post-CTS resizer could not converge (~66,000 ns total negative slack) and
  the run exhausted its wall-clock window before routing.

I reverted to the pre-streaming design, which is verified and closes timing, and
report its measured numbers as the final result.

### 9.4 What I would do differently

- Make the roofline / reuse analysis a gate on the dataflow before investing in
  datapath timing closure.
- If pursuing streaming, break the counter-indexed array access into a pipelined
  address-decode (or a shift-register activation feed) so the combinational cone
  does not exceed the clock period, and reduce `B` to bound the mux fanout.
- Budget more than one PnR iteration for any change that alters the netlist
  structure, given the long flow turnaround.

See `../bench/benchmark.md` for the measured operating point and the streaming
projection.

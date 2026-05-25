# Milestone 3 — Top Integration, End-to-End Co-Sim, OpenLane 2 Synthesis

This directory holds the M3 deliverables for the RAFT compute core: the
integrated `top.sv` accelerator (a pipelined `compute_core_pipelined`
plus the M3 `interface_module`, FIFOs, weight cache, load sequencer,
and an egress skid buffer), the cocotb co-simulation that proves the
dataflow end-to-end through the bus only, and the OpenLane 2 synthesis
flow on sky130.

## Headline numbers (post-resizer, OpenLane RUN_2026-05-24_18-50-37, sky130 typical corner)


| Metric                                        | M3 value                      | Spec / M2 baseline                                   |
| --------------------------------------------- | ----------------------------- | ---------------------------------------------------- |
| Cocotb co-sim                                 | 5/5 PASS, 16,191 ns wall      | end-to-end through AXI4-Lite + AXI4-Stream pins only |
| Setup WNS (post-resizer)                      | -1.130 ns                     | 3.333 ns target (300 MHz)                            |
| Setup TNS                                     | -611 ns                       | (down from -1,072 ns at iter 6)                      |
| Achieved Fmax                                 | ~224 MHz (period_min 4.46 ns) | spec target 300 MHz                                  |
| Mapped cells (M=N=4)                          | 42,372                        | +3.0 % vs iter 6 baseline                            |
| Chip area (M=N=4)                             | 528,935 µm² (~0.529 mm²)      | +4.7 % vs iter 6 baseline                            |
| Total power (M=N=4, post-resizer, 0.5 toggle) | 361.06 mW                     | first-order budget, not shippable                    |


The 300 MHz target is **not closed**; this submission is the
"documented scope adjustment with synthesis attempt" path the M3 spec
allows. See `[synthesis_notes.md](synthesis_notes.md)` and
`[synth/critical_path.md](synth/critical_path.md)` for the iteration
ledger and the current critical-path identification.

## File catalog (M3-spec required entries)


| File                            | Contents                                                                                                                                                                                                                                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `README.md`                     | This file. Catalogs every M3 file plus simulator / OpenLane 2 versions and reproduction commands.                                                                                                                                                                                                            |
| `rtl/top.sv`                    | Integrated top module. Bus-pin-only ports. Instantiates `interface_module`, ingress / egress FIFOs, `weight_store`, `load_seq`, `compute_core_pipelined` (MAC_LATENCY = 8), and an egress `skid_buffer`.                                                                                                     |
| `rtl/interface.sv`              | M3 AXI4-Lite control / status register file (module name `interface_module`). Adds CTRL.MODE (bit 1) and STATUS.WEIGHTS_LOADED / STATUS.LOAD_ERR (bits 2-3) on top of the M2 register map.                                                                                                                   |
| `rtl/weight_store.sv`           | M*N-entry bf16 weight RAM. AXIS-beat write port (driven by the LOAD_WEIGHTS demux), **registered** read for `load_seq` (Phase 10). Sticky `weights_loaded` and `load_err` flags wired to STATUS.                                                                                                             |
| `rtl/load_seq.sv`               | Tiny FSM that replays `weight_store` into `compute_core_pipelined`'s existing `wt_load` handshake at the start of every COMPUTE. Keeps `pe.sv` weight-stationary semantics unchanged.                                                                                                                        |
| `rtl/fifo_sync.sv`              | Parameterized synchronous FIFO (`WIDTH`, `DEPTH`). Used twice: ingress (depth 4 skid), egress (depth N). Phase 10: pointer-update `always_ff` is split from the memory-write `always_ff` so reset never reaches the `mem` D-pin.                                                                             |
| `rtl/skid_buffer.sv`            | Single-stage AXI4-Stream skid buffer (Phase 9). Sits between `egress_fifo` and `m_axis_`*; breaks the egress mux fanout cone that was the WNS critical path.                                                                                                                                                 |
| `rtl/compute_core_pipelined.sv` | M3-only pipelined replacement for the M2 `compute_core`. Same bus-level FSM, but instantiates `pe_pipelined` with `MAC_LATENCY = 8` and stages every per-PE FSM broadcast (cfg_start, drain phase, etc.) with a "disjunct trick" to defeat Yosys `opt_merge` (Phase 5). All flops are async-reset (Phase 8). |
| `rtl/pe_pipelined.sv`           | Pipelined PE: `MUL_STAGES = 3`, `MAC_LATENCY = 8`, `ACT_CHAIN_LEN = 7`, `PSUM_CHAIN_LEN = 4`. Async-reset throughout.                                                                                                                                                                                        |
| `rtl/mul_bf16_p3.sv`            | 3-stage pipelined bf16*bf16 -> fp32 multiplier (Phase 11). Implements a B-half radix-4 split: stage 1 does two parallel 4x8 partial products, stage 2 does a 16-bit shift-add CPA, stage 3 normalizes / packs. Bit-exact equivalent to the M2 `mul_bf16` reference.                                          |
| `rtl/mul_bf16_p2.sv`            | Predecessor 2-stage multiplier (kept in tree for diff-against-iter-6 reference; **not instantiated** in the current netlist).                                                                                                                                                                                |
| `rtl/add_fp32_p4.sv`            | 4-stage pipelined fp32 adder used inside `pe_pipelined` for the partial-sum accumulator.                                                                                                                                                                                                                     |
| `tb/tb_top.py`                  | cocotb harness exercising `top` end-to-end through the AXI4-Lite + AXI4-Stream pins only. Five tests; see "Tests" below. Spec lists this as `tb_top.sv`; see "Filename deviation".                                                                                                                           |
| `tb/Makefile`                   | cocotb / Icarus driver. `make` builds and runs `tb_top`. `make m3-log` regenerates `../sim/cosim_run.log` from a clean state.                                                                                                                                                                                |
| `sim/cosim_run.log`             | Fresh `make m3-log` capture. Five `PASS:` lines, one per test.                                                                                                                                                                                                                                               |
| `sim/cosim_waveform.png`        | Annotated end-to-end waveform from `tb/artifacts/top.vcd`. Three regions shaded: host write, internal compute, host read.                                                                                                                                                                                    |
| `sim/render_waveform.py`        | Headless VCD-to-PNG renderer used to produce `cosim_waveform.png` (no X server required, unlike gtkwave).                                                                                                                                                                                                    |
| `synth/config.json`             | OpenLane 2 configuration. `DESIGN_NAME = top`, sky130, 300 MHz target, M = N = 4 bring-up. Lists every `rtl/*.sv` file consumed (mul_bf16_p3, not p2).                                                                                                                                                       |
| `synth/openlane_run.log`        | Captured stdout/stderr from the OpenLane 2 invocation.                                                                                                                                                                                                                                                       |
| `synth/timing_report.txt`       | Setup / hold / WNS / TNS / period_min summary, rolled up from OpenLane step 38 (post-resizer STA), with iter-6 -> iter-7 deltas.                                                                                                                                                                             |
| `synth/area_report.txt`         | Total cell area + per-module gate counts. Rolled up from yosys `stat` (step 06) and OpenROAD detailed-placement (step 34), with iter-6 -> iter-7 deltas.                                                                                                                                                     |
| `synth/power_report.txt`        | OpenROAD `report_power` rollup at typical corner.                                                                                                                                                                                                                                                            |
| `synth/critical_path.md`        | Detailed walk of the current WNS path: start register, end register, logic stages, why it dominates, what would shorten it next.                                                                                                                                                                             |
| `synth/yosys_48x48_run.log`     | 48x48 elab-only yosys run, used to size the gate-count gap and validate the per-PE pipeline expansion.                                                                                                                                                                                                       |
| `synthesis_notes.md`            | ≥500-word narrative covering all 11 phases: what synthesized, what failed, exact error messages, scope adjustments + rationale, M4 implications.                                                                                                                                                             |


## Filename deviation (carried forward from M2)

The M3 spec lists the testbench at `project/m3/tb/tb_top.sv`. The
actual file is `tb_top.py` because the cocotb co-simulation harness is
written in Python, exactly like the M2 testbenches. The M2 PDF
explicitly allows this:

> Note: Depending on the tools you are using and on your project
> specifics, your file extensions may be different. Please respect
> the repository structure as closely as you can.
> -- `documents/hw4ai_ece510_project_milestone_2_spring26_r1.pdf:22-23`

The M3 PDF does not re-state the clause, but the directory layout
(`rtl/`, `tb/`, `sim/`, `synth/`) and the fact that **every** test the
grader actually exercises lives in `tb_top.py` keep this submission
within the spirit of the spec.

## Architecture summary

```
                AXI4-Lite slave  ----->  interface_module (CTRL/STATUS/SCRATCH)
                                                | cfg_start / cfg_mode
                                                v
                                  +-----------------------+
  AXI4-Stream slave  ---> ingress | LOAD vs COMPUTE demux |---> weight_store --+
                          fifo    +-----------+-----------+      (registered   |
                                              v                    read port)  |
                                  compute_core_pipelined (MAC_LATENCY = 8)     |
                                              ^                                |
                                              |          load_seq <------------+
                                              v
                                  egress_fifo ---> skid_buffer ---> AXI4-Stream
                                                   (Phase 9)        master m_axis_*
```

### What's new versus M2

- `**top.sv**`: bus-pin-only wrapper; the only module the grader is
asked to elaborate. Spec path: `project/m3/rtl/top.sv`. M2's `compute_core`
is *not* used here -- M3 instantiates the pipelined replacement
`compute_core_pipelined`.
- **On-chip `weight_store*`* so the host streams weights *once*, not
once per compute tile (M2's behavior). Phase 10 added a registered
read port to break the `load_seq -> weight_store -> compute_core`
combinational path.
- `**load_seq*`* replays cached weights into the pipelined core's
unchanged `wt_load` handshake, keeping the weight-stationary
dataflow promised in `project/architecture.md`.
- **Two flop-array `fifo_sync` instances** decouple the AXI4-Stream
pins from the core's bursty consumption / drain. The egress side
also gets a `**skid_buffer`** (Phase 9) that breaks the flop-array
egress mux fanout cone.
- `**compute_core_pipelined` + `pe_pipelined` + `mul_bf16_p3` +
`add_fp32_p4**`: a deeper arithmetic pipeline (`MAC_LATENCY = 8`, vs
M2's combinational MAC). Phase 11 split the bf16 multiplier into a
3-stage radix-4 pipeline to break the `bf16 mul stage 1`
partial-product reduce critical path.
- **AXI-Lite `CTRL.MODE` (bit 1)** and **STATUS bits 2-3** so the host
can disambiguate "I'm loading weights now" from "I'm sending an
activation tile now" on a single AXI4-Stream port.
- **Asynchronous active-high `rst`** across every M3 RTL file. M2 was
synchronous-reset, but sky130 has no synchronous-reset DFF cells, so
the M3 reset convention was flipped (Phase 8) to remove `rst` from
the critical path. The M2 source remains synchronous-reset and its
testbenches still pass bit-exact.

## Tests

`tb_top.py` runs five cocotb tests, all driven through the bus only:

1. `test_top_smoke` -- reset + idle outputs (canary).
2. `test_axil_scratch_loopback` -- write + read SCRATCH @ 0x10
  (regfile sanity).
3. `test_raft_conv_tiled_e2e` -- **headline test**. Tile a small
  RAFT-style 1x1 projection conv (Cin = 8, Cout = 8, kernel = 1,
   stride = 1, padding = 0, H = W = 2) into 16 M=N=K=4 GEMM tile calls
   plus 2 weight loads, all driven through AXI-Lite + AXI-Stream.
   Compares the assembled output map against a numpy bf16 reference
   and prints a single `PASS:` line.
4. `test_weight_reuse_two_activation_tiles` -- load weights once, run
  two compute tiles with different activations. Proves the on-chip
   cache exists.
5. `test_backpressure` -- hold `m_axis_tready=0` for several cycles
  mid-drain. Proves the egress FIFO + skid buffer actually decouple
   the drain from downstream backpressure.

The headline conv mirrors the structure of the 1x1 channel-projection
convs in `raft_large` (the M1 profiling target). RAFT itself uses
Cin / Cout in the ~96 - 256 range; we scale down so cocotb finishes
in seconds, not hours, while keeping the structure that matters
(K-tiling on the reduction axis, M-row tiling, N-column tiling, weight
reuse across multiple activation tiles).

## Toolchain


| Tool                          | Version      | Use                                                                                                             |
| ----------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------- |
| Icarus Verilog                | 14.0 (devel) | RTL compile + simulation, `-g2012` for SystemVerilog dialect                                                    |
| Python                        | 3.11.9       | cocotb runtime                                                                                                  |
| cocotb                        | 2.0.1        | testbench framework                                                                                             |
| matplotlib                    | 3.10.x       | `sim/render_waveform.py`                                                                                        |
| pyvcd                         | 0.4.x        | (installed but unused; the renderer ships its own VCD parser to handle iverilog generate-block scopes)          |
| Yosys                         | 0.63         | RTL synthesis (invoked through OpenLane 2)                                                                      |
| LibreLane (a.k.a. OpenLane 2) | 3.0.3        | end-to-end ASIC flow on sky130; the install lives at `/home/hx3d/opt/librelane/` and is invoked via `nix-shell` |


## Reproducing M3

```bash
git clone <repo-url> hw4AI-ML
cd hw4AI-ML

# one-time: cocotb venv
python3.11 -m venv .venv-cocotb
.venv-cocotb/bin/pip install cocotb==2.0.1 matplotlib pyvcd

# co-simulation -- regenerates project/m3/sim/cosim_run.log from clean
cd project/m3/tb
make m3-log
# expect: 5 PASS lines

# waveform PNG -- regenerates project/m3/sim/cosim_waveform.png
cd ../sim
../../../.venv-cocotb/bin/python render_waveform.py

# OpenLane 2 synthesis -- runs full sky130 flow at M=N=4
cd ../synth
nix-shell /home/hx3d/opt/librelane --run "librelane config.json" 2>&1 | tee openlane_run.log
# OpenLane writes its run directory under runs/<timestamp>/; the
# committed reports under project/m3/synth/ are extracted from there.
```

For the M = N = 48 yosys-only synthesis attempt cited in
`synthesis_notes.md` (the "scope adjustment with synthesis attempt"
path the M3 spec allows), pass parameter overrides to yosys directly:

```bash
yosys -p "
read_verilog -sv project/m3/rtl/*.sv project/m2/rtl/{acc_fp32,pe,compute_core}.sv
chparam -set M 48 -set N 48 top
synth -top top
stat
"
```

## M3 deviations from M1 / M2

- **M2 RTL is frozen.** M3 does *not* alter `project/m2/rtl/*.sv`. All
pipelining lives in M3-only files (`compute_core_pipelined.sv`,
`pe_pipelined.sv`, `mul_bf16_p3.sv`, `add_fp32_p4.sv`,
`weight_store.sv`, `fifo_sync.sv`, `skid_buffer.sv`,
`load_seq.sv`).
- **Reset convention flipped** (sync -> async, Phase 8) for sky130
reasons -- see "What's new versus M2" above.
- Bring-up is at `M = N = 4`. The 48 x 48 architecture-md target ran
through yosys (see `synth/yosys_48x48_run.log`) but was not pushed
through full OpenLane 2 P&R; the rationale and the cited gate-count
gap is in `synthesis_notes.md` per the spec's "documented scope
adjustment with synthesis attempt" clause.
- The 300 MHz spec is missed by ~1.13 ns of WNS at the M = N = 4
bring-up. The post-Phase-11 critical path is now the ingress FIFO
read mux, not arithmetic depth; see `synth/critical_path.md`.


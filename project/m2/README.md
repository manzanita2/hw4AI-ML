# Milestone 2 — RTL + Testbenches

This directory holds the M2 deliverables for the RAFT compute core: the
synthesizable HDL, the cocotb testbenches that prove it functionally
correct, the captured simulation log, and the waveform image.

## Layout

| Deliverable                                         | Path                                                                                                                                                                            |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Compute core HDL                                 | [`rtl/compute_core.sv`](rtl/compute_core.sv) (top), [`rtl/pe.sv`](rtl/pe.sv), [`rtl/mul_bf16.sv`](rtl/mul_bf16.sv), [`rtl/acc_fp32.sv`](rtl/acc_fp32.sv)                         |
| 2. Compute core testbench                           | [`tb/tb_compute_core.py`](tb/tb_compute_core.py) (smoke + GEMM), [`tb/tb_mul_bf16.py`](tb/tb_mul_bf16.py), [`tb/tb_acc_fp32.py`](tb/tb_acc_fp32.py)                              |
| 2 (sim log)                                         | [`sim/compute_core_run.log`](sim/compute_core_run.log)                                                                                                                          |
| 2 (waveform)                                        | [`sim/waveform.png`](sim/waveform.png) (manual gtkwave step, see [`sim/README.md`](sim/README.md))                                                                              |
| 3. Interface module HDL                             | [`rtl/interface.sv`](rtl/interface.sv) (AXI4-Lite CTRL/STATUS/SCRATCH regfile + AXI4-Stream pass-through to `compute_core`)                                                       |
| 4. Interface testbench                              | [`tb/tb_interface.py`](tb/tb_interface.py) (smoke + 6 AXI-Lite tests + 2 AXIS pass-through tests, 9 cases total)                                                                |
| 4 (sim log)                                         | [`sim/interface_run.log`](sim/interface_run.log)                                                                                                                                |
| 5. Precision and data format (OPTIONAL)             | [`precision.md`](precision.md) (48×48 `compute_core`; SEED=42, 1440-sample sweep → MAE 4.87e-2; log [`sim/quant_error.log`](sim/quant_error.log))                                                                       |
| 6. Reproducibility                                  | this file                                                                                                                                                                       |

## Toolchain

All testbenches are co-simulation harnesses written in
[cocotb](https://docs.cocotb.org/) and driven by Icarus Verilog. No
commercial simulator required. **Every** `make` / `make TEST=...` target
below uses this same stack (Icarus elaborates `TOPLEVEL` from
[`tb/Makefile`](tb/Makefile); cocotb drives the matching `tb_*.py`).

| Tool                | Version                                | How it's used                                                       |
| ------------------- | -------------------------------------- | ------------------------------------------------------------------- |
| Icarus Verilog      | 14.0 (devel)                           | RTL compile + simulation, `-g2012` for SystemVerilog dialect        |
| Python              | 3.11.9                                 | cocotb runtime                                                      |
| cocotb              | 2.0.1                                  | testbench framework (`cocotb-config`, `Makefile.sim`)               |
| gtkwave             | any 3.3 / 3.4                          | viewing `artifacts/compute_core.vcd`; only needed for the waveform PNG step |
| make                | GNU make                               | top-level driver in [`tb/Makefile`](tb/Makefile)                    |

The Python venv lives at the workspace root: `.venv-cocotb/`. The
`tb/Makefile` resolves it via
`VENV ?= $(abspath $(CURDIR)/../../../.venv-cocotb)`. The only Python
dependency is cocotb itself; everything else (the bf16 helper, the
GEMM reference, the VCD wrapper generation) is stdlib.

## Reproducing M2 simulation from a clean clone

```bash
git clone <repo-url> hw4AI-ML
cd hw4AI-ML

# one-time: create the cocotb venv (skip if .venv-cocotb already exists)
# Tested on Python 3.11.9; cocotb 2.0.1 supports 3.9+ — use `python3` if 3.11 unavailable.
python3.11 -m venv .venv-cocotb
.venv-cocotb/bin/pip install cocotb==2.0.1

# all simulation lives under project/m2/tb/
cd project/m2/tb
```

From `project/m2/tb/`:

The M2 PDF "both testbenches" means **compute_core** + **interface** (rows
below). **Primitive** TBs (`mul_bf16`, `acc_fp32`) and **optional**
`quant_error` are listed too so the full cocotb surface is one place.

```bash
# Primitive testbenches (FP units used by the systolic array).
make TEST=mul_bf16          # bf16 multiplier              -> PASS (15 edge cases)
make TEST=acc_fp32          # fp32 accumulator             -> PASS (8 edge cases)

# PDF "both testbenches" — sibling tops under ../rtl/
make                        # default TEST=compute_core: smoke + 4x4 GEMM tile  -> PASS (2 tests, 4 outputs bit-exact)
make TEST=interface         # AXI-Lite regfile + AXIS pass-through              -> PASS (9 tests)

# Optional deliverable #5 — 48x48 compute_core (Makefile -P overrides), 30 tiles,
# 1440 outputs, SEED=42. ~4 min wall (2304 PEs); same Icarus+cocotb stack.
make TEST=quant_error       # or: make m2-quant  (clean + copy ../sim/quant_error.log)

# Refresh BOTH ../sim/*_run.log deliverable logs from clean.
make m2-log
make m2-log-compute_core    # just ../sim/compute_core_run.log
make m2-log-interface       # just ../sim/interface_run.log

# Deliverable #5 log only (clean + quant_error). Long run — see TEST=quant_error above.
make m2-quant               # copies ../sim/quant_error.log; numbers in precision.md

# Clean.
make clean                  # removes sim_build/ AND artifacts/
```

### Quick smoke (deliverable #6 sanity)

```bash
cd project/m2/tb
make clean && make && make TEST=interface && make m2-log
# optional, slow: make m2-quant
```

Every `make` invocation builds afresh; nothing depends on a previous
run. The `*_run.log` deliverables are regenerated from clean by
`make m2-log` so the committed logs correspond to deterministic
re-runs, not whatever stale state happened to be in `sim_build/`.
`make m2-log` chains `m2-log-compute_core` + `m2-log-interface`; **each**
sub-target starts with its own `make clean` so switching `TOPLEVEL`
between `compute_core` and `interface_module` never leaves a stale
`dump_vcd.v` or `sim_build/` mismatch. Either sub-target is runnable alone.

### Deliverable #6 checklist (this README)

- **Run both PDF testbenches:** `make` (compute_core) and `make TEST=interface` — commands above; simulator **Icarus Verilog 14.0 (devel)** + **cocotb 2.0.1** in toolchain table.
- **Repro from clean clone:** venv + `pip install cocotb==2.0.1` + `cd project/m2/tb` block above; only Python dep is cocotb (stdlib test code).
- **M1 deviation:** none — see **Deviations from the M1 plan** section below.

### Waveform PNG

```bash
cd project/m2/tb
make                                              # produces artifacts/compute_core.vcd
gtkwave artifacts/compute_core.vcd compute_core.gtkw
# arrange + screenshot, then save to ../sim/waveform.png
```

Full procedure (annotation, time-window choice, PDF-to-PNG conversion
with ImageMagick if you want a non-screenshot path) is in
[`sim/README.md`](sim/README.md).

### Running just one testcase under cocotb

cocotb 2.0 honors `COCOTB_TESTCASE` for filtering:

```bash
make COCOTB_TESTCASE=compute_core_gemm    # skip the smoke test
make TEST=acc_fp32 COCOTB_TESTCASE=acc_fp32_reset
```

## Filename / extension note (deviation from PDF, not from M1)

The M2 PDF specifies [`tb/tb_compute_core.sv`](tb/tb_compute_core.sv) and
[`tb/tb_interface.sv`](tb/tb_interface.sv) (both `.sv`). These are
co-simulation harnesses written in cocotb instead, so the actual
filenames are `tb_compute_core.py`, `tb_mul_bf16.py`, `tb_acc_fp32.py`,
`tb_interface.py`, and (optional deliverable #5) `tb_quant_error.py`.
The M2 PDF's "How to submit" section
([documents/hw4ai_ece510_project_milestone_2_spring26_r1.pdf:22-23](../../documents/hw4ai_ece510_project_milestone_2_spring26_r1.pdf))
explicitly allows this:

> Note: Depending on the tools you are using and on your project specifics, your
> file extensions may be different. Please respect the repository structure as
> closely as you can.

The directory layout (`rtl/`, `tb/`, `sim/`, `precision.md` location) is
unchanged from the PDF's expected structure.

## Numerical precision -- pointer

The compute core uses bf16 multiplication, fp32 accumulation, and bf16
output (round-toward-zero / truncation). Rationale and v1 limitations
are documented in
[`rtl/compute_core.sv`](rtl/compute_core.sv) (header) and
[`rtl/mul_bf16.sv`](rtl/mul_bf16.sv) / [`rtl/acc_fp32.sv`](rtl/acc_fp32.sv)
(per-module "v1 limitations" sections). The OPTIONAL deliverable #5
quantization-error analysis lives in [`precision.md`](precision.md). It cites
[`sim/quant_error.log`](sim/quant_error.log), regenerated by **`make
m2-quant`**, where **`compute_core`** is elaborated at **M=N=LANES=48**
(see **`tb/Makefile`** compile args). Thirty tiles ⇒ **1440** outputs;
reported MAE **4.87e-2** vs fp32 `struct`-quant reference, gated **below
0.10**.

## Deviations from the M1 plan

None as of this commit. The kernel target (`aten::mkldnn_convolution`),
interface protocol (AXI4-Stream + AXI4-Lite), array shape (**48 × 48** at
300 MHz target), and numerical format (bf16 multiply, fp32 accumulate, bf16
output) align with **[`../m1/`](../m1/)** and
[`../architecture.md`](../architecture.md). **`make`** (default) and the
GEMM deliverable **`tb_compute_core.py`** keep **M=N=K=4** for fast RTL
bring-up; **parameter overrides** enlarge the DUT (**e.g.** `TEST=quant_error`).

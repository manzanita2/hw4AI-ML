# Hardware for AI and ML — RAFT optical-flow accelerator

**Author:** Elliott Day  
**Course:** ECE 510 — Hardware for AI and Machine Learning (HW4AI), Spring 2026

## Goal

A SystemVerilog accelerator path for **[RAFT](https://arxiv.org/abs/2003.12039)**,
the optical-flow model that dominates the front end of real-time SLAM pipelines
for robotics and AR/VR. CPU profiling identified **`aten::mkldnn_convolution`**
as the hot kernel (**~53%** of inference time on our PyTorch run);
this project maps that work to a systolic GEMM; profiling artifacts live under `codefest/cf02/`.
The Heilmeier narrative is in [`project/heilmeier.md`](project/heilmeier.md); locked sizing and
interfaces are in [`project/architecture.md`](project/architecture.md).

## Implementation

The headline fabric is a **48 × 48 weight-stationary systolic array** of
**bfloat16** multipliers with **fp32** accumulators, **bf16** on output (rounding policy in M2 RTL).
Convolution maps to GEMM via **im2col**, then streams through the mesh. **300 MHz**, **single clock domain**,
sized against M1’s **1.024 TFLOP/s** roofline.

**Data plane:** **AXI4-Stream**, **256 b** @ 300 MHz (~**7.1 GB/s** ingress per M1).
**Control:** **AXI4-Lite** slave. M2 RTL: **`project/m2/rtl/`** (`interface.sv`, `compute_core.sv`, primitives).
Default cocotb uses **4×4** `compute_core`; **`make TEST=quant_error`** runs the **48×48** quant sweep
([`project/m2/README.md`](project/m2/README.md)). Older MAC work: **`codefest/`** (e.g. `cf04/`).

## Where things live

| Topic | Path |
| ----- | ---- |
| M2 RTL, TBs, logs, precision | [`project/m2/`](project/m2/) — **[`project/m2/README.md`](project/m2/README.md)** (clone, venv, every `make` target) |
| M1 + profiling inputs | [`project/m1/`](project/m1/), [`codefest/cf02/`](codefest/cf02/) |

**Read next**

- **[`project/m2/README.md`](project/m2/README.md)** — repro, `make` targets, committed `*_rtl.log` refresh  
- **[`project/architecture.md`](project/architecture.md)** — mesh geometry, AXIS/AXIL, roofline inputs

**Quick start:** `cd project/m2/tb && make` — toolchain versions in the M2 README.
**`make m2-log`** / **`make m2-quant`** refresh committed logs.

This file is the **map + elevator pitch**; stale-prone detail stays in **`project/m2/README.md`**.

# Hardware for AI and ML — RAFT optical-flow accelerator

**Author:** Elliott Day  
**Course:** ECE 510 — Hardware for AI and Machine Learning (HW4AI), Spring 2026

## → M4 final submission

**The graded M4 package lives in [`project/m4/`](project/m4/) — start at
[`project/m4/README.md`](project/m4/README.md).** It catalogs the final
RTL, testbench, simulation outputs, and synthesis/PnR results, and is the
basis for the final examination. The design justification report will be
at [`project/m4/report/`](project/m4/report/).

## Goal

A SystemVerilog accelerator path for **[RAFT](https://arxiv.org/abs/2003.12039)**,
the optical-flow model that dominates the front end of real-time SLAM pipelines
for robotics and AR/VR. CPU profiling identified **`aten::mkldnn_convolution`**
as the hot kernel (**~53%** of inference time on our PyTorch run);
this project maps that work to a systolic GEMM; profiling artifacts live under `codefest/cf02/`.
The Heilmeier narrative is in [`project/heilmeier.md`](project/heilmeier.md).

## Implementation (as built and synthesized for M4)

A **16 × 16 weight-stationary systolic array** (256 PEs) of **bfloat16**
multipliers with **fp32** accumulators, rounding to **bf16** on output.
Convolution maps to GEMM via **im2col**, then streams through the mesh.
**100 MHz, single clock domain**; the MAC pipeline is `MAC_LATENCY = 5`
(`mul_bf16_p2` + `add_fp32_p2`). Synthesized on sky130 via OpenLane 2;
the run reached detailed routing and setup closes at 100 MHz.

> The original **48 × 48 @ 300 MHz / 1.024 TFLOP/s** target in
> [`project/architecture.md`](project/architecture.md) is the *aspiration*;
> the implemented and synthesized scope is the 16 × 16 @ 100 MHz design
> above. See [`project/m4/README.md`](project/m4/README.md) for the
> authoritative design point.

**Data plane:** **AXI4-Stream**, **256 b** (16 bf16 lanes/beat).
**Control:** **AXI4-Lite** slave.

## Where things live

| Topic | Path |
| ----- | ---- |
| **M4 final package** | **[`project/m4/`](project/m4/)** — **[`project/m4/README.md`](project/m4/README.md)** |
| M3 integration, co-sim, synthesis iteration ledger | [`project/m3/`](project/m3/) — [`project/m3/README.md`](project/m3/README.md), [`project/m3/synthesis_notes.md`](project/m3/synthesis_notes.md) |
| M2 RTL, TBs, logs, precision | [`project/m2/`](project/m2/) — [`project/m2/README.md`](project/m2/README.md) |
| M1 + profiling inputs | [`project/m1/`](project/m1/), [`codefest/cf02/`](codefest/cf02/) |

**Quick start (M4 co-sim):** `cd project/m4/tb && make m3-log` — expect
6 PASS + 1 SKIP. Toolchain versions are in the M3 README.

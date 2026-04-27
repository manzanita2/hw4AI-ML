# Hardware for AI and ML — RAFT Optical-Flow Accelerator

**Author:** Elliott Day
**Course:** ECE 510 — Hardware for AI and Machine Learning, Spring 2026

## Goal

A SystemVerilog compute core targeting [RAFT](https://arxiv.org/abs/2003.12039),
the optical-flow model that dominates the front-end of real-time SLAM
pipelines for robotics and AR/VR. CPU profiling identified
`aten::mkldnn_convolution` as the hot kernel (~53 % of inference time);
this project accelerates it. The full Heilmeier write-up lives in
[`project/heilmeier.md`](project/heilmeier.md), and the architectural
decisions driving the RTL are in [`project/architecture.md`](project/architecture.md).

## Implementation

The core is a **48 × 48 weight-stationary systolic array** of bfloat16
multipliers with fp32 accumulators, rounding to bf16 on output.
Convolution is mapped to GEMM via im2col, then streamed through the
array. The target clock is **300 MHz, single domain**, sized against
M1's 1.024 TFLOP/s roofline target.

Data plane is **AXI4-Stream**, 256 b @ 300 MHz (~7.1 GB/s ingress, per
M1's bandwidth budget). Control and status sit behind an **AXI4-Lite**
slave. RTL lives in `project/hdl/`; reference / experimental MAC
modules and supporting cocotb harnesses live under `codefest/cf04/`.

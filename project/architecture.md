# Compute Core — Architecture Plan v0

First-stab planning doc for the top-level compute core HDL. Goal: pin
down enough decisions to start writing the top module port list and
internal block diagram. Deliberately leaves implementation details
(PE internals, RTL pipelining, SRAM micro-architecture) for later.

## Fixed context (from M1)

| Parameter | Value | Source |
|---|---|---|
| Target throughput | 1.024 TFLOP/s | `m1/interface_selection.md` |
| Host interface | AXI4-Stream, 256 b @ 300 MHz | `m1/interface_selection.md` |
| Required ingress BW | 7.11 GB/s | `m1/interface_selection.md` |
| Kernel | `aten::mkldnn_convolution` (~53 % CPU) | `cf02/profiling/torch_results.txt` |
| Arithmetic intensity | 144 FLOP/byte | `cf02/analysis/ai_calculation.md` |
| Platform | Embedded FPGA SoC | `cf02/analysis/partition_rationale.md` |

## Locked-in decisions (this iteration)

1. **Datapath numerics:** FP16. Specific format (IEEE half vs. bfloat16) is pending — see *FP16 format* below.
2. **Compute fabric:** 2-D systolic array of MAC PEs (TPU-style).
3. **Operation mapped:** convolution via im2col → GEMM. See *Convolution mapping* below for whether to revisit.
4. **Interface:** AXI4-Stream from M1, both ingress and egress.

## Top-level block sketch

```
                AXI4-Stream (256 b @ 300 MHz)
                          |
          +---------------v---------------+
          |  ingress FIFO + im2col stage  |
          +---------------+---------------+
                          |
          +---------------v---------------+
          |   on-chip SRAM (act + wt)     |   <-- size pending
          +---+---------------+-----------+
              |               |
        weight feed     activation feed
              |               |
          +---v---------------v---+
          |  M x N systolic array  |   <-- M, N pending
          |  PE = FP16 MAC + accum |
          +-----------+-----------+
                      |
          +-----------v-----------+
          |  bias / activation /  |   <-- presence pending
          |  output requantize    |
          +-----------+-----------+
                      |
          +-----------v-----------+
          | egress FIFO + AXIS    |
          +-----------------------+
```

Top module port list will be a thin shell wrapping this — clk, rst,
AXI4-Stream master/slave bundles, optional config/status registers.

## Sizing back-of-envelope

```
1.024 TFLOP/s @ 300 MHz = 3413 FLOP/cycle = 1707 MAC/cycle
```

That's the steady-state MAC count the array must sustain. Candidate
dimensions (each MAC counts as 2 FLOPs):

| Array | MAC/cyc | FLOP/cyc | FLOP/s @ 300 MHz | Headroom |
|---|---|---|---|---|
| 32 × 32 | 1024 | 2048 | 0.61 TFLOP/s | **under** target |
| 32 × 64 | 2048 | 4096 | 1.23 TFLOP/s | 1.20 × |
| 48 × 48 | 2304 | 4608 | 1.38 TFLOP/s | 1.35 × |
| 64 × 64 | 4096 | 8192 | 2.46 TFLOP/s | 2.40 × (likely over-provisioned) |

Smallest array hitting target at 300 MHz is in the 32 × 64 / 48 × 48
neighborhood. Bumping clock to 500 MHz lets a 32 × 32 hit the target.
This is a key knob coupled to *Array dimensions* and *Clock target* below.

---

## Design decisions still pending

The following items each need a call before HDL writing starts. Each
entry lists the choice space, the relevant tradeoff, a current default
direction, and (where applicable) what input is needed to firm it up.

### FP16 format

- **Choice space:** IEEE 754 half (1 + 5 + 10) vs. bfloat16 (1 + 8 + 7).
- **Tradeoff:** bf16 keeps fp32's dynamic range and converts cheaply
  to/from fp32; IEEE half has more mantissa precision but a narrower
  exponent range (~±65504). RAFT was trained in fp32, so bf16 is the
  safer first cut; IEEE half is viable if activation magnitudes fit.
- **Current direction:** bfloat16, pending activation-magnitude profile.
- **Needs:** one RAFT forward pass with activation-range logging.

CHOICE: bfloat16

### Array dimensions (M × N)

- **Choice space:** M, N in PEs. Sizing table above gives candidates.
- **Tradeoff:** Bigger array = more parallelism but more area and more
  wasted PEs on conv layers whose channel counts don't divide cleanly.
- **Current direction:** Provisionally **32 × 32**, with a clock bump
  to 500 MHz reserved as a fallback to hit 1.024 TFLOP/s.
- **Needs:** Cin/Cout distribution across RAFT conv layers (pull from
  `algorithms/pytorch-RAFT/`) so we pick a size that divides cleanly.

CHOICE: 48 x 48. I don't care about being that efficient

### Dataflow

- **Choice space:** Weight-stationary / output-stationary / input-stationary.
- **Tradeoff:** Weight-stationary is the standard for inference (TPU v1,
  Eyeriss-V) — weights pinned in PE, activations stream. Output-stationary
  pins partial sums and streams both inputs. Input-stationary is rare for
  convolution and not recommended.
- **Current direction:** **Weight-stationary**.
- **Needs:** none; revisit only if first-pass utilization is poor.

CHOICE: weight-sationary

### Accumulator precision

- **Choice space:** FP16 throughout vs. FP16 multiply with FP32 accumulate
  (and FP16 round on output).
- **Tradeoff:** FP16 accumulation drifts after tens of partial sums. FP32
  accumulate is the industry default and costs roughly 2 × the partial-sum
  register bits per PE.
- **Current direction:** **FP16 multiply, FP32 accumulate, FP16 output.**
  No realistic alternative for conv layers with > ~64 reductions.
- **Needs:** none.

CHOICE: yes FP16 with FP32 accumulate with FP16 round on output

### Convolution mapping

- **Choice space:** im2col → GEMM, or direct convolution mapping.
- **Tradeoff:** im2col is what every modern systolic array does because
  the array natively runs GEMMs. Cost: ~9 × activation memory blow-up
  for 3 × 3, plus an im2col staging block on ingress. Direct conv reuses
  activations across PE rows but needs more complex sliding-window control.
- **Current direction:** **im2col + GEMM**.
- **Needs:** none unless ingress bandwidth becomes the bottleneck.

CHOICE: im2col + GEMM

### Clock target

- **Choice space:** Single 300 MHz domain (matching M1 AXIS), or split
  domains (e.g. 300 MHz interface / faster core).
- **Tradeoff:** Single domain is much simpler RTL and verification;
  multi-domain unlocks higher MAC throughput on a smaller array but adds
  CDC FIFOs.
- **Current direction:** **300 MHz, single domain** for v0; revisit only
  if synthesis shows the core has timing slack.
- **Needs:** post-synthesis timing report (after first pass).

CHOICE: 300MHZ, single domain

### On-chip SRAM budget

- **Choice space:** Total SRAM on-chip, split across activation / weight /
  output buffers, single- or double-buffered.
- **Estimate:** 32 × 32 fp16 array with K = 64 tile depth, double-buffered
  — roughly **64 KB minimum** total.
- **Current direction:** Defer firm number until target part is chosen.
- **Needs:** target FPGA part's on-chip SRAM ceiling.

CHOICE: will never be physically implemented, it is not bounded by hardware. defer.

### Synthesis target

- **Choice space:** Specific FPGA part (Xilinx ZCU102 / Versal AI / Intel
  Agilex / etc.) or an OpenLane + SkyWater ASIC flow.
- **Why it matters:** DSP block availability. FP16 multipliers map onto
  DSP58 (Versal) or DSP48E2 (UltraScale+) with vendor-specific tricks.
  Without DSPs, multipliers are pure LUT and area balloons.
- **Current direction:** **Pending the M2/M3 deliverable target.**
- **Needs:** course/project requirement for synthesis target.

CHOICE: will not be physicially implemented

### Post-MAC stages (bias / activation / requantize)

- **Choice space:** Include bias add, ReLU/leaky-ReLU, and any
  requantization downstream of the array; or push them to a separate
  block.
- **Tradeoff:** Including them keeps the conv-layer pipeline
  self-contained. Excluding them keeps this core a "pure GEMM engine"
  and lets a sister block (or the host) handle nonlinearities.
- **Current direction:** **Include bias add + ReLU** in the core.
  Requantize TBD; revisit if INT quantization comes back into scope.
- **Needs:** none.

CHOICE: defer

### Control plane

- **Choice space:** AXI4-Lite config registers, or in-band control via
  AXIS packet headers.
- **Tradeoff:** AXI4-Lite cleanly decouples control from data and is
  conventional. In-band control simplifies the interface but couples
  control timing to data flow.
- **Current direction:** **AXI4-Lite** for config + status. (M1 spec'd
  AXIS for the data plane only.)
- **Needs:** none.

CHOICE: AXI4-Lite for now

---

## Suggested next steps

These don't block the decisions above, but unblock the next iteration.

1. Profile RAFT conv layer shapes (Cin, Cout, kernel, stride, padding)
   from `algorithms/pytorch-RAFT/` to firm up array dimensions.
2. Sketch PE internals as a separate doc (multiplier, accumulator,
   shift-out path, pipeline depth).
3. Prototype a small 4 × 4 array first to prove out dataflow and PE
   timing; expand to full M × N afterward.

---

## Status

- Author: Elliott Day
- Iteration: v0 (planning, no RTL yet)
- Last update: see git log

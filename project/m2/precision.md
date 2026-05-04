# Precision and Data Format

This satisfies M2 deliverable #5: explicit format declaration, kernel and
roofline rationale, quantized error sweep versus fp32 (at least 100
samples), and an acceptability statement.

## Numerical format

Datapath is **bf16 multiply, fp32 accumulate, bf16 output**. Products of
two normal bf16 values are exact in fp32 mantissa (`mul_bf16` header).
The accumulator operates in IEEE-754 single precision; v1 rounds adds
toward zero and bf16-drains via truncation (`acc_fp32` v1-limitations +
`fp32_to_bf16`). Subnormal inputs flush to signed zero (`mul_bf16`,
`acc_fp32` headers).

## Rationale

Convolution (`aten::mkldnn_convolution`, ~53 percent of inference CPU in
[`codefest/cf02/profiling/torch_results.txt`](../../codefest/cf02/profiling/torch_results.txt))
uses long inner products; bf16 retains fp32 dynamic range versus IEEE half,
while fp32 accumulation avoids fp16 creep over tens of reductions.

Arithmetic intensity about **144 FLOP/byte** at fp32 I/O on a representative
layer ([`codefest/cf02/analysis/ai_calculation.md`](../../codefest/cf02/analysis/ai_calculation.md)).
bf16 halves bytes moved per FLOP, pushing toward ~**288 FLOP/byte** and
matching the systolic throughput target versus the **7.11 GB/s** AXIS ingress
budget from M1 (`project/architecture.md`, root `README.md`).

## Sweep methodology

Code: [`tb/tb_quant_error.py`](tb/tb_quant_error.py). Logged run:
[`sim/quant_error.log`](sim/quant_error.log). `make m2-quant` elaborates
`compute_core` with **M=N=LANES=48** (`tb/Makefile -P overrides`), i.e.
the headline **48x48** array (2304 MAC sites). **`LANES=48`** is required so
one COMPUTE-cycle-0 beat carries all **`M`** activations on `act_data`.

Each tile computes **y[n] = sum_k x[k]*B[k,n]** for **k,n in 0..47**.
Independent draws **N(0,1)** are fp32-quantized before use. Reference uses
`struct.pack('<f'); unpack(...)` round-trips after every multiply/add so it
tracks fp32—not Python fp64.

**SEED=42**, **30 tiles** ⇒ **1440** bf16 outputs (four times the rubric
minimum of 100).

## Results

| Metric | Value |
| ------ | ----- |
| MAE | **4.87e-02** |
| RMSE | 6.28e-02 |
| max abs err | 2.70e-01 |
| pct with abs err `<` 1e-2 | 13.6 % |

Dominant histogram bin is **[1e-2, 1e-1)** absolute error—the expected
scaling when reduction depth jumps from prototype **K=4** to production
shape **K=48**. Typical **|y|** grows roughly as **sqrt(K)** under i.i.d.
Gaussian inputs, so dimensionless **MAE/sqrt(Var(y))** stays small.

## Acceptability

RAFT publishes **KITTI/Sintel end-point-error** on the **sub-pixel**
to **few-pixel** scale ([arxiv.org/abs/2003.12039](https://arxiv.org/abs/2003.12039), Table 1). Feature noise dominated by arithmetic at
mean absolute delta **under 5e-2**, with bf16-relative error at percent
levels on nonzero outputs, is tiny compared to iterative refinement and
motion magnitude in the benchmarks.

Declare **engineering pass** when **MAE `<` 1e-1** versus the Gaussian
stress stimulus; simulation reports **MAE = 4.87e-02 (~2×
margin)**. Spike **relative** metrics appear when fp32 refs sit near zero;
trust **MAE and max-abs** tails for assertions.

**Future work:** switch RTZ accumulation / drain to round-to-nearest-even to
remove one-sided bias on long dot products; widen `act_data` coupling to
**`LANES`** only if a future top keeps 256-bit ingress while **M>16**—the
48×48 headline needs the parallel activation beat.

**Simulator note:** thirty 48×48 tiles take **~4 minutes** wall time on
Icarus 14 + cocotb 2.0—2304 instantiated PE MACs enlarge event load. Faster
checks still use **`make`** (default 4×4 `compute_core`). Re-run **`make
m2-quant`** after any change to `mul_bf16` / `acc_fp32` rounding to refresh
[`sim/quant_error.log`](sim/quant_error.log) and this table.

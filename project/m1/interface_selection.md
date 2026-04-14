# Interface Selection

## 1) Chosen interface

- **Selected interface:** **AXI4-Stream**
- **Why this interface:** The dominant kernel is convolution (`aten::mkldnn_convolution`, 53.02% self CPU in `codefest/cf02/profiling/torch_results.txt`), and the design goal in `codefest/cf02/analysis/partition_rationale.md` is high-throughput streaming of tensor data to/from an accelerator. AXI4-Stream is intended for this bulk data path.

## 2) Required bandwidth at target operating point

From prior calculations:
- Target throughput: **1.024 TFLOP/s** (base-clock target used in `partition_rationale.md`)
- Kernel arithmetic intensity: **AI = 144 FLOP/byte** (`codefest/cf02/analysis/ai_calculation.md`)

Using the requested form:

$$
\text{Required bandwidth} = \text{throughput} \times \text{data width per FLOP}
$$

For this kernel:

$$
\text{data width per FLOP} = \frac{1}{AI} = \frac{1}{144}\ \text{byte/FLOP}
$$

So:

$$
\text{BW}_{req} = 1.024\times10^{12}\ \text{FLOP/s} \times \frac{1}{144}\ \text{byte/FLOP}
= 7.11\times10^9\ \text{byte/s}
= \mathbf{7.11\ GB/s}
$$

## 3) Interface rated bandwidth vs required bandwidth

Assumed AXI4-Stream operating point for the accelerator link:
- Stream width: **256 bits** (= 32 bytes/beat)
- Clock: **300 MHz**

Rated bandwidth:

$$
\text{BW}_{AXIS} = f \times W = 300\times10^6\ \text{beat/s} \times 32\ \text{byte/beat} = \mathbf{9.6\ GB/s}
$$

Comparison:

$$
\text{Headroom ratio} = \frac{9.6}{7.11} \approx 1.35\times
$$

- Since 9.6 GB/s > 7.11 GB/s, this interface choice is **not interface-bound** at the 1.024 TFLOP/s target.
- Equivalent interface-limited compute ceiling at this AI:

$$
P_{max,interface} = 9.6\ \text{GB/s} \times 144\ \text{FLOP/byte} = 1.382\ \text{TFLOP/s}
$$

So the interface ceiling is above the target compute point.

## 4) Assumed host platform

- **Host platform assumption:** **Embedded FPGA SoC / single-board computer class system** (as stated in `codefest/cf02/analysis/partition_rationale.md`).
- The host runs software control and non-accelerated logic; the AXI4-Stream path feeds the accelerator data plane.

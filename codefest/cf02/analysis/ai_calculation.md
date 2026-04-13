# Arithmetic Intensity (AI) Calculation for Dominant Kernel

## 1) Identify dominant kernel from profiler

From `codefest/cf02/profiling/torch_results.txt`, the dominant kernel is:

- `aten::mkldnn_convolution` with `Self CPU % = 53.02%`

This indicates convolution is the dominant operation in runtime.

## 2) Choose a representative convolution layer for analytical FLOP counting

Using `codefest/cf02/profiling/torchinfo_results.txt`, select a concrete conv layer instance:

- `Conv2d: 5-1`
- Input shape: `[4, 64, 260, 480]`
- Output shape: `[4, 64, 260, 480]`
- Parameters: `36,928`
- Mult-Adds: `18,434,457,600`

Because `mkldnn_convolution` executes conv layers, this layer is a representative dominant-kernel instance.

## 3) FLOPs (analytical derivation with formula and substituted values)

For convolution, each multiply-add (MAC) has:

- 1 multiplication
- 1 addition

So:

- `FLOPs = 2 * MACs`

Given torchinfo `Mult-Adds = 18,434,457,600`:

- `FLOPs = 2 * 18,434,457,600`
- `FLOPs = 36,868,915,200`

## 4) Bytes transferred (DRAM, no reuse assumption)

Prompt assumption: all operands are loaded from DRAM with no reuse.

We count:

- input activations read
- weights read
- output activations written

### 4.1) Element counts

Input elements:

- `N * C_in * H * W = 4 * 64 * 260 * 480 = 31,948,800`

Output elements:

- `N * C_out * H_out * W_out = 4 * 64 * 260 * 480 = 31,948,800`

Weight elements (from parameters):

- `36,928`

Total elements moved:

- `31,948,800 + 31,948,800 + 36,928 = 63,934,528`

### 4.2) Convert elements to bytes

Data type is FP32, so:

- `4 bytes / element`

Total bytes:

- `63,934,528 * 4 = 255,738,112 bytes`

## 5) Arithmetic intensity

Definition:

- `AI = FLOPs / Bytes`

Substitute:

- `AI = 36,868,915,200 / 255,738,112`
- `AI = 144.17 FLOP/byte` (rounded to 2 decimals)o

Equivalent MAC-based form:

- `18,434,457,600 / 255,738,112 = 72.09 MAC/byte`

## 6) Final result

For the representative dominant convolution kernel instance (`Conv2d: 5-1` corresponding to `aten::mkldnn_convolution`):

- **Arithmetic Intensity = 144.17 FLOP/byte**






CPU research stuff for #7

my cpu is an AMD Ryzen 9 7940HS.
according to https://www.cpu-monkey.com/en/cpu-amd_ryzen_9_7940hs
the maximum memory throughput is 89.5GB/s at ddr5-5600

## Peak FLOP/s Research (Ryzen 9 7940HS)

There is no single official AMD "FLOP/s" value published for this CPU, so I used vendor specs plus a standard theoretical-throughput calculation.

### Source-backed inputs

- AMD official product page lists:
  - 8 CPU cores
  - max boost clock up to 5.2 GHz
  - base clock 4.0 GHz
  - AVX/AVX2/AVX512/FMA3 support
  - Source: https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-9-7940hs.html

- Zen 4 execution description (AVX-512 behavior):
  - 512-bit vectors are executed using internal 256-bit units
  - max throughput up to two 512-bit vector instructions per cycle (e.g., one multiply and one add)
  - Source: https://en.wikipedia.org/wiki/Zen_4

- FLOP counting convention used:
  - multiply + add is counted as two floating-point operations

### Theoretical peak FP32

Assume one vector multiply + one vector add per cycle per core.

- FP32 lanes per 512-bit vector = 512 / 32 = 16
- FLOPs per cycle per core = 16 (mul) + 16 (add) = 32

Formula:

- peak FP32 FLOP/s = cores x clock x FLOPs/cycle/core

At boost clock:

- 8 x 5.2e9 x 32 = 1.3312e12 FLOP/s ~ 1.33 TFLOP/s

At base clock:

- 8 x 4.0e9 x 32 = 1.024e12 FLOP/s ~ 1.02 TFLOP/s


These are theoretical upper bounds. Real sustained FLOP/s is usually lower because of memory bandwidth, cache behavior, instruction mix, and power/thermal limits.

assuming base clock from here on so perfromance peak is 1.02 TFLOPs




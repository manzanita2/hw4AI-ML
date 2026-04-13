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
- `AI = 144.17 FLOP/byte` (rounded to 2 decimals)

Equivalent MAC-based form:

- `18,434,457,600 / 255,738,112 = 72.09 MAC/byte`

## 6) Final result

For the representative dominant convolution kernel instance (`Conv2d: 5-1` corresponding to `aten::mkldnn_convolution`):

- **Arithmetic Intensity = 144.17 FLOP/byte**


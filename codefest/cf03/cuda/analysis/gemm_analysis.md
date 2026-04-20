# GEMM Performance Report (ROCm run, updated)

***I used ROCm instead of CUDA because my laptop has an AMD gpu!***

Matrix size: `N = 1024`  
Tiled kernel configuration: `TILE = 8`  
Operation count per kernel: `FLOPs = 2 * N^3 = 2,147,483,648`

Timing source:
- `gemm_naive_rocprofv3_kernel_stats.csv` -> `TotalDurationNs = 2,464,411`
- `gemm_tiled_rocprofv3_kernel_stats.csv` -> `TotalDurationNs = 2,300,907`

Formulas used:
- `execution_time_ms = TotalDurationNs / 1e6`
- `compute_throughput_GFLOP/s = (2 * N^3) / TotalDurationNs`
- `naive_bytes = (2 * N^3 + N^2) * 4`
- `tiled_bytes = (2 * N^3 / TILE + N^2) * 4` (ideal tile reuse model)
- `effective_bandwidth_GB/s = bytes / time_seconds / 1e9`

Results:
- **Naive kernel**
  - Execution time: **2.464411 ms**
  - Compute throughput: **871.398 GFLOP/s**
  - Effective memory bandwidth (model-derived): **3487.295 GB/s**
  - Arithmetic intensity (model): **0.2499 FLOP/byte**

- **Tiled kernel (TILE=8)**
  - Execution time: **2.300907 ms**
  - Compute throughput: **933.320 GFLOP/s**
  - Effective memory bandwidth (model-derived): **468.483 GB/s**
  - Arithmetic intensity (model): **1.9922 FLOP/byte**

Notes:
- Effective bandwidth above physical DRAM peak indicates the simple traffic model does not match all on-chip/cache behavior.
- Throughput and bandwidth values here come from kernel time plus analytic byte model, not direct hardware counter bytes.

## Answers to questions

A)
The naive kernel is memory bound because there are N accesses to each element resulting in many memory fetches. I expected this to have a bigger impact but I think there is caching that largely nullifies this slow-down.

B)
Tiling reduces DRAM traffic by using each element everywhere it's needed before discarding it. This leverages the additive property of GEMMs to reduce DRAM traffic and increase AI.

C)
Implementing tiling has increased the AI of the kernel from 0.25 to ~2. this is a large improvement but not close to what was calculated in CMAN which is improvement = tile size. The other confusing thing is that both kernels perform better than the memory bandwidth of the GPU should allow. both of these point to hardware optimization such as caching that the model doesn't account for.
Despite this tiling still improves the performance of the model by around 5%. this is less than anticipated but is explained by DRAM caching.
The L3 cache of my GPU is 32MB which is well above the $3*(1024)^2*4=12$MB bytes that are relevant to this kernel. so it could likely execute the entire thing in cache, however not all in the same layer of cache so tiling still provides an improvement. but instead of DRAM to L1 it's like L2 to L1.
The remaining bottleneck is compute.
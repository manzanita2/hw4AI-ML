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

### Theoretical peak FP64

- FP64 lanes per 512-bit vector = 512 / 64 = 8
- FLOPs per cycle per core = 8 (mul) + 8 (add) = 16

At boost clock:

- 8 x 5.2e9 x 16 = 6.656e11 FLOP/s ~ 0.666 TFLOP/s

At base clock:

- 8 x 4.0e9 x 16 = 5.12e11 FLOP/s ~ 0.512 TFLOP/s

### Practical note for partition rationale

These are theoretical upper bounds. Real sustained FLOP/s is usually lower because of memory bandwidth, cache behavior, instruction mix, and power/thermal limits.

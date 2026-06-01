"""CF09 Task 6: re-run M1 software baseline on same hardware (Ryzen 9 7940HS, CPU).

Mirrors project/m1/bench_raft_10_runs.py: raft_large forward, batch [2,3,520,960]
after Raft_Large_Weights.DEFAULT.transforms(), synthetic frames (no video decode).

Adds per-forward wall timing (time.perf_counter) so we get median exec time directly,
without depending on line_profiler/TorchCodec. Run under GNU time for peak RSS:

    /usr/bin/time -v python codefest/cf09/benchmarks/bench_sw_baseline.py
"""
from __future__ import annotations

import statistics
import time

import torch
import torchvision.transforms.functional as F
from torchvision.models.optical_flow import Raft_Large_Weights, raft_large

torch.manual_seed(0)
DEVICE = "cpu"  # M1 baseline was CPU; force CPU regardless of ROCm/CUDA availability

img1_batch = torch.rand(2, 3, 520, 960)
img2_batch = torch.rand(2, 3, 520, 960)

weights = Raft_Large_Weights.DEFAULT
transforms = weights.transforms()


def preprocess(i1: torch.Tensor, i2: torch.Tensor):
    i1 = F.resize(i1, size=[520, 960], antialias=False)
    i2 = F.resize(i2, size=[520, 960], antialias=False)
    return transforms(i1, i2)


img1_batch, img2_batch = preprocess(img1_batch, img2_batch)

model = raft_large(weights=Raft_Large_Weights.DEFAULT, progress=False).to(DEVICE)
model.eval()

x1 = img1_batch.to(DEVICE)
x2 = img2_batch.to(DEVICE)

N = 10
WARMUP = 1
times_s: list[float] = []
with torch.no_grad():
    for i in range(N + WARMUP):
        t0 = time.perf_counter()
        _ = model(x1, x2)
        dt = time.perf_counter() - t0
        if i >= WARMUP:
            times_s.append(dt)
            print(f"forward {i - WARMUP}: {dt * 1e3:.1f} ms")

median_s = statistics.median(times_s)
mean_s = statistics.mean(times_s)

# FLOP model from project/m1/sw_baseline.md: 788.14 GMACs/forward, 2 FLOP/MAC
MACS = 788.14e9
flops = 2 * MACS
print("---")
print(f"device: {DEVICE}, torch: {torch.__version__}")
print(f"runs: {N} (median over), batch [2,3,520,960]")
print(f"median time: {median_s * 1e3:.1f} ms  ({median_s:.4f} s)")
print(f"mean time:   {mean_s * 1e3:.1f} ms  ({mean_s:.4f} s)")
print(f"FLOPs/forward: {flops:.3e}")
print(f"throughput (median): {flops / median_s / 1e9:.1f} GFLOP/s")
print(f"throughput (samples/s, N=2 pairs): {2 / median_s:.3f} pairs/s")

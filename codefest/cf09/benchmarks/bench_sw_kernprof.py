"""CF09: replicate the ORIGINAL M1 timing method (line_profiler on the model() line).

Original baseline (project/m1/sw_baseline.md) timed only the
`list_of_flows = model(img1_batch, img2_batch)` line with kernprof/line_profiler:
10 hits, total 41,451,320.6 us => 4.145 s/forward, ~380 GFLOP/s.

This mirrors that: @profile-decorated main() calls model() 10 times, so line_profiler
reports 10 hits on the model() line. Synthetic frames (no TorchCodec) keep shapes identical.

Run:
    .venv/bin/kernprof -l -v codefest/cf09/benchmarks/bench_sw_kernprof.py
"""
from __future__ import annotations

import torch
import torchvision.transforms.functional as F
from torchvision.models.optical_flow import Raft_Large_Weights, raft_large

torch.manual_seed(0)
DEVICE = "cpu"

weights = Raft_Large_Weights.DEFAULT
transforms = weights.transforms()


def preprocess(i1: torch.Tensor, i2: torch.Tensor):
    i1 = F.resize(i1, size=[520, 960], antialias=False)
    i2 = F.resize(i2, size=[520, 960], antialias=False)
    return transforms(i1, i2)


@profile  # noqa: F821  (injected by kernprof/line_profiler at runtime)
def main():
    img1_batch = torch.rand(2, 3, 520, 960)
    img2_batch = torch.rand(2, 3, 520, 960)
    img1_batch, img2_batch = preprocess(img1_batch, img2_batch)

    model = raft_large(weights=Raft_Large_Weights.DEFAULT, progress=False).to(DEVICE)
    model.eval()

    x1 = img1_batch.to(DEVICE)
    x2 = img2_batch.to(DEVICE)

    with torch.no_grad():
        for _ in range(10):
            list_of_flows = model(x1, x2)
    return list_of_flows


if __name__ == "__main__":
    main()

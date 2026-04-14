"""
Minimal harness: RAFT baseline inputs [2,3,520,960] after preprocess, 10x raft_large forward.

Synthetic frames (random [0,1]) avoid TorchCodec/FFmpeg; same tensor shapes and
`Raft_Large_Weights.DEFAULT.transforms()` as `plot_optical_flow.py`.

Used with: /usr/bin/time -v python project/m1/bench_raft_10_runs.py
"""
from __future__ import annotations

import torch
import torchvision.transforms.functional as F
from torchvision.models.optical_flow import Raft_Large_Weights, raft_large

torch.manual_seed(0)

# Match plot_optical_flow: two pairs -> batch [2,3,H,W], resized to 520x960, then weights transforms
img1_batch = torch.rand(2, 3, 520, 960)
img2_batch = torch.rand(2, 3, 520, 960)

weights = Raft_Large_Weights.DEFAULT
transforms = weights.transforms()


def preprocess(i1: torch.Tensor, i2: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    i1 = F.resize(i1, size=[520, 960], antialias=False)
    i2 = F.resize(i2, size=[520, 960], antialias=False)
    return transforms(i1, i2)


img1_batch, img2_batch = preprocess(img1_batch, img2_batch)

device = "cuda" if torch.cuda.is_available() else "cpu"
model = raft_large(weights=Raft_Large_Weights.DEFAULT, progress=False).to(device)
model.eval()

x1 = img1_batch.to(device)
x2 = img2_batch.to(device)

N = 10
with torch.no_grad():
    for _ in range(N):
        _ = model(x1, x2)

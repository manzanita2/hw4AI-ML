#!/usr/bin/env python3
"""
Profile ResNet-18 (FP32) on a single forward pass (batch=1, 3x224x224)
and print results to stdout.
Deps:
  pip install torch torchvision torchinfo
"""
import time
import torch
from torchinfo import summary
from torchvision.models import resnet18, ResNet18_Weights
def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    torch.set_grad_enabled(False)
    model = resnet18(weights=ResNet18_Weights.DEFAULT).to(device).eval().float()
    x = torch.randn(1, 3, 224, 224, device=device, dtype=torch.float32)
    print(f"Device: {device}")
    print("=== torchinfo summary ===")
    # torchinfo runs a forward pass internally to collect shapes/params.
    print(
        summary(
            model,
            input_data=x,
            verbose=0,
            col_names=("input_size", "output_size", "num_params", "mult_adds"),
            device=str(device),
        )
    )
    # Optional: quick timing of *one* FP32 forward pass.
    if device.type == "cuda":
        torch.cuda.synchronize()
    t0 = time.perf_counter()
    y = model(x)
    if device.type == "cuda":
        torch.cuda.synchronize()
    t1 = time.perf_counter()
    print("=== single forward timing ===")
    print(f"Elapsed: {(t1 - t0) * 1e3:.3f} ms")
if __name__ == "__main__":
    main()

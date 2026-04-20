import sys

import torch
import torch.nn as nn


def main() -> None:
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    if device.type != "cuda":
        print("CUDA GPU not available. Exiting without running forward pass.")
        sys.exit(0)

    print(f"CUDA available: {torch.cuda.is_available()}")
    print(f"Using GPU: {torch.cuda.get_device_name(0)}")
    print(f"Device: {device}")

    model = nn.Sequential(
        nn.Linear(4, 5, bias=False),
        nn.ReLU(),
        nn.Linear(5, 1, bias=False),
    ).to(device)

    x = torch.randn(16, 4).to(device)
    output = model(x)

    print(f"Input shape: {x.shape}")
    print(f"Output shape: {output.shape}")
    print(f"Output device: {output.device}")


if __name__ == "__main__":
    main()

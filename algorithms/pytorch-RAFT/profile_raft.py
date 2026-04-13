from torchvision.models.optical_flow import raft_large, Raft_Large_Weights
from torchinfo import summary
model = raft_large(weights=Raft_Large_Weights.DEFAULT).eval()
summary(
    model,
    input_size=[(2, 3, 520, 960), (2, 3, 520, 960)],
    col_names=["input_size", "output_size", "num_params", "mult_adds"],
    depth=5
)

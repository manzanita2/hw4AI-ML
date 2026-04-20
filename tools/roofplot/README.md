# roofplot

Generate roofline plots from a YAML file that describes:
- hardware limits (peak compute and peak memory bandwidth),
- kernel performance points (AI and achieved GFLOP/s).

## Requirements

- Python 3.9+
- `numpy`
- `matplotlib`
- `PyYAML`

Install:

```bash
pip install numpy matplotlib pyyaml
```

## Usage

```bash
python tools/roofplot/roofplot.py --config tools/roofplot/example_roofline.yml
```

The script saves the output figure to the `plot.output` path (relative to the YAML file location).

## YAML schema

```yaml
hardware:
  peak_compute_gflops: 10000
  peak_bandwidth_name: "VRAM"       # optional
  peak_bandwidth_gbs: 320
  secondary_bandwidth:              # optional
    name: "L2 cache"
    peak_bandwidth_gbs: 1200

plot:
  title: "My Roofline"          # optional
  output: "roofline.png"        # optional, default roofline.png
  ai_min: 0.1                   # optional
  ai_max: 200                   # optional

points:
  - name: "kernel_name"
    ai_flops_per_byte: 1.2
    performance_gflops: 800
    color: "tab:blue"           # optional
    marker: "o"                 # optional
```

## Plot behavior

- x-axis: arithmetic intensity (FLOP/Byte), base-10 log scale
- y-axis: performance (GFLOP/s), base-10 log scale
- primary memory roof uses `P = BW * AI`
- optional secondary memory roof can be added with `hardware.secondary_bandwidth`
- compute roof uses `P = peak_compute`
- each memory roof gets its own ridge point: `AI_ridge = peak_compute / peak_bandwidth`

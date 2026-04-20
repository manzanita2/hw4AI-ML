#!/usr/bin/env python3
"""Generate roofline plot from YAML description."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any, Dict, List

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import yaml


def _require(mapping: Dict[str, Any], key: str, where: str) -> Any:
    if key not in mapping:
        raise ValueError(f"Missing required key '{key}' in {where}.")
    return mapping[key]


def _as_positive_float(value: Any, field: str) -> float:
    try:
        out = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Field '{field}' must be numeric.") from exc
    if out <= 0:
        raise ValueError(f"Field '{field}' must be > 0.")
    return out


def _load_config(path: Path) -> Dict[str, Any]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"Config file not found: {path}") from exc
    except yaml.YAMLError as exc:
        raise ValueError(f"Invalid YAML in config: {path}") from exc

    if not isinstance(data, dict):
        raise ValueError("Top-level YAML must be a mapping/object.")
    return data


def _parse_points(raw_points: Any) -> List[Dict[str, Any]]:
    if not isinstance(raw_points, list) or not raw_points:
        raise ValueError("Field 'points' must be a non-empty list.")

    points: List[Dict[str, Any]] = []
    for idx, point in enumerate(raw_points):
        where = f"points[{idx}]"
        if not isinstance(point, dict):
            raise ValueError(f"{where} must be a mapping/object.")
        name = str(_require(point, "name", where))
        ai = _as_positive_float(_require(point, "ai_flops_per_byte", where), f"{where}.ai_flops_per_byte")
        perf = _as_positive_float(_require(point, "performance_gflops", where), f"{where}.performance_gflops")
        points.append(
            {
                "name": name,
                "ai": ai,
                "perf": perf,
                "color": point.get("color", None),
                "marker": point.get("marker", "o"),
            }
        )
    return points


def _determine_ai_range(points: List[Dict[str, Any]], plot_cfg: Dict[str, Any]) -> tuple[float, float]:
    ai_values = np.array([p["ai"] for p in points], dtype=float)
    ai_min_default = max(1e-3, float(ai_values.min()) * 0.5)
    ai_max_default = float(ai_values.max()) * 2.0

    ai_min = _as_positive_float(plot_cfg.get("ai_min", ai_min_default), "plot.ai_min")
    ai_max = _as_positive_float(plot_cfg.get("ai_max", ai_max_default), "plot.ai_max")
    if ai_min >= ai_max:
        raise ValueError("plot.ai_min must be < plot.ai_max.")
    return ai_min, ai_max


def make_roofline(config: Dict[str, Any], config_path: Path) -> Path:
    hardware = _require(config, "hardware", "top-level config")
    if not isinstance(hardware, dict):
        raise ValueError("Field 'hardware' must be a mapping/object.")

    peak_compute = _as_positive_float(
        _require(hardware, "peak_compute_gflops", "hardware"), "hardware.peak_compute_gflops"
    )
    peak_bandwidth = _as_positive_float(
        _require(hardware, "peak_bandwidth_gbs", "hardware"), "hardware.peak_bandwidth_gbs"
    )
    primary_bandwidth_name = str(hardware.get("peak_bandwidth_name", "Primary bandwidth"))

    secondary_bandwidth = None
    if "secondary_bandwidth" in hardware:
        secondary_cfg = hardware["secondary_bandwidth"]
        if not isinstance(secondary_cfg, dict):
            raise ValueError("Field 'hardware.secondary_bandwidth' must be a mapping/object.")
        secondary_bandwidth = {
            "name": str(_require(secondary_cfg, "name", "hardware.secondary_bandwidth")),
            "peak_bandwidth_gbs": _as_positive_float(
                _require(secondary_cfg, "peak_bandwidth_gbs", "hardware.secondary_bandwidth"),
                "hardware.secondary_bandwidth.peak_bandwidth_gbs",
            ),
        }

    plot_cfg = config.get("plot", {})
    if not isinstance(plot_cfg, dict):
        raise ValueError("Field 'plot' must be a mapping/object.")
    points = _parse_points(_require(config, "points", "top-level config"))

    ai_min, ai_max = _determine_ai_range(points, plot_cfg)
    x = np.logspace(np.log10(ai_min), np.log10(ai_max), num=1024)
    memory_roof = peak_bandwidth * x
    roof = np.minimum(memory_roof, peak_compute)
    ridge_ai = peak_compute / peak_bandwidth
    secondary_memory_roof = None
    secondary_ridge_ai = None
    if secondary_bandwidth is not None:
        secondary_memory_roof = secondary_bandwidth["peak_bandwidth_gbs"] * x
        secondary_ridge_ai = peak_compute / secondary_bandwidth["peak_bandwidth_gbs"]

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(x, roof, linewidth=2.2, label="Roofline")
    ax.plot(x, memory_roof, linestyle="--", linewidth=1.2, label=f"Memory roof ({primary_bandwidth_name}): BW * AI")
    if secondary_memory_roof is not None:
        ax.plot(
            x,
            secondary_memory_roof,
            linestyle="--",
            linewidth=1.2,
            label=f"Memory roof ({secondary_bandwidth['name']}): BW * AI",
        )
    ax.axhline(peak_compute, linestyle="--", linewidth=1.2, label="Compute roof")

    for point in points:
        ax.scatter(point["ai"], point["perf"], color=point["color"], marker=point["marker"], s=70)
        ax.annotate(
            f"{point['name']} ({point['ai']:.3g}, {point['perf']:.3g})",
            (point["ai"], point["perf"]),
            textcoords="offset points",
            xytext=(6, 5),
        )

    ridge_perf = peak_compute
    ax.axvline(ridge_ai, linestyle=":", linewidth=1.1, label=f"Ridge AI = {ridge_ai:.3g}")
    ax.scatter(ridge_ai, ridge_perf, color="black", marker="x", s=80, zorder=5)
    ax.annotate(
        f"ridge-{primary_bandwidth_name} ({ridge_ai:.3g}, {ridge_perf:.3g})",
        (ridge_ai, ridge_perf),
        textcoords="offset points",
        xytext=(8, -12),
    )
    if secondary_ridge_ai is not None:
        ax.axvline(
            secondary_ridge_ai,
            linestyle=":",
            linewidth=1.1,
            color="gray",
            label=f"Ridge AI ({secondary_bandwidth['name']}) = {secondary_ridge_ai:.3g}",
        )
        ax.scatter(secondary_ridge_ai, ridge_perf, color="gray", marker="x", s=80, zorder=5)
        ax.annotate(
            f"ridge-{secondary_bandwidth['name']} ({secondary_ridge_ai:.3g}, {ridge_perf:.3g})",
            (secondary_ridge_ai, ridge_perf),
            textcoords="offset points",
            xytext=(8, 10),
        )
    ax.set_xscale("log", base=10)
    ax.set_yscale("log", base=10)
    ax.set_xlabel("Arithmetic Intensity (FLOP/Byte)")
    ax.set_ylabel("Performance (GFLOP/s)")
    ax.set_title(plot_cfg.get("title", "Roofline Plot"))
    ax.grid(True, which="both", linestyle=":", linewidth=0.6)
    ax.legend()
    fig.tight_layout()

    output_name = str(plot_cfg.get("output", "roofline.png"))
    output_path = (config_path.parent / output_name).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    return output_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot roofline from YAML config.")
    parser.add_argument(
        "--config",
        required=True,
        type=Path,
        help="Path to YAML (.yml/.yaml) roofline config file.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    config_path = args.config.resolve()
    config = _load_config(config_path)
    output_path = make_roofline(config, config_path)
    print(f"Saved roofline plot to: {output_path}")


if __name__ == "__main__":
    main()

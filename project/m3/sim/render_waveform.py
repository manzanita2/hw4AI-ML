"""Render an annotated end-to-end waveform PNG from the cocotb VCD.

Run after `make TEST=top` (or `make m3-log`) so the latest VCD lives at
project/m3/tb/artifacts/top.vcd. Output:
    project/m3/sim/cosim_waveform.png

The picture covers a single compute tile from
test_weight_reuse_two_activation_tiles: the short test that exercises
all three regions the M3 spec calls out:

  * host write    -- AXI-Lite CTRL pulse + AXIS slave push of weights
                     and the activation beat
  * internal compute -- compute_core state register + load_seq busy
                     signal walking through LOAD -> COMPUTE -> DRAIN
  * host read     -- AXIS master drain of N=4 result beats

This script does not need an X server and does not depend on gtkwave.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # headless

import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Rectangle  # noqa: E402
import re  # noqa: E402


HERE        = Path(__file__).resolve().parent
VCD_PATH    = HERE.parent / "tb" / "artifacts" / "top.vcd"
PNG_PATH    = HERE / "cosim_waveform.png"

# Pretty names + display order for the rendered tracks. Each entry is
# the **suffix** of the hierarchical signal path. The script picks the
# shortest hierarchical path whose tail matches.
SIGNALS_OF_INTEREST = [
    # bus side (host writes / reads)
    ("s_axil_awvalid", "host AXI-L AW"),
    ("s_axil_wvalid",  "host AXI-L W"),
    ("s_axis_tvalid",  "host AXIS in valid"),
    ("s_axis_tlast",   "host AXIS in last"),
    ("s_axis_tready",  "DUT AXIS in ready"),
    # decoded control
    ("cfg_start",      "iface cfg_start"),
    ("cfg_mode",       "iface cfg_mode (1=LOAD)"),
    # internal compute
    ("u_core.state",   "compute_core state"),
    ("u_lseq.state",   "load_seq state"),
    # host read
    ("m_axis_tvalid",  "DUT AXIS out valid"),
    ("m_axis_tlast",   "DUT AXIS out last"),
    ("m_axis_tready",  "host AXIS out ready"),
]

# Annotated regions. Times are in nanoseconds. They cover one full host-
# initiated tile from test_weight_reuse_two_activation_tiles (the short
# test). The starting timestamp is right after the prior PASS line at
# 5591ns, which matches the LOAD_WEIGHTS handshake of that test.
REGIONS = [
    ("host write", 5591, 5750),
    ("internal compute", 5750, 6300),
    ("host read", 6300, 6371),
]


_VAR_RE   = re.compile(
    r"^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+).*\$end\s*$"
)
_SCOPE_RE = re.compile(r"^\$scope\s+\S+\s+(\S+)\s+\$end\s*$")
_UPSCOPE_RE = re.compile(r"^\$upscope\s+\$end\s*$")


def _parse_vcd(path: Path):
    """Hand-rolled VCD parser. Tolerates the `$scope begin g_row[0]
    $end` form iverilog emits for generate-block scopes (which pyvcd
    chokes on). Returns (id_to_signal, by_path, samples) where samples
    is a list of (time_ticks, vcd_id, value) sorted by time."""
    id_to_signal = {}
    by_path      = {}
    samples      = []

    scope_stack = []
    cur_time    = 0
    in_header   = True

    with path.open("r") as f:
        for line in f:
            line = line.rstrip("\n")
            if in_header:
                if line.startswith("$enddefinitions"):
                    in_header = False
                    continue
                m = _SCOPE_RE.match(line)
                if m:
                    scope_stack.append(m.group(1))
                    continue
                if _UPSCOPE_RE.match(line):
                    if scope_stack:
                        scope_stack.pop()
                    continue
                m = _VAR_RE.match(line)
                if m:
                    width = int(m.group(1))
                    vid   = m.group(2)
                    name  = m.group(3)
                    full  = ".".join(scope_stack + [name])
                    id_to_signal[vid] = (full, width)
                    by_path[full]     = vid
                continue
            # value-change body
            if not line:
                continue
            c0 = line[0]
            if c0 == "#":
                cur_time = int(line[1:])
            elif c0 in "01xXzZ":
                # scalar: <value><id>
                samples.append((cur_time, line[1:], c0))
            elif c0 == "b" or c0 == "B":
                # vector: b<bits> <id>
                bits, _, vid = line[1:].partition(" ")
                samples.append((cur_time, vid, bits))
            # ignore $dumpvars / $dumpall framing
    return id_to_signal, by_path, samples


def _resolve(by_path: dict, suffix: str) -> str | None:
    """Return the shortest full path whose tail matches `suffix`."""
    matches = [p for p in by_path if p == suffix or p.endswith("." + suffix)]
    if not matches:
        return None
    return min(matches, key=len)


def _waveform_levels(samples, vcd_id, t_start_ns, t_end_ns,
                     ns_per_tick: float):
    """Build a step-shaped (time, level) trace within the window."""
    times  = []
    levels = []

    last = 0.0
    # Start with the value at t_start
    relevant = [(t * ns_per_tick, v) for (t, vid, v) in samples
                if vid == vcd_id]
    relevant.sort()

    for t_ns, v in relevant:
        if t_ns < t_start_ns:
            try:
                if isinstance(v, str):
                    last = float(int(v, 2)) if set(v) <= set("01") else 0.0
                else:
                    last = float(v)
            except (ValueError, TypeError):
                last = 0.0
            continue
        if t_ns > t_end_ns:
            break
        try:
            if isinstance(v, str):
                cur = float(int(v, 2)) if set(v) <= set("01") else 0.0
            else:
                cur = float(v)
        except (ValueError, TypeError):
            cur = 0.0
        times.append(t_ns)
        levels.append(cur)
        last = cur

    # Synthesise endpoint anchors so step plot fills the whole window.
    if not times or times[0] > t_start_ns:
        times.insert(0, t_start_ns)
        levels.insert(0, last)
    if times[-1] < t_end_ns:
        times.append(t_end_ns)
        levels.append(levels[-1])
    return times, levels


def main() -> None:
    if not VCD_PATH.exists():
        raise SystemExit(
            f"VCD not found at {VCD_PATH}; run `make TEST=top` from "
            f"project/m3/tb first."
        )

    id_to_signal, by_path, samples = _parse_vcd(VCD_PATH)

    # iverilog dumps in 1ps steps under cocotb (timescale 1ps). Convert
    # to ns for plotting / annotations.
    ns_per_tick = 1e-3

    t_start_ns = REGIONS[0][1]
    t_end_ns   = REGIONS[-1][2]

    fig, ax = plt.subplots(figsize=(14, 8))

    track_h = 1.0
    gap     = 0.4
    for idx, (suffix, label) in enumerate(SIGNALS_OF_INTEREST):
        full = _resolve(by_path, suffix)
        if full is None:
            continue
        vcd_id = by_path[full]
        ts, ls = _waveform_levels(
            samples, vcd_id, t_start_ns, t_end_ns, ns_per_tick
        )
        # Normalise multibit signals to a 0/1-ish band so they fit.
        max_l = max(ls) if ls else 1.0
        if max_l > 1:
            ls = [l / max_l for l in ls]
        # Stack from the top down.
        y_offset = -idx * (track_h + gap)
        ax.step(ts, [l * 0.8 + y_offset for l in ls], where="post",
                linewidth=1.4)
        ax.text(t_start_ns - (t_end_ns - t_start_ns) * 0.02,
                y_offset + 0.4, label,
                ha="right", va="center", fontsize=9, family="monospace")

    # Region shading + annotations.
    y_top    = 0.9
    y_bottom = -(len(SIGNALS_OF_INTEREST)) * (track_h + gap)
    region_colors = ["#fde68a", "#bae6fd", "#bbf7d0"]
    for (name, lo, hi), color in zip(REGIONS, region_colors):
        ax.add_patch(Rectangle(
            (lo, y_bottom), hi - lo, y_top - y_bottom,
            facecolor=color, edgecolor="none", alpha=0.35, zorder=0,
        ))
        ax.text((lo + hi) / 2, y_top - 0.2, name,
                ha="center", va="top", fontsize=11,
                fontweight="bold")

    ax.set_xlim(t_start_ns - (t_end_ns - t_start_ns) * 0.05, t_end_ns)
    ax.set_ylim(y_bottom - 0.4, y_top)
    ax.set_yticks([])
    ax.set_xlabel("time (ns)")
    ax.set_title(
        "M3 end-to-end co-simulation: one host-driven compute tile\n"
        "(test_weight_reuse_two_activation_tiles, tile 1)"
    )
    ax.grid(True, axis="x", linestyle=":", alpha=0.4)

    fig.tight_layout()
    fig.savefig(PNG_PATH, dpi=140)
    print(f"Wrote {PNG_PATH}")


if __name__ == "__main__":
    main()

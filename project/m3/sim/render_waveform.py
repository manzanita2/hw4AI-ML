"""Render an annotated, multi-panel end-to-end waveform PNG from the VCD.

Run after a VCD-enabled cocotb run so the latest VCD lives at
project/m3/tb/artifacts/top.vcd, e.g.:

    cd project/m3/tb && COCOTB_TEST_FILTER=test_gemm_tile_e2e make

(any run that exercises one LOAD_WEIGHTS + COMPUTE works; filtering to the
headline GEMM tile keeps the VCD small and the picture clean -- a full
`make` run also works but dumps a much larger VCD because of the conv
tests). Output: project/m3/sim/cosim_waveform.png

Why this script is shaped the way it is
---------------------------------------
A single 16x16 tile spans ~5 us (LOAD replay ~256 cy + COMPUTE ~253 cy +
DRAIN 16 beats). On one linear time axis the control writes and the result
drain are sub-1% slivers, so they show "no edges". This renderer instead:

  1. AUTO-DETECTS the regions from signal edges (no hardcoded timestamps),
     so it survives M/N and pipeline-latency changes. It anchors on the
     first CTRL.START with MODE=LOAD (weight load) and the following
     MODE=COMPUTE, then walks u_core.state LOAD -> COMPUTE -> DRAIN -> IDLE.
  2. Draws each region in its OWN subplot with an INDEPENDENT x-scale, so
     the 16-cycle drain gets the same visual width as the 256-cycle load.
  3. Plots BOTH halves of every AXI channel (valid AND ready) plus the
     AXI4-Lite READ channel (AR/R) that carries the host's STATUS polling
     -- the part the old single-window picture omitted entirely.

Wide data buses (wdata/rdata/tdata) are intentionally not drawn: squashed
to a 0..1 band they read as noise. The handshake + state lines are what
make the interaction legible.

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

# iverilog dumps in 1ps steps under cocotb (timescale 1ps). Convert to ns.
NS_PER_TICK = 1e-3

# Pretty names + display order for the rendered tracks. Each entry is the
# **suffix** of the hierarchical signal path; the shortest matching path
# wins. Grouped so each AXI channel's valid/ready pair sits together.
SIGNALS_OF_INTEREST = [
    # -- AXI4-Lite write channel (host -> DUT control) -----------------
    ("s_axil_awvalid", "AXI-L AW valid"),
    ("s_axil_awready", "AXI-L AW ready"),
    ("s_axil_wvalid",  "AXI-L  W valid"),
    ("s_axil_wready",  "AXI-L  W ready"),
    ("s_axil_bvalid",  "AXI-L  B valid"),
    ("s_axil_bready",  "AXI-L  B ready"),
    # -- AXI4-Lite read channel (host STATUS polling) ------------------
    ("s_axil_arvalid", "AXI-L AR valid"),
    ("s_axil_arready", "AXI-L AR ready"),
    ("s_axil_rvalid",  "AXI-L  R valid"),
    ("s_axil_rready",  "AXI-L  R ready"),
    # -- decoded control (incl. the new accumulate bits) ---------------
    ("cfg_start",      "cfg_start"),
    ("cfg_mode",       "cfg_mode (1=LOAD)"),
    ("cfg_accum",      "cfg_accum"),
    ("cfg_hold",       "cfg_hold"),
    # -- AXI4-Stream ingress (weights / activations) -------------------
    ("s_axis_tvalid",  "AXIS in valid"),
    ("s_axis_tready",  "AXIS in ready"),
    ("s_axis_tlast",   "AXIS in last"),
    # -- internal FSMs -------------------------------------------------
    ("u_core.state",   "compute_core state"),
    ("u_lseq.state",   "load_seq state"),
    # -- AXI4-Stream egress (result drain) -----------------------------
    ("m_axis_tvalid",  "AXIS out valid"),
    ("m_axis_tready",  "AXIS out ready"),
    ("m_axis_tlast",   "AXIS out last"),
]

# Decoded enum labels drawn at each transition, by signal suffix.
STATE_LABELS = {
    "u_core.state": {0: "IDLE", 1: "LOAD", 2: "COMPUTE", 3: "DRAIN"},
}

# compute_core_pipelined state encoding (must match the RTL typedef).
ST_IDLE, ST_LOAD, ST_COMPUTE, ST_DRAIN = 0, 1, 2, 3

REGION_COLORS = ["#fde68a", "#fca5a5", "#bae6fd", "#bbf7d0"]


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
                samples.append((cur_time, line[1:], c0))
            elif c0 == "b" or c0 == "B":
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


def _num(v) -> float:
    """VCD value -> numeric. x/z -> 0; binary string -> int."""
    if isinstance(v, str):
        return float(int(v, 2)) if (v and set(v) <= set("01")) else 0.0
    return float(v)


def _trace(samples, vcd_id) -> list[tuple[float, float]]:
    """Sorted [(t_ns, numeric_value)] for one signal."""
    tr = [(t * NS_PER_TICK, _num(v)) for (t, vid, v) in samples if vid == vcd_id]
    tr.sort()
    return tr


def _value_at(trace, t_ns: float) -> float:
    """Last value at or before t_ns (0 if none)."""
    last = 0.0
    for t, v in trace:
        if t > t_ns:
            break
        last = v
    return last


def _rising_edges(trace) -> list[float]:
    """Times where a 0/1 scalar rises to 1."""
    edges = []
    prev = 0.0
    for t, v in trace:
        if v >= 0.5 and prev < 0.5:
            edges.append(t)
        prev = v
    return edges


def _first_state_at_or_after(trace, value: int, t0: float) -> float | None:
    for t, v in trace:
        if t >= t0 and int(round(v)) == value:
            return t
    return None


def _build_step(trace, lo: float, hi: float):
    """Step-shaped (times, levels) clamped to [lo, hi] with anchors so the
    plot fills the whole panel even if no edge falls inside it."""
    times, levels = [], []
    last = 0.0
    for t, v in trace:
        if t < lo:
            last = v
            continue
        if t > hi:
            break
        times.append(t)
        levels.append(v)
        last = v
    if not times or times[0] > lo:
        times.insert(0, lo)
        levels.insert(0, last)
    if times[-1] < hi:
        times.append(hi)
        levels.append(levels[-1])
    return times, levels


def _detect_regions(traces: dict):
    """Auto-locate the four zoom regions from signal edges.

    Anchors on the first CTRL.START with MODE=LOAD (weight load) and the
    next MODE=COMPUTE, then walks u_core.state. Returns a list of
    (label, lo_ns, hi_ns)."""
    cfg_start = traces.get("cfg_start")
    cfg_mode  = traces.get("cfg_mode")
    state     = traces.get("u_core.state")
    if not cfg_start or state is None:
        raise SystemExit(
            "cannot auto-detect regions: missing cfg_start / u_core.state "
            "in the VCD. Re-run a VCD-enabled cocotb tile first."
        )

    starts = _rising_edges(cfg_start)
    if not starts:
        raise SystemExit("no CTRL.START pulse found in the VCD.")

    def mode_at(t):
        return int(round(_value_at(cfg_mode, t))) if cfg_mode else 0

    # First LOAD_WEIGHTS start, then the following COMPUTE start.
    t_loadw = next((t for t in starts if mode_at(t) == 1), None)
    if t_loadw is None:
        t_loadw = starts[0]
    t_comp = next((t for t in starts if t > t_loadw and mode_at(t) == 0), None)
    if t_comp is None:
        raise SystemExit("no MODE=COMPUTE CTRL.START found after the load.")

    # Internal FSM walk for the compute tile.
    t_st_load   = _first_state_at_or_after(state, ST_LOAD, t_comp) or t_comp
    t_st_comp   = _first_state_at_or_after(state, ST_COMPUTE, t_st_load) or t_st_load
    t_st_drain  = _first_state_at_or_after(state, ST_DRAIN, t_st_comp)
    t_st_idle   = (_first_state_at_or_after(state, ST_IDLE, t_st_drain)
                   if t_st_drain is not None else None)
    if t_st_drain is None:
        raise SystemExit("compute_core never entered DRAIN in this VCD.")
    if t_st_idle is None:
        t_st_idle = t_st_drain + 200.0

    pad = 30.0   # ns of breathing room around each region
    return [
        ("(1) load weights\nAXI-L CTRL + AXIS weight burst + STATUS poll",
         t_loadw - pad, t_comp - pad),
        ("(2) start compute\nAXI-L CTRL + AXIS activation push",
         t_comp - pad, t_comp + 400.0),
        ("(3) internal compute\nload_seq replay -> systolic MAC",
         t_st_load - pad, t_st_drain + pad),
        ("(4) host read\nAXIS result drain + STATUS poll -> IDLE",
         t_st_drain - pad, t_st_idle + 500.0),
    ]


def main() -> None:
    if not VCD_PATH.exists():
        raise SystemExit(
            f"VCD not found at {VCD_PATH}; run a VCD-enabled cocotb tile "
            f"first, e.g. `COCOTB_TEST_FILTER=test_gemm_tile_e2e make` in "
            f"project/m3/tb."
        )

    _id, by_path, samples = _parse_vcd(VCD_PATH)

    # Resolve each signal and cache its full numeric trace.
    traces: dict[str, list] = {}
    resolved: list[tuple[str, str]] = []
    for suffix, label in SIGNALS_OF_INTEREST:
        full = _resolve(by_path, suffix)
        if full is None:
            continue
        traces[suffix] = _trace(samples, by_path[full])
        resolved.append((suffix, label))

    regions = _detect_regions(traces)

    track_h, gap = 1.0, 0.4
    y_of = lambda idx: -idx * (track_h + gap)  # noqa: E731

    # Per-signal global max for consistent normalisation across panels.
    glob_max = {}
    for suffix, _ in resolved:
        vals = [v for _, v in traces[suffix]]
        glob_max[suffix] = max(vals) if vals and max(vals) > 1 else 1.0

    n_tracks = len(resolved)
    fig, axes = plt.subplots(
        1, len(regions), figsize=(20, 11), sharey=True
    )

    for ax, (name, lo, hi), color in zip(axes, regions, REGION_COLORS):
        y_bottom = y_of(n_tracks - 1) - 0.4
        y_top    = 0.9
        ax.add_patch(Rectangle(
            (lo, y_bottom), hi - lo, y_top - y_bottom,
            facecolor=color, edgecolor="none", alpha=0.30, zorder=0,
        ))

        for idx, (suffix, _label) in enumerate(resolved):
            ts, ls = _build_step(traces[suffix], lo, hi)
            mx = glob_max[suffix]
            y = y_of(idx)
            ls_n = [l / mx for l in ls]
            ax.step(ts, [l * 0.8 + y for l in ls_n], where="post",
                    linewidth=1.3)

            # Annotate decoded enum names at each transition in view.
            if suffix in STATE_LABELS:
                names = STATE_LABELS[suffix]
                prev = None
                for t, v in traces[suffix]:
                    if t < lo or t > hi:
                        continue
                    iv = int(round(v))
                    if iv != prev:
                        ax.text(max(t, lo), y + 0.85,
                                names.get(iv, str(iv)),
                                fontsize=6, va="bottom", ha="left",
                                family="monospace", color="#1e3a8a")
                        prev = iv

        ax.set_xlim(lo, hi)
        ax.set_title(f"{name}\n[{lo:.0f}-{hi:.0f} ns | {hi - lo:.0f} ns]",
                     fontsize=9)
        ax.grid(True, axis="x", linestyle=":", alpha=0.4)
        ax.tick_params(axis="x", labelsize=7)

    # Shared y labels on the leftmost panel only.
    axes[0].set_yticks([y_of(idx) + 0.4 for idx in range(n_tracks)])
    axes[0].set_yticklabels([label for _, label in resolved],
                            fontsize=8, family="monospace")
    axes[0].set_ylim(y_of(n_tracks - 1) - 0.4, 0.95)

    fig.suptitle(
        "M3 end-to-end co-simulation: one host-driven LOAD + COMPUTE tile "
        "(test_gemm_tile_e2e)\n"
        "four independently zoomed regions -- note each panel has its own "
        "time scale (width in title)",
        fontsize=12,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(PNG_PATH, dpi=140)
    print(f"Wrote {PNG_PATH}")


if __name__ == "__main__":
    main()

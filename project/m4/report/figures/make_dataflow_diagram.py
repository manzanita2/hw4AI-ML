#!/usr/bin/env python3
"""Generate dataflow_diagram.png for the M4 design-justification report.

Two panels:
  (A) the weight-stationary systolic dataflow -- weights held in the PE grid,
      activations streamed in row-by-row with the MAC_LATENCY skew, partial
      products accumulated down each column in fp32 into result_buf, then
      bf16-rounded on drain;
  (B) the per-tile LOAD / COMPUTE(hold) / DRAIN phase timeline with the
      measured steady-state cycle counts (bench/bench_measured.csv).

A 4x4 grid stands in for the real 16x16 array. Pure matplotlib. Run:
    ../../../.venv-cocotb/bin/python make_dataflow_diagram.py
-> dataflow_diagram.png next to this script.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "dataflow_diagram.png")

# measured per-phase cycles (bench/bench_measured.csv)
LOAD_CYC, COMPUTE_CYC, DRAIN_CYC = 23, 422, 16
GRID = 4  # representative tile (real array is 16x16)

C_PE = "#bfe3c6"
C_ACC = "#cfe3f7"
C_ACT = "#f7d9b0"
EDGE = "#333333"

fig, (axA, axB) = plt.subplots(
    1, 2, figsize=(13, 6.2), gridspec_kw={"width_ratios": [1.55, 1.0]})

# =======================================================================
# Panel A: weight-stationary systolic array
# =======================================================================
axA.set_xlim(-3.6, GRID + 1.9)
axA.set_ylim(-2.8, GRID + 1.6)
axA.axis("off")
axA.set_title("(a) Weight-stationary dataflow (4x4 shown; array is 16x16)",
              fontsize=11, fontweight="bold")

step = 1.0
sz = 0.82

def pe_xy(r, c):
    return c * step, (GRID - 1 - r) * step

# PE grid: weights resident
for r in range(GRID):
    for c in range(GRID):
        x, y = pe_xy(r, c)
        axA.add_patch(FancyBboxPatch((x, y), sz, sz,
                      boxstyle="round,pad=0.03,rounding_size=0.08",
                      lw=1.2, edgecolor=EDGE, facecolor=C_PE, zorder=2))
        axA.text(x + sz / 2, y + sz / 2, f"$w_{{{r}{c}}}$",
                 ha="center", va="center", fontsize=9, zorder=3)

# activation entry from the left, staggered (skew) per row
for r in range(GRID):
    x, y = pe_xy(r, 0)
    x0 = -2.6 - 0.45 * (GRID - 1 - r)   # higher rows start further left = later
    axA.add_patch(FancyArrowPatch((x0, y + sz / 2), (x - 0.04, y + sz / 2),
                  arrowstyle="-|>", mutation_scale=12, lw=1.5,
                  color="#b5651d", zorder=1))
    axA.text(x0 - 0.15, y + sz / 2, f"$x[{r}]$", ha="right", va="center",
             fontsize=8.5, color="#7a3e00")

# skew wavefront (dashed diagonal)
axA.plot([-2.6, -1.25], [pe_xy(GRID - 1, 0)[1] + sz / 2,
         pe_xy(0, 0)[1] + sz / 2], ls="--", color="#b5651d", lw=1.0)
axA.text(GRID * step / 2 - 0.1, GRID * step + 0.7,
         "activations stream in row-by-row;\nrow $i$ skewed by $i$+MAC_LATENCY",
         ha="center", va="center", fontsize=8.8, color="#7a3e00")

# partial-sum flow down each column
for c in range(GRID):
    x, _ = pe_xy(0, c)
    axA.add_patch(FancyArrowPatch((x + sz / 2, -0.15), (x + sz / 2, -1.0),
                  arrowstyle="-|>", mutation_scale=12, lw=1.5,
                  color="#1f6feb", zorder=1))

# result_buf accumulators under each column
for c in range(GRID):
    x, _ = pe_xy(0, c)
    axA.add_patch(FancyBboxPatch((x - 0.02, -1.95), sz + 0.04, 0.85,
                  boxstyle="round,pad=0.02,rounding_size=0.06",
                  lw=1.2, edgecolor=EDGE, facecolor=C_ACC, zorder=2))
    axA.text(x + sz / 2, -1.52, f"$\\Sigma_{c}$", ha="center", va="center",
             fontsize=9, zorder=3)

axA.text(GRID * step / 2 - 0.1, -2.5,
         "result_buf: fp32 accumulate down columns  $\\rightarrow$  "
         "bf16 round on drain", ha="center", va="center", fontsize=9)
axA.text(GRID + 1.6, GRID * step - 0.4, "weights\nstationary\n(loaded once,\nheld in PEs)",
         ha="center", va="center", fontsize=8.8, color="#1c5b2b",
         bbox=dict(boxstyle="round,pad=0.3", fc="#e8f5ea", ec="#1c5b2b"))

# =======================================================================
# Panel B: per-tile phase timeline
# =======================================================================
axB.set_title("(b) Per-tile phase timeline (measured cycles @ 100 MHz)",
              fontsize=11, fontweight="bold")
total = LOAD_CYC + COMPUTE_CYC + DRAIN_CYC
phases = [("LOAD\nweights", LOAD_CYC, C_ACT),
          ("COMPUTE (hold)\nstream activations + MAC", COMPUTE_CYC, C_PE),
          ("DRAIN\nN results", DRAIN_CYC, C_ACC)]
axB.set_xlim(0, total)
axB.set_ylim(0, 10)
axB.axis("off")

x = 0
ybar, hbar = 5.5, 2.4
for name, cyc, col in phases:
    axB.add_patch(Rectangle((x, ybar), cyc, hbar, facecolor=col,
                  edgecolor=EDGE, lw=1.3, zorder=2))
    axB.text(x + cyc / 2, ybar + hbar / 2, f"{name}\n({cyc} cyc)",
             ha="center", va="center", fontsize=8.6, zorder=3)
    x += cyc

# axis line + cycle ticks
axB.add_patch(FancyArrowPatch((0, ybar - 0.6), (total, ybar - 0.6),
              arrowstyle="-|>", mutation_scale=12, lw=1.3, color=EDGE))
axB.text(total / 2, ybar - 1.4, f"cycles  (total {total}/tile)",
         ha="center", va="center", fontsize=9)

axB.text(total / 2, 2.4,
         "Cross-tile: COMPUTE asserts CTRL.ACCUM (add into result_buf)\n"
         "and CTRL.HOLD on every K-tile but the last; only the final\n"
         "tile DRAINs. Weight reload per K-tile is the reuse bottleneck\n"
         "(see roofline / 'what did not work').",
         ha="center", va="center", fontsize=8.6,
         bbox=dict(boxstyle="round,pad=0.4", fc="#f5f5f5", ec="#999999"))

fig.suptitle("Compute-core dataflow and scheduling -- "
             "compute_core_pipelined (M=N=16, MAC_LATENCY=5)",
             fontsize=12.5, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.95])
fig.savefig(OUT, dpi=150, bbox_inches="tight")
print("wrote", OUT)

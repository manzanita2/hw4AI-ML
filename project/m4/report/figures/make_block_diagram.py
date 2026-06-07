#!/usr/bin/env python3
"""Generate block_diagram.png for the M4 design-justification report.

Renders the `top` module's block diagram (the structure documented in
project/m4/rtl/top.sv) as a labelled dataflow graph: the AXI4-Stream data
plane (ingress FIFO -> LOAD/COMPUTE demux -> weight_store / compute_core ->
egress FIFO -> skid buffer) and the AXI4-Lite control plane (interface_module).

Pure matplotlib, no graphviz. Run:
    ../../../.venv-cocotb/bin/python make_block_diagram.py
-> block_diagram.png next to this script.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "block_diagram.png")

# ---- palette -----------------------------------------------------------
C_DATA = "#cfe3f7"   # AXIS data-plane blocks
C_CORE = "#bfe3c6"   # compute / weight blocks
C_CTRL = "#f7e0c0"   # AXI-Lite control plane
C_PORT = "#e8e8e8"   # external bus ports
EDGE = "#333333"

fig, ax = plt.subplots(figsize=(12, 7.0))
ax.set_xlim(0, 100)
ax.set_ylim(0, 66)
ax.axis("off")


def box(x, y, w, h, text, fc, fs=10, bold=False):
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.2",
                       linewidth=1.4, edgecolor=EDGE, facecolor=fc, zorder=2)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, zorder=3,
            fontweight="bold" if bold else "normal")
    return (x, y, w, h)


def arrow(p1, p2, text=None, color=EDGE, ls="-", rad=0.0, dy=0.0):
    a = FancyArrowPatch(p1, p2, arrowstyle="-|>", mutation_scale=14,
                        linewidth=1.5, color=color, zorder=1,
                        connectionstyle=f"arc3,rad={rad}", linestyle=ls)
    ax.add_patch(a)
    if text:
        mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2 + dy
        ax.text(mx, my, text, ha="center", va="center", fontsize=8,
                color=color, zorder=4,
                bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))


def rcent(b):  # right-edge center
    x, y, w, h = b; return (x + w, y + h / 2)
def lcent(b):  # left-edge center
    x, y, w, h = b; return (x, y + h / 2)
def tcent(b):
    x, y, w, h = b; return (x + w / 2, y + h)
def bcent(b):
    x, y, w, h = b; return (x + w / 2, y)


# ---- weight path (top band) -------------------------------------------
wstore = box(44, 50, 15, 9, "weight_store\nM*N bf16 RAM", C_CORE, 9)
lseq = box(63, 50, 14, 9, "load_seq\n(weight replay)", C_CORE, 9)

# ---- data plane (middle band, left -> right) --------------------------
yd = 32
sport = box(1, yd, 11, 10, "AXI4-Stream\nslave\n(s_axis_*)", C_PORT, 9)
ingf = box(14.5, yd, 13, 10, "Ingress FIFO\nfifo_sync\n{tlast,tdata}x16", C_DATA, 9)
demux = box(30, yd, 12.5, 10, "LOAD/COMPUTE\ndemux\n(cfg_mode)", C_DATA, 9, bold=True)
core = box(45, yd - 1, 22, 12, "compute_core_pipelined\n16x16 PEs (256 MACs)\nMAC_LATENCY=5\nbf16 x, fp32 acc, bf16 out",
           C_CORE, 9, bold=True)
egf = box(70, yd, 12.5, 10, "Egress FIFO\nfifo_sync x16", C_DATA, 9)
mport = box(86.5, yd, 12, 10, "AXI4-Stream\nmaster\n(m_axis_*)", C_PORT, 9)
skid = box(70, 16, 12.5, 9, "skid_buffer\n(reg AXIS out)", C_DATA, 9)

# ---- control plane (bottom band) --------------------------------------
axilport = box(1, 3, 13, 9, "AXI4-Lite\nslave\n(s_axil_*)", C_PORT, 9)
iface = box(17, 3, 33, 9, "interface_module (AXI4-Lite slave, s_axil_*)\n"
            "CTRL / STATUS / SCRATCH regs", C_CTRL, 9, bold=True)

# ---- data-plane arrows -------------------------------------------------
arrow(rcent(sport), lcent(ingf), "256b beats")
arrow(rcent(ingf), lcent(demux))
arrow(rcent(demux), lcent(core), "mode=0\nCOMPUTE", dy=-1.2)
# demux --LOAD--> weight_store (up), then replay chain back into core
arrow(tcent(demux), lcent(wstore), "mode=1  LOAD", rad=-0.2, dy=1.0)
arrow(rcent(wstore), lcent(lseq), "rd_addr/\nrd_data")
arrow(bcent(lseq), tcent(core), "wt_data_ext", rad=0.15, dy=0.5)
# core -> egress fifo -> skid -> master
arrow(rcent(core), lcent(egf), "res_*")
arrow(bcent(egf), tcent(skid))
arrow(rcent(skid), bcent(mport), "m_axis_*", rad=-0.2)

# ---- control-plane arrows ---------------------------------------------
arrow(rcent(axilport), lcent(iface))
arrow(tcent(iface), bcent(core), "cfg_start, cfg_mode,\ncfg_accum, cfg_hold",
      color="#9a5b16", rad=-0.12, dy=-1.0)
arrow((core[0] + core[2] - 3, core[1]), (iface[0] + iface[2] - 3, iface[1] + iface[3]),
      "status_busy/done,\nweights_loaded, load_err", color="#9a5b16", rad=-0.28, dy=1.0)

ax.set_title("top.sv block diagram -- 16x16 systolic accelerator "
             "(AXI4-Stream data plane + AXI4-Lite control plane)",
             fontsize=11.5, fontweight="bold")

fig.tight_layout()
fig.savefig(OUT, dpi=150, bbox_inches="tight")
print("wrote", OUT)

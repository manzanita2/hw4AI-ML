# Codefest 7 — Synthesis interpretation

Sky130A run of `crossbar_mac` (`hdl/synth_top.sv`), LibreLane Classic flow,
reports copied from `runs/RUN_2026-05-18_22-49-08/` into `codefest/cf07/synth/`.

## (a) Clock period and worst-case slack

`CLOCK_PERIOD = 25 ns` (40 MHz) in `config.json`. A first attempt at
3.333 ns — matching the 300 MHz architectural target in
`project/architecture.md` — hit setup violations across all TT corners,
so I relaxed the period for this codefest. At 25 ns the design closes
on every PVT corner (`synth/summary.rpt`):

| Corner | WNS setup (ns) | WNS hold (ns) |
|---|---|---|
| **Overall worst** | **+8.5706** | **+0.3907** |
| `nom_tt_025C_1v80` | +14.5313 | +0.7218 |
| `max_ss_100C_1v60` | +8.5706 | +1.7051 |
| `max_ff_n40C_1v95` | +16.5743 | +0.3931 |

## (b) Critical path

From `synth/max_ss_100C_1v60/max.rpt`:

- **Startpoint:** primary input `in[25]` (clocked by `clk`, input ext. delay 5 ns)
- **Endpoint:** `out_..._dfxtp_2_Q_18`, one of the 16-bit `out[j]` register flops
- Data arrival 17.24 ns; data required 25.81 ns; slack +8.57 ns.

Dominant cell types along the path: `mux2_1` (selects `+in[i]` vs.
`−in[i]` per the `weight[i][j] == +1` test), `xor2_2`/`xnor2_2` (sum
bits), and the carry-chain reductions in the 4-deep adder tree
(`or4_2`, `or3_2`, `a221o_2`, `a21o_2`, `a21oi_2`), with
`and2b_2`/`nand2b_2` interleaved for inversion.

## (c) Area and top contributors

Total cell area **13,246.45 μm²**, of which **4,020.11 μm² (30.4 %) is
sequential** (`synth/stat.rpt`, l. 58–59). 1,101 cells; 189 D-flops —
close to the 192 expected from `weight[4][4][8]` (128 b) + `out[4][16]`
(64 b); three bits optimized away by Yosys.

| Rank | Cell | Count | Area (μm²) | Role |
|---|---|---|---|---|
| 1 | `sky130_fd_sc_hd__dfxtp_2` | 189 | 4020.11 | weight + output state |
| 2 | `sky130_fd_sc_hd__mux2_1`  | 231 | 2600    | ±1 sign-select on each input lane |
| 3 | `sky130_fd_sc_hd__xnor2_2` |  73 | 1190    | adder sum bits |

By instance count: `mux2_1` (231) > `dfxtp_2` (189) > `xnor2_2` (73).
The 231 muxes confirm the binary-weight multiplication compiles down to
2:1 selects — no DSP-like multiplier in the netlist, as intended.

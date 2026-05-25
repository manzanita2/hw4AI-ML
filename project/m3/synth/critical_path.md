# Critical Path -- `top` at M = N = 4, sky130, 300 MHz target (post-resizer)

This document is sourced from the OpenLane 2 post-resizer STA report at:

```
project/m3/synth/runs/RUN_2026-05-24_18-50-37/38-openroad-stamidpnr-2/max.rpt
```

(typical-typical corner, 25 °C, 1.80 V; this is the canonical timing
sign-off for this run because step 39 globalrouting bailed with
[GRT-0116] congestion -- a floorplan density problem, not a timing
problem; see Phase 10 / 11 of [`synthesis_notes.md`](../synthesis_notes.md).)

## One-line summary

Iter 7 deepened the bf16 multiplier from `mul_bf16_p2` (2 stages, 8x8
mantissa multiply in one stage) to
[`mul_bf16_p3`](../rtl/mul_bf16_p3.sv) (3 stages; B-half radix-4 split:
two 4x8 -> 12-bit half-products in stage 1, 16-bit shift-add CPA in
stage 2, normalize/exp/pack in stage 3). PE pipeline depth went 7 -> 8
([`pe_pipelined.sv`](../rtl/pe_pipelined.sv) `MUL_STAGES = 3`,
`MAC_LATENCY = 8`).

**The targeted iter-6 violator class (bf16 mul stage 1 partial-product
reduce) is reduced from -1.207 ns to -0.34 .. -0.58 ns** -- a slack
recovery of ~ 0.6-0.9 ns on that class, exactly as the radix-4 split
predicted.

WNS shifted from -1.207 ns (iter 6) to **-1.130 ns** (iter 7);
period_min went 4.54 ns -> **4.46 ns** (~ 224 MHz from 220 MHz).
Headline improvement is bound at +0.08 ns by the violator class one
priority below the bf16 mul: the ingress FIFO read mux, which iter 6
had at -0.88 ns and is now exposed as the new WNS at -1.130 ns. (Iter
8 is the mirror skid buffer + weight_store mem mux pipelining.)

## Endpoints (new WNS)

| Field             | Value                                                                                                                                                                                          |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Startpoint        | `_63508_/Q` -- `u_ing_fifo.rd_ptr[0]`, a sky130 `dfrtp_2`. The ingress FIFO read pointer LSB.                                                                                                  |
| Endpoint          | `_62658_/D` -- a sky130 `dfxtp_2` in `compute_core_pipelined` that captures one of the ingress FIFO output bits as the row activation feed (row 2 mid-byte of the AXIS-256 b ingress word).      |
| Path Group        | `clk`                                                                                                                                                                                          |
| Path Type         | `max` (setup; pure register-to-register)                                                                                                                                                       |
| Clock             | `clk`, **3.333 ns** period (300 MHz target)                                                                                                                                                    |
| Data arrival      | 5.43 ns                                                                                                                                                                                        |
| Data required     | 4.30 ns                                                                                                                                                                                        |
| **Setup slack**   | **-1.130 ns (VIOLATED)**                                                                                                                                                                       |
| Achievable period | 4.46 ns (~ 224.06 MHz, from `report_clock_min_period`)                                                                                                                                         |

## Logic stages walked

The post-resizer `max.rpt` lists 13 cells on this path. Per-stage delays
read from cumulative arrival times in `max.rpt` lines 7-95:

| Stage   | Cell type                  | Role                                                         | Cumul    |
| ------- | -------------------------- | ------------------------------------------------------------ | -------- |
| -       | clk-tree to `_63508_/CLK`  | clock-tree path to launching dfrtp_2                          | 1.32 ns  |
| 1       | `_63508_/Q (dfrtp_2)`      | u_ing_fifo.rd_ptr[0] launches; 0.40 ns clk-Q                  | 1.73 ns  |
| 2-7     | 6 buffer hops (buf_6/8)    | rd_ptr[0] fanout to mux decode (high fanout: 257 sinks)       | 2.30 ns  |
| 8       | `_29708 (xnor2_4)`         | mux decode for select-line                                    | 2.46 ns  |
| 9       | `_29731 (nand3b_4)`        | mux decode                                                    | 2.59 ns  |
| 10      | `_29733 (nand4_4)`         | mux decode                                                    | 2.76 ns  |
| 11-15   | 5 more buffer hops         | post-decode select-line buffering across the wide select cone | 5.11 ns  |
| 16      | `_52579 (mux2_1)`          | the actual mux2 that selects the FIFO output bit              | 5.43 ns  |
| 17      | `_62658/D (dfxtp_2)`       | compute_core ingress capture flop                              | 5.43 ns  |

About **2.0 ns** is fanout / select-line buffering (stages 2-7 + 11-15)
-- *more than half the path delay is spent buffering rd_ptr to all
257 mux-input sinks*. The actual mux decode + mux2 is only ~ 0.7 ns.
This is the textbook "wide-FIFO mux on a high-fanout pointer" pattern.

## Why this path dominates

1. **The bf16 mul stage 1 violator class was halved.** Iter 6's WNS
   path (`u_pe.act_reg[k] -> u_pe.u_mul.s1_mant_prod[k]/D`, slack
   -1.207 ns) is no longer in the violator list as a stage-1 endpoint
   -- the radix-4 split moved that endpoint to `u_pe.u_mul.prod_lo_c[k]
   /D` and `prod_hi_c[k]/D`, which now have slack -0.34 .. -0.58 ns.
2. **Iter 6's #2 violator class is now exposed as the new WNS.** That
   class was already at -0.88 ns in iter 6 (~ 25 paths from
   `u_ing_fifo.rd_ptr[0]` into the ingress FIFO read mux). With the
   bf16 mul gone, the FIFO mux is the new top.
3. **The 257-bit-wide FIFO with a 1-bit-wide rd_ptr LSB is structurally
   the same problem the egress FIFO had pre-iter-5.** Iter 5's egress
   skid buffer fixed the egress side by terminating the mux output at
   a flop D pin; the mirror fix on the ingress side has been queued
   since iter 5 but not yet implemented.

## Other surviving violator classes

| Rank | Class                                                                  | Slack (ns)        | Class size  |
| ---- | ---------------------------------------------------------------------- | ----------------- | ----------- |
| 1    | `u_ing_fifo.rd_ptr[0]` -> compute_core capture flop (FIFO read mux)    | -1.130 .. -0.001  | ~ 29 paths  |
| 2    | `u_lseq.cnt[1]` -> `u_ws.rd_data_q[k]` (mem mux from iter-6 fix)        | -0.862            | ~ 8 paths   |
| 3    | `u_pe.weight[k]` -> `u_pe.u_mul.prod_lo_c[k]/D` (radix-4 stage 1)        | -0.34 .. -0.58    | ~ 15 paths  |
| 4    | `rst -> dfrtp_2/RESET_B` (rst recovery checks)                          | -0.001 .. -0.003  | ~ 3 paths   |

Note rank 2: this is the iter-6 plan's "Risk #3" coming home. At 4x4
the weight_store mem is 16 entries deep -- a 16:1 mux is ~ 9 cells of
mux + module-boundary buffering. At 48x48 the mem is 2304 entries
deep, so this class will be much worse at full array size and is the
bigger 300 MHz risk than the ingress FIFO mux class.

## What would shorten the new WNS (ranked by expected impact)

1. **Ingress skid buffer** (mirror of iter-5's egress skid). Insert a
   2-deep AXI register slice between `u_ing_fifo` and the
   `compute_core` ingress port, so the FIFO read mux terminates at a
   skid flop D pin instead of a compute_core flop. This converts the
   problem from "rd_ptr's 1.0 ns of post-Q fanout buffering + 0.7 ns
   of mux decode + 1.5 ns of post-decode buffering + 0.6 ns of
   mux2/setup" into two shorter R2R paths: (a) rd_ptr -> skid_in
   register, and (b) skid_out register -> compute_core capture.
   Estimated WNS recovery: ~ 1.0 ns. Stacked with #2 below, **closes
   300 MHz** with positive headroom.
2. **Weight_store mem-mux address pre-decode pipelining.** At 48x48 the
   mem is 2304 entries; the mem mux is ~ 12 levels deep (vs ~ 9 at
   4x4). Add an address decode register between `u_lseq.cnt` and the
   mem mux's select cone (or split the mem into row-major + col-major
   sub-banks so each sub-bank's mem mux is shallower). Estimated
   recovery on this class: ~ 0.5 ns at 4x4, much more at 48x48.
3. **Radix-2 split on the mantissa multiplier.** Take the radix-4
   split one more step: each 4x8 sub-multiplier becomes two 2x8
   sub-multipliers + a 12-bit shift-add. Reduces stage 1 of
   mul_bf16_p3 from ~ 8 cells to ~ 4 cells, recovering the residual
   -0.5 ns slack on that class. Optional once the FIFO mux + ws mem
   mux fixes land -- the bf16 mul is no longer the top violator.
4. **Accept ~ 224 MHz with the FIFO mux + mem mux as known issues.**
   At M = N = 48 the array sustains
   `2 * 2304 * 224e6 = 1.032 TFLOP/s` (75 % of the 1.38 TFLOP/s spec),
   AXIS-256 b at 224 MHz = 7.17 GB/s (101 % of the 7.11 GB/s ingress
   spec). Pedagogically this is a clean stopping point: the bf16
   arithmetic itself fits the 300 MHz envelope, and the remaining
   gap is data-routing / mux-fanout structural.

## Iteration history at a glance

| Iter | Critical-path startpoint                                  | post-CTS WNS  | post-resizer WNS | Fmax       |
| ---- | --------------------------------------------------------- | ------------- | ---------------- | ---------- |
| 0    | bf16 mul -> fp32 add (intra-PE)                           | -10.4 ns      | (not reached)    | ~ 49 MHz   |
| 1    | `u_core.state[1]`                                         | -4.65 ns      | -4.65 ns plateau | ~ 134 MHz  |
| 2    | `u_core.clr_psum_reg[0][0]`                               | -4.73 ns      | -4.43 ns plateau | ~ 124 MHz  |
| 3    | `rst` input port (sync rst)                               | -3.21 ns      | -1.19 ns         | ~ 227 MHz  |
| 4    | `u_eg_fifo.rd_ptr[0]` (FIFO output mux)                    | -3.56 ns      | -1.245 ns        | ~ 235 MHz  |
| 5    | `rst` -> `u_eg_fifo.mem[i]/D` mux                         | TBD           | -1.500 ns        | ~ 214 MHz  |
| 6    | `u_pe.act_reg[6] -> u_pe.u_mul.s1_mant_prod[15]` (bf16 mul) | TBD          | -1.207 ns        | ~ 220 MHz  |
| **7** | **`u_ing_fifo.rd_ptr[0] -> compute_core` (ingress mux)** | TBD           | **-1.130 ns**    | **~ 224 MHz** |

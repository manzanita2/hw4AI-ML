# Remaining tasks before M4

Ordered by priority. All references are to the most recent synthesis run
`project/m3/synth/runs/RUN_2026-05-31_00-33-25` (20x20 core, CLOCK_PERIOD 3.333 ns =
300 MHz target), which failed setup timing and failed global routing on congestion.

## 1. Make the design close timing and route: relax the clock target and de-pipeline the clock-centered datapath

Post-PnR STA reports setup WNS = **-4.01 ns** at a 3.333 ns period
(`38-openroad-stamidpnr-2/or_metrics_out.json`), i.e. the real critical path is
~7.3 ns and the design tops out near **~137 MHz**, not the 220 MHz Yosys estimate or
the 300 MHz constraint. Action: raise `CLOCK_PERIOD` to ~7.5 ns (133 MHz) as the new
sign-off target and remove the clock-frequency-driven micro-pipelining (the registers
added purely to chase 300 MHz) so the MAC datapath has fewer, shorter stages. This
also cuts the clock-tree load that currently burns **1.32 W / 32.8%** of total power
(`38-openroad-stamidpnr-2/power.rpt`).

## 2. Make local caching functional: add the control + shift logic to load, stage, and tile operands

The 288 FLOP/byte arithmetic intensity in C1 assumes GEMM-style weight/input reuse
that the current RTL does not yet realize (no working on-chip cache, so effective AI
collapses toward the 0.4996 FLOP/byte no-reuse figure). Action: implement the cache
controller and shift/select logic that loads a weight tile and the corresponding input
window once, holds them across the inner-product sweep, and advances the tile pointers
(input window slide + output accumulator flush) so each fetched byte feeds the full
16x16 MAC array instead of being re-fetched per MAC.

## 3. Cut routing congestion: lower placement density / enlarge the core so met1-met2 demand fits

Global routing aborted with `GRT-0116` after `GRT-0704` advised reducing the layer
adjustment from 30% to 22%; met1 and met2 sat at **34.5% / 41.6%** demand with
nonzero overflow (`39-openroad-globalrouting/openroad-globalrouting.log`). Action:
reduce core placement utilization (lower `FP_CORE_UTIL` / increase `DIE_AREA`) so met1
and met2 routing demand drops below the congestion threshold, and/or relax the routing
layer adjustment, then re-run detailed routing to confirm a DRC-clean, fully-routed
layout before any M4 measurement.

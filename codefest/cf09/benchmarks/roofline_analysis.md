# Roofline analysis (PROJECTED path)

The accelerator point sits at the C1 arithmetic intensity of 288 FLOP/byte and a
PROJECTED 112.64 GFLOP/s (16x16 array, 512 FLOP/cycle x 220 MHz), landing on the compute
roof, right of the ridge (AI 11.7), nominally compute-bound. As a projection, the issue is
not a measured gap but its dominant uncertainty: the assumed 220 MHz clock. That is a Yosys
pre-layout estimate, yet the latest place-and-route reports setup WNS of -4.01 ns at a
3.333 ns period, implying a ~7.3 ns critical path and a real frequency closer to ~137 MHz,
which would drop throughput to ~70 GFLOP/s. A second uncertainty is the 288 FLOP/byte
intensity itself: it assumes a working weight/input cache that does not yet exist, so the
effective AI could collapse toward the 0.4996 no-reuse value and pull the point left of the
ridge, into the memory-bound region. Converting this projection to a measurement requires a
timing-closed, fully-routed layout plus a cocotb cycle-accurate run reporting actual clock
period, MAC-array utilization, and sustained interface bandwidth.

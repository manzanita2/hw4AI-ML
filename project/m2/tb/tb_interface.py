"""cocotb harness for `interface_module` (M2 deliverable #4).

Per-feature tests against the AXI4-Lite regfile and AXI4-Stream
pass-through paths in [`interface.sv`](../rtl/interface.sv):

  Test                            Covers
  ------------------------------  -------------------------------------
  tb_interface_smoke              reset + idle outputs (FSMs in IDLE)
  tb_axil_scratch_loopback        write + read SCRATCH @ 0x10  [rubric]
  tb_axil_ctrl_start_pulse        CTRL.START -> 1-cycle cfg_start pulse
  tb_axil_status_bits             STATUS.BUSY / STATUS.DONE tracking
  tb_axil_done_latch_clear        CTRL.START clears sticky DONE
  tb_axil_unimplemented_addr      write + read @ 0x08 returns OKAY / 0
  tb_axil_wstrb                   per-byte strobe mask honored
  tb_axis_ingress_passthrough     s_axis_* mirrors to act_*
  tb_axis_egress_passthrough      res_* mirrors to m_axis_*

Filename mirrors the DUT with a `tb_` prefix (interface.sv ->
tb_interface.py); the SV top module is named `interface_module` because
`interface` is an IEEE-1800 reserved keyword (see the Makefile mapping).

Run:
    make TEST=interface          # run this testbench
    make m2-log                  # regenerate sim/interface_run.log
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


CLK_PERIOD_NS = 10  # 100 MHz in sim; real target is 300 MHz

# Register map -- byte addresses, must match the table in interface.sv
# lines 88-112.
ADDR_CTRL    = 0x00
ADDR_STATUS  = 0x04
ADDR_SCRATCH = 0x10

# STATUS bit positions
STATUS_BUSY_BIT = 0
STATUS_DONE_BIT = 1

# AXI response codes
AXIL_OKAY = 0b00


# ============================================================================
# Helpers
# ============================================================================

def _zero_all_inputs(dut) -> None:
    """Drive every input port to a deterministic idle value.

    Covers the AXI4-Lite master side, the AXIS upstream master, the AXIS
    downstream slave's tready, and the compute_core stub side
    (act_ready / res_* / status_busy / status_done).
    """
    # AXI4-Lite master (bus side)
    dut.s_axil_awaddr.value  = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value   = 0
    dut.s_axil_wstrb.value   = 0
    dut.s_axil_wvalid.value  = 0
    dut.s_axil_bready.value  = 0
    dut.s_axil_araddr.value  = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value  = 0

    # AXIS upstream master (ingress)
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0

    # AXIS downstream slave (egress)
    dut.m_axis_tready.value = 0

    # compute_core stub side
    dut.act_ready.value   = 0
    dut.res_data.value    = 0
    dut.res_valid.value   = 0
    dut.res_last.value    = 0
    dut.status_busy.value = 0
    dut.status_done.value = 0


async def _reset(dut) -> None:
    """4-cycle synchronous reset; leaves FSMs in IDLE with rst = 0."""
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await Timer(1, unit="ns")  # let combinational settle so reads sample post-rst values


async def axil_write(dut, addr: int, data: int, wstrb: int = 0xF) -> int:
    """One complete AXI4-Lite write transaction.

    Drives AW + W simultaneously, waits for the slave's awready/wready to
    be observed high (W_IDLE), takes the handshake clock edge, deasserts
    AW + W, raises bready, waits for bvalid, samples bresp, takes the B
    handshake edge, deasserts bready. Returns bresp.
    """
    dut.s_axil_awaddr.value  = addr
    dut.s_axil_wdata.value   = data
    dut.s_axil_wstrb.value   = wstrb
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wvalid.value  = 1

    while True:
        await Timer(1, unit="ns")
        if int(dut.s_axil_awready.value) and int(dut.s_axil_wready.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value  = 0

    dut.s_axil_bready.value = 1
    while True:
        await Timer(1, unit="ns")
        if int(dut.s_axil_bvalid.value):
            break
        await RisingEdge(dut.clk)
    bresp = int(dut.s_axil_bresp.value)
    await RisingEdge(dut.clk)
    dut.s_axil_bready.value = 0
    return bresp


async def axil_read(dut, addr: int) -> tuple[int, int]:
    """One complete AXI4-Lite read transaction.

    Drives AR + rready, waits for arready (R_IDLE), takes the AR
    handshake edge, deasserts AR, waits for rvalid, samples rdata + rresp,
    takes the R handshake edge, deasserts rready. Returns (rdata, rresp).
    """
    dut.s_axil_araddr.value  = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value  = 1

    while True:
        await Timer(1, unit="ns")
        if int(dut.s_axil_arready.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axil_arvalid.value = 0

    while True:
        await Timer(1, unit="ns")
        if int(dut.s_axil_rvalid.value):
            break
        await RisingEdge(dut.clk)
    rdata = int(dut.s_axil_rdata.value)
    rresp = int(dut.s_axil_rresp.value)
    await RisingEdge(dut.clk)
    dut.s_axil_rready.value = 0
    return rdata, rresp


# ============================================================================
# Test 1: smoke -- reset leaves FSMs in IDLE and bus outputs at idle values
# ============================================================================
@cocotb.test()
async def tb_interface_smoke(dut):
    """Reset; verify both AXI-Lite FSMs idle and all outputs are sane.

    In W_IDLE / R_IDLE, awready / wready / arready are combinationally 1
    (slave is open for business). bvalid / rvalid / m_axis_tvalid /
    cfg_start are all 0. s_axis_tready follows the (driven-low) act_ready,
    so it should also be 0 here.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    checks = [
        ("s_axil_awready",  int(dut.s_axil_awready.value),  1),
        ("s_axil_wready",   int(dut.s_axil_wready.value),   1),
        ("s_axil_bvalid",   int(dut.s_axil_bvalid.value),   0),
        ("s_axil_arready",  int(dut.s_axil_arready.value),  1),
        ("s_axil_rvalid",   int(dut.s_axil_rvalid.value),   0),
        ("m_axis_tvalid",   int(dut.m_axis_tvalid.value),   0),
        ("m_axis_tlast",    int(dut.m_axis_tlast.value),    0),
        ("cfg_start",       int(dut.cfg_start.value),       0),
        ("s_axis_tready",   int(dut.s_axis_tready.value),   0),  # mirrors act_ready=0
        ("w_state",         int(dut.w_state.value),         0),  # W_IDLE
        ("r_state",         int(dut.r_state.value),         0),  # R_IDLE
    ]

    fails = [(name, got, exp) for name, got, exp in checks if got != exp]
    for name, got, exp in checks:
        marker = "OK  " if (name, got, exp) not in fails else "FAIL"
        dut._log.info(f"  {marker} {name:18s} = {got}  (expect {exp})")

    if fails:
        for name, got, exp in fails:
            dut._log.error(f"  MISS {name}: got {got}, expected {exp}")
        assert False, f"smoke: {len(fails)} idle-value mismatches"

    dut._log.info("PASS: interface_module smoke (reset + idle outputs)")


# ============================================================================
# Test 2: SCRATCH register write + read loopback (rubric checkboxes #1, #2)
# ============================================================================
@cocotb.test()
async def tb_axil_scratch_loopback(dut):
    """Complete write + read transaction: write 0xDEADBEEF to SCRATCH,
    read it back, verify value and bresp/rresp = OKAY. This single test
    independently satisfies the M2 PDF deliverable #4 checkboxes #1 and #2.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    payload = 0xDEADBEEF

    bresp = await axil_write(dut, ADDR_SCRATCH, payload)
    assert bresp == AXIL_OKAY, f"write bresp: got 0x{bresp:X}, expected 0x{AXIL_OKAY:X}"
    dut._log.info(f"  OK   write SCRATCH = 0x{payload:08X}, bresp = 0x{bresp:X}")

    rdata, rresp = await axil_read(dut, ADDR_SCRATCH)
    assert rresp == AXIL_OKAY, f"read rresp: got 0x{rresp:X}, expected 0x{AXIL_OKAY:X}"
    assert rdata == payload, f"read rdata: got 0x{rdata:08X}, expected 0x{payload:08X}"
    dut._log.info(f"  OK   read  SCRATCH = 0x{rdata:08X}, rresp = 0x{rresp:X}")

    dut._log.info("PASS: SCRATCH loopback (write + read transaction)")


# ============================================================================
# Test 3: CTRL.START write fires a 1-cycle cfg_start pulse
# ============================================================================
@cocotb.test()
async def tb_axil_ctrl_start_pulse(dut):
    """A write of CTRL.START = 1 must drive cfg_start high for exactly
    one cycle. Mirrors compute_core.sv's >=1 cycle pulse contract.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    high_cycles: list[int] = []

    async def monitor():
        for _ in range(16):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if int(dut.cfg_start.value):
                high_cycles.append(len(high_cycles))

    mon = cocotb.start_soon(monitor())
    bresp = await axil_write(dut, ADDR_CTRL, 0x1)
    assert bresp == AXIL_OKAY
    await mon

    dut._log.info(f"  cfg_start observed high in {len(high_cycles)} cycle(s) of 16")
    assert len(high_cycles) == 1, (
        f"expected exactly 1 cycle of cfg_start, observed {len(high_cycles)}"
    )

    dut._log.info("PASS: CTRL.START -> cfg_start pulses for exactly 1 cycle")


# ============================================================================
# Test 4: STATUS register tracks status_busy (combinational) and
# status_done (sticky DONE latch)
# ============================================================================
@cocotb.test()
async def tb_axil_status_bits(dut):
    """STATUS bit 0 mirrors status_busy combinationally; bit 1 latches
    a status_done pulse and stays sticky until cleared.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    # Phase 1: status_busy = 1, status_done = 0 -> STATUS = 0x01
    dut.status_busy.value = 1
    await ClockCycles(dut.clk, 1)
    rdata, _ = await axil_read(dut, ADDR_STATUS)
    busy = (rdata >> STATUS_BUSY_BIT) & 1
    done = (rdata >> STATUS_DONE_BIT) & 1
    dut._log.info(f"  phase 1: STATUS = 0x{rdata:08X}  (BUSY={busy}, DONE={done})")
    assert busy == 1, f"phase 1 BUSY: got {busy}, expected 1"
    assert done == 0, f"phase 1 DONE: got {done}, expected 0"

    # Phase 2: drop status_busy, pulse status_done for 1 cycle -> DONE sticks
    dut.status_busy.value = 0
    dut.status_done.value = 1
    await RisingEdge(dut.clk)
    dut.status_done.value = 0
    await Timer(1, unit="ns")

    rdata, _ = await axil_read(dut, ADDR_STATUS)
    busy = (rdata >> STATUS_BUSY_BIT) & 1
    done = (rdata >> STATUS_DONE_BIT) & 1
    dut._log.info(f"  phase 2: STATUS = 0x{rdata:08X}  (BUSY={busy}, DONE={done})")
    assert busy == 0, f"phase 2 BUSY: got {busy}, expected 0"
    assert done == 1, f"phase 2 DONE: got {done}, expected 1 (sticky after pulse)"

    # Phase 3: re-raise status_busy; DONE is still latched -> STATUS = 0x03
    dut.status_busy.value = 1
    await ClockCycles(dut.clk, 1)
    rdata, _ = await axil_read(dut, ADDR_STATUS)
    busy = (rdata >> STATUS_BUSY_BIT) & 1
    done = (rdata >> STATUS_DONE_BIT) & 1
    dut._log.info(f"  phase 3: STATUS = 0x{rdata:08X}  (BUSY={busy}, DONE={done})")
    assert busy == 1, f"phase 3 BUSY: got {busy}, expected 1"
    assert done == 1, f"phase 3 DONE: got {done}, expected 1 (still latched)"

    dut._log.info("PASS: STATUS.BUSY combinational, STATUS.DONE sticky")


# ============================================================================
# Test 5: CTRL.START write clears the sticky DONE latch
# ============================================================================
@cocotb.test()
async def tb_axil_done_latch_clear(dut):
    """Set DONE via a status_done pulse, verify it's latched, then write
    CTRL.START = 1 and verify DONE clears (clear-over-set priority for
    next-tile semantics).
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    # Set DONE via a one-cycle status_done pulse.
    dut.status_done.value = 1
    await RisingEdge(dut.clk)
    dut.status_done.value = 0
    await Timer(1, unit="ns")

    rdata, _ = await axil_read(dut, ADDR_STATUS)
    done = (rdata >> STATUS_DONE_BIT) & 1
    dut._log.info(f"  before clear: STATUS.DONE = {done}  (expect 1)")
    assert done == 1, "DONE failed to set after status_done pulse"

    # Clear DONE by writing CTRL.START = 1.
    bresp = await axil_write(dut, ADDR_CTRL, 0x1)
    assert bresp == AXIL_OKAY

    rdata, _ = await axil_read(dut, ADDR_STATUS)
    done = (rdata >> STATUS_DONE_BIT) & 1
    dut._log.info(f"  after  clear: STATUS.DONE = {done}  (expect 0)")
    assert done == 0, "DONE failed to clear after CTRL.START write"

    dut._log.info("PASS: CTRL.START write clears sticky DONE")


# ============================================================================
# Test 6: writes / reads to unimplemented addresses respond OKAY with
# zero data and do not perturb the regfile
# ============================================================================
@cocotb.test()
async def tb_axil_unimplemented_addr(dut):
    """Unimplemented address (0x08) must return OKAY for both write and
    read. The write must not leak into SCRATCH or any other register.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    UNIMPL = 0x08

    bresp = await axil_write(dut, UNIMPL, 0x12345678)
    dut._log.info(f"  write @ 0x{UNIMPL:02X}: bresp = 0x{bresp:X}  (expect OKAY=0x0)")
    assert bresp == AXIL_OKAY, f"unimpl write bresp: got 0x{bresp:X}, expected OKAY"

    rdata, rresp = await axil_read(dut, UNIMPL)
    dut._log.info(f"  read  @ 0x{UNIMPL:02X}: rdata = 0x{rdata:08X}, rresp = 0x{rresp:X}")
    assert rresp == AXIL_OKAY, f"unimpl read rresp: got 0x{rresp:X}, expected OKAY"
    assert rdata == 0, f"unimpl read rdata: got 0x{rdata:08X}, expected 0"

    # And the write must not have leaked into SCRATCH.
    rdata, _ = await axil_read(dut, ADDR_SCRATCH)
    dut._log.info(f"  SCRATCH after unimpl write = 0x{rdata:08X}  (expect 0x0)")
    assert rdata == 0, f"unimpl write leaked into SCRATCH: got 0x{rdata:08X}"

    dut._log.info("PASS: unimplemented address returns OKAY/0, no regfile leak")


# ============================================================================
# Test 7: per-byte wstrb mask honored on SCRATCH writes
# ============================================================================
@cocotb.test()
async def tb_axil_wstrb(dut):
    """Preload SCRATCH = 0xFFFFFFFF, then write 0x12345678 with wstrb =
    0b0011 (low two bytes only). Expect 0xFFFF5678 on read-back: bytes 0
    and 1 take the new value, bytes 2 and 3 are unchanged.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    # Preload all 1's.
    bresp = await axil_write(dut, ADDR_SCRATCH, 0xFFFFFFFF, wstrb=0xF)
    assert bresp == AXIL_OKAY
    rdata, _ = await axil_read(dut, ADDR_SCRATCH)
    dut._log.info(f"  preload: SCRATCH = 0x{rdata:08X}  (expect 0xFFFFFFFF)")
    assert rdata == 0xFFFFFFFF

    # Partial write: only bytes 0 and 1.
    bresp = await axil_write(dut, ADDR_SCRATCH, 0x12345678, wstrb=0b0011)
    assert bresp == AXIL_OKAY

    rdata, _ = await axil_read(dut, ADDR_SCRATCH)
    expected = 0xFFFF5678
    dut._log.info(
        f"  after partial write (wstrb=0b0011): SCRATCH = 0x{rdata:08X}  "
        f"(expect 0x{expected:08X})"
    )
    assert rdata == expected, (
        f"wstrb mask not honored: got 0x{rdata:08X}, expected 0x{expected:08X}"
    )

    dut._log.info("PASS: per-byte wstrb mask honored on SCRATCH")


# ============================================================================
# Test 8: AXIS ingress (s_axis_*) is a combinational pass-through to act_*
# ============================================================================
@cocotb.test()
async def tb_axis_ingress_passthrough(dut):
    """Drive s_axis_t* + act_ready; verify act_data / act_valid /
    act_last and s_axis_tready mirror combinationally. Then drop
    act_ready and verify s_axis_tready follows on the same cycle.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    # 256-bit pattern: 0xDEADBEEFCAFEBABE replicated 4 times.
    PATTERN = 0xDEADBEEFCAFEBABE_DEADBEEFCAFEBABE_DEADBEEFCAFEBABE_DEADBEEFCAFEBABE

    dut.s_axis_tdata.value  = PATTERN
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value  = 1
    dut.act_ready.value     = 1

    await Timer(1, unit="ns")  # let combinational pass-through settle

    checks = [
        ("act_data",       int(dut.act_data.value),      PATTERN),
        ("act_valid",      int(dut.act_valid.value),     1),
        ("act_last",       int(dut.act_last.value),      1),
        ("s_axis_tready",  int(dut.s_axis_tready.value), 1),  # mirrors act_ready=1
    ]
    fails = [c for c in checks if c[1] != c[2]]
    for name, got, exp in checks:
        marker = "OK  " if (name, got, exp) not in fails else "FAIL"
        if name == "act_data":
            dut._log.info(f"  {marker} {name:14s} = 0x{got:064X}  (expect 0x{exp:064X})")
        else:
            dut._log.info(f"  {marker} {name:14s} = {got}  (expect {exp})")
    assert not fails, f"{len(fails)} ingress mirror mismatches"

    # Stability: cycle the clock once and re-sample. Pure combinational
    # paths must hold across edges as long as inputs hold.
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.act_data.value)     == PATTERN
    assert int(dut.act_valid.value)    == 1
    assert int(dut.act_last.value)     == 1
    assert int(dut.s_axis_tready.value) == 1
    dut._log.info("  OK   ingress pass-through stable across clock edge")

    # Backpressure: drop act_ready, expect s_axis_tready to fall same cycle.
    dut.act_ready.value = 0
    await Timer(1, unit="ns")
    assert int(dut.s_axis_tready.value) == 0, (
        f"s_axis_tready failed to follow act_ready=0  "
        f"(s_axis_tready={int(dut.s_axis_tready.value)})"
    )
    dut._log.info("  OK   s_axis_tready follows act_ready -> 0 (backpressure)")

    dut._log.info("PASS: AXIS ingress combinational pass-through")


# ============================================================================
# Test 9: AXIS egress (res_*) is a combinational pass-through to m_axis_*
# ============================================================================
@cocotb.test()
async def tb_axis_egress_passthrough(dut):
    """Mirror of test 8 with the data direction reversed: drive res_* +
    m_axis_tready, sample m_axis_t* and res_ready.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    _zero_all_inputs(dut)
    await _reset(dut)

    # Distinct pattern from the ingress test so swap bugs would surface.
    PATTERN = 0x0123456789ABCDEF_0123456789ABCDEF_0123456789ABCDEF_0123456789ABCDEF

    dut.res_data.value      = PATTERN
    dut.res_valid.value     = 1
    dut.res_last.value      = 1
    dut.m_axis_tready.value = 1

    await Timer(1, unit="ns")

    checks = [
        ("m_axis_tdata",   int(dut.m_axis_tdata.value),   PATTERN),
        ("m_axis_tvalid",  int(dut.m_axis_tvalid.value),  1),
        ("m_axis_tlast",   int(dut.m_axis_tlast.value),   1),
        ("res_ready",      int(dut.res_ready.value),      1),  # mirrors m_axis_tready=1
    ]
    fails = [c for c in checks if c[1] != c[2]]
    for name, got, exp in checks:
        marker = "OK  " if (name, got, exp) not in fails else "FAIL"
        if name == "m_axis_tdata":
            dut._log.info(f"  {marker} {name:14s} = 0x{got:064X}  (expect 0x{exp:064X})")
        else:
            dut._log.info(f"  {marker} {name:14s} = {got}  (expect {exp})")
    assert not fails, f"{len(fails)} egress mirror mismatches"

    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.m_axis_tdata.value)  == PATTERN
    assert int(dut.m_axis_tvalid.value) == 1
    assert int(dut.m_axis_tlast.value)  == 1
    assert int(dut.res_ready.value)     == 1
    dut._log.info("  OK   egress pass-through stable across clock edge")

    # Backpressure: drop m_axis_tready, expect res_ready to fall same cycle.
    dut.m_axis_tready.value = 0
    await Timer(1, unit="ns")
    assert int(dut.res_ready.value) == 0, (
        f"res_ready failed to follow m_axis_tready=0  "
        f"(res_ready={int(dut.res_ready.value)})"
    )
    dut._log.info("  OK   res_ready follows m_axis_tready -> 0 (backpressure)")

    dut._log.info("PASS: AXIS egress combinational pass-through")

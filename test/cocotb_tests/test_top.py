"""Top-level smoke tests kept independent of future protocol programs."""

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import reset_top, start_clock


@cocotb.test()
async def test_safe_inactive_outputs(dut):
    """A reset engine must leave protocol pins undriven."""
    await start_clock(dut)
    await reset_top(dut)

    dut.ui_in.value = 0x14
    dut.uio_in.value = 0x1E
    await ClockCycles(dut.clk, 1)

    assert dut.uo_out.value == 0
    assert dut.uio_out.value == 0
    assert dut.uio_oe.value == 0

"""Top-level smoke tests kept independent of future protocol programs."""

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import host_command, reset_top, start_clock


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


async def set_address(dut, address: int) -> None:
    await host_command(dut, 1, address)
    await host_command(dut, 2, address >> 4)
    await host_command(dut, 3, address >> 8)


@cocotb.test()
async def test_host_program_readback(dut):
    """Command B returns the byte at the current address, not the previous access."""
    await start_clock(dut)
    await reset_top(dut)

    image = {0x000: 0x5A, 0x001: 0xC3, 0x17F: 0x81, 0x3FF: 0x3C}
    for address, byte in image.items():
        await set_address(dut, address)
        await host_command(dut, 4, byte)
        await host_command(dut, 5, byte >> 4)

    for address, byte in [*image.items(), *reversed(image.items())]:
        await set_address(dut, address)
        await host_command(dut, 0xB)
        assert int(dut.uo_out.value) == byte, f"read {address:#05x}"
        # The byte stays on the pins until the next host response.
        await ClockCycles(dut.clk, 3)
        assert int(dut.uo_out.value) == byte, f"held {address:#05x}"

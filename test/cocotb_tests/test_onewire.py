"""1-Wire master demo (Phase 10): reset + presence + write + read, one core."""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level,
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
    wait_until_halted,
)
from cocotb_tests.reference.programs import (
    OW_PIN,
    onewire_write_read_program,
)


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_onewire_reset_write_read(dut):
    await start_clock(dut)
    await reset_top(dut)
    await load_program(dut, onewire_write_read_program())
    await push_tx(dut, 0xA5)
    dut.uio_in.value = 1  # pull-up
    await host_command(dut, 0x8, 1)

    # Wait for the reset pulse, then the release; answer with presence.
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, OW_PIN) == 0:
            break
    else:
        raise AssertionError("1-Wire reset pulse never driven")
    for _ in range(3000):
        await RisingEdge(dut.clk)
        if driven_level(dut, OW_PIN) is None:
            break
    else:
        raise AssertionError("1-Wire bus never released")
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.uio_in.value = 0  # presence pulse
    for _ in range(15):
        await RisingEdge(dut.clk)
    dut.uio_in.value = 1  # release back to pull-up

    await wait_until_halted(dut, timeout_cycles=8000)
    assert not status_running(await read_status(dut))
    assert driven_level(dut, 4) == 1, "presence marker not set"
    assert await pop_rx(dut) == 0x80, "read slot did not sample pull-up"

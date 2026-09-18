"""Streaming host aids (Phase 10): FIFO levels (0xC) + RX peek (0xD)."""

import cocotb

from cocotb_tests.common import (
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
    wait_until_halted,
)
from cocotb_tests.reference.programs import crc_usb16_setup, crc_feed, crc_finalize


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def read_levels(dut) -> int:
    await host_command(dut, 0xC)
    return int(dut.uo_out.value)


async def peek_rx(dut) -> int:
    await host_command(dut, 0xD)
    return int(dut.uo_out.value)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_fifo_levels_and_peek(dut):
    await start_clock(dut)
    await reset_top(dut)

    # Idle: {tx_full=0, rx_empty=1, tx=0, rx=0}.
    assert await read_levels(dut) == 0x40

    await host_command(dut, 0x6, 0xAA)
    await host_command(dut, 0x7, 0x0A)
    await host_command(dut, 0x6, 0xBB)
    await host_command(dut, 0x7, 0x0B)
    assert await read_levels(dut) == 0x50, "tx_level should read 2"

    # Push two RX bytes via a CRC finalize + double push.
    program = [*crc_usb16_setup(), *crc_feed(0x01), crc_finalize(), 0xA4, 0xA5, 0x01]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=4000)
    assert not status_running(await read_status(dut))

    assert await read_levels(dut) == 0x12, "tx=2 rx=2"
    lo_peek = await peek_rx(dut)
    assert await read_levels(dut) == 0x12, "peek must not consume"
    assert await pop_rx(dut) == lo_peek
    assert await read_levels(dut) == 0x11, "tx=2 rx=1"
    hi_peek = await peek_rx(dut)
    assert await pop_rx(dut) == hi_peek

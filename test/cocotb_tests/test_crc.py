"""CRC-32 tests (Phase 8): IEEE-802.3 residue via 0xE1 setup + 4-byte push."""

import binascii

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
    wait_until_halted,
)
from cocotb_tests.reference.programs import crc32_demo_program


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


async def run_crc32(dut, data: list[int]) -> int:
    await reset_top(dut)
    await load_program(dut, crc32_demo_program(data))
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=6000)
    assert not status_running(await read_status(dut))
    raw = [await pop_rx(dut) for _ in range(4)]
    return raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24)


@cocotb.test()
async def test_crc32_ieee_vector(dut):
    """CRC-32 of '123456789' must equal the IEEE check value 0xCBF43926."""
    await start_clock(dut)
    data = list(b"123456789")
    got = await run_crc32(dut, data)
    want = binascii.crc32(bytes(data)) & 0xFFFFFFFF
    assert want == 0xCBF43926
    assert got == want, f"got {got:#010x} want {want:#010x}"


@cocotb.test()
async def test_crc32_empty_and_short(dut):
    """Empty input gives 0x00000000; 0x00 matches zlib."""
    await start_clock(dut)
    assert await run_crc32(dut, []) == 0x00000000
    got = await run_crc32(dut, [0x00])
    want = binascii.crc32(bytes([0x00])) & 0xFFFFFFFF
    assert got == want, f"got {got:#010x} want {want:#010x}"


@cocotb.test()
async def test_cpu_crc_waits_for_action_crc_owner(dut):
    """A CPU feed after RUN_REGION cannot collide with the region feed."""
    from cocotb_tests.reference.programs import (
        HALT, ACT_CRC, action_delay, action_done, action_load_shift,
        action_word, prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        0xE1,  # CRC-32 IEEE setup
        *action_load_shift(0x12),
        *prog_action(0, action_word(ACT_CRC)),
        *prog_action(1, action_delay(80)),
        *prog_action(2, action_done()),
        *run_region(0),
        0xA2, 0x34,  # CPU CRC_FEED; must wait for region release
        wait_region(),
        0xA3, 0xA4, 0xA5, 0xE2, 0xE3, HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=6000)
    raw = [await pop_rx(dut) for _ in range(4)]
    got = sum(byte << (8 * i) for i, byte in enumerate(raw))
    want = binascii.crc32(bytes([0x12, 0x34])) & 0xFFFFFFFF
    assert got == want, f"CRC collision: got {got:#010x}, want {want:#010x}"

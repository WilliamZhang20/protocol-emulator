"""Side-set tests (Phase 6).

Gate-level safe: host commands plus `uio_*` pins and status `0xA` only.
"""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level,
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
)
from cocotb_tests.reference.programs import (
    HALT,
    gpio_oe,
    gpio_write,
    sideset,
    wait,
)

SIDE_PIN = 4
MAIN_PIN = 5


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


@cocotb.test()
async def test_sideset_applies_with_next_op(dut):
    """Side-set pin and the next op's pin transition on the same cycle."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(SIDE_PIN, 1),
        gpio_oe(MAIN_PIN, 1),
        gpio_write(SIDE_PIN, 0),
        gpio_write(MAIN_PIN, 0),
        *sideset(SIDE_PIN, 1),
        gpio_write(MAIN_PIN, 1),
        HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    side_at = main_at = None
    for cycle in range(500):
        await RisingEdge(dut.clk)
        if side_at is None and driven_level(dut, SIDE_PIN) == 1:
            side_at = cycle
        if main_at is None and driven_level(dut, MAIN_PIN) == 1:
            main_at = cycle
        if side_at is not None and main_at is not None:
            break
        if cycle % 48 == 47 and not status_running(await read_status(dut)):
            break
    assert side_at is not None and main_at is not None, "pins never went high"
    assert side_at == main_at, f"not simultaneous: side={side_at} main={main_at}"


@cocotb.test()
async def test_sideset_with_wait_starts_together(dut):
    """Side-set lands at WAIT start, not after it."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(SIDE_PIN, 1),
        gpio_write(SIDE_PIN, 0),
        *sideset(SIDE_PIN, 1),
        *wait(60),
        HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    first_high = None
    for cycle in range(500):
        await RisingEdge(dut.clk)
        if driven_level(dut, SIDE_PIN) == 1:
            first_high = cycle
            break
    assert first_high is not None, "side-set never applied"
    assert first_high < 30, f"side-set applied too late at {first_high}"

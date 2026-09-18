"""ALU + conditional branch tests (Phase 1-2).

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
    ALU_SUB,
    HALT,
    djnz,
    gpio_oe,
    gpio_write,
    jump_if_not_zero,
    jump_if_zero,
    reg_alu,
    reg_mov,
    reg_set,
)

PIN = 4


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def run_until_halt(dut, timeout: int = 3000) -> None:
    for cycle in range(timeout):
        await RisingEdge(dut.clk)
        if cycle % 48 == 47 and not status_running(await read_status(dut)):
            return
    raise AssertionError("engine did not halt")


@cocotb.test()
async def test_alu_sub_sets_zero_flag_jz_taken(dut):
    """R2 = R0 - R1 == 0 -> JZ skips the marker GPIO write."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(PIN, 1),
        gpio_write(PIN, 0),
        *reg_set(0, 5),
        *reg_set(1, 5),
        *reg_mov(2, 0),
        *reg_alu(ALU_SUB, 2, 1),
        *jump_if_zero(17),
        gpio_write(PIN, 1),  # skipped when zero flag works
        HALT,
    ]
    # Patch jump target: HALT index
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await run_until_halt(dut)
    assert driven_level(dut, PIN) == 0


@cocotb.test()
async def test_alu_sub_clears_zero_flag_jnz_taken(dut):
    """R2 = 7 - 5 != 0 -> JNZ skips the marker GPIO write."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(PIN, 1),
        gpio_write(PIN, 0),
        *reg_set(0, 7),
        *reg_set(1, 5),
        *reg_mov(2, 0),
        *reg_alu(ALU_SUB, 2, 1),
        *jump_if_not_zero(17),
        gpio_write(PIN, 1),  # skipped when JNZ works
        HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await run_until_halt(dut)
    assert driven_level(dut, PIN) == 0


@cocotb.test()
async def test_djnz_loop_runs_three_times(dut):
    """DJNZ R0 loops exactly 3 times, toggling the pin each iteration."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(PIN, 1),
        gpio_write(PIN, 0),
        *reg_set(0, 3),
        gpio_write(PIN, 1),  # loop body starts here (index 5)
        gpio_write(PIN, 0),
        *djnz(0, 5),
        HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    rises = 0
    prev = 0
    for _ in range(3000):
        await RisingEdge(dut.clk)
        lvl = driven_level(dut, PIN)
        if lvl is not None:
            if prev == 0 and lvl == 1:
                rises += 1
            prev = lvl
        if _ % 48 == 47 and not status_running(await read_status(dut)):
            break
    assert rises == 3, f"expected 3 loop iterations, saw {rises}"

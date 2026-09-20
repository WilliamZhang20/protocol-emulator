"""Timestamp + event-stamp tests (Phase 3-4).

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
    ALU_ADD,
    EV_PIN_RISE,
    EVENT_DETAIL,
    HALT,
    arm_edges,
    event_stamp,
    get_time,
    gpio_oe,
    gpio_write,
    reg_alu,
    reg_set,
    wait,
    wait_until,
)

PIN = 4
EDGE_PIN = 6


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_wait_until_schedules_pin(dut):
    """GET_TIME + ADD + WAIT_UNTIL fires ~delta cycles after capture."""
    await start_clock(dut)
    await reset_top(dut)
    delta = 150
    program = [
        gpio_oe(PIN, 1),
        gpio_write(PIN, 0),
        *get_time(0),
        *reg_set(1, delta),
        *reg_alu(ALU_ADD, 0, 1),
        *wait_until(0),
        gpio_write(PIN, 1),
        HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    fired_at = None
    for cycle in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, PIN) == 1:
            fired_at = cycle
            break
    assert fired_at is not None, "WAIT_UNTIL never fired"
    assert fired_at >= delta, f"fired too early at {fired_at}"
    assert fired_at <= delta + 250, f"fired too late at {fired_at}"
    for _ in range(200):
        await RisingEdge(dut.clk)
        if _ % 48 == 47 and not status_running(await read_status(dut)):
            break
    assert not status_running(await read_status(dut))


@cocotb.test()
async def test_event_stamp_captures_edge(dut):
    """EVENT_STAMP triple reports time_lo/time_hi/cause with RISE set."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(EDGE_PIN, 0),
        *arm_edges(rise_mask=1 << EDGE_PIN, fall_mask=0),
        *wait(30),
        event_stamp(),
        event_stamp(),
        event_stamp(),
        EVENT_DETAIL,
        HALT,
    ]
    await load_program(dut, program)
    dut.uio_in.value = 0
    await host_command(dut, 0x8, 1)
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.uio_in.value = 1 << EDGE_PIN
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if _ % 48 == 47 and not status_running(await read_status(dut)):
            break
    assert not status_running(await read_status(dut))
    time_lo = await pop_rx(dut)
    time_hi = await pop_rx(dut)
    cause = await pop_rx(dut)
    detail = await pop_rx(dut)
    assert detail == (0x20 | EDGE_PIN), f"edge detail {detail:#x}"
    assert cause & EV_PIN_RISE, f"cause {cause:#x} missing RISE bit"
    assert (time_lo | (time_hi << 8)) > 0, "timestamp did not advance"

@cocotb.test()
async def test_wait_until_across_counter_wrap(dut):
    """An absolute deadline just past 0xffff waits through the wrap."""
    await start_clock(dut)
    await reset_top(dut)
    delta = 200
    program = [
        gpio_oe(PIN, 1), gpio_write(PIN, 0),
        *wait(65400),
        *get_time(0), *reg_set(1, delta), *reg_alu(ALU_ADD, 0, 1),
        *wait_until(0), gpio_write(PIN, 1), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    fired_at = None
    for cycle in range(67000):
        await RisingEdge(dut.clk)
        if driven_level(dut, PIN) == 1:
            fired_at = cycle
            break
    assert fired_at is not None, "wrapped deadline never fired"
    assert fired_at >= 65400 + delta, f"wrapped deadline fired early at {fired_at}"

@cocotb.test()
async def test_zero_async_timer_posts_completion(dut):
    """A zero-length timer posts one completion instead of hanging busy."""
    from cocotb_tests.reference.programs import EV_TIMER_DONE, start_timer, wait_event

    await start_clock(dut)
    await reset_top(dut)
    await load_program(dut, [*start_timer(0), *wait_event(EV_TIMER_DONE), HALT])
    await host_command(dut, 0x8, 1)
    for cycle in range(300):
        await RisingEdge(dut.clk)
        if cycle % 32 == 31 and not status_running(await read_status(dut)):
            break
    assert not status_running(await read_status(dut)), "zero timer did not complete"

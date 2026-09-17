"""Orchestration tests: nonblocking START_XFER, WAIT_EVENT, overlapped timer."""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.reference.programs import (
    EV_PIN_RISE,
    EV_TIMER_DONE,
    EV_XFER_DONE,
    HALT,
    TX_LOAD,
    arm_edges,
    gpio_oe,
    gpio_write,
    overlap_xfer_timer_program,
    start_timer,
    start_xfer,
    wait_event,
)

FLAG = 4
MOSI, MISO, SCLK = 0, 1, 2


async def host_command(dut, command: int, payload: int = 0) -> None:
    dut.ui_in.value = ((command & 0xF) << 4) | (payload & 0xF)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


async def start_engine(dut) -> None:
    await host_command(dut, 0x8, 1)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


def _driven(dut, pin: int) -> int | None:
    oe = int(dut.uio_oe.value)
    out = int(dut.uio_out.value)
    if (oe >> pin) & 1:
        return (out >> pin) & 1
    return None


@cocotb.test()
async def test_nonblocking_xfer_vm_overlap(dut):
    """VM toggles a flag while bit-xfer runs; WAIT_EVENT joins both resources."""
    await start_clock(dut)
    await reset_top(dut)
    await load_program(dut, overlap_xfer_timer_program(half_period=2, timer_cycles=60))
    await push_tx(dut, 0xA5)
    dut.uio_in.value = 0
    await start_engine(dut)

    saw_flag_high_during_xfer = False
    for _ in range(2000):
        await RisingEdge(dut.clk)
        busy = int(dut.user_project.core.bit_xfer.busy.value)
        flag = _driven(dut, FLAG)
        if busy and flag == 1:
            saw_flag_high_during_xfer = True
        if int(dut.user_project.core.state.value) == 9:
            break
    assert saw_flag_high_during_xfer, "VM did not run while XFER was busy"
    assert int(dut.user_project.core.events.pending.value) == 0


@cocotb.test()
async def test_wait_event_or_timeout(dut):
    """WAIT_EVENT(XFER|TIMER) returns on the first of the two."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(MOSI, 1),
        gpio_oe(SCLK, 1),
        gpio_write(SCLK, 0),
        TX_LOAD,
        *start_xfer(clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=4),
        *start_timer(5),  # timer finishes first
        *wait_event(EV_XFER_DONE | EV_TIMER_DONE),
        gpio_write(MOSI, 1),  # marker: reached after OR wait
        *wait_event(EV_XFER_DONE),
        HALT,
    ]
    await load_program(dut, program)
    await push_tx(dut, 0x3C)
    await start_engine(dut)

    saw_marker_before_xfer_done = False
    for _ in range(3000):
        await RisingEdge(dut.clk)
        busy = int(dut.user_project.core.bit_xfer.busy.value)
        marker = _driven(dut, MOSI)
        # After OR wait, program drives MOSI high while xfer may still be busy
        if busy and marker == 1:
            saw_marker_before_xfer_done = True
        if int(dut.user_project.core.state.value) == 9:
            break
    assert saw_marker_before_xfer_done


@cocotb.test()
async def test_edge_event_wake(dut):
    """ARM rising edge on pin 0 and WAIT_EVENT until the host toggles it."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(0, 0),
        *arm_edges(rise_mask=0x01, fall_mask=0x00),
        *wait_event(EV_PIN_RISE),
        HALT,
    ]
    await load_program(dut, program)
    dut.uio_in.value = 0
    await start_engine(dut)

    for _ in range(100):
        await RisingEdge(dut.clk)
    dut.uio_in.value = 1
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.user_project.core.state.value) == 9:
            return
    raise AssertionError("WAIT_EVENT did not wake on rising edge")


@cocotb.test()
async def test_gpio_ownership_blocks_vm(dut):
    """VM GPIO writes to XFER-owned pins are ignored while the engine runs."""
    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(MOSI, 1),
        gpio_oe(SCLK, 1),
        gpio_write(SCLK, 0),
        gpio_write(MOSI, 0),
        TX_LOAD,
        *start_xfer(clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=3),
        # Attempt to force MOSI high while XFER owns it — should not stick via VM path
        gpio_write(MOSI, 1),
        *wait_event(EV_XFER_DONE),
        HALT,
    ]
    await load_program(dut, program)
    await push_tx(dut, 0x00)  # all-zero MOSI from engine
    await start_engine(dut)

    saw_engine_drive_low = False
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if int(dut.user_project.core.bit_xfer.busy.value):
            if _driven(dut, MOSI) == 0:
                saw_engine_drive_low = True
        if int(dut.user_project.core.state.value) == 9:
            break
    assert saw_engine_drive_low

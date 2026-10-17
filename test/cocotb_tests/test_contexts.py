"""Context switching: every timer, shifter, counter, glue cell and pin cell
holds two configurations, and a fabric line picks the active one. Phase
changes happen in the fabric with the controller idle; the tests check
them through the pins only."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    MODE_PUSH_PULL, Bus, Px8, glue, load_program, pin_level, push_tx, shifter_active,
    shifter_out, shifter_stop, shifter_word, start_engine, timer_out, timer_rise, truth,
)

SELECT_PIN = 7
OUT_PIN = 0
UART_PIN = 1
BIT = 24


async def half_periods(dut, bus: Bus, pin: int, count: int) -> list[int]:
    lengths, level, run = [], bus.level(pin), 0
    while len(lengths) < count:
        await RisingEdge(dut.clk)
        now = bus.level(pin)
        run += 1
        if now != level:
            lengths.append(run)
            level, run = now, 0
    return lengths


@cocotb.test()
async def test_pin_selects_timer_context(dut):
    """Timer 0 toggles pin 0 every 10 cycles in context 0 and every 25 in
    context 1; an input pin selects the context while the controller
    idles. The new period appears within one period of the switch."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[SELECT_PIN] = 0
    p = Px8()
    p.write_contexts(3)
    p.pin_cell(OUT_PIN, src=timer_out(0), mode=MODE_PUSH_PULL)
    p.write_contexts(1)
    p.timer(0, reload=9, phase=9, start=1)
    p.write_contexts(2)
    p.timer(0, reload=24, phase=24, start=1)
    p.write_contexts(1)
    p.context_select(pin_level(SELECT_PIN))
    p.arm()
    p.idle_forever()
    await load_program(dut, p.assemble())
    await start_engine(dut)
    await ClockCycles(dut.clk, 300)
    assert (await half_periods(dut, bus, OUT_PIN, 7))[1:] == [10] * 6
    bus.drive[SELECT_PIN] = 1
    seen = await half_periods(dut, bus, OUT_PIN, 8)
    assert seen[2:] == [25] * 6, seen
    bus.drive[SELECT_PIN] = 0
    seen = await half_periods(dut, bus, OUT_PIN, 8)
    assert seen[2:] == [10] * 6, seen


async def uart_frame(dut, bus: Bus, parity: bool) -> tuple[int, int | None]:
    """Reference receiver: (byte, parity bit or None); checks the stop bit."""
    while bus.level(UART_PIN):
        await RisingEdge(dut.clk)
    await ClockCycles(dut.clk, BIT // 2)
    value = 0
    for i in range(8):
        await ClockCycles(dut.clk, BIT)
        value |= bus.level(UART_PIN) << i
    par = None
    if parity:
        await ClockCycles(dut.clk, BIT)
        par = bus.level(UART_PIN)
    await ClockCycles(dut.clk, BIT)
    assert bus.level(UART_PIN) == 1, "missing stop bit"
    return value, par


def uart_contexts(select_line: int, toggle: bool) -> list[int]:
    """8N1 in context 0, 8E1 in context 1, on one shifter and timer. With
    `toggle`, glue cell 0 flips the context at the end of every word; a
    gapless next frame has just begun then and takes the new framing."""
    p = Px8()
    p.write_contexts(3)
    p.timer(0, reload=BIT - 1, phase=BIT - 3, pulse=True,
            start=shifter_active(0), stop=shifter_stop(0))
    p.pin_cell(UART_PIN, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.shifter_io(0, pull=True)
    if toggle:
        p.glue(0, truth(lambda word, q: q != word, 2), [shifter_word(0), glue(0)],
               registered=True)
    p.write_contexts(1)
    p.shifter(0, pre=1, post=1, post_val=1, idle=1, shift=timer_rise(0))
    p.write_contexts(2)
    p.shifter(0, pre=1, post=1, post_val=1, parity=1, idle=1, shift=timer_rise(0))
    p.write_contexts(1)
    p.context_select(select_line)
    p.arm()
    p.idle_forever()
    return p.assemble()


def even(byte: int) -> int:
    return bin(byte).count("1") & 1


@cocotb.test()
async def test_pin_selects_uart_framing(dut):
    """The same shifter sends 8N1 or 8E1 depending on an input pin; the
    framing follows the pin from one byte to the next."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[SELECT_PIN] = 0
    await load_program(dut, uart_contexts(pin_level(SELECT_PIN), toggle=False))
    await start_engine(dut)
    for byte, parity in [(0x5A, False), (0xC3, True), (0x01, False), (0x7F, True)]:
        bus.drive[SELECT_PIN] = int(parity)
        await ClockCycles(dut.clk, 10)
        await push_tx(dut, byte)
        assert await uart_frame(dut, bus, parity) == (byte, even(byte) if parity else None)


@cocotb.test()
async def test_fabric_alternates_framing(dut):
    """A glue-cell flip-flop toggles the context after every frame, so the
    framing alternates 8N1, 8E1, 8N1, ... with no controller involvement,
    even for back-to-back bytes."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, uart_contexts(glue(0), toggle=True))
    for byte in [0x11, 0x22, 0x33, 0x44]:
        await push_tx(dut, byte)
    await start_engine(dut)
    for i, byte in enumerate([0x11, 0x22, 0x33, 0x44]):
        parity = i % 2 == 1
        assert await uart_frame(dut, bus, parity) == (byte, even(byte) if parity else None)

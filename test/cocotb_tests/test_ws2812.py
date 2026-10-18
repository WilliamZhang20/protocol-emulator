"""WS2812 (NeoPixel) transmitter: every bit's period and high time exact."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, push_packet, start_engine
from cocotb_tests.protocols import WS2812_PIN, ws2812_transmit

# 40 MHz: 1.25 us bits, T0H 0.4 us, T1H 0.8 us (datasheet +-150 ns).
BIT, T0H, T1H = 50, 16, 32
CLOCK_NS = 25


async def record_pulses(dut, bus: Bus, pulses: list[tuple[int, int]]) -> None:
    """(rise cycle, high cycles) for every high pulse on the pin."""
    cycle, rise, previous = 0, None, bus.level(WS2812_PIN)
    while True:
        await RisingEdge(dut.clk)
        cycle += 1
        level = bus.level(WS2812_PIN)
        if level and not previous:
            rise = cycle
        if previous and not level and rise is not None:
            pulses.append((rise, cycle - rise))
        previous = level


def decode(pulses: list[tuple[int, int]], gaps: bool = False) -> list[int]:
    """Bytes from pulses, checking every timing against the design: bits
    of a byte exactly BIT apart; with `gaps` (a starved FIFO) a byte may
    start later, but never sooner, than one bit period after the last."""
    bits = []
    for index, (rise, high) in enumerate(pulses):
        assert high in (T0H, T1H), (index, high)
        if index:
            period = rise - pulses[index - 1][0]
            if gaps and index % 8 == 0:
                assert period >= BIT, ("bit period across a gap", index, period)
            else:
                assert period == BIT, ("bit period", index, period)
        bits.append(int(high == T1H))
    assert len(bits) % 8 == 0, len(bits)
    return [sum(b << (7 - i) for i, b in enumerate(bits[k:k + 8]))
            for k in range(0, len(bits), 8)]


async def transmit(dut, data: list[int]) -> list[tuple[int, int]]:
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    pulses: list[tuple[int, int]] = []
    cocotb.start_soon(record_pulses(dut, bus, pulses))
    await load_program(dut, ws2812_transmit(BIT, T0H, T1H))
    await start_engine(dut)
    await push_packet(dut, data)     # the host keeps ahead of the strip
    for _ in range(BIT * 8 * (len(data) + 2)):
        await RisingEdge(dut.clk)
    return pulses


@cocotb.test()
async def test_ws2812_three_leds(dut):
    """Three GRB pixels in one gapless burst, then the line rests low."""
    data = [0xFF, 0x00, 0xA5, 0x01, 0x80, 0x7E, 0x00, 0xFF, 0x3C]
    pulses = await transmit(dut, data)
    assert decode(pulses) == data
    assert bus_low_after(dut)


def bus_low_after(dut) -> bool:
    return ((int(dut.uio_out.value) >> WS2812_PIN) & 1) == 0


@cocotb.test()
async def test_ws2812_random_strip(dut):
    data = [random.Random(2812).randrange(256) for _ in range(12)]
    pulses = await transmit(dut, data)
    assert decode(pulses) == data


@cocotb.test()
async def test_ws2812_starved_fifo(dut):
    """The host falls behind: each byte is pushed a different number of
    cycles (0 to 3 bit periods) after the previous byte's last bit
    started, sweeping the moment the shifter stops and restarts. Every
    bit must still get its full period (the ws2812 protocol proof found a
    shortened low time in this window)."""
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    pulses: list[tuple[int, int]] = []
    cocotb.start_soon(record_pulses(dut, bus, pulses))
    await load_program(dut, ws2812_transmit(BIT, T0H, T1H))
    await start_engine(dut)
    data = []
    for offset in range(0, 3 * BIT, 3):
        byte = (0xA5 + 37 * offset) & 0xFF
        data.append(byte)
        await push_packet(dut, [byte])
        while len(pulses) < 8 * len(data) - 1:      # this byte's last bit has started
            await RisingEdge(dut.clk)
        for _ in range(offset):
            await RisingEdge(dut.clk)
    for _ in range(BIT * 20):
        await RisingEdge(dut.clk)
    assert decode(pulses, gaps=True) == data

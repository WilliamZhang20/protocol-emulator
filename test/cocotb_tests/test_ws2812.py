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


def decode(pulses: list[tuple[int, int]]) -> list[int]:
    """Bytes from pulses, checking every timing against the design."""
    bits = []
    for index, (rise, high) in enumerate(pulses):
        assert high in (T0H, T1H), (index, high)
        if index:
            assert rise - pulses[index - 1][0] == BIT, ("bit period", index, rise)
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

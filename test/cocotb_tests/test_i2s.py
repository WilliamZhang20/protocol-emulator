"""I2S transmitter against a reference I2S receiver."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, push_packet, start_engine
from cocotb_tests.protocols import I2S_BCLK, I2S_SD, I2S_WS, i2s_transmit

HALF = 4


async def receive(dut, bus: Bus, frames: list[tuple[int, int]], bits: int) -> None:
    """Sample SD and WS on every BCLK rising edge; a WS change marks the
    next bit as a sample's MSB. Checks SD and WS only move while BCLK is
    low and that BCLK's half periods are exact."""
    bclk = bus.level(I2S_BCLK)
    ws_prev, word, count, left = bus.level(I2S_WS), 0, None, None    # WS rests high
    held, started, channel = None, False, None
    phase = 0
    while True:
        await RisingEdge(dut.clk)
        now = bus.level(I2S_BCLK)
        phase += 1
        if now == bclk:
            if now and started:
                assert (bus.level(I2S_SD), bus.level(I2S_WS)) == held, "SD/WS moved while BCLK high"
            continue
        if started:
            assert phase == HALF, ("BCLK half period", phase)
        phase = 0
        bclk = now
        if not now:
            continue
        sd, ws = bus.level(I2S_SD), bus.level(I2S_WS)
        held = (sd, ws)
        if count is not None:
            word = (word << 1) | sd
            count += 1
            if count == bits:
                if channel == 0:            # WS low during the sample: left
                    left = word
                else:
                    frames.append((left, word))
                count = None
        if ws != ws_prev:
            count, word, channel = 0, 0, ws
        ws_prev = ws
        started = True


async def stream(dut, samples: list[tuple[int, int]], bits: int = 16):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    frames: list[tuple[int, int]] = []
    cocotb.start_soon(receive(dut, bus, frames, bits))
    await load_program(dut, i2s_transmit(HALF, bits))
    data = []
    for left, right in samples:
        for value in (left, right):
            data += [(value >> (bits - 8 * (k + 1))) & 0xFF for k in range(bits // 8)]
    await start_engine(dut)
    await push_packet(dut, data)
    for _ in range(2 * HALF * 2 * bits * (len(samples) + 2)):
        await RisingEdge(dut.clk)
    return frames


@cocotb.test()
async def test_i2s_16bit_stereo(dut):
    rng = random.Random(1225)
    samples = [(rng.randrange(1 << 16), rng.randrange(1 << 16)) for _ in range(6)]
    samples[0] = (0x8001, 0x7FFE)
    frames = await stream(dut, samples)
    # The last right sample needs a following WS edge to be framed by this
    # receiver; every earlier one must match exactly.
    assert frames[:len(samples) - 1] == samples[:len(samples) - 1], frames


@cocotb.test()
async def test_i2s_24bit_stereo(dut):
    rng = random.Random(24)
    samples = [(rng.randrange(1 << 24), rng.randrange(1 << 24)) for _ in range(4)]
    frames = await stream(dut, samples, bits=24)
    assert frames[:len(samples) - 1] == samples[:len(samples) - 1], frames

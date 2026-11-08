"""Quadrature decoder: one RX byte per step, the host keeps the count."""

import random

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, pop_rx, rx_empty, select_channel, start_engine
from cocotb_tests.protocols import QUAD_A, QUAD_B, quadrature_decoder

FORWARD = [(0, 0), (1, 0), (1, 1), (0, 1)]      # A leads B


async def setup(dut) -> Bus:
    await start_clock(dut, 25)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[QUAD_A] = 0
    bus.drive[QUAD_B] = 0
    await load_program(dut, quadrature_decoder())
    await start_engine(dut)
    await ClockCycles(dut.clk, 300)      # the program arms the fabric
    return bus


async def drain(dut, channel: int) -> list[int]:
    await select_channel(dut, channel)
    out = []
    while not await rx_empty(dut):
        out.append(await pop_rx(dut))
    return out


class Encoder:
    """Drives A/B and tracks the true position and the expected events."""

    def __init__(self, dut, bus: Bus) -> None:
        self.dut, self.bus = dut, bus
        self.state = 0                 # index into FORWARD
        self.position = 0
        self.steps: list[int] = []     # expected channel-0 bytes
        self.doubles = 0

    async def set(self, a: int, b: int, hold: int) -> None:
        self.bus.drive[QUAD_A], self.bus.drive[QUAD_B] = a, b
        await ClockCycles(self.dut.clk, hold)

    async def step(self, direction: int, hold: int = 30) -> None:
        self.state = (self.state + direction) % 4
        self.position += direction
        self.steps.append(1 if direction > 0 else 0)
        await self.set(*FORWARD[self.state], hold)

    async def jump(self, hold: int = 30) -> None:
        """Both pins at once: two states ahead, a step the decoder missed."""
        self.state = (self.state + 2) % 4
        self.doubles += 1
        await self.set(*FORWARD[self.state], hold)


@cocotb.test()
async def test_quadrature_turns(dut):
    """Forward, back, reversals and varying speed: every step arrives in
    order with its direction and the host count is the true position."""
    bus = await setup(dut)
    enc = Encoder(dut, bus)
    rng = random.Random(4)
    got, position = [], 0
    for burst in range(12):
        direction = 1 if burst % 3 != 2 else -1
        for _ in range(3):
            await enc.step(direction if rng.random() < 0.8 else -direction,
                           hold=rng.choice([4, 6, 30, 90]))
        got += await drain(dut, 0)
    for byte in got:
        assert byte in (0, 1), byte
        position += 1 if byte else -1
    assert got == enc.steps, (got, enc.steps)
    assert position == enc.position
    assert await drain(dut, 1) == []


@cocotb.test()
async def test_quadrature_glitch_cancels(dut):
    """A glitch on one pin (out and straight back) is a step and its
    reverse: the count is unchanged."""
    bus = await setup(dut)
    enc = Encoder(dut, bus)
    await enc.step(1)
    got = await drain(dut, 0)
    for _ in range(5):                   # (the RX path holds 7 bytes: drain)
        await enc.step(1, hold=3)
        await enc.step(-1, hold=30)
        got += await drain(dut, 0)
    assert got == enc.steps and sum(1 if b else -1 for b in got) == 1


@cocotb.test()
async def test_quadrature_missed_step_reported(dut):
    """Both pins changing together cannot be decoded: it is reported on
    channel 1 and pushes no step."""
    bus = await setup(dut)
    enc = Encoder(dut, bus)
    await enc.step(1)
    await enc.jump()
    await enc.step(1)
    await enc.jump()
    assert await drain(dut, 0) == enc.steps
    assert len(await drain(dut, 1)) == enc.doubles == 2

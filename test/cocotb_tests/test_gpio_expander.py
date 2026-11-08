"""GPIO expander: a chain of 74HC595 outputs and 74HC165 inputs."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, drain_rx, load_program, push_tx, start_engine, tx_full
from cocotb_tests.protocols import (
    GPIO_LOAD, GPIO_QH, GPIO_RCLK, GPIO_SER, GPIO_SRCLK, gpio_expander,
)

HALF = 4
CHIPS = 3
BITS = 8 * CHIPS
MASK = (1 << BITS) - 1


class Chain:
    """Cycle-level 74HC595 and 74HC165 chains on the bus. The 595s shift SER
    in on every SRCLK rise and copy the shift register to their outputs on
    an RCLK rise. The 165s follow `inputs` while SH/LD# is low and shift
    toward QH on every SRCLK rise while it is high."""

    def __init__(self, dut, bus: Bus) -> None:
        self.dut, self.bus = dut, bus
        self.shift = 0
        self.outputs = 0
        self.inputs = 0
        self.load_reg = 0
        self.latched: list[int] = []        # outputs after each RCLK rise
        self.captured: list[int] = []       # inputs when SH/LD# rose
        self.edges_per_update: list[int] = []
        self.edges = 0
        self.errors: list[str] = []
        cocotb.start_soon(self._run())

    async def _run(self) -> None:
        bus = self.bus
        prev = {p: bus.level(p) for p in (GPIO_SRCLK, GPIO_RCLK, GPIO_LOAD)}
        while True:
            await RisingEdge(self.dut.clk)
            now = {p: bus.level(p) for p in prev}
            srclk_rise = now[GPIO_SRCLK] and not prev[GPIO_SRCLK]
            if now[GPIO_LOAD] and not prev[GPIO_LOAD]:
                self.captured.append(self.load_reg)
                self.edges = 0
            if srclk_rise:
                if not now[GPIO_LOAD]:
                    self.errors.append("SRCLK edge while the 165s load")
                self.edges += 1
                self.shift = ((self.shift << 1) | bus.level(GPIO_SER)) & MASK
            if not now[GPIO_LOAD]:
                self.load_reg = self.inputs
            elif srclk_rise:
                self.load_reg = (self.load_reg << 1) & MASK
            if now[GPIO_RCLK] and not prev[GPIO_RCLK]:
                self.outputs = self.shift
                self.latched.append(self.outputs)
                self.edges_per_update.append(self.edges)
            bus.drive[GPIO_QH] = (self.load_reg >> (BITS - 1)) & 1
            prev = now


async def setup(dut):
    await start_clock(dut, 25)
    await reset_top(dut)
    bus = Bus(dut)
    chain = Chain(dut, bus)
    await load_program(dut, gpio_expander(HALF, CHIPS))
    await start_engine(dut)
    return bus, chain


async def update(dut, chain: Chain, outputs: int, inputs: int) -> list[int]:
    """One update: the input pins hold `inputs` while the bytes for
    `outputs` are pushed; returns the bytes read back."""
    chain.inputs = inputs
    for i in range(CHIPS):
        while await tx_full(dut):
            pass
        await push_tx(dut, (outputs >> (8 * (CHIPS - 1 - i))) & 0xFF)
    return await drain_rx(dut, CHIPS)


def as_bytes(value: int) -> list[int]:
    return [(value >> (8 * (CHIPS - 1 - i))) & 0xFF for i in range(CHIPS)]


@cocotb.test()
async def test_gpio_expander_updates(dut):
    """Several updates: each latches exactly the pushed outputs (after
    exactly 24 SRCLK edges) and reads back the inputs present when the
    update started."""
    _, chain = await setup(dut)
    rng = random.Random(595)
    patterns = [(0xA5C3_0F, 0x123456), (0xFFFFFF, 0x000000), (0x000000, 0xFFFFFF)]
    patterns += [(rng.getrandbits(BITS), rng.getrandbits(BITS)) for _ in range(4)]
    for outputs, inputs in patterns:
        read = await update(dut, chain, outputs, inputs)
        for _ in range(4 * HALF):
            await RisingEdge(dut.clk)
        assert chain.latched[-1] == outputs, (hex(chain.latched[-1]), hex(outputs))
        assert chain.edges_per_update[-1] == BITS, chain.edges_per_update
        assert read == as_bytes(inputs), (read, hex(inputs))
    assert chain.captured == [i for _, i in patterns], chain.captured
    assert not chain.errors, chain.errors


@cocotb.test()
async def test_gpio_expander_outputs_change_together(dut):
    """The 595 outputs change only at RCLK: while an update shifts, the
    previous outputs hold, and RCLK rises once per update."""
    bus, chain = await setup(dut)
    await update(dut, chain, 0x0F0F0F, 0)
    for _ in range(4 * HALF):
        await RisingEdge(dut.clk)
    before = len(chain.latched)
    for i in range(CHIPS):
        await push_tx(dut, 0xF0)
    rclk_rises, prev = 0, bus.level(GPIO_RCLK)
    for _ in range(2 * HALF * (BITS + 6)):
        await RisingEdge(dut.clk)
        level = bus.level(GPIO_RCLK)
        if level and not prev:
            rclk_rises += 1
        if rclk_rises == 0:
            assert chain.outputs == 0x0F0F0F
        prev = level
    await drain_rx(dut, CHIPS)
    assert rclk_rises == 1 and len(chain.latched) == before + 1
    assert chain.outputs == 0xF0F0F0


@cocotb.test()
async def test_gpio_expander_starved_and_moving_inputs(dut):
    """The host pushes an update's bytes with long gaps, and the inputs
    change after the update started: SRCLK only pauses (the 165s stay in
    shift mode, so no input change leaks in), the update still has exactly
    24 edges, and the readback is the inputs present when it started."""
    bus, chain = await setup(dut)
    chain.inputs = 0x5A5A5A
    await push_tx(dut, 0x81)
    while not bus.level(GPIO_LOAD):
        await RisingEdge(dut.clk)
    for byte, inputs in ((0x42, 0xFFFFFF), (0x24, 0x000000)):
        for _ in range(40 * HALF):
            await RisingEdge(dut.clk)
        chain.inputs = inputs
        await push_tx(dut, byte)
    read = await drain_rx(dut, CHIPS)
    for _ in range(4 * HALF):
        await RisingEdge(dut.clk)
    assert read == as_bytes(0x5A5A5A), read
    assert chain.latched[-1] == 0x814224 and chain.edges_per_update[-1] == BITS
    assert not chain.errors, chain.errors


@cocotb.test()
async def test_gpio_expander_host_pushes_ahead(dut):
    """The host queues several updates back to back, so the next update's
    first byte is waiting when an update's last byte starts: each update
    is still exactly 24 edges and latches exactly its own bytes (the
    transaction used to be closed by the controller, a few cycles late,
    and a waiting byte started inside it)."""
    _, chain = await setup(dut)
    updates = [0x112233, 0x445566, 0x778899, 0xAABBCC]
    stream = [b for value in updates for b in as_bytes(value)]
    for byte in stream:
        while await tx_full(dut):
            pass
        await push_tx(dut, byte)
    await drain_rx(dut, len(stream))
    for _ in range(4 * HALF):
        await RisingEdge(dut.clk)
    assert chain.latched == updates, [hex(v) for v in chain.latched]
    assert chain.edges_per_update == [BITS] * len(updates), chain.edges_per_update

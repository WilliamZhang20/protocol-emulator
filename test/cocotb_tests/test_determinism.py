"""Non-interference: once the fabric is armed, what the controller does
cannot change any bit's timing on the pins.

Each protocol runs twice from reset with identical host stimulus at
identical cycles: once with the controller idling after it arms the
fabric, once with it busy on unrelated work (arithmetic, status reads,
counted loops). Every cycle's pin outputs and output enables must match
exactly, and so must everything received."""

import contextlib

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests import protocols
from cocotb_tests.fabric import HDLC_CODES, logic
from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, Px8, drain_rx_tagged, load_program, push_tx, select_channel, start_engine,
)
from cocotb_tests.test_contexts import uart_contexts

BIT = 24


def busy_forever(self: Px8) -> None:
    """Keep the controller busy forever without touching the fabric, a FIFO
    or an event: constants, ALU, status reads and a counted inner loop."""
    outer, inner = f"_busy{len(self.code)}", f"_spin{len(self.code)}"
    self.label(outer)
    self.ldc(0x1234)
    self.xrc(0x00FF)
    self.rd(0)
    self.andc(0x0F0F)
    self.setc(7)
    self.label(inner)
    self.djnz(inner)
    self.a_from_c()
    self.j(outer)


def meddling_forever(self: Px8) -> None:
    """A controller that does interfere: it keeps rewriting timer 0's
    period. Used only to show the comparison catches interference."""
    loop = f"_meddle{len(self.code)}"
    self.label(loop)
    self.ldc(BIT + 5)
    self.wcf(0x00)
    self.ldc(BIT - 1)
    self.wcf(0x00)
    self.j(loop)


@contextlib.contextmanager
def busy_controller(tail=busy_forever):
    idle = Px8.idle_forever
    Px8.idle_forever = tail
    try:
        yield
    finally:
        Px8.idle_forever = idle


async def record(dut, cycles: int, trace: list) -> None:
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        trace.append((int(dut.uio_out.value), int(dut.uio_oe.value)))


async def run(dut, program: list[int], stimulus, cycles: int, rx_channel: int | None):
    """Reset, load, start; record the pins for `cycles` while `stimulus`
    drives the host and the bus; then drain one RX channel."""
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive = [None] * 8
    await load_program(dut, program)
    trace: list = []
    await start_engine(dut)
    recorder = cocotb.start_soon(record(dut, cycles, trace))
    await stimulus(dut, bus)
    await recorder
    received = []
    if rx_channel is not None:
        await select_channel(dut, rx_channel)
        received = await drain_rx_tagged(dut)
    return trace, received


async def compare(dut, build, stimulus, cycles: int, rx_channel: int | None = None,
                  tail=busy_forever) -> None:
    await start_clock(dut)
    idle = await run(dut, build(), stimulus, cycles, rx_channel)
    with busy_controller(tail):
        busy_program = build()
    busy = await run(dut, busy_program, stimulus, cycles, rx_channel)
    assert any(oe for _, oe in idle[0]), "the protocol never drove a pin"
    for cycle, (a, b) in enumerate(zip(idle[0], busy[0])):
        assert a == b, f"pins differ at cycle {cycle}: idle {a}, busy {b}"
    assert idle[1] == busy[1], (idle[1], busy[1])


async def send_uart(dut, bus: Bus, data: list[int], pin: int, start: int) -> None:
    await ClockCycles(dut.clk, start)
    for byte in data:
        for level in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            bus.drive[pin] = level
            await ClockCycles(dut.clk, BIT)


@cocotb.test()
async def test_uart_full_duplex_independent_of_controller(dut):
    """UART TX from the FIFO and RX from the pin, concurrently."""
    async def stimulus(dut, bus):
        rx = cocotb.start_soon(send_uart(dut, bus, [0x3C, 0xA5, 0x0F],
                                         protocols.UART_RX_PIN, start=300))
        await ClockCycles(dut.clk, 150)
        for byte in [0x55, 0x81, 0xFE]:
            await push_tx(dut, byte)
        await rx
    await compare(dut, lambda: protocols.uart_full_duplex(BIT), stimulus,
                  cycles=1400, rx_channel=1)


@cocotb.test()
async def test_framed_burst_independent_of_controller(dut):
    """Burst frames: three bytes inside one start/stop frame."""
    async def stimulus(dut, bus):
        await ClockCycles(dut.clk, 150)
        for byte in [0xA7, 0x3C, 0x01]:
            await push_tx(dut, byte)
        await ClockCycles(dut.clk, 40 * BIT)
    await compare(dut, lambda: protocols.framed_burst_loop(BIT, 3), stimulus,
                  cycles=1200)


@cocotb.test()
async def test_context_switching_independent_of_controller(dut):
    """The fabric alternates 8N1 and 8E1 by itself, frame after frame."""
    async def stimulus(dut, bus):
        await ClockCycles(dut.clk, 150)
        for byte in [0x11, 0x22, 0x33, 0x44]:
            await push_tx(dut, byte)
        await ClockCycles(dut.clk, 30 * BIT)
    await compare(dut, lambda: uart_contexts(logic(0), toggle=True), stimulus,
                  cycles=1400)


@cocotb.test()
async def test_packet_link_independent_of_controller(dut):
    """HDLC framing: checksum, escaping and delimiters in the byte layer."""
    async def stimulus(dut, bus):
        await ClockCycles(dut.clk, 150)
        for i, byte in enumerate([0x01, 0x7E, 0x55]):
            await push_tx(dut, byte, eop=i == 2)
        await ClockCycles(dut.clk, 80 * BIT)
    await compare(dut, lambda: protocols.uart_packet_link(
        BIT, HDLC_CODES, prepend=True), stimulus, cycles=2400, rx_channel=1)


@cocotb.test(expect_fail=True)
async def test_harness_catches_a_meddling_controller(dut):
    """Self-check of the harness: a controller that keeps rewriting the
    UART bit timer must make the comparison fail (expected failure)."""
    async def stimulus(dut, bus):
        await ClockCycles(dut.clk, 150)
        for byte in [0x55, 0x81]:
            await push_tx(dut, byte)
        await ClockCycles(dut.clk, 25 * BIT)
    await compare(dut, lambda: protocols.uart_full_duplex(BIT), stimulus,
                  cycles=900, tail=meddling_forever)


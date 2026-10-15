"""UART on the spatial fabric: exact bit timing and full-duplex operation."""

import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, load_program, pop_rx, push_tx, rx_empty, select_channel, start_engine,
)
from cocotb_tests.protocols import (
    UART_RX_PIN, UART_TX_PIN, uart_dual_transmit, uart_full_duplex,
)

BIT = 24


async def receive_frame(dut, bus: Bus, bit: int, pin: int = UART_TX_PIN) -> int:
    """Reference UART receiver: wait for a start bit, sample mid-bit."""
    while bus.level(pin):
        await RisingEdge(dut.clk)
    await ClockCycles(dut.clk, bit // 2)
    assert bus.level(pin) == 0, "start bit glitch"
    value = 0
    for index in range(8):
        await ClockCycles(dut.clk, bit)
        value |= bus.level(pin) << index
    await ClockCycles(dut.clk, bit)
    assert bus.level(pin) == 1, "missing stop bit"
    return value


async def send_frame(dut, bus: Bus, value: int, bit: int) -> None:
    for level in [0] + [(value >> i) & 1 for i in range(8)] + [1]:
        bus.drive[UART_RX_PIN] = level
        await ClockCycles(dut.clk, bit)


@cocotb.test()
async def test_uart_tx_bit_period_is_exact(dut):
    """0x55 toggles every bit, so every edge interval must equal BIT."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, uart_full_duplex(BIT))
    await push_tx(dut, 0x55)
    await start_engine(dut)

    edges = []
    previous = bus.level(UART_TX_PIN)
    cycle = 0
    while len(edges) < 10:
        await RisingEdge(dut.clk)
        cycle += 1
        level = bus.level(UART_TX_PIN)
        if level != previous:
            edges.append(cycle)
            previous = level
        assert cycle < 50 * BIT, "TX never produced 10 edges"
    intervals = [b - a for a, b in zip(edges, edges[1:])]
    assert intervals == [BIT] * 9, intervals


@cocotb.test()
async def test_uart_tx_stream(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, uart_full_duplex(BIT))
    payload = [0xA6, 0x00, 0xFF, 0x3C]
    for byte in payload:
        await push_tx(dut, byte)
    await start_engine(dut)
    received = [await receive_frame(dut, bus, BIT) for _ in payload]
    assert received == payload


@cocotb.test()
async def test_uart_full_duplex(dut):
    """TX and RX tiles run at the same time without interfering."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    rng = random.Random(7)
    tx_bytes = [rng.randrange(256) for _ in range(3)]
    rx_bytes = [rng.randrange(256) for _ in range(3)]
    await load_program(dut, uart_full_duplex(BIT))
    for byte in tx_bytes:
        await push_tx(dut, byte)
    await start_engine(dut)

    async def stimulus():
        # Start once the fabric is configured (TX start bit observed), then
        # offset RX frames from TX frames by a non-multiple of BIT.
        while bus.level(UART_TX_PIN):
            await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, 37)
        for byte in rx_bytes:
            await send_frame(dut, bus, byte, BIT)

    driver = cocotb.start_soon(stimulus())
    received_tx = [await receive_frame(dut, bus, BIT) for _ in tx_bytes]
    await driver
    await ClockCycles(dut.clk, 4 * BIT)

    # Each shifter owns a FIFO channel: RX bytes arrive on channel 1 only.
    assert await rx_empty(dut)
    await select_channel(dut, 1)
    received_rx = []
    while not await rx_empty(dut):
        received_rx.append(await pop_rx(dut))
    assert received_tx == tx_bytes
    assert received_rx == rx_bytes


@cocotb.test()
async def test_fifo_channels_stream_independently(dut):
    """Each shifter pulls its own FIFO channel: two transmitters at
    different bit rates send their own byte streams at the same time."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bits, pins = (BIT, BIT + 10), (UART_TX_PIN, 4)
    rng = random.Random(11)
    streams = [[rng.randrange(256) for _ in range(4)] for _ in range(2)]
    await load_program(dut, uart_dual_transmit(bits, pins))
    for channel in (1, 0):
        await select_channel(dut, channel)
        for byte in streams[channel]:
            await push_tx(dut, byte)
    await start_engine(dut)

    async def listen(k):
        return [await receive_frame(dut, bus, bits[k], pins[k]) for _ in streams[k]]

    listeners = [cocotb.start_soon(listen(k)) for k in range(2)]
    assert [await listener for listener in listeners] == streams

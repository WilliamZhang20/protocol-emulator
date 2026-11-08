"""SPI mode-0 slave on the spatial fabric against a reference master."""

import random

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import driven_level, reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, pop_rx, push_tx, rx_empty, start_engine
from cocotb_tests.protocols import SPI_CS, SPI_MISO, SPI_MOSI, SPI_SCK, spi_slave

HALF = 10


async def transaction(dut, bus: Bus, sent: list[int]) -> list[int]:
    """Master: CS low, then per byte 8 SCK periods, MOSI set while SCK is
    low, MISO sampled on the rising edge; CS high at the end."""
    bus.drive[SPI_SCK] = 0
    bus.drive[SPI_CS] = 0
    await ClockCycles(dut.clk, HALF)
    got = []
    for byte in sent:
        value = 0
        for i in range(8):
            bus.drive[SPI_MOSI] = (byte >> (7 - i)) & 1
            await ClockCycles(dut.clk, HALF)
            bus.drive[SPI_SCK] = 1
            assert driven_level(dut, SPI_MISO) is not None, "MISO not driven during CS"
            value = (value << 1) | bus.level(SPI_MISO)
            await ClockCycles(dut.clk, HALF)
            bus.drive[SPI_SCK] = 0
        got.append(value)
    await ClockCycles(dut.clk, HALF)
    bus.drive[SPI_CS] = 1
    await ClockCycles(dut.clk, 8)
    assert driven_level(dut, SPI_MISO) is None, "MISO still driven after CS"
    return got


@cocotb.test()
async def test_spi_slave_transactions(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[SPI_CS] = 1
    bus.drive[SPI_SCK] = 0
    await load_program(dut, spi_slave())
    rng = random.Random(77)
    await start_engine(dut)
    await ClockCycles(dut.clk, 40)
    assert driven_level(dut, SPI_MISO) is None, "MISO driven while idle"
    for length in (1, 3, 2):
        replies = [rng.randrange(256) for _ in range(length)]
        sent = [rng.randrange(256) for _ in range(length)]
        for byte in replies:
            await push_tx(dut, byte)
        got = await transaction(dut, bus, sent)
        assert got == replies, (got, replies)
        received = []
        while not await rx_empty(dut):
            received.append(await pop_rx(dut))
        assert received == sent, (received, sent)

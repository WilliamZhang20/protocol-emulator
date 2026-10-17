"""SPI master on the spatial fabric, all four CPOL/CPHA modes."""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock, wait_until_halted
from cocotb_tests.fabric import Bus, load_program, pop_rx, push_tx, start_engine
from cocotb_tests.protocols import SPI_CS, SPI_MISO, SPI_MOSI, SPI_SCK, spi_master

HALF = 6


async def spi_slave(dut, bus: Bus, mode: int, replies: list[int], seen: list[int]) -> None:
    """Reference SPI slave, MSB first, sampling and launching on the edges
    the mode defines."""
    cpol, cpha = mode >> 1, mode & 1
    while bus.level(SPI_CS):
        await RisingEdge(dut.clk)
    replies = list(replies)
    out = replies.pop(0)
    bit = 7
    if cpha == 0:
        bus.drive[SPI_MISO] = (out >> 7) & 1
    shift_in = 0
    received_bits = 0
    previous = bus.level(SPI_SCK)
    assert previous == cpol, "SCK not at idle level when CS asserted"
    since_cs, since_edge, first_edge = 0, 0, None
    while bus.level(SPI_CS) == 0:
        await RisingEdge(dut.clk)
        since_cs += 1
        since_edge += 1
        level = bus.level(SPI_SCK)
        if level == previous:
            continue
        if first_edge is None:
            first_edge = since_cs
        since_edge = 0
        leading = level != cpol
        previous = level
        sample_edge = leading if cpha == 0 else not leading
        if sample_edge:
            shift_in = ((shift_in << 1) | bus.level(SPI_MOSI)) & 0xFF
            received_bits += 1
            if received_bits % 8 == 0:
                seen.append(shift_in)
        else:
            if cpha == 0:
                bit -= 1
                if bit < 0:
                    out = replies.pop(0) if replies else 0
                    bit = 7
            bus.drive[SPI_MISO] = (out >> bit) & 1
            if cpha == 1:
                bit -= 1
                if bit < 0:
                    out = replies.pop(0) if replies else 0
                    bit = 7
    # CS setup before the first SCK edge and hold after the last one.
    assert first_edge is not None and first_edge >= HALF, ("CS setup", first_edge)
    assert since_edge >= HALF, ("CS hold", since_edge)


async def run_mode(dut, mode: int) -> None:
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    sent = [0xA5, 0x3C, 0x81]
    replies = [0x5A, 0xC3, 0x7E]
    await load_program(dut, spi_master(mode, HALF))
    for byte in sent:
        await push_tx(dut, byte)
    seen: list[int] = []
    slave = cocotb.start_soon(spi_slave(dut, bus, mode, replies, seen))
    await start_engine(dut)
    await wait_until_halted(dut, timeout_cycles=20000)
    slave.cancel()
    assert seen == sent, f"mode {mode}: slave saw {seen}"
    got = [await pop_rx(dut) for _ in sent]
    assert got == replies, f"mode {mode}: master read {got}"


@cocotb.test()
async def test_spi_mode0(dut):
    await run_mode(dut, 0)


@cocotb.test()
async def test_spi_mode1(dut):
    await run_mode(dut, 1)


@cocotb.test()
async def test_spi_mode2(dut):
    await run_mode(dut, 2)


@cocotb.test()
async def test_spi_mode3(dut):
    await run_mode(dut, 3)

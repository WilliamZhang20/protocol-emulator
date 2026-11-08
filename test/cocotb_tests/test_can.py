"""CAN 2.0A transmitter against a bit-level reference receiver."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock, wait_until_halted
from cocotb_tests.fabric import Bus, load_program, push_packet, start_engine
from cocotb_tests.protocols import CAN_TX, can_transmit

BIT = 20                 # 2 Mbit/s at 40 MHz; any rate is a timer reload


def crc15(bits: list[int]) -> int:
    crc = 0
    for bit in bits:
        feedback = bit ^ ((crc >> 14) & 1)
        crc = (crc << 1) & 0x7FFF
        if feedback:
            crc ^= 0x4599
    return crc


def frame_bits(ident: int, data: bytes) -> list[int]:
    """SOF .. data field, unstuffed."""
    bits = [0]
    bits += [(ident >> (10 - i)) & 1 for i in range(11)]
    bits += [0, 0, 0]                                   # RTR (data), IDE, r0
    bits += [(len(data) >> (3 - i)) & 1 for i in range(4)]
    for byte in data:
        bits += [(byte >> (7 - i)) & 1 for i in range(8)]
    return bits


def fifo_bytes(ident: int, data: bytes) -> list[int]:
    bits = [1] * 5 + frame_bits(ident, data)
    assert len(bits) % 8 == 0
    return [sum(b << (7 - i) for i, b in enumerate(bits[k:k + 8]))
            for k in range(0, len(bits), 8)]


def stuff(bits: list[int]) -> list[int]:
    out, run, last = [], 0, None
    for bit in bits:
        out.append(bit)
        run = run + 1 if bit == last else 1
        last = bit
        if run == 5:
            out.append(1 - bit)
            run, last = 1, 1 - bit
    return out


async def record_line(dut, bus: Bus, cycles: int) -> list[int]:
    levels = []
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        levels.append(bus.level(CAN_TX))
    return levels


def decode(levels: list[int]) -> tuple[int, bytes, list[int]]:
    """Bit-level receiver: SOF edge, sample every BIT cycles mid-bit, check
    every edge falls on the bit grid, destuff, check CRC and form."""
    start = levels.index(0)
    assert all(levels[:start]), "line not recessive before SOF"
    edges = [i for i in range(start, len(levels)) if levels[i] != levels[i - 1]]
    assert all((e - start) % BIT == 0 for e in edges), "edge off the bit grid"
    raw = [levels[start + BIT // 2 + k * BIT]
           for k in range((len(levels) - start - BIT) // BIT)]
    bits, run, last, k = [], 0, None, 0
    # Destuff through the CRC sequence: header first, to learn the length.
    def take():
        nonlocal run, last, k
        bit = raw[k]
        k += 1
        run = run + 1 if bit == last else 1
        last = bit
        if run == 5:
            stuffed = raw[k]
            assert stuffed != bit, ("stuff error", k)
            k += 1
            run, last = 1, stuffed
        return bit
    for _ in range(19):
        bits.append(take())
    dlc = int("".join(map(str, bits[15:19])), 2)
    for _ in range(8 * min(dlc, 8)):
        bits.append(take())
    crc = [take() for _ in range(15)]
    assert int("".join(map(str, crc)), 2) == crc15(bits), "CRC mismatch"
    tail = raw[k:k + 10]
    assert tail[:1] == [1], "CRC delimiter"
    assert tail[2:10] == [1] * 8, "ACK delimiter / EOF"
    ident = int("".join(map(str, bits[1:12])), 2)
    data = bytes(int("".join(map(str, bits[19 + 8 * i:27 + 8 * i])), 2) for i in range(dlc))
    return ident, data, raw[:k]


async def send(dut, ident: int, data: bytes) -> list[int]:
    """Reset the chip, load the transmitter and send one frame (the clock
    is started once per test)."""
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, can_transmit(BIT))
    await start_engine(dut)
    task = cocotb.start_soon(record_line(dut, bus, BIT * (40 + 8 * len(data) + 40)))
    await push_packet(dut, fifo_bytes(ident, data))
    await wait_until_halted(dut, timeout_cycles=100000)
    return await task


@cocotb.test()
async def test_can_frame_with_stuffing(dut):
    """Identifier and data with long equal runs, so stuff bits appear in
    the header, the data and the CRC."""
    await start_clock(dut, 25)
    ident, data = 0x000, bytes([0x00, 0xFF, 0x0F, 0xF0])
    levels = await send(dut, ident, data)
    got_ident, got_data, raw = decode(levels)
    assert (got_ident, got_data) == (ident, data)
    expected = stuff(frame_bits(ident, data) + [
        (crc15(frame_bits(ident, data)) >> (14 - i)) & 1 for i in range(15)])
    assert raw == expected


@cocotb.test()
async def test_can_random_frames(dut):
    await start_clock(dut, 25)
    rng = random.Random(2026)
    for _ in range(6):
        ident = rng.randrange(0x800)
        data = bytes(rng.randrange(256) for _ in range(rng.randrange(9)))
        levels = await send(dut, ident, data)
        assert decode(levels)[:2] == (ident, data), (hex(ident), data.hex())

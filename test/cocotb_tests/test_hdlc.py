"""Synchronous HDLC: transmit and receive, with an independent CRC-16/X.25."""

import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, load_program, pop_rx_tagged, push_packet, select_channel, start_engine,
)
from cocotb_tests.protocols import (
    HDLC_RXC, HDLC_RXD, HDLC_TXC, HDLC_TXD, hdlc_receive, hdlc_transmit,
)

FLAG = [0, 1, 1, 1, 1, 1, 1, 0]


def fcs16(data: bytes) -> int:
    """CRC-16/X.25 (reflected 0x1021, preset and complemented)."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


assert fcs16(b"123456789") == 0x906E


def lsb_bits(data) -> list[int]:
    return [(b >> i) & 1 for b in data for i in range(8)]


def stuff(bits: list[int]) -> list[int]:
    out, ones = [], 0
    for b in bits:
        out.append(b)
        ones = ones + 1 if b else 0
        if ones == 5:
            out.append(0)
            ones = 0
    return out


def encode(frame: bytes, *, bad_fcs: bool = False) -> list[int]:
    """The body of one frame on the line (no flags)."""
    fcs = fcs16(frame) ^ (0x0001 if bad_fcs else 0)
    return stuff(lsb_bits(frame + bytes([fcs & 0xFF, fcs >> 8])))


def decode(bits: list[int]) -> list[bytes]:
    """Frames between flags: destuffed, FCS checked and removed. Raises on
    a stuffing violation or a bad FCS."""
    frames, i = [], 0
    while True:
        try:
            i = next(j for j in range(i, len(bits) - 7) if bits[j:j + 8] == FLAG)
        except StopIteration:
            return frames
        i += 8
        while bits[i:i + 8] == FLAG:          # flags in a row
            i += 8
        body, ones = [], 0
        while i + 8 <= len(bits) and bits[i:i + 8] != FLAG:
            b = bits[i]
            i += 1
            if ones == 5:
                assert b == 0, "six 1s inside a frame"
                ones = 0
                continue
            body.append(b)
            ones = ones + 1 if b else 0
        if i + 8 > len(bits):
            return frames
        assert len(body) % 8 == 0, ("not whole bytes", len(body))
        data = bytes(sum(body[k + j] << j for j in range(8)) for k in range(0, len(body), 8))
        assert len(data) >= 3 and fcs16(data[:-2]) == (data[-2] | data[-1] << 8), data.hex()
        frames.append(data[:-2])


async def capture(dut, bits: list[int], margins: list[int]) -> None:
    """TXD at every TXC rising edge, and how long TXD was stable around it
    (min of the cycles before and after)."""
    history, prev_clk, pending = [], 0, []
    while True:
        await RisingEdge(dut.clk)
        out = int(dut.uio_out.value)
        clk, d = (out >> HDLC_TXC) & 1, (out >> HDLC_TXD) & 1
        history.append(d)
        for entry in pending:
            if entry[1] is None and d != entry[0]:
                entry[1] = entry[2]
            entry[2] += 1
        for entry in [e for e in pending if e[1] is not None or e[2] > 64]:
            margins.append((min(entry[3], entry[1] if entry[1] is not None else 64),
                            entry[4], entry[3], entry[1]))
            pending.remove(entry)
        if clk and not prev_clk:
            before = 0
            while before + 1 < len(history) and history[-2 - before] == d:
                before += 1
            bits.append(d)
            pending.append([d, None, 0, before, len(bits) - 1])
        prev_clk = clk


async def transmit(dut, bit_cycles: int, frames: list[bytes], wait_bits: int) -> list[int]:
    await start_clock(dut, 25)
    await reset_top(dut)
    bits: list[int] = []
    margins: list[int] = []
    cocotb.start_soon(capture(dut, bits, margins))
    await load_program(dut, hdlc_transmit(bit_cycles))
    await start_engine(dut)
    await select_channel(dut, 1)
    for frame in frames:
        await push_packet(dut, list(frame))
    await ClockCycles(dut.clk, bit_cycles * wait_bits)
    worst = min(margins)
    assert worst[0] >= 2, ("TXD setup/hold at TXC rise (margin, bit, before, after)", worst,
                           [m for m in margins if m[0] < 2][:6])
    return bits


@cocotb.test()
async def test_hdlc_tx_frames(dut):
    """Frames with every awkward byte (flags, escapes, runs of 1s): exact
    flags, stuffing, bytes and FCS; only flags between frames."""
    rng = random.Random(3309)
    frames = [bytes([0x7E, 0x7D, 0xFF, 0x00]), bytes([0xFF] * 6), bytes([0x3C]),
              bytes(rng.randrange(256) for _ in range(9))]
    bits = await transmit(dut, 10, frames, wait_bits=40 + sum(14 * (len(f) + 4) for f in frames))
    assert decode(bits) == frames


@cocotb.test()
async def test_hdlc_tx_fcs_ending_in_ones(dut):
    """Frames whose FCS ends in five 1s: the stuffed 0 goes before the
    closing flag."""
    hits = [bytes([a, b]) for a in range(256) for b in (0x00, 0x55)
            if lsb_bits(fcs16(bytes([a, b])).to_bytes(2, "little"))[-5:] == [1] * 5][:3]
    assert hits
    bits = await transmit(dut, 16, hits, wait_bits=40 + 14 * 6 * len(hits))
    assert decode(bits) == hits


@cocotb.test()
async def test_hdlc_tx_slow_host(dut):
    """Frames arriving at random times, some while the line idles with
    flags, some during the previous frame: every frame exact, and only
    whole flags between them."""
    await start_clock(dut, 25)
    await reset_top(dut)
    bits: list[int] = []
    margins: list = []
    cocotb.start_soon(capture(dut, bits, margins))
    await load_program(dut, hdlc_transmit(12))
    await start_engine(dut)
    await select_channel(dut, 1)
    rng = random.Random(1662)
    frames = [bytes(rng.randrange(256) for _ in range(rng.randrange(1, 6))) for _ in range(6)]
    for frame in frames:
        await ClockCycles(dut.clk, rng.choice([0, 30, 200, 700]))
        await push_packet(dut, list(frame))
    await ClockCycles(dut.clk, 12 * 160)
    assert decode(bits) == frames
    assert min(margins)[0] >= 2


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_hdlc_tx_arrival_sweep(dut):
    """One-byte frames, each pushed a different number of cycles after the
    previous one (a sweep across a whole flag), so the controller marks a
    frame pending at every point of the flag in progress: every frame
    follows a whole opening flag and nothing else (the hdlc_transmit proof
    found a frame lost when the controller fired before copying its
    byte)."""
    await start_clock(dut, 25)
    await reset_top(dut)
    bits: list[int] = []
    margins: list = []
    cocotb.start_soon(capture(dut, bits, margins))
    await load_program(dut, hdlc_transmit(10))
    await start_engine(dut)
    await select_channel(dut, 1)
    frames = [bytes([(0x11 * k) & 0xFF]) for k in range(1, 15)]
    for k, frame in enumerate(frames):
        await ClockCycles(dut.clk, 330 + 7 * k)
        await push_packet(dut, list(frame))
    await ClockCycles(dut.clk, 10 * 120)
    assert decode(bits) == frames
    assert min(margins)[0] >= 2


async def drive(dut, bus: Bus, bits: list[int], half: int) -> None:
    """RXD changes on RXC's falling edge; RXC rises half a bit later."""
    for b in bits:
        bus.drive[HDLC_RXC] = 0
        bus.drive[HDLC_RXD] = b
        await ClockCycles(dut.clk, half)
        bus.drive[HDLC_RXC] = 1
        await ClockCycles(dut.clk, half)


async def receive(dut, line: list[int], half: int = 3) -> list[tuple[bytes, bool]]:
    await start_clock(dut, 25)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[HDLC_RXC] = 1
    bus.drive[HDLC_RXD] = 1
    await load_program(dut, hdlc_receive())
    await start_engine(dut)
    await ClockCycles(dut.clk, 300)
    await select_channel(dut, 1)
    packets, current = [], []

    async def collect():
        while True:
            entry = await pop_rx_tagged(dut)
            if entry is None:
                continue
            byte, eop, err = entry
            current.append(byte)
            if eop:
                packets.append((bytes(current), err))
                current.clear()

    task = cocotb.start_soon(collect())
    await drive(dut, bus, [1] * 10 + line + [1] * 20, half)
    await ClockCycles(dut.clk, 400)
    task.cancel()
    return packets


@cocotb.test()
async def test_hdlc_rx_frames(dut):
    """Good frames (flags shared or doubled, idle 1s between), a bad FCS and
    an abort: bytes and FCS reach the host, eop on the last, err exactly
    on the bad ones."""
    rng = random.Random(7)
    good = [bytes([0x7E, 0xFF, 0x7D, 0x01]), bytes(rng.randrange(256) for _ in range(6)),
            bytes([0xFF] * 4)]

    def with_fcs(f):
        fcs = fcs16(f)
        return f + bytes([fcs & 0xFF, fcs >> 8])

    line = FLAG + encode(good[0]) + FLAG + encode(good[1]) + FLAG + FLAG + [1] * 9
    line += FLAG + encode(good[2], bad_fcs=True) + FLAG
    line += FLAG + stuff(lsb_bits(b"\x12\x34\x56")) + [1] * 8        # abort
    line += FLAG + encode(good[2]) + FLAG
    packets = await receive(dut, line)
    bad = good[2] + bytes([(fcs16(good[2]) ^ 1) & 0xFF, fcs16(good[2]) >> 8])
    assert packets[0] == (with_fcs(good[0]), False), packets
    assert packets[1] == (with_fcs(good[1]), False), packets
    assert packets[2] == (bad, True), packets
    assert packets[3][1] is True                                        # the aborted frame
    assert packets[4] == (with_fcs(good[2]), False), packets
    assert len(packets) == 5


@cocotb.test()
async def test_hdlc_loopback(dut):
    """The transmitter's line, recorded, is a valid receiver input."""
    rng = random.Random(11)
    frames = [bytes(rng.randrange(256) for _ in range(rng.randrange(1, 8))) for _ in range(4)]
    bits = await transmit(dut, 10, frames, wait_bits=40 + sum(14 * (len(f) + 4) for f in frames))
    assert decode(bits) == frames
    packets = await receive(dut, bits)
    assert [p[0][:-2] for p in packets] == frames and not any(p[1] for p in packets)

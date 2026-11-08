"""CAN 2.0A receiver node: destuffing, frame bytes, CRC check and ACK on a
wired-AND bus driven by a reference transmitter."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import driven_level, reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, drain_rx_tagged, load_program, pop_rx_tagged, select_channel, start_engine,
)
from cocotb_tests.protocols import CAN_RX, CAN_TX, can_receive
from cocotb_tests.test_can import crc15, frame_bits, stuff

BIT, SAMPLE = 40, 30         # 1 Mbit/s at 40 MHz, sample point 75%


def wire_frame(ident: int, data: bytes, corrupt: bool = False) -> list[int]:
    """The transmitter's bits: stuffed SOF..CRC, then CRC delimiter, ACK
    slot (recessive from the transmitter), ACK delimiter, EOF, IFS."""
    bits = frame_bits(ident, data)
    crc = crc15(bits) ^ (1 if corrupt else 0)
    body = stuff(bits + [(crc >> (14 - i)) & 1 for i in range(15)])
    return body + [1, 1, 1] + [1] * 7 + [1] * 3


async def run_bus(dut, bus: Bus, frames: list[list[int]], acks: list[int],
                  skew: int = 0) -> None:
    """Drive CAN_RX with the wired-AND of the transmitter and our node's
    CAN_TX; record the bus level in each frame's ACK slot. With `skew`
    = +1 / -1 every fourth bit is one cycle longer / shorter (a transmitter
    clock 0.6% slow / fast)."""
    for bits in frames:
        for _ in range(5 * BIT):
            await RisingEdge(dut.clk)
            bus.drive[CAN_RX] = 1
        ack_index = len(bits) - 12          # tail: delim, ACK, delim, EOF(7), IFS(3)
        for k, bit in enumerate(bits):
            levels = []
            for _ in range(BIT + (skew if k % 4 == 3 else 0)):
                ours = driven_level(dut, CAN_TX)
                level = bit & (1 if ours is None else ours)
                bus.drive[CAN_RX] = level
                levels.append(level)
                await RisingEdge(dut.clk)
            if k == ack_index:
                acks.append(levels[:BIT])
            elif bit == 1 and (min(levels) == 0 if skew == 0 else levels[SAMPLE] == 0):
                # Exact clocks: no dominant cycle anywhere outside the ACK
                # slot. Skewed clocks: what CAN requires, no dominant level
                # at the transmitter's own sample point (a bit error).
                raise AssertionError(f"node drove the bus dominant outside the ACK slot (bit {k})")


def parse(stream: bytes) -> tuple[int, bytes, bool]:
    bits = [(b >> (7 - i)) & 1 for b in stream for i in range(8)]
    dlc = int("".join(map(str, bits[15:19])), 2)
    n = min(dlc, 8)
    head_data = bits[:19 + 8 * n]
    crc = int("".join(map(str, bits[19 + 8 * n:34 + 8 * n])), 2)
    ident = int("".join(map(str, bits[1:12])), 2)
    data = bytes(int("".join(map(str, bits[19 + 8 * i:27 + 8 * i])), 2) for i in range(n))
    return ident, data, crc == crc15(head_data)


async def receive_and_ack(dut, skew: int) -> None:
    await start_clock(dut, 25)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[CAN_RX] = 1
    rng = random.Random(15)
    cases = [(0x123, bytes([0xDE, 0xAD]), False), (0x000, bytes([0x00] * 4), False),
             (0x7FF, b"", False), (0x2A5, bytes(rng.randrange(256) for _ in range(8)), False),
             (0x155, bytes([0x55]), True)]
    frames = [wire_frame(i, d, c) for i, d, c in cases]
    await load_program(dut, can_receive(BIT, SAMPLE))
    await select_channel(dut, 1)
    await start_engine(dut)
    for _ in range(1000):                  # the node configures and arms first
        await RisingEdge(dut.clk)
    acks: list[list[int]] = []
    driver = cocotb.start_soon(run_bus(dut, bus, frames, acks, skew))
    entries = []
    while not driver.done():
        entry = await pop_rx_tagged(dut)
        if entry is not None:
            entries.append(entry)
    await driver
    entries += await drain_rx_tagged(dut)
    packets, current = [], []
    for byte, eop, err in entries:
        current.append(byte)
        if eop:
            packets.append((bytes(current), err))
            current = []
    assert len(packets) == len(cases), [p[0].hex() for p in packets]
    for (ident, data, corrupt), (stream, err), levels in zip(cases, packets, acks):
        got_ident, got_data, crc_good = parse(stream)
        assert (got_ident, got_data) == (ident, data), (hex(got_ident), got_data.hex())
        assert crc_good == (not corrupt), (hex(ident), stream.hex(), corrupt, err)
        assert err == corrupt, "err tag"
        if corrupt:
            assert min(levels) == 1, "acknowledged a frame with a bad CRC"
        else:
            if skew == 0:
                assert levels == [0] * BIT, ("ACK slot", "".join(map(str, levels)))
            else:       # the transmitter sees the ACK at its sample point
                assert levels[SAMPLE] == 0 and levels.count(0) >= BIT - 4, \
                    ("ACK slot", "".join(map(str, levels)))


@cocotb.test()
async def test_can_receive_and_ack(dut):
    await receive_and_ack(dut, 0)


@cocotb.test()
async def test_can_receive_slow_transmitter(dut):
    await receive_and_ack(dut, +1)


@cocotb.test()
async def test_can_receive_fast_transmitter(dut):
    await receive_and_ack(dut, -1)

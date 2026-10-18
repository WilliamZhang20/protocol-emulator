"""DMX512 transmitter: break, mark after break, 8N2 slots, exact timing."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, push_packet, start_engine
from cocotb_tests.protocols import DMX_BIT, DMX_BREAK, DMX_MAB, DMX_PIN, US, dmx512_transmit


async def record(dut, bus: Bus, runs: list[tuple[int, int]], stop) -> None:
    """Run-length record of the line: (level, cycles)."""
    level, length = bus.level(DMX_PIN), 0
    while not stop():
        await RisingEdge(dut.clk)
        now = bus.level(DMX_PIN)
        if now == level:
            length += 1
        else:
            runs.append((level, length))
            level, length = now, 1
    runs.append((level, length))


def decode(runs: list[tuple[int, int]]) -> list[list[int]]:
    """Packets from the run-length record, checking break, mark after
    break, and that every slot is an exact 8N2 frame."""
    line = []
    for level, length in runs:
        line += [level] * length
    packets, i = [], 0
    while True:
        try:
            i = line.index(0, i)
        except ValueError:
            return packets
        brk = i
        while i < len(line) and line[i] == 0:
            i += 1
        if i >= len(line):
            return packets
        assert i - brk >= 88 * US, ("break too short", i - brk)
        mab = i
        while i < len(line) and line[i] == 1:
            i += 1
        assert 8 * US <= i - mab < 1000 * US, ("mark after break", i - mab)
        slots = []
        while i < len(line) and line[i] == 0 and (not slots or True):
            start = i
            bits = [line[start + DMX_BIT // 2 + k * DMX_BIT] for k in range(11)]
            assert bits[0] == 0 and bits[9:] == [1, 1], ("framing", bits)
            assert all(line[start + k] == bits[k // DMX_BIT] for k in range(11 * DMX_BIT)), \
                "edge off the bit grid"
            slots.append(sum(b << k for k, b in enumerate(bits[1:9])))
            i = start + 11 * DMX_BIT
            if i < len(line) and line[i] == 0 and i + DMX_BIT * 22 < len(line) and \
                    all(v == 0 for v in line[i:i + 22 * DMX_BIT]):
                break                       # the next break
        packets.append(slots)
        # the next packet's break starts at or after i


@cocotb.test()
async def test_dmx512_two_packets(dut):
    await start_clock(dut, 25)
    await reset_top(dut)
    bus = Bus(dut)
    rng = random.Random(512)
    packets = [[0x00] + [rng.randrange(256) for _ in range(6)],
               [0x00] + [rng.randrange(256) for _ in range(4)]]
    runs: list[tuple[int, int]] = []
    done = []
    cocotb.start_soon(record(dut, bus, runs, lambda: done))
    await load_program(dut, dmx512_transmit(packets=2))
    await start_engine(dut)
    for k, packet in enumerate(packets):
        # Packet k goes into the FIFO once break k has ended (during the
        # mark after it), as a host or the controller streaming from SRAM
        # would feed it.
        while len([r for r in runs if r[0] == 0 and r[1] >= 88 * US]) <= k:
            await RisingEdge(dut.clk)
        await push_packet(dut, packet)
    for _ in range(12 * DMX_BIT * 8):
        await RisingEdge(dut.clk)
    done.append(True)
    await RisingEdge(dut.clk)
    assert decode(runs) == packets, decode(runs)

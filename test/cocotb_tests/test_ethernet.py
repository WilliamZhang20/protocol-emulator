"""10BASE-T transmit on the spatial fabric at a 40 MHz clock: Manchester
coding with exact 2-cycle half bits, hardware CRC32 FCS, and normal link
pulses."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, load_program, push_tx, start_engine, stream_tx
from cocotb_tests.line_codes import bits_to_bytes, ethernet_fcs
from cocotb_tests.protocols import (
    ETH_TD_N, ETH_TD_P, NLP_PIN, ethernet_10baset_transmit, ethernet_link_pulses,
)

CLOCK_NS = 25       # 40 MHz: one 10 Mb/s bit = 4 cycles
PREAMBLE = bytes([0x55] * 7 + [0xD5])


def test_frame() -> bytes:
    rng = random.Random(10)
    dst = bytes.fromhex("ffffffffffff")
    src = bytes.fromhex("02123456789a")
    ethertype = bytes.fromhex("0800")
    payload = bytes(rng.randrange(256) for _ in range(46))
    return dst + src + ethertype + payload


@cocotb.test()
async def test_10baset_frame(dut):
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    frame = test_frame()
    stream = PREAMBLE + frame
    await load_program(dut, ethernet_10baset_transmit())
    for byte in stream[:4]:
        await push_tx(dut, byte)
    await start_engine(dut)
    feeder = cocotb.start_soon(stream_tx(dut, list(stream[4:])))
    plus, minus = [], []
    total_bits = 8 * (len(stream) + 4)
    for _ in range(40000):
        await RisingEdge(dut.clk)
        plus.append(bus.level(ETH_TD_P) if (int(dut.uio_oe.value) & 1) else 0)
        minus.append(bus.level(ETH_TD_N) if (int(dut.uio_oe.value) & 2) else 0)
        if len(plus) > 4 * total_bits + 2000 and not any(plus[-200:]):
            break
    await feeder

    mid = plus.index(1)                     # first bit is '1': low, then high
    bits = []
    for i in range(total_bits):
        t = mid + 4 * i
        first, second = plus[t - 2:t], plus[t:t + 2]
        assert first[0] == first[1] and second[0] == second[1], f"half bit not 2 cycles at bit {i}"
        assert first[0] != second[0], f"no mid-bit transition at bit {i}"
        bits.append(second[0])
        assert [1 - v for v in plus[t - 2:t + 2]] == minus[t - 2:t + 2], "TD- must mirror TD+"
    decoded = bits_to_bytes(bits)
    assert decoded[:8] == PREAMBLE
    assert decoded[8:-4] == frame
    assert decoded[-4:] == ethernet_fcs(frame), (decoded[-4:].hex(), ethernet_fcs(frame).hex())
    tail = mid + 4 * total_bits
    assert not any(plus[tail:]) and not any(minus[tail:]), "line must idle after the FCS"


@cocotb.test()
async def test_10baset_link_pulses(dut):
    """NLP: 100 ns pulses (4 cycles); period scaled from 16 ms to 2000
    cycles for simulation. Both are exact."""
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, ethernet_link_pulses(period_cycles=2000, width_cycles=4))
    await start_engine(dut)
    rises, widths, high, cycle = [], [], 0, 0
    previous = 0
    while len(rises) < 4:
        await RisingEdge(dut.clk)
        cycle += 1
        level = bus.level(NLP_PIN) if (int(dut.uio_oe.value) >> NLP_PIN) & 1 else 0
        if level and not previous:
            rises.append(cycle)
        if level:
            high += 1
        elif previous:
            widths.append(high)
            high = 0
        previous = level
        assert cycle < 20000
    assert all(w == 4 for w in widths), widths
    assert [b - a for a, b in zip(rises, rises[1:])] == [2000] * 3

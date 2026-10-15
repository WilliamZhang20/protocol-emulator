"""10BASE-T transmit on the spatial fabric at a 40 MHz clock.

One run covers a full link session: a normal link pulse, 16 ms, another
pulse, a frame streamed from SRAM (Manchester with exact 2-cycle half bits,
hardware CRC32 FCS, TP_IDL), 16 ms, and a final pulse, all on the same
TD+/TD- pair."""

import random

import cocotb
from cocotb.triggers import Edge, First, Timer
from cocotb.utils import get_sim_time

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import load_program, start_engine
from cocotb_tests.line_codes import bits_to_bytes, ethernet_fcs
from cocotb_tests.protocols import (
    ETH_FRAME_ADDR, ETH_TD_N, ETH_TD_P, NLP_TICK, NLP_TICKS, TP_IDL_CYCLES,
    ethernet_10baset_link,
)

CLOCK_NS = 25       # 40 MHz: one 10 Mb/s bit = 4 cycles
PREAMBLE = bytes([0x55] * 7 + [0xD5])
NLP_PERIOD = NLP_TICK * NLP_TICKS     # 640,000 cycles = 16 ms


def test_frame() -> bytes:
    rng = random.Random(10)
    dst = bytes.fromhex("ffffffffffff")
    src = bytes.fromhex("02123456789a")
    ethertype = bytes.fromhex("0800")
    payload = bytes(rng.randrange(256) for _ in range(46))
    return dst + src + ethertype + payload


async def record_pins(dut, changes: list) -> None:
    """(cycle, TD+, TD-) at every pin change; driven-low when OE is clear."""
    def snapshot():
        out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
        level = lambda p: (out >> p) & 1 if (oe >> p) & 1 else 0
        return level(ETH_TD_P), level(ETH_TD_N)
    last = None
    while True:
        await First(Edge(dut.uio_out), Edge(dut.uio_oe))
        now = snapshot()
        if now != last:
            changes.append((round(get_sim_time("ns") / CLOCK_NS), *now))
            last = now


def high_runs(changes: list) -> list[tuple[int, int]]:
    runs, start = [], None
    for cycle, plus, _ in changes:
        if plus and start is None:
            start = cycle
        elif not plus and start is not None:
            runs.append((start, cycle - start))
            start = None
    return runs


def levels(changes: list, first: int, last: int) -> tuple[list[int], list[int]]:
    plus, minus, index, state = [], [], 0, (0, 0)
    for cycle in range(first, last):
        while index < len(changes) and changes[index][0] <= cycle:
            state = changes[index][1:]
            index += 1
        plus.append(state[0])
        minus.append(state[1])
    return plus, minus


@cocotb.test()
async def test_10baset_link_session(dut):
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    frame = test_frame()
    stream = PREAMBLE + frame
    await load_program(dut, ethernet_10baset_link(len(stream)))
    await load_program(dut, list(stream), address=ETH_FRAME_ADDR)
    changes: list = []
    cocotb.start_soon(record_pins(dut, changes))
    await start_engine(dut)
    await Timer((3 * NLP_PERIOD // 2 + 2 * NLP_TICK) * CLOCK_NS, "ns")
    await Timer((NLP_PERIOD // 2 + NLP_TICK) * CLOCK_NS, "ns")

    runs = high_runs(changes)
    # Link pulses are isolated 100 ns highs; frame bits are packed together.
    isolated = [run for i, run in enumerate(runs)
                if (i == 0 or run[0] - sum(runs[i - 1]) > 16) and
                   (i == len(runs) - 1 or runs[i + 1][0] - sum(run) > 16)]
    pulses = [run for run in isolated if run[1] == 4]
    assert pulses == isolated, f"every isolated high must be a 100 ns pulse: {isolated}"
    assert len(pulses) == 3, f"expected 3 link pulses, saw runs {runs[:6]} ..."
    starts = [start for start, _ in pulses]
    assert [b - a for a, b in zip(starts, starts[1:])] == [NLP_PERIOD] * 2

    # The frame lies between the second and third pulse.
    frame_changes = [c for c in changes if starts[1] + 4 < c[0] < starts[2]]
    first, last = frame_changes[0][0] - 8, frame_changes[-1][0] + 8
    plus, minus = levels(changes, first, last)
    mid = plus.index(1)                 # first bit is '1': low, then high
    total_bits = 8 * (len(stream) + 4)
    bits = []
    for i in range(total_bits):
        t = mid + 4 * i
        first_half, second_half = plus[t - 2:t], plus[t:t + 2]
        assert len(set(first_half)) == 1 and len(set(second_half)) == 1, f"half bit not 2 cycles at bit {i}"
        assert first_half[0] != second_half[0], f"no mid-bit transition at bit {i}"
        assert [1 - v for v in plus[t - 2:t + 2]] == minus[t - 2:t + 2], "TD- must mirror TD+"
        bits.append(second_half[0])
    decoded = bits_to_bytes(bits)
    assert decoded[:8] == PREAMBLE
    assert decoded[8:-4] == frame
    assert decoded[-4:] == ethernet_fcs(frame), (decoded[-4:].hex(), ethernet_fcs(frame).hex())

    # TP_IDL: the line is held high (TD- low) from the end of the last bit
    # for TP_IDL_CYCLES, then idles at zero differential.
    tail = mid + 4 * total_bits - 2
    held = tail
    while held < len(plus) and plus[held] == 1:
        assert minus[held] == 0
        held += 1
    high_after_frame = held - (mid + 4 * total_bits)
    assert high_after_frame == TP_IDL_CYCLES, high_after_frame
    assert not any(plus[held:]) and not any(minus[held:]), "line must idle after TP_IDL"

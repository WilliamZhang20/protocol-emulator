"""10BASE-T transmit on the spatial fabric at a 40 MHz clock.

One run covers a full link session: a normal link pulse, 16 ms, another
pulse, a frame streamed from SRAM (Manchester with exact 2-cycle half bits,
hardware CRC32 FCS, TP_IDL), 16 ms, and a final pulse, all on the same
TD+/TD- pair."""

import random

import cocotb
from cocotb.triggers import ClockCycles, Edge, First, Timer
from cocotb.utils import get_sim_time

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, drain_rx_tagged, load_program, select_channel, start_engine,
)
from cocotb_tests.line_codes import bits_to_bytes, ethernet_fcs, lsb_bits
from cocotb_tests.protocols import (
    ETH_FRAME_ADDR, ETH_RD, ETH_TD_N, ETH_TD_P, NLP_TICK, NLP_TICKS, TP_IDL_CYCLES,
    ethernet_10baset_link, ethernet_10baset_receive,
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


async def run_session(dut, frame: bytes, nlp_tick: int = NLP_TICK) -> None:
    """Run the link-session program on `frame` and check every pulse, bit,
    the FCS and TP_IDL on the pins."""
    period = nlp_tick * NLP_TICKS
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    stream = PREAMBLE + frame
    await load_program(dut, ethernet_10baset_link(len(stream), nlp_tick))
    await load_program(dut, list(stream), address=ETH_FRAME_ADDR)
    changes: list = []
    cocotb.start_soon(record_pins(dut, changes))
    await start_engine(dut)
    await Timer((3 * period // 2 + 2 * nlp_tick) * CLOCK_NS, "ns")
    await Timer((period // 2 + nlp_tick) * CLOCK_NS, "ns")

    runs = high_runs(changes)
    # Link pulses are isolated 100 ns highs; frame bits are packed together.
    isolated = [run for i, run in enumerate(runs)
                if (i == 0 or run[0] - sum(runs[i - 1]) > 16) and
                   (i == len(runs) - 1 or runs[i + 1][0] - sum(run) > 16)]
    pulses = [run for run in isolated if run[1] == 4]
    assert pulses == isolated, f"every isolated high must be a 100 ns pulse: {isolated}"
    assert len(pulses) == 3, f"expected 3 link pulses, saw runs {runs[:6]} ..."
    starts = [start for start, _ in pulses]
    assert [b - a for a, b in zip(starts, starts[1:])] == [period] * 2

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


@cocotb.test()
async def test_10baset_link_session(dut):
    """The real timing: link pulses exactly 16 ms apart around one frame."""
    await run_session(dut, test_frame())


def frame_with(payload: bytes) -> bytes:
    return bytes.fromhex("ffffffffffff02123456789a0800") + payload


FRAME_CASES = {
    "zeros": frame_with(bytes(46)),         # long runs of one Manchester phase
    "ones": frame_with(bytes([0xFF]) * 46),
    "alternating": frame_with(bytes([0xAA, 0x55]) * 23),
    "random_100": frame_with(bytes(random.Random(3).randrange(256) for _ in range(100))),
    "random_400": frame_with(bytes(random.Random(4).randrange(256) for _ in range(400))),
}


@cocotb.test()
@cocotb.parametrize(case=list(FRAME_CASES))
async def test_10baset_frames(dut, case):
    """Frame contents and lengths up to 400 payload bytes (the frame fills
    most of the SRAM after the program), with link pulses on a short tick:
    every bit, the FCS against zlib, TP_IDL and the pulses still check."""
    # The tick must outlast the frame: the program counts the next 16 ms
    # from the frame's end (true at the real 1.6 ms tick for any 802.3
    # frame, at most 1.2 ms long).
    await run_session(dut, FRAME_CASES[case], nlp_tick=16000)


# ---------------------------------------------------------------- receive
async def send_manchester(dut, bus: Bus, frames: list[bytes], gap_bits: int = 96,
                          link_pulses: int = 0) -> None:
    """Reference transmitter on the RD pin: each frame as preamble, SFD,
    bytes LSB first in Manchester (a 1 is low then high, 2 cycles each),
    then TP_IDL high, then idle low for the inter-frame gap."""
    bus.drive[ETH_RD] = 0
    await ClockCycles(dut.clk, 200)
    for frame in frames:
        for _ in range(link_pulses):            # 100 ns highs, 1.6 us apart
            bus.drive[ETH_RD] = 1
            await ClockCycles(dut.clk, 4)
            bus.drive[ETH_RD] = 0
            await ClockCycles(dut.clk, 60)
        for bit in lsb_bits(PREAMBLE + frame):
            bus.drive[ETH_RD] = 1 - bit
            await ClockCycles(dut.clk, 2)
            bus.drive[ETH_RD] = bit
            await ClockCycles(dut.clk, 2)
        bus.drive[ETH_RD] = 1
        await ClockCycles(dut.clk, TP_IDL_CYCLES)
        bus.drive[ETH_RD] = 0
        await ClockCycles(dut.clk, 4 * gap_bits)


async def receive(dut, frames: list[bytes], link_pulses: int = 0) -> list[tuple[int, bool, bool]]:
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, ethernet_10baset_receive())
    await select_channel(dut, 1)
    await start_engine(dut)
    sender = cocotb.start_soon(send_manchester(dut, bus, frames, link_pulses=link_pulses))
    # An empty poll is one 5-cycle status command; outlast any gap between
    # frames (inter-frame gap, link pulses, preamble).
    received = await drain_rx_tagged(dut, settle_polls=400)
    await sender
    return received


def as_packet(data: bytes, err: bool = False) -> list[tuple[int, bool, bool]]:
    return [(b, i == len(data) - 1, err and i == len(data) - 1) for i, b in enumerate(data)]


def with_fcs(frame: bytes) -> bytes:
    return frame + ethernet_fcs(frame)


@cocotb.test()
async def test_10baset_receive_frame(dut):
    """A minimum frame is recovered from Manchester on the pin: every byte
    after the SFD through the FCS, the last tagged eop, the FCS good."""
    wire = with_fcs(test_frame())
    assert await receive(dut, [wire]) == as_packet(wire)


@cocotb.test()
async def test_10baset_receive_bad_fcs(dut):
    """One corrupted payload byte: the bytes arrive as sent, and the
    packet's last byte is tagged err."""
    wire = bytearray(with_fcs(test_frame()))
    wire[30] ^= 0x10
    assert await receive(dut, [bytes(wire)]) == as_packet(bytes(wire), err=True)


@cocotb.test()
async def test_10baset_receive_back_to_back(dut):
    """Two frames separated by the 96-bit inter-frame gap become two
    packets; the receiver re-locks on the second preamble."""
    first = with_fcs(frame_with(bytes(random.Random(8).randrange(256) for _ in range(46))))
    second = with_fcs(frame_with(bytes([0xFF] * 46)))
    assert await receive(dut, [first, second]) == as_packet(first) + as_packet(second)


@cocotb.test()
async def test_10baset_receive_ignores_link_pulses(dut):
    """Link pulses before each frame neither start a packet nor disturb the
    next frame's lock."""
    first = with_fcs(test_frame())
    second = with_fcs(frame_with(bytes([0x00] * 46)))
    received = await receive(dut, [first, second], link_pulses=3)
    assert received == as_packet(first) + as_packet(second)


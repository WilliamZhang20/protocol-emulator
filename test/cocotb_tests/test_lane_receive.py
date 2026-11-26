"""Receive modes only the lane core's coded shifter can do, at the pins.

Designs come from the compiler (protocol-emulator-compiler
circt_lab/lanes/<design>.json, schema v2). Both run the tagged-receive
program: every received byte is pushed with a tag byte after it, 0 when the
frame was good and 0x40 (coder status bit 6, word bad) when it was not, so a
bad frame is kept and marked instead of ending the transfer.

- uart_rx_8e1: UART 8E1, 20 clocks per bit on in0 (uio 5), timer0 resync.
  Frames with a flipped parity bit or a low stop bit are tagged.
- manchester_rx: IEEE 802.3 Manchester (a 1 is low then high), 20 clocks
  per bit, a sync 1 then 8 data bits LSB first. timer0 ticks every half bit
  and resyncs on falling edges; equal halves are a code violation and tag
  the byte.
- lin_checksum: a LIN response (8N1, four data bytes and the classic
  checksum) whose checksum the CRC tile sums over the coder link, data bits
  only (one's complement, end-around carry). The lane pushes the bytes and
  the sum (0xFF when good) and fails on a bad sum.
- ps2_rx: PS/2 device-to-host receive lowered by the compiler's general
  lowering (grid_lower.py) from examples/ps2.spt, with no hand-written
  lane design: the device's clock on in0, data on in1, odd parity.
"""
import os

import cocotb
from cocotb.triggers import FallingEdge

from cocotb_tests.test_lane_controller import Chip

GATE_LEVEL = os.environ.get('GATES') == 'yes'
RX_BASE = 200
BIT = 20
FRAMES = [0x55, 0xA5, 0x3C, 0x96, 0x69, 0xD2, 0x4B, 0xB4]


async def drive_levels(chip, levels, half, settle=300):
    """Drive pin 0 (uio 5) through `levels`, each `half` clocks long (may be
    fractional: edges land on the clock nearest the ideal time)."""
    dut = chip.dut
    for _ in range(settle):
        await FallingEdge(dut.clk)
    clock = 0
    for index, level in enumerate(levels):
        chip.state['scl'] = level; chip.drive()
        end = round((index + 1) * half)
        while clock < end:
            await FallingEdge(dut.clk)
            clock += 1


def uart_8e1(value, bad_parity=False, bad_stop=False, gap=3):
    parity = bin(value).count('1') & 1
    return ([0] + [value >> i & 1 for i in range(8)] + [parity ^ bad_parity] + [0 if bad_stop else 1]
            + [1] * gap)


def manchester(value, violation=None, gap=4):
    """Half-bit levels: sync 1, 8 data bits LSB first, then idle high. A
    violation at data bit k sends equal halves there."""
    halves = []
    for k, bit in enumerate([1] + [value >> i & 1 for i in range(8)]):
        pair = [0, 1] if bit else [1, 0]
        if violation is not None and k == violation + 1:
            pair = [pair[0], pair[0]]
        halves += pair
    return halves + [1] * (2 * gap)


async def run(chip, name, levels, half, count=2 * len(FRAMES), pairs=True):
    """Load `name`, send `levels`, return (finished, error flag, [(byte, tag)])
    (or the bytes as written when not `pairs`)."""
    chip.state['scl'] = 1; chip.drive()
    await chip.load_design(name, {67: count, 90: RX_BASE})
    for i in range(count):
        await chip.write_byte(RX_BASE + i, 0xEE)
    sender = cocotb.start_soon(drive_levels(chip, levels, half))
    try:
        await chip.start_and_wait(limit=int(half * len(levels)) + 2000)
        finished = True
    except AssertionError:
        finished = False
    await sender
    status = await chip.status()
    raw = [await chip.read_byte(RX_BASE + i) for i in range(count)]
    return finished, bool(status & 0x40), list(zip(raw[0::2], raw[1::2])) if pairs else raw


async def check_8e1(chip, drift=0.0):
    bad = {2: 'parity', 5: 'stop'}
    levels = []
    for i, value in enumerate(FRAMES):
        levels += uart_8e1(value, bad_parity=bad.get(i) == 'parity', bad_stop=bad.get(i) == 'stop')
    finished, error, got = await run(chip, 'uart-rx-8e1', levels, BIT * (1 + drift))
    chip.dut._log.info('8E1 drift %+.0f%%: finished %s error %s got %s', drift * 100, finished, error,
                       [(hex(b), hex(t)) for b, t in got])
    want = [(v, 0x40 if i in bad else 0) for i, v in enumerate(FRAMES)]
    assert finished and not error and got == want, (drift, finished, error, got, want)


async def check_manchester(chip, drift=0.0):
    violations = {3: 4, 6: 0}   # frame: data bit with equal halves
    levels = []
    for i, value in enumerate(FRAMES):
        levels += manchester(value, violations.get(i))
    finished, error, got = await run(chip, 'manchester-rx', levels, BIT / 2 * (1 + drift))
    chip.dut._log.info('Manchester drift %+.0f%%: finished %s error %s got %s', drift * 100, finished, error,
                       [(hex(b), hex(t)) for b, t in got])
    tags = [t for _, t in got]
    assert finished and not error, (drift, finished, error, got)
    assert tags == [0x40 if i in violations else 0 for i in range(len(FRAMES))], (drift, got)
    assert all(b == v for (b, t), v in zip(got, FRAMES) if not t), (drift, got)


def lin_checksum(data):
    """LIN classic checksum: the inverted 8-bit sum with end-around carry."""
    total = 0
    for b in data:
        total += b
        total = (total & 0xFF) + (total >> 8)
    return ~total & 0xFF


def uart_8n1(value, gap=3):
    return [0] + [value >> i & 1 for i in range(8)] + [1] * (1 + gap)


async def check_lin(chip, data, checksum, drift=0.0):
    """Returns (finished, error flag, bytes written)."""
    levels = []
    for value in data + [checksum]:
        levels += uart_8n1(value)
    result = await run(chip, 'lin-checksum', levels, BIT * (1 + drift), count=len(data) + 2, pairs=False)
    chip.dut._log.info('LIN %s + %#x drift %+.0f%%: %s', [hex(b) for b in data], checksum, drift * 100, result)
    return result


LIN_DATA = [0x4A, 0x55, 0x93, 0xE5]   # LIN 2.x spec example sums carry twice


@cocotb.test(skip=GATE_LEVEL)
async def uart_8e1_tags_bad_frames(dut):
    """8E1 at nominal and +-5% baud: every byte arrives, the frame with a
    flipped parity bit and the one with a low stop bit are tagged 0x40."""
    chip = Chip(dut)
    await chip.reset()
    for drift in (0.0, 0.05, -0.05):
        await check_8e1(chip, drift)


@cocotb.test(skip=GATE_LEVEL)
async def manchester_tags_code_violations(dut):
    """Manchester at nominal and +-5% baud: good frames decode, frames with
    equal halves in a data bit are tagged 0x40."""
    chip = Chip(dut)
    await chip.reset()
    for drift in (0.0, 0.05, -0.05):
        await check_manchester(chip, drift)


@cocotb.test(skip=GATE_LEVEL)
async def lin_checksum_in_crc_tile(dut):
    """A good LIN response sums to 0xFF over the data bits alone (at nominal
    and +-5% baud); a corrupted checksum fails the lane with its sum."""
    chip = Chip(dut)
    await chip.reset()
    good = lin_checksum(LIN_DATA)
    for drift in (0.0, 0.05, -0.05):
        finished, error, got = await check_lin(chip, LIN_DATA, good, drift)
        assert finished and not error and got == LIN_DATA + [good, 0xFF], (drift, finished, error, got)
    for data in ([0xFF, 0xFF, 0xFF, 0xFF], [0x00, 0x00, 0x00, 0x01]):
        finished, error, got = await check_lin(chip, data, lin_checksum(data))
        assert finished and not error and got[-1] == 0xFF, (data, finished, error, got)
    finished, error, got = await check_lin(chip, LIN_DATA, good ^ 0x10)
    assert error and got[:-1] == LIN_DATA + [good ^ 0x10] and got[-1] != 0xFF, (finished, error, got)


@cocotb.test()
async def coded_receive_gate_level(dut):
    """One 8E1 and one Manchester run at nominal baud (the gate-level check)."""
    chip = Chip(dut)
    await chip.reset()
    await check_8e1(chip)
    await check_manchester(chip)
    finished, error, got = await check_lin(chip, LIN_DATA, lin_checksum(LIN_DATA))
    assert finished and not error and got[-1] == 0xFF, (finished, error, got)


async def ps2_send(chip, frames, half, bad_parity=()):
    """A PS/2 device: data changes while the clock is high, the host reads
    it on the clock's falling edge; start 0, 8 data bits LSB first, odd
    parity, stop 1; clock idles high."""
    dut = chip.dut
    for _ in range(300):
        await FallingEdge(dut.clk)
    for index, value in enumerate(frames):
        parity = 1 ^ (bin(value).count('1') & 1) ^ (1 if index in bad_parity else 0)
        for bit in [0] + [value >> i & 1 for i in range(8)] + [parity, 1]:
            chip.state['sda'] = bit; chip.drive()
            for _ in range(half // 2):
                await FallingEdge(dut.clk)
            chip.state['scl'] = 0; chip.drive()      # the host samples here
            for _ in range(half):
                await FallingEdge(dut.clk)
            chip.state['scl'] = 1; chip.drive()
            for _ in range(half - half // 2):
                await FallingEdge(dut.clk)
        for _ in range(4 * half):
            await FallingEdge(dut.clk)


async def check_ps2(chip, frames, half, bad_parity=()):
    chip.state['scl'] = 1; chip.state['sda'] = 1; chip.drive()
    await chip.load_design('ps2-rx', {67: len(frames), 90: RX_BASE})
    for i in range(len(frames)):
        await chip.write_byte(RX_BASE + i, 0xEE)
    sender = cocotb.start_soon(ps2_send(chip, frames, half, bad_parity))
    try:
        await chip.start_and_wait(limit=half * 30 * len(frames) + 2000)
        finished = True
    except AssertionError:
        finished = False
    await sender
    status = await chip.status()
    got = [await chip.read_byte(RX_BASE + i) for i in range(len(frames))]
    chip.dut._log.info('PS/2 half %d: finished %s error %s got %s', half, finished, bool(status & 0x40),
                       [hex(b) for b in got])
    return finished, bool(status & 0x40), got


@cocotb.test()
async def ps2_lowered_from_source(dut):
    """PS/2 receive compiled from examples/ps2.spt by general lowering:
    make and break codes and the all-zero/all-one/alternating bytes at two
    clock rates; a byte with a wrong parity bit fails the lane after the
    bytes before it. (The design's word count is 3.)"""
    chip = Chip(dut)
    await chip.reset()
    for frames, half in (([0x1C, 0xF0, 0x1C], 20), ([0x00, 0xFF, 0x55], 33), ([0xAA, 0xA5, 0x5A], 20)):
        finished, error, got = await check_ps2(chip, frames, half)
        assert finished and not error and got == frames, (frames, half, finished, error, got)
        if GATE_LEVEL:
            return
    finished, error, got = await check_ps2(chip, [0x12, 0x34, 0x56], 20, bad_parity={1})
    assert finished and error and got[0] == 0x12 and got[1:] == [0xEE, 0xEE], (finished, error, got)

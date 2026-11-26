"""SLIP-framed UART transmitter on the lane core, at the pins.

The design comes from the compiler: protocol-emulator-compiler
circt_lab/lanes/slip_uart_tx.json (lane design v2), built by
`circt_lab/grid_lane.py lanes/slip_uart_tx.json <prefix>`. The line is uio 6
(the core's out0), 8N1 at 20 clocks per bit. The lane escapes END and ESC
per byte; the core's coded shifter frames each byte and its timer0 times
every bit.
"""
import os
import random
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.test_lane_controller import Chip

GATE_LEVEL = os.environ.get('GATES') == 'yes'
BIT = 20
LINE = 0x40
TX_BASE = 100
END, ESC, ESC_END, ESC_ESC = 0xC0, 0xDB, 0xDC, 0xDD


def slip(packet):
    out = []
    for b in packet:
        out += [ESC, ESC_END] if b == END else [ESC, ESC_ESC] if b == ESC else [b]
    return out + [END]


async def receive(dut, count, stop):
    """UART receiver: wait for each start bit, sample mid-bit; checks the
    start bit is a full bit long and the stop bit is high."""
    frames = []

    def line():
        return int(dut.uio_out.value) & LINE and 1 or 0
    while len(frames) < count and not stop:
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if not int(dut.uio_oe.value) & LINE or line():
            continue
        await ClockCycles(dut.clk, BIT // 2)
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        assert line() == 0, 'start bit shorter than half a bit'
        value = 0
        for i in range(8):
            await ClockCycles(dut.clk, BIT)
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            value |= line() << i
        await ClockCycles(dut.clk, BIT)
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        assert line() == 1, f'framing error after {value:#x}'
        frames.append(value)
    return frames


async def send_packet(chip, packet):
    await chip.load_design('slip-uart-tx', {66: len(packet), 67: 0, 89: TX_BASE})
    for offset, value in enumerate(packet):
        await chip.write_byte(TX_BASE + offset, value)
    expected = slip(packet)
    stop = []
    receiver = cocotb.start_soon(receive(chip.dut, len(expected), stop))
    cycles = await chip.start_and_wait(limit=BIT * 11 * (len(expected) + 2) + 2000)
    await ClockCycles(chip.dut.clk, 2 * BIT)
    stop.append(True)
    frames = await receiver
    status = await chip.status()
    assert not status & 0x40, f'error status {status:#x}'
    assert frames == expected, (frames, expected)
    return cycles


@cocotb.test()
async def slip_escapes_and_frames(dut):
    """Plain bytes pass through; END and ESC are escaped; END closes."""
    chip = Chip(dut)
    await chip.reset()
    packet = [0x01, END, 0x7E, ESC, ESC_END, 0xFF]
    cycles = await send_packet(chip, packet)
    dut._log.info('SLIP packet of %d bytes sent as %d frames in %d clocks', len(packet), len(slip(packet)), cycles)


@cocotb.test(skip=GATE_LEVEL)
async def slip_random_packets(dut):
    """Seeded random packets rich in END and ESC (RTL only)."""
    rng = random.Random(0x511B)
    chip = Chip(dut)
    await chip.reset()
    for _ in range(3):
        packet = [rng.choice([END, ESC, ESC_END, ESC_ESC, rng.randrange(256)]) for _ in range(rng.randint(0, 9))]
        await send_packet(chip, packet)

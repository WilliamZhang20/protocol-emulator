"""Timer modes at the pins, driven by compiled lane designs.

Images and programs come from the compiler (protocol-emulator-compiler
circt_lab/lanes/<design>.json, built by `circt_lab/grid_lane.py`); the
timer mode words (208-215) are the program's `extended_words`.

- pulse_period: timer0 in capture mode measures the clocks between rising
  edges on pin 0 (uio 5); the lane pushes each 16-bit period to SRAM.
- uart_rx_resync / uart_rx_plain: UART receive (8N1, 20 clocks per bit) on
  pin 0 from a sender whose bit is up to 6% long or short. With timer0 in
  resync mode every falling edge re-centres the samples; without it the
  samples walk off the bits and frames fail.
"""
import json
import os
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from cocotb_tests.test_lane_controller import Chip

DATA = Path(__file__).parents[1] / 'data/lane'
GATE_LEVEL = os.environ.get('GATES') == 'yes'
RX_BASE = 200


def design(name):
    program = json.loads((DATA / f'{name}.program.json').read_text())
    extended = {int(k): v for k, v in program.get('extended_words', {}).items()}
    return DATA / f'{name}.mem', program, extended


async def load(chip, name, host):
    image, program, extended = design(name)
    await chip.configure({**extended, **host}, image=image)
    for offset, value in enumerate(program['bytes']):
        await chip.write_byte(program['base'] + offset, value)


async def pulses(chip, periods, settle=300, high=20):
    """A rising edge on pin 0 (uio 5), then one more `period` clocks after
    the previous for each period; every change at a falling clock edge."""
    dut = chip.dut

    async def falling(n):
        for _ in range(n):
            await FallingEdge(dut.clk)
    await falling(settle)
    for period in [None] + list(periods):
        if period is not None:
            await falling(period - high)
        chip.state['scl'] = 1; chip.drive()
        await falling(high)
        chip.state['scl'] = 0; chip.drive()


async def measure(chip, periods):
    chip.state['scl'] = 0; chip.drive()
    await load(chip, 'pulse-period', {67: 2 * len(periods), 90: RX_BASE})
    driver = cocotb.start_soon(pulses(chip, periods))
    await chip.start_and_wait(limit=sum(periods) + 5000)
    await driver
    status = await chip.status()
    assert not status & 0x40, f'error status {status:#x}'
    raw = [await chip.read_byte(RX_BASE + i) for i in range(2 * len(periods))]
    return [raw[2 * i] | raw[2 * i + 1] << 8 for i in range(len(periods))]


@cocotb.test()
async def capture_pulse_period(dut):
    """Capture reads back the exact clock count between rising edges."""
    chip = Chip(dut)
    await chip.reset()
    periods = [137, 1000, 65, 4321]
    measured = await measure(chip, periods)
    dut._log.info('pulse periods %s measured %s', periods, measured)
    assert measured == periods, (measured, periods)


@cocotb.test(skip=GATE_LEVEL)
async def capture_saturates(dut):
    """A period longer than 16 bits reads back as 65535, not a wrapped count."""
    chip = Chip(dut)
    await chip.reset()
    periods = [300, 70000, 500, 65535]
    measured = await measure(chip, periods)
    dut._log.info('pulse periods %s measured %s', periods, measured)
    assert measured == [300, 65535, 500, 65535], measured


NOMINAL_BIT = 20
FRAMES = [0x55, 0xA5, 0x3C, 0x96, 0x69, 0xD2, 0x4B, 0xB4]


async def uart_send(chip, frames, bit, settle=300, gap=3):
    """8N1 frames on pin 0 (uio 5), LSB first, `bit` clocks per bit (may be
    fractional: edges land on the clock nearest the ideal time)."""
    dut = chip.dut
    for _ in range(settle):
        await FallingEdge(dut.clk)
    for value in frames:
        levels = [0] + [value >> i & 1 for i in range(8)] + [1] * (1 + gap)
        clock = 0
        for index, level in enumerate(levels):
            chip.state['scl'] = level; chip.drive()
            end = round((index + 1) * bit)
            while clock < end:
                await FallingEdge(dut.clk)
                clock += 1


async def receive(chip, name, bit):
    """Run the receiver lane on FRAMES at `bit` clocks per bit; returns
    (received bytes or None, error flag)."""
    chip.state['scl'] = 1; chip.drive()
    await load(chip, name, {67: len(FRAMES), 90: RX_BASE})
    for i in range(len(FRAMES)):   # no stale bytes from an earlier run
        await chip.write_byte(RX_BASE + i, 0)
    sender = cocotb.start_soon(uart_send(chip, FRAMES, bit))
    try:
        await chip.start_and_wait(limit=int(bit * 13 * len(FRAMES)) + 2000)
        finished = True
    except AssertionError:
        finished = False   # a lost start edge leaves the lane waiting
    await sender
    status = await chip.status()
    received = [await chip.read_byte(RX_BASE + i) for i in range(len(FRAMES))]
    return finished, bool(status & 0x40), received


@cocotb.test(skip=GATE_LEVEL)
async def resync_tracks_drifting_baud(dut):
    """Resync receives every frame at nominal, 6% slow and 6% fast; the same
    receiver without resync is correct at nominal and fails at both drifts."""
    chip = Chip(dut)
    await chip.reset()
    for drift in (0.0, 0.06, -0.06, 0.09, -0.09):
        bit = NOMINAL_BIT * (1 + drift)
        finished, error, received = await receive(chip, 'uart-rx-resync', bit)
        dut._log.info('resync, drift %+.0f%%: finished %s error %s received %s', drift * 100, finished, error,
                      [hex(b) for b in received])
        if abs(drift) > 0.06:
            continue   # margin beyond the 6% requirement: logged, not asserted
        assert finished and not error and received == FRAMES, (drift, finished, error, received)
        finished, error, received = await receive(chip, 'uart-rx-plain', bit)
        dut._log.info('plain,  drift %+.0f%%: finished %s error %s received %s', drift * 100, finished, error,
                      [hex(b) for b in received])
        good = finished and not error and received == FRAMES
        assert good == (drift == 0.0), (drift, finished, error, received)


@cocotb.test()
async def resync_receive_gate_level(dut):
    """One drifting run of the resync receiver (the gate-level check)."""
    chip = Chip(dut)
    await chip.reset()
    finished, error, received = await receive(chip, 'uart-rx-resync', NOMINAL_BIT * 1.06)
    assert finished and not error and received == FRAMES, (finished, error, received)

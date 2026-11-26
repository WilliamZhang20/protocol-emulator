"""Lane controller timing at the pins: program-load (fetch) occupancy and
decision time from an input edge to the pad the program drives.

Uses the I2C target's fabric wiring (test/data/lane/i2c-target.mem): pin 0
(uio 5) edges on rise; action 0 drives output 0 (uio 6) low when clear.
Numbers are logged and asserted against the model in
experiments/grid_fabric/LANE_TIMING.md, so a timing regression fails here.
RTL only: gate-level timing is the same cycle count by construction.
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.lane_asm import assemble, program_bytes, program_word
from cocotb_tests.test_lane_controller import Chip
from cocotb_tests import test_lane_determinism as D
from cocotb_tests import test_lane_i2c_target as I2C

GATE_LEVEL = os.environ.get('GATES') == 'yes'
BASE = 768
SDA, SCL = 0x40, 0x20


async def configure(chip, words):
    await chip.configure({95: program_word(BASE, words), 66: 0, 67: 0}, image=I2C.IMAGE)
    for offset, value in enumerate(program_bytes(words)):
        await chip.write_byte(BASE + offset, value)


async def start_to_done(chip, contention_seed=None):
    """Clocks from the start strobe rising at the pins to the done strobe."""
    dut = chip.dut
    await FallingEdge(dut.clk)
    dut.ui_in.value = 0
    chip.state['op'] = 5; chip.state['strobe'] = 0; chip.drive()
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    chip.state['strobe'] = 1; chip.drive()
    stop, issued = [], []
    if contention_seed is not None:
        async def later():
            await ClockCycles(dut.clk, 6)
            await D.storm(chip, random.Random(contention_seed), stop, 64, 256, issued)
        cocotb.start_soon(later())
    for cycle in range(1, 5000):
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if cycle == 5:
            chip.state['strobe'] = 0; chip.drive()
        if int(dut.uio_out.value) & 0x80:
            stop.append(True)
            await ClockCycles(dut.clk, 60)
            return cycle
    raise AssertionError('no done')


@cocotb.test(skip=GATE_LEVEL)
async def program_load_occupancy(dut):
    """Load is two bytes per instruction at one byte per clock: start to done
    = fixed overhead + 2 x instructions (load) + instructions (run)."""
    chip = Chip(dut)
    await chip.reset()
    results = {}
    for n in (1, 8, 32, 64):
        words = assemble('NOP\n' * (n - 1) + 'HALT')
        await configure(chip, words)
        results[n] = await start_to_done(chip)
    overhead = results[1] - 3
    dut._log.info('start-to-done clocks by program length: %s; fixed overhead %d', results, overhead)
    for n, cycles in results.items():
        assert cycles == overhead + 3 * n, (n, cycles, overhead)
    # Under a host read storm the lane owns its port while loading: unchanged.
    words = assemble('NOP\n' * 63 + 'HALT')
    await configure(chip, words)
    stormed = await start_to_done(chip, contention_seed=0x10AD)
    dut._log.info('64 instructions under a host storm: %d clocks (quiet %d)', stormed, results[64])
    assert stormed == results[64]


async def edge_to_pad(chip, words, settle=200):
    """Start the program, raise uio 5 after it settles, return clocks from the
    rise (driven at a falling edge) until uio 6's output enable rises."""
    dut = chip.dut
    chip.state['scl'] = 0; chip.drive()
    await configure(chip, words)
    await chip.command(5, 0)
    await ClockCycles(dut.clk, settle)
    assert not int(dut.uio_oe.value) & SDA, 'SDA driven before the edge'
    await FallingEdge(dut.clk)
    chip.state['scl'] = 1; chip.drive()
    for cycle in range(1, 200):
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if int(dut.uio_oe.value) & SDA:
            await ClockCycles(dut.clk, 50)
            return cycle
    raise AssertionError('no response on SDA')


@cocotb.test(skip=GATE_LEVEL)
async def decision_time(dut):
    """Pin edge to pad: I/O latency plus one clock per instruction on the
    decision path; a wait retires the clock its condition is seen."""
    chip = Chip(dut)
    await chip.reset()
    paths = {
        # name: (program, instructions after the wait that precede the ACT)
        'WAIT pulse; ACT': ('ACT 3\nCLEAR\nWAIT 2\nACT 2\nWAIT 8\nHALT', 0),
        'WAIT level; ACT': ('ACT 3\nWAIT 10\nWAIT 8\nACT 2\nWAIT 10\nHALT', 0),
        'WANY; AND; JNZ; ACT': ('ACT 3\nCLEAR\nWANY 6\nAND 4\nJNZ hit\nFAIL\nhit: ACT 2\nWAIT 10\nHALT', 2),
        'I2C STOP decision (WANY; AND; JNZ; RD; AND; JZ; ACT)':
            ('ACT 3\nCLEAR\nWANY 6\nAND 2\nJNZ bad\nRD 2\nAND 1\nJZ bad\nACT 2\nWAIT 10\nHALT\nbad: FAIL', 5),
    }
    measured = {}
    for name, (source, extra) in paths.items():
        measured[name] = await edge_to_pad(chip, assemble(source))
    base = measured['WAIT pulse; ACT']
    dut._log.info('edge-to-pad clocks: %s', measured)
    # Two synchronizer flops, the wait retiring on the clock it sees its
    # condition (pulse events and levels both come from the synchronized
    # pin), then the ACT register: 4 clocks, plus one per instruction.
    assert base == 4, measured
    for name, (source, extra) in paths.items():
        assert measured[name] == base + extra, (name, measured[name], base + extra)

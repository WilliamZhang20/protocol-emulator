"""Lane determinism under SRAM-port contention, at the pins.

Each lane design runs twice with the same external stimulus: once quiet,
once while the host issues a seeded storm of SRAM reads into the bank the
streams use. Every change of the chip-driven pads (output enables and
levels of uio 5 and 6) is recorded as a cycle offset from the start
command; the two traces must be identical. The lane's program lives in a
local buffer and its streams are prefetched, so port contention may delay
memory traffic but must never move a pin edge.

This holds when tiles or the external controller time the bits and each
PULL takes a byte prefetched well before (byte period much longer than the
refill latency): arbitration is round-robin per bank, so a stream request
waits at most two clocks, and the lane owns its port while loading its
program. A program whose pin activity is paced by stream throughput itself
is not covered, by design.
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests import test_lane_i2c_target as I2C
from cocotb_tests import test_lane_slip_tx as SLIP
from cocotb_tests.test_lane_controller import Chip

PADS = 0x60
GATE_LEVEL = os.environ.get('GATES') == 'yes'   # an architectural property: RTL only


class Recorder:
    def __init__(self, dut):
        self.dut, self.trace, self.running = dut, [], True

    async def run(self, start_cycle):
        cycle, last = 0, None
        while self.running:
            await FallingEdge(self.dut.clk); await Timer(1, unit='ns')
            cycle += 1
            state = (int(self.dut.uio_oe.value) & PADS, int(self.dut.uio_out.value) & PADS)
            if state != last:
                self.trace.append((cycle - start_cycle[0], state))
                last = state


async def storm(chip, rng, stop, low, high, issued):
    """Back-to-back host reads (about one SRAM request per 13 clocks, the
    fastest the pin protocol allows) at random addresses in [low, high);
    the address changes every few reads."""
    while not stop:
        address = rng.randrange(low, high)
        await chip.command(0, address & 255); await chip.command(1, address >> 8)
        for _ in range(rng.randrange(1, 6)):
            if stop:
                return
            # A read request occupies the port; its (possibly unwritten) data is not needed.
            await chip.command(3, 0)
            issued.append(1)


async def traced(chip, body, contention_seed):
    """Run body(start) with a recorder; start() issues the start command and
    marks cycle zero. Returns the pad trace."""
    dut = chip.dut
    rec = Recorder(dut)
    mark = [0]
    counter = {'n': 0}

    async def count():
        while rec.running:
            await FallingEdge(dut.clk)
            counter['n'] += 1
    cocotb.start_soon(count())
    cocotb.start_soon(rec.run(mark))
    stop = []

    async def start():
        await chip.command(5, 0)
        mark[0] = counter['n']
        if contention_seed is not None:
            cocotb.start_soon(storm(chip, random.Random(contention_seed), stop, 64, 256, issued))
    issued = []
    await body(start)
    stop.append(True)
    if contention_seed is not None:
        dut._log.info('host storm: %d SRAM reads during the transfer', len(issued))
        assert len(issued) >= 20, "the storm did not overlap the transfer"
    await ClockCycles(dut.clk, 200)
    rec.running = False
    await ClockCycles(dut.clk, 2)
    # Keep only edges after the start command was issued.
    return [(c, s) for c, s in rec.trace if c >= 0]


@cocotb.test(skip=GATE_LEVEL)
async def slip_deterministic_under_contention(dut):
    """SLIP TX: every frame edge lands on the same cycle with and without a
    host read storm on the source bank."""
    chip = Chip(dut)
    await chip.reset()
    packet = [0x01, SLIP.END, 0x7E, SLIP.ESC, 0x55, 0xAA, SLIP.END]
    traces = []
    for seed in (None, 0xC0FFEE):
        await chip.configure({66: len(packet), 67: 0, 89: SLIP.TX_BASE}, image=SLIP.IMAGE)
        for offset, value in enumerate(SLIP.PROGRAM['bytes']):
            await chip.write_byte(SLIP.PROGRAM['base'] + offset, value)
        for offset, value in enumerate(packet):
            await chip.write_byte(SLIP.TX_BASE + offset, value)

        async def body(start):
            await start()
            for _ in range(SLIP.BIT * 11 * 12 + 2000):
                await FallingEdge(dut.clk); await Timer(1, unit='ns')
                if int(dut.uio_out.value) & 0x80:
                    return
            raise AssertionError('SLIP transfer did not finish')
        traces.append(await traced(chip, body, seed))
    dut._log.info('SLIP trace: %d pad changes, last at cycle %d', len(traces[0]), traces[0][-1][0])
    assert len(traces[0]) > 20, traces[0]
    assert traces[0] == traces[1], next((a, b) for a, b in zip(*traces) if a != b)


@cocotb.test(skip=GATE_LEVEL)
async def i2c_target_deterministic_under_contention(dut):
    """I2C target: ACK edges land on the same cycles under the same bus
    stimulus with and without a host read storm on the destination bank."""
    payload = [0x11, 0xA5, 0x00, 0xFF]
    chip, bus = await I2C.setup(dut, len(payload))
    traces = []
    for seed in (None, 0xBEEF):
        async def body(start):
            done = []

            async def watch():                              # done is a one-clock strobe
                while not done:
                    await FallingEdge(dut.clk); await Timer(1, unit='ns')
                    if int(dut.uio_out.value) & 0x80:
                        done.append(True)
            await start()
            watcher = cocotb.start_soon(watch())
            await ClockCycles(dut.clk, 300)                 # program load
            acks = await bus.write(I2C.ADDRESS, payload)
            assert acks == [True] * (len(payload) + 1), acks
            for _ in range(2000):
                if done:
                    return
                await ClockCycles(dut.clk, 1)
            watcher.cancel()
            raise AssertionError('I2C target did not finish')
        traces.append(await traced(chip, body, seed))
        assert [await chip.read_byte(200 + i) for i in range(len(payload))] == payload
    dut._log.info('I2C trace: %d pad changes, last at cycle %d', len(traces[0]), traces[0][-1][0])
    assert traces[0] == traces[1], next((a, b) for a, b in zip(*traces) if a != b)

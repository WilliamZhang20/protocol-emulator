"""I2C target on the lane core, at the top-level pins only.

The design comes from the compiler (protocol-emulator-compiler,
circt_lab/lanes/i2c_target.json, lane design v2, built by
`circt_lab/grid_lane.py lanes/i2c_target.json <prefix>`). The test plays an I2C controller on an
open-drain bus: each line is high unless the test or the chip pulls it.
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.test_lane_controller import Chip

ADDRESS = 0x48
GATE_LEVEL = os.environ.get('GATES') == 'yes'
SDA, SCL = 0x40, 0x20      # uio bits: SDA is pin 1 (uio 6), SCL is pin 0 (uio 5)


class Bus:
    """Open-drain SCL and SDA between the test (controller) and the chip."""

    def __init__(self, chip, half=60):
        self.chip, self.dut, self.half = chip, chip.dut, half
        self.drive = {'scl': 1, 'sda': 1}
        self.acks = []

    def level(self, name):
        bit = SCL if name == 'scl' else SDA
        pulled = int(self.dut.uio_oe.value) & bit and not int(self.dut.uio_out.value) & bit
        return int(self.drive[name] and not pulled)

    async def run(self):
        while True:
            self.chip.state['scl'] = self.level('scl')
            self.chip.state['sda'] = self.level('sda')
            self.chip.drive()
            await FallingEdge(self.dut.clk); await Timer(1, unit='ns')

    async def wait(self, cycles):
        await ClockCycles(self.dut.clk, cycles)

    async def set(self, name, value):
        self.drive[name] = value
        await self.wait(self.half // 2)

    async def start(self):
        await self.set('sda', 1); await self.set('scl', 1); await self.wait(self.half)
        await self.set('sda', 0); await self.wait(self.half)
        await self.set('scl', 0)

    async def stop(self):
        await self.set('sda', 0); await self.set('scl', 1); await self.wait(self.half)
        await self.set('sda', 1); await self.wait(self.half)

    async def clock_bit(self, value):
        await self.set('sda', value)
        await self.set('scl', 1)
        await self.wait(self.half // 2)
        seen = self.level('sda')
        await self.wait(self.half // 2)
        await self.set('scl', 0)
        return seen

    async def write_byte(self, value):
        for i in range(7, -1, -1):
            assert await self.clock_bit((value >> i) & 1) == (value >> i) & 1, 'SDA disturbed during a data bit'
        ack = await self.clock_bit(1) == 0       # release SDA; the target pulls it to ACK
        self.acks.append(ack)
        return ack

    async def write(self, address, payload):
        await self.start()
        acks = [await self.write_byte(address << 1)]
        if acks[0]:
            for byte in payload:
                acks.append(await self.write_byte(byte))
        await self.stop()
        return acks


async def setup(dut, capacity, half=60):
    chip = Chip(dut)
    await chip.reset()
    await chip.load_design('i2c-target', {67: capacity, 90: 200})
    bus = Bus(chip, half)
    cocotb.start_soon(bus.run())
    return chip, bus


async def finish(chip, limit=2000):
    for _ in range(limit):
        await FallingEdge(chip.dut.clk); await Timer(1, unit='ns')
        if int(chip.dut.uio_out.value) & 0x80:
            return
    raise AssertionError('lane did not finish after the STOP')


async def run_transfer(chip, bus, transactions):
    """Start the lane, play the transactions, wait for its halt; return the
    ACK pattern per transaction. The done strobe is watched from the start."""
    done = []

    async def watch():
        while True:
            await FallingEdge(chip.dut.clk); await Timer(1, unit='ns')
            if int(chip.dut.uio_out.value) & 0x80:
                done.append(True)
                return
    await chip.command(5, 0)
    watcher = cocotb.start_soon(watch())
    acks = []
    for address, payload in transactions:
        assert not done, 'lane finished early'
        acks.append(await bus.write(address, payload))
    for _ in range(2000):
        if done:
            break
        await ClockCycles(chip.dut.clk, 1)
    watcher.cancel()
    assert done, 'lane did not finish after the STOP'
    return acks


@cocotb.test()
async def i2c_target_write(dut):
    """A write to another address gets no ACK and is skipped; a write to 0x48
    is ACKed byte by byte and lands in SRAM; the lane halts at its STOP."""
    payload = [0x11, 0xA5, 0x00, 0xFF, 0x48]
    chip, bus = await setup(dut, len(payload))
    acks = await run_transfer(chip, bus, [(0x21, [0x99]), (ADDRESS, payload)])
    assert acks == [[False], [True] * (len(payload) + 1)], acks
    status = await chip.status()
    assert not status & 0x40, f'error status {status:#x}'
    received = [await chip.read_byte(200 + i) for i in range(len(payload))]
    assert received == payload, received


@cocotb.test()
async def i2c_target_back_to_back(dut):
    """Two lane runs on the same armed fabric: the second transaction starts
    after the first ended with a STOP right after an ACK, which leaves the
    shifter mid-byte; the start of the next byte must resynchronize it."""
    chip, bus = await setup(dut, 8)
    first, second = [0x01, 0x02], [0xC0, 0xDE, 0x5A]
    assert await run_transfer(chip, bus, [(ADDRESS, first)]) == [[True] * 3]
    assert [await chip.read_byte(200 + i) for i in range(2)] == first
    assert await run_transfer(chip, bus, [(ADDRESS, second)]) == [[True] * 4]
    assert [await chip.read_byte(200 + i) for i in range(3)] == second
    assert not (await chip.status()) & 0x40


@cocotb.test(skip=GATE_LEVEL)
async def i2c_target_random(dut):
    """Random addresses, payloads and bus speeds (fixed seed; RTL only, the
    two tests above cover the same paths at gate level)."""
    rng = random.Random(0x12C)
    chip, bus = await setup(dut, 16, half=rng.choice([40, 60, 90]))
    transactions = [(rng.choice([0x10, 0x47, 0x49, 0x7F]), [rng.randrange(256) for _ in range(rng.randint(0, 3))])
                    for _ in range(rng.randint(1, 3))]
    payload = [rng.randrange(256) for _ in range(rng.randint(1, 8))]
    acks = await run_transfer(chip, bus, transactions + [(ADDRESS, payload)])
    assert all(a == [False] for a in acks[:-1]) and acks[-1] == [True] * (len(payload) + 1), acks
    assert [await chip.read_byte(200 + i) for i in range(len(payload))] == payload

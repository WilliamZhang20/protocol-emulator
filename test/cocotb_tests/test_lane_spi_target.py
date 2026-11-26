"""SPI target (mode 0, no chip select) on the lane core, at the pins.

The design comes from the compiler: protocol-emulator-compiler
circt_lab/lanes/spi_target.json (lane design v2), built by
`circt_lab/grid_lane.py lanes/spi_target.json <prefix>`. SCLK is uio 5 (in0),
MOSI uio 6 (in1); MISO is the core's out2, visible on uo[0] while the host
opcode is 7 and its strobe is idle.
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.test_lane_controller import Chip

GATE_LEVEL = os.environ.get('GATES') == 'yes'
TX_BASE, RX_BASE = 100, 200


async def setup(dut, replies):
    chip = Chip(dut)
    chip.state['scl'] = 0                  # SCLK idles low in mode 0
    await chip.reset()
    await prepare(chip, replies)
    return chip


async def prepare(chip, replies):
    """(Re)configure for a transfer of len(replies) bytes and load SRAM."""
    chip.state['op'] = 0; chip.drive()
    n = len(replies)
    await chip.load_design('spi-target', {66: n, 67: n, 89: TX_BASE, 90: RX_BASE})
    for offset, value in enumerate(replies):
        await chip.write_byte(TX_BASE + offset, value)


async def transfer(chip, mosi, half, gap):
    """Start the lane, clock the bytes as an SPI controller, return MISO
    bytes; asserts the lane finishes after the last byte without error."""
    dut = chip.dut
    done = []

    async def watch():
        while not done:
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if int(dut.uio_out.value) & 0x80:
                done.append(True)
    await chip.command(5, 0)
    chip.state['op'] = 7; chip.state['strobe'] = 0; chip.drive()   # uo[0] shows MISO
    cocotb.start_soon(watch())
    await ClockCycles(dut.clk, 400)        # program load and the first reply
    miso = []
    for byte in mosi:
        value = 0
        for i in range(7, -1, -1):
            chip.state['sda'] = (byte >> i) & 1; chip.drive()
            await ClockCycles(dut.clk, half)
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if not dut.uo_out.value.is_resolvable:
                raise AssertionError(f'uo_out {dut.uo_out.value} uio_in {dut.uio_in.value} uio_oe {dut.uio_oe.value} at byte {len(miso)} bit {i}')
            value = value << 1 | (int(dut.uo_out.value) & 1)   # sampled at the rise
            chip.state['scl'] = 1; chip.drive()
            await ClockCycles(dut.clk, half)
            chip.state['scl'] = 0; chip.drive()
        miso.append(value)
        if done and len(miso) < len(mosi):
            status = await chip.status()
            raise AssertionError(f'lane finished after byte {len(miso)} of {len(mosi)}, status {status:#x}, miso {miso}')
        await ClockCycles(dut.clk, gap)
    for _ in range(500):
        if done:
            break
        await ClockCycles(dut.clk, 1)
    assert done, 'lane did not finish after the last byte'
    status = await chip.status()
    assert not status & 0x40, f'error status {status:#x}'
    return miso


@cocotb.test()
async def spi_target_full_duplex(dut):
    """Replies come from SRAM on MISO while MOSI bytes are stored."""
    replies = [0xA5, 0x00, 0xFF, 0x3C]
    mosi = [0x5A, 0x81, 0x7E, 0x00]
    chip = await setup(dut, replies)
    assert await transfer(chip, mosi, half=24, gap=60) == replies
    assert [await chip.read_byte(RX_BASE + i) for i in range(len(mosi))] == mosi


@cocotb.test(skip=GATE_LEVEL)
async def spi_target_random(dut):
    """Seeded random lengths, data, clock rates and byte gaps (RTL only)."""
    rng = random.Random(0x5B1)
    chip = None
    for _ in range(2):
        n = rng.randint(1, 10)
        replies = [rng.randrange(256) for _ in range(n)]
        mosi = [rng.randrange(256) for _ in range(n)]
        if chip is None:
            chip = await setup(dut, replies)
        else:
            await prepare(chip, replies)
        half = rng.choice([12, 20, 40])
        assert await transfer(chip, mosi, half=half, gap=2 * half + rng.randrange(40)) == replies
        assert [await chip.read_byte(RX_BASE + i) for i in range(n)] == mosi

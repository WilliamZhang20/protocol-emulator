"""The mesh chip at its pins (FABRIC_REORG.md step 6): every compiled program
(experiments/grid_fabric/reorg/compiled/*.plan.json) loaded and run through
the Tiny Tapeout pins only, so the same test runs on the RTL and on the
gate-level netlist (AGENTS.md).

The host side is test_mesh_compiled's runner with a port that speaks the
chip's host link (src/mesh_host.v): ui = data, uio[4:2] = command, uio[1]
= strobe, uo = the last read byte. Configuration bytes, SRAM, stream
descriptors, flags, events and parameters are all addresses. The protocol
pads are uio 0, 5, 6, 7 (mesh pads 0-3), wired-AND with the peers and
pulled up.
"""
import os
from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.test_compiled import Failure
from cocotb_tests.test_mesh_compiled import run_program

ROOT = Path(__file__).resolve().parents[2]
COMPILED = ROOT / 'experiments/grid_fabric/reorg/compiled'
CONTRACT = 'mesh_3x4_L3'          # the chip's mesh (src/project.v)
PAD_PINS = [0, 5, 6, 7]         # uio bit of mesh pads 0-3
CFG, CTL = 0x1000, 0x2000
STROBE_HIGH, STROBE_LOW, READ_WAIT = 4, 3, 6


class ChipBus:
    """The chip's protocol pads, addressed by logical pad (0-7; 4-7 are not
    bonded and read high). uio_in carries both the pads and the host link."""

    def __init__(self, dut, wires, link):
        self.dut, self.link = dut, link
        self.wires = {to: source for source, to in wires}
        self.drive = {}

    def _chip(self, pad):
        if pad >= len(PAD_PINS):
            return 1, False
        bit = PAD_PINS[pad]
        oe, out = str(self.dut.uio_oe.value)[7 - bit], str(self.dut.uio_out.value)[7 - bit]
        if oe == '1':                       # an unknown enable (before reset) drives nothing
            if out not in '01':
                raise Failure(f'pad {pad} (uio[{bit}]) is driven with an unknown value')
            return int(out), True
        return 1, False

    def chip_driven(self, pad):
        return self._chip(self.wires.get(pad, pad))[1]

    def driven(self, pad):
        pad = self.wires.get(pad, pad)
        return self._chip(pad)[1] or any(p == pad for p, _ in self.drive)

    def level(self, pad):
        pad = self.wires.get(pad, pad)
        return min([self._chip(pad)[0], *(v for (p, _), v in self.drive.items() if p == pad)])

    def pads(self):
        return sum(self.level(p) << PAD_PINS[p] for p in range(len(PAD_PINS)))

    async def run(self):
        while True:
            await FallingEdge(self.dut.clk)
            await Timer(1, unit='ns')
            self.link.apply()


class Link:
    """The host link's pins; uio_in is written whole from here."""

    def __init__(self, dut):
        self.dut, self.op, self.strobe, self.bus = dut, 0, 0, None

    def apply(self):
        pads = self.bus.pads() if self.bus else sum(1 << b for b in PAD_PINS)
        self.dut.uio_in.value = pads | self.op << 2 | self.strobe << 1


class ChipPort:
    """test_mesh_compiled's host port, over the chip's pins."""

    def __init__(self, dut, vector, interface):
        self.dut, self.vector, self.interface = dut, vector, interface
        self.link, self.addr, self.got = Link(dut), None, {}
        if any(s['port'] == 'host' for s in interface['streams'].values()):
            raise Failure('the chip has no direct host byte ports; this program needs one')

    def bus(self, wires):
        self.link.bus = ChipBus(self.dut, wires, self.link)
        return self.link.bus

    def tasks(self):
        return []

    async def command(self, op, data=0):
        dut = self.dut
        await FallingEdge(dut.clk)
        dut.ui_in.value = data; self.link.op = op; self.link.strobe = 1; self.link.apply()
        await ClockCycles(dut.clk, STROBE_HIGH)
        await FallingEdge(dut.clk)
        self.link.strobe = 0; self.link.apply()
        await ClockCycles(dut.clk, STROBE_LOW)

    async def at(self, addr):
        if self.addr is None or self.addr >> 8 != addr >> 8:
            await self.command(1, addr >> 8)
        if self.addr != addr:
            await self.command(0, addr & 0xff)
        self.addr = addr

    async def write(self, addr, value):
        await self.at(addr)
        await self.command(2, value & 0xff)
        self.addr = addr + 1

    async def read(self, addr):
        await self.at(addr)
        await self.command(3)
        self.addr = addr + 1
        await ClockCycles(self.dut.clk, READ_WAIT)
        return int(self.dut.uo_out.value)

    async def start(self):
        dut = self.dut
        dut.ena.value = 1; dut.ui_in.value = 0; dut.rst_n.value = 0
        self.link.apply()
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); dut.rst_n.value = 1
        await ClockCycles(dut.clk, 2)
        self.addr = None
        nbytes = (self.vector.bit_length() + 7) // 8
        for b in range(nbytes):
            byte = self.vector >> (8 * b) & 0xff
            if byte:
                await self.write(CFG + b, byte)
        await self.write(CTL + 0x00, 0)                  # release the hold: the mesh loads its tiles
        for _ in range(16):
            if await self.read(CTL + 0x01) & 0x80:
                return
        raise Failure('the mesh did not finish loading its configuration')

    async def mem(self, addr, data=None):
        if data is None:
            return await self.read(addr)
        await self.write(addr, data)

    async def _pair(self, reg, value):
        await self.write(CTL + reg, value & 0xff)
        await self.write(CTL + reg + 1, value >> 8 & 0x7)

    async def open_writer(self, base, capacity):
        await self._pair(0x08, base); await self._pair(0x0A, capacity)
        await self.write(CTL + 0x0C, 0)

    async def run(self):
        await self.write(CTL + 0x00, 1)

    async def send(self, base, length):
        await self._pair(0x02, base); await self._pair(0x04, length)
        await self.write(CTL + 0x06, 0)

    async def reader_finished(self):
        status = await self.read(CTL + 0x01)
        return bool(status & 0x20 or not status & 0x40)

    async def written(self):
        while True:                                       # the two bytes are read apart: retry a carry
            hi = await self.read(CTL + 0x0E)
            lo = await self.read(CTL + 0x0D)
            if await self.read(CTL + 0x0E) == hi:
                return hi << 8 | lo

    async def flag(self, index):
        return await self.read(CTL + 0x10 + index // 8) >> index % 8 & 1

    async def clear(self):
        await self.command(5)

    async def fire(self, index):
        await self.command(4, 1 << index)

    async def param(self, cell, addr, value):
        await self.write(CTL + 0x18, cell); await self.write(CTL + 0x19, addr)
        await self.write(CTL + 0x1A, value & 0xff)
        await self.write(CTL + 0x1B, value >> 8 & 0xff)    # this write writes the parameter


# Under gate-level simulation (GATES=yes) a subset that still covers every
# path: the host link and configuration (all), SRAM streams both ways
# (uart), the autonomous wire-timed target (i2c_target) and the
# host-sequenced function (spi, without the host-delay repeat).
GL_PROGRAMS = ('i2c_target', 'spi', 'uart', 'usb')
# Programs whose source tests run for tens of milliseconds (Ethernet's three
# 16 ms link sessions per call): no host-delay replay at the chip's pins.
# The replay runs at the mesh's pins (test/Makefile.mesh, SIM=verilator).
LONG_PROGRAMS = ('ethernet_tx_coded',)


@cocotb.test()
async def chip_compiled_programs(dut):
    only = os.environ.get('CHIP_PROGRAM')
    gl = os.environ.get('GATES') == 'yes'
    stems = sorted(str(p)[:-len('.plan.json')] for p in COMPILED.glob(f'*.{CONTRACT}.plan.json'))
    names = [only] if only else GL_PROGRAMS if gl else None
    if names:
        stems = [s for s in stems if Path(s).name.split('.')[0] in names]
    assert stems, f'no compiled programs for {CONTRACT} in {COMPILED}'
    failures = []
    for stem in stems:
        failures += await run_program(dut, stem, ChipPort,
                                      host_delay=not gl and Path(stem).name.split('.')[0] not in LONG_PROGRAMS)
    assert not failures, failures

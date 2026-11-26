"""Lane controller in the fabric, at the top-level pins only.

Configuration word 91 bit 2 selects the lane controller instead of the row
sequencer; word 95 says where its program lives. These tests use the
temporal I2C image for every other word (pins, routes, contexts) and check:
the program loads over the host-bank port and streams bytes through the
reader and writer; a live alternate-context write takes effect when the
program switches context; a write outside the lane's words fails closed;
and the row sequencer still runs when the bit is clear.
"""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.lane_asm import assemble, program_bytes, program_word, EV_EDGE0, EV_EDGE1

IMAGE = Path(__file__).parents[1] / 'data/temporal-i2c.mem'
PROGRAM_BASE = 768


class Chip:
    def __init__(self, dut):
        self.dut = dut
        self.state = {'op': 0, 'strobe': 0, 'scl': 1, 'sda': 1}

    def drive(self):
        s = self.state
        self.dut.uio_in.value = (s['sda'] << 6) | (s['scl'] << 5) | (s['op'] << 2) | (s['strobe'] << 1) | 1

    async def reset(self):
        cocotb.start_soon(Clock(self.dut.clk, 20, unit='ns').start())
        self.dut.ena.value = 1; self.dut.rst_n.value = 0; self.dut.ui_in.value = 0
        self.drive(); await ClockCycles(self.dut.clk, 8)
        await FallingEdge(self.dut.clk); self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, 8)

    async def command(self, op, data):
        await FallingEdge(self.dut.clk); self.dut.ui_in.value = data
        self.state['op'] = op; self.state['strobe'] = 0; self.drive()
        await ClockCycles(self.dut.clk, 4)
        await FallingEdge(self.dut.clk); self.state['strobe'] = 1; self.drive()
        await ClockCycles(self.dut.clk, 5)
        await FallingEdge(self.dut.clk); self.state['strobe'] = 0; self.drive()
        await ClockCycles(self.dut.clk, 4)

    async def config(self, index, word):
        await self.command(0, index); await self.command(6, word & 255); await self.command(7, word >> 8)

    async def write_byte(self, address, value):
        await self.command(0, address & 255); await self.command(1, address >> 8); await self.command(2, value)

    async def read_byte(self, address):
        await self.command(0, address & 255); await self.command(1, address >> 8); await self.command(3, 0)
        await ClockCycles(self.dut.clk, 5); await FallingEdge(self.dut.clk)
        return int(self.dut.uo_out.value)

    async def status(self):
        self.state['op'] = 4; self.state['strobe'] = 0; self.drive()
        await ClockCycles(self.dut.clk, 5); await FallingEdge(self.dut.clk)
        return int(self.dut.uo_out.value)

    async def configure(self, extra, image=IMAGE):
        """Disarmed configuration of the image plus `extra` words, then arm.
        Disarm first: configuration mode is only taken while disarmed, so
        from an armed chip a lone command(4, 8) would drop every write."""
        await self.command(4, 0)
        await self.command(4, 8)
        # Image writes need host address bits 9:8 clear; config() sets only
        # the low byte, and the last SRAM access may have left them set.
        await self.command(1, 0)
        image = [int(x, 16) for x in image.read_text().splitlines()]
        words = dict(enumerate(image))
        words[68] = 3            # pins 0 and 1 read their own pads
        words.update(extra)
        for address, word in sorted(words.items()):
            await self.config(address, word)
        await self.command(4, 0); await self.command(4, 4)
        assert int(self.dut.uio_oe.value) & 0x80, 'configuration did not arm'

    async def load_program(self, words):
        for offset, value in enumerate(program_bytes(words)):
            await self.write_byte(PROGRAM_BASE + offset, value)

    async def start_and_wait(self, limit=20000):
        await self.command(5, 0)
        for cycle in range(limit):
            await FallingEdge(self.dut.clk); await Timer(1, unit='ns')
            if int(self.dut.uio_out.value) & 0x80:
                return cycle
        raise AssertionError('lane did not finish')


def lane_words(program, host=None):
    words = {91: 0x4, 95: program_word(PROGRAM_BASE, program)}
    words.update(host or {})
    return words


@cocotb.test()
async def lane_streams_bytes(dut):
    """Pull each source byte, transform it, push it to the destination."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
    next:
        RD 3          # stream bytes left
        JZ done
        PULL
        XOR 0x5A
        PUSH
        J next
    done:
        HALT
    ''')
    payload = [0x00, 0x5A, 0xFF, 0x12, 0xC3, 0x7E]
    await chip.configure(lane_words(program, {66: len(payload), 67: len(payload), 89: 100, 90: 200}))
    await chip.load_program(program)
    for offset, value in enumerate(payload):
        await chip.write_byte(100 + offset, value)
    cycles = await chip.start_and_wait()
    status = await chip.status()
    received = [await chip.read_byte(200 + i) for i in range(len(payload))]
    dut._log.info('lane stream: done after %d clocks, status %#x, received %s', cycles, status, received)
    assert not status & 0x40, f'error status {status:#x}'
    assert received == [b ^ 0x5A for b in payload], received
    # A second start reloads and runs again on new data.
    for offset, value in enumerate(payload):
        await chip.write_byte(100 + offset, value ^ 0xFF)
    await chip.start_and_wait()
    received = [await chip.read_byte(200 + i) for i in range(len(payload))]
    assert received == [b ^ 0xFF ^ 0x5A for b in payload], received


# With actions 0x9 (bit 3: alternate context) the image's overrides drive
# SDA (uio 6) low and release SCL (uio 5). Word 114 (0x0547, sink 7) is the
# override driving SDA: with it disabled, SDA is released.
SDA, SCL = 0x40, 0x20


async def watch_oe(dut, cycles):
    """uio_oe & (SDA|SCL) each clock until done or `cycles`, as runs."""
    runs = []
    for _ in range(cycles):
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if int(dut.uio_out.value) & 0x80:
            break
        oe = int(dut.uio_oe.value) & (SDA | SCL)
        if runs and runs[-1][0] == oe:
            runs[-1][1] += 1
        else:
            runs.append([oe, 1])
    return runs


@cocotb.test()
async def lane_live_context_write(dut):
    """A live write disables word 114's override while the alternate context
    is selected, and the pads change mid-run. The program puts the word back
    before it halts, so a second run behaves the same."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        ACT 0x9         # alternate context; image override drives SDA
        SETC 100
    a:  LOOP a
        LDI 0x007       # word 114 with its enable bit clear
        WCFG 114
        SETC 100
    b:  LOOP b
        LDI 0x547       # restore the image's word
        WCFG 114
        ACT 0
        HALT
    ''')
    await chip.configure(lane_words(program))
    await chip.load_program(program)
    for run in range(2):
        await chip.command(5, 0)
        runs = [r for r in await watch_oe(dut, 2000) if r[1] > 2]
        dut._log.info('run %d: oe runs %s', run, runs)
        # SCL depends on image tile state left by the previous transfer, so
        # only SDA, which word 114 controls, is checked.
        sda = [bool(oe & SDA) for oe, _ in runs[1:]]
        assert sda and sda[0] and not any(sda[1:]) and len(sda) > 1, \
            f'expected SDA driven, then released by the live write: {runs}'
        assert not (await chip.status()) & 0x40


@cocotb.test()
async def lane_refused_context_write(dut):
    """A live write that would give sink 7 a second override (word 114 has
    it) is refused: the transfer fails, the fabric stays configured and the
    next transfer runs."""
    chip = Chip(dut)
    await chip.reset()
    bad = assemble('''
        LDI 0x407       # override enabled, sink 7: clashes with word 114
        WCFG 112
        HALT
        NOP             # same length as the second program (word 95)
        NOP
    ''')
    await chip.configure(lane_words(bad))
    await chip.load_program(bad)
    await chip.start_and_wait()
    assert (await chip.status()) & 0x40, 'refused write was not reported'
    assert int(dut.uio_oe.value) & 0x80, 'fabric no longer armed'
    good = assemble('''
        ACT 0x9
        SETC 50
    a:  LOOP a
        ACT 0
        HALT
    ''')
    assert len(good) == len(bad)
    await chip.load_program(good)
    await chip.command(5, 0)
    runs = [r for r in await watch_oe(dut, 1000) if r[1] > 2]
    assert [oe for oe, _ in runs if oe] == [SDA], f'image override lost after the refused write: {runs}'
    assert not (await chip.status()) & 0x40


@cocotb.test()
async def lane_wait_any(dut):
    """WANY waits for either pin edge and says which one fired: the program
    halts cleanly only when it saw the SDA edge alone."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble(f'''
        CLEAR
        WANY {1 << EV_EDGE0 | 1 << EV_EDGE1}
        XOR {1 << EV_EDGE1}
        JNZ wrong
        HALT
    wrong: FAIL
    ''')
    await chip.configure(lane_words(program))
    await chip.load_program(program)
    for pin, expect_error in (('sda', False), ('scl', True)):
        await chip.command(5, 0)
        await ClockCycles(dut.clk, 300)
        assert not int(dut.uio_out.value) & 0x80, 'finished before any edge'
        # A low pulse gives an edge in either configured polarity; the done
        # strobe is one clock, so watch every clock.
        finished = False
        for cycle in range(220):
            if cycle in (0, 20):
                chip.state[pin] = int(cycle == 20); chip.drive()
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if int(dut.uio_out.value) & 0x80:
                finished = True
                break
        assert finished, f'WANY missed the {pin} edge'
        chip.state[pin] = 1; chip.drive()
        error = bool((await chip.status()) & 0x40)
        assert error == expect_error, f'{pin} edge: error {error}'


@cocotb.test()
async def lane_stream_limits_fail(dut):
    """A PUSH past the destination's capacity and a PULL with no source bytes
    left both fail the transfer instead of waiting forever, and the bytes
    pushed before the failure are in SRAM."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        LDI 0x31
        PUSH
        LDI 0x32
        PUSH
        LDI 0x33
        PUSH          # capacity is two: fails
        HALT
    ''')
    await chip.configure(lane_words(program, {66: 0, 67: 2, 90: 200}))
    await chip.load_program(program)
    await chip.start_and_wait(limit=2000)
    assert (await chip.status()) & 0x40, 'PUSH past capacity was not reported'
    assert [await chip.read_byte(200 + i) for i in range(2)] == [0x31, 0x32]
    pull = assemble('''
        PULL
        PULL
        PULL          # two source bytes: fails
        HALT
        NOP
        NOP
        NOP
    ''')
    assert len(pull) == len(program)
    await chip.configure(lane_words(pull, {66: 2, 67: 0, 89: 100}))
    await chip.load_program(pull)
    await chip.start_and_wait(limit=2000)
    assert (await chip.status()) & 0x40, 'PULL past the source was not reported'


@cocotb.test()
async def lane_write_fence(dut):
    """A configuration write outside the lane's words fails the transfer."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        LDI 0x123
        WCFG 117
        HALT
    ''')
    await chip.configure(lane_words(program))
    await chip.load_program(program)
    await chip.start_and_wait()
    assert (await chip.status()) & 0x40, 'write outside the lane was not reported'


@cocotb.test()
async def row_sequencer_still_selectable(dut):
    """With word 91 bit 2 clear the image's row-sequencer program runs (it
    starts an I2C START, so SDA is pulled low)."""
    chip = Chip(dut)
    await chip.reset()
    await chip.configure({})
    await chip.command(5, 0)
    for _ in range(4000):
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if int(dut.uio_oe.value) & 0x40:
            break
    else:
        raise AssertionError('row sequencer did not start the I2C START condition')

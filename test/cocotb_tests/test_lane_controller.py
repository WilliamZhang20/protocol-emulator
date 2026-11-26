"""Lane mode in the fabric, at the top-level pins only.

Configuration word 91 bit 2 selects lane mode: lane 0's core (controller,
timers, coded shifter, CRC) runs instead of the row sequencer, configured on
page 1 (core word 36 says where its program lives). These tests use the
temporal I2C image for the page-0 words and check: the program loads over
the host-bank port and streams bytes through the reader and writer; a live
write of a timer period takes effect at its next reload; writes the core
refuses, and writes outside its words, fail closed; and the row sequencer
still runs when the bit is clear.
"""
import json
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.lane_asm import assemble, program_bytes, core_words, READBACK, CORE_PAGE

IMAGE = Path(__file__).parents[1] / 'data/temporal-i2c.mem'
DESIGNS = Path(__file__).parents[1] / 'data/lane'
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
        image = [int(x, 16) for x in image.read_text().splitlines()]
        words = dict(enumerate(image))
        words[68] = 3            # pins 0 and 1 read their own pads
        words.update(extra)
        # Address bits 9:8 pick the page (0 grid and fabric, 1 lane cores);
        # config() sets only the low byte, and the last SRAM access may have
        # left bits 9:8 set, so the page is always written before the first word.
        page = None
        for address, word in sorted(words.items()):
            if address >> 8 != page:
                page = address >> 8
                await self.command(1, page)
            await self.config(address & 255, word)
        await self.command(4, 0); await self.command(4, 4)
        assert int(self.dut.uio_oe.value) & 0x80, 'configuration did not arm'

    async def load_design(self, name, host=None):
        """A compiled lane design (test/data/lane/<name>): the page-0 image,
        the lane core's page-1 words, then its program in the host bank."""
        program = json.loads((DESIGNS / f'{name}.program.json').read_text())
        assert program['schema'] == 'spatial.lane-program.v2', name
        page = program['core_page'] << 8
        core = {page + int(k): v for k, v in program['core_words'].items()}
        await self.configure({**core, **(host or {})}, image=DESIGNS / f'{name}.mem')
        for offset, value in enumerate(program['bytes']):
            await self.write_byte(program['base'] + offset, value)
        return program

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


def lane_words(program, host=None, connect=None, words=None, idle_actions=0):
    """Lane mode (word 91 bit 2) with lane 0's core configured on page 1."""
    out = {91: 0x4}
    out.update(core_words(program, PROGRAM_BASE, connect, words, idle_actions))
    out.update(host or {})
    return out


@cocotb.test()
async def lane_streams_bytes(dut):
    """Pull each source byte, transform it, push it to the destination."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble(f'''
    next:
        RD {READBACK['stream_bytes_left']}
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


SDA, SCL = 0x40, 0x20      # uio 6 is the core's out0 (and in1), uio 5 its out1 (and in0)


async def line_intervals(dut, bit, cycles):
    """Clocks between changes of uio_out & bit, until done or `cycles`."""
    intervals, last, since = [], None, 0
    for _ in range(cycles):
        await FallingEdge(dut.clk); await Timer(1, unit='ns')
        if int(dut.uio_out.value) & 0x80:
            break
        level = bool(int(dut.uio_out.value) & bit)
        since += 1
        if last is not None and level != last:
            intervals.append(since)
            since = 0
        last = level
    return intervals


TOGGLE = {'timer0.start': 'fire', 'timer0.stop': 'action0', 'out0.value': 'timer0.level', 'out0.enable': 'high'}


@cocotb.test()
async def lane_live_context_write(dut):
    """A live write of timer0's period (WCFG) while it toggles out0: the
    interval in progress finishes at the old period and every later one has
    the new period; the program restores the period before it halts, so a
    second run behaves the same."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        ACT 0
        FIRE            # timer0 toggles out0 every 10 clocks
        SETC 120
    a:  LOOP a
        LDI 30
        WCFG 1          # timer0 period: 30 from its next reload
        SETC 200
    b:  LOOP b
        LDI 10
        WCFG 1          # restore
        SETC 60
    c:  LOOP c
        ACT 1           # stop timer0
        HALT
    ''')
    await chip.configure(lane_words(program, connect=TOGGLE, words={0: 10, 1: 10}))
    await chip.load_program(program)
    for run in range(2):
        await chip.command(5, 0)
        intervals = (await line_intervals(dut, SDA, 3000))[1:]
        dut._log.info('run %d: out0 intervals %s', run, intervals)
        groups = []
        for value in intervals:
            if groups and groups[-1][0] == value:
                groups[-1][1] += 1
            else:
                groups.append([value, 1])
        assert [g[0] for g in groups] == [10, 30, 10] and groups[1][1] >= 3, \
            f'expected 10-clock intervals, then 30, then 10 again (never a cut interval): {intervals}'
        assert not (await chip.status()) & 0x40


@cocotb.test()
async def lane_refused_context_write(dut):
    """Live writes the core refuses fail the transfer (timer0's mode word,
    owned but not live-writable; a zero period; a timer not in use); the
    fabric stays configured and the next transfer runs: action 0 pulls SDA
    through an open-drain selection."""
    chip = Chip(dut)
    await chip.reset()
    connect = {'out0.value': 'low', 'out0.enable': 'action0'}
    good = assemble('''
        ACT 1
        SETC 50
    a:  LOOP a
        ACT 0
        HALT
    ''')
    for bad_source in ('LDI 1\nWCFG 2', 'LDI 0\nWCFG 1', 'LDI 9\nWCFG 5'):
        bad = assemble(bad_source + '\nHALT\nNOP\nNOP')
        assert len(good) == len(bad)
        await chip.configure(lane_words(bad, connect=connect, words={0: 10, 1: 10}))
        await chip.load_program(bad)
        await chip.start_and_wait()
        assert (await chip.status()) & 0x40, f'refused write was not reported: {bad_source!r}'
        assert int(dut.uio_oe.value) & 0x80, 'fabric no longer armed'
        await chip.load_program(good)
        await chip.command(5, 0)
        runs = []
        for _ in range(1000):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if int(dut.uio_out.value) & 0x80:
                break
            pulled = bool(int(dut.uio_oe.value) & SDA) and not int(dut.uio_out.value) & SDA
            if not runs or runs[-1][0] != pulled:
                runs.append([pulled, 0])
            runs[-1][1] += 1
        assert [r[0] for r in runs] == [False, True, False] and runs[1][1] > 40, f'SDA pull after a refused write: {runs}'
        assert not (await chip.status()) & 0x40


@cocotb.test()
async def lane_wait_any(dut):
    """WANY waits for either pin edge and says which one fired: the program
    halts cleanly only when it saw the SDA (in1) edge alone."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        CLEAR
        WANY 3
        XOR 2
        JNZ wrong
        HALT
    wrong: FAIL
    ''')
    await chip.configure(lane_words(program, connect={'event0': 'in0.fall', 'event1': 'in1.fall'}))
    await chip.load_program(program)
    for pin, expect_error in (('sda', False), ('scl', True)):
        await chip.command(5, 0)
        await ClockCycles(dut.clk, 300)
        assert not int(dut.uio_out.value) & 0x80, 'finished before any edge'
        # A low pulse; the done strobe is one clock, so watch every clock.
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
    """A configuration write outside the core's owned words fails the transfer."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble('''
        LDI 0x123
        WCFG 8
        HALT
    ''')
    await chip.configure(lane_words(program, words={0: 10, 1: 10}))
    await chip.load_program(program)
    await chip.start_and_wait()
    assert (await chip.status()) & 0x40, 'write outside the lane was not reported'


@cocotb.test()
async def lane_core_validity_gates_arming(dut):
    """Page-1 words reach the lane core and its validity gates arming in lane
    mode: a reserved line on a selector keeps the chip from arming, valid
    words arm it. A page-1 write to the address of a page-0 host word (66,
    the transfer length) leaves the host word alone."""
    chip = Chip(dut)
    await chip.reset()
    program = assemble(f'''
        RD {READBACK['stream_bytes_left']}
        PUSH
        HALT
    ''')
    words = lane_words(program, {66: 3, 67: 1, 89: 100, 90: 200})
    bad = dict(words)
    bad[CORE_PAGE + 25] = 19            # event0 <- line 19: reserved
    try:
        await chip.configure(bad)
    except AssertionError as e:
        assert 'did not arm' in str(e), e
    else:
        raise AssertionError('a reserved core selector was accepted')
    good = dict(words)
    good[CORE_PAGE + 66 - 64] = 0       # page 1, address 2 (core word 2): unrelated to host word 66
    good[CORE_PAGE + 66] = 7            # page 1, address 66: beyond lane 0's 38 words, ignored
    await chip.configure(good)
    await chip.load_program(program)
    await chip.start_and_wait()
    assert not (await chip.status()) & 0x40
    assert await chip.read_byte(200) == 3, 'host word 66 (transfer length) changed by a page-1 write'


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

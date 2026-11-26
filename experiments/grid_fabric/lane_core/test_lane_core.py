"""Lane core standalone (step 2.4a): the controller times nothing; its own
timers, coded shifter and CRC do, wired through the core's local lines.

Python models stand in for the fabric: program memory (one-clock read),
stream reader (bytes from a list) and writer (bytes to a list). Pads are
driven directly as synchronized levels. Line numbers and word layouts are
those documented in src/grid_lane_core.v.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, ReadOnly

from cocotb_tests.lane_asm import assemble, program_bytes

# Lines.
NEVER, FIRE, SHIFT = 0, 1, 2
T0_TICK, T0_RISE, T0_FALL, T1_TICK, T1_RISE, T1_FALL = 3, 4, 5, 6, 7, 8
C_WORD, C_STOP = 9, 10
IN0_RISE, IN0_FALL, IN1_RISE, IN1_FALL = 11, 12, 13, 14
LOW, HIGH = 32, 33
ACT0 = 34
C_SERIAL, C_ACTIVE, CRC_OUT, CRC_OK = 42, 43, 44, 45
IN0, IN1 = 46, 47
C_BAD = 50
# Words.
W_T0, W_T1, W_TSEL, W_CODER, W_CRC, W_EV, W_LV, W_OUT, W_PROG, W_SET = 0, 4, 8, 11, 17, 25, 29, 33, 36, 37
# Readback.
RB_RX, RB_STATUS, RB_CAP0, RB_CAP1, RB_CRC_LO, RB_CRC_HI, RB_PADS, RB_LEFT = range(8)
PROG_BASE = 0
SAMPLE_LATENCY = 2


def frame_word(length, pre=0, pre_val=0, post=0, post_val=0, parity=0, msb=False, idle=0):
    return (idle << 15) | (int(msb) << 12) | (parity << 10) | (post_val << 9) | (post << 7) | \
           (pre_val << 6) | (pre << 4) | (length - 1)


def pair(lo, hi):
    return (hi << 6) | lo


class Core:
    def __init__(self, dut):
        self.dut = dut
        self.program = []
        self.source = []
        self.sink = []
        self.left = 0

    async def reset(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 10, unit='ns').start())
        for name in ('rst_n', 'arm', 'cfg_we', 'cfg_addr', 'cfg_data', 'start', 'abort', 'mem_ready',
                     'mem_rvalid', 'mem_rdata', 'rd_valid', 'rd_data', 'wr_ready', 'pad_in', 'mesh_in',
                     'fabric_readback'):
            getattr(d, name).value = 0
        d.pad_in.value = 0b11
        await ClockCycles(d.clk, 4)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        cocotb.start_soon(self._memory())
        cocotb.start_soon(self._streams())

    async def _memory(self):
        d = self.dut
        d.mem_ready.value = 1
        pending = None
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            req = int(d.mem_req.value)
            addr = int(d.mem_addr.value)
            await FallingEdge(d.clk)
            if pending is not None:
                d.mem_rvalid.value = 1
                d.mem_rdata.value = self.program[pending] if pending < len(self.program) else 0
            else:
                d.mem_rvalid.value = 0
            pending = addr - PROG_BASE if req else None

    async def _streams(self):
        """Drive at the falling edge, sample the settled handshake in that
        timestep's ReadOnly (what the DUT acts on at the next rising edge),
        and apply it at the following falling edge."""
        d = self.dut
        d.wr_ready.value = 1
        await FallingEdge(d.clk)
        while True:
            d.rd_valid.value = 1 if self.source else 0
            d.rd_data.value = self.source[0] if self.source else 0
            d.fabric_readback.value = len(self.source) + (len(self.sink) << 16)
            await ReadOnly()
            consume = int(d.rd_consume.value) and self.source
            push = int(d.wr_valid.value)
            data = int(d.wr_data.value)
            assert not int(d.stream_fault.value), 'stream fault'
            await FallingEdge(d.clk)
            if consume:
                self.source.pop(0)
            if push:
                self.sink.append(data)

    async def configure(self, words, program):
        d = self.dut
        await FallingEdge(d.clk)
        d.arm.value = 0
        full = {i: 0 for i in range(38)}
        full.update(words)
        words_list = assemble(program)
        full[W_PROG] = ((len(words_list) - 1) << 10) | PROG_BASE
        self.program = program_bytes(words_list)
        for address, value in sorted(full.items()):
            await FallingEdge(d.clk)
            d.cfg_we.value = 1; d.cfg_addr.value = address; d.cfg_data.value = value
        await FallingEdge(d.clk)
        d.cfg_we.value = 0
        await ClockCycles(d.clk, 2)
        await FallingEdge(d.clk)
        assert int(d.configured.value), 'lane core refused the configuration'
        d.arm.value = 1

    async def run(self, limit):
        d = self.dut
        await FallingEdge(d.clk)
        d.start.value = 1
        await FallingEdge(d.clk)
        d.start.value = 0
        for cycle in range(limit):
            await FallingEdge(d.clk)
            if int(d.done.value):
                return cycle, bool(int(d.error.value))
        raise AssertionError('lane did not finish')


def parity_bit(value, odd=False):
    return (bin(value).count('1') & 1) ^ int(odd)


async def uart_receive(dut, count, bit, parity_odd=None, limit=None):
    """Frames from out_value[0]; checks start, parity (if given) and stop.
    Gives up after `limit` idle clocks (default 30 bit times) and returns the
    frames so far, so a lane that stops early fails instead of hanging."""
    out = []
    limit = limit or bit * 30
    line = lambda: dut.out_value.value[0]
    while len(out) < count:
        for _ in range(limit):
            await FallingEdge(dut.clk)
            assert line().is_resolvable, f'out_value {dut.out_value.value}'
            if int(line()) == 0:
                break
        else:
            return out
        await ClockCycles(dut.clk, bit // 2)
        assert int(line()) == 0, 'short start bit'
        value = 0
        for i in range(8):
            await ClockCycles(dut.clk, bit)
            value |= int(line()) << i
        if parity_odd is not None:
            await ClockCycles(dut.clk, bit)
            assert int(line()) == parity_bit(value, parity_odd), f'parity {value:#x}'
        await ClockCycles(dut.clk, bit)
        assert int(line()) == 1, f'framing {value:#x}'
        out.append(value)
    return out


async def uart_send(dut, frames, bit, parity_odd=False, bad_parity=(), pad=0):
    """8 data bits, parity, stop on pad `pad` (fractional bit length ok)."""
    clock = 0.0
    for index, value in enumerate(frames):
        par = parity_bit(value, parity_odd) ^ (1 if index in bad_parity else 0)
        levels = [0] + [value >> i & 1 for i in range(8)] + [par, 1, 1]
        for level in levels:
            current = int(dut.pad_in.value)
            dut.pad_in.value = (current & ~(1 << pad)) | (level << pad)
            target = clock + bit
            while clock + 1 <= target + 1e-9:
                await FallingEdge(dut.clk)
                clock += 1


@cocotb.test()
async def coder_uart_tx_auto_pull(dut):
    """UART 8E1 transmit with no controller per byte: the coded shifter
    pulls bytes itself on timer0 ticks; the lane FIREs the timer and waits
    for the shifter to go idle."""
    core = Core(dut)
    await core.reset()
    bit = 16
    payload = [0x55, 0x00, 0xFF, 0xA5, 0x3C, 0x81]
    words = {
        W_T0: bit, W_T0 + 1: bit,
        W_TSEL: pair(FIRE, NEVER), W_TSEL + 1: pair(NEVER, NEVER), W_TSEL + 2: pair(NEVER, NEVER),
        W_CODER + 0: frame_word(8, pre=1, pre_val=0, post=1, post_val=1, parity=1, idle=1),
        W_CODER + 1: pair(T0_TICK, NEVER),                 # shift on timer0 tick
        W_CODER + 2: (1 << 11) | T0_TICK,                  # auto pull, start on a tick
        W_EV: pair(C_STOP, NEVER),
        W_OUT: pair(C_SERIAL, HIGH),
    }
    await core.configure(words, 'FIRE\nWAIT 0\nHALT')
    core.source = list(payload)
    receiver = cocotb.start_soon(uart_receive(dut, len(payload), bit, parity_odd=False))
    cycles, error = await core.run(bit * 12 * (len(payload) + 2))
    got = await receiver
    dut._log.info('UART 8E1 TX: %s in %d clocks', [hex(b) for b in got], cycles)
    assert not error and got == payload, (error, got)


async def rx_config(core, bit, resync=True, program=None):
    words = {
        # The sample lands SAMPLE_LATENCY clocks after a tick count ends (the
        # tick and the coder's sample are registered), so both the first
        # tick and the resync phase aim that much early to hit mid-bit.
        W_T0: bit // 2 - SAMPLE_LATENCY, W_T0 + 1: bit,    # first sample mid start bit
        W_T0 + 2: (3 | (4 << 8)) if resync else 0,         # resync, limit 4
        W_T0 + 3: bit // 2 - SAMPLE_LATENCY,               # phase: mid bit after a fall
        W_TSEL: pair(IN0_FALL, C_STOP), W_TSEL + 1: pair(IN0_FALL if resync else NEVER, NEVER),
        W_TSEL + 2: pair(NEVER, NEVER),
        W_CODER + 0: frame_word(8, pre=1, pre_val=0, post=1, post_val=1, parity=1, idle=1),
        W_CODER + 1: pair(T0_TICK, T0_TICK),               # shift and sample on the tick
        W_CODER + 2: ((IN0 - 32) << 6) | IN0_FALL,         # input level in0, start on its fall
        W_EV: pair(C_WORD, NEVER),
    }
    await core.configure(words, program or '''
            SETC 6
    next:   WAIT 0              # coder word
            RD 1                # status
            AND 0x40            # word bad
            JNZ bad
            RD 0
            PUSH
            LOOP next
            HALT
    bad:    FAIL
    ''')


@cocotb.test()
async def coder_uart_rx_parity_and_resync(dut):
    """UART 8E1 receive at 5% drift: timer0 resyncs on falling edges; the
    controller checks the coder's word-bad bit and pushes good bytes. A byte
    with a wrong parity bit fails the lane."""
    core = Core(dut)
    await core.reset()
    bit = 16
    payload = [0x55, 0xA5, 0x3C, 0x96, 0x0F, 0xC3]
    for drift in (0.0, 0.05, -0.05):
        await rx_config(core, bit)
        core.sink = []
        sender = cocotb.start_soon(uart_send(dut, payload, bit * (1 + drift)))
        cycles, error = await core.run(bit * 14 * len(payload) + 500)
        await sender
        dut._log.info('UART 8E1 RX drift %+.0f%%: %s error %s', drift * 100, [hex(b) for b in core.sink], error)
        assert not error and core.sink == payload, (drift, error, core.sink)
    await rx_config(core, bit)
    core.sink = []
    sender = cocotb.start_soon(uart_send(dut, payload, bit, bad_parity={3}))
    cycles, error = await core.run(bit * 14 * len(payload) + 500)
    await sender
    dut._log.info('bad parity on byte 3: pushed %s, error %s', [hex(b) for b in core.sink], error)
    assert error and core.sink == payload[:3], (error, core.sink)


@cocotb.test()
async def capture_on_timer1(dut):
    """Timer1 in capture mode measures in1 rising-edge periods; the lane
    reads them back and pushes them."""
    core = Core(dut)
    await core.reset()
    words = {
        W_T1: 1, W_T1 + 1: 1, W_T1 + 2: 2,                 # capture
        W_TSEL + 1: pair(NEVER, NEVER), W_TSEL + 2: pair(NEVER, IN1_RISE),
        W_EV: pair(IN1_RISE, NEVER),
    }
    await core.configure(words, '''
            SETC 3
            CLEAR
            WAIT 0
    next:   WAIT 0
            RD 3
            PUSH
            SHR
            SHR
            SHR
            SHR
            SHR
            SHR
            SHR
            SHR
            PUSH
            LOOP next
            HALT
    ''')
    periods = [100, 333, 1000]
    core.sink = []

    async def pulses():
        await ClockCycles(dut.clk, 50)
        await FallingEdge(dut.clk)
        for period in [None] + periods:
            if period is not None:
                for _ in range(period - 10):
                    await FallingEdge(dut.clk)
            dut.pad_in.value = int(dut.pad_in.value) | 2
            for _ in range(10):
                await FallingEdge(dut.clk)
            dut.pad_in.value = int(dut.pad_in.value) & 1
    dut.pad_in.value = 1
    driver = cocotb.start_soon(pulses())
    cycles, error = await core.run(3000)
    await driver
    got = [core.sink[2 * i] | core.sink[2 * i + 1] << 8 for i in range(len(periods))]
    dut._log.info('timer1 captures %s for periods %s', got, periods)
    assert not error and got == periods, (error, got)


@cocotb.test()
async def invalid_configurations_refused(dut):
    """Reserved lines, N=1 equal-bit stuffing, Manchester with NRZI, a CRC
    shape with reserved bits, a half-set timer: each leaves the core
    unconfigured."""
    core = Core(dut)
    await core.reset()
    d = dut
    cases = {
        'reserved pulse line 19 on timer0 start': {W_TSEL: pair(19, NEVER)},
        'reserved level line 51 as output value': {W_OUT: pair(51, HIGH)},
        'selector word reserved bits': {W_EV: 1 << 12},
        'stuffing N=1 of equal bits': {W_CODER + 4: 1},
        'Manchester with NRZI': {W_CODER + 4: 0x8010},
        'CRC shape reserved bit': {W_CRC + 6: 1 << 10},
        'timer0 first without period': {W_T0: 5},
        'timer0 mode reserved bits': {W_T0: 5, W_T0 + 1: 5, W_T0 + 2: 1 << 2},
        'settings reserved bits': {W_SET: 1},
    }
    for name, words in cases.items():
        await FallingEdge(d.clk)
        d.arm.value = 0
        full = {i: 0 for i in range(38)}
        full.update(words)
        for address, value in sorted(full.items()):
            await FallingEdge(d.clk)
            d.cfg_we.value = 1; d.cfg_addr.value = address; d.cfg_data.value = value
        await FallingEdge(d.clk)
        d.cfg_we.value = 0
        await ClockCycles(d.clk, 2)
        assert not int(d.configured.value), f'accepted: {name}'
    # And the all-zero configuration is valid (nothing selected, nothing runs).
    full = {i: 0 for i in range(38)}
    for address, value in sorted(full.items()):
        await FallingEdge(d.clk)
        d.cfg_we.value = 1; d.cfg_addr.value = address; d.cfg_data.value = value
    await FallingEdge(d.clk)
    d.cfg_we.value = 0
    await ClockCycles(d.clk, 2)
    assert int(d.configured.value)

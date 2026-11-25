"""Compiled 10BASE-T link session (link pulses, frame, TP_IDL) at chip pins.

The image is the sibling compiler's lowering of the whole exported
`transmit()` in examples/ethernet_tx_coded.spt. The observer below has no
configuration knowledge: it applies the same digital checks as the source
language's `ethernet_link` peer (4-clock (1,0) link pulses exactly
10 * NLP_TICK apart, Manchester frame, CRC32, exactly 12 clocks of TP_IDL).
Top-level pins and host commands only, so the test is gate-level safe.
"""
import json
import os
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

DATA = Path(__file__).parents[1] / 'data'
GATE_LEVEL = os.environ.get('GATES') == 'yes'


class LinkObserver:
    """Digital 10BASE-T transmit observer at 40 MHz (positive=uio[6], negative=uio[5])."""

    def __init__(self, pulse_period):
        self.pulse_period = pulse_period
        self.frames, self.pulses, self.problems = [], [], []
        self.cycle, self.states, self.start = 0, [], 0

    def decode(self, states, start):
        if states == [(1, 0)] * 4:
            if self.pulses and start - self.pulses[-1] != self.pulse_period:
                self.problems.append(f'link pulses {start - self.pulses[-1]} clocks apart, expected {self.pulse_period}')
            self.pulses.append(start)
            return
        if len(states) < (8 + 60 + 4) * 32 + 12:
            self.problems.append(f'short or malformed pulse/frame of {len(states)} clocks: {states[:16]}')
            return
        body, idle = states[:-12], states[-12:]
        # A longer idle leaves extra (1,0) clocks in the body, breaking whole bytes.
        if idle != [(1, 0)] * 12 or len(body) % 32:
            tail = 0
            while tail < len(states) and states[-1 - tail] == (1, 0):
                tail += 1
            self.problems.append(f'frame has {len(states)} clocks with {tail} trailing (1,0) clocks; expected whole bytes plus 12 idle')
            return
        bits = []
        for i in range(0, len(body), 4):
            first, second = body[i:i + 2], body[i + 2:i + 4]
            if len(set(first)) != 1 or len(set(second)) != 1 or first[0] not in ((1, 0), (0, 1)) or second[0] != first[0][::-1]:
                self.problems.append(f'invalid Manchester half bit at clock {i}')
                return
            bits.append(int(second[0] == (1, 0)))
        data = bytes(sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits), 8))
        if data[:8] != bytes([0x55] * 7 + [0xD5]):
            self.problems.append(f'bad preamble/SFD {data[:8].hex()}')
            return
        frame, check = data[8:-4], data[-4:]
        if check != zlib.crc32(frame).to_bytes(4, 'little'):
            self.problems.append(f'bad FCS {check.hex()}')
            return
        self.frames.append((start, frame))

    def sample(self, out, oe):
        self.cycle += 1
        driven = (oe & 0x60) == 0x60
        state = (((out >> 6) & 1), ((out >> 5) & 1)) if driven else (0, 0)
        if state == (0, 0):
            if self.states:
                self.decode(self.states, self.start)
                self.states = []
        else:
            if not self.states:
                self.start = self.cycle
            self.states.append(state)


async def run_session(dut, stem, sessions):
    image = [int(x, 16) for x in (DATA / f'{stem}.mem').read_text().splitlines()]
    program = json.loads((DATA / f'{stem}.json').read_text())
    payload = bytes(program['payload_bytes'])
    assert len(image) == 185 and image[66] == len(payload) and program['full_source_function_compiled']
    period = program['link_pulse_period_cycles']
    cocotb.start_soon(Clock(dut.clk, 25, unit='ns').start())
    dut.ena.value = 1; dut.rst_n.value = 0; dut.ui_in.value = 0
    state = {'op': 0, 'strobe': 0}

    def drive():
        dut.uio_in.value = (state['op'] << 2) | (state['strobe'] << 1) | 1

    drive(); await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk); dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)

    async def command(op, data):
        await FallingEdge(dut.clk); dut.ui_in.value = data; state['op'] = op; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); state['strobe'] = 1; drive()
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk); state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)

    async def config(i, w):
        await command(1, 0); await command(0, i); await command(6, w & 255); await command(7, w >> 8)

    await command(4, 8)
    for index, word in enumerate(image):
        await config(index, word)
    await command(4, 0); await command(4, 4)
    assert int(dut.uio_oe.value) & 0x80, 'link session image did not arm'
    for i, byte in enumerate(payload):
        await command(0, (100 + i) & 255); await command(1, (100 + i) >> 8); await command(2, byte)
    observer = LinkObserver(period)
    running = {'on': True}

    async def watch():
        while running['on']:
            await RisingEdge(dut.clk)
            observer.sample(int(dut.uio_out.value), int(dut.uio_oe.value))

    watcher = cocotb.start_soon(watch())
    for session in range(sessions):
        state['op'] = 4; state['strobe'] = 0; drive()
        await command(5, 0)
        # Status (opcode 4, idle strobe) bit 5 is tx_active; the session takes
        # three pulse periods plus host latency.
        state['op'] = 4; drive()
        for _ in range(4 * period // 1000 + 400):
            await ClockCycles(dut.clk, 1000)
            if not (int(dut.uo_out.value) >> 5) & 1:
                break
        else:
            assert False, f'session {session} did not finish'
        assert not (int(dut.uo_out.value) >> 6) & 1, f'session {session} reported an error'
        assert len(observer.pulses) == 3 * (session + 1), (session, observer.pulses, observer.problems)
    await ClockCycles(dut.clk, 20)
    running['on'] = False
    await watcher
    assert not observer.problems, observer.problems
    assert [f for _, f in observer.frames] == [payload[8:]] * sessions
    for s in range(sessions):
        p0, p1, p2 = observer.pulses[3 * s:3 * s + 3]
        frame_start = observer.frames[s][0]
        assert p1 < frame_start < p2, 'frame must follow the second link pulse of its session'
    dut._log.info('%d compiled link session(s): pulses %s, frames at %s (period %d clocks)',
                  sessions, observer.pulses, [x for x, _ in observer.frames], period)


@cocotb.test()
async def ethernet_link_sessions_fast_tick(dut):
    """Two back-to-back sessions with NLP_TICK=4000 (GL-friendly)."""
    await run_session(dut, 'grid-ethernet-session-fast', 2)


@cocotb.test(skip=GATE_LEVEL)
async def ethernet_link_session_real_time(dut):
    """The unmodified source: 16 ms link pulse period at 40 MHz (RTL only)."""
    await run_session(dut, 'grid-ethernet-session', 1)

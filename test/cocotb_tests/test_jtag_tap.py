"""Black-box multiframe JTAG TAP IDCODE transaction on the grid chip."""
from pathlib import Path
import json
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

# TAP specification's state transition table; this peer is independent of RTL.
NEXT = {
    'RESET': ('IDLE', 'RESET'), 'IDLE': ('IDLE', 'SELECT_DR'),
    'SELECT_DR': ('CAPTURE_DR', 'SELECT_IR'), 'CAPTURE_DR': ('SHIFT_DR', 'EXIT1_DR'),
    'SHIFT_DR': ('SHIFT_DR', 'EXIT1_DR'), 'EXIT1_DR': ('PAUSE_DR', 'UPDATE_DR'),
    'PAUSE_DR': ('PAUSE_DR', 'EXIT2_DR'), 'EXIT2_DR': ('SHIFT_DR', 'UPDATE_DR'),
    'UPDATE_DR': ('IDLE', 'SELECT_DR'), 'SELECT_IR': ('CAPTURE_IR', 'RESET'),
    'CAPTURE_IR': ('SHIFT_IR', 'EXIT1_IR'), 'SHIFT_IR': ('SHIFT_IR', 'EXIT1_IR'),
    'EXIT1_IR': ('PAUSE_IR', 'UPDATE_IR'), 'PAUSE_IR': ('PAUSE_IR', 'EXIT2_IR'),
    'EXIT2_IR': ('SHIFT_IR', 'UPDATE_IR'), 'UPDATE_IR': ('IDLE', 'SELECT_DR'),
}
IDCODE = 0x1BA00477


async def run_jtag_source_test(dut, fixture):
    cocotb.start_soon(Clock(dut.clk, 20, unit='ns').start())
    dut.ena.value = 1; dut.rst_n.value = 0; dut.ui_in.value = 0
    host = {'op': 0, 'strobe': 0, 'tdo': 1}
    def drive():
        dut.uio_in.value = (host['op'] << 2) | (host['strobe'] << 1) | host['tdo']
    drive(); await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk); dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)

    async def command(op, data):
        await FallingEdge(dut.clk); dut.ui_in.value = data
        host['op'] = op; host['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); host['strobe'] = 1; drive()
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk); host['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)

    async def config(index, word):
        await command(0, index); await command(6, word & 255); await command(7, word >> 8)
    async def write_byte(address, value):
        await command(0, address & 255); await command(1, address >> 8); await command(2, value)
    async def read_byte(address):
        await command(0, address & 255); await command(1, address >> 8); await command(3, 0)
        await ClockCycles(dut.clk, 5); await FallingEdge(dut.clk)
        return int(dut.uo_out.value)

    # The compiler expands the source test into packed TDI/TMS frames and
    # emits source expectations with exact bit offsets. Padding is only idle.
    root = Path(__file__).parents[1] / 'data'
    program = json.loads(Path(os.environ.get('JTAG_PROGRAM', root / fixture)).read_text())
    payload = program['payload_bytes']; frames = program['rx_capacity']
    assert len(payload) == 2 * frames
    tdi = [(payload[2*i] >> bit) & 1 for i in range(frames) for bit in range(8)]
    tms = [(payload[2*i+1] >> bit) & 1 for i in range(frames) for bit in range(8)]
    image_path = Path(os.environ.get('JTAG_IMAGE', root / 'grid-jtag-temporal.mem'))
    image = [int(x, 16) for x in image_path.read_text().splitlines()]
    await command(4, 11)
    for addr, word in enumerate(image):
        await config(addr, word)
    await config(66, len(payload)); await config(67, frames); await config(68, 0)
    await command(4, 3); await command(6, 100); await command(7, 200); await command(4, 7)
    for offset, byte in enumerate(payload):
        await write_byte(100 + offset, byte)

    async def tap():
        previous = 0; state = 'RESET'; shift = 0; length = 1; ir = 14; user = 0; index = 0; expected_rx = []
        peer_checks = {c['bit_offset']: c['value'] for c in program.get('peer_checks', [])}
        host['tdo'] = 1; drive()
        for _ in range(10000):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            pins = int(dut.uio_out.value); clock = (pins >> 5) & 1
            mode = int(dut.uo_out.value) & 1; data = (pins >> 6) & 1
            if clock and not previous:
                assert index < len(tms), 'unexpected extra clock edge'
                assert mode == tms[index] and data == tdi[index], (index, mode, data)
                if index in peer_checks:
                    assert user == peer_checks[index], (index, user, peer_checks[index])
                expected_rx.append(host['tdo'])
                if state in ('SHIFT_DR', 'SHIFT_IR'):
                    shift = (shift >> 1) | (data << (length - 1))
                state = NEXT[state][mode]
                if state == 'CAPTURE_DR':
                    shift,length = ((IDCODE,32) if ir==14 else (user,8) if ir==10 else (0,1))
                elif state == 'CAPTURE_IR':
                    shift,length = 1,4
                elif state == 'UPDATE_IR':
                    ir = shift
                elif state == 'UPDATE_DR' and ir == 10:
                    user = shift
                elif state == 'RESET':
                    ir = 14
                index += 1
            if previous and not clock:
                host['tdo'] = (shift & 1) if state in ('SHIFT_DR', 'SHIFT_IR') else 1
                drive()
            previous = clock
            if pins & 0x80:
                assert index == len(tms), (index, len(tms))
                assert state == 'IDLE', state
                return expected_rx
        dut._log.info('JTAG timeout after %d edges, TAP=%s, uio=%#x oe=%#x', index, state, int(dut.uio_out.value), int(dut.uio_oe.value))
        assert False, 'JTAG transaction did not complete'

    task = cocotb.start_soon(tap())
    await command(5, 0)
    await FallingEdge(dut.clk); host['op'] = 7; host['strobe'] = 0; drive()
    captured = await task
    data = [await read_byte(200 + i) for i in range(frames)]
    observed = [(data[i // 8] >> (i % 8)) & 1 for i in range(len(tms))]
    assert observed == captured, (observed, captured)
    for check in program['checks']:
        value = sum(observed[check['bit_offset'] + i] << i for i in range(check['width']))
        assert value == check['value'], (check, value)
    if program['source_test'] == 'reset and read a 32-bit IDCODE':
        result = sum(observed[9 + i] << i for i in range(32))
        assert result == IDCODE, hex(result)
        dut._log.info('TAP IDCODE %#010x read across %d SRAM frames', result, frames)
    else:
        dut._log.info('TAP user-register source checks passed across %d SRAM frames', frames)


@cocotb.test()
async def read_idcode_across_sram_frames(dut):
    await run_jtag_source_test(dut, 'grid-jtag-idcode.json')


@cocotb.test()
async def write_and_read_tap_user_register(dut):
    await run_jtag_source_test(dut, 'grid-jtag-user.json')

"""Pin-only test of a programmed two-frame I2C write transaction."""
from pathlib import Path
import os
import json

import cocotb
from cocotb_tests.descriptor_fold import fold
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer
from cocotb.utils import get_sim_time


PAGE_BASE = 512


def paged_program(image):
    """Split the temporal I2C program across two SRAM pages.

    Rows 0-7 stay in page 0 and row 8 becomes a page row that holds row 8's
    action while page 1 loads, then enters row 9 there. Page 1 keeps rows
    9-15 at the same indices. Both pages carry the same alternate contexts.
    Returns the SRAM bytes as {address: value}.
    """
    rows = image[96:112]
    contexts = image[112:117]
    filler = 0x8007  # halt with error; unreachable
    action8 = rows[8] & 15
    assert rows[8] >> 4 & 7 == 0, 'row 8 must be an always row'
    page0 = rows[:8] + [0xC000 | 1 << 8 | 9 << 4 | action8] + [filler] * 7
    page1 = [filler] * 9 + rows[9:]
    out = {}
    for page, page_rows in enumerate((page0, page1)):
        words = page_rows + contexts
        for k, word in enumerate(words):
            out[PAGE_BASE + 64 * page + 2 * k] = word & 255
            out[PAGE_BASE + 64 * page + 2 * k + 1] = word >> 8
    return out


@cocotb.test()
async def programmed_i2c_write(dut):
    await _temporal_i2c(dut, paged=False)


@cocotb.test()
async def programmed_i2c_write_paged(dut):
    """The same transaction with its program fetched from SRAM pages."""
    await _temporal_i2c(dut, paged=True)


def watchdog_words(cycles):
    """Lane B watches lane A from cell 13: it starts timer 3 through the
    fabric and fails the transfer if lane A is still running when the timer
    level rises. Returns {config word: value}."""
    return {
        143: 3 | 4 << 3,          # cell 12 east tracks 0,1 = lane B actions 0,1
        179: 14,                  # timer 3 start <- west track 0 (action 0)
        180: 15,                  # timer 3 stop  <- west track 1 (action 1)
        174: cycles, 175: 0xFFFF,  # timer 3 first expiry, then effectively never
        185: 5,                   # lane B sink 43 <- timer 3 level
        192: 2 << 11 | 1 << 7 | 6 << 4 | 1,  # 0: lane A done -> 2, else 1; start timer
        193: 0 << 11 | 3 << 7 | 3 << 4 | 1,  # 1: timer level -> 3, else 0
        194: 0x8002,              # 2: halt, stop timer
        195: 0x8006,              # 3: halt with error, stop timer
        188: 1 << 8 | 2 << 4,     # enable, idle actions stop the timer, entry 0
    }


@cocotb.test()
async def programmed_i2c_write_watchdog(dut):
    """Lane B runs a bus watchdog beside the transaction; all cases pass."""
    await _temporal_i2c(dut, paged=False, watchdog=0xF000)


@cocotb.test()
async def programmed_i2c_write_descriptors(dut):
    """The same transaction with row pairs folded into descriptor rows."""
    await _temporal_i2c(dut, paged=False, descriptors=True)


@cocotb.test()
async def i2c_bus_hang_watchdog(dut):
    """A target that holds SCL low forever: lane B times out and aborts lane A."""
    await _temporal_i2c(dut, paged=False, watchdog=3000, hang=True)


async def _temporal_i2c(dut, paged, watchdog=None, hang=False, descriptors=False):
    cocotb.start_soon(Clock(dut.clk, 20, unit='ns').start())
    dut.ena.value = 1; dut.rst_n.value = 0; dut.ui_in.value = 0
    state = {'op':0, 'strobe':0, 'scl':1, 'sda':1}

    def drive():
        dut.uio_in.value = (state['sda'] << 6) | (state['scl'] << 5) | (state['op'] << 2) | (state['strobe'] << 1) | 1

    drive(); await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk); dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)

    async def command(op, data):
        await FallingEdge(dut.clk); dut.ui_in.value = data
        state['op'] = op; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); state['strobe'] = 1; drive()
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk); state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)

    async def config(index, word):
        await command(0, index); await command(6, word & 255); await command(7, word >> 8)

    async def write_byte(address, value):
        await command(0, address & 255); await command(1, address >> 8); await command(2, value)

    async def read_byte(address):
        await command(0, address & 255); await command(1, address >> 8); await command(3, 0)
        await ClockCycles(dut.clk, 5); await FallingEdge(dut.clk)
        return int(dut.uo_out.value)

    image_path = Path(os.environ.get('TEMPORAL_I2C_IMAGE', str(Path(__file__).parents[1] / 'data/temporal-i2c.mem')))
    image = [int(x, 16) for x in image_path.read_text().splitlines()]
    assert len(image) == 117
    if descriptors:
        rows = fold(image[96:112], entry=image[92] & 15)
        assert len(rows) < 16 and any(r >> 12 in (0xD, 0xE) for r in rows), rows
        dut._log.info('descriptor program: %d rows instead of 16: %s', len(rows), ' '.join(f'{r:04x}' for r in rows))
        image[96:112] = rows + [0x8007] * (16 - len(rows))
    program_path = os.environ.get("TEMPORAL_I2C_PROGRAM")
    program = json.loads(Path(program_path).read_text()) if program_path else {"payload_bytes": [1, 0x21, 1, 0x4d]}
    payload = program["payload_bytes"]
    assert len(payload) == 4, "pin peer expects two frames"
    expected = [((payload[i] << 8 | payload[i + 1]) >> 1) for i in (0, 2)]
    await command(4, 8)
    for address, word in enumerate(image):
        await config(address, word)
    if paged:
        await config(94, 0x8000 | PAGE_BASE)
    if watchdog is not None:
        for address, word in watchdog_words(watchdog).items():
            await config(address, word)
    await command(4, 0); await command(4, 4)
    assert int(dut.uio_oe.value) & 0x80, 'temporal configuration did not arm'
    for offset, value in enumerate(payload):
        await write_byte(100 + offset, value)
    if paged:
        for address, value in paged_program(image).items():
            await write_byte(address, value)

    async def peer(nack_index=None, stretch=False):
        prev_scl = prev_sda = 1
        prev_master_scl_low = False
        started = False; stopped = False; bit_count = 0; value = 0; values = []
        target_low = False; stretch_left = 0; stretched = False; stretch_cycles = 0; last_fall = None
        ack_sample_time = None; min_low_ns = None
        for _ in range(30000):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            enables = int(dut.uio_oe.value)
            master_scl_low = bool(enables & 0x20)
            master_sda_low = bool(enables & 0x40)
            if stretch and started and not stretched and len(values) == 0 and bit_count == 3 and prev_master_scl_low and not master_scl_low:
                stretch_left = 600; stretched = True
            if stretch_left:
                scl = 0; stretch_left -= 1; stretch_cycles += 1
            else:
                scl = int(not master_scl_low)
            sda = int(not (master_sda_low or target_low))
            if prev_scl and scl and prev_sda and not sda:
                assert not started, 'unexpected repeated START'
                started = True
            if started and prev_scl and scl and not prev_sda and sda:
                stopped = True
                dut._log.info('ACK sample to STOP: %s ns; minimum SCL low: %s ns',
                              int(get_sim_time(unit='ns')) - ack_sample_time, min_low_ns)
                state['scl'] = scl; state['sda'] = sda; drive()
                break
            if started and not prev_scl and scl:
                if last_fall is not None:
                    low_ns = int(get_sim_time(unit='ns')) - last_fall
                    assert low_ns >= 5000, 'SCL low phase too short'
                    min_low_ns = low_ns if min_low_ns is None else min(min_low_ns, low_ns)
                if bit_count < 8:
                    value = (value << 1) | sda
                bit_count += 1
                if bit_count == 9:
                    ack_sample_time = int(get_sim_time(unit='ns'))
            if started and prev_scl and not scl:
                last_fall = int(get_sim_time(unit='ns'))
                if bit_count == 8:
                    target_low = len(values) != nack_index
                elif bit_count == 9:
                    values.append(value); value = 0; bit_count = 0; target_low = False
            state['scl'] = scl; state['sda'] = int(not (master_sda_low or target_low)); drive()
            prev_scl, prev_sda = scl, state['sda']
            prev_master_scl_low = master_scl_low
        assert started and stopped, 'transaction did not produce START and STOP'
        if stretch:
            assert stretched and stretch_cycles == 600, 'clock stretch was not exercised'
        return values

    async def run_case(nack_index=None, stretch=False):
        task = cocotb.start_soon(peer(nack_index, stretch))
        await command(5, 0)
        for _ in range(30000):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if int(dut.uio_out.value) & 0x80:
                break
        else:
            assert False, 'sequencer did not finish'
        values = await task
        state['op'] = 4; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 5); await FallingEdge(dut.clk)
        status = int(dut.uo_out.value)
        dut._log.info('temporal I2C peer observed %s; status=%#x', values, status)
        assert bool(status & 0x40) == (nack_index is not None), f'error status {status:#x}'
        assert values == (expected[:1] if nack_index == 0 else expected), values

    if hang:
        async def stuck_peer():
            # Pull SCL low as soon as the master starts and never release it.
            for _ in range(100000):
                await FallingEdge(dut.clk); await Timer(1, unit='ns')
                if int(dut.uio_oe.value) & 0x60:
                    break
            state['scl'] = 0; drive()
        cocotb.start_soon(stuck_peer())
        start = int(get_sim_time(unit='ns'))
        await command(5, 0)
        for _ in range(20000):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            if int(dut.uio_out.value) & 0x80:
                break
        else:
            assert False, 'watchdog did not end the hung transfer'
        elapsed = (int(get_sim_time(unit='ns')) - start) // 20
        await ClockCycles(dut.clk, 2); await FallingEdge(dut.clk)
        assert int(dut.uio_oe.value) & 0x60 == 0, 'pins not released after the timeout'
        state['op'] = 4; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 5); await FallingEdge(dut.clk)
        status = int(dut.uo_out.value)
        dut._log.info('hung bus ended after %d clocks; status=%#x', elapsed, status)
        assert status & 0x40, f'timeout not reported as an error: {status:#x}'
        assert 3000 <= elapsed < 6000, elapsed
        return
    await run_case(stretch=True)
    received = [await read_byte(i) for i in range(200, 204)]
    assert received == [v for b in expected for v in (((b << 1) >> 8), ((b << 1) & 255))]
    await run_case(nack_index=0)
    await run_case(nack_index=1)

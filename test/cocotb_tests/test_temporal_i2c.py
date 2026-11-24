"""Pin-only test of a programmed two-frame I2C write transaction."""
from pathlib import Path
import os
import json

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer
from cocotb.utils import get_sim_time


@cocotb.test()
async def programmed_i2c_write(dut):
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
    program_path = os.environ.get("TEMPORAL_I2C_PROGRAM")
    program = json.loads(Path(program_path).read_text()) if program_path else {"payload_bytes": [1, 0x21, 1, 0x4d]}
    payload = program["payload_bytes"]
    assert len(payload) == 4, "pin peer expects two frames"
    expected = [((payload[i] << 8 | payload[i + 1]) >> 1) for i in (0, 2)]
    await command(4, 8)
    for address, word in enumerate(image):
        await config(address, word)
    await command(4, 0); await command(4, 4)
    assert int(dut.uio_oe.value) & 0x80, 'temporal configuration did not arm'
    for offset, value in enumerate(payload):
        await write_byte(100 + offset, value)

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

    await run_case(stretch=True)
    received = [await read_byte(i) for i in range(200, 204)]
    assert received == [v for b in expected for v in (((b << 1) >> 8), ((b << 1) & 255))]
    await run_case(nack_index=0)
    await run_case(nack_index=1)

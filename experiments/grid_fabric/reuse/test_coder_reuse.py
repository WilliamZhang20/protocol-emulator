"""Check legacy coder/CRC reuse against the earlier packet reference models."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb_tests.line_codes import USB_SYNC, crc16_usb, ethernet_fcs, lsb_bits, usb_encode
from cocotb_tests.test_usb import TX_CASES
from cocotb_tests.test_ethernet import test_frame


@cocotb.test()
async def legacy_packet_coder(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst_n.value = 0; dut.enable.value = 0
    dut.shift_cfg_we.value = 0; dut.crc_cfg_we.value = 0
    dut.lines.value = 0; dut.tx_grant.value = 0; dut.tx_data.value = 0; dut.tx_eop.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk); dut.rst_n.value = 1

    async def write(which, addr, value):
        await FallingEdge(dut.clk)
        getattr(dut, which + '_cfg_addr').value = addr
        getattr(dut, which + '_cfg_data').value = value
        getattr(dut, which + '_cfg_we').value = 1
        await FallingEdge(dut.clk); getattr(dut, which + '_cfg_we').value = 0

    async def run(payload, *, ethernet):
        await FallingEdge(dut.clk); dut.enable.value = 0; dut.lines.value = 0; dut.tx_grant.value = 0
        # Eight-bit LSB-first frame, tick on line 1, automatic FIFO pull,
        # burst termination from the last byte's EOP flag.
        await write('shift', 1, 7)
        await write('shift', 2, 1)
        await write('shift', 3, 1 << 11)
        await write('shift', 4, (1 << 5) | (1 << 6))
        coder = ((1 << 15) | (32 << 9)) if ethernet else (6 | (1 << 3) | (1 << 4) | (16 << 9))
        await write('shift', 5, coder)
        await write('shift', 6, (64 if ethernet else 16) << 6)
        poly = 0x04C11DB7 if ethernet else 0x8005
        for addr, value in [(0, poly & 0xffff), (1, poly >> 16), (2, 0), (3, 0),
                            (4, 0), (5, 0), (6, (31 if ethernet else 15) | 0x60), (7, 0)]:
            await write('crc', addr, value)
        await ClockCycles(dut.clk, 3)
        await FallingEdge(dut.clk); dut.enable.value = 1
        index = 0; observed = []
        for cycle in range(12000):
            await FallingEdge(dut.clk)
            tick = cycle % 4 == 0
            dut.lines.value = 2 if tick else 0
            await Timer(1, unit='ns')
            req = bool(int(dut.tx_request.value)) and index < len(payload)
            dut.tx_grant.value = req
            if req:
                dut.tx_data.value = payload[index]
                dut.tx_eop.value = index == len(payload)-1
            if tick and int(dut.active.value):
                observed.append(int(dut.serial.value))
            await RisingEdge(dut.clk)
            if req:
                index += 1
            await Timer(1, unit='ns')
            if int(dut.stop_pulse.value):
                # The final coded bit is presented with the stop pulse.
                observed.append(int(dut.serial.value))
                break
        else:
            assert False, 'legacy coded shifter did not stop'
        assert index == len(payload), (index, len(payload))
        return observed

    payload = TX_CASES['stuffing_mix']
    packet = bytes([USB_SYNC, 0xC3]) + payload
    observed = await run(packet, ethernet=False)
    expected = [int(s == 'K') for s in usb_encode(packet + crc16_usb(payload).to_bytes(2, 'little'))[:-3]]
    assert observed == expected, (next((i for i,(a,b) in enumerate(zip(observed,expected)) if a!=b), None), observed[-16:], expected[-16:], len(observed), len(expected))

    frame = test_frame()
    preamble = bytes([0x55] * 7 + [0xD5])
    observed = await run(preamble + frame, ethernet=True)
    bits = lsb_bits(preamble + frame + ethernet_fcs(frame))
    expected = [half for bit in bits for half in (1-bit, bit)]
    assert observed == expected, (observed[:24], expected[:24], len(observed), len(expected))

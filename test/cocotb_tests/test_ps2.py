"""PS/2 device-to-host reception on the spatial fabric: the device drives the
clock, and frames carry odd parity."""

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, drain_rx, load_program, select_channel, start_engine
from cocotb_tests.protocols import PS2_CLK, PS2_DATA, ps2_receive

HALF = 200   # scaled-down device clock half period


async def device_send(dut, bus: Bus, value: int) -> None:
    bits = [0] + [(value >> i) & 1 for i in range(8)]
    bits += [1 - (sum(bits[1:]) & 1), 1]          # odd parity, stop
    for bit in bits:
        bus.drive[PS2_DATA] = bit                  # change while CLK high
        await ClockCycles(dut.clk, HALF // 2)
        bus.drive[PS2_CLK] = 0                     # host samples on fall
        await ClockCycles(dut.clk, HALF)
        bus.drive[PS2_CLK] = None
        await ClockCycles(dut.clk, HALF // 2)
    bus.drive[PS2_DATA] = None


@cocotb.test()
async def test_ps2_scan_codes(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    await load_program(dut, ps2_receive())
    await start_engine(dut)
    await ClockCycles(dut.clk, 400)
    codes = [0x1C, 0xF0, 0x1C, 0x5A]

    async def device():
        for code in codes:
            await device_send(dut, bus, code)
            await ClockCycles(dut.clk, 3 * HALF)

    await select_channel(dut, 1)                 # shifter 1's channel
    sender = cocotb.start_soon(device())
    received = await drain_rx(dut, len(codes))
    await sender
    assert received == codes

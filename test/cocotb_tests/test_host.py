"""Host link: SRAM program readback and FIFO status, through the pins only."""

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import host_command, reset_top, start_clock
from cocotb_tests.fabric import load_program


async def read_sram(dut, address: int) -> int:
    await host_command(dut, 0x1, address)
    await host_command(dut, 0x2, address >> 4)
    await host_command(dut, 0x3, address >> 8)
    await host_command(dut, 0xB)
    await host_command(dut, 0x0)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_sram_readback(dut):
    """Every byte written through commands 4/5 reads back through B, at any
    address and in any order."""
    await start_clock(dut)
    await reset_top(dut)
    data = [(37 * i + 11) & 0xFF for i in range(16)]
    await load_program(dut, data, address=0x3F0)
    for index in [5, 0, 15, 7, 7, 3]:
        assert await read_sram(dut, 0x3F0 + index) == data[index], index


async def fifo_levels(dut) -> int:
    await host_command(dut, 0xC)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_held_command_acts_once(dut):
    """A command held for several cycles is accepted once; 8'h00 re-arms."""
    await start_clock(dut)
    await reset_top(dut)
    await host_command(dut, 0x6, 0x5)          # stage low nibble
    dut.ui_in.value = 0x7A                     # commit 0xA5, held 5 cycles
    await ClockCycles(dut.clk, 5)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 1)
    assert (await fifo_levels(dut) >> 3) & 0b111 == 1, "held push must act once"
    await host_command(dut, 0x7, 0xA)          # re-armed by 8'h00
    assert (await fifo_levels(dut) >> 3) & 0b111 == 2

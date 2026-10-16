"""Host link: SRAM program readback and FIFO status, through the pins only."""

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.common import host_command, reset_top, start_clock, wait_until_halted
from cocotb_tests.fabric import (MODE_PUSH_PULL, Px8, flag, load_program, pop_rx, push_tx,
                                 select_channel, start_engine)


OPR_CFG_BYTE = 0xE9      # OPR 9: block config load


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
    dut.ui_in.value = 0x7A                     # commit 0xA5, held 8 cycles
    await ClockCycles(dut.clk, 8)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 3)
    assert (await fifo_levels(dut) >> 3) & 0b111 == 1, "held push must act once"
    await host_command(dut, 0x7, 0xA)          # re-armed by 8'h00
    assert (await fifo_levels(dut) >> 3) & 0b111 == 2


@cocotb.test()
async def test_half_changed_byte_is_ignored(dut):
    """An asynchronous host changes ui_in bits at different moments. The
    byte seen for one cycle mid-change (here 0x0A, itself a nonzero byte)
    must not act, or the real command 0x5A that follows would be lost."""
    await start_clock(dut)
    await reset_top(dut)
    for address in (0x2A0, 0x2A1):
        await host_command(dut, 0x1, address)
        await host_command(dut, 0x2, address >> 4)
        await host_command(dut, 0x3, address >> 8)
        await host_command(dut, 0x4, 0xA)      # stage low nibble A
        dut.ui_in.value = 0x0A                 # low bits arrive first ...
        await ClockCycles(dut.clk, 1)
        dut.ui_in.value = 0x5A                 # ... then the high bits
        await ClockCycles(dut.clk, 2)
        dut.ui_in.value = 0
        await ClockCycles(dut.clk, 3)
    # Command 5 commits {payload, staged low nibble} = 0xAA.
    assert await read_sram(dut, 0x2A0) == 0xAA
    assert await read_sram(dut, 0x2A1) == 0xAA


@cocotb.test()
async def test_fifo_channels_are_separate(dut):
    """Host pushes and pops reach only the selected channel, and the
    controller's TXP and PUSH reach only the channel their operand names."""
    await start_clock(dut)
    await reset_top(dut)
    await select_channel(dut, 1)
    await push_tx(dut, 0x11)
    assert await fifo_levels(dut) == 0b01_001_000   # ch1: tx_level 1, rx empty
    await select_channel(dut, 0)
    assert await fifo_levels(dut) == 0b01_000_000   # ch0 untouched

    p = Px8()
    p.ldc(0x5A)
    p.txp(channel=0)
    p.ldc(0xC3)
    p.push(channel=1)
    p.ldc(0x3C)
    p.push(channel=0)
    p.halt()
    await load_program(dut, p.assemble())
    await start_engine(dut)
    await wait_until_halted(dut)

    assert await fifo_levels(dut) == 0b00_001_001   # ch0: TXP byte, one RX byte
    assert await pop_rx(dut) == 0x3C
    await select_channel(dut, 1)
    assert await fifo_levels(dut) == 0b00_001_001   # ch1: host byte, one RX byte
    assert await pop_rx(dut) == 0xC3


@cocotb.test()
async def test_block_config_and_controller_pull(dut):
    """A block config load (pin cells, flags, arm) drives the pins, and the
    controller pulls host bytes from a channel no shifter owns and pushes
    results back on it."""
    await start_clock(dut)
    await reset_top(dut)
    p = Px8()
    p.pin_cell(0, src=flag(0), mode=MODE_PUSH_PULL)
    p.pin_cell(1, src=flag(1), mode=MODE_PUSH_PULL)
    p.flags(0b10)
    p.arm()
    for _ in range(2):
        p.pull(channel=1)
        p.xrc(0xFF)
        p.push(channel=1)
    p.halt()
    program = p.assemble()
    assert OPR_CFG_BYTE in program, "the four writes must form one block"
    await load_program(dut, program)
    await select_channel(dut, 1)
    await start_engine(dut)
    await ClockCycles(dut.clk, 60)
    assert int(dut.uio_oe.value) & 0b11 == 0b11
    assert int(dut.uio_out.value) & 0b11 == 0b10
    await push_tx(dut, 0x5A)
    await push_tx(dut, 0x0F)
    await wait_until_halted(dut)
    assert await pop_rx(dut) == 0xA5
    assert await pop_rx(dut) == 0xF0


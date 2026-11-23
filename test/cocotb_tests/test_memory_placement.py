"""Black-box RTL/GL test of the two-SRAM physical test vehicle."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer


@cocotb.test()
async def two_banks_and_twelve_bit_transfer(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 1  # serial input held high
    await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)

    async def command(op, data):
        await FallingEdge(dut.clk)
        dut.ui_in.value = data
        dut.uio_in.value = (op << 2) | 1
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk)
        dut.uio_in.value = (op << 2) | 3
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk)
        dut.uio_in.value = (op << 2) | 1
        await ClockCycles(dut.clk, 4)

    async def select_bank(bank):
        await command(4, 0)  # disarm
        assert int(dut.uio_oe.value) == 0
        await command(4, bank * 3)  # both requesters use this bank
        await command(4, bank * 3 + 4)  # arm
        assert int(dut.uio_oe.value) == 0xE0

    async def write_byte(addr, value):
        await command(0, addr & 255)
        await command(1, addr >> 8)
        await command(2, value)

    async def read_byte(addr):
        await command(0, addr & 255)
        await command(1, addr >> 8)
        await command(3, 0)
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk)
        return int(dut.uo_out.value)

    await select_bank(0)
    await write_byte(7, 0x31)
    assert await read_byte(7) == 0x31
    await select_bank(1)
    await write_byte(7, 0xA2)
    assert await read_byte(7) == 0xA2
    await write_byte(100, 0x0A)
    await write_byte(101, 0x5C)
    await command(6, 100)
    await command(7, 200)
    await command(5, 0)
    observed = 0
    samples = 0
    old_sck = 0
    done = False
    for _ in range(500):
        await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        pins = int(dut.uio_out.value)
        sck = (pins >> 5) & 1
        if sck and not old_sck:
            observed = (observed << 1) | ((pins >> 6) & 1)
            samples += 1
        old_sck = sck
        if pins & 0x80:
            done = True
            break
    assert done, "transfer did not complete"
    assert (samples, observed) == (12, 0xA5C)
    assert await read_byte(200) == 0x0F
    assert await read_byte(201) == 0xFF
    await select_bank(0)
    assert await read_byte(7) == 0x31, "banks must remain independent"

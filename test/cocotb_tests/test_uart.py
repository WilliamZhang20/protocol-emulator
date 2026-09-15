"""End-to-end programmable UART TX and RX tests through the Tiny Tapeout pins."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.reference.programs import uart_rx_program, uart_tx_program

WAIT_CYCLES = 5
SYMBOL_CYCLES = WAIT_CYCLES + 11
FIRST_SAMPLE_WAIT = (3 * SYMBOL_CYCLES // 2) - 11


async def host_command(dut, command: int, payload: int = 0) -> None:
    dut.ui_in.value = ((command & 0xF) << 4) | (payload & 0xF)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)


async def set_program_address(dut, address: int) -> None:
    await host_command(dut, 0x1, address)
    await host_command(dut, 0x2, address >> 4)
    await host_command(dut, 0x3, address >> 8)


async def load_program(dut, program: list[int]) -> None:
    await set_program_address(dut, 0)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


async def start_engine(dut) -> None:
    await host_command(dut, 0x8, 1)


async def wait_for_tx_start(dut, timeout_cycles: int = 500) -> None:
    saw_idle = False
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        driven = int(dut.uio_oe.value) & 1
        level = int(dut.uio_out.value) & 1
        saw_idle |= bool(driven and level)
        if saw_idle and driven and not level:
            return
    raise AssertionError("UART TX did not produce a start bit")


@cocotb.test()
async def test_uart_tx_program(dut):
    await start_clock(dut)
    await reset_top(dut)
    value = 0xA6

    await load_program(dut, uart_tx_program(WAIT_CYCLES))
    await push_tx(dut, value)
    await start_engine(dut)
    await wait_for_tx_start(dut)

    expected = [0] + [(value >> bit) & 1 for bit in range(8)] + [1]
    for bit_index, bit_value in enumerate(expected):
        if bit_index:
            await ClockCycles(dut.clk, SYMBOL_CYCLES)
        assert (int(dut.uio_out.value) & 1) == bit_value


@cocotb.test()
async def test_uart_rx_program(dut):
    await start_clock(dut)
    await reset_top(dut)
    value = 0x5B
    dut.uio_in.value = 1

    await load_program(dut, uart_rx_program(WAIT_CYCLES, FIRST_SAMPLE_WAIT))
    await start_engine(dut)
    await ClockCycles(dut.clk, 100)

    frame = [0] + [(value >> bit) & 1 for bit in range(8)] + [1]
    for bit_value in frame:
        dut.uio_in.value = bit_value
        await ClockCycles(dut.clk, SYMBOL_CYCLES)

    await ClockCycles(dut.clk, 50)
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == value

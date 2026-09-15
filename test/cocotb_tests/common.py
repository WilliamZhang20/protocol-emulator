"""Shared clocks, reset sequencing, and top-level initialization."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


async def start_clock(dut, period_ns: int = 20) -> None:
    """Start the design clock at the configured 50 MHz default."""
    cocotb.start_soon(Clock(dut.clk, period_ns, unit="ns").start())


async def reset_top(dut, cycles: int = 5) -> None:
    """Initialize external inputs and apply the active-low reset."""
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

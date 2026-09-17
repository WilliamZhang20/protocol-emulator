"""Shared clocks, reset sequencing, host helpers, and pin observers.

Helpers here are gate-level safe: they only touch top-level Tiny Tapeout pins
(`ui_in` / `uo_out` / `uio_*`). Do not reach into `dut.user_project.*`.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


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


async def host_command(dut, command: int, payload: int = 0) -> None:
    dut.ui_in.value = ((command & 0xF) << 4) | (payload & 0xF)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)


async def read_status(dut) -> int:
    """Host command 0xA → `{running, halted, tx_full, rx_empty, 4'b0}`."""
    await host_command(dut, 0xA)
    return int(dut.uo_out.value)


def status_running(status: int) -> bool:
    return bool(status & 0x80)


def status_halted(status: int) -> bool:
    return bool(status & 0x40)


def status_finished(status: int) -> bool:
    """True when the engine is no longer running.

    After HALT the host clears `enable`, which also clears the core `halted`
    flag — so bit 6 is not sticky. Prefer `not status_running(status)` once
    the program has been started.
    """
    return (not status_running(status)) or status_halted(status)


async def wait_until_halted(dut, timeout_cycles: int = 8000, poll_every: int = 64) -> None:
    """Poll host status until `running` clears (call after start_engine)."""
    for cycle in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if cycle % poll_every == poll_every - 1:
            if not status_running(await read_status(dut)):
                return
    raise AssertionError(f"engine did not finish within {timeout_cycles} cycles")


def driven_level(dut, pin: int) -> int | None:
    """Return 0/1 if `uio_oe[pin]` is set, else None (not driven by DUT)."""
    oe = int(dut.uio_oe.value)
    out = int(dut.uio_out.value)
    if (oe >> pin) & 1:
        return (out >> pin) & 1
    return None

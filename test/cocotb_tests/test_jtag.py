"""JTAG Shift-DR loopback (Phase 7): generic shift engine reuse, no RTL change.

The DUT drives TCK/TMS/TDI and samples TDO; the testbench ties TDO to the
driven TDI level every cycle (combinational loopback). The pushed byte must
equal the transmitted byte, proving the engine is protocol-neutral.
"""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
    wait_until_halted,
)
from cocotb_tests.reference.programs import (
    JTAG_TCK,
    JTAG_TDI,
    JTAG_TDO,
    jtag_shift_dr_program,
)


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_jtag_shift_dr_loopback(dut):
    await start_clock(dut)
    await reset_top(dut)
    tx_byte = 0xA5
    # The external loopback passes through the two-flop GPIO synchronizer.
    await load_program(dut, jtag_shift_dr_program(half_period=8))
    await push_tx(dut, tx_byte)
    dut.uio_in.value = 0
    await host_command(dut, 0x8, 1)

    for _ in range(3000):
        await RisingEdge(dut.clk)
        oe = int(dut.uio_oe.value)
        out = int(dut.uio_out.value)
        tdi = (out >> JTAG_TDI) & 1 if (oe >> JTAG_TDI) & 1 else 0
        dut.uio_in.value = tdi << JTAG_TDO
        if _ % 48 == 47 and not status_running(await read_status(dut)):
            break
    await wait_until_halted(dut, timeout_cycles=2000)
    got = await pop_rx(dut)
    assert got == tx_byte, f"loopback got {got:#04x} want {tx_byte:#04x}"

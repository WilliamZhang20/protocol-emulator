"""Manchester TX decode (Phase 10): same core, pins + time only."""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level,
    host_command,
    reset_top,
    start_clock,
)
from cocotb_tests.reference.programs import manchester_tx_program

PIN = 0


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


@cocotb.test()
async def test_manchester_decode(dut):
    await start_clock(dut)
    await reset_top(dut)
    byte = 0xA5
    await load_program(dut, manchester_tx_program(byte))
    await host_command(dut, 0x8, 1)

    trace: list[int] = []
    for _ in range(1500):
        await RisingEdge(dut.clk)
        lvl = driven_level(dut, PIN)
        trace.append(-1 if lvl is None else lvl)

    # Idle is high; the first falling edge starts bit 0 (sync past setup).
    # Only driven-to-driven transitions count (None = undriven setup skew).
    edges = [
        i
        for i in range(1, len(trace))
        if trace[i] != trace[i - 1] and trace[i] in (0, 1) and trace[i - 1] in (0, 1)
    ]
    falling = [i for i in edges if trace[i] == 0]
    assert falling, "no falling edge driven"
    e0 = falling[0]
    later = [i for i in edges if i > e0]
    assert len(later) >= 8, f"too few edges: {len(edges)}"
    half = later[0] - e0
    assert half > 4, f"half period implausible: {half}"

    got = 0
    for bit in range(8):
        first = trace[e0 + half // 2 + bit * 2 * half]
        second = trace[e0 + half // 2 + half + bit * 2 * half]
        assert {first, second} == {0, 1}, f"bit {bit}: no mid transition"
        if first == 0 and second == 1:
            got |= 1 << bit
    assert got == byte, f"decoded {got:#04x} want {byte:#04x}"

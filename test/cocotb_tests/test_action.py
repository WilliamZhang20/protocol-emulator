"""Action-engine architecture tests (Phases C/D).

Gate-level safe: host commands plus `uio_*` pins and status `0xA` only.
Covers GPIO regions, CPU↔action overlap, shift+counter loops, region
repeats, and READ_RESULT into the register file.
"""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level,
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
    wait_until_halted,
)
from cocotb_tests.reference.programs import (
    action_gpio_pulse_program,
    action_overlap_program,
    action_read_result_program,
    action_repeat_n_program,
    action_shift_out_byte_program,
)

ACTION_PIN = 0
CPU_PIN = 1
SAMPLE_PIN = 2
MARKER_PIN = 3


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


@cocotb.test()
async def test_action_region_gpio_pulse(dut):
    """RUN_REGION drives a pin via action words; WAIT_REGION joins before HALT."""
    await start_clock(dut)
    await reset_top(dut)
    program = action_gpio_pulse_program(pin=ACTION_PIN, delay=8)
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    saw_high = False
    for cycle in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, ACTION_PIN) == 1:
            saw_high = True
            break
        if cycle % 64 == 63 and not status_running(await read_status(dut)):
            break

    assert saw_high, "action region never drove the pin high"
    await wait_until_halted(dut, timeout_cycles=4000)


@cocotb.test()
async def test_action_cpu_overlap(dut):
    """CPU may toggle another pin while RUN_REGION holds the action pin."""
    await start_clock(dut)
    await reset_top(dut)
    program = action_overlap_program(
        action_pin=ACTION_PIN, cpu_pin=CPU_PIN, delay=60
    )
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    overlapped = False
    for cycle in range(4000):
        await RisingEdge(dut.clk)
        a = driven_level(dut, ACTION_PIN)
        c = driven_level(dut, CPU_PIN)
        if a == 1 and c == 1:
            overlapped = True
            break
        if cycle % 64 == 63 and not status_running(await read_status(dut)):
            break

    assert overlapped, "CPU and action engine never drove high together"
    await wait_until_halted(dut, timeout_cycles=4000)


@cocotb.test()
async def test_action_shift_out_lsb(dut):
    """Action SHIFT+COUNT DJNZ walks 0x55 LSB-first (7 transitions on the wire)."""
    await start_clock(dut)
    await reset_top(dut)
    data = 0x55  # LSB-first alternating 1,0,1,0,1,0,1,0
    program = action_shift_out_byte_program(data, pin=ACTION_PIN, half=3)
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    transitions = 0
    prev = None
    first = None
    for cycle in range(8000):
        await RisingEdge(dut.clk)
        level = driven_level(dut, ACTION_PIN)
        if level is None:
            if prev is not None and transitions >= 7:
                break
            continue
        if first is None:
            first = level
            prev = level
            continue
        if level != prev:
            transitions += 1
            prev = level
        if cycle % 64 == 63 and not status_running(await read_status(dut)):
            break

    assert first == 1, f"LSB of 0x55 should drive 1 first, got {first}"
    assert transitions >= 7, f"expected >=7 toggles for 0x55, got {transitions}"
    await wait_until_halted(dut, timeout_cycles=4000)


@cocotb.test()
async def test_action_region_repeat(dut):
    """RUN_REGION_N with 2 extras yields 3 high pulses on the pin."""
    await start_clock(dut)
    await reset_top(dut)
    extras = 2
    program = action_repeat_n_program(pin=ACTION_PIN, extras=extras, pulse=4)
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    pulses = 0
    prev = 0
    for cycle in range(8000):
        await RisingEdge(dut.clk)
        level = driven_level(dut, ACTION_PIN)
        cur = 0 if level is None else level
        if prev == 0 and cur == 1:
            pulses += 1
        prev = cur
        if cycle % 64 == 63 and not status_running(await read_status(dut)):
            break

    assert pulses == extras + 1, f"got {pulses} pulses, want {extras + 1}"
    await wait_until_halted(dut, timeout_cycles=2000)


@cocotb.test()
async def test_action_read_result_sample(dut):
    """SAMPLE + READ_RESULT feeds the RF; JNZ takes the marker path."""
    await start_clock(dut)
    await reset_top(dut)
    # Host holds sample pin high so SAMPLE sees 1.
    dut.uio_in.value = 1 << SAMPLE_PIN
    program = action_read_result_program(
        sample_pin=SAMPLE_PIN, marker_pin=MARKER_PIN
    )
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=4000)
    assert driven_level(dut, MARKER_PIN) == 1, "READ_RESULT/JNZ marker not set"

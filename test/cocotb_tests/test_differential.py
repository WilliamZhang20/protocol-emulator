"""Deterministic differential fuzzing against a pure Python region model.

All observations use Tiny Tapeout pins and the host link, so the same corpus
can be run after synthesis.
"""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level, host_command, reset_top, start_clock, wait_until_halted,
)
from cocotb_tests.reference.programs import (
    HALT, action_delay, action_done, action_gpio,
    prog_action, run_region_n, wait_region,
)
from cocotb_tests.reference.region_spec import RegionSpec


async def load_program(dut, program: list[int]) -> None:
    for cmd in (1, 2, 3):
        await host_command(dut, cmd, 0)
    for byte in program:
        await host_command(dut, 4, byte)
        await host_command(dut, 5, byte >> 4)


@cocotb.test()
async def test_random_regions_match_cycle_trace(dut):
    """Compare every pin transition and its cycle for 16 legal regions."""
    await start_clock(dut)
    rng = random.Random(0x5EED2026)
    for case in range(16):
        await reset_top(dut)
        high_delay = rng.randint(1, 9)
        low_delay = rng.randint(1, 9)
        extra_passes = rng.randint(0, 3)
        slots = [
            action_gpio(pin=0, out=1, oe=1),
            action_delay(high_delay),
            action_gpio(pin=0, out=0, oe=1),
            action_delay(low_delay),
            action_done(),
        ]
        expected = [
            (change.cycle, (change.output & 1))
            for change in RegionSpec(slots, extras=extra_passes).trace()
        ]
        program = [
            *(byte for slot, word in enumerate(slots) for byte in prog_action(slot, word)),
            *run_region_n(0, extra_passes), wait_region(), HALT,
        ]
        await load_program(dut, program)
        await host_command(dut, 8, 1)

        transitions = []
        previous = None
        for cycle in range(260):
            await RisingEdge(dut.clk)
            level = driven_level(dut, 0)
            if level is not None and level != previous:
                transitions.append((cycle, level))
            previous = level
        await wait_until_halted(dut, timeout_cycles=4000)
        assert transitions, f"case {case}: no output transitions"
        first = transitions[0][0]
        observed = [(cycle - first, level) for cycle, level in transitions]
        assert observed == expected, (
            f"case {case}, delays={high_delay}/{low_delay}, repeats={extra_passes}: "
            f"observed {observed}, expected {expected}"
        )

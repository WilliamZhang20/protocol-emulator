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

@cocotb.test()
async def test_action_parallel_gpio_lane(dut):
    """A 32-bit action changes two output pins on the same clock edge."""
    from cocotb_tests.reference.programs import (
        HALT, action_done, action_gpio, action_parallel_gpio,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(0, action_gpio(pin=0, out=1, oe=1) |
                     action_parallel_gpio(1, out=1, oe=1)),
        *prog_action(1, action_done()),
        *run_region(0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    seen = False
    for _ in range(3000):
        await RisingEdge(dut.clk)
        a, b = driven_level(dut, 0), driven_level(dut, 1)
        assert (a == 1) == (b == 1), "parallel pins changed on different cycles"
        if a == 1:
            seen = True
        if seen and _ % 64 == 63 and not status_running(await read_status(dut)):
            break
    assert seen, "parallel action never drove the pins"
    await wait_until_halted(dut, timeout_cycles=3000)


@cocotb.test()
async def test_two_action_lanes_execute_concurrently(dut):
    """Independent pin claims allow both real-time lanes to overlap."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_gpio,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = []
    for lane, pin in ((0, 0), (1, 1)):
        program += prog_action(0, action_gpio(pin=pin, out=1, oe=1), lane)
        program += prog_action(1, action_delay(80), lane)
        program += prog_action(2, action_done(), lane)
    program += [*run_region(0, 0), *run_region(0, 1),
                wait_region(), wait_region(), HALT]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    overlapped = False
    for _ in range(5000):
        await RisingEdge(dut.clk)
        if driven_level(dut, 0) == 1 and driven_level(dut, 1) == 1:
            overlapped = True
            break
    assert overlapped, "the two nonconflicting lanes did not overlap"
    await wait_until_halted(dut, timeout_cycles=5000)


@cocotb.test()
async def test_lane_tx_load_overlaps_other_lane(dut):
    """C8 for an idle lane must not wait for the other lane to finish."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_delay,
        action_done, action_gpio, action_load_tx, action_shift,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(0, action_gpio(pin=0, out=1, oe=1), 0),
        *prog_action(1, action_delay(255), 0),
        *prog_action(2, action_done(), 0),
        *prog_action(0, action_count_load(8), 1),
        *prog_action(1, action_shift(pin=1, msb_first=True), 1),
        *prog_action(2, action_count_djnz(1), 1),
        *prog_action(3, action_done(), 1),
        *run_region(0, 0),
        *action_load_tx(8, msb_first=True, lane=1),
        *run_region(0, 1),
        wait_region(), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x6, 0x5)
    await host_command(dut, 0x7, 0xA)
    await host_command(dut, 0x8, 1)

    overlapped = False
    for _ in range(5000):
        await RisingEdge(dut.clk)
        if driven_level(dut, 0) == 1 and driven_level(dut, 1) is not None:
            overlapped = True
            break
    assert overlapped, "lane-1 TX load waited for lane 0 to finish"
    await wait_until_halted(dut, timeout_cycles=5000)


@cocotb.test()
async def test_lane_result_push_overlaps_other_lane(dut):
    """EF for a completed lane must not wait for the other lane to finish."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_push_result, action_sample,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    dut.uio_in.value = 1 << 2
    program = [
        *prog_action(0, action_sample(pin=2), 1),
        *prog_action(1, action_done(), 1),
        *prog_action(0, action_sample(pin=0), 0),
        *prog_action(1, action_delay(255), 0),
        *prog_action(2, action_done(), 0),
        *run_region(0, 0),
        *run_region(0, 1),
        *action_push_result(lane=1),
        wait_region(), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=5000)
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == 1, "lane-1 result push was delayed or lost"


@cocotb.test()
async def test_lane_pin_conflict_stalls_launch(dut):
    """A second lane waits until the first releases an overlapping claim."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_gpio,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = []
    program += prog_action(0, action_gpio(pin=0, out=1, oe=1), 0)
    program += prog_action(1, action_delay(40), 0)
    program += prog_action(2, action_done(), 0)
    program += prog_action(0, action_gpio(pin=0, out=0, oe=1), 1)
    program += prog_action(1, action_delay(4), 1)
    program += prog_action(2, action_done(), 1)
    program += [*run_region(0, 0), *run_region(0, 1),
                wait_region(), wait_region(), HALT]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)

    sequence = []
    previous = None
    for _ in range(5000):
        await RisingEdge(dut.clk)
        level = driven_level(dut, 0)
        if level is not None and level != previous:
            sequence.append(level)
            previous = level
        if len(sequence) >= 2:
            break
    assert sequence[:2] == [1, 0], sequence
    await wait_until_halted(dut, timeout_cycles=5000)


@cocotb.test()
async def test_action_slots_extend_to_sixteen(dut):
    """Slots 14 and 15 execute without aliasing the original eight slots."""
    from cocotb_tests.reference.programs import (
        HALT, action_done, action_gpio, prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(14, action_gpio(pin=2, out=1, oe=1)),
        *prog_action(15, action_done()),
        *run_region(14), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    saw_high = False
    for _ in range(3000):
        await RisingEdge(dut.clk)
        saw_high |= driven_level(dut, 2) == 1
    assert saw_high
    await wait_until_halted(dut, timeout_cycles=3000)

@cocotb.test()
async def test_action_region_clocked_transfer_bits(dut):
    """A clocked region emits the expected eight MOSI bits on rising SCLK."""
    from cocotb_tests.reference.programs import (
        HALT, action_clocked_transfer, gpio_oe, gpio_write, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    byte = 0xA5
    program = [
        gpio_oe(0, 1), gpio_oe(1, 1), gpio_write(1, 0),
        *action_clocked_transfer(
            clk_pin=1, tx_pin=0, rx_pin=2, bit_count=8,
            half_period=5, msb_first=False,
        ),
        wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)
    await host_command(dut, 0x8, 1)
    observed = []
    old_clock = 0
    for _ in range(4000):
        await RisingEdge(dut.clk)
        clk = driven_level(dut, 1)
        mosi = driven_level(dut, 0)
        if clk == 1 and old_clock == 0 and mosi is not None:
            observed.append(mosi)
            if len(observed) == 8:
                break
        if clk is not None:
            old_clock = clk
    assert observed == [(byte >> bit) & 1 for bit in range(8)]
    await wait_until_halted(dut, timeout_cycles=4000)


@cocotb.test()
async def test_action_shift_16_bit_preload(dut):
    """Both preload bytes reach a 16-bit region transfer in LSB order."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_delay,
        action_done, action_load_shift, action_load_shift_hi,
        action_shift, prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    word = 0xA55A
    region = [
        *prog_action(0, action_count_load(16)),
        *prog_action(1, action_shift(pin=0)),
        *prog_action(2, action_delay(2)),
        *prog_action(3, action_count_djnz(1)),
        *prog_action(4, action_done()),
    ]
    program = [
        *action_load_shift(word & 0xFF),
        *action_load_shift_hi(word >> 8),
        *region, *run_region(0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    observed = []
    last = None
    for cycle in range(4000):
        await RisingEdge(dut.clk)
        bit = driven_level(dut, 0)
        if bit is not None and bit != last:
            observed.append(bit)
            last = bit
        if cycle % 64 == 63 and not status_running(await read_status(dut)):
            break
    expected = [(word >> i) & 1 for i in range(16)]
    transitions = [expected[0]] + [b for a, b in zip(expected, expected[1:]) if b != a]
    assert observed == transitions, f"got transitions {observed}, want {transitions}"
    await wait_until_halted(dut, timeout_cycles=4000)

@cocotb.test()
async def test_action_duplex_receive_result(dut):
    """The output SHIFT lane samples a separate RX pin on every bit."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_done,
        action_load_shift, action_push_result, action_shift,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    dut.uio_in.value = 1 << 2
    region = [
        *prog_action(0, action_count_load(8)),
        *prog_action(1, action_shift(pin=0, rx_pin=2, duplex=True)),
        *prog_action(2, action_count_djnz(1)),
        *prog_action(3, action_done()),
    ]
    program = [
        *action_load_shift(0), *region,
        *run_region(0), wait_region(), *action_push_result(high=True), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=4000)
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == 0xFF


@cocotb.test()
async def test_region_native_fifo_stalls_and_streams(dut):
    """PULL waits for TX, then SHIFT and PUSH deliver a received byte."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_delay,
        action_done, action_pull_tx, action_push_rx, action_shift,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    dut.uio_in.value = 1 << 2
    program = [
        *prog_action(0, action_pull_tx(bits=8, msb_first=True)),
        *prog_action(1, action_count_load(8)),
        *prog_action(2, action_shift(pin=0, rx_pin=2, duplex=True,
                                     msb_first=True)),
        *prog_action(3, action_delay(2)),
        *prog_action(4, action_count_djnz(2)),
        *prog_action(5, action_push_rx(high=False)),
        *prog_action(6, action_done()),
        *run_region(0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(160):
        await RisingEdge(dut.clk)
        assert driven_level(dut, 0) is None, "PULL advanced with empty TX"
    await host_command(dut, 0x6, 0xA)
    await host_command(dut, 0x7, 0x5)
    await wait_until_halted(dut, timeout_cycles=4000)
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == 0xFF


@cocotb.test()
async def test_shift_autopull_autopush_full_duplex(dut):
    """A streaming SHIFT pulls TX once and pushes its eighth RX sample."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_done,
        action_shift, prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    dut.uio_in.value = 1 << 2
    program = [
        *prog_action(0, action_count_load(8)),
        *prog_action(1, action_shift(
            pin=0, rx_pin=2, duplex=True, msb_first=True, stream=True,
        )),
        *prog_action(2, action_count_djnz(1)),
        *prog_action(3, action_done()),
        *run_region(0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(120):
        await RisingEdge(dut.clk)
        assert driven_level(dut, 0) is None, "autopull advanced on empty TX"
    await host_command(dut, 0x6, 0xA)
    await host_command(dut, 0x7, 0x5)
    await wait_until_halted(dut, timeout_cycles=4000)
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == 0xFF


@cocotb.test()
async def test_cpu_pin_write_waits_for_region_claim(dut):
    """CPU's conflicting write issues after the region releases its pin."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_gpio, gpio_write,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(0, action_gpio(pin=0, out=1, oe=1)),
        *prog_action(1, action_delay(90)),
        *prog_action(2, action_done()),
        *run_region(0), gpio_write(0, 0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, 0) == 1:
            break
    else:
        raise AssertionError("region did not claim pin")
    for _ in range(45):
        await RisingEdge(dut.clk)
        assert driven_level(dut, 0) == 1, "CPU wrote through live claim"
    await wait_until_halted(dut, timeout_cycles=4000)
    assert driven_level(dut, 0) == 0


@cocotb.test()
async def test_map_swaps_physical_pins(dut):
    """Remapping one logical pin preserves a one-to-one physical map."""
    from cocotb_tests.reference.programs import (
        HALT, gpio_oe, gpio_write, map_pin,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *map_pin(0, 1),
        gpio_oe(0, 1), gpio_write(0, 1),
        gpio_oe(1, 1), gpio_write(1, 0), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    await wait_until_halted(dut, timeout_cycles=4000)
    assert driven_level(dut, 1) == 1
    assert driven_level(dut, 0) == 0


@cocotb.test()
async def test_action_table_write_waits_for_region(dut):
    """CPU cannot alter a live action word or advance past that write."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_gpio, gpio_oe, gpio_write,
        prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        gpio_oe(1, 1),
        *prog_action(0, action_gpio(pin=0, out=1, oe=1)),
        *prog_action(1, action_delay(100)),
        *prog_action(2, action_done()),
        *run_region(0),
        *prog_action(0, action_gpio(pin=0, out=0, oe=1)),
        gpio_write(1, 1),  # marker after the table write
        wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, 0) == 1:
            break
    else:
        raise AssertionError("region did not start")
    for _ in range(50):
        await RisingEdge(dut.clk)
        assert driven_level(dut, 1) == 0, "CPU passed table write while busy"
    await wait_until_halted(dut, timeout_cycles=4000)
    assert driven_level(dut, 1) == 1


@cocotb.test()
async def test_region_push_stalls_on_full_rx(dut):
    """A fifth region push waits until the host drains one FIFO entry."""
    from cocotb_tests.reference.programs import (
        HALT, action_count_djnz, action_count_load, action_done,
        action_push_rx, prog_action, run_region, wait_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(0, action_count_load(5)),
        *prog_action(1, action_push_rx()),
        *prog_action(2, action_count_djnz(1)),
        *prog_action(3, action_done()),
        *run_region(0), wait_region(), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(200):
        await RisingEdge(dut.clk)
    assert status_running(await read_status(dut)), "region ignored RX full"
    await host_command(dut, 0x9)
    assert int(dut.uo_out.value) == 0
    await wait_until_halted(dut, timeout_cycles=4000)
    for _ in range(4):
        await host_command(dut, 0x9)
        assert int(dut.uo_out.value) == 0


@cocotb.test()
async def test_halt_waits_for_outstanding_region(dut):
    """HALT does not let the host disable a region still driving the bus."""
    from cocotb_tests.reference.programs import (
        HALT, action_delay, action_done, action_gpio, prog_action, run_region,
    )

    await start_clock(dut)
    await reset_top(dut)
    program = [
        *prog_action(0, action_gpio(pin=0, out=1, oe=1)),
        *prog_action(1, action_delay(100)),
        *prog_action(2, action_done()),
        *run_region(0), HALT,
    ]
    await load_program(dut, program)
    await host_command(dut, 0x8, 1)
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if driven_level(dut, 0) == 1:
            break
    else:
        raise AssertionError("region did not start")
    for _ in range(50):
        await RisingEdge(dut.clk)
        assert driven_level(dut, 0) == 1
    assert status_running(await read_status(dut))
    await wait_until_halted(dut, timeout_cycles=4000)

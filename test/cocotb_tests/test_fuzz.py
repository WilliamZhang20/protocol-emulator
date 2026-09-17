"""Mutational orchestration fuzzer with hang watchdog and hard invariants.

Gate-level safe: observes host status and `uio_*` only. Generates completable
programs by construction; stresses double START_XFER, OR-waits, edge arming,
and GPIO on free pins.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import (
    driven_level,
    host_command,
    read_status,
    reset_top,
    start_clock,
    status_running,
)
from cocotb_tests.reference.programs import (
    EV_PIN_FALL,
    EV_PIN_RISE,
    EV_TIMER_DONE,
    EV_XFER_DONE,
    HALT,
    NOP,
    TX_LOAD,
    arm_edges,
    gpio_oe,
    gpio_write,
    start_timer,
    start_xfer,
    wait,
    wait_event,
)

MOSI, MISO, SCLK = 0, 1, 2
FREE_PIN = 5  # never claimed by XFER in this fuzzer
EDGE_PIN = 6


async def load_program(dut, program: list[int]) -> None:
    for cmd, payload in [(0x1, 0), (0x2, 0), (0x3, 0)]:
        await host_command(dut, cmd, payload)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


@dataclass
class FuzzPlan:
    program: list[int]
    tx_bytes: list[int]
    needs_edge: bool = False
    edge_rise: bool = True
    xfer_starts: int = 0
    timer_starts: int = 0
    # Minimum SCLK edges expected when xfer_starts > 0 (black-box busy proxy).
    min_sclk_edges: int = 0
    labels: set[str] = field(default_factory=set)


def _xfer_kwargs(rng: random.Random) -> dict:
    return dict(
        clk_pin=SCLK,
        tx_pin=MOSI,
        rx_pin=MISO,
        bit_count=rng.choice([1, 4, 8, 16]),
        half_period=rng.randint(1, 4),
        msb_first=True,
        clk_idle=rng.randint(0, 1),
        sample_phase=rng.randint(0, 1),
    )


def _nops(rng: random.Random) -> list[int]:
    return [NOP for _ in range(rng.randint(0, 2))]


def _lead() -> list[int]:
    return [
        gpio_oe(MOSI, 1),
        gpio_oe(SCLK, 1),
        gpio_oe(FREE_PIN, 1),
        gpio_write(SCLK, 0),
        gpio_write(FREE_PIN, 0),
    ]


def build_fuzz_plan(rng: random.Random) -> FuzzPlan:
    """Build a program that must reach HALT if the DUT is correct."""
    kind = rng.choices(
        ["paired", "double_xfer", "or_join", "edge_wake", "busy_gpio"],
        weights=[40, 20, 15, 15, 10],
        k=1,
    )[0]
    labels = {kind}

    if kind == "paired":
        tx_bytes = [rng.randint(0, 255)]
        xfer_kw = _xfer_kwargs(rng)
        body: list[int] = [TX_LOAD, *_nops(rng)]
        ops = ["xfer", "timer"]
        rng.shuffle(ops)
        for op in ops:
            if op == "xfer":
                body += start_xfer(**xfer_kw)
            else:
                body += start_timer(rng.randint(4, 48))
            body += _nops(rng)
            if rng.random() < 0.6:
                body.append(gpio_write(FREE_PIN, rng.randint(0, 1)))
        waits = [wait_event(EV_XFER_DONE), wait_event(EV_TIMER_DONE)]
        rng.shuffle(waits)
        flat: list[int] = []
        for w in waits:
            flat += w
        program = _lead() + body + flat + [HALT]
        return FuzzPlan(
            program,
            tx_bytes,
            xfer_starts=1,
            timer_starts=1,
            min_sclk_edges=xfer_kw["bit_count"],
            labels=labels,
        )

    if kind == "double_xfer":
        labels.add("serialize")
        tx_bytes = [rng.randint(0, 255), rng.randint(0, 255)]
        first = _xfer_kwargs(rng)
        first["bit_count"] = rng.choice([8, 16])
        first["half_period"] = rng.randint(2, 4)
        second = _xfer_kwargs(rng)
        body = [
            TX_LOAD,
            *start_xfer(**first),
            TX_LOAD,
            *start_xfer(**second),
            *wait_event(EV_XFER_DONE),
            *wait_event(EV_XFER_DONE),
        ]
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes,
            xfer_starts=2,
            min_sclk_edges=first["bit_count"] + second["bit_count"],
            labels=labels,
        )

    if kind == "or_join":
        labels.add("or")
        tx_bytes = [rng.randint(0, 255)]
        xfer_kw = _xfer_kwargs(rng)
        body = [
            TX_LOAD,
            *start_xfer(**xfer_kw),
            *start_timer(rng.randint(3, 24)),
            *_nops(rng),
            *wait_event(EV_XFER_DONE | EV_TIMER_DONE),
        ]
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes,
            xfer_starts=1,
            timer_starts=1,
            min_sclk_edges=xfer_kw["bit_count"],
            labels=labels,
        )

    if kind == "edge_wake":
        edge_rise = rng.random() < 0.5
        rise = (1 << EDGE_PIN) if edge_rise else 0
        fall = 0 if edge_rise else (1 << EDGE_PIN)
        body = [
            gpio_oe(EDGE_PIN, 0),
            *arm_edges(rise_mask=rise, fall_mask=fall),
        ]
        if rng.random() < 0.5:
            body += wait(2)
        body += wait_event(EV_PIN_RISE if edge_rise else EV_PIN_FALL)
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes=[],
            needs_edge=True,
            edge_rise=edge_rise,
            labels=labels,
        )

    # busy_gpio — VM wiggles a free pin while XFER owns MOSI/SCLK
    labels.add("ownership")
    tx_bytes = [rng.randint(0, 255)]
    xfer_kw = _xfer_kwargs(rng)
    body = [
        TX_LOAD,
        *start_xfer(**xfer_kw),
        gpio_write(FREE_PIN, 1),
        gpio_write(FREE_PIN, 0),
        gpio_write(FREE_PIN, 1),
        *wait_event(EV_XFER_DONE),
    ]
    return FuzzPlan(
        _lead() + body + [HALT],
        tx_bytes,
        xfer_starts=1,
        min_sclk_edges=xfer_kw["bit_count"],
        labels=labels,
    )


async def run_plan(dut, plan: FuzzPlan, trial: int, hang_limit: int = 8000) -> dict:
    for byte in plan.tx_bytes:
        await push_tx(dut, byte)

    dut.uio_in.value = 0 if plan.edge_rise else (1 << EDGE_PIN)
    await host_command(dut, 0x8, 1)

    saw_sclk_edges = 0
    saw_free_pin_high_during_xfer = 0
    edge_fired = False
    prev_sclk = driven_level(dut, SCLK)
    last_pin_key = None
    stalled = 0
    xfer_recent = 0
    finished = False

    cycle = 0
    while cycle < hang_limit:
        await RisingEdge(dut.clk)
        cycle += 1

        if plan.needs_edge and not edge_fired and cycle > 50:
            dut.uio_in.value = (1 << EDGE_PIN) if plan.edge_rise else 0
            edge_fired = True

        sclk = driven_level(dut, SCLK)
        if sclk is not None and prev_sclk is not None and sclk != prev_sclk:
            saw_sclk_edges += 1
            xfer_recent = 32
        elif xfer_recent:
            xfer_recent -= 1
        if sclk is not None:
            prev_sclk = sclk

        free_oe = (int(dut.uio_oe.value) >> FREE_PIN) & 1
        free_out = (int(dut.uio_out.value) >> FREE_PIN) & 1
        if free_oe and free_out and xfer_recent:
            saw_free_pin_high_during_xfer += 1

        pin_key = (
            int(dut.uio_out.value),
            int(dut.uio_oe.value),
            int(dut.uio_in.value),
            xfer_recent > 0,
        )
        if pin_key == last_pin_key:
            stalled += 1
        else:
            stalled = 0
            last_pin_key = pin_key

        # After HALT the host clears enable (running bit). Poll infrequently.
        if cycle % 64 == 0:
            if not status_running(await read_status(dut)):
                finished = True
                break

        # Only treat pin-idle as a hang while the engine still claims to be running.
        if stalled > 4000:
            st = await read_status(dut)
            if not status_running(st):
                finished = True
                break
            raise AssertionError(
                f"trial {trial}: hang (pins idle) labels={plan.labels} "
                f"sclk_edges={saw_sclk_edges}"
            )
    else:
        raise AssertionError(
            f"trial {trial}: no halt in {hang_limit} cycles labels={plan.labels}"
        )

    assert finished

    # OR-join may HALT while XFER still finishes; wait for SCLK to go quiet.
    if "or" in plan.labels:
        quiet = 0
        prev = driven_level(dut, SCLK)
        for _ in range(2000):
            await RisingEdge(dut.clk)
            cur = driven_level(dut, SCLK)
            if cur is not None and prev is not None and cur != prev:
                saw_sclk_edges += 1
                quiet = 0
            else:
                quiet += 1
            if cur is not None:
                prev = cur
            if quiet > 64:
                break
        else:
            raise AssertionError(
                f"trial {trial}: OR-join background xfer never went quiet"
            )

    if plan.xfer_starts:
        assert saw_sclk_edges > 0, f"trial {trial}: expected SCLK activity"
    if plan.min_sclk_edges:
        # Each transferred bit produces one SCLK period (≥1 level change pair);
        # require a conservative fraction so CPOL/idle edges do not flake.
        need = max(1, plan.min_sclk_edges)
        assert saw_sclk_edges >= need, (
            f"trial {trial}: sclk_edges {saw_sclk_edges} < {need} "
            f"labels={plan.labels}"
        )
    if "ownership" in plan.labels:
        assert saw_free_pin_high_during_xfer > 0, (
            f"trial {trial}: free pin never high during xfer"
        )

    return {
        "labels": set(plan.labels),
        "edge": plan.needs_edge,
    }


@cocotb.test()
async def test_fuzz_orchestrate_campaign(dut):
    """Mutational campaign across orchestration shapes with hang watchdog."""
    rng = random.Random(0xF0227EA1)
    await start_clock(dut)

    coverage: set[str] = set()
    for trial in range(48):
        await reset_top(dut)
        plan = build_fuzz_plan(rng)
        await load_program(dut, plan.program)
        stats = await run_plan(dut, plan, trial)
        coverage |= stats["labels"]
        if stats["edge"]:
            coverage.add("edge")

    required = {
        "paired",
        "double_xfer",
        "or_join",
        "edge_wake",
        "busy_gpio",
        "serialize",
        "or",
        "ownership",
        "edge",
    }
    missing = required - coverage
    assert not missing, f"fuzz campaign missed shapes: {missing}"


@cocotb.test()
async def test_fuzz_adversarial_or_then_halt(dut):
    """OR-wait alone must halt even if the sibling event is still pending."""
    await start_clock(dut)
    await reset_top(dut)
    plan = FuzzPlan(
        program=[
            gpio_oe(MOSI, 1),
            gpio_oe(SCLK, 1),
            gpio_write(SCLK, 0),
            TX_LOAD,
            *start_xfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            *start_timer(120),
            *wait_event(EV_XFER_DONE | EV_TIMER_DONE),
            HALT,
        ],
        tx_bytes=[0x5A],
        xfer_starts=1,
        timer_starts=1,
        min_sclk_edges=8,
        labels={"or", "adversarial"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-1, hang_limit=4000)


@cocotb.test()
async def test_fuzz_double_start_serialization(dut):
    """Back-to-back START_XFER must serialize and complete two transfers."""
    await start_clock(dut)
    await reset_top(dut)
    plan = FuzzPlan(
        program=[
            gpio_oe(MOSI, 1),
            gpio_oe(SCLK, 1),
            gpio_write(SCLK, 0),
            TX_LOAD,
            *start_xfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            TX_LOAD,
            *start_xfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            *wait_event(EV_XFER_DONE),
            *wait_event(EV_XFER_DONE),
            HALT,
        ],
        tx_bytes=[0x11, 0x22],
        xfer_starts=2,
        min_sclk_edges=16,
        labels={"double_xfer", "serialize"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-2, hang_limit=6000)

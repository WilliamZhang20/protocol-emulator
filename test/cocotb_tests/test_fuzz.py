"""Mutational orchestration fuzzer with hang watchdog and hard invariants.

Generates completable programs by construction, stresses double START_XFER,
OR-waits, edge arming, and GPIO on free pins. Fails fast on deadlocks or
scoreboard/ownership violations.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
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

ST_EVENT_WAIT = 12
ST_HALTED = 9
ST_EXT_WAIT = 11


async def host_command(dut, command: int, payload: int = 0) -> None:
    dut.ui_in.value = ((command & 0xF) << 4) | (payload & 0xF)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)


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
        body: list[int] = [TX_LOAD, *_nops(rng)]
        ops = ["xfer", "timer"]
        rng.shuffle(ops)
        for op in ops:
            if op == "xfer":
                body += start_xfer(**_xfer_kwargs(rng))
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
            program, tx_bytes, xfer_starts=1, timer_starts=1, labels=labels
        )

    if kind == "double_xfer":
        labels.add("serialize")
        tx_bytes = [rng.randint(0, 255), rng.randint(0, 255)]
        # First transfer must still be busy when the 2nd START arrives.
        first = _xfer_kwargs(rng)
        first["bit_count"] = rng.choice([8, 16])
        first["half_period"] = rng.randint(2, 4)
        body = [
            TX_LOAD,
            *start_xfer(**first),
            TX_LOAD,
            *start_xfer(**_xfer_kwargs(rng)),
            *wait_event(EV_XFER_DONE),
            *wait_event(EV_XFER_DONE),
        ]
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes,
            xfer_starts=2,
            labels=labels,
        )

    if kind == "or_join":
        labels.add("or")
        tx_bytes = [rng.randint(0, 255)]
        body = [
            TX_LOAD,
            *start_xfer(**_xfer_kwargs(rng)),
            *start_timer(rng.randint(3, 24)),
            *_nops(rng),
            *wait_event(EV_XFER_DONE | EV_TIMER_DONE),
        ]
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes,
            xfer_starts=1,
            timer_starts=1,
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
    body = [
        TX_LOAD,
        *start_xfer(**_xfer_kwargs(rng)),
        gpio_write(FREE_PIN, 1),
        gpio_write(FREE_PIN, 0),
        gpio_write(FREE_PIN, 1),
        *wait_event(EV_XFER_DONE),
    ]
    return FuzzPlan(
        _lead() + body + [HALT],
        tx_bytes,
        xfer_starts=1,
        labels=labels,
    )


async def run_plan(dut, plan: FuzzPlan, trial: int, hang_limit: int = 8000) -> dict:
    for byte in plan.tx_bytes:
        await push_tx(dut, byte)

    dut.uio_in.value = 0 if plan.edge_rise else (1 << EDGE_PIN)
    await host_command(dut, 0x8, 1)

    core = dut.user_project.core
    saw_busy = 0
    saw_ext_stall = 0
    saw_free_pin_high = 0
    edge_fired = False
    last_key = None
    stalled = 0
    idle_claim_cycles = 0

    for cycle in range(hang_limit):
        await RisingEdge(dut.clk)

        if plan.needs_edge and not edge_fired and cycle > 50:
            dut.uio_in.value = (1 << EDGE_PIN) if plan.edge_rise else 0
            edge_fired = True

        busy = int(core.bit_xfer.busy.value)
        claim = int(core.xfer_pin_claim.value)
        state = int(core.state.value)
        pending = int(core.events.pending.value)
        drive_en = int(core.bit_xfer.drive_enable.value)
        drive_mask = int(core.bit_xfer.drive_out_mask.value)

        if busy:
            saw_busy += 1
            idle_claim_cycles = 0
        if state == ST_EXT_WAIT and busy:
            saw_ext_stall += 1

        free_oe = (int(dut.uio_oe.value) >> FREE_PIN) & 1
        free_out = (int(dut.uio_out.value) >> FREE_PIN) & 1
        if free_oe and free_out:
            saw_free_pin_high += 1

        assert pending & ~0x1F == 0, f"trial {trial}: bad pending {pending:#x}"

        if busy:
            assert claim != 0, f"trial {trial}: busy without pin claim"
            if drive_en:
                assert drive_mask & ~claim == 0, (
                    f"trial {trial}: drive_mask {drive_mask:#x} outside claim {claim:#x}"
                )
            expect = (1 << MOSI) | (1 << SCLK)
            assert claim & expect == expect, (
                f"trial {trial}: claim {claim:#x} missing xfer pins"
            )
        else:
            if claim != 0:
                idle_claim_cycles += 1
                if idle_claim_cycles > 2:
                    raise AssertionError(
                        f"trial {trial}: claim {claim:#x} stuck while idle"
                    )
            else:
                idle_claim_cycles = 0

        key = (state, busy, pending, claim)
        if key == last_key:
            stalled += 1
        else:
            stalled = 0
            last_key = key

        if state == ST_EVENT_WAIT and stalled > 2500:
            raise AssertionError(
                f"trial {trial}: EVENT_WAIT hang pending={pending:#x} busy={busy} "
                f"labels={plan.labels}"
            )
        if stalled > 4000:
            raise AssertionError(
                f"trial {trial}: hang state={state} pending={pending:#x} "
                f"busy={busy} labels={plan.labels}"
            )

        if state == ST_HALTED:
            break
    else:
        raise AssertionError(
            f"trial {trial}: no halt in {hang_limit} cycles labels={plan.labels}"
        )

    assert int(core.state.value) == ST_HALTED
    # OR-join may HALT while XFER/timer still finish; drain ownership.
    if "or" in plan.labels:
        for _ in range(2000):
            await RisingEdge(dut.clk)
            if int(core.bit_xfer.busy.value) == 0 and int(core.xfer_pin_claim.value) == 0:
                break
        else:
            raise AssertionError(f"trial {trial}: OR-join background xfer never released claim")
    else:
        assert int(core.bit_xfer.busy.value) == 0
        assert int(core.xfer_pin_claim.value) == 0

    if plan.xfer_starts:
        assert saw_busy > 0, f"trial {trial}: expected xfer busy"
    if "serialize" in plan.labels:
        assert saw_ext_stall > 0, f"trial {trial}: expected EXT_WAIT on 2nd START"
    if "ownership" in plan.labels:
        assert saw_free_pin_high > 0, f"trial {trial}: free pin never high during xfer"

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
        labels={"or", "adversarial"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-1, hang_limit=4000)


@cocotb.test()
async def test_fuzz_double_start_serialization(dut):
    """Back-to-back START_XFER must serialize in EXT_WAIT and take two dones."""
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
        labels={"double_xfer", "serialize"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-2, hang_limit=6000)

"""Mutational orchestration fuzzer with hang watchdog and hard invariants.

Gate-level safe: observes host status and `uio_*` only. Generates completable
programs by construction; stresses double RUN_REGION, OR-waits, edge arming,
GPIO ownership, CRC feeds, and action line drive/sample.
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
    EV_REGION_DONE,
    HALT,
    LINE_J,
    LINE_K,
    LINE_SE0,
    NOP,
    arm_edges,
    crc_finalize,
    crc_feed,
    crc_push_result,
    crc_setup,
    crc_usb16_setup,
    gpio_oe,
    gpio_write,
    action_line_drive,
    action_line_release,
    action_line_sample,
    start_timer,
    action_clocked_transfer,
    wait,
    wait_event,
)

MOSI, MISO, SCLK = 0, 1, 2
FREE_PIN = 5  # never claimed by XFER in this fuzzer
EDGE_PIN = 6
# two-pin demo pins — keep clear of MOSI/SCLK/FREE/EDGE
LP_A, LP_B = 3, 4


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


@dataclass
class FuzzPlan:
    program: list[int]
    tx_bytes: list[int]
    needs_edge: bool = False
    edge_rise: bool = True
    xfer_starts: int = 0
    timer_starts: int = 0
    min_sclk_edges: int = 0
    expect_rx: list[int] | None = None
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
    return [NOP for _ in range(rng.randint(0, 3))]


def _lead() -> list[int]:
    return [
        gpio_oe(MOSI, 1),
        gpio_oe(SCLK, 1),
        gpio_oe(FREE_PIN, 1),
        gpio_write(SCLK, 0),
        gpio_write(FREE_PIN, 0),
    ]


def _sw_crc16_usb(data: list[int]) -> int:
    """Match crc_engine USB-CRC16 configuration used by fuzz plans."""
    width, poly = 16, 0x8005
    width_mask = (1 << width) - 1
    crc = width_mask
    for byte in data:
        b = int(f"{byte:08b}"[::-1], 2)
        for i in range(8):
            bit = (b >> (7 - i)) & 1
            top = ((crc >> (width - 1)) & 1) ^ bit
            crc = (crc << 1) & width_mask
            if top:
                crc ^= poly & width_mask
    rev = 0
    for i in range(width):
        if (crc >> i) & 1:
            rev |= 1 << (width - 1 - i)
    return (rev ^ width_mask) & width_mask


def build_fuzz_plan(rng: random.Random) -> FuzzPlan:
    """Build a program that must reach HALT if the DUT is correct."""
    kind = rng.choices(
        [
            "paired",
            "double_xfer",
            "or_join",
            "edge_wake",
            "busy_gpio",
            "crc_pipe",
            "line_regions",
            "crc_then_xfer",
        ],
        weights=[22, 14, 12, 12, 10, 12, 10, 8],
        k=1,
    )[0]
    labels = {kind}

    if kind == "paired":
        tx_bytes = [rng.randint(0, 255)]
        xfer_kw = _xfer_kwargs(rng)
        body: list[int] = [*_nops(rng)]
        ops = ["xfer", "timer"]
        rng.shuffle(ops)
        for op in ops:
            if op == "xfer":
                body += action_clocked_transfer(**xfer_kw)
            else:
                body += start_timer(rng.randint(4, 48))
            body += _nops(rng)
            if rng.random() < 0.6:
                body.append(gpio_write(FREE_PIN, rng.randint(0, 1)))
        waits = [wait_event(EV_REGION_DONE), wait_event(EV_TIMER_DONE)]
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
            *action_clocked_transfer(**first),
            *wait_event(EV_REGION_DONE),
            *_nops(rng),
            *action_clocked_transfer(**second),
            *wait_event(EV_REGION_DONE),
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
            *action_clocked_transfer(**xfer_kw),
            *start_timer(rng.randint(3, 24)),
            *_nops(rng),
            *wait_event(EV_REGION_DONE | EV_TIMER_DONE),
        ]
        return FuzzPlan(
            _lead() + body + [HALT],
            tx_bytes,
            xfer_starts=1,
            timer_starts=1,
            min_sclk_edges=1,
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

    if kind == "crc_pipe":
        labels.add("crc")
        n = rng.randint(1, 4)
        data = [rng.randint(0, 255) for _ in range(n)]
        expect = _sw_crc16_usb(data)
        body = [*crc_usb16_setup()]
        for b in data:
            body += crc_feed(b)
            body += _nops(rng)
        body += [crc_finalize(), *crc_push_result(), HALT]
        return FuzzPlan(
            body,
            tx_bytes=[],
            expect_rx=[expect & 0xFF, (expect >> 8) & 0xFF],
            labels=labels,
        )

    if kind == "line_regions":
        labels.add("line")
        seq = [LINE_J, LINE_K, LINE_SE0, LINE_J]
        if rng.random() < 0.5:
            mid = [LINE_K, LINE_SE0]
            rng.shuffle(mid)
            seq = [LINE_J] + mid + [LINE_J]
        body = []
        for st in seq:
            body += [*action_line_drive(st, pin_a=LP_A, pin_b=LP_B),
                     *wait(rng.randint(2, 6))]
        body += [*action_line_release(pin_a=LP_A, pin_b=LP_B),
                 *action_line_sample(pin_a=LP_A, pin_b=LP_B), HALT]
        return FuzzPlan(
            body,
            tx_bytes=[],
            expect_rx=[LINE_J],
            labels=labels,
        )

    if kind == "crc_then_xfer":
        labels.update({"crc", "paired"})
        tx_bytes = [rng.randint(0, 255)]
        data = [rng.randint(0, 255)]
        expect = _sw_crc16_usb(data)
        xfer_kw = _xfer_kwargs(rng)
        xfer_kw["bit_count"] = rng.choice([4, 8])
        body = [
            *_lead(),
            *crc_usb16_setup(),
            *crc_feed(data[0]),
            *_nops(rng),
            crc_finalize(),
            *crc_push_result(),
            *action_clocked_transfer(**xfer_kw),
            *wait_event(EV_REGION_DONE),
            HALT,
        ]
        return FuzzPlan(
            body,
            tx_bytes,
            xfer_starts=1,
            min_sclk_edges=xfer_kw["bit_count"],
            expect_rx=[expect & 0xFF, (expect >> 8) & 0xFF],
            labels=labels,
        )

    # busy_gpio — VM wiggles a free pin while XFER owns MOSI/SCLK
    labels.add("ownership")
    tx_bytes = [rng.randint(0, 255)]
    xfer_kw = _xfer_kwargs(rng)
    body = [
            *action_clocked_transfer(**xfer_kw),
        gpio_write(FREE_PIN, 1),
        gpio_write(FREE_PIN, 0),
        gpio_write(FREE_PIN, 1),
        *wait_event(EV_REGION_DONE),
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

    # Idle J on two-pin bus inputs for SAMPLE-after-release plans.
    idle = 0 if plan.edge_rise else (1 << EDGE_PIN)
    idle |= (0 << LP_A) | (1 << LP_B)
    dut.uio_in.value = idle
    await host_command(dut, 0x8, 1)

    saw_sclk_edges = 0
    saw_free_pin_high_during_xfer = 0
    saw_line_activity = 0
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
            dut.uio_in.value = ((1 << EDGE_PIN) if plan.edge_rise else 0) | (
                (0 << LP_A) | (1 << LP_B)
            )
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

        la = driven_level(dut, LP_A)
        lb = driven_level(dut, LP_B)
        if la is not None and lb is not None:
            saw_line_activity += 1

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

        if cycle % 64 == 0:
            if not status_running(await read_status(dut)):
                finished = True
                break

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
        need = max(1, plan.min_sclk_edges)
        assert saw_sclk_edges >= need, (
            f"trial {trial}: sclk_edges {saw_sclk_edges} < {need} "
            f"labels={plan.labels}"
        )
    if "ownership" in plan.labels:
        assert saw_free_pin_high_during_xfer > 0, (
            f"trial {trial}: free pin never high during xfer"
        )
    if "line" in plan.labels:
        assert saw_line_activity > 0, f"trial {trial}: action pair never drove"

    if plan.expect_rx is not None:
        for i, want in enumerate(plan.expect_rx):
            got = await pop_rx(dut)
            assert got == want, (
                f"trial {trial}: RX[{i}] got {got:#x} want {want:#x} "
                f"labels={plan.labels}"
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
    for trial in range(96):
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
        "crc",
        "line",
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
            *action_clocked_transfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            *start_timer(120),
            *wait_event(EV_REGION_DONE | EV_TIMER_DONE),
            HALT,
        ],
        tx_bytes=[0x5A],
        xfer_starts=1,
        timer_starts=1,
        min_sclk_edges=1,
        labels={"or", "adversarial"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-1, hang_limit=4000)


@cocotb.test()
async def test_fuzz_double_start_serialization(dut):
    """Sequential action regions must complete two transfers."""
    await start_clock(dut)
    await reset_top(dut)
    plan = FuzzPlan(
        program=[
            gpio_oe(MOSI, 1),
            gpio_oe(SCLK, 1),
            gpio_write(SCLK, 0),
            *action_clocked_transfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            *wait_event(EV_REGION_DONE),
            *action_clocked_transfer(
                clk_pin=SCLK, tx_pin=MOSI, rx_pin=MISO, bit_count=8, half_period=2
            ),
            *wait_event(EV_REGION_DONE),
            HALT,
        ],
        tx_bytes=[0x11, 0x22],
        xfer_starts=2,
        min_sclk_edges=16,
        labels={"double_xfer", "serialize"},
    )
    await load_program(dut, plan.program)
    await run_plan(dut, plan, trial=-2, hang_limit=6000)


@cocotb.test()
async def test_fuzz_crc_random_polys(dut):
    """Adversarial CRC: random width/poly still finalizes and pushes."""
    await start_clock(dut)
    rng = random.Random(0xC2C)
    for trial in range(8):
        await reset_top(dut)
        width = rng.choice([5, 8, 16])
        poly = rng.randint(1, (1 << width) - 1) | 1  # odd poly
        data = [rng.randint(0, 255) for _ in range(rng.randint(1, 3))]
        program = [
            *crc_setup(width=width, poly=poly),
            *[b for byte in data for b in crc_feed(byte)],
            crc_finalize(),
            *crc_push_result(),
            HALT,
        ]
        await load_program(dut, program)
        await run_plan(
            dut,
            FuzzPlan(program, [], labels={"crc", "crc_rand"}),
            trial=-(100 + trial),
            hang_limit=3000,
        )
        # Just ensure two RX bytes pop without hanging.
        _ = await pop_rx(dut)
        _ = await pop_rx(dut)

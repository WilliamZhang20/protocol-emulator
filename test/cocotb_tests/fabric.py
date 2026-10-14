"""PX8 assembler, spatial-fabric configuration helpers, and host/bus helpers.

Everything here drives only top-level Tiny Tapeout pins, so tests built on it
are gate-level safe.
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.common import host_command

# ----------------------------------------------------------------- event bus
EV_NEVER = 0
EV_ALWAYS = 1


def ev_fire(n: int) -> int:
    return 2 + n


def ev_timer_rise(k: int) -> int:
    return 4 + 2 * k


def ev_timer_fall(k: int) -> int:
    return 5 + 2 * k


def ev_shifter_start(k: int) -> int:
    return 12 + 2 * k


def ev_shifter_done(k: int) -> int:
    return 13 + 2 * k


def ev_pin_rise(p: int) -> int:
    return 16 + p


def ev_pin_fall(p: int) -> int:
    return 24 + p


# --------------------------------------------------------------- pin sources
SRC_CPU = 0


def src_timer(k: int) -> int:
    return 1 + k


def src_shifter(k: int) -> int:
    return 5 + k


MODE_INPUT = 0
MODE_PUSH_PULL = 1
MODE_OPEN_DRAIN = 2

# ----------------------------------------------------------------- readback
RD_PINS = 0
RD_TIMERS = 5


def rd_shifter_data(k: int) -> int:
    return 1 + 2 * k


def rd_shifter_status(k: int) -> int:
    return 2 + 2 * k


# ------------------------------------------------------------------ assembler
OP_PFIX, OP_LDC, OP_ADC, OP_XRC, OP_J, OP_JZ, OP_DJNZ, OP_SETC = range(8)
OP_WCF, OP_RD, OP_WEV, OP_FIRE, OP_PIN, OP_DLY, OP_OPR, OP_ANDC = range(8, 16)
OPR_NOP, OPR_HALT, OPR_PULL, OPR_PUSH, OPR_CLREV, OPR_A_FROM_C, OPR_C_FROM_A = range(7)


class Px8:
    """Tiny two-pass assembler. Branch targets always use three nibbles so
    forward references have a fixed size."""

    def __init__(self) -> None:
        self.code: list[int] = []
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[int, int, str]] = []

    def _emit(self, op: int, value: int) -> None:
        value &= 0xFFFF
        digits = []
        while True:
            digits.insert(0, value & 0xF)
            value >>= 4
            if not value:
                break
        for digit in digits[:-1]:
            self.code.append((OP_PFIX << 4) | digit)
        self.code.append((op << 4) | digits[-1])

    def _branch(self, op: int, label: str) -> None:
        self.fixups.append((len(self.code), op, label))
        self.code += [0, 0, 0]

    def label(self, name: str) -> None:
        self.labels[name] = len(self.code)

    def ldc(self, v: int) -> None: self._emit(OP_LDC, v)
    def adc(self, v: int) -> None: self._emit(OP_ADC, v)
    def xrc(self, v: int) -> None: self._emit(OP_XRC, v)
    def andc(self, v: int) -> None: self._emit(OP_ANDC, v)
    def setc(self, v: int) -> None: self._emit(OP_SETC, v)
    def wcf(self, addr: int) -> None: self._emit(OP_WCF, addr)
    def rd(self, addr: int) -> None: self._emit(OP_RD, addr)
    def wev(self, event: int) -> None: self._emit(OP_WEV, event)
    def fire(self, n: int) -> None: self._emit(OP_FIRE, n)
    def dly(self, cycles: int) -> None: self._emit(OP_DLY, cycles)
    def pin(self, p: int, v: int) -> None: self.code.append((OP_PIN << 4) | (v << 3) | p)
    def j(self, label: str) -> None: self._branch(OP_J, label)
    def jz(self, label: str) -> None: self._branch(OP_JZ, label)
    def djnz(self, label: str) -> None: self._branch(OP_DJNZ, label)
    def halt(self) -> None: self._emit(OP_OPR, OPR_HALT)
    def pull(self) -> None: self._emit(OP_OPR, OPR_PULL)
    def push(self) -> None: self._emit(OP_OPR, OPR_PUSH)
    def clrev(self) -> None: self._emit(OP_OPR, OPR_CLREV)

    def cfg(self, addr: int, value: int) -> None:
        self.ldc(value)
        self.wcf(addr)

    def assemble(self) -> list[int]:
        code = list(self.code)
        for at, op, label in self.fixups:
            target = self.labels[label]
            code[at] = (OP_PFIX << 4) | ((target >> 8) & 0xF)
            code[at + 1] = (OP_PFIX << 4) | ((target >> 4) & 0xF)
            code[at + 2] = (op << 4) | (target & 0xF)
        assert len(code) <= 1024
        return code

    # ------------------------------------------------------------- fabric
    def timer(self, k: int, *, reload: int, phase: int, start: int = EV_NEVER,
              stop: int = EV_NEVER, idle: int = 0, pulse: bool = False,
              hold_pin: int | None = None) -> None:
        base = 4 * k
        self.cfg(base + 0, reload)
        self.cfg(base + 1, phase)
        ctl = start | (stop << 5) | (idle << 10) | (int(pulse) << 11)
        if hold_pin is not None:
            ctl |= (hold_pin << 12) | (1 << 15)
        self.cfg(base + 2, ctl)

    def timer_cmd(self, k: int, *, start: bool = False, stop: bool = False) -> None:
        self.cfg(4 * k + 3, int(start) | (int(stop) << 1))

    def shifter(self, k: int, *, length: int = 8, pre: int = 0, pre_val: int = 0,
                post: int = 0, post_val: int = 0, parity: int = 0,
                msb: bool = False, lead: bool = False, end_on_sample: bool = False,
                idle: int = 0, shift: int = EV_NEVER, sample: int = EV_NEVER,
                start: int = EV_NEVER) -> None:
        base = 0x10 + 4 * k
        frame = ((length - 1) | (pre << 4) | (pre_val << 6) | (post << 7) |
                 (post_val << 9) | (parity << 10) | (int(msb) << 12) |
                 (int(lead) << 13) | (int(end_on_sample) << 14) | (idle << 15))
        self.cfg(base + 1, frame)
        self.cfg(base + 2, shift | (sample << 5) | (start << 10))

    def shifter_data(self, k: int, value: int) -> None:
        self.cfg(0x10 + 4 * k, value)

    def shifter_io(self, k: int, *, in_pin: int = 0, pull: bool = False,
                   push: bool = False, start_now: bool = False) -> None:
        self.cfg(0x10 + 4 * k + 3, in_pin | (int(pull) << 3) | (int(push) << 4) |
                 (int(start_now) << 5))

    def pin_cell(self, p: int, src: int, mode: int) -> None:
        self.cfg(0x18 + p, src | (mode << 3))


# ------------------------------------------------------------- host helpers
async def load_program(dut, program: list[int]) -> None:
    await host_command(dut, 0x1, 0)
    await host_command(dut, 0x2, 0)
    await host_command(dut, 0x3, 0)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def push_tx(dut, byte: int) -> None:
    await host_command(dut, 0x6, byte)
    await host_command(dut, 0x7, byte >> 4)


async def start_engine(dut) -> None:
    await host_command(dut, 0x8, 1)


async def pop_rx(dut) -> int:
    await host_command(dut, 0x9)
    return int(dut.uo_out.value)


async def rx_empty(dut) -> bool:
    await host_command(dut, 0xA)
    return bool(int(dut.uo_out.value) & 0x10)


# ------------------------------------------------------------ external bus
class Bus:
    """Wired-AND pin model with pull-ups. `drive[p]` holds an external level
    (None = released). A DUT pin with OE high contributes its output level."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.drive: list[int | None] = [None] * 8
        cocotb.start_soon(self._run())

    def level(self, p: int) -> int:
        oe = (int(self.dut.uio_oe.value) >> p) & 1
        out = (int(self.dut.uio_out.value) >> p) & 1
        dut_level = out if oe else 1
        ext = self.drive[p]
        return dut_level & (1 if ext is None else ext)

    def levels(self) -> int:
        return sum(self.level(p) << p for p in range(8))

    def update(self) -> None:
        self.dut.uio_in.value = self.levels()

    async def _run(self) -> None:
        while True:
            await FallingEdge(self.dut.clk)
            self.update()


async def wait_level(dut, bus: Bus, p: int, value: int, timeout: int = 100000) -> None:
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if bus.level(p) == value:
            return
    raise AssertionError(f"pin {p} never reached {value}")

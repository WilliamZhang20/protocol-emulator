"""PX8 assembler, spatial-fabric configuration helpers, and host/bus helpers.

Everything here drives only top-level Tiny Tapeout pins, so tests built on it
are gate-level safe.
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge

from cocotb_tests.common import host_command

# -------------------------------------------------------------- signal space
ZERO = 0
ONE = 1


def fire(n: int) -> int: return 2 + n
def timer_rise(k: int) -> int: return 4 + 2 * k
def timer_fall(k: int) -> int: return 5 + 2 * k
def shifter_word(k: int) -> int: return 12 + 2 * k
def shifter_stop(k: int) -> int: return 13 + 2 * k
def pin_rise(p: int) -> int: return 16 + p
def pin_fall(p: int) -> int: return 24 + p
def pin_level(p: int) -> int: return 32 + p
def timer_out(k: int) -> int: return 40 + k
def shifter_out(k: int) -> int: return 44 + k
def shifter_active(k: int) -> int: return 46 + k
def counter_ge(k: int) -> int: return 48 + k
def counter_hit(k: int) -> int: return 50 + k


CRC_OUT = 52
CRC_OK = 53


def flag(n: int) -> int: return 54 + n
def glue(k: int) -> int: return 56 + k


# --------------------------------------------------------------- pin modes
MODE_INPUT = 0
MODE_PUSH_PULL = 1
MODE_OPEN_DRAIN = 2

# ------------------------------------------------------------------ readback
RD_PINS = 0


def rd_shifter_data(k: int) -> int: return 1 + 2 * k
def rd_shifter_status(k: int) -> int: return 2 + 2 * k
def rd_counter(k: int) -> int: return 5 + k


RD_CRC_LO = 7
RD_CRC_HI = 8

# counter modes
COUNT_STEPS, RUN_ONES, RUN_ZEROS, RUN_EQUAL = range(4)


def _level(line: int) -> int:
    """Encode a level-only select (signal space 32-63)."""
    assert 32 <= line < 64, f"line {line} is not a level line"
    return line - 32


def _pulse(line: int) -> int:
    """Encode a pulse-only select (signal space 0-31, includes 0 and 1)."""
    assert 0 <= line < 32, f"line {line} is not a pulse line"
    return line


def truth(fn, inputs: int = 4) -> int:
    """Truth table for a glue cell from a Python predicate over (in0..in3)."""
    table = 0
    for index in range(16):
        bits = [(index >> b) & 1 for b in range(4)]
        if fn(*bits[:inputs]):
            table |= 1 << index
    return table


# ------------------------------------------------------------------ assembler
OP_PFIX, OP_LDC, OP_ADC, OP_XRC, OP_J, OP_JZ, OP_DJNZ, OP_SETC = range(8)
OP_WCF, OP_RD, OP_WEV, OP_FIRE, OP_PIN, OP_DLY, OP_OPR, OP_ANDC = range(8, 16)
OPR_HALT, OPR_PULL, OPR_PUSH, OPR_CLREV, OPR_A_FROM_C = 1, 2, 3, 4, 5
OPR_TXP, OPR_LDM = 7, 8


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
    def xrc(self, v: int) -> None: self._emit(OP_XRC, v)
    def andc(self, v: int) -> None: self._emit(OP_ANDC, v)
    def setc(self, v: int) -> None: self._emit(OP_SETC, v)
    def wcf(self, addr: int) -> None: self._emit(OP_WCF, addr)
    def rd(self, addr: int) -> None: self._emit(OP_RD, addr)
    def wev(self, line: int) -> None: self._emit(OP_WEV, line)
    def fire(self, n: int) -> None: self._emit(OP_FIRE, n)
    def dly(self, cycles: int) -> None: self._emit(OP_DLY, cycles)
    def pin(self, p: int, v: int) -> None: self.code.append((OP_PIN << 4) | (v << 3) | p)
    def j(self, label: str) -> None: self._branch(OP_J, label)
    def jz(self, label: str) -> None: self._branch(OP_JZ, label)
    def djnz(self, label: str) -> None: self._branch(OP_DJNZ, label)
    def halt(self) -> None: self._emit(OP_OPR, OPR_HALT)
    def push(self, channel: int = 0) -> None: self._emit(OP_OPR, (channel << 4) | OPR_PUSH)
    def clrev(self) -> None: self._emit(OP_OPR, OPR_CLREV)
    def a_from_c(self) -> None: self._emit(OP_OPR, OPR_A_FROM_C)
    def txp(self, channel: int = 0) -> None: self._emit(OP_OPR, (channel << 4) | OPR_TXP)
    def ldm(self) -> None: self._emit(OP_OPR, OPR_LDM)

    def stream_sram_to_tx(self, start: int, end: int, channel: int = 0) -> None:
        """Copy SRAM[start:end] into a TX FIFO (about 25 cycles a byte)."""
        loop, done = f"_copy{len(self.code)}", f"_copied{len(self.code)}"
        self.setc(start)
        self.label(loop)
        self.ldm()
        self.txp(channel)
        self.a_from_c()
        self.xrc(end)
        self.jz(done)
        self.j(loop)
        self.label(done)

    def cfg(self, addr: int, value: int) -> None:
        self.ldc(value)
        self.wcf(addr)

    def idle_forever(self) -> None:
        name = f"_idle{len(self.code)}"
        self.label(name)
        self.j(name)

    def assemble(self) -> list[int]:
        code = list(self.code)
        for at, op, label in self.fixups:
            target = self.labels[label]
            code[at] = (OP_PFIX << 4) | ((target >> 8) & 0xF)
            code[at + 1] = (OP_PFIX << 4) | ((target >> 4) & 0xF)
            code[at + 2] = (op << 4) | (target & 0xF)
        assert len(code) <= 1024, len(code)
        return code

    # ------------------------------------------------------------- fabric
    def timer(self, k: int, *, reload: int, phase: int, start: int = ZERO,
              stop: int = ZERO, idle: int = 0, pulse: bool = False,
              resync: int | None = None, hold: int | None = None,
              hold_invert: bool = False) -> None:
        base = 4 * k
        self.cfg(base + 0, reload)
        self.cfg(base + 1, phase)
        sync = 0
        if resync is not None:
            sync |= _level(resync) | (1 << 5)
        if hold is not None:
            sync |= (_level(hold) << 6) | (1 << 11) | (int(hold_invert) << 12)
        self.cfg(base + 3, sync)
        self.cfg(base + 2, start | (stop << 6) | (idle << 12) | (int(pulse) << 13))

    def shifter(self, k: int, *, length: int = 8, pre: int = 0, pre_val: int = 0,
                post: int = 0, post_val: int = 0, parity: int = 0,
                msb: bool = False, lead: bool = False, end_on_sample: bool = False,
                idle: int = 0, shift: int = ZERO, sample: int = ZERO) -> None:
        base = 0x10 + 4 * k
        frame = ((length - 1) | (pre << 4) | (pre_val << 6) | (post << 7) |
                 (post_val << 9) | (parity << 10) | (int(msb) << 12) |
                 (int(lead) << 13) | (int(end_on_sample) << 14) | (idle << 15))
        self.cfg(base + 1, frame)
        self.cfg(base + 2, shift | (sample << 6))

    def shifter_data(self, k: int, value: int) -> None:
        self.cfg(0x10 + 4 * k, value)

    def shifter_io(self, k: int, *, start: int = ZERO, data_in: int | None = None,
                   pull: bool = False, push: bool = False) -> None:
        data = 0 if data_in is None else _level(data_in)
        self.cfg(0x10 + 4 * k + 3, start | (data << 6) | (int(pull) << 11) |
                 (int(push) << 12))

    def counter(self, k: int, *, match: int, step: int, data: int | None = None,
                mode: int = COUNT_STEPS, clear: int = ZERO) -> None:
        base = 0x20 + 4 * k
        level = 0 if data is None else _level(data)
        self.cfg(base + 0, match)
        self.cfg(base + 2, _pulse(clear))
        self.cfg(base + 1, step | (level << 6) | (mode << 11))

    def crc(self, *, width: int, poly: int, check: int, absorb: int, data: int,
            emit: int = ZERO, init: int = ZERO, init_ones: bool = True) -> None:
        """The register holds its init value until the fabric is armed;
        `init` re-initializes it at runtime (e.g. between packets)."""
        self.cfg(0x28, poly & 0xFFFF)
        self.cfg(0x29, poly >> 16)
        self.cfg(0x2A, check & 0xFFFF)
        self.cfg(0x2B, check >> 16)
        self.cfg(0x2E, (width - 1) | (int(init_ones) << 5))
        self.cfg(0x2D, emit | (_pulse(init) << 6))
        self.cfg(0x2C, absorb | (_level(data) << 6))

    def glue(self, k: int, table: int, inputs: list[int], *,
             registered: bool = False, enable: int = ONE) -> None:
        """Inputs 0-1 take any line, inputs 2-3 only level lines, so pulse
        inputs are listed first (landing in slots 0-1) and the truth table is
        permuted to match. Unused slots are don't-cares in the table."""
        pulses = [i for i, line in enumerate(inputs) if line < 32]
        levels = [i for i, line in enumerate(inputs) if line >= 32]
        assert len(pulses) <= 2, "a glue cell takes at most two pulse inputs"
        order = pulses + levels + [None] * (4 - len(inputs))   # slot -> input
        permuted = 0
        for index in range(16):
            original = 0
            for slot, source in enumerate(order):
                if source is not None and (index >> slot) & 1:
                    original |= 1 << source
            if (table >> original) & 1:
                permuted |= 1 << index
        line = [ZERO if src is None else inputs[src] for src in order]
        base = 0x40 + 4 * k
        self.cfg(base + 0, permuted)
        self.cfg(base + 1, line[0] | (line[1] << 6))
        self.cfg(base + 2, (_level(line[2]) if order[2] is not None else 0) |
                 ((_level(line[3]) if order[3] is not None else 0) << 5))
        self.cfg(base + 3, _pulse(enable) | (int(registered) << 5))

    def pin_cell(self, p: int, *, mode: int, src: int | None = None, cpu: bool = False) -> None:
        """Drive pin p from a level line, or from the controller pin bit."""
        level = 0 if src is None else _level(src)
        self.cfg(0x18 + p, level | (int(cpu) << 5) | (mode << 6))

    def flags(self, value: int) -> None:
        self.cfg(0x30, value)

    def arm(self) -> None:
        """Go live: tiles and pin outputs stay idle until the whole
        configuration has been written."""
        self.cfg(0x31, 1)


# ------------------------------------------------------------- host helpers
async def load_program(dut, program: list[int], address: int = 0) -> None:
    """Write bytes into SRAM at `address` (programs at 0, data after them)."""
    await host_command(dut, 0x1, address)
    await host_command(dut, 0x2, address >> 4)
    await host_command(dut, 0x3, address >> 8)
    for byte in program:
        await host_command(dut, 0x4, byte)
        await host_command(dut, 0x5, byte >> 4)


async def select_channel(dut, channel: int) -> None:
    """FIFO channel k belongs to shifter k; TX/RX/status commands use it."""
    await host_command(dut, 0xE, channel)


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


async def tx_full(dut) -> bool:
    await host_command(dut, 0xA)
    return bool(int(dut.uo_out.value) & 0x20)


async def stream_tx(dut, data: list[int]) -> None:
    """Keep the 4-deep TX FIFO topped up while the engine runs."""
    for byte in data:
        while await tx_full(dut):
            pass
        await push_tx(dut, byte)


async def drain_rx(dut, count: int, timeout_polls: int = 20000) -> list[int]:
    received: list[int] = []
    for _ in range(timeout_polls):
        if len(received) == count:
            return received
        if not await rx_empty(dut):
            received.append(await pop_rx(dut))
    raise AssertionError(f"received only {received}")


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

    async def _run(self) -> None:
        while True:
            await FallingEdge(self.dut.clk)
            self.dut.uio_in.value = self.levels()

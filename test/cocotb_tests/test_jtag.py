"""JTAG master on the spatial fabric against a reference IEEE 1149.1 TAP."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import driven_level, reset_top, start_clock
from cocotb_tests.fabric import Bus, drain_until_halted, load_program, start_engine
from cocotb_tests.protocols import JTAG_TCK, JTAG_TDI, JTAG_TDO, JTAG_TMS, jtag_master

HALF = 5
IDCODE = 0x1BA0_0477
IR_LEN = 4
IR_IDCODE, IR_USER, IR_BYPASS = 0b1110, 0b1010, 0b1111

# TAP state -> (next if TMS=0, next if TMS=1)
NEXT = {
    "RESET": ("IDLE", "RESET"), "IDLE": ("IDLE", "SELECT_DR"),
    "SELECT_DR": ("CAPTURE_DR", "SELECT_IR"), "CAPTURE_DR": ("SHIFT_DR", "EXIT1_DR"),
    "SHIFT_DR": ("SHIFT_DR", "EXIT1_DR"), "EXIT1_DR": ("PAUSE_DR", "UPDATE_DR"),
    "PAUSE_DR": ("PAUSE_DR", "EXIT2_DR"), "EXIT2_DR": ("SHIFT_DR", "UPDATE_DR"),
    "UPDATE_DR": ("IDLE", "SELECT_DR"), "SELECT_IR": ("CAPTURE_IR", "RESET"),
    "CAPTURE_IR": ("SHIFT_IR", "EXIT1_IR"), "SHIFT_IR": ("SHIFT_IR", "EXIT1_IR"),
    "EXIT1_IR": ("PAUSE_IR", "UPDATE_IR"), "PAUSE_IR": ("PAUSE_IR", "EXIT2_IR"),
    "EXIT2_IR": ("SHIFT_IR", "UPDATE_IR"), "UPDATE_IR": ("IDLE", "SELECT_DR"),
}


def tck_level(bus: Bus) -> int:
    """TCK has a pull-down (IEEE 1149.1 recommends one), so a released pin,
    as after the program halts, reads low."""
    if driven_level(bus.dut, JTAG_TCK) is None:
        return 0
    return bus.level(JTAG_TCK)


class Tap:
    """Samples TMS/TDI on TCK rising, updates TDO on TCK falling, and checks
    that the master only moves TMS/TDI while TCK is low and settled."""

    def __init__(self, dut, bus: Bus) -> None:
        self.dut, self.bus = dut, bus
        self.state = "RESET"
        self.ir = IR_IDCODE
        self.user = 0x00
        self.shift = 0
        self.length = 0
        self.tdo = 0
        self.updates: list[tuple[str, int]] = []
        cocotb.start_soon(self._run())

    def _dr(self) -> tuple[int, int]:
        if self.ir == IR_IDCODE:
            return IDCODE, 32
        if self.ir == IR_USER:
            return self.user, 8
        return 0, 1                                  # BYPASS captures 0

    async def _run(self) -> None:
        bus = self.bus
        tck = tck_level(bus)
        tms, tdi = bus.level(JTAG_TMS), bus.level(JTAG_TDI)
        low_for = 0
        self.cycle = 0
        self.clocks = 0
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            now = tck_level(bus)
            if now == tck:
                if now == 1:
                    assert (bus.level(JTAG_TMS), bus.level(JTAG_TDI)) == (tms, tdi), \
                        ("TMS/TDI moved while TCK high", self.cycle, self.state)
                else:
                    low_for += 1
                tms, tdi = bus.level(JTAG_TMS), bus.level(JTAG_TDI)
                continue
            if now == 1:                             # rising edge: sample
                assert low_for >= HALF - 1, ("TCK low too short", low_for)
                self._clock(tms, tdi)
                self.clocks += 1
            else:                                    # falling edge: drive TDO
                low_for = 0
                bus.drive[JTAG_TDO] = self.tdo
            tck = now

    def _clock(self, tms: int, tdi: int) -> None:
        state = self.state
        if state == "SHIFT_DR" or state == "SHIFT_IR":
            self.shift = (self.shift >> 1) | (tdi << (self.length - 1))
        nxt = NEXT[state][tms]
        if nxt == "CAPTURE_DR":
            self.shift, self.length = self._dr()
        elif nxt == "CAPTURE_IR":
            self.shift, self.length = 0b0001, IR_LEN     # IEEE: ...01 captured
        elif nxt == "UPDATE_IR":
            self.ir = self.shift
            self.updates.append(("IR", self.shift))
        elif nxt == "UPDATE_DR":
            if self.ir == IR_USER:
                self.user = self.shift
            self.updates.append(("DR", self.shift))
        elif nxt == "RESET":
            self.ir = IR_IDCODE
        self.state = nxt
        # TDO presents the shift register's LSB while shifting.
        self.tdo = self.shift & 1 if nxt in ("SHIFT_DR", "SHIFT_IR") else 1


def sequence() -> list[tuple[int, int]]:
    """(tms, tdi) per TCK, built from TAP moves."""
    bits: list[tuple[int, int]] = []

    def tms(*levels):
        bits.extend((t, 0) for t in levels)

    def shift(value: int, length: int):
        for i in range(length):
            bits.append((int(i == length - 1), (value >> i) & 1))   # last bit exits

    tms(1, 1, 1, 1, 1, 0)                  # any state -> RESET -> IDLE
    tms(1, 0, 0)                           # -> SELECT_DR -> CAPTURE_DR -> SHIFT_DR
    shift(0, 32)                           # IDCODE out (IR is IDCODE after reset)
    tms(1, 0)                              # EXIT1 -> UPDATE_DR -> IDLE
    tms(1, 1, 0, 0)                        # -> SELECT_IR -> CAPTURE_IR -> SHIFT_IR
    shift(IR_USER, IR_LEN)
    tms(1, 0)                              # -> UPDATE_IR -> IDLE
    tms(1, 0, 0)                           # -> SHIFT_DR
    shift(0x5A, 8)
    tms(1, 0)
    tms(1, 0, 0)                           # read the user register back
    shift(0xC3, 8)
    tms(1, 0)
    return bits


def chunks(bits: list[tuple[int, int]]) -> list[tuple[int, int, int]]:
    out = []
    for k in range(0, len(bits), 8):
        part = bits[k:k + 8]
        out.append((len(part), sum(t << i for i, (t, _) in enumerate(part)),
                    sum(d << i for i, (_, d) in enumerate(part))))
    return out


@cocotb.test()
async def test_jtag_idcode_and_user_register(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    tap = Tap(dut, bus)
    bits = sequence()
    await load_program(dut, jtag_master(HALF, chunks(bits)))
    await start_engine(dut)
    received = await drain_until_halted(dut, timeout_cycles=40000)
    tdo = [(byte >> i) & 1 for (length, _, _), byte in zip(chunks(bits), received)
           for i in range(length)]
    assert len(tdo) == len(bits)
    # TDO bits seen while shifting each register, in order.
    assert tap.updates == [("DR", 0), ("IR", IR_USER), ("DR", 0x5A), ("DR", 0xC3)]
    shifted = [bit for bit, (_, _) in zip(tdo, bits)]
    def word(start: int, length: int) -> int:
        return sum(shifted[start + i] << i for i in range(length))
    assert word(9, 32) == IDCODE, hex(word(9, 32))
    assert word(9 + 32 + 2 + 4, IR_LEN) == 0b0001          # captured IR
    assert word(9 + 32 + 2 + 4 + 4 + 2 + 3, 8) == 0x00     # user before write
    assert word(9 + 32 + 2 + 4 + 4 + 2 + 3 + 8 + 2 + 3, 8) == 0x5A
    assert tap.state == "IDLE"

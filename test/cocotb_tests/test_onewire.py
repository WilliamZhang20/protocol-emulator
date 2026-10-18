"""1-Wire master on the spatial fabric against a DS18B20-style slave."""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import Bus, drain_until_halted, load_program, start_engine
from cocotb_tests.protocols import ONEWIRE_DQ, US, onewire_master

CLOCK_NS = 25            # 40 MHz


def crc8(data: bytes) -> int:
    """Dallas/Maxim CRC-8 (x^8 + x^5 + x^4 + 1, reflected)."""
    crc = 0
    for byte in data:
        for _ in range(8):
            mix = (crc ^ byte) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8C
            byte >>= 1
    return crc


ROM = bytes([0x28, 0x61, 0x64, 0x12, 0x3F, 0x9C, 0x01])
ROM = ROM + bytes([crc8(ROM)])


class Slave:
    """Cycle-level 1-Wire device: answers resets with a presence pulse,
    samples write slots 30 us after the master's falling edge, and drives
    0 bits of read slots for 30 us. Records every master low pulse."""

    def __init__(self, dut, bus: Bus, present: bool = True) -> None:
        self.dut, self.bus, self.present = dut, bus, present
        self.lows: list[tuple[int, int]] = []          # (fall cycle, cycles)
        self.received: list[int] = []
        self.scratchpad = bytearray([0x50, 0x05, 0x4B, 0x46, 0x7F, 0xFF, 0x0C, 0x10])
        self.cycle = 0
        cocotb.start_soon(self._clock())
        cocotb.start_soon(self._monitor())
        cocotb.start_soon(self._run())

    async def _clock(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1

    async def _monitor(self) -> None:
        """Record every interval the master pulls the line low."""
        fall = None
        while True:
            await RisingEdge(self.dut.clk)
            pulling = self.master_pulling()
            if pulling and fall is None:
                fall = self.cycle
            elif not pulling and fall is not None:
                self.lows.append((fall, self.cycle - fall))
                fall = None

    async def _wait(self, cycles: int) -> None:
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)

    async def _fall(self) -> int:
        """Wait for the master to pull the line low; return the low time
        (the slave's own pull, if any, is not counted)."""
        while self.bus.level(ONEWIRE_DQ):
            await RisingEdge(self.dut.clk)
        return self.cycle

    async def _master_low(self, fall: int) -> int:
        while self.master_pulling():
            await RisingEdge(self.dut.clk)
        return self.cycle - fall

    def master_pulling(self) -> bool:
        oe = (int(self.dut.uio_oe.value) >> ONEWIRE_DQ) & 1
        out = (int(self.dut.uio_out.value) >> ONEWIRE_DQ) & 1
        return bool(oe) and not out

    async def _slot(self, send: int | None) -> int:
        """One slot; returns the bit the master wrote (send=None) or sends."""
        fall = await self._fall()
        if send == 0:
            self.bus.drive[ONEWIRE_DQ] = 0
        await self._wait(30 * US - 1)
        bit = self.bus.level(ONEWIRE_DQ)
        self.bus.drive[ONEWIRE_DQ] = None
        low = await self._master_low(fall)
        if low >= 400 * US:
            raise _Reset()
        return bit

    async def _byte(self) -> int:
        value = 0
        for i in range(8):
            value |= await self._slot(None) << i
        self.received.append(value)
        return value

    async def _send(self, data: bytes) -> None:
        for byte in data:
            for i in range(8):
                await self._slot((byte >> i) & 1)

    async def _run(self) -> None:
        while True:
            try:
                fall = await self._fall()
                low = await self._master_low(fall)
                if low < 400 * US:
                    continue                  # not a reset: ignore until one
                await self._session()
            except _Reset:
                await self._session()

    async def _session(self) -> None:
        if not self.present:
            return
        await self._wait(30 * US)
        self.bus.drive[ONEWIRE_DQ] = 0
        await self._wait(120 * US)
        self.bus.drive[ONEWIRE_DQ] = None
        command = await self._byte()
        if command == 0x33:                   # READ ROM
            await self._send(ROM)
            return
        assert command == 0xCC, hex(command)  # SKIP ROM
        function = await self._byte()
        if function == 0x4E:                  # WRITE SCRATCHPAD: TH, TL, config
            for k in range(3):
                self.scratchpad[2 + k] = await self._byte()
        elif function == 0xBE:                # READ SCRATCHPAD
            data = bytes(self.scratchpad)
            await self._send(data + bytes([crc8(data)]))


class _Reset(Exception):
    pass


async def run(dut, ops, present=True):
    await start_clock(dut, CLOCK_NS)
    await reset_top(dut)
    bus = Bus(dut)
    slave = Slave(dut, bus, present)
    await load_program(dut, onewire_master(ops))
    await start_engine(dut)
    received = await drain_until_halted(dut, timeout_cycles=4_000_000)
    return slave, received


def check_timing(lows: list[tuple[int, int]]) -> None:
    """Every master low is one of exactly three lengths (6 us, 60 us, 480 us,
    the same cycle count every time); slots start at least 70 us apart; a
    reset is followed by at least 480 us of release."""
    lengths = sorted({length for _, length in lows})
    assert len(lengths) <= 3, lengths
    for length in lengths:
        assert any(abs(length - t * US) <= 2 for t in (6, 60, 480)), lengths
    for k, (fall, length) in enumerate(lows):
        if k:
            gap = fall - lows[k - 1][0]
            minimum = 960 * US if lows[k - 1][1] > 400 * US else 70 * US
            assert gap >= minimum - 2, (k, gap)


@cocotb.test()
async def test_onewire_read_rom(dut):
    ops = [("reset", 0), ("write", 0x33)] + [("read", 0)] * 8
    slave, received = await run(dut, ops)
    assert received[0] & 1 == 0, "no presence pulse seen"
    assert bytes(received[1:]) == ROM, bytes(received[1:]).hex()
    assert crc8(bytes(received[1:])) == 0
    check_timing(slave.lows)


@cocotb.test()
async def test_onewire_scratchpad_write_then_read(dut):
    ops = ([("reset", 0), ("write", 0xCC), ("write", 0x4E),
            ("write", 0x19), ("write", 0xE6), ("write", 0x5F)] +
           [("reset", 0), ("write", 0xCC), ("write", 0xBE)] + [("read", 0)] * 9)
    slave, received = await run(dut, ops)
    assert [r & 1 for r in received[:2]] == [0, 0]
    pad = bytes(received[2:])
    assert pad[2:5] == bytes([0x19, 0xE6, 0x5F]), pad.hex()
    assert crc8(pad) == 0, pad.hex()
    check_timing(slave.lows)


@cocotb.test()
async def test_onewire_no_device(dut):
    """With nothing on the bus the presence sample reads released (1)."""
    _, received = await run(dut, [("reset", 0)], present=False)
    assert received == [1], received

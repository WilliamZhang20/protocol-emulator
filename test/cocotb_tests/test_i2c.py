"""I2C master on the spatial fabric against an open-drain reference slave,
including clock stretching and a NACK from an absent address."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import read_status, reset_top, start_clock, status_running
from cocotb_tests.fabric import Bus, load_program, pop_rx, rx_empty, start_engine
from cocotb_tests.protocols import I2C_SCL, I2C_SDA, i2c_write_then_read

HALF = 10
ADDRESS = 0x50


class I2cSlave:
    def __init__(self, dut, bus: Bus, address: int, read_data: list[int],
                 stretch_cycles: int = 0) -> None:
        self.dut = dut
        self.bus = bus
        self.address = address
        self.read_data = list(read_data)
        self.stretch_cycles = stretch_cycles
        self.written: list[int] = []
        self.starts = 0
        self.stops = 0
        cocotb.start_soon(self._run())

    def _sda(self, level: int | None) -> None:
        self.bus.drive[I2C_SDA] = level

    async def _stretch(self) -> None:
        self.bus.drive[I2C_SCL] = 0
        await ClockCycles(self.dut.clk, self.stretch_cycles)
        self.bus.drive[I2C_SCL] = None

    async def _run(self) -> None:
        bus = self.bus
        phase = "idle"
        shift = bits = 0
        reading = False
        out = 0
        prev_scl, prev_sda = bus.level(I2C_SCL), bus.level(I2C_SDA)
        while True:
            await RisingEdge(self.dut.clk)
            scl, sda = bus.level(I2C_SCL), bus.level(I2C_SDA)
            if scl and prev_scl and sda != prev_sda:
                if not sda:
                    self.starts += 1
                    phase, shift, bits, reading = "addr", 0, 0, False
                    self._sda(None)
                else:
                    self.stops += 1
                    phase = "idle"
                    self._sda(None)
            elif scl and not prev_scl:
                if phase in ("addr", "write"):
                    shift = ((shift << 1) | sda) & 0xFF
                    bits += 1
                elif phase == "master_ack":
                    phase = "send" if sda == 0 else "idle"
            elif not scl and prev_scl:
                if phase in ("addr", "write") and bits == 8:
                    if phase == "addr":
                        if shift >> 1 != self.address:
                            phase = "idle"
                        else:
                            reading = bool(shift & 1)
                            self._sda(0)
                            phase = "ack"
                    else:
                        self.written.append(shift)
                        self._sda(0)
                        phase = "ack"
                elif phase == "ack":
                    if self.stretch_cycles:
                        cocotb.start_soon(self._stretch())
                    if reading:
                        out = self.read_data.pop(0)
                        self._sda((out >> 7) & 1)
                        bits, phase = 1, "tx"
                    else:
                        self._sda(None)
                        shift, bits, phase = 0, 0, "write"
                elif phase == "tx":
                    if bits < 8:
                        self._sda((out >> (7 - bits)) & 1)
                        bits += 1
                    else:
                        self._sda(None)
                        phase = "master_ack"
                elif phase == "send":
                    out = self.read_data.pop(0)
                    self._sda((out >> 7) & 1)
                    bits, phase = 1, "tx"
            prev_scl, prev_sda = scl, sda


async def drain_until_halted(dut, timeout_cycles: int = 60000) -> list[int]:
    """The RX FIFO is 4 deep, so drain it while the program runs."""
    received = []
    for _ in range(timeout_cycles // 8):
        await ClockCycles(dut.clk, 4)
        if not await rx_empty(dut):
            received.append(await pop_rx(dut))
            continue
        if not status_running(await read_status(dut)):
            return received
    raise AssertionError("I2C program did not finish")


async def scl_phases(dut, bus: Bus, phases: list[tuple[int, int]]) -> None:
    """Record (level, cycles) for every completed SCL phase."""
    level, length = bus.level(I2C_SCL), 0
    while True:
        await RisingEdge(dut.clk)
        now = bus.level(I2C_SCL)
        if now == level:
            length += 1
        else:
            phases.append((level, length))
            level, length = now, 1


async def run_transaction(dut, stretch_cycles: int) -> list[tuple[int, int]]:
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    phases: list[tuple[int, int]] = []
    cocotb.start_soon(scl_phases(dut, bus, phases))
    slave = I2cSlave(dut, bus, ADDRESS, [0xC3, 0x5A], stretch_cycles)
    payload = [0x10, 0xA5]
    await load_program(dut, i2c_write_then_read(HALF, ADDRESS, payload, reads=2))
    await start_engine(dut)
    received = await drain_until_halted(dut)
    assert slave.written == payload
    assert slave.starts == 2 and slave.stops == 1
    # address ACK, two payload ACKs, read-address ACK, two data bytes
    assert received == [0, 0, 0, 0, 0xC3, 0x5A], received
    # Every SCL phase after the first START honours the half period, even
    # when the slave stretches (the timer tile must not truncate high time).
    short = [p for p in phases[1:] if p[1] < HALF]
    assert not short, short
    return phases


@cocotb.test()
async def test_i2c_write_then_read(dut):
    await run_transaction(dut, stretch_cycles=0)


@cocotb.test()
async def test_i2c_clock_stretching(dut):
    """The slave holds SCL low after every ACK; the timer tile's hold input
    freezes the clock until SCL is really released."""
    stretched = await run_transaction(dut, stretch_cycles=20 * HALF)
    longest_low = max(n for level, n in stretched if level == 0)
    assert longest_low >= 20 * HALF, longest_low


@cocotb.test()
async def test_i2c_absent_address_nacks(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    I2cSlave(dut, bus, 0x22, [0x00, 0x00])
    await load_program(dut, i2c_write_then_read(HALF, ADDRESS, [], reads=1))
    await start_engine(dut)
    received = await drain_until_halted(dut)
    assert received[0] == 1, "absent address must read back NACK"

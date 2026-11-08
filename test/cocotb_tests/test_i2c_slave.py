"""I2C slave on the spatial fabric against a reference open-drain master."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import driven_level, reset_top, start_clock
from cocotb_tests.fabric import (
    Bus, drain_rx_tagged, load_program, push_tx, select_channel, start_engine,
)
from cocotb_tests.protocols import I2C_SCL, I2C_SDA, i2c_slave

ADDRESS = 0x3C
Q = 50                    # quarter SCL period: 200 cycles = 100 kHz at 20 MHz scale


class Master:
    """Open-drain master: drives SCL and SDA through the bus model, checks
    the slave never moves SDA while SCL is high."""

    def __init__(self, dut, bus: Bus) -> None:
        self.dut, self.bus = dut, bus
        self.violations: list[str] = []
        cocotb.start_soon(self._watch())

    async def _watch(self) -> None:
        prev_scl, prev_pull = 1, False
        while True:
            await RisingEdge(self.dut.clk)
            scl = self.bus.level(I2C_SCL)
            pull = driven_level(self.dut, I2C_SDA) == 0      # the slave pulls SDA low
            if scl and prev_scl and pull != prev_pull:
                self.violations.append("slave moved SDA while SCL high")
            prev_scl, prev_pull = scl, pull

    async def _wait(self, n=Q):
        await ClockCycles(self.dut.clk, n)

    def _scl(self, v):
        self.bus.drive[I2C_SCL] = 0 if v == 0 else None

    def _sda(self, v):
        self.bus.drive[I2C_SDA] = 0 if v == 0 else None

    async def start(self):
        self._sda(1); self._scl(1); await self._wait()
        self._sda(0); await self._wait()
        self._scl(0); await self._wait()

    async def stop(self):
        self._sda(0); await self._wait()
        self._scl(1); await self._wait()
        self._sda(1); await self._wait(4 * Q)

    async def _bit(self, v: int) -> int:
        self._sda(v); await self._wait()
        self._scl(1); await self._wait()
        got = self.bus.level(I2C_SDA)
        await self._wait()
        self._scl(0); await self._wait()
        return got

    async def write(self, byte: int) -> int:
        for i in range(8):
            await self._bit((byte >> (7 - i)) & 1)
        return await self._bit(1)          # ACK bit from the slave (0 = ACK)

    async def read(self, ack: bool) -> int:
        value = 0
        for _ in range(8):
            value = (value << 1) | await self._bit(1)
        await self._bit(0 if ack else 1)
        return value


@cocotb.test()
async def test_i2c_slave_write_read_and_foreign_address(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    master = Master(dut, bus)
    await load_program(dut, i2c_slave(ADDRESS))
    for byte in (0xA1, 0x5E, 0x00):
        await push_tx(dut, byte)
    await start_engine(dut)
    await ClockCycles(dut.clk, 1000)
    # write two bytes
    await master.start()
    acks = [await master.write(ADDRESS << 1)]
    acks += [await master.write(0x12), await master.write(0x34)]
    await master.stop()
    assert acks == [0, 0, 0], acks
    # someone else's address: no ACK, slave stays off the bus
    await master.start()
    assert await master.write(0x51 << 1) == 1, "ACKed a foreign address"
    await master.write(0xFF)
    await master.stop()
    # read two bytes (repeated start after a register write)
    await master.start()
    assert await master.write(ADDRESS << 1) == 0
    assert await master.write(0x07) == 0
    await master.start()                     # repeated START
    assert await master.write((ADDRESS << 1) | 1) == 0
    got = [await master.read(ack=True), await master.read(ack=False)]
    await master.stop()
    assert got == [0xA1, 0x5E], [hex(g) for g in got]
    assert not master.violations, master.violations[:3]
    assert driven_level(dut, I2C_SDA) is None, "SDA still held after STOP"
    await select_channel(dut, 1)
    received = [b for b, _, _ in await drain_rx_tagged(dut)]
    assert received[:3] == [ADDRESS << 1, 0x12, 0x34], [hex(b) for b in received]

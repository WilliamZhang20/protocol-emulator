"""Bit-transfer engine tests: SPI mode 0/3 and I2C write with clock stretch."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.reference.programs import (
    i2c_write_byte_program,
    spi_master_program,
)

MOSI, MISO, SCLK, CS = 0, 1, 2, 3
SDA, SCL = 0, 1
HALF = 4


async def host_command(dut, command: int, payload: int = 0) -> None:
    dut.ui_in.value = ((command & 0xF) << 4) | (payload & 0xF)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)


async def set_program_address(dut, address: int) -> None:
    await host_command(dut, 0x1, address)
    await host_command(dut, 0x2, address >> 4)
    await host_command(dut, 0x3, address >> 8)


async def load_program(dut, program: list[int]) -> None:
    await set_program_address(dut, 0)
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


def _pin(value: int, pin: int) -> int:
    return (value >> pin) & 1


def _set_pin(value: int, pin: int, bit: int) -> int:
    if bit:
        return value | (1 << pin)
    return value & ~(1 << pin)


def _driven_level(dut, pin: int) -> int | None:
    oe = int(dut.uio_oe.value)
    out = int(dut.uio_out.value)
    if _pin(oe, pin):
        return _pin(out, pin)
    return None


async def wait_cs_low(dut, timeout: int = 2000) -> None:
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if _driven_level(dut, CS) == 0:
            return
    raise AssertionError("SPI CS did not go low")


async def wait_cs_high(dut, timeout: int = 2000) -> None:
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if _driven_level(dut, CS) == 1:
            return
    raise AssertionError("SPI CS did not go high")


async def spi_slave(
    dut,
    *,
    mode: int,
    miso_byte: int,
    expect_mosi: int,
    bit_count: int = 8,
) -> int:
    """SPI slave: change MISO on the trailing edge; sample MOSI on the leading edge for CPHA=0."""
    cpol = 1 if mode in (2, 3) else 0
    cpha = 1 if mode in (1, 3) else 0
    # Wait until SCLK sits at CPOL so the first transfer edge is not missed/doubled.
    for _ in range(100):
        await RisingEdge(dut.clk)
        live = _driven_level(dut, SCLK)
        if live == cpol:
            break
    prev_clk = cpol
    bit_index = 0
    sampled = 0
    uio = int(dut.uio_in.value)

    # CPHA=0: first MISO bit valid while clock idle before the first leading edge
    if cpha == 0:
        uio = _set_pin(uio, MISO, (miso_byte >> (bit_count - 1)) & 1)
        dut.uio_in.value = uio

    while bit_index < bit_count:
        await RisingEdge(dut.clk)
        clk = _driven_level(dut, SCLK)
        if clk is None:
            continue
        edge_rise = prev_clk == 0 and clk == 1
        edge_fall = prev_clk == 1 and clk == 0
        leading = edge_rise if cpol == 0 else edge_fall
        trailing = edge_fall if cpol == 0 else edge_rise

        if cpha == 0:
            if leading:
                mosi = _driven_level(dut, MOSI)
                assert mosi is not None
                sampled = (sampled << 1) | mosi
                bit_index += 1
            elif trailing and bit_index < bit_count:
                uio = _set_pin(
                    int(dut.uio_in.value),
                    MISO,
                    (miso_byte >> (bit_count - 1 - bit_index)) & 1,
                )
                dut.uio_in.value = uio
        else:
            # CPHA=1: capture MOSI on the trailing edge using the level held
            # through the active half (ignore same-cycle launches).
            if leading and bit_index < bit_count:
                uio = _set_pin(
                    int(dut.uio_in.value),
                    MISO,
                    (miso_byte >> (bit_count - 1 - bit_index)) & 1,
                )
                dut.uio_in.value = uio
            if trailing:
                mosi = _driven_level(dut, MOSI)
                assert mosi is not None
                sampled = (sampled << 1) | mosi
                bit_index += 1

        prev_clk = clk

    assert sampled == expect_mosi, f"MOSI {sampled:#x} != {expect_mosi:#x}"
    return sampled


async def run_spi_mode(dut, mode: int) -> None:
    await start_clock(dut)
    await reset_top(dut)
    tx_byte = 0xA5
    rx_byte = 0x3C
    await load_program(dut, spi_master_program(mode=mode, half_period=HALF))
    await push_tx(dut, tx_byte)
    await start_engine(dut)
    await wait_cs_low(dut)
    await spi_slave(dut, mode=mode, miso_byte=rx_byte, expect_mosi=tx_byte)
    await wait_cs_high(dut)
    got = await pop_rx(dut)
    assert got == rx_byte, f"SPI mode {mode}: expected RX {rx_byte:#x}, got {got:#x}"


@cocotb.test()
async def test_spi_mode0_bit_xfer(dut):
    await run_spi_mode(dut, 0)


@cocotb.test()
async def test_spi_mode3_bit_xfer(dut):
    await run_spi_mode(dut, 3)


class OpenDrainBus:
    """Wired-AND model for SDA/SCL with pull-ups and optional slave holds."""

    def __init__(self, dut, sda: int = SDA, scl: int = SCL):
        self.dut = dut
        self.sda = sda
        self.scl = scl
        self.slave_sda_low = False
        self.slave_scl_low = False
        self._uio = (1 << sda) | (1 << scl)
        dut.uio_in.value = self._uio

    def _master_low(self, pin: int) -> bool:
        level = _driven_level(self.dut, pin)
        return level == 0

    def apply(self) -> None:
        sda = 0 if self._master_low(self.sda) or self.slave_sda_low else 1
        scl = 0 if self._master_low(self.scl) or self.slave_scl_low else 1
        self._uio = _set_pin(self._uio, self.sda, sda)
        self._uio = _set_pin(self._uio, self.scl, scl)
        self.dut.uio_in.value = self._uio

    def line(self, pin: int) -> int:
        return _pin(self._uio, pin)


async def i2c_bus_updater(dut, bus: OpenDrainBus):
    while True:
        await RisingEdge(dut.clk)
        bus.apply()


async def i2c_slave_write_listener(
    bus: OpenDrainBus,
    *,
    expect_byte: int,
    ack: bool = True,
) -> int:
    """Observe START, capture 8 bits, drive ACK."""
    dut = bus.dut
    prev_scl = 1
    prev_sda = 1
    started = False
    bits = 0
    value = 0
    saw_ack_phase = False

    while True:
        await RisingEdge(dut.clk)
        bus.apply()
        scl = bus.line(SCL)
        sda = bus.line(SDA)

        if prev_scl == 1 and scl == 1 and prev_sda == 1 and sda == 0:
            started = True
            bits = 0
            value = 0

        if started and prev_scl == 0 and scl == 1 and bits < 8:
            value = (value << 1) | sda
            bits += 1
            if bits == 8:
                assert value == expect_byte, f"I2C got {value:#x}, expected {expect_byte:#x}"
                bus.slave_sda_low = bool(ack)
                bus.apply()
                saw_ack_phase = True

        if saw_ack_phase and prev_scl == 1 and scl == 0:
            bus.slave_sda_low = False
            bus.apply()
            return value

        if started and bits >= 8 and prev_scl == 1 and scl == 1 and prev_sda == 0 and sda == 1:
            return value

        prev_scl = scl
        prev_sda = sda


@cocotb.test()
async def test_i2c_byte_write_ack(dut):
    await start_clock(dut)
    await reset_top(dut)
    payload = 0x5A
    bus = OpenDrainBus(dut)
    cocotb.start_soon(i2c_bus_updater(dut, bus))

    await load_program(dut, i2c_write_byte_program(half_period=HALF))
    await push_tx(dut, payload)
    await push_tx(dut, 0x01)  # ACK slot releases SDA (open-drain 1)
    listener = cocotb.start_soon(
        i2c_slave_write_listener(bus, expect_byte=payload, ack=True)
    )
    await start_engine(dut)
    got = await listener
    assert got == payload
    ack_byte = await pop_rx(dut)
    # 1-bit ACK transfer left-aligns the sampled bit into the MSB of the byte
    assert (ack_byte & 0x80) == 0x00, f"expected ACK (0), got {ack_byte:#x}"


async def i2c_ack_responder(bus: OpenDrainBus) -> None:
    """After START + 8 SCL rises, pull SDA low for the ACK slot."""
    dut = bus.dut
    prev_scl = 1
    prev_sda = 1
    started = False
    bits = 0
    while True:
        await RisingEdge(dut.clk)
        bus.apply()
        scl = bus.line(SCL)
        sda = bus.line(SDA)
        if prev_scl == 1 and scl == 1 and prev_sda == 1 and sda == 0:
            started = True
            bits = 0
        if started and prev_scl == 0 and scl == 1 and bits < 8:
            bits += 1
            if bits == 8:
                bus.slave_sda_low = True
                bus.apply()
        if bits == 8 and prev_scl == 1 and scl == 0:
            bus.slave_sda_low = False
            bus.apply()
            return
        prev_scl = scl
        prev_sda = sda


@cocotb.test()
async def test_i2c_clock_stretch(dut):
    """Hold SCL low in CLOCK_ACTIVE; engine must stay busy until SCL rises."""
    await start_clock(dut)
    await reset_top(dut)
    payload = 0xC3
    stretch = 40
    bus = OpenDrainBus(dut)
    cocotb.start_soon(i2c_bus_updater(dut, bus))

    await load_program(dut, i2c_write_byte_program(half_period=HALF))
    await push_tx(dut, payload)
    await push_tx(dut, 0x01)
    cocotb.start_soon(i2c_ack_responder(bus))
    await start_engine(dut)

    for _ in range(2000):
        await RisingEdge(dut.clk)
        bus.apply()
        if _driven_level(dut, SCL) is None:
            break
    else:
        raise AssertionError("master never released SCL")

    # Slave stretches clock low.
    bus.slave_scl_low = True
    bus.apply()

    for _ in range(stretch):
        await RisingEdge(dut.clk)
        bus.apply()
        assert bus.line(SCL) == 0

    # Release stretch.
    bus.slave_scl_low = False
    bus.apply()

    for _ in range(5000):
        await RisingEdge(dut.clk)
        bus.apply()
        if int(dut.user_project.core.state.value) == 9:
            break
    else:
        raise AssertionError("engine did not halt after clock stretch")

    ack_byte = await pop_rx(dut)
    assert (ack_byte & 0x80) == 0x00, f"expected ACK (0), got {ack_byte:#x}"

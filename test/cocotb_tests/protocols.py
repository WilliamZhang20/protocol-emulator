"""Protocol programs for the spatial fabric. Each protocol is a fabric
configuration plus a short PX8 control loop; none of them is RTL.

Timing rule of thumb: every event-bus hop costs one cycle, and pin outputs are
registered, so phase values absorb a fixed, documented latency.
"""

from cocotb_tests.fabric import (
    MODE_OPEN_DRAIN, MODE_PUSH_PULL, SRC_CPU, Px8, ev_pin_fall,
    ev_pin_rise, ev_shifter_done, ev_shifter_start, ev_timer_fall,
    ev_timer_rise, rd_shifter_data, rd_shifter_status, src_shifter, src_timer,
)

UART_TX_PIN = 0
UART_RX_PIN = 1

SPI_CS, SPI_SCK, SPI_MOSI, SPI_MISO = 3, 4, 5, 6

I2C_SCL, I2C_SDA = 1, 2


def uart_full_duplex(bit_cycles: int) -> list[int]:
    """8N1 transmitter (shifter 0 + timer 0) and receiver (shifter 1 +
    timer 1) running concurrently and independently."""
    p = Px8()
    # TX: the shifter pulls a byte, its start event launches the bit timer,
    # and every timer tick advances one bit. The first interval absorbs the
    # start-event hop and the registered timer start.
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 3, pulse=True,
            start=ev_shifter_start(0), stop=ev_shifter_done(0))
    p.shifter(0, pre=1, pre_val=0, post=1, post_val=1, idle=1,
              shift=ev_timer_rise(0))
    p.pin_cell(UART_TX_PIN, src_shifter(0), MODE_PUSH_PULL)
    # RX: a falling edge starts both the sampling timer (first tick in the
    # middle of the start bit, net of synchronizer latency) and the shifter.
    p.timer(1, reload=bit_cycles - 1, phase=bit_cycles // 2 - 2, pulse=True,
            start=ev_pin_fall(UART_RX_PIN), stop=ev_shifter_done(1))
    p.shifter(1, pre=1, post=1, shift=ev_timer_rise(1),
              sample=ev_timer_rise(1), start=ev_pin_fall(UART_RX_PIN))
    p.shifter_io(1, in_pin=UART_RX_PIN, push=True)
    p.shifter_io(0, pull=True)
    p.label("idle")
    p.j("idle")
    return p.assemble()


def spi_master(mode: int, half_cycles: int, count: int) -> list[int]:
    """Full-duplex SPI master, MSB first, any CPOL/CPHA. Timer 0 is SCK;
    shifter 0 streams TX FIFO bytes out and RX bytes in."""
    cpol, cpha = mode >> 1, mode & 1
    leading = ev_timer_fall(0) if cpol else ev_timer_rise(0)
    trailing = ev_timer_rise(0) if cpol else ev_timer_fall(0)
    p = Px8()
    p.pin(SPI_CS, 1)
    p.pin_cell(SPI_CS, SRC_CPU, MODE_PUSH_PULL)
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=cpol,
            start=ev_shifter_start(0), stop=ev_shifter_done(0))
    p.pin_cell(SPI_SCK, src_timer(0), MODE_PUSH_PULL)
    if cpha == 0:
        p.shifter(0, msb=True, shift=trailing, sample=leading)
    else:
        p.shifter(0, msb=True, lead=True, end_on_sample=True,
                  shift=leading, sample=trailing)
    p.pin_cell(SPI_MOSI, src_shifter(0), MODE_PUSH_PULL)
    p.pin(SPI_CS, 0)
    p.dly(half_cycles)
    p.setc(count)
    p.shifter_io(0, in_pin=SPI_MISO, pull=True, push=True)
    p.label("byte")
    p.wev(ev_shifter_done(0))
    p.djnz("byte")
    p.dly(half_cycles)
    p.pin(SPI_CS, 1)
    p.dly(4)
    p.halt()
    return p.assemble()


class _I2c:
    """I2C master: timer 0 drives SCL (with clock-stretch hold), shifter 0
    drives SDA and samples it on the observed SCL rising edge. START,
    repeated START, and STOP are CPU pin sequences."""

    def __init__(self, half_cycles: int) -> None:
        self.h = half_cycles
        p = self.p = Px8()
        p.pin(I2C_SCL, 1)
        p.pin(I2C_SDA, 1)
        self._cpu_owns_bus()
        p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
                start=ev_shifter_start(0), stop=ev_shifter_done(0),
                hold_pin=I2C_SCL)
        self._configure_shifter(1)

    def _configure_shifter(self, ninth: int) -> None:
        self.p.shifter(0, msb=True, post=1, post_val=ninth, idle=1,
                       shift=ev_timer_fall(0), sample=ev_pin_rise(I2C_SCL))

    def _cpu_owns_bus(self) -> None:
        self.p.pin_cell(I2C_SCL, SRC_CPU, MODE_OPEN_DRAIN)
        self.p.pin_cell(I2C_SDA, SRC_CPU, MODE_OPEN_DRAIN)

    def _fabric_owns_bus(self) -> None:
        self.p.pin_cell(I2C_SCL, src_timer(0), MODE_OPEN_DRAIN)
        self.p.pin_cell(I2C_SDA, src_shifter(0), MODE_OPEN_DRAIN)

    def _release_scl(self) -> None:
        """Release SCL and wait until the bus really is high, so a
        stretching slave is honoured by START/STOP as well."""
        p = self.p
        p.clrev()
        p.pin(I2C_SCL, 1)
        p.wev(ev_pin_rise(I2C_SCL))
        p.dly(self.h)

    def start(self) -> None:
        p = self.p
        p.pin(I2C_SDA, 0)
        p.dly(self.h)
        p.pin(I2C_SCL, 0)
        p.dly(self.h)
        self._fabric_owns_bus()

    def restart(self) -> None:
        p = self.p
        p.pin(I2C_SCL, 0)
        p.pin(I2C_SDA, 1)
        self._cpu_owns_bus()
        p.dly(self.h)
        self._release_scl()
        self.start()

    def stop(self) -> None:
        p = self.p
        p.pin(I2C_SCL, 0)
        p.pin(I2C_SDA, 0)
        self._cpu_owns_bus()
        p.dly(self.h)
        self._release_scl()
        p.pin(I2C_SDA, 1)
        p.dly(self.h)

    def _byte(self, data: int, ninth: int) -> None:
        p = self.p
        self._configure_shifter(ninth)
        p.shifter_data(0, data)
        p.shifter_io(0, in_pin=I2C_SDA, start_now=True)
        p.wev(ev_shifter_done(0))

    def write(self, data: int) -> None:
        """Send a byte and push the slave's ACK bit (0 = ACK) to RX."""
        self._byte(data, 1)
        self.p.rd(rd_shifter_status(0))
        self.p.andc(1)
        self.p.push()

    def read(self, ack: bool) -> None:
        """Clock in a byte, answer ACK/NACK, and push the byte to RX."""
        self._byte(0xFF, 0 if ack else 1)
        self.p.rd(rd_shifter_data(0))
        self.p.push()

    def finish(self) -> list[int]:
        self.p.halt()
        return self.p.assemble()


def i2c_write_then_read(half_cycles: int, address: int, payload: list[int],
                        reads: int) -> list[int]:
    """START, write payload, repeated START, read `reads` bytes, STOP.
    RX order: address ACK, one ACK per payload byte, read ACK, read data."""
    bus = _I2c(half_cycles)
    bus.start()
    bus.write(address << 1)
    for byte in payload:
        bus.write(byte)
    bus.restart()
    bus.write((address << 1) | 1)
    for index in range(reads):
        bus.read(ack=index != reads - 1)
    bus.stop()
    return bus.finish()


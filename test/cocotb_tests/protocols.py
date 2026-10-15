"""Protocol programs for the spatial fabric. Each protocol is a fabric
configuration plus a short PX8 control loop; none of them is RTL.

Timing rule of thumb: pulse lines are registered (one cycle per hop), pin
outputs are registered, and inputs pass a two-flop synchronizer, so phase
values absorb a fixed, documented latency.
"""

from cocotb_tests.fabric import (
    CRC_OUT, MODE_OPEN_DRAIN, MODE_PUSH_PULL, ONE, RD_CRC_LO, RUN_ONES, ZERO,
    Px8, counter_ge, fire, flag, glue, pin_fall, pin_level,
    pin_rise, rd_shifter_data, rd_shifter_status, shifter_active, shifter_out,
    shifter_stop, shifter_word, timer_fall, timer_out, timer_rise, truth,
)

UART_TX_PIN, UART_RX_PIN = 0, 1
SPI_CS, SPI_SCK, SPI_MOSI, SPI_MISO = 3, 4, 5, 6
I2C_SCL, I2C_SDA = 1, 2
PS2_CLK, PS2_DATA = 4, 5
USB_DP, USB_DM = 0, 1
ETH_TD_P, ETH_TD_N = 0, 1


# --------------------------------------------------------------------- UART
def uart_full_duplex(bit_cycles: int) -> list[int]:
    """8N1 transmitter (shifter 0 + timer 0) and receiver (shifter 1 +
    timer 1) running concurrently and independently."""
    p = Px8()
    # TX: the bit timer runs while shifter 0 is active and its ticks advance
    # the frame. Frames restart gaplessly while the TX FIFO has bytes.
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 3, pulse=True,
            start=shifter_active(0), stop=shifter_stop(0))
    p.shifter(0, pre=1, pre_val=0, post=1, post_val=1, idle=1,
              shift=timer_rise(0))
    p.pin_cell(UART_TX_PIN, src=shifter_out(0), mode=MODE_PUSH_PULL)
    # RX: a falling edge starts both the sampling timer (first tick in the
    # middle of the start bit, net of synchronizer latency) and the shifter.
    p.timer(1, reload=bit_cycles - 1, phase=bit_cycles // 2 - 2, pulse=True,
            start=pin_fall(UART_RX_PIN), stop=shifter_stop(1))
    p.shifter(1, pre=1, post=1, shift=timer_rise(1), sample=timer_rise(1))
    p.shifter_io(1, start=pin_fall(UART_RX_PIN),
                 data_in=pin_level(UART_RX_PIN), push=True)
    p.shifter_io(0, pull=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


# ---------------------------------------------------------------------- SPI
def spi_master(mode: int, half_cycles: int) -> list[int]:
    """Full-duplex SPI master, MSB first, any CPOL/CPHA. Timer 0 is SCK and
    runs continuously across back-to-back bytes."""
    cpol, cpha = mode >> 1, mode & 1
    leading = timer_fall(0) if cpol else timer_rise(0)
    trailing = timer_rise(0) if cpol else timer_fall(0)
    p = Px8()
    p.pin(SPI_CS, 1)
    p.pin_cell(SPI_CS, cpu=True, mode=MODE_PUSH_PULL)
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=cpol,
            start=shifter_active(0), stop=shifter_stop(0))
    p.pin_cell(SPI_SCK, src=timer_out(0), mode=MODE_PUSH_PULL)
    if cpha == 0:
        p.shifter(0, msb=True, shift=trailing, sample=leading)
    else:
        p.shifter(0, msb=True, lead=True, end_on_sample=True,
                  shift=leading, sample=trailing)
    p.pin_cell(SPI_MOSI, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.arm()
    p.pin(SPI_CS, 0)
    p.dly(half_cycles)
    p.shifter_io(0, data_in=pin_level(SPI_MISO), pull=True, push=True)
    p.wev(shifter_stop(0))
    p.dly(half_cycles)
    p.pin(SPI_CS, 1)
    p.dly(4)
    p.halt()
    return p.assemble()


# ---------------------------------------------------------------------- I2C
class _I2c:
    """I2C master: timer 0 drives SCL (held while a slave stretches it),
    shifter 0 drives SDA and samples it on the observed SCL rising edge.
    START, repeated START, and STOP are controller pin sequences."""

    def __init__(self, half_cycles: int) -> None:
        self.h = half_cycles
        p = self.p = Px8()
        p.pin(I2C_SCL, 1)
        p.pin(I2C_SDA, 1)
        self._cpu_owns_bus()
        p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
                start=shifter_active(0), stop=shifter_stop(0),
                hold=pin_level(I2C_SCL), hold_invert=True)
        self._configure_shifter(1)
        p.shifter_io(0, start=fire(0), data_in=pin_level(I2C_SDA))
        p.arm()

    def _configure_shifter(self, ninth: int) -> None:
        self.p.shifter(0, msb=True, post=1, post_val=ninth, idle=1,
                       shift=timer_fall(0), sample=pin_rise(I2C_SCL))

    def _cpu_owns_bus(self) -> None:
        self.p.pin_cell(I2C_SCL, cpu=True, mode=MODE_OPEN_DRAIN)
        self.p.pin_cell(I2C_SDA, cpu=True, mode=MODE_OPEN_DRAIN)

    def _fabric_owns_bus(self) -> None:
        self.p.pin_cell(I2C_SCL, src=timer_out(0), mode=MODE_OPEN_DRAIN)
        self.p.pin_cell(I2C_SDA, src=shifter_out(0), mode=MODE_OPEN_DRAIN)

    def _release_scl(self) -> None:
        """Release SCL and wait until the bus really is high, so a
        stretching slave is honoured by START/STOP as well."""
        p = self.p
        p.clrev()
        p.pin(I2C_SCL, 1)
        p.wev(pin_rise(I2C_SCL))
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
        p.fire(0)
        p.wev(shifter_stop(0))

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


# --------------------------------------------------------------------- PS/2
def ps2_receive() -> list[int]:
    """PS/2 device-to-host: 11-bit frames (start, 8 data LSB first, odd
    parity, stop) clocked by the device. Shifter 1 restarts forever; each
    synchronized CLK falling edge samples and advances one bit."""
    p = Px8()
    p.shifter(1, pre=1, post=1, parity=2,
              shift=pin_fall(PS2_CLK), sample=pin_fall(PS2_CLK))
    p.shifter_io(1, start=ONE, data_in=pin_level(PS2_DATA), push=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


# ---------------------------------------------------------------- USB (LS)
USB_CRC16_POLY = 0x8005
USB_CRC16_RESIDUE = 0x800D


def usb_ls_transmit(bit_cycles: int) -> list[int]:
    """Low-speed USB packet transmitter. The TX FIFO supplies SYNC, PID and
    data bytes; the fabric adds NRZI, bit stuffing, CRC16 and EOP.

    At every bit tick E the line register latches the current bit X, the
    shifter advances (unless the bit is a stuffed 0), and the CRC absorbs
    the data bit or emits its next FCS bit once the shifter runs dry."""
    p = Px8()
    tick = timer_rise(0)
    stuff = counter_ge(0)
    # Rank 0 (cells 0-3) sees glue values registered; rank 1 (4-7) also
    # sees rank 0 live. Registered cells read the same either way.
    x, g, dp, dm, absorb, emit, se0, nrzi = (glue(i) for i in range(8))
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 1, pulse=True,
            start=shifter_active(0), stop=fire(1))
    p.shifter(0, shift=g)
    # X: the bit for this period (stuffed 0, data, or FCS).
    p.glue(0, truth(lambda st, act, so, co: (not st) and (so if act else co)),
           [stuff, shifter_active(0), shifter_out(0), CRC_OUT])
    # G: a tick that consumes a source bit.
    p.glue(1, truth(lambda e, st: e and not st, 2), [tick, stuff])
    p.glue(2, truth(lambda k, s0: k and not s0, 2), [nrzi, se0])
    p.glue(3, truth(lambda k, s0: (not k) and not s0, 2), [nrzi, se0])
    p.glue(4, truth(lambda gg, act, f0: gg and act and f0, 3),
           [g, shifter_active(0), flag(0)])
    p.glue(5, truth(lambda gg, act: gg and not act, 2), [g, shifter_active(0)])
    # SE0 latch: begins at a tick after the controller asks, but never
    # in place of a pending stuffed bit.
    p.glue(6, truth(lambda f1, st, q: f1 and (not st or q), 3),
           [flag(1), stuff, se0], registered=True, enable=tick)
    # NRZI line state (1 = K): a 0 toggles; SE0 parks it at J.
    p.glue(7, truth(lambda q, xb, s0: (not s0) and (q if xb else not q), 3),
           [nrzi, x, se0], registered=True, enable=tick)
    p.counter(0, match=6, step=tick, data=x, mode=RUN_ONES)
    p.counter(1, match=16, step=emit)
    p.crc(width=16, poly=USB_CRC16_POLY, check=USB_CRC16_RESIDUE,
          absorb=absorb, data=shifter_out(0), emit=emit)
    p.pin_cell(USB_DP, src=dp, mode=MODE_PUSH_PULL)
    p.pin_cell(USB_DM, src=dm, mode=MODE_PUSH_PULL)
    p.shifter_io(0, pull=True)
    p.arm()
    # CRC16 covers the data field only: start absorbing after SYNC and PID.
    p.wev(shifter_word(0))
    p.wev(shifter_word(0))
    p.flags(0b01)
    # EOP: two bit times of SE0, one of J, then release the bus.
    p.wev(counter_ge(1))
    p.flags(0b11)
    p.wev(se0)
    p.clrev()
    p.wev(tick)
    p.flags(0b00)
    p.clrev()
    p.wev(tick)
    p.wev(tick)
    p.fire(1)
    p.pin_cell(USB_DP, mode=0)
    p.pin_cell(USB_DM, mode=0)
    p.halt()
    return p.assemble()


def usb_ls_receive(bit_cycles: int) -> list[int]:
    """Low-speed USB packet receiver. Timer 0 recovers the bit clock by
    resynchronizing on every D+ transition; the fabric NRZI-decodes, drops
    stuffed bits, and pushes SYNC, PID, data and CRC bytes. At EOP the
    controller pushes 0xA5 if the CRC16 residue checks, else 0xEE."""
    p = Px8()
    tick = timer_rise(0)
    p.glue(0, truth(lambda dp: dp, 1), [pin_level(USB_DP)], registered=True, enable=tick)
    p.glue(1, truth(lambda dp, prev: dp == prev, 2), [pin_level(USB_DP), glue(0)])
    p.glue(2, truth(lambda e, st: e and not st, 2), [tick, counter_ge(0)])
    p.glue(3, truth(lambda dp, dm: not dp and not dm, 2),
           [pin_level(USB_DP), pin_level(USB_DM)])
    p.glue(4, truth(lambda r, f: r or f, 2), [pin_rise(USB_DP), pin_fall(USB_DP)])
    p.glue(5, truth(lambda g, f0: g and f0, 2), [glue(2), flag(0)])
    # Mid-bit sampling: sync (2) + pulse register (1) + resync (1) + tick.
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles // 2 - 3, pulse=True,
            start=glue(4), resync=glue(4), stop=glue(3))
    p.counter(0, match=6, step=tick, data=glue(1), mode=RUN_ONES)
    p.crc(width=16, poly=USB_CRC16_POLY, check=USB_CRC16_RESIDUE,
          absorb=glue(5), data=glue(1))
    p.shifter(1, shift=glue(2), sample=glue(2))
    p.shifter_io(1, start=ONE, data_in=glue(1), push=True)
    p.arm()
    p.wev(shifter_word(1))
    p.wev(shifter_word(1))
    p.flags(0b01)
    p.wev(glue(3))
    p.rd(RD_CRC_LO)
    p.xrc(USB_CRC16_RESIDUE)
    p.jz("good")
    p.ldc(0xEE)
    p.push()
    p.j("done")
    p.label("good")
    p.ldc(0xA5)
    p.push()
    p.label("done")
    p.halt()
    return p.assemble()


# ---------------------------------------------------------------- 10BASE-T
ETH_CRC32_POLY = 0x04C11DB7
ETH_CRC32_RESIDUE = 0xC704DD7B
ETH_FRAME_ADDR = 0x200        # frame bytes (preamble..payload) live in SRAM
NLP_TICK = 64000              # 1.6 ms at 40 MHz; ten ticks = 16 ms
NLP_TICKS = 10
TP_IDL_CYCLES = 12            # 300 ns high after the last bit (>= 250 ns)


def ethernet_10baset_link(frame_bytes: int) -> list[int]:
    """10BASE-T transmitter for a 40 MHz clock (2 cycles per half bit).

    Sequence: link pulse, 16 ms, link pulse, one frame streamed from SRAM
    (preamble, SFD and frame bytes; the fabric appends the CRC32 FCS and the
    TP_IDL end-of-frame high), 16 ms, link pulse. Link pulses and the frame
    share the TD+/TD- pair; the controller swaps the pin sources.

    Frame path: timer 0 runs continuously; the shifter starts and advances
    on its fall line, and glue cell 4 delays the timer output one cycle so
    the half-bit phase lines up exactly with the shifter output."""
    p = Px8()
    edge = timer_fall(0)
    act = shifter_active(0)
    in_crc = counter_ge(1)        # preamble + SFD (8 words) passed
    fcs_done = counter_ge(0)      # all 32 FCS bits emitted
    manchester, window, absorb, emit, half, idl_done, td_p, td_n = (
        glue(i) for i in range(8))
    # ---- frame datapath
    p.timer(0, reload=1, phase=1, idle=1, start=ONE)
    p.shifter(0, shift=edge)
    p.glue(0, truth(lambda a, so, co, h: (so if a else co) == h),
           [act, shifter_out(0), CRC_OUT, half])
    p.glue(1, truth(lambda a, c1, c0: a or (c1 and not c0), 3), [act, in_crc, fcs_done])
    p.glue(2, truth(lambda e, a, c1: e and a and c1, 3), [edge, act, in_crc])
    p.glue(3, truth(lambda e, a, c1: e and not a and c1, 3), [edge, act, in_crc])
    p.glue(4, truth(lambda t: t, 1), [timer_out(0)], registered=True)
    # TP_IDL: high from the end of the FCS until timer 3 has run once.
    p.glue(5, truth(lambda q, f3, f0: (q or f3) and not f0, 3),
           [idl_done, timer_fall(3), fire(0)], registered=True)
    p.glue(6, truth(lambda w, m, c0, d: m if w else (c0 and not d)),
           [window, manchester, fcs_done, idl_done])
    p.glue(7, truth(lambda w, m: w and not m, 2), [window, manchester])
    # Measured from the end of the last bit: high for reload + 2 cycles.
    p.timer(3, reload=TP_IDL_CYCLES - 2, phase=0, start=fcs_done, stop=idl_done)
    p.counter(0, match=32, step=emit, clear=fire(0))
    p.counter(1, match=8, step=shifter_word(0), clear=fire(0))
    p.crc(width=32, poly=ETH_CRC32_POLY, check=ETH_CRC32_RESIDUE,
          absorb=absorb, data=shifter_out(0), emit=emit, init=fire(0))
    p.shifter_io(0, start=edge, pull=True)
    # ---- link pulses: timer 1 ticks every 1.6 ms; timer 2 is a 100 ns
    # one-shot that stops itself on its own falling edge.
    p.timer(1, reload=NLP_TICK - 1, phase=NLP_TICK - 1, pulse=True, start=ONE)
    p.timer(2, reload=3, phase=0, idle=0, start=fire(1), stop=timer_fall(2))

    def link_pins() -> None:
        p.pin_cell(ETH_TD_P, src=timer_out(2), mode=MODE_PUSH_PULL)
        p.pin_cell(ETH_TD_N, src=ZERO, mode=MODE_PUSH_PULL)

    def wait_16ms() -> None:
        p.clrev()
        for _ in range(NLP_TICKS):
            p.wev(timer_rise(1))

    link_pins()
    p.arm()
    p.clrev()
    p.wev(timer_rise(1))          # align every pulse to a timer-1 tick
    p.fire(1)
    wait_16ms()
    p.fire(1)
    # ---- one frame
    p.dly(16)
    p.fire(0)
    p.pin_cell(ETH_TD_P, src=td_p, mode=MODE_PUSH_PULL)
    p.pin_cell(ETH_TD_N, src=td_n, mode=MODE_PUSH_PULL)
    p.stream_sram_to_tx(ETH_FRAME_ADDR, ETH_FRAME_ADDR + frame_bytes)
    p.wev(idl_done)
    link_pins()
    wait_16ms()
    p.fire(1)
    p.dly(16)
    p.halt()
    program = p.assemble()
    assert len(program) <= ETH_FRAME_ADDR, len(program)
    return program

"""Protocol programs for the spatial fabric. Each protocol is a fabric
configuration plus a short PX8 control loop; none of them is RTL.

Timing rule of thumb: pulse lines are registered (one cycle per hop), pin
outputs are registered, and inputs pass a two-flop synchronizer, so phase
values absorb a fixed, documented latency.
"""

from cocotb_tests.fabric import (
    CRC_OUT, MODE_OPEN_DRAIN, MODE_PUSH_PULL, ONE, RD_CRC_LO, RD_PINS, RUN_EQUAL, RUN_ONES, RUN_ZEROS,
    CRC_OK, Px8, counter_ge, counter_hit, fire, flag, logic, pin_fall, pin_level,
    pin_rise, rd_shifter_data, rd_shifter_status, rx_tile, shifter_active, shifter_out,
    shifter_stop, shifter_word, tile_event, timer_fall, timer_out, timer_rise, truth,
    tx_tile,
)

# Default pins follow the Tiny Tapeout recommended uio pinouts where one
# exists (https://tinytapeout.com/specs/pinouts/); any program may remap.
UART_TX_PIN, UART_RX_PIN = 1, 2                    # UART top row: TXD, RXD
SPI_CS, SPI_MOSI, SPI_MISO, SPI_SCK = 0, 1, 2, 3   # SPI top row
I2C_SCL, I2C_SDA = 2, 3                            # I2C top row
PS2_CLK, PS2_DATA = 4, 5                           # no standard: bottom row
USB_DP, USB_DM = 4, 5                              # no standard: bottom row
ETH_TD_P, ETH_TD_N = 6, 7                          # no standard: bottom row
ETH_RD = 4                                         # receiver comparator output


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
    p.shifter(1, pre=1, post=1, post_val=1, shift=timer_rise(1), sample=timer_rise(1))
    p.shifter_io(1, start=pin_fall(UART_RX_PIN),
                 data_in=pin_level(UART_RX_PIN), push=True)
    p.shifter_io(0, pull=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


def uart_dual_transmit(bit_cycles: tuple[int, int], pins: tuple[int, int]) -> list[int]:
    """Two independent 8N1 transmitters: shifter k pulls FIFO channel k and
    sends at its own bit rate on pins[k]."""
    p = Px8()
    for k in range(2):
        p.timer(k, reload=bit_cycles[k] - 1, phase=bit_cycles[k] - 3, pulse=True,
                start=shifter_active(k), stop=shifter_stop(k))
        p.shifter(k, pre=1, pre_val=0, post=1, post_val=1, idle=1,
                  shift=timer_rise(k))
        p.pin_cell(pins[k], src=shifter_out(k), mode=MODE_PUSH_PULL)
        p.shifter_io(k, pull=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


def framed_burst_loop(bit_cycles: int, words: int) -> list[int]:
    """Burst mode on both shifters: a frame of one start bit, `words` bytes
    back to back, even parity over the last byte, and one stop bit. Shifter
    0 sends bytes pulled from channel 0 on the UART TX pin; shifter 1
    receives the same framing on the RX pin and pushes every byte to
    channel 1. Counter k counts shifter k's words and ends its burst."""
    p = Px8()
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 3, pulse=True,
            start=shifter_active(0), stop=shifter_stop(0))
    p.timer(1, reload=bit_cycles - 1, phase=bit_cycles // 2 - 2, pulse=True,
            start=pin_fall(UART_RX_PIN), stop=shifter_stop(1))
    for k in range(2):
        p.counter(k, match=words - 1, step=shifter_word(k))
        p.shifter_burst(k, end=counter_ge(k))
    p.shifter(0, pre=1, pre_val=0, post=1, post_val=1, parity=1, idle=1,
              shift=timer_rise(0))
    p.shifter(1, pre=1, post=1, post_val=1, parity=1, shift=timer_rise(1),
              sample=timer_rise(1))
    p.pin_cell(UART_TX_PIN, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.shifter_io(0, pull=True)
    p.shifter_io(1, start=pin_fall(UART_RX_PIN),
                 data_in=pin_level(UART_RX_PIN), push=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


# ------------------------------------------------- packets over UART (bytes)
def _uart_tx(p: Px8, k: int, bit_cycles: int, pin: int, **frame) -> None:
    p.timer(k, reload=bit_cycles - 1, phase=bit_cycles - 3, pulse=True,
            start=shifter_active(k), stop=shifter_stop(k))
    p.shifter(k, pre=1, pre_val=0, post=1, post_val=1, idle=1,
              shift=timer_rise(k), **frame)
    p.pin_cell(pin, src=shifter_out(k), mode=MODE_PUSH_PULL)


def _uart_rx(p: Px8, k: int, timer: int, bit_cycles: int, pin: int, **frame) -> None:
    p.timer(timer, reload=bit_cycles - 1, phase=bit_cycles // 2 - 2, pulse=True,
            start=pin_fall(pin), stop=shifter_stop(k))
    p.shifter(k, pre=1, post=1, post_val=1, shift=timer_rise(timer),
              sample=timer_rise(timer), **frame)
    p.shifter_io(k, start=pin_fall(pin), data_in=pin_level(pin), push=True)


def uart_packet_link(bit_cycles: int, codes: tuple, *, prepend: bool,
                     xor: bool = False,
                     program_packets: tuple = ()) -> list[int]:
    """Byte-stuffed packets with a checksum over 8N1 UART, sent on the TX
    pin and received back from the same pin.

    TX (channel 0): CHECK appends a checksum, ESCAPE stuffs the delimiter
    and escape bytes and frames the packet with the delimiter. RX (shifter
    1, channel 1): UNESCAPE delimits and unstuffs, CHECK verifies; the host
    sees each packet's last byte (the checksum) tagged eop, and err if the
    checksum failed. `program_packets` are (bytes, inject_error) sent by
    the controller after the host's packets."""
    p = Px8()
    _uart_tx(p, 0, bit_cycles, UART_TX_PIN)
    p.shifter_io(0, pull=True)
    p.tile_check(tx_tile(0, 0), verify=False, xor=xor)
    p.tile_escape(tx_tile(0, 1), codes, append=True, prepend=prepend)
    _uart_rx(p, 1, 1, bit_cycles, UART_TX_PIN)
    p.tile_unescape(rx_tile(1, 0), codes)
    p.tile_check(rx_tile(1, 1), verify=True, xor=xor)
    p.arm()
    for data, inject in program_packets:
        for i, byte in enumerate(data):
            last = i == len(data) - 1
            p.ldc(byte)
            p.txp(0, eop=last, err=last and inject)
    p.idle_forever()
    return p.assemble()


MODBUS_DONE_PIN = 5


def idle_framed_receiver(bit_cycles: int, gap_bits: int, address: int) -> list[int]:
    """Modbus-RTU-style receiver: packets are delimited by line idle time,
    and only packets whose first byte is `address` reach the host.

    The bit layer finds the gaps: logic cell 0 marks every RX pin edge and
    restarts timer 2, which fires only after `gap_bits` without an edge.
    The byte layer packetizes on that event (TAG) and filters on the
    address (MATCH). The controller waits for the first match and then
    raises a pin through a flag line."""
    p = Px8()
    _uart_rx(p, 0, 1, bit_cycles, UART_RX_PIN)
    edge = logic(0)
    p.logic(0, truth(lambda r, f: r or f, 2),
           [pin_rise(UART_RX_PIN), pin_fall(UART_RX_PIN)])
    gap = gap_bits * bit_cycles
    p.timer(2, reload=gap - 1, phase=gap - 1, pulse=True,
            start=pin_fall(UART_RX_PIN), resync=edge)
    p.tile_tag(rx_tile(0, 0), end=timer_rise(2))
    p.tile_match(rx_tile(0, 1), value=address)
    p.pin_cell(MODBUS_DONE_PIN, src=flag(0), mode=MODE_PUSH_PULL)
    p.arm()
    p.wev(tile_event(rx_tile(0, 1)))
    p.flags(0b01)
    p.idle_forever()
    return p.assemble()


def uart_packet_bursts(bit_cycles: int) -> list[int]:
    """Each host packet is one burst frame: a start bit, the packet's bytes
    back to back, even parity over the last byte, a stop bit. The burst
    ends on the byte tagged eop; nothing counts words."""
    p = Px8()
    _uart_tx(p, 0, bit_cycles, UART_TX_PIN, parity=1)
    p.shifter_burst(0, end=flag(0), on_eop=True)    # flag 0 stays low
    p.shifter_io(0, pull=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


def uart_receiver(bit_cycles: int, *, parity: int) -> list[int]:
    """8-bit UART receiver on the RX pin (shifter 0, channel 0); bytes whose
    parity or stop bit is wrong reach the host tagged err."""
    p = Px8()
    _uart_rx(p, 0, 1, bit_cycles, UART_RX_PIN, parity=parity)
    p.arm()
    p.idle_forever()
    return p.assemble()


# ---------------------------------------------------------------------- SPI
def spi_master(mode: int, half_cycles: int) -> list[int]:
    """Full-duplex SPI master, MSB first, any CPOL/CPHA, every edge timed by
    the fabric. Timer 0 is SCK and runs continuously across back-to-back
    bytes. CS is logic cell 0: FIRE 0 pulls it low, and timer 2, a one-shot
    started when the shifter stops, raises it a half period after the last
    edge. The shifter runs while CS is low, so SCK's first edge comes a
    half period after CS falls (timer 0 starts with the shifter)."""
    cpol, cpha = mode >> 1, mode & 1
    leading = timer_fall(0) if cpol else timer_rise(0)
    trailing = timer_rise(0) if cpol else timer_fall(0)
    cs_low = logic(0)
    p = Px8()
    p.logic(0, truth(lambda go, done, low: go or (low and not done), 3),
           [fire(0), timer_rise(2), cs_low])
    p.logic(1, truth(lambda low: not low, 1), [cs_low], start=1)
    p.pin_cell(SPI_CS, src=logic(1), mode=MODE_PUSH_PULL)
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=cpol,
            start=shifter_active(0), stop=shifter_stop(0))
    p.timer(2, reload=half_cycles - 1, phase=half_cycles - 1, pulse=True,
            start=shifter_stop(0), stop=timer_rise(2))
    # Timer 1: CS stays high a few cycles before the program halts.
    p.timer(1, reload=3, phase=3, pulse=True, start=timer_rise(2), stop=timer_rise(1))
    p.pin_cell(SPI_SCK, src=timer_out(0), mode=MODE_PUSH_PULL)
    if cpha == 0:
        p.shifter(0, msb=True, shift=trailing, sample=leading)
    else:
        p.shifter(0, msb=True, lead=True, end_on_sample=True,
                  shift=leading, sample=trailing)
    p.pin_cell(SPI_MOSI, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.shifter_io(0, start=cs_low, data_in=pin_level(SPI_MISO), pull=True, push=True)
    p.arm()
    p.fire(0)
    p.wev(timer_rise(2))
    p.wev(timer_rise(1))
    p.halt()
    return p.assemble()


# ---------------------------------------------------------------------- I2C
class _I2c:
    """I2C master, every edge timed by the fabric. Bytes: timer 0 drives SCL
    (held while a slave stretches it), shifter 0 drives SDA and samples it
    on the observed SCL rising edge. Conditions (START, repeated START,
    STOP) are short two-pin patterns: shifter 0 plays the SDA pattern and
    shifter 1 the SCL pattern, both stepped by timer 1 every half period;
    timer 1 freezes while SCL is released but still low, so a stretching
    slave is honoured here too. The controller only chooses which
    condition or byte comes next; it never drives a pin.

    No pin's rest level is ever reconfigured (a configuration write would
    move the pin at once): SDA rests released, which is legal after every
    condition because SCL is low then, and SCL rests at the last bit of
    the last condition, captured by a registered logic cell.

    Logic cells: 0 SCL (the condition pattern while one plays, else timer 0 or
    the rest level), 1 shifter 0 start (either FIRE), 2 shifter 0 step (a
    byte tick or a condition tick), 3 SCL rest, inverted so it powers up
    released, 4 byte phase (starts timer 0), 5 condition stretch."""

    def __init__(self, half_cycles: int) -> None:
        self.h = half_cycles
        p = self.p = Px8()
        byte_phase = self.byte_phase = logic(4)
        self.step = logic(2)
        # Timer 0 idles low and runs only in a byte, where the rest is low.
        p.logic(0, truth(lambda a1, c, t, rest_n: c if a1 else (t or not rest_n)),
               [shifter_active(1), shifter_out(1), timer_out(0), logic(3)], start=1)
        p.logic(1, truth(lambda f0, f1: f0 or f1, 2), [fire(0), fire(1)])
        p.logic(2, truth(lambda b, c: b or c, 2), [timer_fall(0), timer_rise(1)])
        p.logic(3, truth(lambda a1, c, rest_n: (not c) if a1 else rest_n, 3),
               [shifter_active(1), shifter_out(1), logic(3)])
        p.logic(5, truth(lambda c, scl: c and not scl, 2),
               [shifter_out(1), pin_level(I2C_SCL)])
        p.logic(4, truth(lambda a0, a1: a0 and not a1, 2),
               [shifter_active(0), shifter_active(1)])
        p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
                start=byte_phase, stop=shifter_stop(0),
                hold=pin_level(I2C_SCL), hold_invert=True)
        p.timer(1, reload=half_cycles - 1, phase=half_cycles - 1, idle=1, pulse=True,
                start=shifter_active(1), stop=shifter_stop(1), hold=logic(5))
        p.shifter(0, idle=1, shift=self.step)
        p.shifter(1, shift=timer_rise(1))
        p.shifter_io(0, start=logic(1), data_in=pin_level(I2C_SDA))
        p.shifter_io(1, start=fire(1))
        p.pin_cell(I2C_SCL, src=logic(0), mode=MODE_OPEN_DRAIN)
        p.pin_cell(I2C_SDA, src=shifter_out(0), mode=MODE_OPEN_DRAIN)
        p.arm()

    def _configure_shifter(self, ninth: int) -> None:
        self.p.shifter(0, msb=True, post=1, post_val=ninth, idle=1,
                       shift=self.step, sample=pin_rise(I2C_SCL))

    def _condition(self, sda: list[int], scl: list[int]) -> None:
        """Play one half period per slot on both pins; SCL then rests at its
        last level, SDA is released. Patterns never change SDA and SCL
        together."""
        p = self.p
        bits = lambda levels: sum(v << i for i, v in enumerate(levels))
        p.shifter(0, length=len(sda), idle=1, shift=self.step)
        p.shifter_data(0, bits(sda))
        p.shifter(1, length=len(scl), shift=timer_rise(1))
        p.shifter_data(1, bits(scl))
        p.fire(1)
        p.wev(shifter_stop(1))
        p.wev(shifter_stop(0))      # both end together; leave no stale event

    def start(self) -> None:
        # From an idle bus: SDA falls while SCL is high, then SCL falls.
        self._condition(sda=[0, 0], scl=[1, 0])

    def restart(self) -> None:
        # From SCL low: release SDA, release SCL (stretching honoured),
        # SDA falls while SCL is high, SCL falls.
        self._condition(sda=[1, 1, 0, 0], scl=[0, 1, 1, 0])

    def stop(self) -> None:
        # From SCL low: SDA low, release SCL, SDA rises while SCL is high.
        self._condition(sda=[0, 0, 1], scl=[0, 1, 1])

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
    p.shifter(1, pre=1, post=1, post_val=1, parity=2,
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
    # Logic cells see each other registered. X is registered every cycle:
    # nothing it depends on changes in the cycle before a tick, so the NRZI
    # cell and the stuffing counter read the same bit a cycle later.
    x, g, dp, dm, absorb, emit, se0, nrzi = (logic(i) for i in range(8))
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 1, pulse=True,
            start=shifter_active(0), stop=fire(1))
    p.shifter(0, shift=g)
    # X: the bit for this period (stuffed 0, data, or FCS).
    p.logic(0, truth(lambda st, act, so, co: (not st) and (so if act else co)),
           [stuff, shifter_active(0), shifter_out(0), CRC_OUT])
    # G: a tick that consumes a source bit.
    p.logic(1, truth(lambda e, st: e and not st, 2), [tick, stuff])
    p.logic(2, truth(lambda k, s0: k and not s0, 2), [nrzi, se0])
    p.logic(3, truth(lambda k, s0: (not k) and not s0, 2), [nrzi, se0])
    # Absorb and emit repeat G's terms (tick and not stuffed) inline.
    p.logic(4, truth(lambda e, st, act, f0: e and not st and act and f0),
           [tick, stuff, shifter_active(0), flag(0)])
    p.logic(5, truth(lambda e, st, act: e and not st and not act, 3),
           [tick, stuff, shifter_active(0)])
    # SE0 latch: begins at a tick after the controller asks, but never
    # in place of a pending stuffed bit.
    p.logic(6, truth(lambda f1, st, q: f1 and (not st or q), 3),
           [flag(1), stuff, se0], enable=tick)
    # NRZI line state (1 = K): a 0 toggles; SE0 parks it at J.
    p.logic(7, truth(lambda q, xb, s0: (not s0) and (q if xb else not q), 3),
           [nrzi, x, se0], enable=tick)
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
    p.logic(0, truth(lambda dp: dp, 1), [pin_level(USB_DP)], enable=tick)
    p.logic(1, truth(lambda dp, prev: dp == prev, 2), [pin_level(USB_DP), logic(0)])
    p.logic(2, truth(lambda e, st: e and not st, 2), [tick, counter_ge(0)])
    p.logic(3, truth(lambda dp, dm: not dp and not dm, 2),
           [pin_level(USB_DP), pin_level(USB_DM)])
    p.logic(4, truth(lambda r, f: r or f, 2), [pin_rise(USB_DP), pin_fall(USB_DP)])
    p.logic(5, truth(lambda e, st, f0: e and not st and f0, 3),
           [tick, counter_ge(0), flag(0)])
    # Mid-bit sampling: sync (2) + pulse register (1) + resync (1) + tick.
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles // 2 - 3, pulse=True,
            start=logic(4), resync=logic(4), stop=logic(3))
    p.counter(0, match=6, step=tick, data=logic(1), mode=RUN_ONES)
    p.crc(width=16, poly=USB_CRC16_POLY, check=USB_CRC16_RESIDUE,
          absorb=logic(5), data=logic(1))
    p.shifter(1, shift=logic(2), sample=logic(2))
    p.shifter_io(1, start=ONE, data_in=logic(1), push=True)
    p.arm()
    p.wev(shifter_word(1))
    p.wev(shifter_word(1))
    p.flags(0b01)
    p.wev(logic(3))
    p.rd(RD_CRC_LO)
    p.xrc(USB_CRC16_RESIDUE)
    p.jz("good")
    p.ldc(0xEE)
    p.push(channel=1)            # after the packet bytes, on shifter 1's channel
    p.j("done")
    p.label("good")
    p.ldc(0xA5)
    p.push(channel=1)
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


def ethernet_10baset_link(frame_bytes: int, nlp_tick: int = NLP_TICK) -> list[int]:
    """10BASE-T transmitter for a 40 MHz clock (2 cycles per half bit).

    Sequence: link pulse, 16 ms, link pulse, one frame streamed from SRAM
    (preamble, SFD and frame bytes; the fabric appends the CRC32 FCS and the
    TP_IDL end-of-frame high), 16 ms, link pulse. Link pulses and the frame
    share the TD+/TD- pair; the controller swaps the pin sources. The 16 ms
    after the frame is counted in link-pulse ticks from the frame's end, so
    a frame must be shorter than one tick (any 802.3 frame, at most 1.2 ms,
    is shorter than the 1.6 ms tick).

    Frame path: timer 0 runs continuously; the shifter starts and advances
    on its fall line, and logic cell 4 delays the timer output one cycle so
    the half-bit phase lines up exactly with the shifter output."""
    p = Px8()
    p.write_contexts(3)            # shared by both pin contexts
    edge = timer_fall(0)
    act = shifter_active(0)
    in_crc = counter_ge(1)        # preamble + SFD (8 words) passed
    fcs_done = counter_ge(0)      # all 32 FCS bits emitted
    manchester, window, absorbing, emitting, half, idl_done, td_p, td_n = (
        logic(i) for i in range(8))
    # ---- frame datapath
    p.timer(0, reload=1, phase=1, idle=1, start=ONE)
    p.shifter(0, shift=edge)
    p.logic(0, truth(lambda a, so, co, h: (so if a else co) == h),
           [act, shifter_out(0), CRC_OUT, half])
    p.logic(1, truth(lambda a, c1, c0: a or (c1 and not c0), 3), [act, in_crc, fcs_done])
    # CRC phases as levels: the CRC and the FCS bit counter step on the raw
    # edge, gated by them, in the same cycle the shifter shifts.
    p.logic(2, truth(lambda a, c1: a and c1, 2), [act, in_crc])
    p.logic(3, truth(lambda a, c1: (not a) and c1, 2), [act, in_crc])
    p.logic(4, truth(lambda t: t, 1), [timer_out(0)])
    # TP_IDL: high from the end of the FCS until timer 3 has run once.
    p.logic(5, truth(lambda q, f3, f0: (q or f3) and not f0, 3),
           [idl_done, timer_fall(3), fire(0)])
    p.logic(6, truth(lambda w, m, c0, d: m if w else (c0 and not d)),
           [window, manchester, fcs_done, idl_done])
    p.logic(7, truth(lambda w, m: w and not m, 2), [window, manchester])
    # Measured from the end of the last bit, which reaches the pins a cycle
    # after fcs_done (manchester and window are registered): reload + 1.
    p.timer(3, reload=TP_IDL_CYCLES - 1, phase=0, start=fcs_done, stop=idl_done)
    p.counter(0, match=32, step=edge, data=emitting, mode=RUN_ONES, clear=fire(0))
    p.counter(1, match=8, step=shifter_word(0), clear=fire(0))
    p.crc(width=32, poly=ETH_CRC32_POLY, check=ETH_CRC32_RESIDUE,
          absorb=edge, absorb_gate=absorbing, data=shifter_out(0),
          emit=edge, emit_gate=emitting, init=fire(0))
    p.shifter_io(0, start=edge, pull=True)
    # ---- link pulses: timer 1 ticks every 1.6 ms; timer 2 is a 100 ns
    # one-shot that stops itself on its own falling edge.
    p.timer(1, reload=nlp_tick - 1, phase=nlp_tick - 1, pulse=True, start=ONE)
    p.timer(2, reload=3, phase=0, idle=0, start=fire(1), stop=timer_fall(2))

    # ---- pins: context 0 carries link pulses (TD- held low), context 1 the
    # frame; controller flag 1 selects the context, so swapping the pair's
    # sources is one flag write, not four pin-cell rewrites.
    p.write_contexts(1)
    p.pin_cell(ETH_TD_P, src=timer_out(2), mode=MODE_PUSH_PULL)
    p.pin_cell(ETH_TD_N, const=0, mode=MODE_PUSH_PULL)
    p.write_contexts(2)
    p.pin_cell(ETH_TD_P, src=td_p, mode=MODE_PUSH_PULL)
    p.pin_cell(ETH_TD_N, src=td_n, mode=MODE_PUSH_PULL)
    p.write_contexts(1)
    p.context_select(flag(1))

    def wait_16ms() -> None:
        p.clrev()
        for _ in range(NLP_TICKS):
            p.wev(timer_rise(1))

    def link_pulse() -> None:
        p.clrev()
        p.fire(1)
        p.wev(timer_fall(2))       # the 100 ns pulse has ended

    p.arm()
    p.clrev()
    p.wev(timer_rise(1))          # align every pulse to a timer-1 tick
    link_pulse()
    wait_16ms()
    link_pulse()
    # ---- one frame
    p.flags(0b10)
    p.fire(0)
    p.stream_sram_to_tx(ETH_FRAME_ADDR, ETH_FRAME_ADDR + frame_bytes)
    p.wev(idl_done)
    p.flags(0b00)
    wait_16ms()
    link_pulse()
    p.halt()
    program = p.assemble()
    assert len(program) <= ETH_FRAME_ADDR, len(program)
    return program


def ethernet_10baset_receive() -> list[int]:
    """10BASE-T receiver for a 40 MHz clock (4 cycles per bit), from the
    digital output of an external line receiver on ETH_RD. Bytes from the
    first one after the SFD through the FCS reach the host on channel 1,
    the last tagged eop, and err if the FCS residue failed.

    Clock recovery: every Manchester bit has a mid-bit edge, the value is
    the level after it. An edge is accepted only once a window has opened,
    3 cycles after the last accepted edge, so bit-boundary edges (2 cycles
    after) are ignored; the alternating preamble has no boundary edges, so
    the window locks onto mid-bit edges by itself. A run-of-ones counter
    finds the SFD's final 11 and marks the frame; timer 1 fires once about
    2 bits pass without an accepted edge (carrier loss), which aborts the
    shifter's partial word, re-initializes the CRC, clears the frame mark
    and ends the packet in the byte layer."""
    p = Px8()
    rd = pin_level(ETH_RD)
    prev, win, acc, absorb, in_frame, bad = (logic(i) for i in range(6))
    lost = timer_rise(1)
    p.logic(0, truth(lambda d: d, 1), [rd])
    p.logic(1, truth(lambda t, d, pv, w: (not (d != pv and w)) and (t or w)),
           [timer_rise(0), rd, prev, win])
    p.logic(2, truth(lambda d, pv, w: d != pv and w, 3), [rd, prev, win])
    p.logic(3, truth(lambda d, pv, w, f: d != pv and w and f), [rd, prev, win, in_frame])
    p.logic(4, truth(lambda gone, hit, f: (not gone) and (hit or f), 3),
           [lost, counter_hit(0), in_frame])
    # Bad FCS: the CRC residue is wrong once the line has been quiet for 6
    # cycles, so the flag is up before the carrier-loss pulse ends the packet.
    p.logic(5, truth(lambda quiet, ok: quiet and not ok, 2), [counter_ge(1), CRC_OK])
    p.counter(1, match=6, step=ONE, data=acc, mode=RUN_ZEROS)
    # Window: opens 3 cycles after an accepted edge (resync + pulse + logic cell).
    p.timer(0, reload=15, phase=0, pulse=True, start=ONE, resync=acc)
    # Carrier: fires 8 cycles after the last accepted edge.
    p.timer(1, reload=7, phase=6, pulse=True, start=ONE, resync=acc)
    p.counter(0, match=2, step=acc, data=rd, mode=RUN_ONES, clear=lost)
    p.crc(width=32, poly=ETH_CRC32_POLY, check=ETH_CRC32_RESIDUE,
          absorb=absorb, data=rd, init=lost)
    p.shifter(1, shift=acc, sample=acc)
    p.shifter_io(1, start=in_frame, data_in=rd, push=True)
    p.shifter_abort(1, lost)
    p.tile_tag(rx_tile(1, 0), end=lost, err=bad)
    p.arm()
    p.idle_forever()
    return p.assemble()



# ------------------------------------------------------------------ WS2812
WS2812_PIN = 0


def ws2812_transmit(bit_cycles: int, t0h: int, t1h: int) -> list[int]:
    """WS2812 / NeoPixel transmitter: GRB bytes from the TX FIFO, MSB first,
    one gapless burst; every bit starts high, falling after t0h cycles for
    a 0 and t1h cycles for a 1. The line then rests low (the latch reset).

    Timer 0 ticks once per bit while shifter 0 runs and starts two one-shot
    timers together: timer 1 high for t0h cycles, timer 2 for t1h. The
    shifter presents each bit on a tick (lead) and ends its burst at the
    last bit's timer-1 rise, so timer 0 stops before a tick could start a
    spurious extra bit. Logic cell 0 holds the bit from that rise (the
    shifter output leaves it once the burst ends); logic cell 1 drives the
    pin: timer 1, or timer 2 while the bit is 1."""
    assert 1 <= t0h < t1h < bit_cycles - 3
    p = Px8()
    tick = timer_rise(0)
    p.timer(0, reload=bit_cycles - 1, phase=0, pulse=True,
            start=shifter_active(0), stop=shifter_stop(0))
    p.timer(1, reload=t0h - 1, phase=0, start=tick, stop=timer_fall(1))
    p.timer(2, reload=t1h - 1, phase=0, start=tick, stop=timer_fall(2))
    p.shifter(0, msb=True, lead=True, end_on_sample=True,
              shift=tick, sample=timer_rise(1))
    p.shifter_burst(0, end=flag(0))
    p.shifter_io(0, pull=True)
    p.logic(0, truth(lambda b: b, 1), [shifter_out(0)], enable=timer_rise(1))
    p.logic(1, truth(lambda short, long, b: short or (long and b), 3),
            [timer_out(1), timer_out(2), logic(0)])
    p.pin_cell(WS2812_PIN, src=logic(1), mode=MODE_PUSH_PULL)
    p.arm()
    p.idle_forever()
    return p.assemble()


# -------------------------------------------------------------------- JTAG
JTAG_TCK, JTAG_TMS, JTAG_TDI, JTAG_TDO = 0, 1, 2, 3


def jtag_master(half_cycles: int, chunks: list[tuple[int, int, int]]) -> list[int]:
    """JTAG master: each chunk (length, tms bits, tdi bits) is clocked out
    LSB first, TMS and TDI changing on TCK's falling edge and TDO sampled
    on its rising edge (IEEE 1149.1), and the TDO bits of every chunk are
    pushed to the host as one byte. Shifter 0 carries TDI/TDO, shifter 1
    TMS, both stepped by the same TCK timer edges, so the two never skew;
    TCK (timer 0) runs only while shifter 0 does and rests low."""
    p = Px8()
    rise, fall = timer_rise(0), timer_fall(0)
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
            start=shifter_active(0), stop=shifter_stop(0))
    p.pin_cell(JTAG_TCK, src=timer_out(0), mode=MODE_PUSH_PULL)
    p.pin_cell(JTAG_TDI, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.pin_cell(JTAG_TMS, src=shifter_out(1), mode=MODE_PUSH_PULL)
    p.shifter_io(0, start=fire(0), data_in=pin_level(JTAG_TDO))
    p.shifter_io(1, start=fire(0))
    p.arm()
    for length, tms, tdi in chunks:
        assert 1 <= length <= 8
        p.shifter(0, length=length, shift=fall, sample=rise)
        p.shifter(1, length=length, shift=fall)
        p.shifter_data(0, tdi)
        p.shifter_data(1, tms)
        p.fire(0)
        p.wev(shifter_stop(0))
        p.rd(rd_shifter_data(0))
        p.push()
    p.halt()
    return p.assemble()


# ------------------------------------------------------------------ 1-Wire
ONEWIRE_DQ = 4
US = 40                          # cycles per microsecond at 40 MHz


def onewire_master(ops: list[tuple[str, int]]) -> list[int]:
    """1-Wire master (standard speed, open drain on ONEWIRE_DQ). `ops` is a
    list of ("reset", 0), ("write", byte) or ("read", 0); a reset pushes the
    presence bit (0 = a device answered) and a read pushes the byte.

    Timer 0 runs freely and ticks once per slot; on a tick while shifter 0
    is busy, logic cell 2 starts a slot: timer 1 holds the line low 6 us,
    timer 2 60 us, and timer 3 samples it 13 us in. The bit being sent
    decides whether the long low applies (a 0), so a read slot is a
    write-1 slot with the sample kept. LSB first. The shifter ends its
    frame at the last bit's sample, so the next tick starts nothing and
    slots, recovery times and the next operation all stay on the slot grid.

    A reset is the same pattern with other timing: one 1 bit whose low
    lasts 480 us, sampled for presence 70 us after the release, on a 960 us
    grid (so 480 us of high follow before the next slot). Context 0 holds
    the slot timing, context 1 the reset timing; controller flag 1 picks
    one, so a reset is one flag write, not a reconfiguration."""
    p = Px8()
    tick = timer_rise(0)
    slot_start = logic(2)
    sample = timer_rise(3)

    def pattern(slot, short, long, sample_at):
        p.timer(0, reload=slot - 1, phase=0, pulse=True, start=ONE)
        p.timer(1, reload=short - 1, phase=0, start=slot_start, stop=timer_fall(1))
        p.timer(2, reload=long - 1, phase=0, start=slot_start, stop=timer_fall(2))
        # Pulse mode: one rise sample_at cycles after the slot starts.
        p.timer(3, reload=3, phase=sample_at - 2, pulse=True,
                start=slot_start, stop=sample)

    p.write_contexts(1)
    pattern(slot=70 * US, short=6 * US, long=60 * US, sample_at=13 * US)
    p.write_contexts(2)
    pattern(slot=960 * US, short=480 * US, long=480 * US, sample_at=550 * US)
    p.write_contexts(3)
    p.shifter_io(0, start=fire(0), data_in=pin_level(ONEWIRE_DQ))
    p.logic(2, truth(lambda t, a: t and a, 2), [tick, shifter_active(0)])
    # Bit latch (the shifter output leaves the bit when the frame ends at
    # the last sample), then the open-drain driver: low while timer 1 runs,
    # or while timer 2 runs and the bit is 0.
    p.logic(0, truth(lambda b: b, 1), [shifter_out(0)], enable=timer_rise(1))
    p.logic(1, truth(lambda short, long, b: not (short or (long and not b)), 3),
            [timer_out(1), timer_out(2), logic(0)], start=1)
    p.pin_cell(ONEWIRE_DQ, src=logic(1), mode=MODE_OPEN_DRAIN)
    p.context_select(flag(1))
    p.arm()
    for op, value in ops:
        reset = op == "reset"
        p.flags(0b10 if reset else 0b00)
        p.shifter(0, length=1 if reset else 8, lead=True, end_on_sample=True,
                  shift=slot_start, sample=sample)
        p.shifter_data(0, 1 if reset else value if op == "write" else 0xFF)
        p.fire(0)
        p.wev(shifter_stop(0))
        if op != "write":
            p.rd(rd_shifter_data(0))
            p.push()
    p.halt()
    return p.assemble()


# --------------------------------------------------------------------- CAN
CAN_TX, CAN_RX = 6, 7
CAN_CRC15_POLY = 0x4599


def can_transmit(bit_cycles: int) -> list[int]:
    """CAN 2.0A data frame transmitter on CAN_TX (0 = dominant). The TX
    FIFO supplies five recessive bits, then SOF, identifier, RTR, IDE, r0,
    DLC and data, MSB first (so a frame is whole bytes); the fabric adds
    bit stuffing, the CRC-15 sequence and the recessive tail.

    The prefix is indistinguishable from an idle bus: the frame starts at
    the first dominant data bit, which sets logic cell 6 (in frame). At every
    tick the line register (cell 2) launches X, the bit for this period: a
    stuff bit (the complement of the last one) after five equal bits, else
    the data or, once the shifter runs dry, the CRC (the tile shifts out
    its complement, cell 1 undoes that), and recessive after the 15th CRC
    bit and any stuff bit that follows it. Counter 0 counts equal bits
    (the stuff bit starts the next run); counter 1 counts CRC bits."""
    p = Px8()
    tick = timer_rise(0)
    stuff, crc_done = counter_ge(0), counter_ge(1)
    x, d, line, consume, absorb, emit, in_frame, stuff_step = (logic(i) for i in range(8))
    act = shifter_active(0)
    p.timer(0, reload=bit_cycles - 1, phase=bit_cycles - 1, pulse=True,
            start=act, stop=fire(1))
    p.shifter(0, msb=True, idle=1, shift=consume)
    p.shifter_burst(0, end=flag(0))
    p.shifter_io(0, pull=True)
    p.logic(0, truth(lambda st, last, done, dd: (not last) if st else (1 if done else dd)),
            [stuff, line, crc_done, d], start=1)
    p.logic(1, truth(lambda a, so, co: so if a else not co, 3), [act, shifter_out(0), CRC_OUT],
            start=1)
    p.logic(2, truth(lambda b: b, 1), [x], enable=tick, start=1)
    p.logic(3, truth(lambda e, st: e and not st, 2), [tick, stuff])
    p.logic(4, truth(lambda e, st, a, f: e and not st and a and f), [tick, stuff, act, in_frame])
    p.logic(5, truth(lambda e, st, a, f: e and not st and not a and f),
            [tick, stuff, act, in_frame])
    # In frame from the first dominant data bit (SOF), a tick before it is
    # launched; it is 0, so absorbing it into the zero CRC changes nothing.
    p.logic(6, truth(lambda q, a, so: q or (a and not so), 3), [in_frame, act, shifter_out(0)])
    # Count launched bits for stuffing while in frame, and once more after
    # the CRC if a stuff bit is due there; then freeze (no stuffing in the
    # recessive tail).
    p.logic(7, truth(lambda e, f, done, st: e and f and (not done or st)),
            [tick, in_frame, crc_done, stuff])
    p.counter(0, match=5, step=stuff_step, data=x, mode=RUN_EQUAL)
    p.counter(1, match=15, step=emit)
    p.crc(width=15, poly=CAN_CRC15_POLY, check=0, absorb=absorb, data=shifter_out(0),
          emit=emit, init_ones=False)
    p.pin_cell(CAN_TX, src=line, mode=MODE_PUSH_PULL)
    p.arm()
    p.wev(crc_done)
    p.clrev()
    for _ in range(14):           # stuff bit, delimiter, ACK, delimiter, EOF, IFS
        p.wev(tick)
    p.halt()
    return p.assemble()


def uart_transmit(bit_cycles: int) -> list[int]:
    """8N1 transmitter on the TX pin, bytes from TX FIFO channel 0."""
    p = Px8()
    _uart_tx(p, 0, bit_cycles, UART_TX_PIN)
    p.shifter_io(0, pull=True)
    p.arm()
    p.idle_forever()
    return p.assemble()


# --------------------------------------------------------------------- I2S
I2S_BCLK, I2S_WS, I2S_SD = 0, 1, 2


def i2s_transmit(half_cycles: int, bits: int = 16) -> list[int]:
    """Philips I2S transmitter: stereo samples of `bits` bits (whole bytes,
    MSB first, left then right) streamed from the TX FIFO. SD changes on
    BCLK's falling edge; WS (low = left) changes one BCLK before each
    sample's MSB, so the stream starts with a pre bit. Timer 0 is BCLK;
    timer 1 is WS, resting high so the first left sample is marked by a WS
    edge too: its first tick, right after the start, brings it low, and
    then it toggles every `bits` BCLKs, a cycle after BCLK's falling edge.
    Both run while the shifter does."""
    assert bits % 8 == 0
    p = Px8()
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
            start=shifter_active(0), stop=shifter_stop(0))
    p.timer(1, reload=2 * bits * half_cycles - 1, phase=0, idle=1,
            start=shifter_active(0), stop=shifter_stop(0))
    p.shifter(0, msb=True, pre=1, pre_val=0, shift=timer_fall(0))
    p.shifter_burst(0, end=flag(0))
    p.shifter_io(0, pull=True)
    p.pin_cell(I2S_BCLK, src=timer_out(0), mode=MODE_PUSH_PULL)
    p.pin_cell(I2S_WS, src=timer_out(1), mode=MODE_PUSH_PULL)
    p.pin_cell(I2S_SD, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.arm()
    p.idle_forever()
    return p.assemble()


# --------------------------------------------------------------- SPI slave
def spi_slave() -> list[int]:
    """SPI mode-0 slave, MSB first, any number of bytes per transaction:
    each byte received on MOSI goes to RX channel 0, each byte sent on
    MISO comes from TX channel 0. Every edge comes from the master's pins
    (two-flop synchronized), so SCK may run at up to about clk / 16.

    Shifter 0 frames restart back to back while CS is low (logic cell 0 is
    CS inverted), presenting the first bit at once and shifting on SCK's
    falling edge, sampling on its rising edge. CS itself selects the
    context: context 1 (CS high) leaves MISO released, context 0 drives it,
    so the slave lets go of the bus with no controller involvement."""
    p = Px8()
    cs_low = logic(0)
    p.logic(0, truth(lambda cs: not cs, 1), [pin_level(SPI_CS)])
    p.write_contexts(3)
    p.shifter(0, msb=True, shift=pin_fall(SPI_SCK), sample=pin_rise(SPI_SCK))
    p.shifter_io(0, start=cs_low, data_in=pin_level(SPI_MOSI), pull=True, push=True)
    p.write_contexts(1)
    p.pin_cell(SPI_MISO, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.write_contexts(2)
    p.pin_cell(SPI_MISO, mode=0)
    p.write_contexts(3)
    p.context_select(pin_level(SPI_CS))
    p.arm()
    p.idle_forever()
    return p.assemble()


# ------------------------------------------------------------------ DMX512
DMX_PIN = 1
DMX_BIT = 4 * US                 # 250 kbit/s
DMX_BREAK = 92 * US              # >= 88 us
DMX_MAB = 12 * US                # >= 8 us


def dmx512_transmit(packets: int = 1) -> list[int]:
    """DMX512 transmitter: per packet a break, a mark after break, then the
    start code and slots from the TX FIFO as one gapless 8N2 stream, all at
    exact fabric timing. The break is a context: timer 1, a one-shot,
    selects context 1, where the pin cell drives a constant 0; timer 2
    times the mark after it. The controller only sequences: break, then
    open the FIFO to the shifter until it runs dry (the host, or the
    controller streaming from SRAM, keeps ahead of the 44 us slots), then
    the next packet."""
    p = Px8()
    p.write_contexts(3)
    p.timer(0, reload=DMX_BIT - 1, phase=DMX_BIT - 3, pulse=True,
            start=shifter_active(0), stop=shifter_stop(0))
    p.shifter(0, pre=1, pre_val=0, post=2, post_val=1, idle=1, shift=timer_rise(0))
    p.timer(1, reload=DMX_BREAK - 1, phase=0, start=fire(1), stop=timer_fall(1))
    p.timer(2, reload=DMX_MAB - 1, phase=DMX_MAB - 1, pulse=True,
            start=timer_fall(1), stop=timer_rise(2))
    p.write_contexts(1)
    p.pin_cell(DMX_PIN, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.write_contexts(2)
    p.pin_cell(DMX_PIN, const=0, mode=MODE_PUSH_PULL)
    p.write_contexts(3)
    p.context_select(timer_out(1))
    p.arm()
    for _ in range(packets):
        p.clrev()
        p.fire(1)
        p.wev(timer_rise(2))          # break and mark after break are done
        p.shifter_io(0, pull=True)    # frames follow back to back
        p.wev(shifter_stop(0))        # the FIFO ran dry: the packet is over
        p.shifter_io(0)               # close the FIFO until the next break
    p.halt()
    return p.assemble()


# --------------------------------------------------------------------- SWD
SWD_CLK, SWD_IO = 0, 1


def swd_host(half_cycles: int, chunks: list[tuple[int, int, bool]]) -> list[int]:
    """ARM Serial Wire Debug host. Each chunk (length, bits, read) is
    clocked LSB first on SWCLK (timer 0, resting low between chunks). A
    write chunk (up to 16 bits) drives SWDIO, changing it on SWCLK's
    falling edge for the target to sample on the rising one; a read chunk
    (up to 8 bits, turnarounds too) releases SWDIO and samples it on each
    falling edge, after the target has driven it on the rising one, and
    pushes the bits to the host.

    Direction is the context: context 0 drives SWDIO from shifter 0 and
    samples on the rising edge, context 1 releases it and samples on the
    falling edge. Controller flag 1 picks it per chunk."""
    p = Px8()
    rise, fall = timer_rise(0), timer_fall(0)
    p.write_contexts(3)
    p.timer(0, reload=half_cycles - 1, phase=half_cycles - 1, idle=0,
            start=shifter_active(0), stop=shifter_stop(0))
    p.pin_cell(SWD_CLK, src=timer_out(0), mode=MODE_PUSH_PULL)
    p.shifter_io(0, start=fire(0), data_in=pin_level(SWD_IO))
    p.write_contexts(1)
    p.pin_cell(SWD_IO, src=shifter_out(0), mode=MODE_PUSH_PULL)
    p.cfg(0x12, fall | (rise << 6))           # shifter 0 step: shift, sample
    p.write_contexts(2)
    p.pin_cell(SWD_IO, mode=0)
    p.cfg(0x12, fall | (fall << 6))
    p.write_contexts(3)
    p.context_select(flag(1))
    p.arm()
    length_now, read_now = None, None
    for length, bits, read in chunks:
        assert 1 <= length <= (8 if read else 16)
        if read != read_now:
            p.flags(0b10 if read else 0b00)
            read_now = read
        if length != length_now:
            p.cfg(0x11, (length - 1) | (1 << 15))  # shifter 0 frame: length, idle 1
            length_now = length
        p.shifter_data(0, bits)
        p.fire(0)
        p.wev(shifter_stop(0))
        if read:
            p.rd(rd_shifter_data(0))
            p.push()
    p.halt()
    return p.assemble()


def ps2_host(commands: list[tuple[int, int]], inhibit_cycles: int) -> list[int]:
    """PS/2 host: sends each (command byte, reply count) to the device
    (host-to-device frames: start, 8 data bits LSB first, odd parity,
    stop, then the device's ACK) and waits for that many reply bytes
    before the next command, on the same two open-drain lines. Replies go
    to RX channel 1, ACK bits (0 = acknowledged) to channel 0.

    Sending: timer 1 holds CLK low for `inhibit_cycles` (a one-shot that
    rests released), shifter 0 has already pulled DATA low with its start
    bit; then the device clocks: each CLK falling edge presents the next
    bit and samples DATA, so the 11th edge's sample is the device's ACK.
    Receiving is shifter 1 as in ps2_receive, idle while shifter 0 sends."""
    p = Px8()
    p.timer(1, reload=inhibit_cycles - 1, phase=0, idle=1, start=fire(1), stop=timer_rise(1))
    p.pin_cell(PS2_CLK, src=timer_out(1), mode=MODE_OPEN_DRAIN)
    p.pin_cell(PS2_DATA, src=shifter_out(0), mode=MODE_OPEN_DRAIN)
    p.shifter(0, pre=1, pre_val=0, parity=2, post=1, post_val=1, idle=1,
              shift=pin_fall(PS2_CLK), sample=pin_fall(PS2_CLK))
    p.shifter_io(0, start=fire(0), data_in=pin_level(PS2_DATA))
    p.shifter(1, pre=1, post=1, post_val=1, parity=2,
              shift=pin_fall(PS2_CLK), sample=pin_fall(PS2_CLK))
    p.shifter_io(1, start=ONE, data_in=pin_level(PS2_DATA), push=True)
    p.arm()
    for command, replies in commands:
        p.shifter_io(1)                  # the receiver stands aside
        p.shifter_data(0, command)
        p.clrev()
        p.fire(1)
        p.wev(pin_fall(PS2_CLK))         # our own inhibit edge has passed
        p.fire(0)
        p.wev(shifter_stop(0))
        p.rd(rd_shifter_status(0))
        p.andc(1)                        # the last post-bit sample: ACK (0)
        p.push()
        p.clrev()
        p.shifter_io(1, start=ONE, data_in=pin_level(PS2_DATA), push=True)
        for _ in range(replies):
            p.wev(shifter_word(1))
        p.clrev()
        p.wev(pin_rise(PS2_CLK))         # the device releases its last clock
    p.halt()
    return p.assemble()


def can_receive(bit_cycles: int, sample_at: int) -> list[int]:
    """CAN 2.0A receiver node on CAN_RX, acknowledging on CAN_TX. The
    destuffed frame (SOF through CRC, then the tail) reaches RX channel 1
    as MSB-first bytes, the last one tagged eop, and err if the CRC-15
    failed; a frame whose CRC checks is acknowledged in its ACK slot.

    Timer 0 samples `sample_at` cycles into each bit, resynchronized on
    every recessive-to-dominant edge (logic cell 0). Counter 0 counts
    equal bits; after five, the next sample is a stuff bit and is not
    consumed (cell 1 is the consume pulse). Counter 1 counts consumed bits:
    its hit just before the DLC starts shifter 0, which captures the 4 DLC
    bits; the controller then sets counter 1 to the bit count of the CRC
    delimiter (35 + 8 * DLC), which a trailing stuff bit cannot shift since
    stuff bits are not consumed. The CRC absorbs consumed bits through the
    delimiter (cell 3; its 1 makes the good residue the polynomial itself)
    and destuffing stops there; timer 2 times the ACK slot from the
    delimiter, and cell 4 drives it dominant only if the residue checks. Timer 3 ends the frame once 11 bits
    pass without a dominant edge (end of frame), which also re-initializes
    the CRC and counters, and ends the packet in the byte layer. All eight
    logic cells, all four timers, both shifters and counters, and the CRC:
    the whole fabric is one CAN node."""
    assert bit_cycles - sample_at >= 8, "the ACK needs 8 cycles after the delimiter's sample"
    p = Px8()
    rx = pin_level(CAN_RX)
    edge, consume, in_frame, crc_on, ack, past_dlc, ack_go, bad = (logic(i) for i in range(8))
    tick, eof = timer_rise(0), timer_rise(3)
    stuff = counter_ge(0)
    p.logic(0, truth(lambda f: f, 1), [pin_fall(CAN_RX)])
    # Destuffing stops after the CRC delimiter (the recessive tail is not
    # stuffed), so the tail completes the frame's last byte.
    p.logic(1, truth(lambda t, st, c: t and not (st and c), 3), [tick, stuff, crc_on])
    p.logic(2, truth(lambda q, e, end: (q or e) and not end, 3), [in_frame, edge, eof])
    # CRC on from SOF (the first edge of an idle bus) through the delimiter.
    p.logic(3, truth(lambda q, e, f, go: (q or (e and not f)) and not go),
            [crc_on, edge, in_frame, ack_go])
    p.logic(4, truth(lambda a, ok: not (a and ok), 2), [timer_out(2), CRC_OK], start=1)
    # Counter 1 hits twice per frame: before the DLC, then at the CRC end;
    # only the second, once the DLC has been captured, starts the ACK.
    p.logic(5, truth(lambda q, got, end: (q or got) and not end, 3),
            [past_dlc, shifter_stop(0), eof])
    p.logic(6, truth(lambda h, past: h and past, 2), [counter_hit(1), past_dlc])
    p.logic(7, truth(lambda c, f, ok: f and not c and not ok, 3), [crc_on, in_frame, CRC_OK])
    # Sample point: edge on the wire + 2 (synchronizer) + 1 (pulse) + 1
    # (cell 0) + resync + tick + pulse = phase + 6.
    p.timer(0, reload=bit_cycles - 1, phase=sample_at - 6, pulse=True,
            start=edge, resync=edge, stop=eof)
    p.timer(3, reload=11 * bit_cycles, phase=11 * bit_cycles, pulse=True,
            start=edge, resync=edge, stop=eof)
    # ACK slot: the bit after the CRC delimiter; cell 6 fires sample_at + 3
    # cycles into the delimiter; timer 2's output follows its start by
    # phase + 2, and the pin follows it by 3 more (cell 4, pin register,
    # the transceiver's wire).
    p.timer(2, reload=bit_cycles - 1, phase=bit_cycles - sample_at - 8, idle=0,
            start=ack_go, stop=timer_fall(2))
    p.counter(0, match=5, step=tick, data=rx, mode=RUN_EQUAL, clear=eof)
    p.counter(1, match=15, step=consume, clear=eof)
    p.crc(width=15, poly=CAN_CRC15_POLY, check=CAN_CRC15_POLY, absorb=consume, absorb_gate=crc_on,
          data=rx, init=eof, init_ones=False)
    p.shifter(1, msb=True, shift=consume, sample=consume)
    p.shifter_io(1, start=in_frame, data_in=rx, push=True)
    p.shifter_abort(1, eof)
    p.tile_tag(rx_tile(1, 0), end=eof, err=bad)
    p.shifter(0, length=4, msb=True, shift=consume, sample=consume)
    p.shifter_io(0, start=counter_hit(1), data_in=rx)
    p.pin_cell(CAN_TX, src=ack, mode=MODE_PUSH_PULL)
    p.arm()
    p.label("frame")
    p.clrev()
    p.wev(shifter_stop(0))
    p.rd(rd_shifter_data(0))
    # delimiter = 35 + 8 * min(DLC, 8): DLC 8..15 have bit 3 set.
    p.andc(0x8)
    p.jz("small")
    p.ldc(35 + 64)
    p.wcf(0x24)
    p.j("wait")
    p.label("small")
    for dlc in range(8):
        p.rd(rd_shifter_data(0))
        p.xrc(dlc)
        p.jz(f"dlc{dlc}")
    p.label("dlc0")                      # (dlc 0 falls through here too)
    p.ldc(35)
    p.wcf(0x24)
    p.j("wait")
    for dlc in range(1, 8):
        p.label(f"dlc{dlc}")
        p.ldc(35 + 8 * dlc)
        p.wcf(0x24)
        p.j("wait")
    p.label("wait")
    p.wev(eof)
    p.ldc(15)
    p.wcf(0x24)                          # next frame: hit before its DLC again
    p.j("frame")
    return p.assemble()


# --------------------------------------------------------------- I2C slave
def i2c_slave(address: int) -> list[int]:
    """I2C slave at a 7-bit address (standard mode: SCL high >= 4 us). A
    write to us is acknowledged byte by byte and every byte on the bus,
    address first, reaches RX channel 1; a read from us returns TX channel
    0 bytes until the master answers NACK. Other addresses are not
    acknowledged and never driven.

    Logic cells: 0 START and 1 STOP (SDA falling / rising while SCL is
    high), 2 in a transaction, 3 the ACK window (loaded at every SCL fall:
    true from the fall after a byte's 8th bit to the fall after the 9th),
    4 the SDA driver, 5 START or STOP, 6 a byte boundary (START or the 9th
    rising edge), 7 the read phase (the controller's flag 1, taken at an
    SCL fall so SDA never moves while SCL is high). Counter 0 counts SCL
    falls and counter 1 rises within a byte; timer 1 turns cell 6 into the
    pulse that clears them. Shifter 1 receives every byte (8 bits and the
    ACK bit, on SCL rising edges); shifter 0 sends during reads (changing
    after SCL falls, releasing for the master's ACK bit). The controller
    compares the address while SCL is high after its 8th bit."""
    scl_rise, scl_fall = pin_rise(I2C_SCL), pin_fall(I2C_SCL)
    start, stop, in_txn, ack_win, sda_out, start_stop, boundary, read_eff = (
        logic(i) for i in range(8))
    matched, reading = flag(0), flag(1)
    p = Px8()
    p.logic(0, truth(lambda f, scl: f and scl, 2), [pin_fall(I2C_SDA), pin_level(I2C_SCL)])
    p.logic(1, truth(lambda r, scl: r and scl, 2), [pin_rise(I2C_SDA), pin_level(I2C_SCL)])
    p.logic(2, truth(lambda q, s, e: (q or s) and not e, 3), [in_txn, start, stop])
    p.logic(3, truth(lambda ge: ge, 1), [counter_ge(0)], enable=scl_fall)
    p.logic(4, truth(lambda w, m, rd, so: (not (w and m and not rd)) and (not rd or so)),
            [ack_win, matched, read_eff, shifter_out(0)], start=1)
    p.logic(5, truth(lambda s, e: s or e, 2), [start, stop])
    p.logic(6, truth(lambda w, s: w or s, 2), [shifter_word(1), start])
    p.logic(7, truth(lambda r: r, 1), [reading], enable=scl_fall)
    p.timer(1, reload=3, phase=0, pulse=True, start=boundary, stop=timer_rise(1))
    p.counter(0, match=8, step=scl_fall, clear=timer_rise(1))
    p.counter(1, match=8, step=scl_rise, clear=timer_rise(1))
    p.shifter(1, msb=True, post=1, post_val=0, shift=scl_rise, sample=scl_rise)
    p.shifter_io(1, start=in_txn, data_in=pin_level(I2C_SDA), push=True)
    p.shifter_abort(1, start_stop)
    p.shifter(0, msb=True, post=1, post_val=1, idle=1, shift=scl_fall)
    p.shifter_io(0, start=read_eff, pull=True)
    p.shifter_abort(0, start_stop)
    p.pin_cell(I2C_SDA, src=sda_out, mode=MODE_OPEN_DRAIN)
    p.arm()
    p.label("idle")
    p.flags(0)
    # Logic-cell lines are levels to the controller, not sticky events, so
    # it waits on the transaction level: a repeated START keeps it high.
    p.wev(in_txn)
    p.wev(counter_ge(1))               # 8 address bits in, SCL high
    p.rd(rd_shifter_data(1))
    p.andc(0xFE)
    p.xrc(address << 1)
    p.jz("ours")
    p.clrev()
    p.wev(start_stop)                  # not us: wait for the bus to move on
    p.j("idle")
    p.label("ours")
    p.flags(0b01)                      # ACK the address
    p.rd(rd_shifter_data(1))
    p.andc(1)
    p.jz("write")
    p.clrev()
    p.wev(shifter_word(1))             # the address ACK clock
    p.flags(0b11)                      # read phase from the next SCL fall
    p.label("read_byte")
    p.clrev()
    p.wev(shifter_word(1))             # a byte sent and the master's ACK bit
    # The ACK bit is still on SDA (SCL is high); the shifter has already
    # started its next frame, which clears its own copy.
    p.rd(RD_PINS)
    p.andc(1 << I2C_SDA)               # 1 = NACK: that was the last byte
    p.jz("read_byte")
    p.flags(0b01)                      # release SDA from the next SCL fall
    p.clrev()
    p.wev(start_stop)
    p.j("idle")
    p.label("write")
    p.clrev()
    p.wev(start_stop)                  # bytes are ACKed until STOP / START
    p.j("idle")
    return p.assemble()

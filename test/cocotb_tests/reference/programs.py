"""Assembler helpers and minimal protocol programs for the protocol-neutral ISA."""

NOP = 0x00
HALT = 0x01
TX_LOAD = 0x40
RX_PUSH = 0x70
SHIFT_CLEAR = 0xA0

# Opcode 0xA immediate sub-ops (general CRC + line_pair)
CRC_SETUP = 0xA1
CRC_FEED = 0xA2
CRC_FINALIZE = 0xA3
CRC_PUSH_LO = 0xA4
CRC_PUSH_HI = 0xA5
LINE_CFG = 0xA6
LINE_DRIVE = 0xA7
LINE_RELEASE = 0xA8
LINE_SAMPLE = 0xA9

# Event mask bits (WAIT_EVENT / OR)
EV_XFER_DONE = 1 << 0
EV_TIMER_DONE = 1 << 1
EV_PIN_RISE = 1 << 2
EV_PIN_FALL = 1 << 3
EV_COMPARE = 1 << 4
EV_LINE_CHANGE = 1 << 5


def wait(cycles: int) -> list[int]:
    if not 0 <= cycles <= 0xFFFF:
        raise ValueError("wait duration must fit in 16 bits")
    return [0x10, cycles & 0xFF, cycles >> 8]


def start_timer(cycles: int) -> list[int]:
    """Nonblocking timer: sets EV_TIMER_DONE on expiry."""
    if not 0 <= cycles <= 0xFFFF:
        raise ValueError("timer duration must fit in 16 bits")
    return [0xE0, cycles & 0xFF, cycles >> 8]


def wait_event(mask: int) -> list[int]:
    """Stall until any pending event in mask is set; clears matched bits."""
    if not 0 <= mask <= 0xFF:
        raise ValueError("event mask must fit in 8 bits")
    return [0xD0, mask & 0xFF]


def arm_edges(rise_mask: int, fall_mask: int, compare: bool = False) -> list[int]:
    """Arm pin-edge / compare events for WAIT_EVENT."""
    return [0xF0 | (1 if compare else 0), rise_mask & 0xFF, fall_mask & 0xFF]


def gpio_write(pin: int, value: int) -> int:
    return 0x20 | ((value & 1) << 3) | (pin & 7)


def gpio_oe(pin: int, enabled: int) -> int:
    return 0x30 | ((enabled & 1) << 3) | (pin & 7)


def shift_out(pin: int) -> int:
    return 0x50 | (pin & 7)


def shift_in(pin: int) -> int:
    return 0x60 | (pin & 7)


def jump(address: int) -> list[int]:
    return [0x80, address & 0xFF, (address >> 8) & 0x03]


def wait_pin(pin: int, value: int) -> int:
    return 0x90 | ((value & 1) << 3) | (pin & 7)


def map_pin(logical_pin: int, physical_pin: int) -> list[int]:
    return [0xB0 | (logical_pin & 7), physical_pin & 7]


def start_xfer(
    *,
    clk_pin: int,
    tx_pin: int,
    rx_pin: int,
    bit_count: int,
    half_period: int,
    msb_first: bool = True,
    clk_idle: int = 0,
    sample_phase: int = 0,
    tx_open_drain: bool = False,
    clk_open_drain: bool = False,
    wait_clk_high: bool = False,
) -> list[int]:
    """Configure and launch the bit-transfer engine without waiting."""
    if not 1 <= bit_count <= 16:
        raise ValueError("bit_count must be 1..16")
    if not 0 <= half_period <= 0xFF:
        raise ValueError("half_period must fit in 8 bits")
    cfg = (
        ((bit_count - 1) & 0xF)
        | ((1 if msb_first else 0) << 4)
        | ((clk_idle & 1) << 5)
        | ((sample_phase & 1) << 6)
        | ((1 if tx_open_drain else 0) << 7)
    )
    pins = (
        (tx_pin & 7)
        | ((rx_pin & 7) << 3)
        | ((1 if clk_open_drain else 0) << 6)
        | ((1 if wait_clk_high else 0) << 7)
    )
    return [0xC0 | (clk_pin & 7), cfg, pins, half_period & 0xFF]


def bit_xfer(**kwargs) -> list[int]:
    """Backward-compatible blocking transfer: START_XFER + WAIT_EVENT XFER_DONE."""
    return start_xfer(**kwargs) + wait_event(EV_XFER_DONE)


def uart_tx_program(wait_cycles: int, pin: int = 0) -> list[int]:
    """Continuous 8-N-1 TX loop; TX_LOAD stalls safely on an empty FIFO."""
    program = [gpio_oe(pin, 1), gpio_write(pin, 1)]
    loop_address = len(program)
    program += [TX_LOAD, gpio_write(pin, 0), *wait(wait_cycles)]
    for _ in range(8):
        program += [shift_out(pin), *wait(wait_cycles)]
    program += [gpio_write(pin, 1), *wait(wait_cycles), *jump(loop_address)]
    return program


def uart_rx_program(wait_cycles: int, first_sample_wait: int, pin: int = 0) -> list[int]:
    """Continuous 8-N-1 RX loop sampling at bit centers into the RX FIFO."""
    program = [gpio_oe(pin, 0)]
    loop_address = len(program)
    program += [wait_pin(pin, 0), *wait(first_sample_wait), SHIFT_CLEAR, shift_in(pin)]
    for _ in range(7):
        program += [*wait(wait_cycles), shift_in(pin)]
    program += [*wait(wait_cycles), RX_PUSH, wait_pin(pin, 1), *jump(loop_address)]
    return program


def spi_master_program(
    *,
    mode: int,
    bit_count: int = 8,
    half_period: int = 2,
    mosi: int = 0,
    miso: int = 1,
    sclk: int = 2,
    cs: int = 3,
) -> list[int]:
    """One SPI master transfer via nonblocking START_XFER + WAIT_EVENT."""
    if mode not in (0, 1, 2, 3):
        raise ValueError("SPI mode must be 0..3")
    clk_idle = 1 if mode in (2, 3) else 0
    sample_phase = 1 if mode in (1, 3) else 0
    return [
        gpio_oe(cs, 1),
        gpio_write(cs, 1),
        gpio_oe(mosi, 1),
        gpio_oe(sclk, 1),
        gpio_write(sclk, clk_idle),
        gpio_oe(miso, 0),
        TX_LOAD,
        gpio_write(cs, 0),
        *start_xfer(
            clk_pin=sclk,
            tx_pin=mosi,
            rx_pin=miso,
            bit_count=bit_count,
            half_period=half_period,
            msb_first=True,
            clk_idle=clk_idle,
            sample_phase=sample_phase,
        ),
        *wait_event(EV_XFER_DONE),
        RX_PUSH,
        gpio_write(cs, 1),
        HALT,
    ]


def overlap_xfer_timer_program(
    *,
    half_period: int = 2,
    timer_cycles: int = 80,
    mosi: int = 0,
    miso: int = 1,
    sclk: int = 2,
    flag_pin: int = 4,
) -> list[int]:
    """Prove VM freedom: START_XFER, toggle a flag, wait XFER_DONE|TIMER_DONE."""
    return [
        gpio_oe(mosi, 1),
        gpio_oe(sclk, 1),
        gpio_oe(flag_pin, 1),
        gpio_write(sclk, 0),
        gpio_write(flag_pin, 0),
        TX_LOAD,
        *start_xfer(
            clk_pin=sclk,
            tx_pin=mosi,
            rx_pin=miso,
            bit_count=8,
            half_period=half_period,
        ),
        *start_timer(timer_cycles),
        gpio_write(flag_pin, 1),
        *wait_event(EV_XFER_DONE),
        *wait_event(EV_TIMER_DONE),
        RX_PUSH,
        gpio_write(flag_pin, 0),
        HALT,
    ]


def i2c_write_byte_program(
    *,
    sda: int = 0,
    scl: int = 1,
    half_period: int = 2,
    with_ack_xfer: bool = True,
) -> list[int]:
    """I2C master: START, 8-bit write via BIT_XFER, optional ACK bit, STOP."""
    program = [
        gpio_oe(sda, 1),
        gpio_write(sda, 1),
        gpio_oe(scl, 1),
        gpio_write(scl, 1),
        TX_LOAD,
        gpio_write(sda, 0),
        *wait(half_period),
        gpio_write(scl, 0),
        *bit_xfer(
            clk_pin=scl,
            tx_pin=sda,
            rx_pin=sda,
            bit_count=8,
            half_period=half_period,
            msb_first=True,
            clk_idle=0,
            sample_phase=0,
            tx_open_drain=True,
            clk_open_drain=True,
            wait_clk_high=True,
        ),
    ]
    if with_ack_xfer:
        program += [
            TX_LOAD,
            *bit_xfer(
                clk_pin=scl,
                tx_pin=sda,
                rx_pin=sda,
                bit_count=1,
                half_period=half_period,
                msb_first=True,
                clk_idle=0,
                sample_phase=0,
                tx_open_drain=True,
                clk_open_drain=True,
                wait_clk_high=True,
            ),
            RX_PUSH,
        ]
    program += [
        gpio_oe(sda, 1),
        gpio_write(sda, 0),
        gpio_oe(scl, 1),
        gpio_write(scl, 1),
        *wait(half_period),
        gpio_oe(sda, 0),
        HALT,
    ]
    return program


# Low-speed USB-ish line pins (logical): D+ / D− on uio[0]/uio[1] by default.
DP_PIN = 0
DM_PIN = 1

# LS bit time at 50 MHz ≈ 33 cycles (1.5 Mb/s). Use a round value for smoke.
LS_BIT_CYCLES = 33

# Line-pair state codes (match line_pair RTL)
LINE_SE0 = 0
LINE_J = 1
LINE_K = 2
LINE_SE1 = 3


def crc_setup(
    *,
    width: int,
    poly: int,
    refin: bool = True,
    refout: bool = True,
    xor_ones: bool = True,
    init_ones: bool = True,
) -> list[int]:
    """Programmable CRC init: `A1 cfg poly_lo poly_hi`."""
    if not 1 <= width <= 16:
        raise ValueError("CRC width must be 1..16")
    cfg = (
        ((width - 1) & 0xF)
        | ((1 if refin else 0) << 4)
        | ((1 if refout else 0) << 5)
        | ((1 if xor_ones else 0) << 6)
        | ((1 if init_ones else 0) << 7)
    )
    return [CRC_SETUP, cfg, poly & 0xFF, (poly >> 8) & 0xFF]


def crc_feed(byte: int) -> list[int]:
    return [CRC_FEED, byte & 0xFF]


def crc_finalize() -> int:
    return CRC_FINALIZE


def crc_push_result() -> list[int]:
    return [CRC_PUSH_LO, CRC_PUSH_HI]


def crc_usb5_setup() -> list[int]:
    """USB token CRC5: poly x^5+x^2+1."""
    return crc_setup(width=5, poly=0x05)


def crc_usb16_setup() -> list[int]:
    """USB data CRC16: poly x^16+x^15+x^2+1."""
    return crc_setup(width=16, poly=0x8005)


def line_cfg(pin_a: int = DP_PIN, pin_b: int = DM_PIN, jk_swap: bool = False) -> list[int]:
    pins = (pin_a & 7) | ((pin_b & 7) << 3) | ((1 if jk_swap else 0) << 6)
    return [LINE_CFG, pins]


def line_drive(state: int) -> list[int]:
    return [LINE_DRIVE, state & 3]


def line_release() -> int:
    return LINE_RELEASE


def line_sample() -> int:
    return LINE_SAMPLE


def line_state_smoke_program(
    *,
    dp: int = DP_PIN,
    dm: int = DM_PIN,
    bit_cycles: int = LS_BIT_CYCLES,
) -> list[int]:
    """Phase-0 smoke: drive J / K / SE0 / J on a pin pair using only GPIO+WAIT16.

    LS idle is J (D+ = 0, D− = 1) with a board pull-up on D−. No CRC or
    line_pair resource — proves timing headroom before dedicated engines.
    """
    def drive(dp_v: int, dm_v: int) -> list[int]:
        return [gpio_write(dp, dp_v), gpio_write(dm, dm_v), *wait(bit_cycles)]

    return [
        gpio_oe(dp, 1),
        gpio_oe(dm, 1),
        *drive(0, 1),
        *drive(1, 0),
        *drive(0, 0),
        *drive(0, 1),
        gpio_oe(dp, 0),
        gpio_oe(dm, 0),
        HALT,
    ]


def line_pair_smoke_program(
    *,
    dp: int = DP_PIN,
    dm: int = DM_PIN,
    bit_cycles: int = LS_BIT_CYCLES,
) -> list[int]:
    """Drive J/K/SE0/J via line_pair, sample final idle after release."""
    return [
        *line_cfg(dp, dm),
        *line_drive(LINE_J),
        *wait(bit_cycles),
        *line_drive(LINE_K),
        *wait(bit_cycles),
        *line_drive(LINE_SE0),
        *wait(bit_cycles),
        *line_drive(LINE_J),
        *wait(bit_cycles),
        line_release(),
        # Host/cocotb may drive idle J on uio_in while OE is released.
        line_sample(),
        HALT,
    ]


def crc_usb16_demo_program(data: list[int]) -> list[int]:
    """Feed bytes through USB CRC16 and push the 16-bit result to RX."""
    program = [*crc_usb16_setup()]
    for b in data:
        program += crc_feed(b)
    program += [crc_finalize(), *crc_push_result(), HALT]
    return program


def ls_ack_packet_program(
    *,
    dp: int = DP_PIN,
    dm: int = DM_PIN,
    bit_cycles: int = LS_BIT_CYCLES,
) -> list[int]:
    """Soft LS device TX: SYNC + ACK PID (0xD2) as raw NRZI-ish line states.

    Emits a fixed line-state sequence (not a full NRZI encoder): KJKJKJKK
    SYNC pattern plus ACK PID bits as J/K toggles, then SE0 EOP and idle J.
    Framing stays in bytecode — no USB FSM in RTL.
    """
    # Simplified: drive a recognizable J/K pattern then SE0 EOP.
    # SYNC (LSB first NRZI from idle J): K J K J K J K K
    sync = [LINE_K, LINE_J, LINE_K, LINE_J, LINE_K, LINE_J, LINE_K, LINE_K]
    # ACK PID 0xD2 = 11010010 LSB-first bits; NRZI from last SYNC state (K):
    # bit0=0 -> toggle to J, 1=J, 0=K, 0=J, 1=J, 0=K, 1=K, 1=K — approximate demo
    ack = [LINE_J, LINE_J, LINE_K, LINE_J, LINE_J, LINE_K, LINE_K, LINE_K]
    program = [*line_cfg(dp, dm), *line_drive(LINE_J), *wait(bit_cycles)]
    for st in sync + ack:
        program += [*line_drive(st), *wait(bit_cycles)]
    # EOP: SE0 for two bit times, then J
    program += [
        *line_drive(LINE_SE0),
        *wait(bit_cycles),
        *wait(bit_cycles),
        *line_drive(LINE_J),
        *wait(bit_cycles),
        line_release(),
        HALT,
    ]
    return program

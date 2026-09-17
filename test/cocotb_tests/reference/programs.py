"""Assembler helpers and minimal protocol programs for the protocol-neutral ISA."""

NOP = 0x00
HALT = 0x01
TX_LOAD = 0x40
RX_PUSH = 0x70
SHIFT_CLEAR = 0xA0


def wait(cycles: int) -> list[int]:
    if not 0 <= cycles <= 0xFFFF:
        raise ValueError("wait duration must fit in 16 bits")
    return [0x10, cycles & 0xFF, cycles >> 8]


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


def bit_xfer(
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
    """Encode configure+start for the autonomous bit-transfer engine."""
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
    """One SPI master transfer: CS low, BIT_XFER, CS high, push RX, halt."""
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
        *bit_xfer(
            clk_pin=sclk,
            tx_pin=mosi,
            rx_pin=miso,
            bit_count=bit_count,
            half_period=half_period,
            msb_first=True,
            clk_idle=clk_idle,
            sample_phase=sample_phase,
            tx_open_drain=False,
            clk_open_drain=False,
            wait_clk_high=False,
        ),
        RX_PUSH,
        gpio_write(cs, 1),
        HALT,
    ]


def i2c_write_byte_program(
    *,
    sda: int = 0,
    scl: int = 1,
    half_period: int = 2,
    with_ack_xfer: bool = True,
) -> list[int]:
    """I2C master: START, 8-bit write via BIT_XFER, optional ACK bit, STOP.

    When with_ack_xfer is set, the TX FIFO must supply a second byte whose low
    bit is 1 so the ACK slot releases SDA (open-drain).
    """
    program = [
        gpio_oe(sda, 1),
        gpio_write(sda, 1),
        gpio_oe(scl, 1),
        gpio_write(scl, 1),
        TX_LOAD,
        # START: SDA falls while SCL high
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
    # STOP: drive SDA low, raise SCL, release SDA
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

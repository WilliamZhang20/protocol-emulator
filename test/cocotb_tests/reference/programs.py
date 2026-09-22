"""Assembler helpers and minimal protocol programs for the protocol-neutral ISA."""

NOP = 0x00
HALT = 0x01
TX_LOAD = 0x40
RX_PUSH = 0x70
SHIFT_CLEAR = 0xA0

# Opcode 0xA immediate sub-ops (CRC, ALU, and time)
CRC_SETUP = 0xA1
CRC_FEED = 0xA2
CRC_FINALIZE = 0xA3
CRC_PUSH_LO = 0xA4
CRC_PUSH_HI = 0xA5

# Event mask bits (WAIT_EVENT / OR)
EV_TIMER_DONE = 1 << 1
EV_PIN_RISE = 1 << 2
EV_PIN_FALL = 1 << 3
EV_COMPARE = 1 << 4
EV_REGION_DONE = 1 << 6

# Action-engine CPU interface (Phase C/D)
RUN_REGION = 0xE4
RUN_REGION_N = 0xE5
WAIT_REGION = 0xE6
READ_RESULT = 0xE7
ACTION_WR_LO = 0xE8
ACTION_WR_HI = 0xE9
ACTION_LOAD_SHIFT = 0xEA
ACTION_WR_LANE_LO = 0xEB
ACTION_WR_LANE_HI = 0xEC
EVENT_DETAIL = 0xED
ACTION_LOAD_SHIFT_HI = 0xEE
ACTION_PUSH_RESULT = 0xEF
ACTION_LOAD_TX = 0xC8

# Action word opcodes (bits [15:12])
ACT_NOP = 0x0
ACT_GPIO = 0x1
ACT_SAMPLE = 0x2
ACT_SHIFT = 0x3
ACT_COUNT = 0x4
ACT_CRC = 0x5
ACT_NEXT = 0x6
ACT_DELAY = 0x7
ACT_REPEAT = 0x8
ACT_DONE = 0x9
ACT_PULL = 0xB
ACT_PUSH = 0xC


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


def jump_if_zero(address: int) -> list[int]:
    """JZ: jump if the ALU zero flag is set (additive; 0x80 stays unconditional)."""
    return [0x81, address & 0xFF, (address >> 8) & 0x03]


def jump_if_not_zero(address: int) -> list[int]:
    """JNZ: jump if the ALU zero flag is clear."""
    return [0x82, address & 0xFF, (address >> 8) & 0x03]


def djnz(reg: int, address: int) -> list[int]:
    """DJNZ Rn: decrement Rn, jump if result != 0. Reg 0..7."""
    if not 0 <= reg <= 7:
        raise ValueError("DJNZ register must be 0..7")
    return [0x88 | (reg & 7), address & 0xFF, (address >> 8) & 0x03]


# Tiny ALU ops (0xAC sub-op select)
ALU_ADD = 0
ALU_SUB = 1
ALU_AND = 2
ALU_OR = 3
ALU_XOR = 4
ALU_SHL = 5
ALU_SHR = 6


def reg_set(reg: int, value: int) -> list[int]:
    """SET Rd, imm8: Rd = zero-extended immediate, updates zero flag."""
    if not 0 <= reg <= 7:
        raise ValueError("register must be 0..7")
    return [0xAA, reg & 7, value & 0xFF]


def reg_mov(dst: int, src: int) -> list[int]:
    """MOV Rd, Rs: Rd = Rs, updates zero flag."""
    return [0xAB, ((src & 7) << 3) | (dst & 7)]


def reg_alu(op: int, dst: int, src: int) -> list[int]:
    """ALU: Rd = Rd op Rs (ADD/SUB/AND/OR/XOR/SHL/SHR), updates zero flag."""
    if not 0 <= op <= 6:
        raise ValueError("ALU op must be 0..6")
    return [0xAC, op & 7, ((src & 7) << 3) | (dst & 7)]


def get_time(reg: int) -> list[int]:
    """GET_TIME Rd: Rd = global cycle counter low 16 bits, updates zero flag."""
    if not 0 <= reg <= 7:
        raise ValueError("register must be 0..7")
    return [0xAD, reg & 7]


def wait_until(reg: int) -> list[int]:
    """WAIT_UNTIL Rn: stall until counter[15:0] >= Rn (unsigned)."""
    if not 0 <= reg <= 7:
        raise ValueError("register must be 0..7")
    return [0xAE, reg & 7]


def event_stamp() -> int:
    """EVENT_STAMP: push one timestamped-event byte; 3x = time_lo/time_hi/cause."""
    return 0xAF


def sideset(pin: int, value: int) -> list[int]:
    """Side-set prefix: `pin <- value` applied atomically at the next EXECUTE.

    Opcode 0x0 immediates 0x2-0xF (previously NOPs). The two degenerate
    codes fall back: 0x0 is a plain NOP, and 0x1 would be HALT so pin 1 <- 0
    uses a normal GPIO_WRITE instead.
    """
    if not 0 <= pin <= 7:
        raise ValueError("side-set pin must be 0..7")
    imm = ((value & 1) << 3) | (pin & 7)
    if imm == 0:
        return [NOP]
    if imm == 1:
        return [gpio_write(pin, value)]
    return [imm]


def wait_pin(pin: int, value: int) -> int:
    return 0x90 | ((value & 1) << 3) | (pin & 7)


def map_pin(logical_pin: int, physical_pin: int) -> list[int]:
    return [0xB0 | (logical_pin & 7), physical_pin & 7]


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
    *, mode: int, bit_count: int = 8, half_period: int = 2,
    mosi: int = 0, miso: int = 1, sclk: int = 2, cs: int = 3,
) -> list[int]:
    """One SPI master transaction compiled to an action region."""
    if mode not in (0, 1, 2, 3):
        raise ValueError("SPI mode must be 0..3")
    clk_idle = 1 if mode in (2, 3) else 0
    sample_phase = 1 if mode in (1, 3) else 0
    return [
        gpio_oe(cs, 1), gpio_write(cs, 1),
        gpio_oe(mosi, 1), gpio_oe(sclk, 1),
        gpio_write(sclk, clk_idle), gpio_oe(miso, 0),
        gpio_write(cs, 0),
        *action_clocked_transfer(
            clk_pin=sclk, tx_pin=mosi, rx_pin=miso,
            bit_count=bit_count, half_period=half_period,
            msb_first=True, clk_idle=clk_idle, sample_phase=sample_phase,
        ),
        wait_region(), *action_push_result(),
        gpio_write(cs, 1), HALT,
    ]


def overlap_region_timer_program(
    *,
    half_period: int = 2,
    timer_cycles: int = 80,
    mosi: int = 0,
    miso: int = 1,
    sclk: int = 2,
    flag_pin: int = 4,
) -> list[int]:
    """Prove VM freedom: RUN_REGION, toggle a flag, wait REGION_DONE|TIMER_DONE."""
    return [
        gpio_oe(mosi, 1),
        gpio_oe(sclk, 1),
        gpio_oe(flag_pin, 1),
        gpio_write(sclk, 0),
        gpio_write(flag_pin, 0),
        *action_clocked_transfer(
            clk_pin=sclk,
            tx_pin=mosi,
            rx_pin=miso,
            bit_count=8,
            half_period=half_period,
        ),
        *start_timer(timer_cycles),
        gpio_write(flag_pin, 1),
        *wait_event(EV_REGION_DONE),
        *wait_event(EV_TIMER_DONE),
        *action_push_result(),
        gpio_write(flag_pin, 0),
        HALT,
    ]


def i2c_write_byte_program(
    *, sda: int = 0, scl: int = 1, half_period: int = 2,
    with_ack_xfer: bool = True,
) -> list[int]:
    """I2C master START/write/ACK/STOP using action regions."""
    program = [
        gpio_oe(sda, 1), gpio_write(sda, 1),
        gpio_oe(scl, 1), gpio_write(scl, 1),
        gpio_write(sda, 0), *wait(half_period), gpio_write(scl, 0),
        *action_clocked_transfer(
            clk_pin=scl, tx_pin=sda, rx_pin=sda, bit_count=8,
            half_period=half_period, msb_first=True, clk_idle=0,
            tx_open_drain=True, clk_open_drain=True, wait_clk_high=True,
        ),
        wait_region(),
    ]
    if with_ack_xfer:
        program += [
            *action_clocked_transfer(
                clk_pin=scl, tx_pin=sda, rx_pin=sda, bit_count=1,
                half_period=half_period, msb_first=True, clk_idle=0,
                tx_open_drain=True, clk_open_drain=True, wait_clk_high=True,
            ),
            wait_region(), *action_push_result(shift=7),
        ]
    program += [
        gpio_oe(sda, 1), gpio_write(sda, 0),
        gpio_oe(scl, 1), gpio_write(scl, 1),
        *wait(half_period), gpio_oe(sda, 0), HALT,
    ]
    return program


# Low-speed USB-ish line pins (logical): D+ / D− on uio[0]/uio[1] by default.
DP_PIN = 0
DM_PIN = 1

# LS bit time at 50 MHz ≈ 33 cycles (1.5 Mb/s). Use a round value for smoke.
LS_BIT_CYCLES = 33

# Two-pin line state codes used by action programs
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


CRC32_SETUP = 0xE1
CRC_PUSH_B2 = 0xE2
CRC_PUSH_B3 = 0xE3


def crc32_setup_op() -> int:
    """IEEE-802.3 CRC-32 setup: width 32, poly 0x04C11DB7, init/xor ones."""
    return CRC32_SETUP


def crc_push_full() -> list[int]:
    """Push the full 32-bit CRC residue, little-endian (b0..b3)."""
    return [CRC_PUSH_LO, CRC_PUSH_HI, CRC_PUSH_B2, CRC_PUSH_B3]


def crc32_demo_program(data: list[int]) -> list[int]:
    """Feed bytes through IEEE CRC-32 and push the 32-bit result to RX."""
    program = [crc32_setup_op()]
    for b in data:
        program += crc_feed(b)
    program += [crc_finalize(), *crc_push_full(), HALT]
    return program


# JTAG Shift-DR pins (logical): the shift engine is protocol-neutral, so a
# JTAG DR shift is just an MSB-first 8-bit transfer with TMS held low.
JTAG_TDI = 0
JTAG_TDO = 1
JTAG_TCK = 2
JTAG_TMS = 3


def jtag_shift_dr_program(
    *, tck: int = JTAG_TCK, tms: int = JTAG_TMS,
    tdi: int = JTAG_TDI, tdo: int = JTAG_TDO,
    half_period: int = 4,
) -> list[int]:
    """One Shift-DR byte using the generic action region."""
    return [
        gpio_oe(tms, 1), gpio_oe(tdi, 1), gpio_oe(tck, 1),
        gpio_oe(tdo, 0), gpio_write(tck, 0), gpio_write(tms, 0),
        *action_clocked_transfer(
            clk_pin=tck, tx_pin=tdi, rx_pin=tdo,
            bit_count=8, half_period=half_period, msb_first=True,
        ),
        wait_region(), *action_push_result(), HALT,
    ]


def line_state_smoke_program(
    *,
    dp: int = DP_PIN,
    dm: int = DM_PIN,
    bit_cycles: int = LS_BIT_CYCLES,
) -> list[int]:
    """Phase-0 smoke: drive J / K / SE0 / J on a pin pair using only GPIO+WAIT16.

    LS idle is J (D+ = 0, D− = 1) with a board pull-up on D−. No CRC or
    dedicated line resources — proves GPIO timing headroom.
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


def action_line_smoke_program(
    *, dp: int = DP_PIN, dm: int = DM_PIN,
    bit_cycles: int = LS_BIT_CYCLES,
) -> list[int]:
    """Drive J/K/SE0/J with action regions and sample idle after release."""
    program = []
    for state in (LINE_J, LINE_K, LINE_SE0, LINE_J):
        program += action_line_drive(state, pin_a=dp, pin_b=dm)
        program += wait(bit_cycles)
    program += action_line_release(pin_a=dp, pin_b=dm)
    program += action_line_sample(pin_a=dp, pin_b=dm)
    return program + [HALT]


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
    program = [*action_line_drive(LINE_J, pin_a=dp, pin_b=dm), *wait(bit_cycles)]
    for st in sync + ack:
        program += [*action_line_drive(st, pin_a=dp, pin_b=dm), *wait(bit_cycles)]
    program += [
        *action_line_drive(LINE_SE0, pin_a=dp, pin_b=dm),
        *wait(bit_cycles), *wait(bit_cycles),
        *action_line_drive(LINE_J, pin_a=dp, pin_b=dm),
        *wait(bit_cycles),
        *action_line_release(pin_a=dp, pin_b=dm), HALT,
    ]
    return program


# 1-Wire demo (logical pin 0, sim-scaled slot times, ratios preserved).
# Presence is reported via ARM/WAIT_EVENT + EVENT_STAMP (cause carries FALL);
# RX_PUSH carries the manual shifter byte, not the TX byte.
OW_PIN = 0
OW_RESET_LOW = 40
OW_SLOT = 12
OW_SLOT_GAP = 4
OW_READ_SAMPLE = 4


def onewire_write_read_program(*, pin: int = OW_PIN, flag: int = 4) -> list[int]:
    """1-Wire master demo: reset + presence detect, write byte, read one bit.

    Host preloads TX with [data_byte]. Presence (FALL while released) wakes
    WAIT_EVENT; a side-set marker on `flag` confirms it on the pins. The
    sampled read bit pushes as 0x80 when the bus reads high.
    """
    program = [
        gpio_oe(pin, 1),
        gpio_oe(flag, 1),
        gpio_write(pin, 0),
        gpio_write(flag, 0),
        *wait(OW_RESET_LOW),
        *arm_edges(rise_mask=0, fall_mask=1 << pin),
        gpio_oe(pin, 0),  # release; device presence pulls low
        *wait_event(EV_PIN_FALL),  # stall until presence observed
        *sideset(flag, 1),
        gpio_oe(pin, 1),
        TX_LOAD,  # data byte preloaded by host
    ]
    for _ in range(8):
        program += [
            shift_out(pin),
            *wait(OW_SLOT),
            gpio_write(pin, 1),
            *wait(OW_SLOT_GAP),
        ]
    program += [
        gpio_write(pin, 1),
        *wait(OW_SLOT_GAP),
        SHIFT_CLEAR,
        gpio_write(pin, 0),
        *wait(2),
        gpio_oe(pin, 0),  # release for read slot
        *wait(OW_READ_SAMPLE),
        shift_in(pin),
        *wait(OW_SLOT),
        RX_PUSH,
        HALT,
    ]
    return program

def manchester_tx_program(byte: int, *, pin: int = 0, half: int = 8) -> list[int]:
    """Manchester TX (IEEE: 1 = low-to-high): idle high, LSB-first."""
    program = [gpio_oe(pin, 1), gpio_write(pin, 1)]
    for bit in range(8):
        if (byte >> bit) & 1:
            program += [gpio_write(pin, 0), *wait(half), gpio_write(pin, 1), *wait(half)]
        else:
            program += [gpio_write(pin, 1), *wait(half), gpio_write(pin, 0), *wait(half)]
    program += [gpio_write(pin, 1), HALT]
    return program


def action_word(op: int, args: int = 0) -> int:
    """Pack a 16-bit action word: `{op[3:0], args[11:0]}`."""
    return ((op & 0xF) << 12) | (args & 0xFFF)


def action_gpio(*, pin: int, out: int | None = None, oe: int | None = None) -> int:
    """GPIO action: optional out and/or OE update on `pin`."""
    args = pin & 7
    if out is not None:
        args |= (1 << 9) | ((out & 1) << 8)
    if oe is not None:
        args |= (1 << 11) | ((oe & 1) << 10)
    return action_word(ACT_GPIO, args)


def action_delay(cycles: int) -> int:
    if not 0 <= cycles <= 0xFF:
        raise ValueError("action delay must fit in 8 bits")
    return action_word(ACT_DELAY, cycles)


def action_done() -> int:
    return action_word(ACT_DONE)


def action_pull_tx(bits: int = 8, msb_first: bool = True) -> int:
    """Region-local TX pop; PC holds until data is available."""
    if not 1 <= bits <= 16:
        raise ValueError("transfer width must be 1..16")
    return action_word(ACT_PULL, bits | (0x20 if msb_first else 0))


def action_push_rx(high: bool = False, shift: int = 0) -> int:
    """Region-local RX push; PC holds while the host RX FIFO is full."""
    if not 0 <= shift <= 7:
        raise ValueError("result shift must be 0..7")
    return action_word(ACT_PUSH, (1 if high else 0) | (shift << 1))


def action_target(slot: int, lane: int = 0) -> int:
    """Pack a two-lane action target: lane[4], slot[3:0]."""
    if lane not in (0, 1):
        raise ValueError("action lane must be 0 or 1")
    if not 0 <= slot < 16:
        raise ValueError("action slot must be 0..15")
    return (lane << 4) | slot


def prog_action(slot: int, word: int, lane: int = 0) -> list[int]:
    """Write an action slot, including its optional parallel lane."""
    return [
        ACTION_WR_LO,
        action_target(slot, lane),
        word & 0xFF,
        ACTION_WR_HI,
        action_target(slot, lane),
        (word >> 8) & 0xFF,
        *([ACTION_WR_LANE_LO, action_target(slot, lane), (word >> 16) & 0xFF,
           ACTION_WR_LANE_HI, action_target(slot, lane), (word >> 24) & 0xFF]
          if word >> 16 else []),
    ]


def action_parallel_gpio(pin: int, *, out: int | None = None,
                         oe: int | None = None, sample: bool = False,
                         lfsr: bool = False, count: bool = False,
                         delay: int = 0) -> int:
    """Encode the upper lane of a 32-bit action word."""
    lane = (1 << 15) | ((pin & 7) << 8)
    if out is not None:
        lane |= (1 << 12) | ((out & 1) << 11)
    if oe is not None:
        lane |= (1 << 14) | ((oe & 1) << 13)
    if sample:
        lane |= 1 << 7
    if lfsr:
        lane |= 1 << 6
    if count:
        lane |= 1 << 5
    if not 0 <= delay <= 31:
        raise ValueError("compound action delay must be 0..31")
    lane |= delay
    return lane << 16


def run_region(slot: int = 0, lane: int = 0) -> list[int]:
    return [RUN_REGION, action_target(slot, lane)]


def run_region_n(slot: int, count: int, lane: int = 0) -> list[int]:
    """Start region at `slot`; `count` is extra passes after the first."""
    if not 0 <= count <= 0xFF:
        raise ValueError("region repeat count must fit in 8 bits")
    return [RUN_REGION_N, action_target(slot, lane), count & 0xFF]


def wait_region() -> int:
    return WAIT_REGION


def read_result(rd: int, lane: int = 0) -> list[int]:
    return [READ_RESULT, (rd & 7) | ((lane & 1) << 7)]


def action_load_shift(data: int) -> list[int]:
    return [ACTION_LOAD_SHIFT, data & 0xFF]


def action_load_shift_hi(data: int) -> list[int]:
    return [ACTION_LOAD_SHIFT_HI, data & 0xFF]


def action_push_result(high: bool = False, shift: int = 0,
                       lane: int = 0) -> list[int]:
    if not 0 <= shift <= 7:
        raise ValueError("result byte shift must be 0..7")
    return [ACTION_PUSH_RESULT, (1 if high else 0) | (shift << 1) |
            ((lane & 1) << 7)]


def action_load_tx(bits: int = 8, msb_first: bool = True,
                   lane: int = 0) -> list[int]:
    if not 1 <= bits <= 16:
        raise ValueError("transfer width must be 1..16")
    return [ACTION_LOAD_TX, (bits & 0x1F) | (0x20 if msb_first else 0) |
            ((lane & 1) << 7)]


def action_gpio_pulse_program(*, pin: int = 0, delay: int = 4) -> list[int]:
    """Program a 3-slot region: OE+drive high, delay, done — then run/join."""
    region = [
        *prog_action(0, action_gpio(pin=pin, out=1, oe=1)),
        *prog_action(1, action_delay(delay)),
        *prog_action(2, action_done()),
    ]
    return [
        *region,
        *run_region(0),
        wait_region(),
        HALT,
    ]


def action_shift(*, pin: int, shift_in: bool = False, msb_first: bool = False,
                 rx_pin: int = 0, duplex: bool = False,
                 open_drain: bool = False, stream: bool = False) -> int:
    """SHIFT with optional duplex I/O and automatic byte FIFO streaming."""
    args = ((pin & 7) | ((rx_pin & 7) << 4) |
            ((1 if stream else 0) << 7) |
            ((1 if open_drain else 0) << 8) |
            ((1 if duplex else 0) << 9) |
            ((1 if msb_first else 0) << 10) |
            ((1 if shift_in else 0) << 11))
    return action_word(ACT_SHIFT, args)


def action_count_load(value: int) -> int:
    return action_word(ACT_COUNT, ((0b00) << 10) | (value & 0xFF))


def action_count_djnz(target_slot: int) -> int:
    return action_word(ACT_COUNT, ((0b11) << 10) | (target_slot & 0xF))


def action_sample(pin: int) -> int:
    return action_word(ACT_SAMPLE, pin & 7)


def action_shift_out_byte_program(
    data: int, *, pin: int = 0, half: int = 2
) -> list[int]:
    """Shift out 8 LSB-first bits via action region (SPI-shaped without bit-xfer)."""
    # slots: 0 COUNT_LOAD 8, 1 SHIFT out, 2 DELAY, 3 DJNZ ->1, 4 DONE
    region = [
        *prog_action(0, action_count_load(8)),
        *prog_action(1, action_shift(pin=pin, shift_in=False, msb_first=False)),
        *prog_action(2, action_delay(half)),
        *prog_action(3, action_count_djnz(1)),
        *prog_action(4, action_done()),
    ]
    return [
        *action_load_shift(data),
        *region,
        *run_region(0),
        wait_region(),
        HALT,
    ]


def action_overlap_program(*, action_pin: int = 0, cpu_pin: int = 1, delay: int = 40) -> list[int]:
    """CPU toggles cpu_pin while action region holds action_pin high."""
    region = [
        *prog_action(0, action_gpio(pin=action_pin, out=1, oe=1)),
        *prog_action(1, action_delay(delay)),
        *prog_action(2, action_done()),
    ]
    return [
        gpio_oe(cpu_pin, 1),
        gpio_write(cpu_pin, 0),
        *region,
        *run_region(0),
        gpio_write(cpu_pin, 1),  # overlaps with running region
        wait_region(),
        HALT,
    ]


def action_repeat_n_program(*, pin: int = 0, extras: int = 2, pulse: int = 3) -> list[int]:
    """RUN_REGION_N: first pass + `extras` repeats; each pass pulses pin."""
    region = [
        *prog_action(0, action_gpio(pin=pin, out=1, oe=1)),
        *prog_action(1, action_delay(pulse)),
        *prog_action(2, action_gpio(pin=pin, out=0, oe=1)),
        *prog_action(3, action_delay(pulse)),
        *prog_action(4, action_done()),
    ]
    return [
        *region,
        *run_region_n(0, extras),
        wait_region(),
        HALT,
    ]


def action_read_result_program(*, sample_pin: int = 2, marker_pin: int = 3) -> list[int]:
    """READ_RESULT immediately after launch waits and forwards final result."""
    region = [
        *prog_action(0, action_sample(sample_pin)),
        *prog_action(1, action_done()),
    ]
    prefix = [
        gpio_oe(marker_pin, 1),
        gpio_write(marker_pin, 0),
        *region,
        *run_region(0),
        *read_result(0),
    ]
    # layout: prefix | JNZ(3) | HALT | gpio_write | HALT
    marker_addr = len(prefix) + 3 + 1
    return [
        *prefix,
        *jump_if_not_zero(marker_addr),
        HALT,
        gpio_write(marker_pin, 1),
        HALT,
    ]


def action_sample_acc(pin: int, *, msb_first: bool) -> int:
    return action_word(ACT_SAMPLE, (1 << 11) | ((1 if msb_first else 0) << 10) | (pin & 7))


def action_count_djnz_done(target_slot: int) -> int:
    return action_word(ACT_COUNT, (0b11 << 10) | (1 << 9) |
                       (target_slot & 0xF))


def action_clocked_transfer(
    *, clk_pin: int, tx_pin: int, rx_pin: int, bit_count: int,
    half_period: int, msb_first: bool = True, clk_idle: int = 0,
    sample_phase: int = 0, tx_open_drain: bool = False,
    clk_open_drain: bool = False, wait_clk_high: bool = False,
) -> list[int]:
    """Compile a clocked transfer to eight generic action slots and launch it."""
    if not 1 <= bit_count <= 16:
        raise ValueError("bit_count must be 1..16")
    if not 0 <= half_period <= 0xFF:
        raise ValueError("half_period must fit in 8 bits")
    period = max(1, half_period)
    idle_oe = 0 if clk_open_drain and clk_idle else 1
    active_oe = 0 if clk_open_drain and not clk_idle else 1
    idle_out = 0 if clk_open_drain else clk_idle
    active_out = 0 if clk_open_drain else 1 - clk_idle
    # COUNT, launch data/idle clock, setup time, active clock, hold time,
    # sample RX, idle clock, loop-or-done. Data and clock change in parallel.
    region = [
        action_count_load(bit_count),
        action_shift(pin=tx_pin, msb_first=msb_first,
                     open_drain=tx_open_drain) |
            action_parallel_gpio(clk_pin, out=idle_out, oe=idle_oe),
        action_delay(period),
        action_parallel_gpio(clk_pin, out=active_out, oe=active_oe),
        action_word(ACT_DELAY, period | ((1 << 11) | ((clk_pin & 7) << 8)
                                  if wait_clk_high else 0)),
        action_sample_acc(rx_pin, msb_first=msb_first) |
            (action_parallel_gpio(clk_pin, out=idle_out, oe=idle_oe)
             if sample_phase else 0),
        action_parallel_gpio(clk_pin, out=idle_out, oe=idle_oe)
            if not sample_phase else action_word(ACT_NOP),
        action_count_djnz_done(1),
    ]
    program = []
    for slot, word in enumerate(region):
        program += prog_action(slot, word)
    program += [*action_load_tx(bit_count, msb_first), *run_region(0)]
    return program


def action_line_drive(state: int, *, pin_a: int = DP_PIN,
                      pin_b: int = DM_PIN, jk_swap: bool = False) -> list[int]:
    a, b = {
        LINE_SE0: (0, 0), LINE_J: (0, 1),
        LINE_K: (1, 0), LINE_SE1: (1, 1),
    }[state]
    if jk_swap and state in (LINE_J, LINE_K):
        a, b = b, a
    return [
        *prog_action(0, action_gpio(pin=pin_a, out=a, oe=1) |
                     action_parallel_gpio(pin_b, out=b, oe=1)),
        *prog_action(1, action_done()),
        *run_region(0), wait_region(),
    ]


def action_line_release(*, pin_a: int = DP_PIN,
                        pin_b: int = DM_PIN) -> list[int]:
    return [
        *prog_action(0, action_gpio(pin=pin_a, oe=0) |
                     action_parallel_gpio(pin_b, oe=0)),
        *prog_action(1, action_done()),
        *run_region(0), wait_region(),
    ]


def action_line_sample(*, pin_a: int = DP_PIN, pin_b: int = DM_PIN,
                       jk_swap: bool = False) -> list[int]:
    pair = action_word(0xA, (pin_a & 7) | ((pin_b & 7) << 3) |
                            ((1 if jk_swap else 0) << 6))
    return [
        *prog_action(0, pair), *prog_action(1, action_done()),
        *run_region(0), wait_region(), *action_push_result(),
    ]

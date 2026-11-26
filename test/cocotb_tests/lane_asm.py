"""Assembler for the lane controller (src/grid_lane_controller.v).

One instruction per line, optionally after `label:`; `#` comments. Operands are numbers
or labels. Instructions are 16 bits {op[3:0], arg[11:0]}, stored
little-endian in SRAM; `program_bytes` returns the SRAM image.

    NOP HALT FAIL CLEAR SHIFT PULL PUSH ATOC CTOA     (op 0, no operand)
    WAIT e     e 0-7 latched pulse event, 8-15 live level
    ACT  a     action levels
    FIRE       start pulse
    LDI k  RD r  AND k  XOR k  ADD k
    J t  JZ t  JNZ t  LOOP t
    SETC k     WCFG addr
"""

SYS = {'NOP': 0, 'HALT': 1, 'FAIL': 2, 'CLEAR': 3, 'SHIFT': 4, 'PULL': 5, 'PUSH': 6, 'ATOC': 7, 'CTOA': 8}
OPS = {'WAIT': 1, 'ACT': 2, 'FIRE': 3, 'LDI': 4, 'RD': 5, 'AND': 6, 'XOR': 7, 'ADD': 8,
       'J': 9, 'JZ': 10, 'JNZ': 11, 'LOOP': 12, 'SETC': 13, 'WCFG': 14}
NO_OPERAND = {'FIRE'}
LIMIT = {'WAIT': 15, 'ACT': 15, 'RD': 15, 'SETC': 255, 'WCFG': 255}
MAX_INSTRUCTIONS = 64

# Event and level numbers as wired in grid_stream_fabric.v.
EV_TICK0, EV_SHIFT0_DONE, EV_EDGE0, EV_EDGE1, EV_SHIFT1_DONE, EV_SINK41, EV_SINK42, EV_LANE_B_DONE = range(8)
LV_PIN0, LV_PIN1, LV_PIN0_LOW, LV_PIN1_LOW, LV_STREAM_BYTE, LV_STREAM_EMPTY, LV_SHIFT0_BUSY, LV_SHIFT1_BUSY = range(8, 16)
RB_RX0, RB_RX1, RB_PINS, RB_STREAM_LEFT, RB_RX_WRITTEN, RB_STATUS = range(6)


def assemble(source):
    lines = []
    labels = {}
    for raw in source.splitlines():
        text = raw.split('#', 1)[0].strip()
        if not text:
            continue
        while ':' in text:
            label, text = text.split(':', 1)
            if label.strip() in labels:
                raise ValueError(f'label {label.strip()!r} defined twice')
            labels[label.strip()] = len(lines)
            text = text.strip()
        if text:
            lines.append(text.split())
    words = []
    for index, parts in enumerate(lines):
        name = parts[0].upper()
        if name in SYS:
            if len(parts) != 1:
                raise ValueError(f'{name} takes no operand')
            words.append(SYS[name])
            continue
        if name not in OPS:
            raise ValueError(f'unknown instruction {parts[0]!r}')
        if name in NO_OPERAND:
            words.append(OPS[name] << 12)
            continue
        if len(parts) != 2:
            raise ValueError(f'{name} takes one operand')
        token = parts[1]
        value = labels[token] if token in labels else int(token, 0)
        if not 0 <= value <= LIMIT.get(name, 0xFFF):
            raise ValueError(f'{name} operand {value} out of range')
        words.append(OPS[name] << 12 | value)
    if not 1 <= len(words) <= MAX_INSTRUCTIONS:
        raise ValueError(f'{len(words)} instructions; the lane buffer holds 1..{MAX_INSTRUCTIONS}')
    return words


def program_bytes(words):
    return [b for w in words for b in (w & 255, w >> 8)]


def program_word(base, words):
    """Configuration word 95: {last instruction index, base}."""
    if not 0 <= base < 1024:
        raise ValueError('program base is a 10-bit host-bank address')
    return (len(words) - 1) << 10 | base

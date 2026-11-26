"""Assembler for the lane controller (src/grid_lane_controller.v), and the
lane core's page-1 words for tests that write programs directly.

One instruction per line, optionally after `label:`; `#` comments. Operands are numbers
or labels. Instructions are 16 bits {op[3:0], arg[11:0]}, stored
little-endian in SRAM; `program_bytes` returns the SRAM image.

    NOP HALT FAIL CLEAR SHIFT PULL PUSH ATOC CTOA SHL SHR   (op 0, no operand)
    WAIT e     e 0-7 latched pulse event, 8-15 live level
    ACT  a     action levels
    FIRE       start pulse
    LDI k  RD r  AND k  XOR k  ADD k
    J t  JZ t  JNZ t  LOOP t
    SETC k     WCFG addr
    WANY m     wait for any latched pulse event in mask m (A = the set bits)
"""

import json
from pathlib import Path

SYS = {'NOP': 0, 'HALT': 1, 'FAIL': 2, 'CLEAR': 3, 'SHIFT': 4, 'PULL': 5, 'PUSH': 6, 'ATOC': 7, 'CTOA': 8,
       'SHL': 9, 'SHR': 10}
OPS = {'WAIT': 1, 'ACT': 2, 'FIRE': 3, 'LDI': 4, 'RD': 5, 'AND': 6, 'XOR': 7, 'ADD': 8,
       'J': 9, 'JZ': 10, 'JNZ': 11, 'LOOP': 12, 'SETC': 13, 'WCFG': 14, 'WANY': 15}
NO_OPERAND = {'FIRE'}
LIMIT = {'WAIT': 15, 'ACT': 15, 'RD': 15, 'SETC': 255, 'WCFG': 255, 'WANY': 255}
MAX_INSTRUCTIONS = 64

# Lane core (src/grid_lane_core.v): lines, selectors and words come from the
# contract's lane_core section (architecture/grid_5x3.json), which
# tools/check_grid_contract.py checks against the RTL.
_CONTRACT = json.loads((Path(__file__).resolve().parents[2] / 'architecture/grid_5x3.json').read_text())
CORE = _CONTRACT['lane_core']
LANE = _CONTRACT['lane']
LINES = {name: index for index, name, _ in CORE['lines']}
READBACK = {name: index for index, name in enumerate(CORE['readback'])}
CORE_PAGE = LANE['core_page'] << 8   # host configuration address of core word 0


def core_words(program_words, base, connect=None, words=None, idle_actions=0):
    """Page-1 configuration {host address: value} for lane 0's core: the
    selectors in `connect` ({selector: line name}), raw `words` ({core
    word: value}), the program word and the idle actions. Every core word is
    written, so nothing is left from an earlier configuration."""
    out = [0] * CORE['words']
    for index, value in (words or {}).items():
        out[index] = value
    selectors = {name: (word, bits, kind) for name, word, bits, kind in CORE['selectors']}
    for selector, line in (connect or {}).items():
        word, (hi, lo), kind = selectors[selector]
        value = LINES[line] - (CORE['level_lines'][0] if kind == 'level' else 0)
        out[word] |= value << lo
        if selector in CORE['gate_enables']:
            gate_word, gate_bit = CORE['gate_enables'][selector]
            out[gate_word] |= 1 << gate_bit
    out[LANE['program_word']] = program_word(base, program_words)
    hi, lo = LANE['idle_actions_bits']
    out[LANE['idle_actions_word']] |= idle_actions << lo
    return {CORE_PAGE + i: v for i, v in enumerate(out)}


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
    """The lane program word (core word 36): {last instruction index, base}."""
    if not 0 <= base < 1024:
        raise ValueError('program base is a 10-bit host-bank address')
    return (len(words) - 1) << 10 | base

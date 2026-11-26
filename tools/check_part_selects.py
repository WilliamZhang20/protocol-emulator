#!/usr/bin/env python3
"""Fail on indexed part-selects whose base depends on a run-time signal.

`x[base +: w]` with a signal in `base` asks synthesis to build a shifter
from an arithmetic expression. One flow got that wrong: the page loader's
`ctx_buf[(got-33)*8 +: 16]` lost its scale at gate level (words written 2
bits apart instead of 16), while RTL simulation and a generic yosys run
were correct. The rule, by construction: a part-select base may use only
constants, parameters, genvars and loop variables (unrolled, so constant);
a run-time choice is an array index (`words[sel]`) or a shift register.
"""
import re
import sys
from pathlib import Path

PART = re.compile(r'\[([^\[\]]*?)([+-]):')
IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_$]*\b")
CONST_DECL = re.compile(r'\b(?:genvar|parameter|localparam|integer)\b([^;]*);')
FOR_VAR = re.compile(r'\bfor\s*\(\s*(?:integer\s+|genvar\s+)?([A-Za-z_]\w*)\s*=')


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def constants(text):
    names = set()
    for decl in CONST_DECL.findall(text):
        decl = re.sub(r'\[[^\]]*\]', '', decl)
        for part in decl.split(','):
            m = re.match(r'\s*(?:\[[^\]]*\]\s*)?(?:signed\s+)?([A-Za-z_]\w*)', part)
            if m:
                names.add(m.group(1))
    names.update(FOR_VAR.findall(text))
    return names


def check(path):
    text = strip_comments(Path(path).read_text())
    ok = constants(text)
    problems = []
    for line_no, line in enumerate(text.splitlines(), 1):
        for m in PART.finditer(line):
            base = m.group(1)
            # Sized literals (8'd3, 4'b0) and system functions are constants.
            names = [n for n in IDENT.findall(re.sub(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ]+", '', base))
                     if not n.startswith('$')]
            bad = [n for n in names if n not in ok]
            if bad:
                problems.append(f'{path}:{line_no}: part-select base uses signal(s) {", ".join(sorted(set(bad)))}: '
                                f'[{base}{m.group(2)}:...]; use an array index or a shift register')
    return problems


def main(paths):
    problems = [p for path in paths for p in check(path)]
    for p in problems:
        print(p)
    if problems:
        print(f'{len(problems)} run-time part-select base(s); see tools/check_part_selects.py')
        return 1
    print(f'part-select bases: {len(paths)} files, all constant')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

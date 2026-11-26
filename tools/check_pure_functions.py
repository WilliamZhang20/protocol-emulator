#!/usr/bin/env python3
"""Fail on functions that read module signals instead of their arguments.

A continuous assignment (`wire x = f(a, b);`) is re-evaluated when its
operands change; a function that reads a module signal directly hides that
signal from the assignment's sensitivity. Event-driven simulators then keep
a stale value: in the lane core, the coded shifter's `bit_hold` stayed X
after configuration because `index` and `tx_word` sat at their reset values
while the frame registers the function read were written later. Synthesis
and verilator are unaffected, so only simulation lies, and only sometimes.

The rule, by construction: a function body may use only its arguments, its
own local variables, its own name, and parameters/localparams/genvars. Pass
anything else in (a packed bundle keeps call sites short).
"""
import re
import sys
from pathlib import Path

IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_$]*\b")
FUNC = re.compile(r'\bfunction\b(.*?)\bendfunction\b', re.S)
CONST_DECL = re.compile(r'\b(?:genvar|parameter|localparam)\b([^;]*);')
LOCAL_DECL = re.compile(r'\b(?:input|reg|integer|logic|bit)\b([^;]*?)(?:;|\)|,\s*input\b)')
KEYWORDS = set('''
automatic signed unsigned input reg integer logic bit begin end if else case casez casex endcase
default for while repeat function endfunction or and not
'''.split())


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def strip_literals(text):
    text = re.sub(r'"[^"]*"', '', text)
    return re.sub(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+", '0', text)


def declared_names(decl):
    decl = re.sub(r'\[[^\]]*\]', '', decl)
    names = set()
    for part in decl.split(','):
        part = re.sub(r'\b(?:input|reg|integer|logic|bit|signed|unsigned|automatic)\b', '', part)
        m = re.match(r'\s*([A-Za-z_]\w*)', part)
        if m:
            names.add(m.group(1))
    return names


def constants(text):
    names = set()
    for decl in CONST_DECL.findall(text):
        for part in re.sub(r'\[[^\]]*\]', '', decl).split(','):
            m = re.match(r'\s*(?:integer\s+|signed\s+)?([A-Za-z_]\w*)', part)
            if m:
                names.add(m.group(1))
    # Header parameter lists: #(parameter A=1, parameter B=A+1)
    names.update(re.findall(r'\b(?:parameter|localparam|genvar)\s+(?:\[[^\]]*\]\s*)?'
                            r'(?:integer\s+|signed\s+)?([A-Za-z_]\w*)', text))
    return names


def check(path):
    text = strip_literals(strip_comments(Path(path).read_text()))
    consts = constants(text)
    problems = []
    for m in FUNC.finditer(text):
        body = m.group(1)
        line_no = text[:m.start()].count('\n') + 1
        header = re.match(r'\s*(?:automatic\s+)?(?:signed\s+)?(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)', body)
        name = header.group(1)
        local = {name}
        for decl in LOCAL_DECL.findall(body):
            local |= declared_names(decl)
        # Header-style ports: function f(input [3:0] a, input b);
        paren = re.match(r'\s*(?:automatic\s+)?(?:signed\s+)?(?:\[[^\]]*\]\s*)?\w+\s*\(([^)]*)\)', body)
        if paren:
            for port in re.split(r',\s*(?=input\b)', paren.group(1)):
                local |= declared_names(port)
        used = {n for n in IDENT.findall(body) if not n.startswith('$')}
        bad = sorted(used - local - consts - KEYWORDS)
        if bad:
            problems.append(f'{path}:{line_no}: function {name} reads module signal(s) {", ".join(bad)}; '
                            'pass them as arguments')
    return problems


def main(paths):
    problems = [p for path in paths for p in check(path)]
    for p in problems:
        print(p)
    if problems:
        print(f'{len(problems)} impure function(s)')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

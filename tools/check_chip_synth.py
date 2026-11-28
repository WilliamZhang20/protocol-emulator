#!/usr/bin/env python3
"""The chip's synthesis checks, as LibreLane's Checker.YosysSynthChecks runs
them, with one rule of our own for combinational loops.

The actor chip's mesh has structural combinational loops: a control actor's
outputs are combinational selections of its inputs (mesh_logic, ACTOR=1),
and a route can carry an actor's output back to an actor's input. No
configuration closes one (the compiler's mapper refuses it), so LibreLane's
loop error is switched off (src/config.json ERROR_ON_SYNTH_CHECKS 0) and
this check takes its place:

- every other problem `check` reports fails (an undriven wire, a multiply
  driven one: the class of 5dd1a72's GDS failure);
- every loop must pass through an actor's selection (a cell under a
  mesh_logic `actor` block). The tracks cannot form a loop (their turn rule
  makes them a DAG) and every other cell output is a register, so a loop
  anywhere else is a design error.

Usage: check_chip_synth.py [yosys]
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'


def main(yosys):
    # info.yaml's source_files list (no YAML library needed).
    info = (ROOT / 'info.yaml').read_text()
    block = info.split('source_files:', 1)[1]
    sources = []
    for line in block.splitlines()[1:]:
        m = re.match(r'\s*-\s*"?([^"#\s]+)"?', line)
        if m:
            sources.append(m.group(1))
        elif line.strip() and not line.strip().startswith('#'):
            break
    files = ' '.join(str(SRC / f) for f in sources)
    script = (f'read_verilog -lib {ROOT}/tools/blackbox/sg13cmos5l_dlhrq_1.v; '
              f'read_verilog -lib {SRC}/RM_IHPSG13_1P_1024x8_c2_bm_bist.v; '
              f'read_verilog -sv -D__librelane__ {files}; '
              'hierarchy -check -top tt_um_protocol_emulator; proc; flatten; opt_clean; check')
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / 'check.log'
        subprocess.run([yosys, '-q', '-l', str(log), '-p', script], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        text = log.read_text()
    loops, other = [], []
    blocks = re.split(r'\n(?=Warning: )', text)
    for b in blocks:
        if not b.startswith('Warning: '):
            continue
        if b.startswith('Warning: found logic loop'):
            loops.append(b)
        elif 'Found and reported' not in b:
            other.append(b.splitlines()[0])
    bad_loops = [b for b in loops if not re.search(r'\.lg\.t\.actor\.|\\actor\b|actor\.', b)]
    print(f'chip synthesis check: {len(loops)} loops (each must pass an actor selection), '
          f'{len(other)} other problems')
    for w in other[:20]:
        print('  ' + w)
    for b in bad_loops[:5]:
        print('  loop without an actor:\n' + '\n'.join('    ' + l for l in b.splitlines()[:12]))
    if other or bad_loops:
        sys.exit('chip synthesis check FAILED')
    print('chip synthesis check: PASS')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'yosys')

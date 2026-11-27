#!/usr/bin/env python3
"""How many switch selectors change between contexts (single-protocol
study, FABRIC_REORG.md "One protocol owns the fabric", measurement 1).

For every compiled program of a contract (compiled/NAME.CONTRACT.hex, the
configuration vector as 32-bit words, least significant first), decode
each contexted cell's switch (mesh.v / ctx_switch.v layout):
  [0,192)   tracks: context c at [48c +: 48], 16 selectors x 3 bits
            ({east, west, south, north} x tracks 0-3);
  [192,312) sinks:  context c at [30c +: 30], 6 selectors x 5 bits;
  [312,368) transitions: context c at [14c +: 14],
            {B next[13:12], B ev[11:7], A next[6:5], A ev[4:0]}.
Only the contexts reachable from context 0 through transition rows with a
non-zero event count. A selector is
  used     if it is non-zero in some reachable context;
  dynamic  if its value differs between two reachable contexts.

  python3 context_study.py [CONTRACT] [--compiled DIR] [--json OUT]
"""
import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
CELL_BITS, TRACK_LSB, SINK_LSB, TRANS_LSB = 512, 0, 192, 312
DIRS = ('north', 'south', 'west', 'east')


def vector(hexfile):
    words = [int(w, 16) for w in hexfile.read_text().split()]
    return sum(w << (32 * i) for i, w in enumerate(words))


def field(v, lsb, width):
    return (v >> lsb) & ((1 << width) - 1)


def param(s):
    width, val = s.split("'d")
    return int(val), int(width)


def study(contract, compiled=HERE / 'compiled'):
    rows = cols = None
    out = {}
    for mj in sorted(compiled.glob(f'*.{contract}.mesh.json')):
        prog = mj.name.split('.')[0]
        p = json.loads(mj.read_text())['params']
        rows, cols = p['ROWS'], p['COLS']
        n = rows * cols
        ctx4, _ = param(p['CTX4'])
        logic, _ = param(p.get('LOGIC', "1'd0"))
        v = vector(compiled / f'{prog}.{contract}.hex')
        cells = {}
        for c in range(n):
            if not (ctx4 >> c) & 1 or (logic >> c) & 1:
                continue
            base = c * CELL_BITS
            trans = [field(v, base + TRANS_LSB + 14 * k, 14) for k in range(4)]
            reach, todo = {0}, [0]
            while todo:
                k = todo.pop()
                for ev, nxt in ((trans[k] & 31, (trans[k] >> 5) & 3), ((trans[k] >> 7) & 31, (trans[k] >> 12) & 3)):
                    if ev and nxt not in reach:
                        reach.add(nxt)
                        todo.append(nxt)
            reach = sorted(reach)
            sels = {}
            for d in range(4):
                for t in range(4):
                    sels[f'{DIRS[d]}{t}'] = [field(v, base + TRACK_LSB + 48 * k + 12 * d + 3 * t, 3) for k in reach]
            for s in range(6):
                sels[f'sink{s}'] = [field(v, base + SINK_LSB + 30 * k + 5 * s, 5) for k in reach]
            used = [k for k, vals in sels.items() if any(vals)]
            dyn = [k for k, vals in sels.items() if len(set(vals)) > 1]
            cells[c] = {'contexts': len(reach), 'used': used, 'dynamic': dyn,
                        'dynamic_tracks': [k for k in dyn if not k.startswith('sink')],
                        'dynamic_sinks': [k for k in dyn if k.startswith('sink')]}
        out[prog] = cells
    return out, rows, cols


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('contract', nargs='?', default='mesh_3x5_L3')
    ap.add_argument('--json', type=Path)
    ap.add_argument('--compiled', type=Path, default=HERE / 'compiled', help='directory of compiled programs')
    a = ap.parse_args()
    res, rows, cols = study(a.contract, a.compiled)
    print(f'{a.contract}: per program, over contexted cells (not logic):')
    print(f'{"program":40s} {"multi-ctx cells":>15s} {"used sel":>9s} {"dynamic":>8s} {"dyn trk":>8s} {"dyn sink":>9s} {"max ctx":>8s}')
    tot = {'cells': 0, 'used': 0, 'dyn': 0, 'dt': 0, 'ds': 0}
    for prog, cells in res.items():
        multi = [c for c, x in cells.items() if x['contexts'] > 1]
        used = sum(len(x['used']) for x in cells.values())
        dyn = sum(len(x['dynamic']) for x in cells.values())
        dt = sum(len(x['dynamic_tracks']) for x in cells.values())
        ds = sum(len(x['dynamic_sinks']) for x in cells.values())
        mx = max((x['contexts'] for x in cells.values()), default=1)
        print(f'{prog:40s} {len(multi):>15d} {used:>9d} {dyn:>8d} {dt:>8d} {ds:>9d} {mx:>8d}')
        for k, v in (('cells', len(multi)), ('used', used), ('dyn', dyn), ('dt', dt), ('ds', ds)):
            tot[k] = max(tot[k], v)
    # Per cell: the largest number of dynamic selectors any program needs there.
    per_cell = {}
    for cells in res.values():
        for c, x in cells.items():
            pc = per_cell.setdefault(c, {'dyn': 0, 'dt': 0, 'ds': 0, 'ctx': 1, 'progs': 0})
            pc['dyn'] = max(pc['dyn'], len(x['dynamic']))
            pc['dt'] = max(pc['dt'], len(x['dynamic_tracks']))
            pc['ds'] = max(pc['ds'], len(x['dynamic_sinks']))
            pc['ctx'] = max(pc['ctx'], x['contexts'])
            pc['progs'] += x['contexts'] > 1
    print('\nper contexted cell (row, col): worst case over programs')
    print(f'{"cell":>10s} {"programs using >1 ctx":>22s} {"max ctx":>8s} {"max dyn":>8s} {"trk":>4s} {"sink":>5s}  (of 16 track + 6 sink selectors)')
    for c, pc in sorted(per_cell.items()):
        print(f'{f"{c // cols},{c % cols}":>10s} {pc["progs"]:>22d} {pc["ctx"]:>8d} {pc["dyn"]:>8d} {pc["dt"]:>4d} {pc["ds"]:>5d}')
    if a.json:
        a.json.write_text(json.dumps({'contract': a.contract, 'programs': res, 'per_cell': per_cell}, indent=1) + '\n')


if __name__ == '__main__':
    main()

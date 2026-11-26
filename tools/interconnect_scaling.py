#!/usr/bin/env python3
"""Interconnect area as lanes are added: this fabric's switch-box mesh
against the earlier fabric's (arch/spatial) 64-wire signal space.

Both interconnects connect the same tiles. A lane is one grid row: 4
cells, 16 tile outputs (4 per cell) and 14 tile-input selectors (the
current grid's average per row). For N lanes:

  mesh          4N grid_switch instances (src/grid_switch.v, 4 tracks per
                direction, unregistered hops), each with its 48 selector
                bits, plus 14N 22:1 sink selectors (5 bits each) reading
                their cell's local outputs and the four incoming tracks.
  signal space  16N tile outputs + 18 shared lines (constants, controller
                pulses and flags, 8 pin levels and edges) = L lines, each a
                register (arch/spatial's one-hop-per-cycle rule); 14N L:1
                selectors with ceil(log2 L) bits each.

Configuration bits are flops on a scan chain in both, so the comparison
is interconnect logic plus its configuration storage. Synthesized with
yosys and the IHP liberty; tile logic is excluded (it is the same in both).
"""
import argparse
import json
import math
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COLS, OUTS_PER_CELL, SINKS_PER_LANE = 4, 4, 14
SHARED_LINES = 18
SINKS_PER_CELL = [4, 4, 3, 3]


def scan_chain(bits, name):
    return (f"  reg [{bits - 1}:0] {name};\n"
            f"  always @(posedge clk) {name} <= {{{name}[{bits - 2}:0], {name}_in}};\n" if bits > 1 else
            f"  reg [0:0] {name};\n  always @(posedge clk) {name} <= {name}_in;\n")


def mesh(lanes):
    rows, cells = lanes, lanes * COLS
    sinks = lanes * SINKS_PER_LANE
    cfg_bits = cells * 48 + sinks * 5
    v = [f"module mesh_{lanes}(input wire clk, input wire cfg_in, input wire [{cells * OUTS_PER_CELL - 1}:0] tile_out,",
         f"  output wire [{sinks - 1}:0] sink);",
         scan_chain(cfg_bits, 'cfg').replace('cfg_in', 'cfg_in'),
         f"  wire [3:0] n_out[0:{cells - 1}], s_out[0:{cells - 1}], w_out[0:{cells - 1}], e_out[0:{cells - 1}];"]
    for c in range(cells):
        r, col = divmod(c, COLS)
        def nb(rr, cc, port):
            return f"{port}[{rr * COLS + cc}]" if 0 <= rr < rows and 0 <= cc < COLS else "4'b0"
        n_in, s_in = nb(r - 1, col, 's_out'), nb(r + 1, col, 'n_out')
        w_in, e_in = nb(r, col - 1, 'e_out'), nb(r, col + 1, 'w_out')
        base = c * 48
        v.append(f"  grid_switch sw{c}({n_in}, {s_in}, {w_in}, {e_in}, tile_out[{c * 4 + 3}:{c * 4}],"
                 f" cfg[{base + 11}:{base}], cfg[{base + 23}:{base + 12}], cfg[{base + 35}:{base + 24}], cfg[{base + 47}:{base + 36}],"
                 f" n_out[{c}], s_out[{c}], w_out[{c}], e_out[{c}]);")
        v.append(f"  wire [3:0] n_in{c} = {n_in}, s_in{c} = {s_in}, w_in{c} = {w_in}, e_in{c} = {e_in};")
        v.append(f"  wire [21:0] choices{c} = {{e_in{c}, w_in{c}, s_in{c}, n_in{c}, tile_out[{c * 4 + 3}:{c * 4}], 2'b10}};")
    index = 0
    for lane in range(lanes):
        for col, count in enumerate(SINKS_PER_CELL):
            c = lane * COLS + col
            for _ in range(count):
                sel = f"cfg[{cells * 48 + index * 5 + 4}:{cells * 48 + index * 5}]"
                v.append(f"  assign sink[{index}] = {sel} < 22 ? choices{c}[{sel}] : 1'b0;")
                index += 1
    v.append("endmodule")
    return '\n'.join(v), cfg_bits


def signal_space(lanes):
    lines = lanes * COLS * OUTS_PER_CELL + SHARED_LINES
    sel_bits = math.ceil(math.log2(lines))
    sinks = lanes * SINKS_PER_LANE
    cfg_bits = sinks * sel_bits
    v = [f"module space_{lanes}(input wire clk, input wire cfg_in, input wire [{lines - 1}:0] sources,",
         f"  output wire [{sinks - 1}:0] sink);",
         scan_chain(cfg_bits, 'cfg'),
         f"  reg [{lines - 1}:0] line;",
         "  always @(posedge clk) line <= sources;   // every line is a register output"]
    for i in range(sinks):
        sel = f"cfg[{i * sel_bits + sel_bits - 1}:{i * sel_bits}]"
        v.append(f"  assign sink[{i}] = {sel} < {lines} ? line[{sel}] : 1'b0;")
    v.append("endmodule")
    return '\n'.join(v), cfg_bits, lines


def area(yosys, liberty, top, text, extra_sources):
    with tempfile.TemporaryDirectory(prefix='interconnect-') as tmp:
        path = Path(tmp) / f'{top}.v'
        path.write_text(text + '\n')
        script = (f"read_verilog {' '.join(str(s) for s in extra_sources)} {path}; hierarchy -top {top}; "
                  f"synth -top {top} -flatten; dfflibmap -liberty {liberty}; abc -liberty {liberty}; "
                  f"opt_clean; stat -liberty {liberty}")
        log = Path(tmp) / 'yosys.log'
        subprocess.run([yosys, '-q', '-l', str(log), '-p', script], capture_output=True, text=True, check=True)
        out = log.read_text()
        found = re.findall(r'Chip area for (?:top )?module.*?:\s*([0-9.]+)', out)
        if not found:
            raise RuntimeError(out[-2000:])
        return float(found[-1])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--yosys', default='yosys')
    p.add_argument('--liberty', required=True)
    p.add_argument('--lanes', default='1,3,5')
    p.add_argument('--json', type=Path)
    args = p.parse_args()
    rows = []
    for n in [int(x) for x in args.lanes.split(',')]:
        mtext, mbits = mesh(n)
        stext, sbits, lines = signal_space(n)
        rows.append({'lanes': n,
                     'mesh_um2': area(args.yosys, args.liberty, f'mesh_{n}', mtext, [ROOT / 'src/grid_switch.v']),
                     'mesh_cfg_bits': mbits,
                     'space_um2': area(args.yosys, args.liberty, f'space_{n}', stext, []),
                     'space_cfg_bits': sbits, 'space_lines': lines})
    print('| Lanes | Mesh (um2) | Mesh cfg bits | Signal space lines | Signal space (um2) | Signal space cfg bits | Space / mesh |')
    print('|---|---|---|---|---|---|---|')
    for r in rows:
        print(f"| {r['lanes']} | {r['mesh_um2']:,.0f} | {r['mesh_cfg_bits']} | {r['space_lines']} | "
              f"{r['space_um2']:,.0f} | {r['space_cfg_bits']} | {r['space_um2'] / r['mesh_um2']:.2f} |")
    for a, b in zip(rows, rows[1:]):
        dn = b['lanes'] - a['lanes']
        print(f"per added lane, {a['lanes']}->{b['lanes']}: mesh {(b['mesh_um2'] - a['mesh_um2']) / dn:,.0f} um2, "
              f"signal space {(b['space_um2'] - a['space_um2']) / dn:,.0f} um2")
    if args.json:
        args.json.write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    main()

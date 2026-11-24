#!/usr/bin/env python3
"""Synthesize isolated configurable-switch proxies with an IHP liberty file."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def verilog(width, registered):
    direction = [('north', 'south', 'west', 'east'), ('south', 'north', 'west', 'east'),
                 ('west', 'east', 'north', 'south'), ('east', 'west', 'north', 'south')]
    lines = [f'module switch_proxy(input clk, input [{width-1}:0] north_in,south_in,west_in,east_in,',
             f'input [3:0] local_out, input [{3*width-1}:0] north_cfg,south_cfg,west_cfg,east_cfg,',
             f'output {"reg" if registered else "wire"} [{width-1}:0] north_out,south_out,west_out,east_out);',
             'function automatic pick; input [2:0] s; input [3:0] l; input straight,a,b,allow;',
             'begin case(s) 1:pick=l[0]; 2:pick=l[1]; 3:pick=l[2]; 4:pick=l[3];',
             '5:pick=straight; 6:pick=allow && a; 7:pick=allow && b; default:pick=0; endcase end endfunction']
    for output, straight, a, b in direction:
        for track in range(width):
            allow = track < (width + 1) // 2 if output in ('north', 'south') else track >= (width + 1) // 2
            expr = f'pick({output}_cfg[{3*track}+:3],local_out,{straight}_in[{track}],{a}_in[{track}],{b}_in[{track}],1\'b{int(allow)})'
            lines.append(f'{"always @(posedge clk)" if registered else "assign"} {output}_out[{track}] {"<=" if registered else "="} {expr};')
    lines.append('endmodule')
    return '\n'.join(lines) + '\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--liberty', type=Path, required=True)
    p.add_argument('--yosys', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    liberty = args.liberty.resolve(strict=True)
    if any(c.isspace() or c in ';"' for c in str(liberty)):
        raise ValueError('liberty path cannot contain whitespace or Yosys syntax')
    result = []
    with tempfile.TemporaryDirectory(prefix='switch-area-') as tmp:
        src = Path(tmp) / 'switch.v'
        src.write_text(verilog(4, False))
        miter = Path(tmp) / 'miter.v'
        miter.write_text('''module miter(input [3:0] n,s,w,e,l, input [11:0] nc,sc,wc,ec, output mismatch);
wire [3:0] an,as_,aw,ae,bn,bs,bw,be;
grid_switch a(n,s,w,e,l,nc,sc,wc,ec,an,as_,aw,ae);
switch_proxy b(1'b0,n,s,w,e,l,nc,sc,wc,ec,bn,bs,bw,be);
assign mismatch = |({an,as_,aw,ae} ^ {bn,bs,bw,be});
endmodule
''')
        script = f'read_verilog {ROOT}/src/grid_switch.v {src} {miter}; prep -top miter -flatten; sat -verify -prove mismatch 0'
        subprocess.run([args.yosys, '-Q', '-q', '-p', script], check=True)
        for width in (2, 4, 6, 8):
            for registered in (False, True):
                src = Path(tmp) / 'switch.v'
                src.write_text(verilog(width, registered))
                script = (f'read_verilog {src}; hierarchy -check -top switch_proxy; synth -top switch_proxy -flatten; '
                          f'dfflibmap -liberty {liberty}; abc -liberty {liberty}; stat -liberty {liberty}')
                run = subprocess.run([args.yosys, '-Q', '-p', script], check=True, text=True, capture_output=True)
                area = re.findall(r"Chip area for module .*?:\s*([\d.]+)", run.stdout)
                if not area:
                    raise ValueError('missing area')
                result.append({'tracks_per_direction': width, 'registered_outputs': registered,
                               'standard_cell_area_um2_per_four_port_switch': float(area[-1]),
                               'register_bits_per_switch': 4 * width if registered else 0})
    args.output.write_text(json.dumps({'schema':'spatial.switch-proxy-area.v1',
        'liberty_sha256':hashlib.sha256(liberty.read_bytes()).hexdigest(),
        'yosys_version':subprocess.check_output([args.yosys, '-V'], text=True).strip(),
        'four_track_proxy_proved_equivalent_to_current_rtl': True,
        'measurements':result,
        'limitations':['Single isolated four-port switch; all ports connected. Not a complete grid or routed layout.',
                       'No configuration storage, clock tree, interconnect wiring, bank macros or physical timing.',
                       'Changing track count requires corresponding RTL, encoding, and compiler changes.']}, indent=2) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()

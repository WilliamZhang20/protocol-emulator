#!/usr/bin/env python3
"""Registered-routing study (FABRIC_REORG.md step 5): per study point REG,
synthesize the test_3x5c mesh (a) with the configuration free (structural:
loops, area, worst path over every configuration) and (b) with each compiled
program's configuration as constants (that mapping's critical path).
Usage: reg_study.py LIBERTY OUT_DIR  (the IHP sg13cmos5l liberty, e.g.
from a GDS CI artifact's runs/wokwi/tmp/). Writes OUT_DIR/synth.json.
Areas are from a delay mapping here; the table in FABRIC_REORG.md takes
areas from the default (area) mapping."""
import json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
RTL = Path(__file__).resolve().parents[3]
LIB = Path(sys.argv[1]).resolve()
S = Path(sys.argv[2]).resolve()
S.mkdir(parents=True, exist_ok=True)
YOSYS = RTL / '.tools/oss-cad-suite/bin/yosys'
SRCS = ' '.join(str(RTL / p) for p in ['src/grid_timer.v', 'src/fabric_shifter.v', 'src/fabric_crc.v', 'src/fabric_counter.v',
       'src/config_bank.v', 'src/ctx_switch.v', 'src/wnet.v',
       'src/io_tile.v', 'src/mesh.v'])
COMP = RTL / 'experiments/grid_fabric/reorg/compiled'
P = dict(KINDS=287029521, CTX4=11242, CNT=4096)
CFG_BITS = 15 * 512 + 128

def wrapper(name, reg, vector):
    v = S / f'w_{name}_{reg}.v'
    v.write_text(f"""module top(input wire clk, rst_n, run_req, input wire [3:0] host_ev, output wire [59:0] seen, input wire seen_clear,
  input wire param_we, input wire [3:0] param_cell, input wire [2:0] param_addr, input wire [15:0] param_data, input wire [7:0] pins,
  output wire [7:0] pad_oe, pad_out, output wire ready, input wire [15:0] rd_data, input wire rd_valid, output wire rd_ready,
  output wire [15:0] wr_data, output wire wr_valid, input wire wr_ready, output wire [14:0] host_valid, output wire [119:0] host_byte);
  mesh #(.KINDS({P['KINDS']}),.CTX4({P['CTX4']}),.CNT({P['CNT']}),.REG({reg})) m(clk,rst_n,run_req,host_ev,seen,seen_clear,param_we,param_cell,
    param_addr,param_data,{CFG_BITS}'h{vector:x},pins,pad_oe,pad_out,ready,rd_data,rd_valid,rd_ready,wr_data,wr_valid,wr_ready,host_valid,host_byte);
endmodule
""")
    return v

def run(name, reg, vector=None):
    log = S / f's_{name}_{reg}.log'
    if vector is None:
        read, top = f'read_verilog -sv {SRCS}; chparam -set KINDS {P["KINDS"]} -set CTX4 {P["CTX4"]} -set CNT {P["CNT"]} -set REG {reg} mesh', 'mesh'
    else:
        read, top = f'read_verilog -sv {SRCS} {wrapper(name, reg, vector)}', 'top'
    cmd = (f'{read}; synth -top {top} -flatten; tee -o {S}/scc_{name}_{reg}.txt scc; '
           f'dfflibmap -liberty {LIB}; abc -liberty {LIB} -script +strash;dch,-f;map,-D,1;topo;stime,-p; opt_clean; stat -liberty {LIB}')
    subprocess.run([str(YOSYS), '-Q', '-l', str(log), '-p', cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3600)
    t = log.read_text()
    area = re.findall(r'Chip area for (?:module|top module) .*?: ([\d.]+)', t)
    delay = re.findall(r'Delay =\s*([\d.]+) ps', t)
    sccs = re.findall(r'Found (\d+) SCCs', (S / f'scc_{name}_{reg}.txt').read_text())
    return name, reg, float(area[-1]) if area else None, float(delay[-1]) if delay else None, int(sccs[-1]) if sccs else 0

jobs = [('structural', r, None) for r in range(4)]
for hexf in sorted(COMP.glob('*.plan.json')):
    stem = hexf.name.split('.')[0]
    words = [int(x, 16) for x in (COMP / f'{stem}.test_3x5c.hex').read_text().split()]
    vec = sum(w << (32 * i) for i, w in enumerate(words))
    jobs += [(stem, r, vec) for r in range(4)]
with ThreadPoolExecutor(24) as ex:
    res = list(ex.map(lambda j: run(*j), jobs))
out = [dict(name=n, reg=r, area=a, delay_ps=d, loops=l) for n, r, a, d, l in res]
(S / 'synth.json').write_text(json.dumps(out, indent=1))
for o in out: print(o)

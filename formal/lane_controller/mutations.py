#!/usr/bin/env python3
"""The lane-controller proof must fail on each of these RTL mutations.

Each mutation is applied to a copy of src/grid_lane_controller.v and the
k-induction proof is rerun; a mutation that still passes means the proof
lost its teeth.
"""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
RTL = HERE.parents[1] / 'src' / 'grid_lane_controller.v'
MUTATIONS = [
    ('XOR computes OR', "acc<=acc ^ {4'b0,arg};", "acc<=acc | {4'b0,arg};"),
    ('WAIT does not consume its event', "4'h1: if(!sel[3]) latched[sel[2:0]]<=1'b0;", "4'h1: ;"),
    ('write fence admits word 117', "wire owned=own_offset<=OWN_SPAN && arg[11:8]==0;", "wire owned=own_offset<=OWN_SPAN+8'd1 && arg[11:8]==0;"),
    ('LOOP tests the old count', "(op==4'hC && count!=8'd1)", "(op==4'hC && count!=8'd0)"),
    ('refused value is written', "assign cfg_we=exec && op==4'hE && owned && cfg_ok;", "assign cfg_we=exec && op==4'hE && owned;"),
    ('WANY consumes the whole mask register', "latched<=seen & ~arg[7:0];", "latched<=0;"),
    ('SHL shifts right', "4'd9: acc<={acc[14:0],1'b0};", "4'd9: acc<={1'b0,acc[15:1]};"),
    ('outputs live while disabled', "wire running=enable && active && !loading;", "wire running=active && !loading;"),
]


def main(sby, build):
    build = pathlib.Path(build)
    source = RTL.read_text()
    failures = []
    for name, before, after in MUTATIONS:
        if source.count(before) != 1:
            failures.append(f'{name}: pattern not found once')
            continue
        work = build / name.replace(' ', '_')
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        (work / 'grid_lane_controller.v').write_text(source.replace(before, after))
        shutil.copy(HERE / 'lane_controller_properties.sv', work)
        sby_text = (HERE / 'lane_controller.sby').read_text().replace(
            '../../src/grid_lane_controller.v', 'grid_lane_controller.v')
        (work / 'lc.sby').write_text(sby_text)
        subprocess.run([sby, '-f', '-d', 'run', 'lc.sby', 'prove'], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: proof {status}')
        if status != 'FAIL':
            failures.append(f'{name}: proof {status}, expected a counterexample')
    if failures:
        sys.exit('lane controller mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'Lane controller: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

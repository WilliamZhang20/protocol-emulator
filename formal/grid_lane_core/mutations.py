#!/usr/bin/env python3
"""The lane core validity proof must fail on each of these RTL mutations.

Each mutation loosens one validity rule in a copy of src/grid_lane_core.v
and reruns the k-induction proof; a mutation that still passes means the
proof lost its teeth (wrong top, vacuous assumption, missing field).
"""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parents[1] / 'src'
RTL = SRC / 'grid_lane_core.v'
OTHERS = ['grid_lane_controller.v', 'grid_timer.v', 'fabric_shifter.v', 'fabric_crc.v', 'config_bank.v']
MUTATIONS = [
    ('line 19 accepted', "line_ok=s<=6'd18 ||", "line_ok=s<=6'd19 ||"),
    ('line 51 accepted', "(s>=6'd32 && s<=6'd50)", "(s>=6'd32 && s<=6'd51)"),
    ('level 19 accepted', "level_ok=s<=5'd18;", "level_ok=s<=5'd19;"),
    ('output 2 unchecked', "for(k=0;k<3;k=k+1) sel_ok=sel_ok && line_ok(ov_sel[k])",
     "for(k=0;k<2;k=k+1) sel_ok=sel_ok && line_ok(ov_sel[k])"),
    ('timer1 aux unchecked', "line_ok(t1_stop_sel) && line_ok(t1_aux_sel) &&", "line_ok(t1_stop_sel) &&"),
    ('coder abort unchecked', "level_ok(word[14][4:0]) && line_ok(word[14][12:7]) &&", "level_ok(word[14][4:0]) &&"),
    ('crc init beyond pulses', "word[22][10:6]<=5'd18", "word[22][10:6]<=5'd31"),
    ('coder io reserved bit', "word[13][15:13]==0", "word[13][15:14]==0"),
    ('settings low bits', "word[37][15:8]==0 && word[37][3:0]==0", "word[37][15:8]==0"),
    ('level selector reserved bits', "word[29+k][15:12]==0", "word[29+k][15:13]==0"),
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
        (work / 'grid_lane_core.v').write_text(source.replace(before, after))
        for other in OTHERS:
            shutil.copy(SRC / other, work)
        shutil.copy(HERE / 'grid_lane_core_properties.sv', work)
        sby_text = (HERE / 'grid_lane_core.sby').read_text().replace('../../src/', '')
        (work / 't.sby').write_text(sby_text)
        subprocess.run([sby, '-f', '-d', 'run', 't.sby', 'prove'], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: proof {status}')
        if status != 'FAIL':
            failures.append(f'{name}: proof {status}, expected a counterexample')
    if failures:
        sys.exit('lane core mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'Lane core: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

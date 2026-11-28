#!/usr/bin/env python3
"""The timer proof must fail on each of these RTL mutations.

Each mutation is applied to a copy of src/grid_timer.v and the
k-induction proof is rerun; a mutation that still passes means the proof
lost its teeth.
"""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
RTL = HERE.parents[1] / 'src' / 'grid_timer.v'
MUTATIONS = [
    ('live write cuts the running period', "end else remaining <= period;", "end else remaining <= live_we ? live_period : period;"),
    ('hold ignored', "wire hold = fn == 2'd0 && aux;", "wire hold = 1'b0;"),
    ('count mode steps on clocks', "wire step = fn == 2'd1 ? aux : !hold;", "wire step = !hold;"),
    ('capture does not restart its count', "if (aux) begin captured <= elapsed; elapsed <= 1; end", "if (aux) begin captured <= elapsed; end"),
    ('resync double-samples a late edge', "wire [W:0] want = late_edge ? {1'b0, phase} + {1'b0, period} : {1'b0, phase};", "wire [W:0] want = {1'b0, phase};"),
    ('resync wraps instead of saturating', "wire [W-1:0] saturated = clamped[W] ? {W{1'b1}} : clamped[W-1:0];", "wire [W-1:0] saturated = clamped[W-1:0];"),
    ('resync ignores its limit', "wire [W:0] clamped = want < lo ? lo : want > hi ? hi : want;", "wire [W:0] clamped = want;"),
    ('zero period accepted', "valid <= (cfg_first != 0 && cfg_period != 0);", "valid <= (cfg_first != 0);"),
    ('shadow kept after reload', "remaining <= next_period; first <= next_first; period <= next_period; pending <= 0;", "remaining <= next_period; first <= next_first; period <= next_period;"),
    ('reserved mode bits accepted', "assign configured = (valid || counter) && mode[7:3] == 0;", "assign configured = valid || counter;"),
    # The counter function (mode bit 2), against fabric_counter.
    ('counter: equal-bits restart at 0', "default: cnext = stop == last ? dec : from_one;", "default: cnext = stop == last ? dec : first;", 'counter_prove'),
    ('counter: ones rule inverted', "2'd1: cnext = stop ? dec : first;", "2'd1: cnext = stop ? first : dec;", 'counter_prove'),
    ('counter: clear loses to step', "end else if (aux) begin\n        remaining <= first; level <= first == 0;\n      end else if (start) begin",
     "end else if (aux && !start) begin\n        remaining <= first; level <= first == 0;\n      end else if (start) begin", 'counter_prove'),
    ('counter: reached pulses again', "tick <= remaining != 0 && cnext == 0;", "tick <= cnext == 0;", 'counter_prove'),
    ('counter: count does not saturate', "wire [W-1:0] dec = remaining == 0 ? {W{1'b0}} : remaining - 1'b1;", "wire [W-1:0] dec = remaining - 1'b1;", 'counter_prove'),
]


def main(sby, build):
    build = pathlib.Path(build)
    source = RTL.read_text()
    failures = []
    for name, before, after, *task in MUTATIONS:
        task = task[0] if task else 'prove'
        if source.count(before) != 1:
            failures.append(f'{name}: pattern not found once')
            continue
        work = build / name.replace(' ', '_')
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        (work / 'grid_timer.v').write_text(source.replace(before, after))
        shutil.copy(HERE / 'grid_timer_properties.sv', work)
        shutil.copy(HERE / 'grid_timer_counter_properties.sv', work)
        for f in ('config_bank.v', 'fabric_counter.v'):
            shutil.copy(RTL.parent / f, work)
        sby_text = (HERE / 'grid_timer.sby').read_text().replace(
            '../../src/grid_timer.v', 'grid_timer.v').replace(
            '../../src/config_bank.v', 'config_bank.v').replace('../../src/fabric_counter.v', 'fabric_counter.v')
        (work / 't.sby').write_text(sby_text)
        subprocess.run([sby, '-f', '-d', 'run', 't.sby', task], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: proof {status}')
        if status != 'FAIL':
            failures.append(f'{name}: proof {status}, expected a counterexample')
    if failures:
        sys.exit('timer mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'Timer: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

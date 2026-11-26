#!/usr/bin/env python3
"""Each check must fail on its RTL mutation of src/fabric_shifter.v:
link_bmc on mutations that let a framing bit onto the CRC link or keep a
data bit off it; bmc on a receive readback that a restarting frame can
clear (the live register instead of the word latched at its end)."""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parents[1] / 'src'
RTL = SRC / 'fabric_shifter.v'
MUTATIONS = [
    ('data-only ignored', '(!link_data_only || coded_data);', "1'b1;", 'link_bmc'),
    ('advance classed at the old index', 'next_index >= pre_n && next_index < data_end;',
     'index >= pre_n && index < data_end;', 'link_bmc'),
    ('frame start always data', "start      ? pre_n == 5'd0 :", "start      ? 1'b1 :", 'link_bmc'),
    ('burst word start not data', "burst_next ? 1'b1 :", "burst_next ? 1'b0 :", 'link_bmc'),
    ('rx readback live', 'assign rx_data    = bit_strobe ? rx_word : last_word;', 'assign rx_data    = rx_word;', 'bmc'),
]


def main(sby, build):
    build = pathlib.Path(build)
    source = RTL.read_text()
    failures = []
    for name, before, after, task in MUTATIONS:
        if source.count(before) != 1:
            failures.append(f'{name}: pattern not found once')
            continue
        work = build / name.replace(' ', '_')
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        (work / 'fabric_shifter.v').write_text(source.replace(before, after))
        shutil.copy(SRC / 'config_bank.v', work)
        for sv in HERE.glob('*.sv'):
            shutil.copy(sv, work)
        (work / 't.sby').write_text((HERE / 'fabric_shifter.sby').read_text().replace('../../src/', ''))
        subprocess.run([sby, '-f', '-d', 'run', 't.sby', task], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: check {status}')
        if status != 'FAIL':
            failures.append(f'{name}: check {status}, expected a counterexample')
    if failures:
        sys.exit('shifter mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'Shifter: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

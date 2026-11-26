#!/usr/bin/env python3
"""The CRC link data-only check (link_bmc) must fail on each of these RTL
mutations of src/fabric_shifter.v: each lets a framing bit onto the link or
keeps a data bit off it."""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parents[1] / 'src'
RTL = SRC / 'fabric_shifter.v'
MUTATIONS = [
    ('data-only ignored', '(!link_data_only || coded_data);', "1'b1;"),
    ('advance classed at the old index', 'next_index >= pre_n && next_index < data_end;',
     'index >= pre_n && index < data_end;'),
    ('frame start always data', "start      ? pre_n == 5'd0 :", "start      ? 1'b1 :"),
    ('burst word start not data', "burst_next ? 1'b1 :", "burst_next ? 1'b0 :"),
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
        (work / 'fabric_shifter.v').write_text(source.replace(before, after))
        shutil.copy(SRC / 'config_bank.v', work)
        for sv in HERE.glob('*.sv'):
            shutil.copy(sv, work)
        (work / 't.sby').write_text((HERE / 'fabric_shifter.sby').read_text().replace('../../src/', ''))
        subprocess.run([sby, '-f', '-d', 'run', 't.sby', 'link_bmc'], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: check {status}')
        if status != 'FAIL':
            failures.append(f'{name}: check {status}, expected a counterexample')
    if failures:
        sys.exit('CRC link mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'CRC link: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

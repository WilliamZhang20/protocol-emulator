#!/usr/bin/env python3
"""The CRC additive-mode proof must fail on each of these RTL mutations.

Each mutation is applied to a copy of src/fabric_crc.v and the
k-induction proof is rerun; a mutation that still passes means the proof
lost its teeth.
"""
import pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
RTL = HERE.parents[1] / 'src' / 'fabric_crc.v'
MUTATIONS = [
    ("two's complement keeps the carry", "wire        add_carry = sum_carry && !(twos && word_last);", "wire        add_carry = sum_carry;"),
    ('carry ignored', "wire        sum_bit   = crc[0] ^ data_in ^ carry;", "wire        sum_bit   = crc[0] ^ data_in;"),
    ('no fold', "assign value = additive ? folded : crc;", "assign value = crc;"),
    ('emit does not fold', "wire [31:0] emit_crc  = folded >> 1;", "wire [31:0] emit_crc  = crc >> 1;"),
    ('init keeps the carry', "wire        carry_next = init_now ? 1'b0 :", "wire        carry_next = init_now ? carry :"),
    ('word end off by one', "wire        word_last = bit_pos == shape[4:0];", "wire        word_last = bit_pos == shape[4:0] - 5'd1;"),
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
        (work / 'fabric_crc.v').write_text(source.replace(before, after))
        shutil.copy(HERE / 'fabric_crc_additive_properties.sv', work)
        shutil.copy(HERE / 'fabric_crc_properties.sv', work)
        sby_text = (HERE / 'fabric_crc.sby').read_text().replace(
            '../../src/fabric_crc.v', 'fabric_crc.v')
        (work / 't.sby').write_text(sby_text)
        subprocess.run([sby, '-f', '-d', 'run', 't.sby', 'add_prove'], cwd=work,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        log = (work / 'run' / 'logfile.txt').read_text()
        status = 'FAIL' if 'DONE (FAIL' in log else 'PASS' if 'DONE (PASS' in log else 'OTHER'
        print(f'{name}: proof {status}')
        if status != 'FAIL':
            failures.append(f'{name}: proof {status}, expected a counterexample')
    if failures:
        sys.exit('CRC additive mutation check failed:\n  ' + '\n  '.join(failures))
    print(f'CRC additive: all {len(MUTATIONS)} mutations caught')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

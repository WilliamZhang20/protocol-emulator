#!/usr/bin/env python3
"""Generate a 3x3 candidate swapping timer 0 and the LUT, without touching RTL."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    rtl = (ROOT / 'src/grid_core.v').read_text()
    changes = {
        'assign local_signal[2]={level,fall,rise,tick};': 'assign local_signal[4]={level,fall,rise,tick};',
        "assign local_signal[4]={3'b0,cfg[3][{2'b00,sink[11],sink[10]}]};": "assign local_signal[2]={3'b0,cfg[3][{2'b00,sink[11],sink[10]}]};",
        'localparam integer CELL=(q<3)?2:(q<7)?3:(q<10)?1:(q<12)?4:(q<15)?5:7;':
            'localparam integer CELL=(q<3)?4:(q<7)?3:(q<10)?1:(q<12)?2:(q<15)?5:7;',
    }
    for original, replacement in changes.items():
        if rtl.count(original) != 1:
            raise ValueError('grid_core.v no longer matches the candidate transformation')
        rtl = rtl.replace(original, replacement)
    contract = json.loads((ROOT / 'architecture/grid_3x3.json').read_text())
    cells = contract['grid']['cells']
    for key in ('resources', 'local_outputs'):
        cells[2][key], cells[4][key] = cells[4][key], cells[2][key]
    contract['resources']['timer0']['cell'] = 4
    contract['resources']['lut']['cell'] = 2
    for i in (0, 1, 2):
        contract['bit_network']['sink_cells'][i] = 4
    for i in (10, 11):
        contract['bit_network']['sink_cells'][i] = 2
    contract['name'] = 'grid-3x3-centre-timer-candidate'
    contract['implementation']['status'] = 'generated_candidate'
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'grid_core.v').write_text(rtl)
    (args.output / 'grid_3x3.json').write_text(json.dumps(contract, indent=2) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()

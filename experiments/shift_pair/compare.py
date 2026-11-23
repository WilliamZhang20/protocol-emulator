#!/usr/bin/env python3
"""Compare flattened generic synthesis, not physical area or timing."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent
YOSYS=os.environ.get('YOSYS','yosys')


def main():
    result={}
    with tempfile.TemporaryDirectory(prefix='shift-pair-synth-') as temp:
        for top in ('pair_separate','pair_combined_shared','pair_combined_independent'):
            output=Path(temp)/f'{top}.json'
            script=(f'read_verilog {HERE / "candidates.v"}; hierarchy -check -top {top}; '
                    f'flatten; synth -top {top}; tee -o {output} stat -json')
            subprocess.run([YOSYS,'-Q','-T','-p',script],check=True,stdout=subprocess.DEVNULL)
            stats=json.loads(output.read_text())['modules'][f'\\{top}']['num_cells_by_type']
            cells={k:v for k,v in stats.items() if k!='$scopeinfo'}
            result[top]={'generic_cells':sum(cells.values()),
                         'flip_flops':sum(v for k,v in cells.items() if 'DFF' in k), 'cell_types':cells}
    print(json.dumps({'yosys':subprocess.check_output([YOSYS,'-V'],text=True).strip(),
                      'scope':'generic flattened cell counts; shared control accepts a narrower workload; excludes routing, timers, IO and physical area/timing',
                      'results':result},indent=2,sort_keys=True))


if __name__=='__main__':
    main()

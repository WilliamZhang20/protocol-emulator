#!/usr/bin/env python3
"""Ensure the contract check rejects drift in topology, FIFO depth and switches."""
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from check_grid_contract import check, SOURCES

ROOT = Path(__file__).resolve().parents[1]
contract = json.loads((ROOT / 'architecture/grid_3x3.json').read_text())
mutations = []
bad = copy.deepcopy(contract); bad['grid']['cells'][0]['column'] = 1; mutations.append(('coordinate', bad))
bad = copy.deepcopy(contract); bad['memory']['reader_fifo_bytes'] = 3; mutations.append(('FIFO depth', bad))
bad = copy.deepcopy(contract)
bad['bit_network']['turn_classes'][0]['tracks'] = [2, 3]
bad['bit_network']['turn_classes'][1]['tracks'] = [0, 1]
mutations.append(('switch turns', bad))
with tempfile.TemporaryDirectory(prefix='grid-contract-mutations-') as tmp:
    for name, bad in mutations:
        path = Path(tmp) / 'contract.json'
        path.write_text(json.dumps(bad))
        result = subprocess.run([sys.executable, str(ROOT / 'tools/check_grid_contract.py'),
                                 '--contract', str(path), '--yosys', sys.argv[1]],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode == 0:
            raise SystemExit(f'ERROR: {name} mutation was accepted')
        if name == 'switch turns' and 'proof did fail' not in result.stdout.lower():
            raise SystemExit(f'ERROR: switch mutation failed for an unexpected reason: {result.stdout}')
    # Mutate the elaborated direct CRC-to-coder link rather than just the
    # metadata: accepting this would produce silently wrong packet FCS.
    netlist = Path(tmp) / 'grid.json'
    script = ('read_verilog ' + ' '.join('src/' + x for x in SOURCES) +
              '; hierarchy -check -top grid_stream_fabric; proc; write_json ' + str(netlist))
    subprocess.run([sys.argv[1], '-Q', '-q', '-p', script], cwd=ROOT, check=True)
    modules = json.loads(netlist.read_text())['modules']
    modules['grid_core']['cells']['coded_tile']['connections']['crc_in'] = ['0']
    try:
        check(contract, modules)
    except AssertionError:
        pass
    else:
        raise SystemExit('ERROR: broken coded CRC link was accepted')
print('PASS: contract checker rejects topology, FIFO, switch and CRC-link mutations')

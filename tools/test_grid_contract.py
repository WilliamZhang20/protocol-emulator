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
    modules['grid_core']['cells']['coded_tile']['connections']['crc_in'] = (
        modules['grid_core']['cells']['crc_tile']['connections']['tail_out'])
    check(contract, modules)  # the restored netlist passes again
    # Lane controller drift the compiler would silently encode against.
    lane_mutations = []
    bad = copy.deepcopy(contract); bad['lane']['program_word'] = 96; lane_mutations.append(('program word', bad))
    bad = copy.deepcopy(contract); bad['lane']['instruction']['opcodes']['WANY'] = 14; lane_mutations.append(('opcode', bad))
    bad = copy.deepcopy(contract); bad['lane']['levels'] = bad['lane']['levels'][:7]; lane_mutations.append(('levels', bad))
    bad = copy.deepcopy(contract); bad['lane']['live_write_words'] = [112, 117]; lane_mutations.append(('write fence', bad))
    bad = copy.deepcopy(contract); bad['lane']['buffer_instructions'] = 32; lane_mutations.append(('buffer depth', bad))
    bad = copy.deepcopy(contract); bad['resources']['shifter0']['config_fields']['restart'] = [7, 7]; lane_mutations.append(('shifter restart bit', bad))
    bad = copy.deepcopy(contract); bad['configuration']['timer_mode_words'] = [200, 207]; lane_mutations.append(('timer mode words', bad))
    bad = copy.deepcopy(contract); bad['resources']['coded_shifter']['coder_fields']['manchester'] = [14, 14]; lane_mutations.append(('coder manchester bit', bad))
    bad = copy.deepcopy(contract); bad['resources']['coded_shifter']['coder_fields']['receive'] = [6, 6]; lane_mutations.append(('coder receive bit', bad))
    bad = copy.deepcopy(contract); bad['resources']['coded_shifter']['coder_word'] = 120; lane_mutations.append(('coder word', bad))
    bad = copy.deepcopy(contract); bad['configuration']['timer_functions']['capture'] = 3; lane_mutations.append(('timer function code', bad))
    bad = copy.deepcopy(contract); bad['configuration']['timer_mode_fields']['resync_limit'] = [15, 9]; lane_mutations.append(('resync limit field', bad))
    bad = copy.deepcopy(contract); bad['resources']['timer2']['mode_words'] = [214, 215]; lane_mutations.append(('timer mode owner', bad))
    bad = copy.deepcopy(contract); bad['lane']['readback'][6:8] = ['timer1_capture', 'timer0_capture']; lane_mutations.append(('capture readback slot', bad))
    for name, bad in lane_mutations:
        try:
            check(bad, modules)
        except AssertionError:
            continue
        raise SystemExit(f'ERROR: lane {name} mutation was accepted')
print('PASS: contract checker rejects topology, FIFO, switch, CRC-link, lane-controller, timer-mode and coder-field mutations')

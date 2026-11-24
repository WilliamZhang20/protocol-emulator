#!/usr/bin/env python3
"""Check contract topology and resource instances against elaborated grid RTL."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['grid_stream_fabric.v', 'grid_stream_tiles.v', 'grid_stream_memory.v',
           'grid_core.v', 'grid_sequencer.v', 'grid_switch.v', 'fabric_v2_tiles.v', 'fabric_crc.v',
           'memory_tiles.v', 'program_memory.v']


def check(contract, modules):
    grid = contract['grid']
    network = contract['bit_network']
    cells = grid['cells']
    assert contract['schema'] == 'protocol-emulator.grid-contract.v1'
    assert len(cells) == grid['rows'] * grid['columns']
    core = modules['grid_core']['cells']
    switches = [core[f'mesh[{cell["id"]}].sw'] for cell in cells]
    assert sum(c['type'] == 'grid_switch' for c in core.values()) == len(cells)
    for cell, switch in zip(cells, switches):
        index, row, col = cell['id'], cell['row'], cell['column']
        assert index == row * grid['columns'] + col
        assert switch['type'] == 'grid_switch'
        for direction, dr, dc, opposite in [('north', -1, 0, 'south'), ('south', 1, 0, 'north'),
                                             ('west', 0, -1, 'east'), ('east', 0, 1, 'west')]:
            wires = switch['connections'][direction + '_in']
            assert len(wires) == network['tracks_per_direction']
            nr, nc = row + dr, col + dc
            if 0 <= nr < grid['rows'] and 0 <= nc < grid['columns']:
                neighbor = switches[nr * grid['columns'] + nc]
                assert wires == neighbor['connections'][opposite + '_out'], (index, direction)
            else:
                assert all(bit == '0' for bit in wires), (index, direction)
            assert len(switch['connections'][direction + '_cfg']) == network['tracks_per_direction'] * network['switch_words']['selector_bits']
        assert switch['connections']['local_out'] == modules['grid_core']['netnames'][f'local_signal[{index}]']['bits']
    for name, kind in [('timer0', 'fabric_v2_timer'), ('timer1', 'fabric_v2_timer'),
                       ('shifter0', 'fabric_v2_shift'), ('shifter1', 'fabric_v2_shift'),
                       ('crc', 'fabric_crc')]:
        assert core[contract['resources'][name]['instance']]['type'] == kind
    sinks = modules['grid_core']['netnames']['sink']['bits']
    for name, first in [('timer0', 0), ('shifter0', 3), ('timer1', 12), ('shifter1', 15)]:
        resource = contract['resources'][name]
        tile = core[resource['instance']]
        for offset, port in enumerate(resource['inputs']):
            assert tile['connections'][port] == [sinks[first + offset]], (name, port)
            assert network['sink_cells'][first + offset] == resource['cell']
        local = modules['grid_core']['netnames'][f'local_signal[{resource["cell"]}]']['bits']
        for index, port in enumerate(resource['outputs']):
            if port in tile['connections']:
                assert tile['connections'][port] == [local[index]], (name, port)
    top = modules[contract['implementation']['fabric']]['cells']
    assert top['grid']['type'] == contract['implementation']['core']
    for name in ('reader', 'writer'):
        assert f'grid_stream_{name}' in top[name]['type']
        module = modules[top[name]['type']]
        assert int(module['parameter_default_values']['DEPTH'], 2) == contract['memory'][name + '_fifo_bytes']
    memory = modules[top['memory']['type']]['cells']
    banks = [c for c in memory.values() if 'grid_stream_bank' in c['type']]
    assert len(banks) == contract['memory']['bank_count']
    for index in range(len(banks)):
        resource = contract['resources'][f'sram{index}']
        cell = cells[resource['cell']]
        bank = memory[f'row{cell["row"]}_col{cell["column"]}']
        bank_module = modules[bank['type']]
        implementation = modules[bank_module['cells']['bank']['type']]
        storage = implementation['memories']['model_bank.words']
        assert (storage['size'], storage['width']) == (resource['bytes'], resource['data_width_bits'])
        assert resource['ports'] == 1
        assert len(implementation['ports']['address']['bits']) == (resource['bytes'] - 1).bit_length()
        for port in ('write_data', 'read_data'):
            assert len(implementation['ports'][port]['bits']) == resource['data_width_bits']
    assert sum(contract['resources'][f'sram{i}']['bytes'] for i in range(len(banks))) == contract['memory']['total_bytes']
    for resource in contract['resources'].values():
        assert resource['cell'] in range(len(cells))
    for cell in cells:
        for resource in cell['resources']:
            assert contract['resources'][resource]['cell'] == cell['id']
    assert len(network['sink_cells']) == 19
    assert network['hop_cycles'] == 0 and contract['temporal']['programmable_sequencer']
    assert top['sequencer']['type'] == 'grid_sequencer'
    seq = modules['grid_sequencer']['memories']['rows']
    assert seq['size'] == contract['temporal']['rows'] and seq['width'] == 16
    contexts = modules['grid_core']['memories']['context_routes']
    assert contexts['size'] == contract['temporal']['alternate_context_slots'] and contexts['width'] == 16


def prove_switch(contract, yosys, tmp):
    """Prove every selector, input combination and track against the contract."""
    network = contract['bit_network']
    values = network['selector_values']
    tracks = network['tracks_per_direction']
    assert tracks == 4 and network['switch_words']['selector_bits'] == 3
    classes = network['turn_classes']
    assert sorted(t for group in classes for t in group['tracks']) == list(range(tracks))
    assert values['zero'] == 0 and values['local_last'] == values['local_first'] + 3
    outputs = [('north', 'south', 'west', 'east'), ('south', 'north', 'west', 'east'),
               ('west', 'east', 'north', 'south'), ('east', 'west', 'north', 'south')]
    lines = ['module contract_switch_check(input [3:0] north_in,south_in,west_in,east_in,local_out,',
             'input [11:0] north_cfg,south_cfg,west_cfg,east_cfg, output mismatch);',
             'wire [3:0] north_out,south_out,west_out,east_out;',
             'grid_switch dut(north_in,south_in,west_in,east_in,local_out,',
             'north_cfg,south_cfg,west_cfg,east_cfg,north_out,south_out,west_out,east_out);',
             'function automatic pick; input [2:0] s; input [3:0] local_bits;',
             'input straight,turn_a,turn_b,allow_turn; begin case(s)']
    for local in range(4):
        lines.append(f'{values["local_first"] + local}: pick=local_bits[{local}];')
    lines += [f'{values["straight"]}: pick=straight;',
              f'{values["turn_first"]}: pick=allow_turn && turn_a;',
              f'{values["turn_last"]}: pick=allow_turn && turn_b;',
              'default: pick=0; endcase end endfunction']
    differences = []
    for direction, straight, turn_a, turn_b in outputs:
        for track in range(tracks):
            order = next(group['order'] for group in network['turn_classes'] if track in group['tracks'])
            turns = (direction in ('north', 'south') and order == 'horizontal_then_vertical') or (direction in ('west', 'east') and order == 'vertical_then_horizontal')
            expected = f'pick({direction}_cfg[{track*3}+:3],local_out,{straight}_in[{track}],{turn_a}_in[{track}],{turn_b}_in[{track}],1\'b{int(turns)})'
            differences.append(f'({direction}_out[{track}] != {expected})')
    lines += ['assign mismatch=' + ' | '.join(differences) + ';', 'endmodule']
    reference = Path(tmp) / 'switch_reference.v'
    reference.write_text('\n'.join(lines) + '\n')
    script = f'read_verilog src/grid_switch.v {reference}; prep -top contract_switch_check -flatten; sat -verify -prove mismatch 0'
    subprocess.run([yosys, '-Q', '-q', '-p', script], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', type=Path, default=ROOT / 'architecture/grid_3x3.json')
    parser.add_argument('--yosys', default='yosys')
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text())
    with tempfile.TemporaryDirectory(prefix='grid-contract-') as tmp:
        netlist = Path(tmp) / 'elaborated.json'
        script = ('read_verilog ' + ' '.join('src/' + x for x in SOURCES) +
                  '; hierarchy -check -top grid_stream_fabric; proc; write_json ' + str(netlist))
        subprocess.run([args.yosys, '-Q', '-q', '-p', script], cwd=ROOT, check=True)
        check(contract, json.loads(netlist.read_text())['modules'])
        prove_switch(contract, args.yosys, tmp)
    print('PASS: grid contract instances, FIFO depths and neighbor connections match RTL; all switch selectors proved')


if __name__ == '__main__':
    main()

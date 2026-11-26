#!/usr/bin/env python3
"""Check contract topology and resource instances against elaborated grid RTL."""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['grid_stream_fabric.v', 'grid_stream_tiles.v', 'grid_stream_memory.v',
           'grid_core.v', 'grid_sequencer.v', 'grid_lane_controller.v', 'grid_timer.v', 'grid_switch.v', 'fabric_v2_tiles.v', 'fabric_crc.v',
           'fabric_shifter.v', 'config_bank.v', 'memory_tiles.v', 'program_memory.v']


def check(contract, modules):
    grid = contract['grid']
    network = contract['bit_network']
    cells = grid['cells']
    assert contract['schema'] == 'protocol-emulator.grid-contract.v1'
    assert len(cells) == grid['rows'] * grid['columns']
    core = modules['grid_core']['cells']
    first_ext = network['switch_words']['extension_first_cell']
    switches = [core[f'mesh[{cell["id"]}].' + ('base' if cell['id'] < first_ext else 'extension') + '.sw'] for cell in cells]
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
    for name, kind in [('timer0', 'grid_timer'), ('timer1', 'grid_timer'),
                       ('shifter0', 'fabric_v2_shift'), ('shifter1', 'fabric_v2_shift'),
                       ('crc', 'fabric_crc'), ('coded_shifter', 'fabric_shifter')]:
        assert core[contract['resources'][name]['instance']]['type'] == kind
    # The coded tile and CRC share direct registered handshake signals, not
    # independent soft routes; catch drift that would silently corrupt FCS.
    coder = core[contract['resources']['coded_shifter']['instance']]['connections']
    crc = core[contract['resources']['crc']['instance']]['connections']
    for codec_port, crc_port in [('crc_absorb', 'link_absorb'), ('crc_bit', 'link_bit'), ('crc_emit', 'link_emit')]:
        assert coder[codec_port] == crc[crc_port][:1], codec_port
    assert coder['crc_in'] == crc['tail_out']
    sinks = modules['grid_core']['netnames']['sink']['bits']
    for name, resource in contract['resources'].items():
        if resource['kind'] == 'timer' and 'input_sinks' in resource:
            assert core[resource['instance']]['type'] == 'grid_timer'
        if resource['kind'] == 'lut4_register':
            assert core[resource['instance']]['type'] == 'grid_lut4_cell'
            tile = core[resource['instance']]['connections']
            assert tile['in'] == [sinks[i] for i in resource['input_sinks']], name
            local = modules['grid_core']['netnames'][f'local_signal[{resource["cell"]}]']['bits']
            assert tile['q'] == [local[0]], name
        for i in resource.get('input_sinks', []):
            assert network['sink_cells'][i] == resource['cell'], (name, i)
    for name in ('timer2', 'timer3'):
        resource = contract['resources'][name]
        tile = core[resource['instance']]
        for sink, port in zip(resource['input_sinks'], resource['inputs']):
            assert tile['connections'][port] == [sinks[sink]], (name, port)
        local = modules['grid_core']['netnames'][f'local_signal[{resource["cell"]}]']['bits']
        for index, port in enumerate(resource['outputs']):
            assert tile['connections'][port] == [local[index]], (name, port)
    assert modules['grid_core']['netnames']['seq_events']['bits'] == [sinks[i] for i in contract['resources']['sequencer_events']['input_sinks']]
    assert len(network['sink_words']) == len(network['sink_cells'])
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
    assert len(network['sink_cells']) == 43 and network['context_overridable_sinks'] == 19
    assert network['hop_cycles'] == 0 and contract['temporal']['programmable_sequencer']
    assert top['sequencer']['type'] == 'grid_sequencer'
    seq = modules['grid_sequencer']['memories']['rows']
    assert seq['size'] == contract['temporal']['rows'] and seq['width'] == 16
    slots = contract['temporal']['alternate_context_slots']
    netnames = modules['grid_core']['netnames']
    assert all(len(netnames[f'context_routes[{i}]']['bits']) == 16 for i in range(slots))
    assert f'context_routes[{slots}]' not in netnames
    # Configuration reaches the core only through the registered distribution tree.
    tree = contract['configuration']['distribution']
    assert top['config_tree']['type'] == tree['module']
    core_ports = modules['grid_core']['ports']
    assert 'cfg_leaves' in core_ports and not {'cfg_we', 'cfg_addr', 'cfg_data'} & set(core_ports)
    assert len(core_ports['cfg_leaves']['bits']) == tree['leaves'] * tree['leaf_bits']
    assert len(modules[tree['module']]['ports']['leaves']['bits']) == tree['leaves'] * tree['leaf_bits']
    check_lane(contract, modules, top)
    check_timers(contract, modules)
    check_coder(contract)
    # Shifter configuration fields: the core's validity check and port wiring.
    core_text = (ROOT / 'src/grid_core.v').read_text()
    for name, instance in (('shifter0', 'shifter'), ('shifter1', 'shifter1')):
        resource = contract['resources'][name]
        word, fields = resource['config_words'][0], resource['config_fields']
        assert f"cfg[{word}][15:{fields['reserved'][1]}]==0" in core_text, name
        wiring = (re.escape(f"fabric_v2_shift {instance}(") + r'clk,rst_n,live,sink\[\d+\],sink\[\d+\],sink\[\d+\],' +
                  re.escape(f"cfg[{word}][{fields['width'][0]}:{fields['width'][1]}],cfg[{word}][{fields['msb_first'][0]}],"
                            f"cfg[{word}][{fields['restart'][0]}],"))
        assert re.search(wiring, core_text), name


def check_coder(contract):
    """Coded shifter register 5 fields and the configuration rules the
    fabric enforces, against the tile and grid_core source."""
    coder = contract['resources']['coded_shifter']
    f = coder['coder_fields']
    word = coder['coder_word']
    assert word == coder['config_words'][0] + 4   # words 117-122 are tile registers 1-6; register 5 is the coder
    tile = (ROOT / 'src/fabric_shifter.v').read_text()
    for name, rtl in [('stuff_run', 'stuff_n'), ('runs_of_ones', 'ones_run'), ('receive', 'coder_rx'),
                      ('arm_at_first_zero', 'sof_arm'), ('tail_invert', 'tail_inv'), ('bit_strobe', 'bit_strobe'),
                      ('tail_length', 'tail_n')]:
        hi, lo = f[name]
        select = f'coder[{hi}:{lo}]' if hi != lo else f'coder[{hi}]'
        assert re.search(r'wire\s+(\[\d+:0\]\s+)?%s\s*=\s*%s;' % (rtl, re.escape(select)), tile), name
    nrzi, rx, manch = f['nrzi'][0], f['receive'][0], f['manchester'][0]
    assert f'wire       nrzi_rx    = coder[{nrzi}] && coder_rx;' in tile
    assert f'wire       manch      = coder[{manch}] && !coder[{rx}];' in tile
    assert f'wire       manch_rx   = coder[{manch}] && coder[{rx}];' in tile
    status = coder['coder_status_bits']
    assert status == {'post_capture': [3, 0], 'stuff_error': [4, 4], 'manchester_violation': [5, 5]}
    assert 'assign status = {active_r, overrun, push_pending, 7\'b0, manch_err, stuff_err, post_cap};' in tile
    core = (ROOT / 'src/grid_core.v').read_text()
    stuff_hi, stuff_lo = f['stuff_run']
    rule = (f"coder_word_valid<=!(ld[8][{stuff_hi}:{stuff_lo}]==3'd1 && !ld[8][{f['runs_of_ones'][0]}]) && "
            f"!(ld[8][{manch}] && ld[8][{nrzi}]);")
    assert f'if(la[8]=={word}) begin' in core and rule in core
    assert 'packet_configured_now=(&coder_written) && coder_word_valid &&' in core


def check_timers(contract, modules):
    """Timer mode words: addresses, owning cells, field layout, mode and
    phase wiring, reserved-bit validity."""
    cfg = contract['configuration']
    fields = cfg['timer_mode_fields']
    first, last = cfg['timer_mode_words']
    names = ['timer0', 'timer1', 'timer2', 'timer3']
    assert last - first + 1 == 2 * len(names)
    timer = modules['grid_timer']
    assert len(timer['ports']['mode']['bits']) == 16
    text = (ROOT / 'src/grid_timer.v').read_text()
    assert f"wire [1:0] fn = mode[{fields['function'][0]}:{fields['function'][1]}];" in text
    assert f"wire [7:0] limit = mode[{fields['resync_limit'][0]}:{fields['resync_limit'][1]}];" in text
    assert f"assign configured = valid && mode[{fields['reserved'][0]}:{fields['reserved'][1]}] == 0;" in text
    for name, code in cfg['timer_functions'].items():
        assert re.search(r'//\s+%d %s\b' % (code, name), text), name
    core_text = (ROOT / 'src/grid_core.v').read_text()
    cells = re.search(r'localparam integer CELL=\(ti==0\)\?(\d+):\(ti==1\)\?(\d+):\(ti==2\)\?(\d+):(\d+);', core_text)
    assert cells and [int(x) for x in cells.groups()] == [contract['resources'][n]['cell'] for n in names]
    assert f"localparam [7:0] MODE_ADDR=8'd{first}+2*ti;" in core_text
    assert f"localparam [7:0] PHASE_ADDR=8'd{first + 1}+2*ti;" in core_text
    assert f"assign timer_mode_ok[ti]=mode_q[{fields['reserved'][0]}:{fields['reserved'][1]}]==0;" in core_text
    assert '&& (&timer_mode_ok);' in core_text
    core = modules['grid_core']
    netnames = core['netnames']
    for index, name in enumerate(names):
        resource = contract['resources'][name]
        assert resource['mode_words'] == [first + 2 * index, first + 2 * index + 1], name
        tile = core['cells'][resource['instance']]['connections']
        assert tile['mode'] == netnames[f'timer_mode[{index}]']['bits'], name
        assert tile['phase'] == netnames[f'timer_phase[{index}]']['bits'], name
    # Lane readback slots 6 and 7 are the timer 0 and 1 capture registers.
    lane = contract['lane']['readback']
    for slot, (name, port) in enumerate([('timer0_capture', 'timer0_captured'), ('timer1_capture', 'timer1_captured')], 6):
        assert lane[slot] == name
        tile = core['cells'][contract['resources'][f'timer{slot - 6}']['instance']]['connections']
        assert tile['captured'] == core['ports'][port]['bits'], name
    fabric = (ROOT / 'src/grid_stream_fabric.v').read_text()
    assert "lane_readback={128'b0,timer1_captured,timer0_captured," in fabric


def check_lane(contract, modules, top):
    """The lane section the compiler encodes against matches the RTL."""
    lane = contract['lane']
    assert top[lane['instance']]['type'] == lane['controller']
    module = modules[lane['controller']]
    ports = module['ports']
    assert len(ports['events']['bits']) == len(lane['events'])
    assert len(ports['levels']['bits']) == len(lane['levels']) == 8 and lane['level_wait_offset'] == 8
    assert len(ports['readback']['bits']) >= 16 * len(lane['readback'])
    assert 2 ** int(module['parameter_default_values']['ABITS'], 2) == lane['buffer_instructions']
    assert len(ports['prog_base']['bits']) == lane['program_fields']['base'][0] + 1
    last = lane['program_fields']['last']
    assert len(ports['prog_last']['bits']) == last[0] - last[1] + 1
    fabric = (ROOT / 'src/grid_stream_fabric.v').read_text()
    assert re.search(r'leaf_addr==%d\) begin temporal_mode<=leaf_data\[%d\];lane_mode<=leaf_data\[%d\]'
                     % (lane['mode_word'], lane['mode_exclusive_with_bit'], lane['mode_bit']), fabric)
    assert re.search(r'seq_addr==%d\) lane_prog<=seq_data' % lane['program_word'], fabric)
    assert 'grid_lane_controller lane_ctl(clk,rst_n,arm && configured && lane_mode,' in fabric
    first, final = lane['live_write_words']
    rtl = (ROOT / 'src/grid_lane_controller.v').read_text()
    assert f"arg[7:0]>=8'd{first} && arg[7:0]<=8'd{final}" in rtl
    assert (first, final) == tuple(contract['configuration']['alternate_context_words'])
    # The instruction table in the RTL header comment names every opcode.
    header = rtl.split('module grid_lane_controller')[0]
    for name, code in lane['instruction']['opcodes'].items():
        assert re.search(r'\b%X %s\b' % (code, name), header), name
    for name, code in lane['instruction']['sys'].items():
        if name in ('ATOC', 'CTOA'):
            continue  # written "7 C = A[7:0], 8 A = C" in the header
        assert re.search(r'\b%d %s\b' % (code, name), header), name


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
    print('PASS: grid contract instances, FIFO depths, neighbor connections and lane controller match RTL; all switch selectors proved')


if __name__ == '__main__':
    main()

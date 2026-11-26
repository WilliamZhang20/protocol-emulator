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
           'grid_core.v', 'grid_sequencer.v', 'grid_lane_controller.v', 'grid_lane_core.v', 'grid_timer.v', 'grid_switch.v', 'fabric_v2_tiles.v', 'fabric_crc.v',
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
    check_crc_shape(contract)
    check_lane_core(contract)
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


def concat_items(text, name):
    """The items of `assign <name>={...};`, expanded LSB first to one entry
    per bit: a name or bit-select per bit, '0'/'1' for constant bits."""
    body = re.search(r'assign\s+%s\s*=\s*\{(.*?)\};' % re.escape(name), text, re.S).group(1)
    bits = []
    for item in reversed([x.strip() for x in body.replace('\n', ' ').split(',')]):
        m = re.fullmatch(r"(\d+)'b([01]+)", item)
        if m:
            value = m.group(2).rjust(int(m.group(1)), m.group(2)[0] if len(m.group(2)) == 1 else '0')
            bits.extend(reversed(value))
        else:
            bits.append(item)
    return bits


def check_lane_core(contract):
    """Lane core local signal set, selector fields, validity bounds and
    readback against src/grid_lane_core.v and the validity proof's tables."""
    core = contract['lane_core']
    rtl = (ROOT / 'src/grid_lane_core.v').read_text()
    assert f"module {core['module']}(" in rtl
    assert f"reg [15:0] word[0:{core['words'] - 1}];" in rtl
    # Line table: every bit of the lines vector, defined or constant zero.
    bits = concat_items(rtl, 'lines')
    assert len(bits) == 64, len(bits)
    table = {index: source for index, _, source in core['lines']}
    names = [name for _, name, _ in core['lines']]
    assert len(set(names)) == len(names) and len(table) == len(core['lines'])
    for index in range(64):
        want = table.get(index, "1'b0")
        want = {"1'b0": '0', "1'b1": '1'}.get(want, want)
        assert bits[index] == want, f'line {index}: RTL {bits[index]}, contract {want}'
    lo_p, hi_p = core['pulse_lines']
    lo_l, hi_l = core['level_lines']
    pulses = sorted(i for i in table if lo_p <= i <= hi_p)
    levels = sorted(i for i in table if lo_l <= i <= hi_l)
    assert pulses == list(range(pulses[-1] + 1)) and levels == list(range(lo_l, levels[-1] + 1))
    assert f"line_ok=s<=6'd{pulses[-1]} || (s>=6'd{lo_l} && s<=6'd{levels[-1]});" in rtl
    assert f"level_ok=s<=5'd{levels[-1] - lo_l};" in rtl
    # The validity proof checks exactly the contract's fields and line set.
    props = (ROOT / 'formal/grid_lane_core/grid_lane_core_properties.sv').read_text()
    mask = sum(1 << i for i in table)
    assert f"localparam [63:0] DEFINED = 64'h{mask:016x};" in props
    kinds = {'LINE': 'line', 'LEVEL': 'level', 'PULSE5': 'pulse5'}
    proved = sorted((n, int(w), [int(h), int(l)], kinds[k]) for k, n, w, h, l in
                    re.findall(r'`SEL_(LINE|LEVEL|PULSE5)\(([\w.]+), (\d+), (\d+), (\d+)\)', props))
    assert proved == sorted((n, w, b, k) for n, w, b, k in core['selectors']), 'proof selector fields'
    reserved = sorted([int(w), [int(h), int(l)]] for w, h, l in re.findall(r'`RESERVED\((\d+), (\d+), (\d+)\)', props))
    assert reserved == sorted(core['reserved_bits']), 'proof reserved bits'
    # Selector wiring in the RTL.
    sel = {n: (w, b) for n, w, b, _ in core['selectors']}
    for name, wire in [('timer0.start', 't0_start_sel'), ('timer0.stop', 't0_stop_sel'), ('timer0.aux', 't0_aux_sel'),
                       ('timer1.start', 't1_start_sel'), ('timer1.stop', 't1_stop_sel'), ('timer1.aux', 't1_aux_sel')]:
        w, (h, l) = sel[name]
        assert f'{wire}=word[{w}][{h}:{l}]' in rtl, name
    layout = core['word_layout']
    for group, array, first_name in [('event_selectors', 'ev_sel', 'event'), ('level_selectors', 'lv_sel', 'level')]:
        base = layout[group][0]
        assert sel[f'{first_name}0'] == (base, [5, 0]) and sel[f'{first_name}1'] == (base, [11, 6])
        assert f'assign {array}[2*si]=word[{base}+si][5:0];assign {array}[2*si+1]=word[{base}+si][11:6];' in rtl
    base = layout['outputs'][0]
    assert sel['out0.value'] == (base, [5, 0]) and sel['out0.enable'] == (base, [11, 6])
    assert f'assign ov_sel[si]=word[{base}+si][5:0];assign oe_sel[si]=word[{base}+si][11:6];' in rtl
    prog, settings = layout['program'], layout['settings']
    assert f'word[{prog}][9:0],word[{prog}][15:10],' in rtl and f'readback,word[{settings}][7:4],' in rtl
    # Readback slots, low slot first.
    joined = rtl.split('assign readback={')[1].split('};')[0]
    assert joined == "96'b0," + ','.join(reversed(core['readback_rtl'])), joined
    assert len(core['readback']) == 10
    # Register fields the compiler encodes by name, against the tile decodes.
    regs = core['registers']
    shifter = (ROOT / 'src/fabric_shifter.v').read_text()
    for reg, field, decl in [('coder.frame', 'pre', "wire [4:0] pre_n     = {3'b0, frame[%s]};"),
                             ('coder.frame', 'pre_value', 'wire       pre_val   = frame[%s];'),
                             ('coder.frame', 'post_value', 'wire       post_val  = frame[%s];'),
                             ('coder.frame', 'msb_first', 'wire       msb_first = frame[%s];'),
                             ('coder.frame', 'lead', 'wire       lead      = frame[%s];'),
                             ('coder.frame', 'end_on_sample', 'wire       end_on_sample = frame[%s];'),
                             ('coder.io', 'auto_pull', 'wire       auto_pull = io[%s];'),
                             ('coder.io', 'auto_push', 'wire       auto_push = io[%s];'),
                             ('coder.burst', 'burst', 'wire       burst_mode = burst[%s];'),
                             ('coder.coder2', 'crc_skip', 'wire [6:0] skip_n     = coder2[%s];'),
                             ('coder.coder2', 'link_data_only', 'wire       link_data_only = coder2[%s];')]:
        hi, lo = regs[reg]['fields'][field]
        assert decl % (f'{hi}:{lo}' if hi != lo else f'{hi}') in shifter, (reg, field)
    frame = regs['coder.frame']['fields']
    assert frame['parity'] == [11, 10] and regs['coder.frame']['parity'] == {'none': 0, 'even': 1, 'odd': 2}
    assert "wire       odd_parity = frame[11];" in shifter and "frame[11:10] != 2'd0" in shifter
    assert frame['idle'] == [15, 15] and 'wire        idle_next   = frame_next[15];' in shifter
    assert frame['length_minus_1'] == [3, 0] and 'frame[3:0]' in shifter
    assert regs['coder.coder']['fields'] == contract['resources']['coded_shifter']['coder_fields']
    shape = {k: v for k, v in contract['resources']['crc']['shape_fields'].items() if k != 'reserved'}
    assert regs['crc.shape']['fields'] == shape and regs['crc.shape']['word'] == layout['crc_registers'][0] + 6
    for name, base in [('coder.frame', 1), ('coder.io', 3), ('coder.burst', 4), ('coder.coder', 5), ('coder.coder2', 6)]:
        assert regs[name]['word'] == layout['coder_registers'][0] + base - 1, name
    crc0 = layout['crc_registers'][0]
    assert regs['crc.polynomial']['words'] == [crc0, crc0 + 1] and regs['crc.residue']['words'] == [crc0 + 2, crc0 + 3]
    gates = core['gate_enables']
    assert gates['coder.stuff_gate'] == [regs['coder.coder2']['word'], 5] and '(!coder2[5] || levels[coder2[4:0]])' in shifter
    crc_rtl = (ROOT / 'src/fabric_crc.v').read_text()
    assert gates['crc.absorb_gate'] == [crc0 + 7, 5] and "(!gate_cfg[5] || lines[{1'b1, gate_cfg[4:0]}])" in crc_rtl
    assert gates['crc.emit_gate'] == [crc0 + 7, 11] and "(!gate_cfg[11] || lines[{1'b1, gate_cfg[10:6]}])" in crc_rtl


def check_crc_shape(contract):
    """CRC shape word fields (additive mode) against the tile and the
    grid_core validity rule."""
    crc = contract['resources']['crc']
    f = crc['shape_fields']
    tile = (ROOT / 'src/fabric_crc.v').read_text()
    assert f"wire additive = shape[{f['additive'][0]}];" in tile
    assert f"wire twos     = shape[{f['twos_complement'][0]}];" in tile
    assert f"wire linked = shape[{f['linked'][0]}];" in tile
    assert f"3'd6: shape      <= cfg_data[{f['twos_complement'][0]}:0];" in tile
    assert crc['shape_word'] == crc['config_words'][6]
    core = (ROOT / 'src/grid_core.v').read_text()
    rule = (f"crc_shape_valid<=ld[8][15:{f['reserved'][1]}]==0 && !ld[8][{f['link_select'][0]}] && "
            f"!(ld[8][{f['twos_complement'][0]}] && !ld[8][{f['additive'][0]}]);")
    assert f"if(la[8]=={crc['shape_word']}) begin" in core and rule in core


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
    assert status == {'post_capture': [3, 0], 'stuff_error': [4, 4], 'manchester_violation': [5, 5], 'word_bad': [6, 6]}
    assert 'assign status = {active_r, overrun, push_pending, 6\'b0, word_bad, manch_err, stuff_err, post_cap};' in tile
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


def check_lane(contract, modules, top):
    """Lane mode: the fabric runs one lane core (page-1 words) whose
    controller the compiler assembles for."""
    lane = contract['lane']
    core = contract['lane_core']
    assert top[lane['instance']]['type'] == lane['core'] == core['module']
    # The core's controller is parameterized (its owned words), so yosys
    # names it $paramod\\grid_lane_controller\\...; exactly one such module.
    names = [n for n in modules if n == lane['controller'] or n.startswith('$paramod\\' + lane['controller'] + '\\')]
    assert len(names) == 1, names
    module = modules[names[0]]
    ports = module['ports']
    assert len(ports['events']['bits']) == lane['events'] == 8
    assert len(ports['levels']['bits']) == lane['levels'] == 8 and lane['level_wait_offset'] == 8
    assert 2 ** int(module['parameter_default_values']['ABITS'], 2) == lane['buffer_instructions']
    assert len(ports['prog_base']['bits']) == lane['program_fields']['base'][0] + 1
    last = lane['program_fields']['last']
    assert len(ports['prog_last']['bits']) == last[0] - last[1] + 1
    layout = core['word_layout']
    assert lane['program_word'] == layout['program'] and lane['idle_actions_word'] == layout['settings']
    assert lane['core_words_per_lane'] >= core['words'] and lane['lanes'] == 1
    rtl_core = (ROOT / 'src/grid_lane_core.v').read_text()
    hi, lo = lane['idle_actions_bits']
    assert f"readback,word[{lane['idle_actions_word']}][{hi}:{lo}]," in rtl_core
    # Event and level slots are the core's selectors, in order.
    assert [n for n, *_ in core['selectors'] if n.startswith('event')] == [f'event{i}' for i in range(lane['events'])]
    assert [n for n, *_ in core['selectors'] if n.startswith('level') and n[5:].isdigit()] == \
        [f'level{i}' for i in range(lane['levels'])]
    fabric = (ROOT / 'src/grid_stream_fabric.v').read_text()
    assert re.search(r'leaf_addr==%d\) begin temporal_mode<=leaf_data\[%d\];lane_mode<=leaf_data\[%d\]'
                     % (lane['mode_word'], lane['mode_exclusive_with_bit'], lane['mode_bit']), fabric)
    assert 'grid_lane_core lane_core(clk,rst_n,arm && configured && lane_mode,' in fabric
    # Page 1 reaches the core through the tree's lane leaf; lane 0 only.
    assert lane['core_page'] == 1 and lane['core_words_base'] == 0 and lane['core_words_per_lane'] == 64
    assert "wire core_cfg_we=lane_leaf[25] && !lane_leaf[24] && lane_leaf[23:22]==2'd0;" in fabric
    assert 'core_cfg_we,lane_leaf[21:16],lane_leaf[15:0],core_configured,' in fabric
    project = (ROOT / 'src/project.v').read_text()
    assert "wire page0=host_addr[9:8]==2'd0,page1=host_addr[9:8]==2'd1;" in project
    for name, word in lane['stream']['words'].items():
        assert f'host_addr[7:0]=={word}' in project, name
    # Live writes: the controller owns the core words; the core accepts timer first/period.
    first, final = lane['live_write_words']
    assert f"grid_lane_controller #(.OWN_FIRST(8'd{first}),.OWN_LAST(8'd{final})) ctl(" in rtl_core
    assert lane['live_write_accepted'] == [layout['timer0'][0], layout['timer0'][0] + 1,
                                           layout['timer1'][0], layout['timer1'][0] + 1]
    assert "wire live_ok=ctl_cfg_addr<=8'd7 && !live_idx[1] && ctl_cfg_data!=16'd0 &&" in rtl_core
    # The instruction table in the RTL header comment names every opcode.
    rtl = (ROOT / 'src/grid_lane_controller.v').read_text()
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

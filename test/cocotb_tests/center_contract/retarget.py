"""Retarget the original black-box fixture routes to the center-timer RTL."""
import json
from pathlib import Path
from .grid_route import routes

CONTRACT = json.loads((Path(__file__).parent / 'grid_3x3.json').read_text())
SOURCE = {0:'input_io', 2:'timer0', 3:'shifter0', 4:'lut',
          5:'timer1', 6:'sram0', 7:'shifter1', 8:'crc'}
SINKS = (['timer0'] * 3 + ['shifter0'] * 4 + ['output_io'] * 3 + ['lut'] * 2 +
         ['timer1'] * 3 + ['shifter1'] * 4)
OPPOSITE = [1, 0, 3, 2]
DELTA = [-3, 3, -1, 1]


def retarget(words):
    """Decode driven sources, reroute each sink, and keep constants/invalids."""
    words = list(words)
    original = list(words)
    nets = {}
    sink_words = [(i, 41 + i if i < 12 else 56 + i - 12, CONTRACT['bit_network']['sink_cells'][i], SINKS[i]) for i in range(19)]
    if words[4] & 0x100:
        sink_words += [(i, i, 8, 'crc') for i in range(77, 81)]

    def source(cell, direction, lane):
        visited = set()
        while True:
            key = cell, direction, lane
            if key in visited:
                raise ValueError('cycle in original fixture')
            visited.add(key)
            neighbor = cell + DELTA[direction]
            if not 0 <= neighbor < 9 or (direction >= 2 and neighbor // 3 != cell // 3):
                return None
            outgoing = OPPOSITE[direction]
            selection = (original[5 + neighbor * 4 + outgoing] >> (3 * lane)) & 7
            if 1 <= selection <= 4:
                if neighbor not in SOURCE or selection > len(CONTRACT['grid']['cells'][neighbor]['local_outputs']):
                    return None
                return SOURCE[neighbor], selection - 1
            if selection == 0:
                return None
            if selection >= 6 and ((outgoing < 2 and lane >= 2) or (outgoing >= 2 and lane < 2)):
                return None
            if selection == 5:
                direction = OPPOSITE[outgoing]
            elif outgoing < 2:
                direction = 2 if selection == 6 else 3
            else:
                direction = 0 if selection == 6 else 1
            cell = neighbor

    constant = {}
    for sink, addr, cell, resource in sink_words:
        selection = original[addr]
        if selection <= 1 or selection > 21:
            constant[addr] = selection
            continue
        if resource == 'lut' and selection < 6:
            constant[addr] = selection
            continue
        if selection < 6:
            origin = (SOURCE[cell], selection - 2) if cell in SOURCE and selection - 2 < len(CONTRACT['grid']['cells'][cell]['local_outputs']) else None
        else:
            direction = (selection - 6) // 4
            origin = source(cell, direction, (selection - 6) % 4)
        if origin is None:
            constant[addr] = 0
            continue
        name = f'{origin[0]}.{origin[1]}'
        net = nets.setdefault(name, {'name':name, 'source':{'resource':origin[0], 'port':origin[1]}, 'sinks':[]})
        net['sinks'].append({'resource':resource, 'port':sink})
    workload = {'name':'center-test-fixture', 'nets':list(nets.values())}
    result = routes(CONTRACT, workload, layout={'timer0':4, 'lut':2})
    if result['status'] != 'routed':
        raise ValueError('center candidate cannot route fixture: ' + result['status'])
    for addr in range(5, 41):
        words[addr] = 0
    for _, addr, _, _ in sink_words:
        words[addr] = constant.get(addr, 0)
    for route in result['routes']:
        for hop in route['hops']:
            addr = 5 + hop['from'] * 4 + hop['direction']
            shift = route['track'] * 3
            words[addr] = (words[addr] & ~(7 << shift)) | (hop['selector'] << shift)
        sink = route['sink']['port']
        addr = sink if sink >= 77 else 41 + sink if sink < 12 else 56 + sink - 12
        words[addr] = route['sink_select']
    return words

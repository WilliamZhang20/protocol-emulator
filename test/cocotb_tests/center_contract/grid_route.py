#!/usr/bin/env python3
"""Route a bounded bit-net experiment against the grid switch contract.

One path keeps its track. A multicast net may use different tracks for its
destinations. Each track's fixed turn class admits a single Manhattan path.
The search is exhaustive within this model unless the node limit is reached.
It does not assign operations to tiles or lower a source program.
"""
import argparse
import json
from pathlib import Path

from .grid_contract import DEFAULT

DIRS = [(-1, 0), (1, 0), (0, -1), (0, 1)]


def mlir_problem(contract, workload, tracks=None, layout=None):
    # Reuse endpoint and placement validation before emitting typed attributes.
    routes(contract, workload, tracks, layout, limit=1)
    grid, cfg = contract['grid'], contract['bit_network']
    count = tracks or cfg['tracks_per_direction']
    classes = ([next(c['order'] for c in cfg['turn_classes'] if i in c['tracks']) for i in range(count)]
               if count == cfg['tracks_per_direction'] else
               ['horizontal_then_vertical'] * ((count + 1) // 2) + ['vertical_then_horizontal'] * (count // 2))
    positions = {name: r['cell'] for name, r in contract['resources'].items()}
    positions.update(layout or {})
    values = cfg['selector_values']
    select = cfg['input_selector']
    # Hypothetical track counts require widened/re-encoded tile-input selectors.
    north = select['north_first']
    sink_starts = [north + count * i for i in range(4)]
    def endpoint(e):
        return '{resource = ' + json.dumps(e['resource']) + ', port = ' + str(e['port']) + ' : i64}'
    nets = ['{name = ' + json.dumps(n['name']) + ', source = ' + endpoint(n['source']) + ', sinks = [' +
            ', '.join(endpoint(s) for s in n['sinks']) + ']}' for n in workload['nets']]
    locations = ['{resource = ' + json.dumps(k) + ', cell = ' + str(v) + ' : i64}' for k,v in positions.items()]
    return ('module {\n  "spatial.grid_route_problem"() {\n'
            '    name = ' + json.dumps(workload['name']) + ',\n'
            f'    rows = {grid["rows"]} : i64, columns = {grid["columns"]} : i64,\n'
            '    tracks = [' + ', '.join(json.dumps(x) for x in classes) + '],\n'
            '    switch_selectors = [' + ', '.join(str(values[k]) + ' : i64' for k in ('zero','local_first','straight','turn_first','turn_last')) + '],\n'
            '    input_selectors = [' + ', '.join(str(x) + ' : i64' for x in [select['local_first'], *sink_starts]) + '],\n'
            '    layout = [' + ', '.join(locations) + '],\n'
            '    nets = [\n      ' + ',\n      '.join(nets) + '\n    ]\n'
            '  } : () -> ()\n}\n')


def routes(contract, workload, tracks=None, layout=None, registered=False, limit=1000000, direct=None):
    grid = contract['grid']
    netcfg = contract['bit_network']
    rows, cols = grid['rows'], grid['columns']
    tracks = tracks or netcfg['tracks_per_direction']
    if not 1 <= tracks <= 16:
        raise ValueError('tracks must be in 1..16')
    if tracks == netcfg['tracks_per_direction']:
        classes = [next(c['order'] for c in netcfg['turn_classes'] if i in c['tracks']) for i in range(tracks)]
    else:
        classes = ['horizontal_then_vertical'] * ((tracks + 1) // 2) + ['vertical_then_horizontal'] * (tracks // 2)
    resources = contract['resources']
    loc = {name: resource['cell'] for name, resource in resources.items()}
    if layout:
        if set(layout) - set(loc):
            raise ValueError('layout names unknown resource')
        loc.update(layout)
    if any(not isinstance(x, int) or not 0 <= x < rows * cols for x in loc.values()):
        raise ValueError('layout cell out of bounds')
    values = netcfg['selector_values']
    sink_selector = netcfg['input_selector']
    nets = workload['nets']
    if len({n['name'] for n in nets}) != len(nets):
        raise ValueError('duplicate net name')
    sources = [(n['source']['resource'], n['source']['port']) for n in nets]
    if len(set(sources)) != len(sources):
        raise ValueError('merge fanout destinations for duplicate source signals')
    seen_sinks = set()
    endpoints = []
    for net in nets:
        source = net['source']
        if source['resource'] not in loc:
            raise ValueError('invalid source')
        original_cell = resources[source['resource']]['cell']
        if not 0 <= source['port'] < len(grid['cells'][original_cell]['local_outputs']):
            raise ValueError('source port is not exposed by the current tile')
        for sink in net['sinks']:
            if sink['resource'] not in loc:
                raise ValueError('invalid sink resource')
            valid_regular = 0 <= sink['port'] < len(netcfg['sink_cells']) and netcfg['sink_cells'][sink['port']] == resources[sink['resource']]['cell']
            valid_crc = sink['resource'] == 'crc' and 77 <= sink['port'] <= 80
            if not (valid_regular or valid_crc):
                raise ValueError('sink port is not exposed by the current tile')
            key = (sink['resource'], sink['port'])
            if key in seen_sinks:
                raise ValueError(f'multiple drivers for {key}')
            seen_sinks.add(key)
            endpoints.append((net, sink))

    direct = direct or []

    def path(net, sink, lane):
        src = loc[net['source']['resource']]
        dest = loc[sink['resource']]
        if src == dest:
            if sink['resource'] == 'lut' and not netcfg['lut_local_feedback']:
                return None
            return {'track': lane, 'hops': [], 'sink_select': sink_selector['local_first'] + net['source']['port']}
        r, c = divmod(src, cols)
        dr, dc = divmod(dest, cols)
        steps = []
        axes = ('h', 'v') if classes[lane] == 'horizontal_then_vertical' else ('v', 'h')
        for axis in axes:
            while (c != dc if axis == 'h' else r != dr):
                direction = (3 if c < dc else 2) if axis == 'h' else (1 if r < dr else 0)
                nr, nc = r + DIRS[direction][0], c + DIRS[direction][1]
                steps.append((r * cols + c, direction, nr * cols + nc))
                r, c = nr, nc
        hops, previous = [], None
        for cell, direction, nxt in steps:
            turn = previous is not None and ((direction < 2) != (previous < 2))
            select = (values['local_first'] + net['source']['port'] if previous is None else
                      (values['turn_first'] if previous in (1, 3) else values['turn_last']) if turn else values['straight'])
            hops.append({'from': cell, 'to': nxt, 'direction': direction, 'selector': select})
            previous = direction
        north = sink_selector['north_first']
        select = (north + tracks, north, north + 3 * tracks, north + 2 * tracks)[previous] + lane
        return {'track': lane, 'hops': hops, 'sink_select': select}

    # Most-constrained routes first, stable across runs. Every candidate is
    # retained, so this ordering does not change completeness in the model.
    candidates = []
    for net, sink in endpoints:
        options = [p for i in range(tracks) if (p := path(net, sink, i)) is not None]
        if any(x['source'] == net['source'] and x['sink'] == sink for x in direct):
            options.insert(0, {'track': None, 'hops': [], 'sink_select': None, 'direct': True})
        candidates.append((net, sink, options))
    candidates.sort(key=lambda x: (len(x[2]), x[0]['name'] != 'mosi', -min((len(p['hops']) for p in x[2]), default=0), x[0]['name'], x[1]['resource'], x[1]['port']))
    occupied, chosen = {}, []
    visits = 0
    exhausted = False

    def search(index):
        nonlocal visits, exhausted
        visits += 1
        if visits > limit:
            exhausted = True
            return False
        if index == len(candidates):
            return True
        net, sink, options = candidates[index]
        for option in options:
            keys = [(hop['from'], hop['direction'], option['track']) for hop in option['hops']]
            if any(key in occupied and occupied[key] != (net['name'], hop['selector']) for key, hop in zip(keys, option['hops'])):
                continue
            added = []
            for key, hop in zip(keys, option['hops']):
                if key not in occupied:
                    occupied[key] = (net['name'], hop['selector']); added.append(key)
            chosen.append({'net': net['name'], 'source': net['source'], 'sink': sink, **option})
            if search(index + 1):
                return True
            chosen.pop()
            for key in added:
                del occupied[key]
            if exhausted:
                return False
        return False

    found = search(0)
    status = 'routed' if found else 'unknown_search_limit' if exhausted else 'unroutable_in_model'
    hop_counts = [len(x['hops']) for x in chosen] if found else []
    registered_links = None if registered is True else {tuple(x) for x in registered} if registered else set()
    def latency(route):
        return sum(1 for hop in route['hops'] if registered_links is None or (hop['from'], hop['to']) in registered_links)
    if found:
        for route in chosen:
            route['route_cycles'] = latency(route)
    return {'schema': 'spatial.grid-route-experiment.v1', 'workload': workload['name'],
            'status': status, 'track_count': tracks, 'layout': loc,
            'registered_hops': registered, 'search_nodes': visits,
            'direct_links': direct,
            'route_count': len(chosen) if found else 0, 'routes': chosen if found else [],
            'used_directed_track_segments': len(occupied) if found else None,
            'max_hops': max(hop_counts, default=0) if found else None,
            'max_route_cycles': max((latency(x) for x in chosen), default=0) if found else None,
            'limitations': ['Fixed resource placements and explicit bit nets, not full source compilation.',
                            'Each sink path uses one track and its fixed Manhattan turn order; alternate fanout trees and operation remapping are not exhaustive.',
                            'No word streams, resource scheduling, pad timing, pipeline skew compensation or physical timing.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workload', type=Path)
    parser.add_argument('--contract', type=Path, default=DEFAULT)
    parser.add_argument('--tracks', type=int)
    parser.add_argument('--layout', type=Path)
    parser.add_argument('--registered', action='store_true')
    parser.add_argument('--registered-links', type=Path, help='JSON array of directed [from_cell,to_cell] pairs')
    parser.add_argument('--direct-links', type=Path)
    parser.add_argument('--limit', type=int, default=1000000)
    parser.add_argument('--emit-mlir', action='store_true')
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text())
    workload = json.loads(args.workload.read_text())
    layout = json.loads(args.layout.read_text()) if args.layout else None
    if args.emit_mlir:
        if args.registered or args.registered_links or args.direct_links:
            parser.error('registered and direct-link variants are modeled by the exploration router only')
        print(mlir_problem(contract, workload, args.tracks, layout), end='')
        return
    direct = json.loads(args.direct_links.read_text()) if args.direct_links else None
    if args.registered and args.registered_links:
        parser.error('choose --registered or --registered-links')
    registered = json.loads(args.registered_links.read_text()) if args.registered_links else args.registered
    print(json.dumps(routes(contract, workload, args.tracks, layout, registered, args.limit, direct), indent=2))


if __name__ == '__main__':
    main()

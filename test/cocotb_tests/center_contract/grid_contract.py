#!/usr/bin/env python3
"""Inspect the hardware contract or emit its conservative bit-network graph."""
import argparse
import json
import os
from pathlib import Path

DEFAULT = Path(os.environ.get('RTL_ROOT', Path(__file__).resolve().parents[2] / 'protocol-emulator')) / 'architecture/grid_3x3.json'


def target(contract):
    """Produce a graph view; actual switch legality remains an image check."""
    network = contract['bit_network']
    grid = contract['grid']
    cells = grid['cells']
    tiles, links = [], []

    def add_tile(id, kind, operations, width=1, extra=''):
        ops = ', '.join(json.dumps(x) for x in operations)
        tiles.append(f'{{id = "{id}", resource = "{kind}", operations = [{ops}], width = {width} : i64, slots = 1 : i64, latency = 1 : i64, interval = 1 : i64{extra}}}')

    def add_link(source, dest):
        links.append(f'{{from = "{source}", to = "{dest}", width = 1 : i64, latency = {network["hop_cycles"]} : i64}}')

    for cell in cells:
        add_tile(f'cell{cell["id"]}', 'route', ['route'])
    for cell in cells:
        i, row, col = cell['id'], cell['row'], cell['column']
        assert i == row * grid['columns'] + col
        for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nr, nc = row + dr, col + dc
            if 0 <= nr < grid['rows'] and 0 <= nc < grid['columns']:
                add_link(f'cell{i}', f'cell{nr * grid["columns"] + nc}')
    for id, resource in contract['resources'].items():
        kind = resource['kind']
        cell = f'cell{resource["cell"]}'
        if kind == 'memory':
            add_tile(id, 'memory', ['read', 'write'], resource['data_width_bits'], f', depth = {resource["bytes"]} : i64')
            continue  # Word paths and arbitration are deliberately not modeled here.
        if kind == 'input_io':
            for pin in range(resource['pins']):
                port = f'{id}_{pin}'
                add_tile(port, 'input', ['input'])
                add_link(port, cell)
        elif kind == 'output_io':
            for pin in range(resource['pins']):
                port = f'{id}_{pin}'
                add_tile(port, 'output', ['output'])
                add_link(cell, port)
        elif kind == 'timer':
            extra = f', period_min = {resource["period_cycles_min"]} : i64, period_max = {resource["period_cycles_max"]} : i64'
            add_tile(id, kind, ['timer'], extra=extra)
            add_link(id, cell); add_link(cell, id)
        elif kind == 'shifter':
            add_tile(id, kind, ['shift_msb_first'], resource['width_bits_max'])
            add_link(id, cell); add_link(cell, id)
        elif kind == 'lut':
            add_tile(id, 'lut', ['lut2'])
            add_link(id, cell); add_link(cell, id)
        elif kind == 'crc':
            add_tile(id, 'crc', ['crc'], resource['width_bits_max'])
            add_link(id, cell); add_link(cell, id)
        else:
            raise ValueError(f'unsupported resource type: {kind}')
    return ('// Connectivity overapproximation: no turn classes, track conflicts, word paths, or cycle-accurate schedule.\n'
            'module {\n  "spatial.target_graph"() {\n'
            f'    name = "{contract["name"]}-bit-overapprox",\n'
            '    tiles = [\n      ' + ',\n      '.join(tiles) + '\n    ],\n'
            '    links = [\n      ' + ',\n      '.join(links) + '\n    ]\n'
            '  } : () -> ()\n}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['target', 'summary'])
    parser.add_argument('--contract', type=Path, default=DEFAULT)
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text())
    if contract['schema'] != 'protocol-emulator.grid-contract.v1':
        raise ValueError('unsupported contract schema')
    if args.mode == 'target':
        print(target(contract), end='')
    else:
        grid = contract['grid']
        for row in range(grid['rows']):
            print(' -- '.join('[' + '+'.join(cell['resources']) + ']' for cell in grid['cells'] if cell['row'] == row))
            if row + 1 < grid['rows']:
                print('  |' * grid['columns'])
        print(f"{contract['bit_network']['tracks_per_direction']} tracks/direction; combinational hops; "+
              f"{contract['memory']['bank_count']} SRAM banks; temporal control: {contract['temporal']['kind']}")
        print('Connectivity graph is an overapproximation; image legality requires selector/track checking.')


if __name__ == '__main__':
    main()

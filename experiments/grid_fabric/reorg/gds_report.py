#!/usr/bin/env python3
"""Summarize one GDS run's physical results (FABRIC_REORG.md step 7) from
its downloaded GDS_logs artifact (`gh run download RUN -n GDS_logs`):

  python3 gds_report.py RUNS_DIR [--bins 8x4]

RUNS_DIR is the run directory (`.../runs/wokwi`). Reports, as far as the
run got:
  - where it stopped (the last step directory, error.log);
  - initial and final cell placement: standard-cell area per bin of the
    core (global placement's DEF, then the last placed DEF), in % of the
    bin, so a hot spot is visible by location;
  - congestion by layer (global routing's final congestion report) and
    overflow;
  - detailed routing convergence (violations per iteration);
  - timing (worst setup/hold slack per corner from STA post-PnR, or the
    latest mid-PnR STA), area and utilization, KLayout DRC count.
"""
import argparse
import re
from pathlib import Path


def last(paths):
    paths = sorted(paths)
    return paths[-1] if paths else None


def step_dir(run, key):
    return last(p for p in run.iterdir() if p.is_dir() and key in p.name)


def def_density(path, bins):
    """Standard-cell area per bin (fraction) from a DEF's COMPONENTS, using
    the cell sizes in the DEF's own LEF-free way: placed cells' widths are
    unknown in DEF, so the cell count per bin stands in, weighted by a
    nominal cell area (counts are what changes between runs)."""
    text = path.read_text(errors='replace')
    units = int(re.search(r'UNITS DISTANCE MICRONS (\d+)', text).group(1))
    die = [int(v) / units for v in re.search(r'DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)', text).groups()]
    bx, by = bins
    grid = [[0] * bx for _ in range(by)]
    comps = re.search(r'COMPONENTS \d+ ;(.*?)END COMPONENTS', text, re.S).group(1)
    for m in re.finditer(r'- (\S+) (\S+)[^;]*?\+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \)', comps):
        master = m.group(2)
        if 'fill' in master or 'decap' in master or 'tap' in master or 'RM_IHP' in master:
            continue
        x, y = int(m.group(3)) / units, int(m.group(4)) / units
        i = min(bx - 1, max(0, int((x - die[0]) / (die[2] - die[0]) * bx)))
        j = min(by - 1, max(0, int((y - die[1]) / (die[3] - die[1]) * by)))
        grid[by - 1 - j][i] += 1
    return grid


def show_grid(title, grid):
    total = sum(map(sum, grid)) or 1
    print(f'  {title} (cells per bin, % of all; top row = top of die)')
    for row in grid:
        print('    ' + ' '.join(f'{100 * v / total:5.1f}' for v in row))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('run', type=Path)
    ap.add_argument('--bins', default='8x4')
    a = ap.parse_args()
    run = a.run
    bins = tuple(int(v) for v in a.bins.split('x'))
    steps = sorted(p.name for p in run.iterdir() if p.is_dir() and p.name[:2].isdigit())
    print(f'{run}: {len(steps)} steps, last {steps[-1] if steps else None}')
    err = run / 'error.log'
    if err.exists() and err.read_text().strip():
        print('  error:', err.read_text().strip().splitlines()[-1][:200])
    for key in ('mesh_regions', 'meshregions'):
        d = step_dir(run, key)
        if d:
            for line in next(d.glob('*.log')).read_text().splitlines():
                if 'mesh regions' in line or 'OVERFULL' in line or 'utilization' in line:
                    print('  ' + line.strip()[:200])
    fp = step_dir(run, 'openroad-floorplan')
    if fp:
        log = next(fp.glob('*.log')).read_text()
        for m in re.finditer(r'(Core area|Effective utilization):\s+(\S+)', log):
            print(f'  {m.group(1)}: {m.group(2)}')
    gpl = last(p for p in run.iterdir() if p.is_dir() and re.search(r'-openroad-globalplacement$', p.name))
    if gpl:
        log = next(gpl.glob('*.log')).read_text()
        ov = re.findall(r'GPL-0041\] Total routing overflow: (\S+)', log)
        ut = re.findall(r'GPL-0019\] Utilization:\s+(\S+)', log)
        print(f'  global placement: utilization {ut[-1] if ut else "?"} %, '
              f'final routability overflow {ov[-1] if ov else "?"}')
        d = next(gpl.glob('*.def'), None)
        if d:
            show_grid('initial placement', def_density(d, bins))
    placed = last(p for p in run.iterdir() if p.is_dir() and re.search(r'detailedplacement|resizertimingpost|globalrouting|detailedrouting', p.name) and list(p.glob('*.def')))
    if placed:
        show_grid(f'latest placement ({placed.name})', def_density(next(placed.glob('*.def')), bins))
    grt = last(p for p in run.iterdir() if p.is_dir() and p.name.endswith('-openroad-globalrouting'))
    if grt:
        log = next(grt.glob('*.log')).read_text()
        rep = log.rsplit('Final congestion report', 1)
        if len(rep) == 2:
            print('  global routing congestion (final report):')
            for line in rep[1].splitlines()[:14]:
                if re.match(r'\s*(Metal|TopMetal|Total)', line.split('] ')[-1]):
                    print('    ' + line.split('] ')[-1].strip())
    drt = last(p for p in run.iterdir() if p.is_dir() and p.name.endswith('-openroad-detailedrouting'))
    if drt:
        log = next(drt.glob('*.log')).read_text()
        it = list(zip(re.findall(r'Start (\d+)\S* optimization iteration', log),
                      re.findall(r'Number of violations = (\d+)', log)))
        print('  detailed routing violations by iteration: ' + ', '.join(f'{i}:{v}' for i, v in it[-12:]))
    sta = last(p for p in run.iterdir() if p.is_dir() and 'stapostpnr' in p.name) or \
        last(p for p in run.iterdir() if p.is_dir() and 'stamidpnr' in p.name)
    if sta:
        summ = next(sta.glob('summary.rpt'), None)
        if summ:
            print(f'  timing ({sta.name}):')
            for line in summ.read_text().splitlines()[:16]:
                print('    ' + line[:150])
    metrics = run / 'final' / 'metrics.json'
    if metrics.exists():
        import json
        m = json.loads(metrics.read_text())
        keys = ('design__instance__area__stdcell', 'design__instance__utilization', 'klayout__drc_error__count',
                'magic__drc_error__count', 'route__drc_errors', 'design__lvs_error__count',
                'timing__setup__ws', 'timing__hold__ws', 'antenna__violating__nets')
        for k in keys:
            if k in m:
                print(f'  {k}: {m[k]}')


if __name__ == '__main__':
    main()

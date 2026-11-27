# Tile-aware placement regions for the mesh chip (FABRIC_REORG.md step 7).
#
# OpenROAD places the flattened netlist with no notion of the mesh's cells.
# This step recovers each mesh cell's logic from the names that survive
# flattening and gives each cell a rectangular INCLUSIVE region laid out
# like the logical mesh (row 0 at the top, column 0 at the left), with a
# channel between regions for inter-cell routing and unassigned glue:
#
#   1. Seeds: an instance on a net named inside cell c's generate scope
#      (`...cl[c]...`), on configuration bit i (`cfg[i]`, i // CELL_BITS ==
#      c) or on the storage of configuration byte b (`store.by[b]...`,
#      8b // CELL_BITS == c) belongs to cell c.
#   2. Every other instance takes the label of the nearest seed through the
#      netlist (multi-source breadth-first search over nets with at most
#      MAX_FANOUT pins, so clock, reset and broadcast nets do not merge
#      cells); instances no seed reaches, or reached first from host /
#      stream logic, stay unconstrained.
#   3. Column widths follow the largest cell of each column and row heights
#      the largest of each row (logic area / TARGET utilization), scaled to
#      the core; each box is shrunk by MARGIN on every side (the channel).
#
# It prints the assignment, each region's box and its utilization (cell
# area over free area, SRAM and obstructions removed), so a run's log says
# whether a region was overfull before placement started.
import collections
import re

import click
import odb
from reader import click_odb

CELL = re.compile(r"(?:^|[./])cl\[(\d+)\]\.")
CFG = re.compile(r"^(?:.*\.)?cfg\[(\d+)\]$")
STORE = re.compile(r"^store\.by\[(\d+)\]\.")           # configuration byte b's storage
OTHER = re.compile(r"^(host|fabric\.memory|fabric\.rd|fabric\.wr|store\.(?!by))\.?")


def fixed(inst):
    if inst.getMaster().isBlock():
        return True
    try:
        return str(inst.getPlacementStatus()).upper() in ("FIRM", "LOCKED", "COVER")
    except Exception:
        return False


@click.command()
@click.option("--rows", default=3, type=int)
@click.option("--cols", default=5, type=int)
@click.option("--cell-bits", default=512, type=int)
@click.option("--margin", default=4.0, type=float, help="channel half-width, um")
@click.option("--target", default=0.55, type=float, help="planned region utilization")
@click.option("--max-fanout", default=24, type=int)
@click_odb
def regions(reader, rows, cols, cell_bits, margin, target, max_fanout):
    block = reader.block
    dbu = block.getDefUnits()
    n = rows * cols
    label = {}
    insts = [i for i in block.getInsts() if not i.getMaster().isBlock()
             and not i.getMaster().getName().startswith(("sg13cmos5l_fill", "sg13cmos5l_decap"))
             and not fixed(i)]

    def seed(net):
        name = net.getName()
        m = CELL.search(name)
        if m:
            return int(m.group(1))
        m = CFG.match(name)
        if m and int(m.group(1)) < n * cell_bits:
            return int(m.group(1)) // cell_bits
        m = STORE.match(name)
        if m and 8 * int(m.group(1)) < n * cell_bits:
            return 8 * int(m.group(1)) // cell_bits
        if OTHER.match(name):
            return "other"
        return None

    frontier = collections.deque()
    for net in block.getNets():
        if net.getSigType() in ("POWER", "GROUND", "CLOCK"):
            continue
        s = seed(net)
        if s is None:
            continue
        for it in net.getITerms():
            inst = it.getInst()
            if fixed(inst):
                continue
            if inst.getName() not in label:
                label[inst.getName()] = s
                frontier.append(inst)
    seeded = len(label)
    while frontier:
        inst = frontier.popleft()
        s = label[inst.getName()]
        for it in inst.getITerms():
            net = it.getNet()
            if net is None or net.getSigType() in ("POWER", "GROUND", "CLOCK"):
                continue
            pins = net.getITerms()
            if len(pins) > max_fanout:
                continue
            for other in pins:
                o = other.getInst()
                if fixed(o) or o.getName() in label:
                    continue
                label[o.getName()] = s
                frontier.append(o)

    area = collections.Counter()
    members = collections.defaultdict(list)
    for inst in insts:
        s = label.get(inst.getName())
        if isinstance(s, int):
            m = inst.getMaster()
            area[s] += m.getWidth() * m.getHeight() / dbu / dbu
            members[s].append(inst)
    free = sum(1 for i in insts if not isinstance(label.get(i.getName()), int))
    total = sum(m.getWidth() * m.getHeight() for m in (i.getMaster() for i in insts)) / dbu / dbu
    print(f"[INFO] mesh regions: {len(insts)} movable instances, {seeded} seeded, "
          f"{len(insts) - free} in mesh cells ({sum(area.values()):.0f} um2 of {total:.0f}), {free} unconstrained")

    core = block.getCoreArea()
    cx0, cy0, cx1, cy1 = (core.xMin() / dbu, core.yMin() / dbu, core.xMax() / dbu, core.yMax() / dbu)
    colw = [max(area[r * cols + c] for r in range(rows)) for c in range(cols)]
    rowh = [max(area[r * cols + c] for c in range(cols)) for r in range(rows)]
    # Square-ish regions: width share by column demand, height by row demand.
    xs, ys = [cx0], [cy1]
    for w in colw:
        xs.append(xs[-1] + (cx1 - cx0) * w / sum(colw))
    for h in rowh:
        ys.append(ys[-1] - (cy1 - cy0) * h / sum(rowh))
    blockages = [(i.getBBox().xMin() / dbu, i.getBBox().yMin() / dbu, i.getBBox().xMax() / dbu,
                  i.getBBox().yMax() / dbu) for i in block.getInsts() if i.getMaster().isBlock()]
    blockages += [(b.getBBox().xMin() / dbu, b.getBBox().yMin() / dbu, b.getBBox().xMax() / dbu,
                   b.getBBox().yMax() / dbu) for b in block.getBlockages()]

    def overlap(a, b):
        w = min(a[2], b[2]) - max(a[0], b[0])
        h = min(a[3], b[3]) - max(a[1], b[1])
        return max(w, 0) * max(h, 0)

    made = 0
    for r in range(rows):
        for c in range(cols):
            cell = r * cols + c
            box = (xs[c] + margin, ys[r + 1] + margin, xs[c + 1] - margin, ys[r] - margin)
            avail = (box[2] - box[0]) * (box[3] - box[1]) - sum(overlap(box, b) for b in blockages)
            util = area[cell] / avail if avail > 0 else float("inf")
            print(f"[INFO] cell {cell} (row {r}, col {c}): {len(members[cell])} instances, {area[cell]:.0f} um2, "
                  f"box ({box[0]:.1f}, {box[1]:.1f})-({box[2]:.1f}, {box[3]:.1f}), free {avail:.0f} um2, "
                  f"utilization {util:.2f}" + ("  OVERFULL" if util > 0.9 else ""))
            if not members[cell]:
                continue
            region = odb.dbRegion_create(block, f"mesh_cell_{cell}")
            odb.dbBox_create(region, *(int(round(v * dbu)) for v in box))
            try:
                region.setRegionType(odb.dbRegionType(odb.dbRegionType.INCLUSIVE))
            except Exception:
                pass
            if hasattr(odb, "dbGroup_create"):
                group = odb.dbGroup_create(region, f"mesh_cell_{cell}")
                for inst in members[cell]:
                    group.addInst(inst)
            else:
                for inst in members[cell]:
                    region.addInst(inst)
            made += 1
    print(f"[INFO] mesh regions: {made} regions created (target utilization {target}, channel {2 * margin} um)")


if __name__ == "__main__":
    regions()

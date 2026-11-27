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


def physical(inst):
    """Tap, end-cap and filler cells: placed by the flow, not logic."""
    t = str(inst.getMaster().getType()).upper()
    n = inst.getMaster().getName().lower()
    return any(k in t for k in ("WELLTAP", "ENDCAP", "SPACER", "TIEHIGH_NEVER")) or \
        any(k in n for k in ("tap", "endcap", "fill", "decap"))


def fixed(inst):
    if inst.getMaster().isBlock() or physical(inst):
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
@click.option("--target", default=0.85, type=float, help="outside logic utilization limit (placer accounting)")
@click.option("--max-fanout", default=24, type=int)
@click.option("--enabled", default=1, type=int, help="0: leave the design unconstrained")
@click_odb
def regions(reader, rows, cols, cell_bits, margin, target, max_fanout, enabled):
    block = reader.block
    if not enabled:
        print("[INFO] mesh regions: disabled (MESH_REGIONS 0); placement unconstrained")
        return
    dbu = block.getDefUnits()
    n = rows * cols
    label = {}
    insts = [i for i in block.getInsts() if not i.getMaster().isBlock()
             and not i.getMaster().getName().startswith(("sg13cmos5l_fill", "sg13cmos5l_decap"))
             and not fixed(i)]

    def seed(net):
        name = net.getName().replace("\\", "")     # OpenROAD escapes [ ] in names
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

    if not area:
        sample = [net.getName() for net in block.getNets()][:: max(1, block.getNets().__len__() // 40)][:40]
        print("[ERROR] mesh regions: no instance was assigned to a mesh cell; sample net names:")
        for name in sample:
            print("    " + name)
        raise SystemExit(1)
    core = block.getCoreArea()
    cx0, cy0, cx1, cy1 = (core.xMin() / dbu, core.yMin() / dbu, core.xMax() / dbu, core.yMax() / dbu)
    blockages = [(i.getBBox().xMin() / dbu, i.getBBox().yMin() / dbu, i.getBBox().xMax() / dbu,
                  i.getBBox().yMax() / dbu) for i in block.getInsts() if i.getMaster().isBlock()]
    blockages += [(b.getBBox().xMin() / dbu, b.getBBox().yMin() / dbu, b.getBBox().xMax() / dbu,
                   b.getBBox().yMax() / dbu) for b in block.getBlockages()]

    def overlap(a, b):
        w = min(a[2], b[2]) - max(a[0], b[0])
        h = min(a[3], b[3]) - max(a[1], b[1])
        return max(w, 0) * max(h, 0)

    # The regions are fences: instances outside every region (host, streams,
    # word-network glue) may only use the channels. Column widths and row
    # heights are balanced on the free area each region really has (SRAM and
    # obstructions removed), then the channel widens until the outside logic
    # fits at the target utilization.
    free_area = total - sum(area.values())
    core_area = (cx1 - cx0) * (cy1 - cy0)
    blocked = sum(overlap((cx0, cy0, cx1, cy1), b) for b in blockages)
    # OpenROAD's global placer charges every region the design's whole fixed
    # standard-cell area (tap and end cells), and its movable area is the
    # cells' area inflated for pin density (run 45959386194: x1.16 in the
    # regions, x1.26 outside); size the regions on that accounting.
    taps = sum(i.getMaster().getWidth() * i.getMaster().getHeight() for i in block.getInsts()
               if physical(i)) / dbu / dbu
    INFLATE_IN, INFLATE_OUT = 1.16, 1.26
    print(f"[INFO] mesh regions: core {core_area:.0f} um2, blocked {blocked:.0f} um2, taps {taps:.0f} um2 ({len(blockages)} blockages), "
          f"cells {sum(area.values()):.0f} um2, outside {free_area:.0f} um2")

    def layout(m, cw, rh):
        xs, ys = [cx0], [cy1]
        for w in cw:
            xs.append(xs[-1] + (cx1 - cx0) * w / sum(cw))
        for h in rh:
            ys.append(ys[-1] - (cy1 - cy0) * h / sum(rh))
        boxes = {r * cols + c: (xs[c] + m, ys[r + 1] + m, xs[c + 1] - m, ys[r] - m)
                 for r in range(rows) for c in range(cols)}
        boxa = {k: (b[2] - b[0]) * (b[3] - b[1]) if b[2] > b[0] and b[3] > b[1] else 1.0 for k, b in boxes.items()}
        avail = {k: max(1.0, boxa[k] - taps - sum(overlap(b, x) for x in blockages)) for k, b in boxes.items()}
        util = {k: INFLATE_IN * area[k] / avail[k] for k in boxes}
        outside = core_area - blocked - taps - sum(boxa.values())
        return boxes, avail, util, outside

    limit = 0.85                                 # a cell region, on the placer's accounting (GPL-0301 at 1.0)
    cw = [float(max(area[r * cols + c] for r in range(rows))) for c in range(cols)]
    rh = [float(max(area[r * cols + c] for c in range(cols))) for r in range(rows)]
    best = None
    for m in [margin + k for k in range(0, 40)]:
        for _ in range(60):                      # balance on the free area at this channel width
            boxes, avails, util, outside = layout(m, cw, rh)
            mean = sum(util.values()) / len(util)
            for c in range(cols):
                cw[c] *= (max(util[r * cols + c] for r in range(rows)) / mean) ** 0.3
            for r in range(rows):
                rh[r] *= (max(util[r * cols + c] for c in range(cols)) / mean) ** 0.3
        boxes, avails, util, outside = layout(m, cw, rh)
        worst = max(util.values())
        fu = INFLATE_OUT * free_area / outside if outside > 0 else float("inf")
        score = max(fu / target, worst / limit)
        print(f"[INFO] mesh regions: channel {2 * m:.0f} um: worst cell region {worst:.2f}, outside logic {fu:.2f}")
        if best is None or score < best[0]:
            best = (score, m, boxes, avails, worst, fu)
        if fu <= target and worst <= limit:
            break
        if fu <= target:
            break                                # wider channels only fill the cells more
    _, margin, boxes, avails, worst, fu = best
    if best[0] > 1.15:
        print("[ERROR] mesh regions: no channel width fits the cells and the outside logic on the placer's "
              "accounting; the regions are infeasible at this utilization")
        raise SystemExit(1)
    print(f"[INFO] mesh regions: chose channel {2 * margin:.0f} um: worst cell region {worst:.2f}, "
          f"outside logic {fu:.2f} of its channels" + ("  OVER LIMITS" if best[0] > 1 else ""))
    made = 0
    for r in range(rows):
        for c in range(cols):
            cell = r * cols + c
            box = boxes[cell]
            avail = avails[cell]
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

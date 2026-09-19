# Rewrite the tile Metal4 PDN over the IHP SRAM so its rails become the PDN.
#
# Modeled on ihp-um-janestreet-prism/odb_stripes.py, specialized for the
# single 1024x8 RM_IHPSG13 SRAM in this project (three Metal4 power pins).
# Unlike prism we have no CFGMEM macros and no multi-region allocate_sram:
# every LEF VDD! / VDDARRAY! / VSS! column gets a full-height stripe.
#
#   1. Collect Metal4 pin columns from the placed macro's LEF geometry.
#   2. Destroy every VPWR/VGND Metal4 stripe (and pin boxes / rail vias)
#      that intersects the SRAM footprint.
#   3. Draw full-height Metal4 stripes on those pin columns, core bottom→top.
#   4. Recreate M1↔M4 via stacks where the new stripes cross stdcell rails
#      outside the macro.
#   5. Tidy so each stripe x has exactly one full-height box + matching pin
#      (refusing to extend any partial that would cross the SRAM off-column).
import click
import odb
from reader import click_odb


SRAM_PINS = {
    "VPWR": ("VDD!", "VDDARRAY!"),
    "VGND": ("VSS!",),
}


def is_sram(master):
    return (
        master.findMTerm("VDD!") is not None
        and master.findMTerm("VSS!") is not None
    )


@click.command()
@click.option("--layer", default="Metal4", help="Vertical PDN layer")
@click_odb
def extend(reader, layer):
    block = reader.block
    tech = reader.tech
    m = tech.findLayer(layer)
    if m is None:
        raise click.ClickException(f"tech layer {layer} not found")
    core = block.getCoreArea()
    ylo, yhi = core.yMin(), core.yMax()
    dbu = block.getDefUnits()

    # pdngen via stacks joining a Metal1 rail to a Metal4 stripe (2.1 um).
    rail_vias = []
    for prefix in ("via1_2_2100_440", "via2_3_2100_440", "via3_4_2100_440"):
        found = [v for v in block.getVias() if v.getName().startswith(prefix)]
        if found:
            rail_vias.append(found[0])

    # Signal pins of the tile: a full-height stripe may not sit under one.
    pin_xs = []
    for bterm in block.getBTerms():
        if bterm.getSigType() in ("POWER", "GROUND"):
            continue
        for bpin in bterm.getBPins():
            for box in bpin.getBoxes():
                pin_xs.append((box.xMin(), box.xMax()))

    # SRAM footprints + legal column x-ranges (die frame), for tidy().
    sram_cols = {"VPWR": [], "VGND": []}
    sram_boxes = []
    for inst in block.getInsts():
        master = inst.getMaster()
        if not master.isBlock() or not is_sram(master):
            continue
        ib = inst.getBBox()
        ox = ib.xMin()
        sram_boxes.append((ib.xMin(), ib.xMax()))
        for nn, pins in SRAM_PINS.items():
            for pin_name in pins:
                mterm = master.findMTerm(pin_name)
                if mterm is None:
                    continue
                for mpin in mterm.getMPins():
                    for box in mpin.getGeometry():
                        if (
                            box.getTechLayer() is not None
                            and box.getTechLayer().getName() == layer
                        ):
                            sram_cols[nn].append(
                                (ox + box.xMin(), ox + box.xMax())
                            )
    for nn in sram_cols:
        sram_cols[nn] = sorted(set(sram_cols[nn]))

    clearance = int(0.24 * dbu)
    full_tol = int(1.0 * dbu)

    def on_sram_column(x0, x1, nn):
        """Full-height [x0,x1] may cross an SRAM only inside a same-polarity
        LEF power column (Metal4 OBS everywhere else)."""
        for sx0, sx1 in sram_boxes:
            if x1 <= sx0 or x0 >= sx1:
                continue
            if not any(
                c0 - 0.02 * dbu <= x0 and x1 <= c1 + 0.02 * dbu
                for (c0, c1) in sram_cols[nn]
            ):
                return False
        return True

    def clear_of_pins(x0, x1):
        return all(
            x1 + clearance <= px0 or x0 - clearance >= px1
            for (px0, px1) in pin_xs
        )

    def is_full(b):
        return b.yMin() <= ylo + full_tol and b.yMax() >= yhi - full_tol

    def xkey(b):
        return int(((b.xMin() + b.xMax()) // 2) // (0.01 * dbu))

    def vertical_m4(boxes):
        return [
            b for b in boxes
            if b.getTechLayer() is not None
            and b.getTechLayer().getName() == layer
            and (b.yMax() - b.yMin()) > (b.xMax() - b.xMin())
        ]

    def tidy(net_name, swire, bpin, rails):
        """Leave exactly one full-height stripe (+ pin box) per stripe x."""
        boxes = vertical_m4(swire.getWires())
        vias = [b for b in swire.getWires() if b.getTechLayer() is None]
        pboxes = []
        if bpin is not None:
            pboxes = [
                p for p in bpin.getBoxes()
                if p.getTechLayer() is not None
                and p.getTechLayer().getName() == layer
                and (p.yMax() - p.yMin()) > (p.xMax() - p.xMin())
            ]
        groups, pgroups = {}, {}
        for b in boxes:
            groups.setdefault(xkey(b), []).append(b)
        for p in pboxes:
            pgroups.setdefault(xkey(p), []).append(p)
        dropped = extended = pins_dropped = orphans = 0
        for k, sb in sorted(groups.items()):
            x0 = min(b.xMin() for b in sb)
            x1 = max(b.xMax() for b in sb)
            cx = (x0 + x1) // 2
            full = [b for b in sb if is_full(b)]
            if full:
                keep = max(full, key=lambda b: b.yMax() - b.yMin())
                for b in sb:
                    if b is not keep:
                        odb.dbSBox_destroy(b)
                        dropped += 1
            else:
                # Mirror prism: never extend a partial through the SRAM
                # off its legal columns (would fight Metal4 OBS).
                if not (
                    on_sram_column(x0, x1, net_name) and clear_of_pins(x0, x1)
                ):
                    print(
                        f"[WARNING] {net_name}: partial-height stripe at "
                        f"x={cx/dbu:.2f} um blocked from full height"
                    )
                    continue
                for b in sb:
                    odb.dbSBox_destroy(b)
                keep = odb.dbSBox_create(swire, m, x0, ylo, x1, yhi, "STRIPE")
                have = [
                    (v.yMin() + v.yMax()) // 2 for v in vias
                    if abs((v.xMin() + v.xMax()) // 2 - cx) < 0.5 * dbu
                ]
                new_vias = 0
                for r in rails:
                    if r.xMin() <= cx <= r.xMax():
                        ry = (r.yMin() + r.yMax()) // 2
                        if not any(abs(h - ry) < 0.3 * dbu for h in have):
                            for via in rail_vias:
                                odb.dbSBox_create(swire, via, cx, ry, "STRIPE")
                            new_vias += 1
                extended += 1
                print(
                    f"[INFO] {net_name}: {len(sb)} partial-height segments at "
                    f"x={cx/dbu:.2f} um → one full-height stripe "
                    f"(+{new_vias} rail via stacks)"
                )
            if bpin is not None:
                for p in pgroups.pop(k, []):
                    odb.dbBox_destroy(p)
                    pins_dropped += 1
                odb.dbBox_create(
                    bpin, m, keep.xMin(), keep.yMin(), keep.xMax(), keep.yMax()
                )
                pins_dropped -= 1
        for _k, ps in pgroups.items():
            for p in ps:
                odb.dbBox_destroy(p)
                orphans += 1
        print(
            f"[INFO] {net_name}: tidy: dropped {dropped} redundant segments, "
            f"extended {extended}, dropped {pins_dropped} duplicate / "
            f"{orphans} orphan pin boxes; {len(groups)} stripes remain"
        )

    def sram_columns(inst):
        """Die-frame (x0, x1) for each Metal4 power pin column, per net."""
        master = inst.getMaster()
        ox = inst.getBBox().xMin()
        cols = {"VPWR": [], "VGND": []}
        for net_name, pins in SRAM_PINS.items():
            for pin_name in pins:
                mterm = master.findMTerm(pin_name)
                if mterm is None:
                    continue
                for mpin in mterm.getMPins():
                    for box in mpin.getGeometry():
                        if (
                            box.getTechLayer() is None
                            or box.getTechLayer().getName() != layer
                        ):
                            continue
                        c = (ox + box.xMin(), ox + box.xMax())
                        if not clear_of_pins(c[0], c[1]):
                            print(
                                f"[WARNING] {inst.getName()}: {pin_name} "
                                f"column x={((c[0]+c[1])/2)/dbu:.2f} um "
                                f"sits under a tile signal pin — skipping"
                            )
                            continue
                        cols[net_name].append(c)
            cols[net_name] = sorted(set(cols[net_name]))
        return cols

    for net_name in ("VPWR", "VGND"):
        net = block.findNet(net_name)
        if net is None:
            raise click.ClickException(f"net {net_name} not found")
        swires = list(net.getSWires())
        swire = swires[0] if swires else odb.dbSWire_create(net, "ROUTED")
        stripes = vertical_m4(swire.getWires())
        rails = [
            b for b in swire.getWires()
            if b.getTechLayer() is not None
            and b.getTechLayer().getName() == "Metal1"
            and (b.xMax() - b.xMin()) > (b.yMax() - b.yMin())
        ]
        bpin = None
        for bterm in net.getBTerms():
            pins = list(bterm.getBPins())
            if pins:
                bpin = pins[0]
                break

        added = 0
        for inst in block.getInsts():
            master = inst.getMaster()
            if not master.isBlock() or not is_sram(master):
                continue
            if inst.getOrient() not in ("R0", "MX"):
                raise click.ClickException(
                    f"{inst.getName()} orientation {inst.getOrient()} "
                    "unsupported (need R0 or MX)"
                )
            ib = inst.getBBox()
            x0, x1 = ib.xMin(), ib.xMax()
            columns = sram_columns(inst)[net_name]
            if not columns:
                print(
                    f"[WARNING] {inst.getName()}: no {net_name} columns on "
                    f"{layer}"
                )
                continue

            crossing = [
                b for b in stripes if b.xMax() > x0 and b.xMin() < x1
            ]
            removed_x = [(b.xMin(), b.xMax()) for b in crossing]

            def on_removed(box):
                return any(
                    box.xMax() > rx0 and box.xMin() < rx1
                    for (rx0, rx1) in removed_x
                )

            removed = 0
            for b in crossing:
                odb.dbSBox_destroy(b)
                removed += 1
            if bpin is not None:
                for box in list(bpin.getBoxes()):
                    if (
                        box.getTechLayer() is not None
                        and box.getTechLayer().getName() == layer
                        and on_removed(box)
                    ):
                        odb.dbBox_destroy(box)
            for b in list(swire.getWires()):
                if b.getTechLayer() is None and on_removed(b):
                    odb.dbSBox_destroy(b)
            stripes = [b for b in stripes if b not in crossing]

            for c0, c1 in columns:
                stripes.append(
                    odb.dbSBox_create(swire, m, c0, ylo, c1, yhi, "STRIPE")
                )
                if bpin is not None:
                    odb.dbBox_create(bpin, m, c0, ylo, c1, yhi)
                added += 1
                cx = (c0 + c1) // 2
                for r in rails:
                    if r.xMin() <= cx <= r.xMax() and (
                        r.yMax() <= ib.yMin() or r.yMin() >= ib.yMax()
                    ):
                        ry = (r.yMin() + r.yMax()) // 2
                        for via in rail_vias:
                            odb.dbSBox_create(swire, via, cx, ry, "STRIPE")
            print(
                f"[INFO] {inst.getName()}: {net_name}: removed {removed} "
                f"crossing tile stripes; placed {len(columns)} "
                f"full-height column stripe(s) "
                f"({len(rail_vias)} via masters per rail crossing)"
            )

        print(
            f"[INFO] {net_name}: kept "
            f"{len(vertical_m4(swire.getWires())) - added} non-SRAM stripes, "
            f"added {added} SRAM-column stripe(s)"
        )
        tidy(net_name, swire, bpin, rails)


if __name__ == "__main__":
    extend()

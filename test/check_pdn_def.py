#!/usr/bin/env python3
"""Verify SRAM power topology in a final DEF (column-aligned full-height).

Usage:
  python3 test/check_pdn_def.py path/to/tt_um_protocol_emulator.def

Asserts:
  - program_memory.sram/{VSS!,VDD!,VDDARRAY!} sit on VGND / VPWR / VPWR
  - each LEF power column has a matching full-height Metal4 stripe
  - VPWR stripes through the SRAM footprint only sit on VDD!/VDDARRAY!
  - VGND stripes through the SRAM footprint only sit on VSS!
  - no leftover misaligned tile stripe remains through the footprint
  - exported VPWR/VGND pin boxes on those columns are full-height
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


INSTANCE = "program_memory.sram"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"

PIN_NET = {
    "VSS!": "VGND",
    "VDD!": "VPWR",
    "VDDARRAY!": "VPWR",
}

# LEF pin boxes in master coordinates (um); die frame = origin + local.
LEF_PINS_UM = {
    "VSS!": (21.12, 0.0, 23.93, 336.46),
    "VDD!": (69.46, 0.0, 72.27, 336.46),
    "VDDARRAY!": (117.33, 45.465, 120.14, 336.46),
}
MACRO_SIZE_UM = (146.88, 336.46)
# Stripe centre must land inside the LEF pin X; width may be pin-exact.
X_TOL_NM = 50
# Full-height: within 2 um of die bottom/top (TT pin check uses ~10 um).
EDGE_TOL_NM = 2000


def fail(msg: str) -> None:
    raise SystemExit(f"PDN DEF check error: {msg}")


def parse_units_nm(text: str) -> int:
    match = re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)\s*;", text)
    if not match:
        fail("DEF missing UNITS DISTANCE MICRONS")
    # DEF "MICRONS N" means N database units per micron → 1 dbu = 1000/N nm
    # when N=1000, dbu is nm. We keep all geometry in DEF units and report um.
    return int(match.group(1))


def parse_die(text: str) -> tuple[int, int, int, int]:
    match = re.search(
        r"DIEAREA\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+"
        r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*;",
        text,
    )
    if not match:
        fail("DEF missing DIEAREA")
    return tuple(int(g) for g in match.groups())  # type: ignore[return-value]


def parse_specialnets(text: str) -> dict[str, dict]:
    match = re.search(r"SPECIALNETS\s+\d+\s*;(.*?)END SPECIALNETS", text, re.S)
    if not match:
        fail("DEF has no SPECIALNETS section")
    body = match.group(1)
    nets: dict[str, dict] = {}
    for part in re.split(r"\n(?=    - )", body.strip()):
        part = part.strip()
        if not part.startswith("- "):
            continue
        rest = part[2:]
        name = rest.split(None, 1)[0]
        head, _, wiring = rest.partition("+")
        conns = re.findall(r"\(\s*([^\)]+?)\s*\)", head)
        rects: list[tuple[int, int, int, int]] = []
        for mm in re.finditer(
            r"(?:(?:NEW|ROUTED)\s+)?Metal4\s+(\d+)\s+\+\s+SHAPE\s+STRIPE\s+"
            r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)",
            wiring,
        ):
            width = int(mm.group(1))
            x1, y1, x2, y2 = map(int, mm.groups()[1:])
            half = width / 2.0
            if y1 == y2:
                rects.append(
                    (min(x1, x2), int(y1 - half), max(x1, x2), int(y1 + half))
                )
            elif x1 == x2:
                rects.append(
                    (int(x1 - half), min(y1, y2), int(x1 + half), max(y1, y2))
                )
            else:
                rects.append(
                    (
                        int(min(x1, x2) - half),
                        int(min(y1, y2) - half),
                        int(max(x1, x2) + half),
                        int(max(y1, y2) + half),
                    )
                )
        nets[name] = {"conns": conns, "rects": rects}
    return nets


def parse_ports(text: str) -> dict[str, list[tuple[int, int, int, int]]]:
    """PINS section: Metal4 boxes for each port name."""
    match = re.search(r"^PINS\s+\d+\s*;(.*?)END PINS", text, re.M | re.S)
    if not match:
        fail("DEF has no PINS section")
    ports: dict[str, list[tuple[int, int, int, int]]] = {}
    for part in re.split(r"\n(?=    - )", match.group(1).strip()):
        part = part.strip()
        if not part.startswith("- "):
            continue
        name = part[2:].split(None, 1)[0]
        boxes: list[tuple[int, int, int, int]] = []
        for mm in re.finditer(
            r"LAYER\s+Metal4\s*;\s*"
            r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+"
            r"\(\s*(-?\d+)\s+(-?\d+)\s*\)",
            part,
        ):
            x1, y1, x2, y2 = map(int, mm.groups())
            boxes.append((min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)))
        if boxes:
            ports[name] = boxes
    return ports


def find_sram_origin(text: str) -> tuple[int, int]:
    match = re.search(
        rf"-\s+{re.escape(INSTANCE)}\s+{re.escape(MACRO_NAME)}\s+"
        rf".*?FIXED\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)",
        text,
        re.S,
    )
    if not match:
        fail(f"could not find FIXED placement for {INSTANCE}")
    return int(match.group(1)), int(match.group(2))


def pin_on_net(conns: list[str], pin: str) -> bool:
    return any(c.strip().endswith(pin) for c in conns)


def is_vertical(r: tuple[int, int, int, int]) -> bool:
    return (r[3] - r[1]) > (r[2] - r[0])


def is_full_height(
    r: tuple[int, int, int, int], die: tuple[int, int, int, int]
) -> bool:
    return r[1] <= die[1] + EDGE_TOL_NM and r[3] >= die[3] - EDGE_TOL_NM


def centre_x(r: tuple[int, int, int, int]) -> float:
    return (r[0] + r[2]) / 2.0


def column_match(
    pin_die: tuple[float, float, float, float],
    stripe: tuple[int, int, int, int],
) -> bool:
    cx = centre_x(stripe)
    return pin_die[0] - X_TOL_NM <= cx <= pin_die[2] + X_TOL_NM


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        fail("usage: check_pdn_def.py <design.def>")
    path = Path(argv[1])
    if not path.is_file():
        fail(f"DEF not found: {path}")

    text = path.read_text(encoding="utf-8", errors="replace")
    units = parse_units_nm(text)
    die = parse_die(text)
    ox, oy = find_sram_origin(text)
    macro = (
        ox,
        oy,
        ox + int(MACRO_SIZE_UM[0] * units),
        oy + int(MACRO_SIZE_UM[1] * units),
    )
    nets = parse_specialnets(text)
    ports = parse_ports(text)

    pin_die: dict[str, tuple[float, float, float, float]] = {}
    for pin, (lx0, ly0, lx1, ly1) in LEF_PINS_UM.items():
        pin_die[pin] = (
            ox + lx0 * units,
            oy + ly0 * units,
            ox + lx1 * units,
            oy + ly1 * units,
        )

    for pin, net_name in PIN_NET.items():
        if net_name not in nets:
            fail(f"special net {net_name} missing")
        if not pin_on_net(nets[net_name]["conns"], pin):
            fail(
                f"{INSTANCE}/{pin} not on special net {net_name} "
                f"(conns={nets[net_name]['conns']})"
            )
        print(f"  {INSTANCE}/{pin} ∈ {net_name}")

    # Per-column full-height stripe + matching pin box.
    for pin, net_name in PIN_NET.items():
        pd = pin_die[pin]
        rects = [
            r for r in nets[net_name]["rects"]
            if is_vertical(r) and column_match(pd, r)
        ]
        full = [r for r in rects if is_full_height(r, die)]
        if not full:
            fail(
                f"{pin}: no full-height Metal4 {net_name} stripe on LEF "
                f"column x=[{pd[0]/units:.2f},{pd[2]/units:.2f}] um"
            )
        keep = max(full, key=lambda r: r[3] - r[1])
        print(
            f"  {pin}: full-height {net_name} stripe "
            f"x=[{keep[0]/units:.3f},{keep[2]/units:.3f}] "
            f"y=[{keep[1]/units:.3f},{keep[3]/units:.3f}] um"
        )
        pin_boxes = ports.get(net_name, [])
        matching_pins = [
            p for p in pin_boxes
            if is_vertical(p)
            and column_match(pd, p)
            and is_full_height(p, die)
        ]
        if not matching_pins:
            fail(
                f"{pin}: no full-height {net_name} PORT box on the same "
                f"column (TT power-pin check will fail)"
            )

    # Through-footprint polarity + no misaligned leftovers.
    legal = {
        "VPWR": (pin_die["VDD!"], pin_die["VDDARRAY!"]),
        "VGND": (pin_die["VSS!"],),
    }
    for net_name, columns in legal.items():
        through = [
            r for r in nets[net_name]["rects"]
            if is_vertical(r)
            and r[2] > macro[0]
            and r[0] < macro[2]
            and r[3] > macro[1]
            and r[1] < macro[3]
        ]
        for r in through:
            if not any(column_match(c, r) for c in columns):
                fail(
                    f"{net_name}: misaligned Metal4 stripe through SRAM at "
                    f"x={centre_x(r)/units:.3f} um "
                    f"(expected only LEF {net_name} columns)"
                )
            if not is_full_height(r, die):
                fail(
                    f"{net_name}: non-full-height stripe remains through "
                    f"SRAM at x={centre_x(r)/units:.3f} um"
                )
        print(
            f"  {net_name}: {len(through)} through-SRAM stripe(s), "
            f"all column-aligned + full-height"
        )

    print("PDN DEF connectivity/topology: PASS")


if __name__ == "__main__":
    main(sys.argv)

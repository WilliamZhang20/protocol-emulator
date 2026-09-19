#!/usr/bin/env python3
"""Verify SRAM power connectivity/topology in a final DEF (not fixed coords).

Usage:
  python3 test/check_pdn_def.py path/to/tt_um_protocol_emulator.def

Checks pin membership:
  program_memory.sram/VSS!      ∈ VGND
  program_memory.sram/VDD!      ∈ VPWR
  program_memory.sram/VDDARRAY! ∈ VPWR

and that each pin has substantial Metal4 special-wire overlap at the
reachable macro boundary on its net (feeder-style attach).
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
MIN_OVERLAP_UM = {
    "VSS!": 1.0,
    "VDD!": 2.5,
    "VDDARRAY!": 1.0,
}


def fail(msg: str) -> None:
    raise SystemExit(f"PDN DEF check error: {msg}")


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


def find_sram_origin_nm(text: str) -> tuple[int, int]:
    # - program_memory.sram RM_IHPSG13... + FIXED ( x y ) N ;
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


def x_overlap(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    return max(0.0, min(a[2], b[2]) - max(a[0], b[0]))


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        fail("usage: check_pdn_def.py <design.def>")
    path = Path(argv[1])
    if not path.is_file():
        fail(f"DEF not found: {path}")

    text = path.read_text(encoding="utf-8", errors="replace")
    ox, oy = find_sram_origin_nm(text)
    macro = (
        ox,
        oy,
        ox + int(MACRO_SIZE_UM[0] * 1000),
        oy + int(MACRO_SIZE_UM[1] * 1000),
    )
    nets = parse_specialnets(text)

    for pin, net_name in PIN_NET.items():
        if net_name not in nets:
            fail(f"special net {net_name} missing")
        if not pin_on_net(nets[net_name]["conns"], pin):
            fail(
                f"{INSTANCE}/{pin} not on special net {net_name} "
                f"(conns={nets[net_name]['conns']})"
            )
        print(f"  {INSTANCE}/{pin} ∈ {net_name}")

        lx0, ly0, lx1, ly1 = LEF_PINS_UM[pin]
        pin_die = (
            ox + int(lx0 * 1000),
            oy + int(ly0 * 1000),
            ox + int(lx1 * 1000),
            oy + int(ly1 * 1000),
        )
        # Reachable boundaries: south if pin hits macro south, north likewise.
        sides = []
        if abs(pin_die[1] - macro[1]) <= 1000:
            sides.append("south")
        if abs(pin_die[3] - macro[3]) <= 1000:
            sides.append("north")
        if not sides:
            fail(f"{pin} reaches neither macro boundary")

        rects = nets[net_name]["rects"]
        min_ov = MIN_OVERLAP_UM[pin] * 1000.0
        for side in sides:
            y_edge = macro[1] if side == "south" else macro[3]
            best = 0.0
            for r in rects:
                # Boundary band: geometry that touches the macro edge
                # from outside.
                if side == "south":
                    if r[3] < y_edge - 2000 or r[1] > y_edge + 200:
                        continue
                else:
                    if r[1] > y_edge + 2000 or r[3] < y_edge - 200:
                        continue
                # Reject deep interior straps.
                if r[1] > macro[1] + 200 and r[3] < macro[3] - 200:
                    continue
                best = max(best, x_overlap(r, pin_die))
            if best < min_ov:
                fail(
                    f"{pin} {side} boundary Metal4 overlap {best/1000:.3f} um "
                    f"< {MIN_OVERLAP_UM[pin]} um"
                )
            print(
                f"  {pin} {side} feeder overlap "
                f"{best/1000:.3f} um (>= {MIN_OVERLAP_UM[pin]})"
            )

    print("PDN DEF connectivity/topology: PASS")


if __name__ == "__main__":
    main(sys.argv)

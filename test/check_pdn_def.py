#!/usr/bin/env python3
"""Verify SRAM power topology in a final DEF (paired column-aligned).

Usage:
  python3 test/check_pdn_def.py path/to/tt_um_protocol_emulator.def

Asserts:
  - program_memory.sram/{VSS!,VDD!,VDDARRAY!} sit on VGND / VPWR / VPWR
  - each declared LEF power PIN has a matching full-height Metal4 stripe
  - through-SRAM VPWR/VGND stripes only sit on legal OBS-corridor columns
  - every through-SRAM VPWR stripe has a VGND partner within pair_gap
  - exported pin boxes on those stripes are full-height
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


INSTANCE = "program_memory.sram"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
ROOT = Path(__file__).resolve().parents[1]
LEF_PATH = ROOT / "macro" / MACRO_NAME / f"{MACRO_NAME}.lef"

PIN_NET = {
    "VSS!": "VGND",
    "VDD!": "VPWR",
    "VDDARRAY!": "VPWR",
}

# Declared LEF PIN boxes in master coordinates (um).
LEF_PINS_UM = {
    "VSS!": (21.12, 0.0, 23.93, 336.46),
    "VDD!": (69.46, 0.0, 72.27, 336.46),
    "VDDARRAY!": (117.33, 45.465, 120.14, 336.46),
}
MACRO_SIZE_UM = (146.88, 336.46)
PAIR_PITCH_UM = 5.62
PAIR_GAP_UM = 6.5
X_TOL_NM = 50
EDGE_TOL_NM = 2000


def fail(msg: str) -> None:
    raise SystemExit(f"PDN DEF check error: {msg}")


def parse_units(text: str) -> int:
    match = re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)\s*;", text)
    if not match:
        fail("DEF missing UNITS DISTANCE MICRONS")
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


def legal_corridors_um() -> dict[str, list[tuple[float, float]]]:
    """Master-frame corridors by polarity (LEF OBS gaps + PINs)."""
    if not LEF_PATH.is_file():
        fail(f"LEF not found: {LEF_PATH}")
    lef = LEF_PATH.read_text(encoding="utf-8", errors="replace")
    obs_m = re.search(
        r"LAYER Metal4 SPACING.*?(?=\n\s*END)", lef, re.S
    )
    if not obs_m:
        fail("LEF has no Metal4 OBS block")
    tall = []
    for r in re.findall(
        r"RECT\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", obs_m.group(0)
    ):
        x0, y0, x1, y1 = map(float, r)
        if y1 - y0 > 50.0:
            tall.append((x0, x1))
    tall = sorted(set(tall))
    pin_w = 2.81
    gaps: list[tuple[float, float]] = []
    for i in range(len(tall) - 1):
        g0, g1 = tall[i][1], tall[i + 1][0]
        if 0 < g1 - g0 <= 4.0:
            cx = (g0 + g1) / 2.0
            half = pin_w / 2.0
            gaps.append((max(g0 + 0.05, cx - half), min(g1 - 0.05, cx + half)))
    for pin, (x0, _y0, x1, _y1) in LEF_PINS_UM.items():
        gaps.append((x0, x1))
    # unique by centre
    by_cx: dict[float, tuple[float, float]] = {}
    for x0, x1 in gaps:
        by_cx[round((x0 + x1) / 2.0, 3)] = (x0, x1)

    known = {
        (LEF_PINS_UM["VSS!"][0] + LEF_PINS_UM["VSS!"][2]) / 2.0: "VGND",
        (LEF_PINS_UM["VDD!"][0] + LEF_PINS_UM["VDD!"][2]) / 2.0: "VPWR",
        (
            LEF_PINS_UM["VDDARRAY!"][0] + LEF_PINS_UM["VDDARRAY!"][2]
        )
        / 2.0: "VPWR",
    }

    def polarity(cx: float) -> str:
        for kx, nn in known.items():
            if abs(cx - kx) <= 0.5:
                return nn
        kx = min(known, key=lambda k: abs(k - cx))
        steps = int(round((cx - kx) / PAIR_PITCH_UM))
        base = known[kx]
        if steps % 2 == 0:
            return base
        return "VGND" if base == "VPWR" else "VPWR"

    out: dict[str, list[tuple[float, float]]] = {"VPWR": [], "VGND": []}
    for cx, box in sorted(by_cx.items()):
        out[polarity(cx)].append(box)
    return out


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        fail("usage: check_pdn_def.py <design.def>")
    path = Path(argv[1])
    if not path.is_file():
        fail(f"DEF not found: {path}")

    text = path.read_text(encoding="utf-8", errors="replace")
    units = parse_units(text)
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
    corridors = legal_corridors_um()
    corridors_die = {
        nn: [
            (ox + x0 * units, ox + x1 * units) for (x0, x1) in boxes
        ]
        for nn, boxes in corridors.items()
    }

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

    # Declared PIN columns must keep a full-height stripe (LVS abstract hooks).
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
                f"PIN column x=[{pd[0]/units:.2f},{pd[2]/units:.2f}] um"
            )
        keep = max(full, key=lambda r: r[3] - r[1])
        print(
            f"  {pin}: full-height {net_name} stripe "
            f"x=[{keep[0]/units:.3f},{keep[2]/units:.3f}] um"
        )
        matching_pins = [
            p for p in ports.get(net_name, [])
            if is_vertical(p)
            and column_match(pd, p)
            and is_full_height(p, die)
        ]
        if not matching_pins:
            fail(
                f"{pin}: no full-height {net_name} PORT box on the same column"
            )

    def on_legal(nn: str, stripe: tuple[int, int, int, int]) -> bool:
        cx = centre_x(stripe)
        return any(
            c0 - X_TOL_NM <= cx <= c1 + X_TOL_NM
            for (c0, c1) in corridors_die[nn]
        )

    pair_gap = PAIR_GAP_UM * units
    through: dict[str, list[tuple[int, int, int, int]]] = {}
    for net_name in ("VPWR", "VGND"):
        through[net_name] = [
            r for r in nets[net_name]["rects"]
            if is_vertical(r)
            and r[2] > macro[0]
            and r[0] < macro[2]
            and r[3] > macro[1]
            and r[1] < macro[3]
        ]
        for r in through[net_name]:
            if not on_legal(net_name, r):
                fail(
                    f"{net_name}: misaligned Metal4 stripe through SRAM at "
                    f"x={centre_x(r)/units:.3f} um "
                    f"(not on a legal {net_name} OBS corridor)"
                )
            if not is_full_height(r, die):
                fail(
                    f"{net_name}: non-full-height stripe remains through "
                    f"SRAM at x={centre_x(r)/units:.3f} um"
                )
        print(
            f"  {net_name}: {len(through[net_name])} through-SRAM "
            f"stripe(s), all corridor-aligned + full-height"
        )

    # Pairing: every through VPWR has a VGND within pair_gap (and vice versa).
    def has_partner(
        stripe: tuple[int, int, int, int],
        others: list[tuple[int, int, int, int]],
    ) -> bool:
        cx = centre_x(stripe)
        return any(abs(centre_x(o) - cx) <= pair_gap for o in others)

    unpaired = [
        centre_x(r) / units for r in through["VPWR"]
        if not has_partner(r, through["VGND"])
    ]
    if unpaired:
        fail(
            "VPWR through-SRAM stripe(s) without VGND partner within "
            f"{PAIR_GAP_UM} um: " + ", ".join(f"{x:.2f}" for x in unpaired)
        )
    unpaired_g = [
        centre_x(r) / units for r in through["VGND"]
        if not has_partner(r, through["VPWR"])
    ]
    if unpaired_g:
        fail(
            "VGND through-SRAM stripe(s) without VPWR partner within "
            f"{PAIR_GAP_UM} um: " + ", ".join(f"{x:.2f}" for x in unpaired_g)
        )
    print(
        f"  pairing: all through-SRAM VPWR/VGND stripes partnered "
        f"(gap ≤ {PAIR_GAP_UM} um)"
    )

    print("PDN DEF connectivity/topology: PASS")


if __name__ == "__main__":
    main(sys.argv)

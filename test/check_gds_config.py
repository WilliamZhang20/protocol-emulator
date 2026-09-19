#!/usr/bin/env python3
"""Static preflight for the SRAM macro's LibreLane physical configuration.

Asserts the dynamic PDN topology contract (ODB-derived feeders/jogs), not
hardcoded die coordinates — placement, LEF pins, and PDNGen stripes decide
geometry at run time.
"""

from __future__ import annotations

import json
import re
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "src" / "config.json"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
INSTANCE_NAME = "program_memory.sram"
MACRO_DIR = ROOT / "macro" / MACRO_NAME
PDN_CONFIG_PATH = ROOT / "src" / "pdn_cfg.tcl"

REQUIRED_PROCS = (
    "tt_find_sram_inst",
    "tt_pin_bbox_on_layer",
    "tt_net_m4_rects",
    "tt_nearest_south_stub",
    "tt_nearest_north_stub",
    "tt_clip_feeder_x",
    "tt_attach_sram_pin",
    "tt_export_pin_from_stripe",
)

# Deprecated absolute edge-tab / through-macro straps (nm strings).
DEPRECATED_STRAPS = (
    "111460 80000 114270 418440",
    "159330 80050 163930 418440",
    "63940 80000 68030 418440",
    "64500 80000 68030 418440",
    "64350 79520 65930 418500",
    "111830 79520 113930 81000",
    "159330 417460 163930 419580",
    "64400 79520 68030 81000",
    "161830 417460 163930 418440",
    "160500 417460 163930 418440",
    "65500 80000 68030 81000",
    "65500 417460 68030 418440",
    "64800 80000 68030 81000",
    "64800 417460 68030 418440",
    "64350 79520 65930 81000",
    "159330 417460 162140 418440",
)


def gds_flattened_extents(path: Path) -> dict[int, list[float]]:
    """Flattened per-layer bounding boxes in um (reflection-aware SREFs)."""
    data = path.read_bytes()
    recs = []
    offset = 0
    while offset < len(data):
        require(offset + 4 <= len(data), f"truncated GDS record in {path}")
        header = data[offset:offset + 4]
        length, record_type, _ = struct.unpack(">HBB", header)
        require(
            length >= 4 and offset + length <= len(data),
            f"invalid GDS record in {path}",
        )
        recs.append((record_type, data[offset + 4:offset + length]))
        offset += length
    structs: dict[int, dict] = {}
    current = None
    for record_type, payload in recs:
        if record_type == 0x05:
            current = {"name": None, "bounds": [], "refs": []}
            structs[id(current)] = current
        elif record_type == 0x06 and current is not None:
            current["name"] = payload.rstrip(b"\x00").decode()
        elif record_type == 0x08 and current is not None:
            current["open_boundary"] = True
            current["boundary_layer"] = None
        elif (
            record_type == 0x0D
            and current is not None
            and current.get("open_boundary")
        ):
            current["boundary_layer"] = struct.unpack(">h", payload[:2])[0]
        elif (
            record_type == 0x10
            and current is not None
            and current.get("open_boundary")
            and current.get("boundary_layer") is not None
        ):
            nwords = len(payload) // 4
            points = struct.unpack(">" + "i" * nwords, payload)
            current["bounds"].append(
                (
                    current["boundary_layer"],
                    min(points[0::2]),
                    min(points[1::2]),
                    max(points[0::2]),
                    max(points[1::2]),
                )
            )
        elif record_type == 0x11 and current is not None:
            current["open_boundary"] = False
        elif record_type == 0x0A and current is not None:
            current["open_ref"] = {
                "name": None,
                "mirror": False,
                "placed": False,
            }
        elif (
            record_type == 0x1A
            and current is not None
            and current.get("open_ref") is not None
        ):
            flags = struct.unpack(">H", payload[:2])[0]
            current["open_ref"]["mirror"] = bool(flags & 0x8000)
        elif (
            record_type == 0x12
            and current is not None
            and current.get("open_ref") is not None
        ):
            current["open_ref"]["name"] = payload.rstrip(b"\x00").decode()
        elif (
            record_type == 0x10
            and current is not None
            and current.get("open_ref") is not None
        ):
            nwords = len(payload) // 4
            points = struct.unpack(">" + "i" * nwords, payload)
            ref = current["open_ref"]
            current["refs"].append(
                (ref["name"], points[0], points[1], ref["mirror"])
            )
            current["open_ref"] = None
    by_name = {s["name"]: s for s in structs.values()}
    memo: dict[str, dict[int, list[float]]] = {}

    def extents(name: str) -> dict[int, list[float]]:
        if name in memo:
            return memo[name]
        struct_def = by_name[name]
        out: dict[int, list[float]] = {}
        for layer, x0, y0, x1, y1 in struct_def["bounds"]:
            box = out.setdefault(
                layer,
                [float("inf"), float("inf"), float("-inf"), float("-inf")],
            )
            box[0] = min(box[0], x0)
            box[1] = min(box[1], y0)
            box[2] = max(box[2], x1)
            box[3] = max(box[3], y1)
        for child, dx, dy, mirror in struct_def["refs"]:
            require(
                child in by_name,
                f"GDS references unknown cell {child}",
            )
            for layer, box in extents(child).items():
                if mirror:
                    child_y0, child_y1 = -box[3], -box[2]
                else:
                    child_y0, child_y1 = box[1], box[3]
                merged = out.setdefault(
                    layer,
                    [
                        float("inf"),
                        float("inf"),
                        float("-inf"),
                        float("-inf"),
                    ],
                )
                merged[0] = min(merged[0], box[0] + dx)
                merged[1] = min(merged[1], child_y0 + dy)
                merged[2] = max(merged[2], box[2] + dx)
                merged[3] = max(merged[3], child_y1 + dy)
        memo[name] = out
        return out

    raw = extents(MACRO_NAME)
    return {
        layer: [v * 0.001 for v in box] for layer, box in raw.items()
    }


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"GDS configuration error: {message}")


def main() -> None:
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    macro = config.get("MACROS", {}).get(MACRO_NAME)
    require(macro is not None, f"MACROS.{MACRO_NAME} is missing")
    require(
        INSTANCE_NAME in macro.get("instances", {}),
        f"macro placement for {INSTANCE_NAME} is missing",
    )

    placement = macro["instances"][INSTANCE_NAME]
    require(
        placement.get("orientation") == "R0",
        "SRAM must use R0 so pin transform stays trivial for PDN attach",
    )
    # Metal3 keepout below is authored in die um for this placement.
    require(
        placement.get("location") == [42, 81],
        "SRAM location must stay at [42, 81] for the Metal3 M3.f keepout",
    )

    routing_obs = config.get("ROUTING_OBSTRUCTIONS", [])
    hotspot = (174.0, 80.4, 189.4, 81.0)
    covered = any(
        ob[0] == "Metal3"
        and ob[1] <= hotspot[0]
        and ob[2] <= hotspot[1]
        and ob[3] >= hotspot[2]
        and ob[4] >= hotspot[3]
        for ob in routing_obs
    )
    require(
        covered,
        "Metal3 keepout must cover the SRAM M3.f hotspot "
        f"(at least {hotspot})",
    )

    expected_views = {
        "gds": MACRO_DIR / f"{MACRO_NAME}.gds",
        "lef": MACRO_DIR / f"{MACRO_NAME}.lef",
        "spice": MACRO_DIR / f"{MACRO_NAME}.cdl",
    }
    for view, path in expected_views.items():
        require(path.is_file(), f"{view.upper()} view does not exist: {path}")
        require(macro.get(view), f"MACROS.{MACRO_NAME}.{view} is empty")

    lef = expected_views["lef"].read_text(encoding="utf-8")
    for pin, use in (
        ("VDD!", "POWER"),
        ("VDDARRAY!", "POWER"),
        ("VSS!", "GROUND"),
    ):
        require(f"PIN {pin}" in lef, f"SRAM LEF has no {pin} pin")
        require(
            f"USE {use} ;" in lef,
            f"SRAM LEF has no {use} pin declaration",
        )
    require(
        "LAYER Metal4 ;" in lef,
        "SRAM power geometry is not exposed on Metal4",
    )
    extents = gds_flattened_extents(expected_views["gds"])
    for layer in (16, 25):
        if layer in extents:
            x0, y0, x1, y1 = extents[layer]
            require(
                x0 >= 0 and y0 >= 0 and x1 <= 146.88 and y1 <= 336.46,
                f"SRAM GDS layer {layer} protrudes past the LEF boundary: "
                f"[{x0:.3f}, {y0:.3f}, {x1:.3f}, {y1:.3f}]",
            )

    hooks = set(config.get("PDN_MACRO_CONNECTIONS", []))
    for hook in (
        f"{INSTANCE_NAME} VPWR VGND VDD! VSS!",
        f"{INSTANCE_NAME} VPWR VGND VDDARRAY! VSS!",
    ):
        require(hook in hooks, f"missing supply hook: {hook}")

    require(
        config.get("MAGIC_DRC_USE_GDS") in (0, False),
        "Magic must use the DEF/LEF view instead of rechecking "
        "foundry SRAM internals",
    )
    require(
        config.get("PDN_MULTILAYER") in (0, False),
        "PDN_MULTILAYER must be disabled for the Metal4-only grid",
    )
    require(
        config.get("PDN_CFG") == "dir::pdn_cfg.tcl",
        "custom PDN_CFG is not selected",
    )
    require(
        config.get("PDN_VERTICAL_LAYER") == "Metal4",
        "power pins must use Metal4",
    )
    for halo in (
        "FP_MACRO_HORIZONTAL_HALO",
        "FP_MACRO_VERTICAL_HALO",
        "PDN_HORIZONTAL_HALO",
        "PDN_VERTICAL_HALO",
    ):
        require(
            config.get(halo) == 0,
            f"{halo} must be zero for same-layer SRAM abutment",
        )

    pdn_config = PDN_CONFIG_PATH.read_text(encoding="utf-8")
    require(
        "-pins Metal4" in pdn_config,
        "PDN does not export Metal4-only power pins",
    )
    require(
        "TopMetal1" not in pdn_config,
        "custom PDN still routes on forbidden TopMetal1",
    )
    require(
        "Metal3" not in pdn_config,
        "custom PDN must not cross the SRAM's Metal3 obstruction",
    )

    # Dynamic topology contract: helpers must exist and be used.
    for proc in REQUIRED_PROCS:
        require(
            re.search(
                rf"\bproc\s+{re.escape(proc)}\b",
                pdn_config,
            )
            is not None,
            f"pdn_cfg.tcl missing helper proc {proc}",
        )
    require(
        "tt_attach_sram_pin" in pdn_config
        and pdn_config.count("tt_attach_sram_pin") >= 4,
        "pdngen must attach VSS/VDD/VDDARRAY via tt_attach_sram_pin",
    )
    require(
        re.search(
            r"tt_attach_sram_pin\s+.*?vdda_pin\s+.*?\{north\}",
            pdn_config,
            re.S,
        )
        is not None,
        "VDDARRAY must attach on the north side only",
    )
    require(
        "tt_export_pin_from_stripe" in pdn_config,
        "exported VPWR/VGND pins must come from real stripes",
    )
    # No absolute dbSBox strap literals — geometry comes from ODB queries.
    absolute = re.findall(
        r"odb::dbSBox_create\s+\$\w+\s+\$metal4\s*\\\s*"
        r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+STRIPE",
        pdn_config,
    )
    require(
        not absolute,
        "pdn_cfg.tcl must not hardcode Metal4 strap coordinates; "
        f"found {absolute}",
    )
    for deprecated in DEPRECATED_STRAPS:
        require(
            deprecated not in pdn_config,
            f"deprecated hardcoded strap remains: {deprecated}",
        )
    for deprecated in (
        "FP_PDN_MULTILAYER",
        "FP_PDN_VPITCH",
        "FP_PDN_VWIDTH",
    ):
        require(
            deprecated not in config,
            f"deprecated setting remains: {deprecated}",
        )

    print("GDS SRAM/PDN configuration: PASS")
    print(
        "  topology: ODB-derived feeders/jogs "
        "(no hardcoded strap coordinates)"
    )


if __name__ == "__main__":
    main()

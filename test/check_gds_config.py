#!/usr/bin/env python3
"""Static preflight for the SRAM macro's LibreLane physical configuration.

Encodes the prism-style PDN topology: normal tile GeneratePDN, then
Project.ExtendPowerStripes rewrites crossing Metal4 stripes onto the
SRAM's LEF power columns (full-height VPWR/VGND).
"""

from __future__ import annotations

import json
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "src" / "config.json"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
INSTANCE_NAME = "program_memory.sram"
MACRO_DIR = ROOT / "macro" / MACRO_NAME
PDN_CONFIG_PATH = ROOT / "src" / "pdn_cfg.tcl"
PLUGIN_PATH = ROOT / "librelane_plugin_sram_pdn.py"
ODB_SCRIPT_PATH = ROOT / "odb_sram_stripes.py"


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
        "SRAM must use R0 so Metal4 power columns keep die-frame X",
    )
    require(
        placement.get("location") == [42, 81],
        "SRAM location must stay at [42, 81]",
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
    require(
        config.get("ERROR_ON_PDN_VIOLATIONS") in (0, False),
        "ERROR_ON_PDN_VIOLATIONS must be 0 (pdngen runs before "
        "ExtendPowerStripes)",
    )
    # Prism-style signoff: Magic LEF-abstract OBS false positives on the
    # VDDARRAY! column are waived; KLayout DRC + LVS remain required.
    require(
        config.get("ERROR_ON_ILLEGAL_OVERLAPS") in (0, False),
        "ERROR_ON_ILLEGAL_OVERLAPS must be 0 (VDDARRAY! LEF OBS bar)",
    )
    require(
        config.get("RUN_MAGIC_DRC") in (0, False),
        "RUN_MAGIC_DRC must be 0 once illegal-overlap is waived",
    )
    require(
        config.get("RUN_KLAYOUT_DRC") in (1, True),
        "RUN_KLAYOUT_DRC must be on as the physical DRC signoff",
    )

    meta = config.get("meta", {})
    require(
        meta.get("flow") == "Classic",
        'meta.flow must be "Classic" when using substituting_steps '
        "(LibreLane: substituting_steps set with no flow)",
    )
    steps = meta.get("substituting_steps", {})
    require(
        steps.get("+OpenROAD.GeneratePDN") == "Project.ExtendPowerStripes",
        "meta.substituting_steps must insert Project.ExtendPowerStripes "
        "after OpenROAD.GeneratePDN",
    )
    require(
        PLUGIN_PATH.is_file(),
        f"missing LibreLane plugin: {PLUGIN_PATH}",
    )
    plugin = PLUGIN_PATH.read_text(encoding="utf-8")
    require(
        "class ExtendPowerStripes" in plugin
        and 'id = "Project.ExtendPowerStripes"' in plugin,
        "plugin must register Project.ExtendPowerStripes",
    )
    require(
        "loads_repairing_escapes" in plugin or "BAD_ESCAPE" in plugin,
        "plugin must monkeypatch netgen JSON loads for IHP \\VDD! pins",
    )
    require(
        ODB_SCRIPT_PATH.is_file(),
        f"missing ODB script: {ODB_SCRIPT_PATH}",
    )
    odb = ODB_SCRIPT_PATH.read_text(encoding="utf-8")
    for needle in (
        "VDD!",
        "VDDARRAY!",
        "VSS!",
        "dbSBox_destroy",
        "dbSBox_create",
        "STRIPE",
        "on_sram_column",
        "tidy",
    ):
        require(needle in odb, f"odb_sram_stripes.py missing {needle!r}")

    pdn_config = PDN_CONFIG_PATH.read_text(encoding="utf-8")
    require(
        "PDN_VERTICAL_LAYER" in pdn_config or "-pins Metal4" in pdn_config,
        "PDN does not export Metal4-only power pins",
    )
    require(
        "TopMetal1" not in pdn_config,
        "custom PDN still routes on forbidden TopMetal1",
    )
    require(
        "define_pdn_grid" in pdn_config
        and "stdcell_grid" in pdn_config,
        "pdn_cfg.tcl must define the stdcell PDN grid",
    )
    # No manual SRAM bridge / feeder / jog rectangles.
    require(
        "dbSBox_create" not in pdn_config,
        "pdn_cfg.tcl must not invent manual Metal4 bridge boxes; "
        "ExtendPowerStripes owns SRAM column stripes",
    )
    require(
        "tt_attach_sram_pin" not in pdn_config,
        "dynamic ODB PDN helpers must not live in pdn_cfg.tcl",
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
        "  topology: GeneratePDN + Project.ExtendPowerStripes "
        "(SRAM-column full-height Metal4)"
    )


if __name__ == "__main__":
    main()

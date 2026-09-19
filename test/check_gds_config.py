#!/usr/bin/env python3
"""Static preflight for the SRAM macro's LibreLane physical configuration.

Encodes the reference-style PDN topology (aligned boundary feeders + outside
jogs). Strap coordinates are declarative and tied to placement [42, 81].
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

SRAM_ORIGIN = (42.0, 81.0)
SRAM_SIZE = (146.88, 336.46)
SRAM_BBOX = (
    SRAM_ORIGIN[0],
    SRAM_ORIGIN[1],
    SRAM_ORIGIN[0] + SRAM_SIZE[0],
    SRAM_ORIGIN[1] + SRAM_SIZE[1],
)
PIN_VSS = (63.12, 81.0, 65.93, 417.46)
PIN_VDD = (111.46, 81.0, 114.27, 417.46)
PIN_VDDARRAY = (159.33, 126.465, 162.14, 417.46)

VDD_FEEDERS = (
    (111460, 80000, 114270, 81000),
    (111460, 417460, 114270, 418440),
)
VSS_FEEDERS = (
    (64350, 79520, 65930, 81000),
    (64350, 417460, 65930, 418500),
)
VSS_JOGS = (
    (65930, 79520, 68030, 80520),
    (65930, 417940, 68030, 418500),
)
VDDARRAY_FEEDER = (159330, 417460, 162140, 418440)
VDDARRAY_JOG = (162140, 417940, 163930, 418440)

MIN_VSS_OVERLAP_UM = 1.0
MIN_VDDARRAY_OVERLAP_UM = 1.0
M4_SPACING_UM = 0.42
VPWR_WEST_OF_VSS = (61.83, 3.56, 63.93, 80.52)


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


def nm_box_to_um(
    box: tuple[int, int, int, int],
) -> tuple[float, float, float, float]:
    return tuple(v * 0.001 for v in box)  # type: ignore[return-value]


def x_overlap_um(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
) -> float:
    return max(0.0, min(a[2], b[2]) - max(a[0], b[0]))


def outside_or_on_boundary(
    box_um: tuple[float, float, float, float],
) -> bool:
    _x0, y0, _x1, y1 = box_um
    _mx0, my0, _mx1, my1 = SRAM_BBOX
    return y1 <= my0 + 1e-9 or y0 >= my1 - 1e-9


def parse_pdn_strap_boxes(pdn_text: str) -> list[tuple[int, int, int, int]]:
    boxes: list[tuple[int, int, int, int]] = []
    for match in re.finditer(
        r"odb::dbSBox_create\s+\$\w+\s+\$metal4\s*\\\s*"
        r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+STRIPE",
        pdn_text,
    ):
        boxes.append(
            tuple(int(g) for g in match.groups())  # type: ignore[arg-type]
        )
    return boxes


def box_to_key(box: tuple[int, int, int, int]) -> str:
    return f"{box[0]} {box[1]} {box[2]} {box[3]}"


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
        "SRAM must use R0 to align its vertical Metal4 rails with the PDN",
    )
    require(
        placement.get("location") == [42, 81],
        "SRAM location must stay at [42, 81] for the pdn_cfg.tcl rail straps",
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
    require(
        config.get("PDN_VPITCH") == 50.0,
        "PDN pitch no longer aligns with SRAM rails",
    )
    require(
        config.get("PDN_VOFFSET") == 10.0,
        "PDN offset no longer aligns with SRAM rails",
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

    expected_boxes = (
        *VDD_FEEDERS,
        *VSS_FEEDERS,
        *VSS_JOGS,
        VDDARRAY_FEEDER,
        VDDARRAY_JOG,
    )
    for box in expected_boxes:
        require(
            box_to_key(box) in pdn_config,
            f"missing SRAM-aligned PDN strap: {box_to_key(box)}",
        )
    parsed = parse_pdn_strap_boxes(pdn_config)
    require(
        set(parsed) == set(expected_boxes),
        "pdn_cfg.tcl SRAM straps must be exactly the feeder/jog set "
        f"(got {sorted(parsed)})",
    )

    for feeder in VSS_FEEDERS:
        ov = x_overlap_um(nm_box_to_um(feeder), PIN_VSS)
        require(
            ov >= MIN_VSS_OVERLAP_UM,
            f"VSS feeder {feeder} pin overlap {ov:.3f} um "
            f"< {MIN_VSS_OVERLAP_UM} um",
        )
    for feeder in VDD_FEEDERS:
        ov = x_overlap_um(nm_box_to_um(feeder), PIN_VDD)
        require(
            abs(ov - (PIN_VDD[2] - PIN_VDD[0])) < 1e-6,
            f"VDD feeder {feeder} must keep full pin width "
            f"overlap, got {ov:.3f}",
        )
    ov = x_overlap_um(nm_box_to_um(VDDARRAY_FEEDER), PIN_VDDARRAY)
    require(
        ov >= MIN_VDDARRAY_OVERLAP_UM,
        f"VDDARRAY feeder pin overlap {ov:.3f} um "
        f"< {MIN_VDDARRAY_OVERLAP_UM} um",
    )

    for box in expected_boxes:
        require(
            outside_or_on_boundary(nm_box_to_um(box)),
            f"strap enters macro interior: {nm_box_to_um(box)}",
        )
    for jog in (*VSS_JOGS, VDDARRAY_JOG):
        _x0, y0, _x1, y1 = nm_box_to_um(jog)
        require(
            y1 <= SRAM_BBOX[1] + 1e-9 or y0 >= SRAM_BBOX[3] - 1e-9,
            f"horizontal jog not outside macro bbox: {nm_box_to_um(jog)}",
        )
    for feeder in VSS_FEEDERS:
        gap = nm_box_to_um(feeder)[0] - VPWR_WEST_OF_VSS[2]
        require(
            gap >= M4_SPACING_UM - 1e-9,
            f"VSS feeder only {gap:.3f} um from VPWR "
            f"(need >={M4_SPACING_UM})",
        )

    for through_macro in (
        "111460 80000 114270 418440",
        "159330 80050 163930 418440",
        "63940 80000 68030 418440",
        "64500 80000 68030 418440",
        "64350 79520 65930 418500",
    ):
        require(
            through_macro not in pdn_config,
            f"full-height Metal4 through SRAM OBS remains: {through_macro}",
        )
    for deprecated_tab in (
        "111830 79520 113930 81000",
        "159330 417460 163930 419580",
        "64400 79520 68030 81000",
        "161830 417460 163930 418440",
        "160500 417460 163930 418440",
        "65500 80000 68030 81000",
        "65500 417460 68030 418440",
        "64800 80000 68030 81000",
        "64800 417460 68030 418440",
    ):
        require(
            deprecated_tab not in pdn_config,
            f"deprecated edge-tab strap remains: {deprecated_tab}",
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
    # Guard against reintroducing the broken ODB-dynamic path.
    require(
        "tt_attach_sram_pin" not in pdn_config,
        "dynamic ODB PDN helpers must stay disabled until CI-proven",
    )

    print("GDS SRAM/PDN configuration: PASS")
    print(
        "  topology: aligned VSS/VDD/VDDARRAY feeders + outside jogs"
    )


if __name__ == "__main__":
    main()

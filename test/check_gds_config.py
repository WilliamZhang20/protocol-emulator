#!/usr/bin/env python3
"""Static preflight for the SRAM macro's LibreLane physical configuration."""

import json
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "src" / "config.json"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
INSTANCE_NAME = "program_memory.sram"
MACRO_DIR = ROOT / "macro" / MACRO_NAME
PDN_CONFIG_PATH = ROOT / "src" / "pdn_cfg.tcl"


def gds_layer_pairs(path: Path) -> set[tuple[int, int]]:
    """Return layer/purpose pairs from simple GDSII element records."""
    data = path.read_bytes()
    result = set()
    offset = 0
    layer = None
    while offset < len(data):
        require(offset + 4 <= len(data), f"truncated GDS record in {path}")
        length, record_type, _ = struct.unpack(">HBB", data[offset : offset + 4])
        require(length >= 4 and offset + length <= len(data), f"invalid GDS record in {path}")
        payload = data[offset + 4 : offset + length]
        if record_type == 0x0D:
            layer = struct.unpack(">h", payload[:2])[0]
        elif record_type in (0x0E, 0x16, 0x2A, 0x2E) and layer is not None:
            result.add((layer, struct.unpack(">h", payload[:2])[0]))
            layer = None
        offset += length
    return result


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
        "SRAM must use R0 to align its vertical Metal4 rails with the PDN",
    )
    require(
        placement.get("location") == [42, 81],
        "SRAM location must stay at [42, 81] for the Metal3 keepout abutment",
    )

    expected_obs = ["Metal3", 174.0, 80.4, 189.4, 81.0]
    routing_obs = config.get("ROUTING_OBSTRUCTIONS", [])
    require(
        expected_obs in routing_obs,
        "missing Metal3 south-edge keepout for SRAM M3.f spacing "
        f"(expected {expected_obs})",
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
    for pin, use in (("VDD!", "POWER"), ("VDDARRAY!", "POWER"), ("VSS!", "GROUND")):
        require(f"PIN {pin}" in lef, f"SRAM LEF has no {pin} pin")
        require(f"USE {use} ;" in lef, f"SRAM LEF has no {use} pin declaration")
    require("LAYER Metal4 ;" in lef, "SRAM power geometry is not exposed on Metal4")
    macro_layers = gds_layer_pairs(expected_views["gds"])
    require((16, 0) not in macro_layers, "SRAM GDS retains forbidden DigiBnd.drawing")
    require((25, 0) not in macro_layers, "SRAM GDS retains forbidden SRAM.drawing")

    hooks = set(config.get("PDN_MACRO_CONNECTIONS", []))
    for hook in (
        f"{INSTANCE_NAME} VPWR VGND VDD! VSS!",
        f"{INSTANCE_NAME} VPWR VGND VDDARRAY! VSS!",
    ):
        require(hook in hooks, f"missing supply hook: {hook}")

    require(
        config.get("MAGIC_DRC_USE_GDS") in (0, False),
        "Magic must use the DEF/LEF view instead of rechecking foundry SRAM internals",
    )
    require(
        config.get("PDN_MULTILAYER") in (0, False),
        "PDN_MULTILAYER must be disabled for the Metal4-only grid",
    )
    require(config.get("PDN_CFG") == "dir::pdn_cfg.tcl", "custom PDN_CFG is not selected")
    require(config.get("PDN_VERTICAL_LAYER") == "Metal4", "power pins must use Metal4")
    for halo in (
        "FP_MACRO_HORIZONTAL_HALO",
        "FP_MACRO_VERTICAL_HALO",
        "PDN_HORIZONTAL_HALO",
        "PDN_VERTICAL_HALO",
    ):
        require(config.get(halo) == 0, f"{halo} must be zero for same-layer SRAM abutment")
    require(config.get("PDN_VPITCH") == 50.0, "PDN pitch no longer aligns with SRAM rails")
    require(config.get("PDN_VOFFSET") == 10.0, "PDN offset no longer aligns with SRAM rails")
    pdn_config = PDN_CONFIG_PATH.read_text(encoding="utf-8")
    require("-pins Metal4" in pdn_config, "PDN does not export Metal4-only power pins")
    require("TopMetal1" not in pdn_config, "custom PDN still routes on forbidden TopMetal1")
    require("Metal3" not in pdn_config, "custom PDN must not cross the SRAM's Metal3 obstruction")
    for deprecated in ("FP_PDN_MULTILAYER", "FP_PDN_VPITCH", "FP_PDN_VWIDTH"):
        require(deprecated not in config, f"deprecated setting remains: {deprecated}")

    print("GDS SRAM/PDN configuration: PASS")


if __name__ == "__main__":
    main()

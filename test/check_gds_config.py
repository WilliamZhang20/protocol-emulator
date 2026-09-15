#!/usr/bin/env python3
"""Static preflight for the SRAM macro's LibreLane physical configuration."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "src" / "config.json"
MACRO_NAME = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
INSTANCE_NAME = "program_memory.sram"
MACRO_DIR = ROOT / "macro" / MACRO_NAME


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
        "SRAM must use R0 so its Metal4 supply rails cross the TopMetal1 PDN",
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

    hooks = set(config.get("PDN_MACRO_CONNECTIONS", []))
    for hook in (
        f"{INSTANCE_NAME} VPWR VGND VDD! VSS!",
        f"{INSTANCE_NAME} VPWR VGND VDDARRAY! VSS!",
    ):
        require(hook in hooks, f"missing supply hook: {hook}")

    require(
        config.get("PDN_MULTILAYER") in (1, True),
        "PDN_MULTILAYER must connect SRAM Metal4 rails to the TopMetal1 grid",
    )
    for deprecated in ("FP_PDN_MULTILAYER", "FP_PDN_VPITCH", "FP_PDN_VWIDTH"):
        require(deprecated not in config, f"deprecated setting remains: {deprecated}")

    print("GDS SRAM/PDN configuration: PASS")


if __name__ == "__main__":
    main()

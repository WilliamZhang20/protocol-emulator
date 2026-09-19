#!/usr/bin/env python3
"""Verify Magic-extracted SRAM power ports collapse onto VPWR/VGND.

Usage:
  python3 test/check_pdn_extract.py path/to/tt_um_protocol_emulator.spice

Pass criteria for the extracted netlist binding:
  SRAM VSS      -> VGND
  SRAM VDD      -> VPWR
  SRAM VDDARRAY -> VPWR
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


CELL = "RM_IHPSG13_1P_1024x8_c2_bm_bist"
INSTANCE_PREFIX = "Xprogram_memory.sram"


def fail(msg: str) -> None:
    raise SystemExit(f"PDN extract check error: {msg}")


def flatten_continuation(text: str) -> str:
    return re.sub(r"\n\+", " ", text)


def parse_subckt_ports(text: str, cell: str) -> list[str]:
    match = re.search(
        rf"\.subckt\s+{re.escape(cell)}\b(.*?)\n\.ends\b",
        text,
        re.I | re.S,
    )
    if not match:
        fail(f"black-box .subckt {cell} not found in spice")
    header = flatten_continuation(
        f".subckt {cell} " + match.group(1).strip()
    )
    tokens = header.split()
    # .subckt NAME ports...
    return tokens[2:]


def parse_instance_nets(text: str) -> list[str]:
    match = re.search(
        rf"^{re.escape(INSTANCE_PREFIX)}\b(.*?)\s+"
        rf"{re.escape(CELL)}\s*$",
        text,
        re.M | re.S,
    )
    if not match:
        fail(f"instance {INSTANCE_PREFIX} of {CELL} not found")
    body = flatten_continuation(match.group(1))
    return body.split()


def main(argv: list[str]) -> None:
    if len(argv) != 2:
        fail("usage: check_pdn_extract.py <extracted.spice>")
    path = Path(argv[1])
    if not path.is_file():
        fail(f"spice not found: {path}")

    text = path.read_text(encoding="utf-8", errors="replace")
    ports = parse_subckt_ports(text, CELL)
    nets = parse_instance_nets(text)
    if len(ports) != len(nets):
        fail(f"port/net count mismatch: {len(ports)} vs {len(nets)}")

    binding = dict(zip(ports, nets))
    expected = {
        "VSS": "VGND",
        "VDD": "VPWR",
        "VDDARRAY": "VPWR",
    }
    for port, net in expected.items():
        if port not in binding:
            fail(f"SRAM port {port} missing from extracted subckt")
        got = binding[port]
        if got != net:
            fail(f"SRAM {port} bound to {got}, expected {net}")
        print(f"  SRAM {port} -> {got}")

    print("PDN extracted connectivity: PASS")


if __name__ == "__main__":
    main(sys.argv)

#!/usr/bin/env python3
"""Fail if the RTL contains structurally dead logic.

Two independent detectors:
  1. Verilator -Wall: unused/undriven signals, bits, and parameters.
  2. Yosys synthesis plus `opt_dff -sat`: flip-flops that optimisation (or a
     SAT check) proves constant or never enabled, i.e. state that can be
     deleted without changing behaviour.

Usage: dead_rtl_check.py <verilator> <yosys> <top> <rtl files...>
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile

LINT_CLASSES = ("UNUSEDSIGNAL", "UNUSEDPARAM", "UNDRIVEN", "UNUSEDGENVAR")
FF_PATTERNS = (
    re.compile(r"Setting constant \d-bit at position \d+ on .*\$(?:s?dff|adff|dffe|sdffe|sdffce|aldff)"),
    re.compile(r"[Nn]ever-active"),
    re.compile(r"Removing (?:constant|unused) (?:FF|flip-flop)"),
)


def lint(verilator: str, top: str, sources: list[str]) -> list[str]:
    env = dict(os.environ)
    env.pop("VERILATOR_ROOT", None)
    result = subprocess.run(
        [verilator, "--lint-only", "-Wall", "-Wno-DECLFILENAME",
         "--top-module", top, *sources],
        capture_output=True, text=True, env=env, check=False,
    )
    return [line for line in result.stderr.splitlines()
            if line.startswith("%Warning-") and
            any(f"-{cls}:" in line for cls in LINT_CLASSES)]


def synth(yosys: str, top: str, sources: list[str]) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "synth.log")
        result = subprocess.run(
            [yosys, "-q", "-l", log, "-p",
             f"read_verilog {' '.join(sources)}; synth -flatten -top {top}; opt_dff -sat"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            sys.exit(f"yosys failed:\n{result.stdout}{result.stderr}")
        with open(log) as handle:
            text = handle.read().splitlines()
    return sorted({line.strip() for line in text
                   if any(p.search(line) for p in FF_PATTERNS)})


def main() -> int:
    verilator, yosys, top, *sources = sys.argv[1:]
    rtl = [s for s in sources if not s.endswith("_bm_bist.v")]
    findings = [f"lint: {line}" for line in lint(verilator, top, sources)
                if not any(m in line for m in ("models/", "_bm_bist"))]
    findings += [f"synth: {line}" for line in synth(yosys, top, sources)]
    for finding in findings:
        print(finding)
    print(f"dead-rtl-check: {len(rtl)} RTL files, {len(findings)} findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

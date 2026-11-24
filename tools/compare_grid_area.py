#!/usr/bin/env python3
"""Compare flattened top-level standard-cell area; SRAMs remain black boxes."""

import argparse
import hashlib
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def measure(root, yosys, liberty, log):
    makefile = (root / "Makefile").read_text()
    block = re.search(r"RTL_SOURCES := \\\n(.*?)\n\n", makefile, re.S)
    if not block:
        raise ValueError(f"Cannot find RTL_SOURCES in {root}/Makefile")
    sources = re.findall(r"src/[\w]+\.v", block.group(1))
    # Yosys parses the script itself, so reject paths requiring quoting.
    if any(c.isspace() or c in ';\"' for c in str(liberty)):
        raise ValueError("Liberty path cannot contain whitespace, semicolons or quotes")
    script = (
        "read_verilog " + " ".join(sources)
        + " src/RM_IHPSG13_1P_1024x8_c2_bm_bist.v; "
        "hierarchy -check -top tt_um_protocol_emulator; "
        "synth -top tt_um_protocol_emulator -flatten; check -assert; "
        f"dfflibmap -liberty {liberty}; abc -liberty {liberty}; "
        f"stat -liberty {liberty}"
    )
    result = subprocess.run([yosys, "-Q", "-p", script], cwd=root,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    result.check_returncode()
    area = re.findall(r"Chip area for module .*?:\s*([\d.]+)", result.stdout)
    if not area:
        raise ValueError(f"No mapped area in {log}")
    return float(area[-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--liberty", type=Path, required=True)
    parser.add_argument("--baseline", default="HEAD")
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-comparison")
    args = parser.parse_args()
    liberty = args.liberty.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sha = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory(prefix="protocol-area-baseline-") as tmp:
        archive = Path(tmp) / "baseline.tar"
        with archive.open("wb") as f:
            subprocess.run(["git", "archive", sha], cwd=ROOT, stdout=f, check=True)
        baseline = Path(tmp) / "source"
        baseline.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(baseline, filter="data")
        before = measure(baseline, args.yosys, liberty, output / "baseline.log")
        after = measure(ROOT, args.yosys, liberty, output / "current.log")
    print(f"Baseline commit: {sha}")
    print(f"Liberty SHA-256: {hashlib.sha256(liberty.read_bytes()).hexdigest()}")
    print(f"Standard-cell area, baseline: {before:.2f} µm²")
    print(f"Standard-cell area, current:  {after:.2f} µm²")
    print(f"Difference: {after-before:+.2f} µm² ({(after/before-1)*100:+.2f}%)")
    print("Both exclude the two black-box SRAM macros and physical overhead; see logs.")


if __name__ == "__main__":
    main()

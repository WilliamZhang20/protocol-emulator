#!/usr/bin/env python3
"""Synthesize two deliberately different selector topologies with Yosys."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
YOSYS = os.environ.get("YOSYS", "yosys")


def synthesize(top: str, out: Path) -> dict:
    script = (
        f"read_verilog {HERE / 'selector_candidates.v'}; "
        f"hierarchy -check -top {top}; synth -top {top}; "
        f"tee -o {out} stat -json"
    )
    subprocess.run([YOSYS, "-Q", "-T", "-p", script], check=True, stdout=subprocess.DEVNULL)
    report = json.loads(out.read_text())
    module = report["modules"][f"\\{top}"]
    cells = module["num_cells_by_type"]
    flops = sum(count for name, count in cells.items() if "DFF" in name)
    return {"generic_cells": module["num_cells"], "flip_flops": flops, "cell_types": cells}


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="routing-compare-") as tmp:
        results = {top: synthesize(top, Path(tmp) / f"{top}.json")
                   for top in ("global_selector", "flat15_selector", "local_selector")}
    print(json.dumps({"yosys": subprocess.check_output([YOSYS, "-V"], text=True).strip(),
                      "results": results}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

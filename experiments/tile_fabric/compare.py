#!/usr/bin/env python3
"""Compare the same SPI tile slice with fixed and programmable routes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
YOSYS = os.environ.get("YOSYS", "yosys")


def synthesize(top, output):
    script = (f"read_verilog {HERE.parent.parent / 'src' / 'spi_tiles.v'}; hierarchy -check -top {top}; "
              f"flatten; synth -top {top}; tee -o {output} stat -json")
    subprocess.run([YOSYS, "-Q", "-T", "-p", script], check=True, stdout=subprocess.DEVNULL)
    stats = json.loads(output.read_text())["modules"][f"\\{top}"]["num_cells_by_type"]
    cells = {name: count for name, count in stats.items() if name != "$scopeinfo"}
    return {"generic_cells": sum(cells.values()),
            "flip_flops": sum(count for name, count in cells.items() if "DFF" in name),
            "cell_types": cells}


def main():
    with tempfile.TemporaryDirectory(prefix="tile-routing-") as tmp:
        results = {top: synthesize(top, Path(tmp) / f"{top}.json")
                   for top in ("spi_fixed_routes", "spi_fabric")}
    print(json.dumps({"yosys": subprocess.check_output([YOSYS, "-V"], text=True).strip(),
                      "results": results}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

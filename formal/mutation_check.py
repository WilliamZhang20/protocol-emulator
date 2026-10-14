"""Check that focused formal targets reject representative RTL defects.

All variants are written to a temporary directory. Repository RTL is read
only; no source file is modified by this script.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Mutation:
    name: str
    target: str
    source: str
    old: str
    new: str
    sources: tuple[str, ...]
    harness: str
    top: str


MUTATIONS = (
    Mutation(
        "fifo_count_direction", "byte_fifo", "byte_fifo.v",
        "2'b10: count <= count + 1'b1;",
        "2'b10: count <= count - 1'b1;",
        ("byte_fifo.v",), "byte_fifo_properties.sv", "byte_fifo_properties",
    ),
    Mutation(
        "timer_reload_off_by_one", "fabric_timer", "fabric_timer.v",
        "count <= reload;",
        "count <= reload + 16'd1;",
        ("fabric_timer.v",), "fabric_timer_properties.sv", "fabric_timer_properties",
    ),
    Mutation(
        "timer_hold_ignored", "fabric_timer", "fabric_timer.v",
        "wire hold      = hold_en && out_r && !pins[hold_pin];",
        "wire hold      = 1'b0;",
        ("fabric_timer.v",), "fabric_timer_properties.sv", "fabric_timer_properties",
    ),
    Mutation(
        "shifter_bit_order", "fabric_shifter", "fabric_shifter.v",
        "wire [3:0] data_pos = msb_first ? (frame[3:0] - data_pos_raw) : data_pos_raw;",
        "wire [3:0] data_pos = data_pos_raw;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_parity_polarity", "fabric_shifter", "fabric_shifter.v",
        "wire parity_bit = (^(tx_word & len_mask)) ^ parity[1];",
        "wire parity_bit = (^(tx_word & len_mask)) ^ parity[0];",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_overrun_lost", "fabric_shifter", "fabric_shifter.v",
        "              overrun <= 1'b1;",
        "              overrun <= 1'b0;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
)


def run_mutation(mutation: Mutation, sby: str, scratch: Path) -> bool:
    sources = []
    for filename in mutation.sources:
        original = (ROOT / "src" / filename).read_text()
        if filename == mutation.source:
            if original.count(mutation.old) != 1:
                raise RuntimeError(f"{mutation.name}: mutation anchor is not unique")
            original = original.replace(mutation.old, mutation.new, 1)
        variant = scratch / mutation.name / filename
        variant.parent.mkdir(parents=True, exist_ok=True)
        variant.write_text(original)
        sources.append(variant)

    harness = ROOT / "formal" / mutation.target / mutation.harness
    config = scratch / mutation.name / "mutation.sby"
    config.write_text(
        "[tasks]\nbmc\n\n[options]\nmode bmc\ndepth 48\nmulticlock on\n\n"
        "[engines]\nsmtbmc boolector\n\n[script]\n"
        + "\n".join(f"read -formal -sv {source.name}" for source in sources)
        + f"\nread -formal -sv {harness.name}\nprep -top {mutation.top}\n\n"
        "[files]\n"
        + "\n".join(str(source) for source in sources)
        + f"\n{harness}\n"
    )
    result = subprocess.run(
        [sby, "-f", "-d", str(scratch / mutation.name / "run"), str(config), "bmc"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    log = result.stdout + result.stderr
    caught = result.returncode != 0 and "DONE (FAIL" in log
    if not caught:
        print(f"{mutation.name}: verification did not reject the mutation")
        print("\n".join(log.splitlines()[-12:]))
    else:
        print(f"{mutation.name}: rejected by {mutation.target} BMC")
    return caught


def main() -> int:
    sby = shutil.which("sby")
    if sby is None:
        raise RuntimeError("sby not found on PATH")
    with tempfile.TemporaryDirectory(prefix="protocol-formal-mutations-") as tmp:
        scratch = Path(tmp)
        results = [run_mutation(mutation, sby, scratch) for mutation in MUTATIONS]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

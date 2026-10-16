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


CORE_SOURCES = (
    "protocol_emulator_core.v", "px8_controller.v", "fabric_timer.v", "fabric_shifter.v", "fabric_counter.v", "fabric_crc.v", "fabric_lut.v",
)

MUTATIONS = (
    Mutation(
        "host_unsynchronized_accept", "host_interface", "host_interface.v",
        "wire stable = host_sync == host_prev;",
        "wire stable = 1'b1;",
        ("host_interface.v",), "host_interface_properties.sv", "host_interface_properties",
    ),
    Mutation(
        "host_no_post_increment", "host_interface", "host_interface.v",
        "address_register <= address_register + 1'b1;",
        "address_register <= address_register;",
        ("host_interface.v",), "host_interface_properties.sv", "host_interface_properties",
    ),
    Mutation(
        "px8_prefix_dropped", "px8_controller", "px8_controller.v",
        "oreg     <= op == OP_PFIX ? opnd[11:0] : 12'd0;",
        "oreg     <= op == OP_PFIX ? {8'd0, n} : 12'd0;",
        ("px8_controller.v",), "px8_controller_properties.sv", "px8_controller_properties",
    ),
    Mutation(
        "px8_djnz_off_by_one", "px8_controller", "px8_controller.v",
        "OP_DJNZ: if (cnt_dec != 16'd0) next_pc = opnd[9:0];",
        "OP_DJNZ: if (cnt != 16'd0) next_pc = opnd[9:0];",
        ("px8_controller.v",), "px8_controller_properties.sv", "px8_controller_properties",
    ),
    Mutation(
        "px8_level_wait_same_cycle", "px8_controller", "px8_controller.v",
        "OP_WEV:  retire = event_ready && (waiting || !opnd[5]);",
        "OP_WEV:  retire = event_ready;",
        ("px8_controller.v",), "px8_controller_properties.sv", "px8_controller_properties",
    ),
    Mutation(
        "px8_block_bytes_swapped", "px8_controller", "px8_controller.v",
        "assign cfg_data      = block ? {instruction_data, acc[7:0]} : acc;",
        "assign cfg_data      = block ? {acc[7:0], instruction_data} : acc;",
        ("px8_controller.v",), "px8_controller_properties.sv", "px8_controller_properties",
    ),
    Mutation(
        "px8_block_pointer_stuck", "px8_controller", "px8_controller.v",
        """          if (!block_last)
            ptr <= ptr + 10'd1;""",
        """          if (!block_last)
            ptr <= ptr;""",
        ("px8_controller.v",), "px8_controller_properties.sv", "px8_controller_properties",
    ),
    Mutation(
        "lut_enable_ignored", "fabric_lut", "fabric_lut.v",
        "else if (lines[{1'b0, mode[4:0]}])",
        "else",
        ("fabric_lut.v",), "fabric_lut_properties.sv", "fabric_lut_properties",
    ),
    Mutation(
        "core_arm_bypassed", "fabric_core", "protocol_emulator_core.v",
        "wire        live = enable && armed;",
        "wire        live = enable;",
        (CORE_SOURCES), "fabric_core_properties.sv", "fabric_core_properties",
    ),
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
        "wire hold       = out_r && sync[11] && (levels[sync[10:6]] ^ sync[12]);",
        "wire hold       = 1'b0;",
        ("fabric_timer.v",), "fabric_timer_properties.sv", "fabric_timer_properties",
    ),
    Mutation(
        "shifter_rx_bit_order", "fabric_shifter", "fabric_shifter.v",
        "wire [3:0] data_pos = msb_first ? (frame[3:0] - data_pos_raw) : data_pos_raw;",
        "wire [3:0] data_pos = data_pos_raw;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_tx_bit_order", "fabric_shifter", "fabric_shifter.v",
        "frame_bit_at = w[msb_first ? (frame[3:0] - raw) : raw];",
        "frame_bit_at = w[raw];",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_parity_polarity", "fabric_shifter", "fabric_shifter.v",
        "frame_bit_at = (^(w & len_mask)) ^ odd_parity;",
        "frame_bit_at = (^(w & len_mask)) ^ !odd_parity;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_overrun_lost", "fabric_shifter", "fabric_shifter.v",
        "          overrun <= 1'b1;",
        "          overrun <= 1'b0;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_burst_end_forgotten", "fabric_shifter", "fabric_shifter.v",
        "!(burst_end_seen || levels[burst[4:0]]);",
        "!levels[burst[4:0]];",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_burst_keeps_pre", "fabric_shifter", "fabric_shifter.v",
        "        index     <= pre_n;",
        "        index     <= 5'd0;",
        ("fabric_shifter.v",), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "counter_equal_restart", "fabric_counter", "fabric_counter.v",
        "default: next = data == last ? inc : 8'd1;",
        "default: next = data == last ? inc : 8'd0;",
        ("fabric_counter.v",), "fabric_counter_properties.sv", "fabric_counter_properties",
    ),
    Mutation(
        "crc_feedback_ignores_data", "fabric_crc", "fabric_crc.v",
        "wire feedback = msb ^ lines[{1'b1, absorb_cfg[10:6]}];",
        "wire feedback = msb;",
        ("fabric_crc.v",), "fabric_crc_properties.sv", "fabric_crc_properties",
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
        "[tasks]\nbmc\n\n[options]\nmode bmc\ndepth 24\n\n"
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
        timeout=600,
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

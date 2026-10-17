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
    engine: str = "smtbmc boolector"


CORE_SOURCES = (
    "protocol_emulator_core.v", "px8_controller.v", "fabric_timer.v", "fabric_shifter.v", "fabric_counter.v", "fabric_crc.v", "fabric_lut.v", "byte_tile.v", "config_bank.v",
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
        "context_write_ignores_mask", "fabric_lut", "config_bank.v",
        "wire [WIDTH-1:0] bank1_next = (we && write_bank[1]) ? data : bank1;",
        "wire [WIDTH-1:0] bank1_next = we ? data : bank1;",
        ("config_bank.v", "fabric_lut.v"), "fabric_lut_properties.sv", "fabric_lut_properties",
    ),
    Mutation(
        "context_select_inverted", "fabric_lut", "config_bank.v",
        "assign value = ctx ? bank1 : bank0;",
        "assign value = ctx ? bank0 : bank1;",
        ("config_bank.v", "fabric_lut.v"), "fabric_lut_properties.sv", "fabric_lut_properties",
    ),
    Mutation(
        "lut_enable_ignored", "fabric_lut", "fabric_lut.v",
        "else if (lines[{1'b0, mode[4:0]}])",
        "else",
        ("config_bank.v", "fabric_lut.v"), "fabric_lut_properties.sv", "fabric_lut_properties",
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
        ("config_bank.v", "fabric_timer.v"), "fabric_timer_properties.sv", "fabric_timer_properties",
    ),
    Mutation(
        "timer_hold_ignored", "fabric_timer", "fabric_timer.v",
        "wire hold       = out_r && sync[11] && (levels[sync[10:6]] ^ sync[12]);",
        "wire hold       = 1'b0;",
        ("config_bank.v", "fabric_timer.v"), "fabric_timer_properties.sv", "fabric_timer_properties",
    ),
    Mutation(
        "shifter_rx_bit_order", "fabric_shifter", "fabric_shifter.v",
        "wire [3:0] data_pos = msb_first ? (frame[3:0] - data_pos_raw) : data_pos_raw;",
        "wire [3:0] data_pos = data_pos_raw;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_tx_bit_order", "fabric_shifter", "fabric_shifter.v",
        "frame_bit_at = w[msb_first ? (frame[3:0] - raw) : raw];",
        "frame_bit_at = w[raw];",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_parity_polarity", "fabric_shifter", "fabric_shifter.v",
        "frame_bit_at = (^(w & len_mask)) ^ odd_parity ^ word_err;",
        "frame_bit_at = (^(w & len_mask)) ^ !odd_parity ^ word_err;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_overrun_lost", "fabric_shifter", "fabric_shifter.v",
        "          overrun <= 1'b1;",
        "          overrun <= 1'b0;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_burst_end_forgotten", "fabric_shifter", "fabric_shifter.v",
        "!(burst_end_seen || levels[burst[4:0]] || (burst[6] && word_eop));",
        "!(levels[burst[4:0]] || (burst[6] && word_eop));",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_burst_keeps_pre", "fabric_shifter", "fabric_shifter.v",
        "        index     <= pre_n;",
        "        index     <= 5'd0;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_injection_ignored", "fabric_shifter", "fabric_shifter.v",
        "frame_bit_at = (^(w & len_mask)) ^ odd_parity ^ word_err;",
        "frame_bit_at = (^(w & len_mask)) ^ odd_parity;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_abort_ignored", "fabric_shifter", "fabric_shifter.v",
        "        if (done || abort)",
        "        if (done)",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "shifter_rx_eop_lost", "fabric_shifter", "fabric_shifter.v",
        "push_eop  <= done && burst_mode;",
        "push_eop  <= 1'b0;",
        ("config_bank.v", "fabric_shifter.v"), "fabric_shifter_properties.sv", "fabric_shifter_properties",
    ),
    Mutation(
        "tile_escape_map_swapped", "byte_tile", "byte_tile.v",
        "wire [7:0]  mapped   = in_data == c0 ? m0 : m1;",
        "wire [7:0]  mapped   = in_data == c0 ? m1 : m0;",
        ("byte_tile.v",), "byte_tile_properties.sv", "byte_tile_roundtrip",
        engine="abc bmc3",
    ),
    Mutation(
        "tile_unescape_wrong_byte", "byte_tile", "byte_tile.v",
        "wire [7:0]  restored = in_data == m0 ? c0 : in_data == m1 ? c1 : in_data;",
        "wire [7:0]  restored = in_data == m0 ? c1 : in_data == m1 ? c1 : in_data;",
        ("byte_tile.v",), "byte_tile_properties.sv", "byte_tile_roundtrip",
        engine="abc bmc3",
    ),
    Mutation(
        "tile_checksum_not_negated", "byte_tile", "byte_tile.v",
        "p_data <= (use_xor ? acc_next : 8'd0 - acc_next) ^ {8{in_err}};",
        "p_data <= acc_next ^ {8{in_err}};",
        ("byte_tile.v",), "byte_tile_properties.sv", "byte_tile_checksum",
        engine="abc bmc3",
    ),
    Mutation(
        "tile_injection_ignored", "byte_tile", "byte_tile.v",
        "p_data <= (use_xor ? acc_next : 8'd0 - acc_next) ^ {8{in_err}};",
        "p_data <= (use_xor ? acc_next : 8'd0 - acc_next);",
        ("byte_tile.v",), "byte_tile_properties.sv", "byte_tile_checksum",
        engine="abc bmc3",
    ),
    Mutation(
        "tile_output_dropped", "byte_tile", "byte_tile.v",
        """      if (o_valid && out_ready)
        o_valid <= 1'b0;""",
        """      if (o_valid)
        o_valid <= 1'b0;""",
        ("byte_tile.v",), "byte_tile_properties.sv", "byte_tile_roundtrip",
        engine="abc bmc3",
    ),
    Mutation(
        "counter_equal_restart", "fabric_counter", "fabric_counter.v",
        "default: next = data == last ? inc : 8'd1;",
        "default: next = data == last ? inc : 8'd0;",
        ("config_bank.v", "fabric_counter.v"), "fabric_counter_properties.sv", "fabric_counter_properties",
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
        f"[engines]\n{mutation.engine}\n\n[script]\n"
        + "\n".join(f"read -formal -sv {source.name}" for source in sources)
        + f"\nread -formal -sv {harness.name}\nprep -top {mutation.top}\n\n"
        "[files]\n"
        + "\n".join(str(source) for source in sources)
        + f"\n{harness}\n"
    )
    try:
        result = subprocess.run(
            [sby, "-f", "-d", str(scratch / mutation.name / "run"), str(config), "bmc"],
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
        log = result.stdout + result.stderr
        caught = result.returncode != 0 and "DONE (FAIL" in log
    except subprocess.TimeoutExpired:
        log, caught = "timed out after 600 s", False
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

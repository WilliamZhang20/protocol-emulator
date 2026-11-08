"""One hop per cycle: no signal-space line depends combinationally on a line.

Per tile, the outputs the core places on the signal space must have no
combinational path from the tile's `lines` input (the cone stops at
flip-flops). In the core, the logic assembling `lines` must not read
`lines` (the cone stops at flip-flops and at tile instances, whose own
outputs are checked per tile). Together: every path is register, line,
selector, tile logic, register, for any configuration.

usage: one_hop_check.py <yosys> <rtl files...>
"""

import subprocess
import sys
import tempfile
from pathlib import Path

FF = "$dff,$sdff,$dffe,$sdffe,$sdffce,$adff,$adffe,$aldff,$dlatch"
TILES = ["fabric_timer", "fabric_shifter", "fabric_counter", "fabric_crc", "fabric_logic",
         "config_bank"]
# Tile outputs that the core places on the signal space directly.
LINE_OUTPUTS = {
    "fabric_timer": ["out"],
    "fabric_shifter": ["out", "active"],
    "fabric_counter": ["ge"],
    "fabric_crc": ["out", "ok"],
    "fabric_logic": ["q"],
}

yosys, sources = sys.argv[1], sys.argv[2:]
script = [f"read_verilog {' '.join(sources)}", "hierarchy -top protocol_emulator_core",
          "proc", "opt_clean"]
checks = []
for module, ports in LINE_OUTPUTS.items():
    for port in ports:
        checks.append((f"{module}.{port}",
                       f"select -set c {module}/o:{port} %ci*:-{FF}; "
                       f"select -count @c {module}/i:lines %i"))
stop = ",".join([FF] + TILES)
checks.append(("protocol_emulator_core.lines",
               f"select -set c protocol_emulator_core/w:lines %ci*:-{stop}; "
               f"select -set r protocol_emulator_core/w:lines %co1 c:* %i; "
               f"select -count @c @r %i"))
failures = []
with tempfile.TemporaryDirectory() as tmp:
    for name, check in checks:
        log = Path(tmp) / "count.txt"
        *setup, count_cmd = check.split("; ")
        cmd = script + setup + [f"tee -q -o {log} {count_cmd}"]
        result = subprocess.run([yosys, "-q", "-p", "; ".join(cmd)], capture_output=True, text=True)
        if result.returncode:
            sys.exit(result.stderr or result.stdout)
        count = int(log.read_text().split()[0])
        print(f"{name}: {'ok' if count == 0 else f'{count} line-dependent objects'}")
        if count:
            failures.append(name)
if failures:
    sys.exit(f"one-hop rule broken: {failures}")
print("one-hop-check: every signal-space line is a register output")

"""Simulate a protocol harness from reset until the program arms the fabric
(the harness's `configured` flag) and write `<name>_prearm.ys`, which
replays that deterministic prefix and stores the state as the proof's
initial state (yosys `sim -w`). Until arming the harness supplies no FIFO
bytes and constant inputs, so this prefix is the only possible one.

usage: prearm.py <yosys> <name>
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCES = ["protocol_emulator_core.v", "px8_controller.v", "fabric_timer.v", "fabric_shifter.v",
           "fabric_counter.v", "fabric_crc.v", "fabric_logic.v", "byte_tile.v", "config_bank.v"]
HERE = Path(__file__).resolve().parent
yosys, name = sys.argv[1], sys.argv[2]
if "/" in yosys:
    yosys = str(Path(yosys).resolve())
src = " ".join(str(HERE / "../../src" / f) for f in SOURCES)
with tempfile.TemporaryDirectory() as tmp:
    vcd = Path(tmp) / "pre.vcd"
    (Path(tmp) / "rom.vh").write_text((HERE / f"{name}_rom.vh").read_text())
    script = (f"read -formal -sv -I{tmp} {src} {HERE / (name + '_properties.sv')}; "
              f"prep -top {name}_properties; flatten; chformal -lower; "
              f"sim -clock clk -n 400 -vcd {vcd}")
    subprocess.run([yosys, "-q", "-p", script], check=True, cwd=tmp,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    text = vcd.read_text()
ident = re.findall(r"\$var \S+ 1 (\S+) configured \$end", text)[-1]   # the harness flag
period = None
armed_at = None
time = 0
times = []
for line in text.splitlines():
    if line.startswith("#"):
        time = int(line[1:])
        times.append(time)
    elif line in ("1" + ident, "b1 " + ident) and armed_at is None:
        armed_at = time
assert armed_at is not None, "the program never armed the fabric"
step = times[2] - times[1] if len(times) > 2 else 10
cycles = armed_at // (2 * step) if step else armed_at
cycles = max(cycles - 2, 0)                    # stop just before arming
(HERE / f"{name}_prearm.ys").write_text(
    f"# {name}: the program arms the fabric after about {cycles + 2} cycles\n"
    f"flatten\nchformal -lower\nsim -clock clk -n {cycles} -w\n")
print(f"{name}: proof starts at cycle {cycles} (deterministic configuration before it)")

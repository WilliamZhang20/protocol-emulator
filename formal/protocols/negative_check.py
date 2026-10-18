"""Each protocol proof must reject a wrong program: the proof is rerun with
the ROM assembled from a program that differs only in its timing, and the
solver must find a counterexample.

usage: negative_check.py <sby> <python> <yosys> <build dir>
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WRONG = {
    "uart_tx": "uart_transmit(5)",            # 5 cycles a bit, proof expects 4
    "ws2812": "ws2812_transmit(7, 1, 2)",     # 7-cycle bits, proof expects 6
    "spi_master": "spi_master(0, 4, 2)",      # half period 4, proof expects 3
}

sby, python, yosys, build = sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4])
failures = []
for proof, program in WRONG.items():
    rom = HERE / f"{proof}_rom.vh"
    subprocess.run([python, "gen_rom.py", rom.name, program], cwd=HERE, check=True)
    subprocess.run([python, "prearm.py", yosys, proof], cwd=HERE, check=True)
    out = build / "negative" / proof
    result = subprocess.run([sby, "-f", "-d", str(out), f"{proof}.sby", "bmc"], cwd=HERE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    rom.unlink()                              # the real proofs regenerate it
    (HERE / f"{proof}_prearm.ys").unlink()
    failed = "DONE (FAIL" in result.stdout
    print(f"{proof} with {program}: {'rejected' if failed else 'NOT REJECTED'}")
    if not failed:
        failures.append(proof)
if failures:
    sys.exit(f"proofs accepted a wrong program: {failures}")

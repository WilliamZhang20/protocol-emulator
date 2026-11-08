"""Each protocol proof must reject a wrong program: the proof is rerun with
the ROM assembled from a program that differs only in its timing, and the
solver must find a counterexample.

usage: negative_check.py <sby> <python> <yosys> <build dir> [proof ...]
(all proofs when none is named)
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WRONG = {
    "uart_tx": "uart_transmit(5)",            # 5 cycles a bit, proof expects 4
    "ws2812": "ws2812_transmit(7, 1, 2)",     # 7-cycle bits, proof expects 6
    "spi_master": "spi_master(0, 3, 2)",      # half period 3, proof expects 2
    "gpio_expander": "gpio_expander(4, 2)",   # 2 chips a chain, proof expects 1
    "quadrature_decoder": "quadrature_decoder(1, 0)",   # A and B swapped
    "vga": "vga(3, 8, 1, 1, 1, 1, 1, 2, 1)",                # 2 VSYNC lines, proof expects 1
    "vga_framebuffer": "vga_framebuffer(3, 8, 16, 12, 12, [0, 0], 1, 1, 1, 1)",  # rows of 1 line, proof expects 2
    "hdlc_receive": "hdlc_receive(HDLC_FCS_RESIDUE)",       # forgets the flag bits the CRC takes
    "hdlc_transmit": "hdlc_transmit(12)",                   # 12-cycle bits, proof expects 10
}

sby, python, yosys, build = sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4])
chosen = sys.argv[5:] or list(WRONG)
failures = []
for proof, program in ((p, WRONG[p]) for p in chosen):
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

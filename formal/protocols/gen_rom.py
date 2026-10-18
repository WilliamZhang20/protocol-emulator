"""Write a protocol program, assembled exactly as the cocotb tests load it,
as a Verilog ROM function for the protocol proofs.

usage: gen_rom.py <out.vh> <python expression over cocotb_tests.protocols>
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "test"))

from cocotb_tests import protocols  # noqa: E402

out, expression = sys.argv[1], sys.argv[2]
program = eval(expression, vars(protocols))
lines = [f"// {expression}: {len(program)} bytes", "function automatic [7:0] rom_byte(input [9:0] a);",
         "  case (a)"]
lines += [f"    10'd{i}: rom_byte = 8'h{b:02x};" for i, b in enumerate(program)]
lines += ["    default: rom_byte = 8'h00;", "  endcase", "endfunction", ""]
Path(out).write_text("\n".join(lines))

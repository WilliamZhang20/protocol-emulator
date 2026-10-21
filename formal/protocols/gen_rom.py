"""Write a protocol program, assembled exactly as the cocotb tests load it,
as a Verilog ROM function for the protocol proofs.

usage: gen_rom.py <out.vh> <python expression over cocotb_tests.protocols>
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "test"))

# Only the assembler is needed; the formal job has no cocotb installed, so
# stand in for the simulator modules the test helpers import.
try:
    import cocotb  # noqa: F401
except ImportError:
    import types
    stub = types.ModuleType("cocotb")
    stub.test = lambda *a, **k: (lambda f: f)
    stub.start_soon = None
    triggers = types.ModuleType("cocotb.triggers")
    for name in ("ClockCycles", "FallingEdge", "RisingEdge", "Timer"):
        setattr(triggers, name, None)
    clock = types.ModuleType("cocotb.clock")
    clock.Clock = None
    stub.triggers, stub.clock = triggers, clock
    sys.modules.update({"cocotb": stub, "cocotb.triggers": triggers, "cocotb.clock": clock})

from cocotb_tests import fabric, protocols  # noqa: E402

# Record the code length (the program without its config tables), so a
# harness can tell when a program that drives no pin has armed: its final
# idle loop is the last 3 code bytes. Labels are recorded too, so a harness
# can start its proof where the program reaches one, and data tables (their
# SRAM addresses), so a harness can make their contents symbolic.
_assemble = fabric.Px8.assemble
code_length, labels, tables = [], [], []


def _recording(self):
    image = _assemble(self)
    code_length.append(len(self.code))
    labels.append(dict(self.labels))
    tables.append([(len(self.code) + offset, length) for offset, length in self.tables])
    return image


fabric.Px8.assemble = _recording

out, expression = sys.argv[1], sys.argv[2]
program = eval(expression, vars(protocols))
lines = [f"// {expression}: {len(program)} bytes",
         f"localparam CODE_LENGTH = {code_length[-1]};",
         *(f"localparam LABEL_{name} = {at};" for name, at in sorted(labels[-1].items())
           if name.isidentifier()),
         *(line for k, (at, length) in enumerate(tables[-1])
           for line in (f"localparam TABLE{k} = {at};", f"localparam TABLE{k}_LENGTH = {length};")),
         "function automatic [7:0] rom_byte(input [9:0] a);",
         "  case (a)"]
lines += [f"    10'd{i}: rom_byte = 8'h{b:02x};" for i, b in enumerate(program)]
lines += ["    default: rom_byte = 8'h00;", "  endcase", "endfunction", ""]
Path(out).write_text("\n".join(lines))

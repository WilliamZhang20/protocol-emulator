![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# SRAM-Programmed Protocol Emulator

This Tiny Tapeout design is a deterministic, reprogrammable bit-level protocol
engine. A host loads bytecode into the on-chip foundry SRAM, exchanges payload
bytes through TX/RX FIFOs, and starts the engine. Timing, shifting, GPIO output
and output-enable control, pin mapping, waits, and branches are protocol-neutral;
UART behavior is supplied entirely by the SRAM image.

The current milestone includes working UART TX and RX programs, a synchronous
nibble-command host interface, configurable GPIO, FIFOs, timer, serial shifter,
and the complete SRAM-backed fetch/execute path.

## Local verification

Python dependencies are isolated in `.venv`; RTL/formal tools can be supplied by
the YosysHQ OSS CAD Suite under `.tools/oss-cad-suite` or through `PATH`.

```sh
uv venv --python 3.12
uv pip install --python .venv/bin/python -r test/requirements.txt pytest
export PATH="$PWD/.tools/oss-cad-suite/bin:$PWD/.venv/bin:$PATH"
make verify
```

`make verify` runs:

- full-hierarchy Verilator lint;
- a standalone compile/test of the delivered foundry SRAM model;
- a flattened-synthesis check that requires the LibreLane-visible SRAM instance
  to be named `program_memory.sram`;
- cocotb smoke and end-to-end UART TX/RX tests through the top-level pins; and
- a GDS configuration preflight for the SRAM views, placement, supply hooks,
  and required Metal4/TopMetal1 PDN;
- formal SRAM checks plus exhaustive 300-step UART TX/RX safety checks and
  complete-frame cover traces.

Individual commands include `make lint`, `make synth-check`,
`make gds-config-check`, `make memory-test`, `make sim`, and `make formal`.

## Documentation

- [Architecture, ISA, and host protocol](docs/architecture.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

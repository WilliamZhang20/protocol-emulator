![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Spatial Protocol Emulator

This Tiny Tapeout design is a spatial, reconfigurable protocol engine. Bit-level
behavior comes from a fabric of generic tiles (4 timers, 2 shifters, 8 pin
cells) wired together through a registered 32-line event bus. Once configured,
the fabric runs every clock with no instruction fetch, so timing is exact by
construction. A tiny prefix-encoded controller (PX8) executes from the on-chip
foundry SRAM: it writes the configuration and handles transaction-level
decisions. The host loads the SRAM, exchanges payload through TX/RX FIFOs, and
starts the engine.

UART (full duplex), SPI (modes 0–3) and I²C (with clock stretching) are
configurations, not RTL. The whole design synthesizes to about 4.4k generic
cells. See [architecture.md](docs/architecture.md).

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
- `dead-check`: Verilator unused/undriven signals plus yosys constant or
  never-active flip-flops (must be zero);
- a flattened-synthesis check that requires the LibreLane-visible SRAM instance
  to be named `program_memory.sram`;
- a GDS configuration preflight for the SRAM views, placement, supply hooks,
  required Metal4 PDN, and the SRAM Metal3 M3.f keepout;
- a standalone compile/test of the delivered foundry SRAM model;
- cocotb UART, SPI and I²C tests through the top-level pins; and
- formal SRAM, FIFO, timer-tile and shifter-tile checks with cover traces and
  mutation testing.

Individual commands include `make lint`, `make dead-check`, `make synth-check`,
`make gds-config-check`, `make memory-test`, `make sim`, and `make formal`.

## Documentation

- [Architecture, ISA, and host protocol](docs/architecture.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

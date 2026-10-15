![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Spatial Protocol Emulator

This Tiny Tapeout design is a spatial, reconfigurable protocol engine. Bit-level
behavior comes from a fabric of generic tiles (4 timers, 2 shifters, 2
counters, a CRC engine, 8 LUT4+FF glue cells, and 8 pin cells) connected
through one 64-line signal space. Once configured, the fabric runs every
clock with no instruction fetch, so timing is exact by construction. A small
prefix-encoded controller (PX8) executes from the on-chip foundry SRAM: it
writes the configuration and makes transaction-level decisions.

UART (full duplex), SPI (modes 0–3), I²C (with clock stretching), PS/2,
low-speed USB transmit and receive (NRZI, bit stuffing, CRC16, clock
recovery), and 10BASE-T transmit (Manchester + CRC32 FCS, at 40 MHz) are all
configurations, not RTL. See [architecture.md](docs/architecture.md).

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
- cocotb UART, SPI, I²C, PS/2, USB and 10BASE-T tests through the top-level
  pins; and
- formal SRAM, FIFO, timer, shifter, counter and CRC checks with cover traces
  and mutation testing.

Individual commands include `make lint`, `make dead-check`, `make synth-check`,
`make gds-config-check`, `make memory-test`, `make sim`, and `make formal`.

## Documentation

- [Architecture, ISA, and host protocol](docs/architecture.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Spatial Protocol Emulator

A Tiny Tapeout chip that speaks serial protocols on its pins (UART, SPI,
I²C, PS/2, low-speed USB, 10BASE-T Ethernet, CAN, JTAG, SWD, 1-Wire, I²S,
WS2812, DMX512, HDLC, VGA and more) without any of them being built into
the hardware.

Instead, the chip has general-purpose hardware blocks: timers, shifters,
counters, a CRC engine, small logic cells and pin drivers. A program in
on-chip memory **connects** these blocks for one protocol, then steps
aside. The connected blocks run every clock cycle on their own, so every
bit comes out at exactly the right time.

New to the project? Start with [docs/README.md](docs/README.md).

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

- `tooling-test`: Python regression tests for verification tooling;
- full-hierarchy Verilator lint;
- `dead-check`: Verilator unused/undriven signals plus yosys constant or
  never-active flip-flops (must be zero);
- a flattened-synthesis check that requires the LibreLane-visible SRAM instance
  to be named `program_memory.sram`;
- a GDS configuration preflight for the SRAM views, placement, supply hooks,
  required Metal4 PDN, and the SRAM Metal3 M3.f keepout;
- a standalone compile/test of the delivered foundry SRAM model;
- cocotb tests of every protocol through the top-level pins, against
  models of the devices on the other end; and
- formal checks of every block and of the whole core, with unbounded proofs
  where they converge, cover traces, and mutation testing, and protocol
  proofs that run whole protocol programs on the whole core.

Individual commands include `make lint`, `make dead-check`, `make synth-check`,
`make gds-config-check`, `make memory-test`, `make sim`, and `make formal`.

## Documentation

- [Start here: reading order and glossary](docs/README.md)
- [External hardware, pins, and clocks](docs/hardware.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

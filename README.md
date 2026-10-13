![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# SRAM-Programmed Protocol Emulator

A Tiny Tapeout design that runs bit-level protocols from a program in
on-chip SRAM. A host loads bytecode, exchanges payload bytes through TX/RX
FIFOs, and starts the engine. Pin timing, shifting, output enables, pin
mapping, waits, and branches are all generic; UART, SPI, I²C, JTAG, 1-Wire,
and low-speed USB line patterns are programs, not hardware.

The engine is a small control CPU (8×16 registers, ALU, timer, CRC, event
scoreboard) plus two real-time action lanes. Each lane runs a 16-slot table
of 32-bit actions at one action per cycle: it can shift, sample, drive a
side-set pin, step its LFSR, count, and delay in the same cycle, and stream
bytes to and from the FIFOs with backpressure. The CPU launches regions on
the lanes without blocking and joins on their completion. A dispatcher
admits a region only when its pins are free and shares the FIFO ports
between lanes.

See [docs/architecture.md](docs/architecture.md) for the host protocol,
instruction set, and lane action format.

## Local verification

Python dependencies live in `.venv`; RTL and formal tools come from the
YosysHQ OSS CAD Suite under `.tools/oss-cad-suite` or from `PATH`.

```sh
uv venv --python 3.12
uv pip install --python .venv/bin/python -r test/requirements.txt pytest
export PATH="$PWD/.tools/oss-cad-suite/bin:$PWD/.venv/bin:$PATH"
make verify
```

`make verify` runs:

| Target | Checks |
| --- | --- |
| `make lint` | Verilator lint of the full hierarchy |
| `make synth-check` | Flattened synthesis keeps the SRAM instance at `program_memory.sram` for LibreLane |
| `make gds-config-check` | SRAM macro views, placement, supply hooks, Metal4 PDN, Metal3 keepout |
| `make memory-test` | Standalone test of the foundry SRAM model |
| `make sim` | cocotb regression through the top-level pins |
| `make formal` | SymbiYosys proofs and covers, then mutation testing |

## Documentation

- [Architecture, instruction set, and host protocol](docs/architecture.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

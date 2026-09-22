![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# SRAM-Programmed Protocol Emulator

This Tiny Tapeout design is a deterministic, reprogrammable bit-level protocol
engine. A host loads bytecode into the on-chip foundry SRAM, exchanges payload
bytes through TX/RX FIFOs, and starts the engine. Timing, shifting, GPIO output
and output-enable control, pin mapping, waits, and branches are protocol-neutral;
UART behavior is supplied entirely by the SRAM image.

The RTL includes UART TX/RX, a synchronous host interface, an 8×16 register
file and ALU, configurable GPIO, TX/RX FIFOs, a generic CPU CRC/timer path,
and two 16-slot real-time action lanes. SPI, I²C, JTAG, and low-speed
line patterns are action-region programs; the old bit-transfer and line-pair
blocks and opcodes have been removed. See [architecture.md](docs/architecture.md).

Each lane has separate TX/RX shifters, a counter and delay timer, and a local
configurable CRC/LFSR. A compound action can shift, sample, change a side-set
pin, update the LFSR, count, and schedule a short delay together. Streaming
shifts automatically pull and push bytes with FIFO backpressure. The dispatcher
admits complete pin claims atomically, stalls conflicts, and fairly arbitrates
the shared FIFO ports. GPIO mapping remains one-to-one by swapping assignments.

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
- cocotb smoke, UART, clocked-region, orchestration, and fuzz tests through the
  top-level pins; and
- a GDS configuration preflight for the SRAM views, placement, supply hooks,
  required Metal4 PDN, and the SRAM Metal3 M3.f keepout;
- formal SRAM/UART checks plus FIFO ordering, event tokens, GPIO ownership,
  lane admission, action repeat/claim lifetime, automatic stream handshakes,
  shared-resource safety, cover traces, and mutation testing.

Individual commands include `make lint`, `make synth-check`,
`make gds-config-check`, `make memory-test`, `make sim`, and `make formal`.

## Documentation

- [Architecture, ISA, and host protocol](docs/architecture.md)
- [Dynamic verification](test/README.md)
- [Formal verification](formal/README.md)
- [Tiny Tapeout datasheet text](docs/info.md)

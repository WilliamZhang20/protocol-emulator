# Dynamic verification

The simulation layer uses cocotb for scenarios, monitors, scoreboards, and
executable protocol models. Verilator and Icarus can both run the RTL tests;
the Tiny Tapeout gate-level flow continues to use this directory as well.

## Commands

From the repository root:

```sh
make verify
make sim
make memory-test
make lint
```

Or run the cocotb regression directly:

```sh
make -C test clean
make -C test
```

Verilator is the default; set `SIM=icarus` to run the RTL regression with Icarus.
Gate-level simulation remains available through `make -C test GATES=yes` after
the hardened netlist has been copied into `test/gate_level_netlist.v`.

## Structure

- `cocotb_tests/common.py` owns shared clock, reset, and host status helpers.
- `cocotb_tests/fabric.py` contains the PX8 assembler, fabric configuration
  helpers, host load/push/pop helpers, and the wired-AND `Bus` pin model.
- `cocotb_tests/protocols.py` builds UART, SPI, and I²C programs as fabric
  configurations.
- `cocotb_tests/test_*.py` contains discoverable test modules.
- `models/` contains vendor simulation models only.

**Gate-level rule:** every module in `COCOTB_TEST_MODULES` must be GL-safe.
Do not reach below `dut.user_project`. Use host commands and `uio_*` /
`uo_out` only. See `AGENTS.md` and `cocotb_tests/common.py`.

The standalone `program_memory_tb.sv` verifies the delivered foundry SRAM model,
including masked writes. Formal verification uses a separate logical SRAM model
under `formal/models/`; neither model is synthesized into the ASIC.

`test_top.py` checks that a reset engine leaves every protocol pin undriven.

`test_uart.py` checks that every edge of a UART frame lands exactly one bit
period apart, streams four bytes through a reference receiver, and runs TX and
RX concurrently (full duplex) with frames deliberately misaligned.

`test_spi.py` runs a three-byte full-duplex transfer in each of SPI modes 0–3
against a reference slave and checks both directions.

`test_i2c.py` runs START, two writes, repeated START, and two reads (ACK, then
NACK) against an open-drain reference slave. It checks that no SCL phase is
shorter than the half period, that a slave stretching SCL for 20 half periods
is honored, and that an absent address reads back NACK.

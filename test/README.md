# Dynamic verification

The simulation layer uses cocotb for scenarios, monitors, scoreboards, and
executable protocol models. Verilator and Icarus can both run the RTL tests;
the Tiny Tapeout gate-level flow continues to use this directory as well.

## Commands

From the repository root:

```sh
make sim
make memory-test
make lint
```

Or run the cocotb regression directly:

```sh
make -C test clean
make -C test
```

Set `SIM=verilator` to use Verilator instead of the default Icarus simulator.
Gate-level simulation remains available through `make -C test GATES=yes` after
the hardened netlist has been copied into `test/gate_level_netlist.v`.

## Structure

- `cocotb_tests/common.py` owns shared clock and reset behavior.
- `cocotb_tests/test_*.py` contains discoverable test modules.
- `cocotb_tests/reference/` contains the ISA and protocol reference models.
- `models/` contains vendor simulation models only.

Keep drivers and monitors independent of individual tests. Compare externally
observable events through the common trace vocabulary so the same scoreboards
can be reused for UART, SPI, I2C, and arbitrary instruction sequences.

The standalone `program_memory_tb.sv` verifies the delivered foundry SRAM model,
including masked writes. Formal verification uses a separate logical SRAM model
under `formal/models/`; neither model is synthesized into the ASIC.

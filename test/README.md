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

- `cocotb_tests/common.py` owns shared clock and reset behavior.
- `cocotb_tests/test_*.py` contains discoverable test modules.
- `cocotb_tests/reference/` contains the ISA and protocol reference models.
- `models/` contains vendor simulation models only.

Keep drivers and monitors independent of individual tests. Compare externally
observable events through the common trace vocabulary so the same scoreboards
can be reused for UART, SPI, I2C, and arbitrary instruction sequences.

**Gate-level rule:** every module in `COCOTB_TEST_MODULES` must be GL-safe.
Do not reach below `dut.user_project` (no `core`, `bit_xfer`, etc.). Use host
commands and `uio_*` / `uo_out` only — see `AGENTS.md` and
`cocotb_tests/common.py`.

The standalone `program_memory_tb.sv` verifies the delivered foundry SRAM model,
including masked writes. Formal verification uses a separate logical SRAM model
under `formal/models/`; neither model is synthesized into the ASIC.

`test_uart.py` loads distinct TX and RX bytecode images through the real host
interface and SRAM, then checks complete 8-N-1 frames at the top-level GPIO pins.

`test_bit_xfer.py` exercises the shared autonomous bit-transfer engine with SPI
mode 0, SPI mode 3, an I²C byte write plus ACK, and an I²C clock-stretching case.

`test_orchestrate.py` checks nonblocking `START_XFER` / `WAIT_EVENT`, overlapped
timer joins, edge wakeups, and GPIO ownership while a transfer runs.

`test_fuzz.py` runs a mutational orchestration campaign (96 trials: double START,
OR-joins, edge wake, ownership, CRC pipelines, line_pair, CRC-then-XFER) with a
hang watchdog, RX scoreboarding, and directed CRC poly stress.

`test_usb_ls.py` covers GPIO line-state smoke, programmable CRC5/CRC16, the
`line_pair` helper, and a soft LS ACK line-pattern TX demo (GL-safe).

`test_alu_branch.py` covers the 8x register file, ALU ops, the zero flag, and
`JZ`/`JNZ`/`DJNZ` (GL-safe, pins + status only).

`test_time_event.py` covers `GET_TIME`/`WAIT_UNTIL` scheduling and timestamped
`EVENT_STAMP` triples against edge events.

`test_sideset.py` checks side-set prefixes land on the same cycle as the next
op's pin transition.

`test_crc.py` checks IEEE-802.3 CRC-32 (`0xE1` setup, 4-byte push) against zlib.

`test_jtag.py` runs a Shift-DR loopback through the generic shift engine with
no RTL change per protocol.

`test_onewire.py` runs a 1-Wire reset + presence + write + read demo on one pin.

`test_manchester.py` decodes a Manchester TX frame purely from pin timing.

`test_host_stream.py` checks FIFO level reads (`0xC`) and RX peek (`0xD`).

# Dynamic verification

The regression uses cocotb with Verilator (default) or Icarus for RTL, and
the same tests run on the hardened netlist for gate-level simulation.

## Commands

From the repository root:

```sh
make sim            # cocotb regression
make memory-test    # foundry SRAM model test
make lint
make verify         # everything, including formal
```

Or run cocotb directly:

```sh
make -C test clean
make -C test                 # Verilator
make -C test SIM=icarus
make -C test GATES=yes       # after copying the netlist to test/gate_level_netlist.v
```

## Gate-level rule

Every module in `COCOTB_TEST_MODULES` must run on the gate-level netlist,
where the design is flattened. Observe only top-level pins: drive the host
link on `ui_in`, read `uo_out` (status `0xA`, FIFO data), and use `uio_*`.
Never reach below `dut.user_project`. See `AGENTS.md` and
`cocotb_tests/common.py`.

## Structure

- `cocotb_tests/common.py`: clock, reset, host commands, and status helpers.
- `cocotb_tests/reference/`: program builders and reference models.
- `cocotb_tests/test_*.py`: test modules.
- `models/`: vendor SRAM simulation models.
- `program_memory_tb.sv`: standalone test of the foundry SRAM model,
  including masked writes. Formal uses its own SRAM abstraction under
  `formal/models/`; neither model is synthesized.

## Test modules

| Module | Covers |
| --- | --- |
| `test_top.py` | Safe reset outputs; SRAM readback with command `B` |
| `test_uart.py` | UART TX and RX programs loaded through the host link, checked as 8-N-1 frames on the pins |
| `test_clocked_regions.py` | SPI modes 0 and 3, an I²C byte write with ACK, and I²C clock stretching |
| `test_orchestrate.py` | Nonblocking `RUN_REGION`, `WAIT_EVENT`, overlapped timers, edge wakeups, pin ownership during a transfer |
| `test_fuzz.py` | Randomized orchestration (96 trials) with a hang watchdog, RX scoreboarding, and CRC stress |
| `test_differential.py` | 16 seeded regions compared pin-transition-for-pin-transition, cycle-exact, against `reference/region_spec.py` |
| `test_action.py` | Lane programming, regions, bundles, streaming and FIFO backpressure, claims and stalls, `MAP`, results, CPU/lane FIFO port sharing |
| `test_alu_branch.py` | Registers, ALU, zero flag, `JZ`/`JNZ`/`DJNZ` |
| `test_time_event.py` | `GET_TIME`, `WAIT_UNTIL` (including wrap), `EVENT_STAMP`, event detail, zero-length timers |
| `test_sideset.py` | Side-set lands on the same cycle as the next instruction's pin change |
| `test_crc.py` | CRC-32 against zlib; CPU CRC alongside a lane LFSR |
| `test_usb_ls.py` | USB line states, CRC5/CRC16, bundle GPIO regions, a soft low-speed ACK |
| `test_jtag.py` | JTAG Shift-DR loopback through a clocked region |
| `test_onewire.py` | 1-Wire reset, presence, write, and read |
| `test_manchester.py` | Manchester TX decoded from pin timing |
| `test_host_stream.py` | FIFO levels (`C`) and RX peek (`D`) |

`reference/region_spec.py` supports only `GPIO`, `DELAY`, `COUNT`, `REPEAT`,
and `DONE`, and rejects other opcodes, so an unsupported generated action
cannot be silently scored as a `NOP`.

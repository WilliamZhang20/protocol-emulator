# Protocol emulator architecture

## Purpose

The chip is a deterministic, SRAM-programmed protocol engine. Protocol behavior
is expressed as programs that manipulate shared timing, serial, FIFO, and GPIO
resources. UART, SPI, and I2C are initial demonstrations of the architecture,
not fixed-function peripherals in the hardware.

The first implementation contains one engine. The structure intentionally keeps
execution resources and external interfaces separable so later versions can add
more engines, event routing, and autonomous data movement without replacing the
programming model.

## System structure

```text
                         Host control and data
                                  |
                         +------------------+
                         |  Host interface  |
                         +------------------+
                           |      |      |
                    program|    TX|      |RX
                           v      v      ^
                    +----------+  +--------+
                    | Program  |  | FIFOs  |
                    |   SRAM   |  +--------+
                    +----------+      |
                         |             |
                         v             v
                    +---------------------+
                    |   Protocol engine   |
                    | sequencing + state  |
                    +---------------------+
                       |       |       |
                  +--------+ +-----+ +--------+
                  | timers | |bit  | | GPIO   |
                  |counts  | |xfer | | fabric |
                  +--------+ +-----+ +--------+
                                          |
                                   Physical protocol pins
```

The architecture has two conceptual planes:

- The host plane loads programs, starts and observes execution, and exchanges
  payload bytes through queues.
- The protocol plane runs deterministically from the chip clock and controls
  external pins without depending on host response time.

## Major components

### Host interface

The host interface is the control boundary of the chip. It provides access to
program loading, execution control, status, and queued payload data. Host
transactions are deliberately kept out of the exact-cycle execution path.

The implemented host link accepts one command byte on `ui_in` for one clock,
followed by `8'h00`. The upper nibble is the command and the lower nibble is
data:

| Command | Operation |
| --- | --- |
| `1`, `2`, `3` | Set address bits 3:0, 7:4, and 9:8 |
| `4` | Stage the low program-data nibble |
| `5` | Stage the high nibble, write SRAM, and increment the address |
| `6` | Stage the low TX-data nibble |
| `7` | Stage the high nibble and push the TX FIFO |
| `8` | Bit 0 starts and bit 1 stops the engine |
| `9` | Pop one RX byte to `uo_out` |
| `A` | Read engine/FIFO status on `uo_out` |
| `B` | Read SRAM at the current address to `uo_out` |
| `C` | Read FIFO levels: `{tx_full, rx_empty, tx_level[2:0], rx_level[2:0]}` |
| `D` | Peek next RX byte without popping (no-op while empty) |

Program reads and writes are rejected while the engine runs. This keeps host
traffic from perturbing instruction timing. Status is
`{running, halted, tx_full, rx_empty, 4'b0}`.

### Program memory

A foundry SRAM macro stores protocol programs. SRAM contents define pin timing,
framing, branches, waits, and data movement, allowing behavior to change after
fabrication.

The memory is wrapped behind a technology-independent program-memory interface.
This isolates the engine from foundry-specific controls and permits a logical
model in simulation and formal verification.

### Protocol engine

The protocol engine owns instruction sequencing (`vm_sequencer`) and
coordinates shared resources. Pin claim/merge lives in `gpio_arbiter`. The
engine advances only when the current operation's timing and flow-control
conditions are satisfied.

The bytecode is intentionally small and embeds a logical pin number in bits 2:0
where applicable:

| Encoding | Operation |
| --- | --- |
| `00`, `01` | NOP, HALT |
| `02`-`0F` | `SIDESET`: `imm = {val, pin[2:0]}` latched, applied atomically at next `EXECUTE` |
| `10 ll hh` | WAIT16, blocking little-endian cycle count |
| `2vppp`, `3vppp` | Write logical GPIO, write its output enable |
| `40` | Load a byte from TX FIFO; stall while empty |
| `5p`, `6p` | Shift one bit out or in, LSB first |
| `70` | Push the received byte; stall while RX FIFO is full |
| `80 ll hh` | Jump to a 10-bit SRAM address |
| `81 ll hh` | `JZ`: jump if ALU zero flag set (`80` stays unconditional) |
| `82 ll hh` | `JNZ`: jump if ALU zero flag clear |
| `88+n ll hh` | `DJNZ Rn`: decrement `Rn` (0..7), jump if result != 0 |
| `AA rd ii` | `SET Rd, imm8`: zero-extended load, updates zero flag |
| `AB rsrd` | `MOV Rd, Rs`: `rsrd = {Rs[2:0], Rd[2:0]}`, updates zero flag |
| `AC op rsrd` | ALU `Rd = Rd op Rs`, `op`: 0 ADD, 1 SUB, 2 AND, 3 OR, 4 XOR, 5 SHL, 6 SHR |
| `AD rd` | `GET_TIME Rd`: `Rd` = global cycle-counter low 16 bits |
| `AE rn` | `WAIT_UNTIL Rn`: stall until counter `[15:0]` >= `Rn` (unsigned) |
| `AF` | `EVENT_STAMP`: push one byte; 3 consecutive stamps = time_lo/time_hi/cause |
| `9vppp` | Wait until a logical input pin equals `v` |
| `A0` | Clear the bit-transfer shift register |
| `A1 cfg poly_lo poly_hi` | `CRC_SETUP`: width/ref/xor/init in `cfg`, 16-bit poly |
| `A2 data` | `CRC_FEED`: absorb one byte |
| `A3` | `CRC_FINALIZE`: apply refout/xorout to residue |
| `A4` / `A5` | Push CRC low/high byte to RX FIFO |
| `A6 pins` | `LINE_CFG`: `{jk_swap, pin_b[2:0], pin_a[2:0]}` |
| `A7 state` | `LINE_DRIVE`: `state` in `{SE0,J,K,SE1}` |
| `A8` | `LINE_RELEASE`: drop OE/claim on the pair |
| `A9` | `LINE_SAMPLE`: push sampled state code to RX |
| `Bppp qq` | Map logical pin `ppp` to physical pin `qq` |
| `Cppp cfg pins half` | `START_XFER`: configure and launch bit-transfer (nonblocking) |
| `D0 mask` | `WAIT_EVENT`: stall until any pending event in `mask`; clear matches |
| `E0 ll hh` | `START_TIMER`: nonblocking timer; sets `EV_TIMER_DONE` on expiry |
| `E1` | `CRC32_SETUP`: one-pulse IEEE-802.3 CRC-32 init (width 32, poly `0x04C11DB7`) |
| `E2` / `E3` | Push CRC residue byte 2 / byte 3 (`A4`/`A5` push bytes 0/1) |
| `F0 rise fall` | `ARM_EDGE`: arm rise/fall masks (`imm0` also arms compare) |

### Orchestration model

Resources run concurrently with the VM. Launch is nonblocking; joining uses
events:

```text
TX_LOAD
START_XFER
START_TIMER        ; VM is free — both resources run
WAIT_EVENT XFER_DONE
WAIT_EVENT TIMER_DONE
RX_PUSH
```

`WAIT_EVENT` ORs its mask against a sticky pending vector. `XFER_DONE` and
`TIMER_DONE` are **token-counted** (so back-to-back completions are not lost);
edge/compare sources are level-sticky. Typical bits:

| Bit | Name | Source |
| --- | --- | --- |
| 0 | `EV_XFER_DONE` | bit-transfer engine done pulse |
| 1 | `EV_TIMER_DONE` | async timer expiry |
| 2 | `EV_PIN_RISE` | armed rising edges |
| 3 | `EV_PIN_FALL` | armed falling edges |
| 4 | `EV_COMPARE` | armed GPIO compare match |
| 5 | `EV_LINE_CHANGE` | `line_pair` sampled state changed |

`WAIT_EVENT(XFER_DONE \| TIMER_DONE)` wakes on the first of the two (timeout-or-
complete). To require both, issue two waits with single-bit masks (events are
sticky).

`START_XFER` claims the TX and CLK pins for the duration of the transfer; VM
GPIO writes to claimed pins are ignored so two drivers cannot fight. Blocking
`WAIT16` remains for UART-style bit bang.

`Cppp cfg pins half` operand layout is unchanged from the bit-transfer engine:

| Byte | Fields |
| --- | --- |
| `cfg` | `{tx_od, sample_phase, clk_idle, msb_first, bit_count_m1[3:0]}` |
| `pins` | `{wait_clk_high, clk_od, rx_pin[2:0], tx_pin[2:0]}` |
| `half` | half-period in engine clocks (`0` means `1`) |

The synchronous SRAM path has deterministic instruction overhead. In the
supplied UART programs each symbol lasts `WAIT16 + 11` engine clocks. At
50 MHz, a wait operand of 423 yields approximately 115,207 baud.

Exact per-opcode cost (engine clocks, excluding stall cycles): every
instruction byte costs 3 cycles (`FETCH_REQUEST` + `FETCH_WAIT` + `EXECUTE`)
and every operand byte costs 2 (`REQUEST` + `WAIT`). So single-byte ops
(`GPIO_WRITE`, `SHIFT_OUT/IN`, `TX_LOAD` hit, `RX_PUSH` hit, `SET`-prefix
`SIDESET`) cost 3; one-operand ops (`MAP`, `CRC_FEED`, `MOV`, `GET_TIME`,
`WAIT_UNTIL` entry) cost 5; two-operand ops (`WAIT16`/`START_TIMER`/`ARM_EDGE`
entry, `JMP`/`JZ`/`JNZ`/`DJNZ`, `SET`, ALU) cost 7; `START_XFER`/`CRC_SETUP`
cost 9 plus resource-busy stall. `WAIT16(N)` totals `N + 11` including the
following bit operation's fetch. Stalls (`TX` empty, `RX` full, `WAIT_PIN`,
`WAIT_EVENT`, `WAIT_UNTIL`, `TIMER_WAIT`) add one cycle per waiting clock.

A deeper prefetch queue is intentionally deferred: fetching ahead during
`EXECUTE` would change every count above and invalidate the characterized
baud rates, so it is scheduled after the streaming-host cutover when all
programs are re-timed together.

Baseline lock (Phase 0, pre-deterministic-core migration): this `+11`
overhead, the single-port 1024x8 SRAM behind `program_memory.sram`, the
nibble host commands `1`-`B`, and the sticky `event_engine` semantics are
frozen. New ISA work is purely additive (unused `0xA` sub-ops `0xAA+`,
`0x8n` branch immediates) until the explicit cutover phase. `make verify`
must stay green after every phase.

### Register and state storage

A compact register file holds working values, flags, loop state, addresses, and
temporary protocol data. Dedicated counters and shift storage handle operations
that would otherwise require long software sequences while remaining reusable
across protocols.

### Bit-transfer engine

Autonomous FSM for repetitive clocked transfers:

`IDLE → DRIVE_DATA → CLOCK_ACTIVE → SAMPLE → CLOCK_IDLE → … → DONE`

Launched with `START_XFER` (nonblocking). Completion is observed through
`EV_XFER_DONE` and `WAIT_EVENT`. The same resource covers SPI and I²C data
bytes; framing stays in bytecode. JTAG Shift-DR is the same engine with
`TMS` held low (`jtag_shift_dr_program`) — no RTL change per protocol. Clock
idle/phase, open-drain, and stretch-wait bits are generic shift primitives,
not SPI/I²C modes; slow protocols can alternatively bit-bang the same
transfers with `GPIO_WRITE` + `WAIT_UNTIL` now that the CPU has real branches.

### Event engine

Sticky pending bits from resources and pin activity. `WAIT_EVENT` is the join
primitive that turns the VM into an orchestrator. Edge and compare sources are
armed with `ARM_EDGE`.

### Timers and counters

`WAIT16` remains a blocking delay. `START_TIMER` runs the same counter
autonomously and posts `EV_TIMER_DONE`, enabling overlapped timeouts.

### Configurable GPIO fabric

The GPIO fabric is the engine's protocol-facing datapath. It provides sampled
inputs, output values, independent output-enable control, masked comparisons,
edge observations, and logical-to-physical pin mapping.

Independent output-enable control is essential for bidirectional and open-drain
interfaces such as I2C. Pin mapping lets the same SRAM program bind its logical
signals to different physical pins.

### TX and RX FIFOs

Small transmit and receive FIFOs decouple payload traffic from deterministic
execution. A running program can consume or produce bytes at protocol timing
while the host services data at a less predictable rate.

Programs may wait or branch on FIFO state. The engine must define explicit
behavior for empty and full conditions so host latency cannot silently corrupt
a transfer.

## Reprogrammability model

Programming occurs in a configuration phase before execution begins. The host
loads the SRAM image, configures logical pin bindings, supplies initial payload
data, and starts the engine. During execution, the host exchanges data through
the FIFOs and reads status without modifying timing-critical engine state.

Protocol programs define:

- pin levels and output-enable changes;
- timing intervals and repeated cycles;
- input sampling, edge handling, and masked conditions;
- serial bit order and transfer length;
- framing decisions and conditional branches; and
- movement of payload bytes to and from the host queues.

UART, SPI, and I2C therefore differ primarily in SRAM contents and configuration.
No module is designated as a UART controller, SPI controller, or I2C controller.

## Initial demonstrations

- UART transmit and receive establish accurate asynchronous bit timing and
  framing.
- SPI master transfer establishes programmable clock phase, polarity, and
  simultaneous shifting.
- I2C master transactions establish bidirectional open-drain control,
  acknowledgements, and conditional waits.

Loopback or paired endpoints will verify that each demonstration uses the same
engine and execution resources.

## Growth path

### Cutover notes (Phase 9-10): deprecate, don't delete

The following older blocks still work and stay covered by tests; new
programs should avoid them:

- `line_pair` + `LINE_*` (`A6`-`A9`): kept for the existing USB-LS images.
  New differential buses should drive pin pairs with `GPIO_WRITE` + `WAIT`
  (see `line_state_smoke_program`) — the CPU is now fast enough.
- Per-instruction `MAP` (`Bppp qq`): configure logical-to-physical bindings
  once at load time; rebinding mid-program stays legal but is discouraged.
- Nibble host commands `1`-`B` are extended (not replaced) by level/peek
  reads `C`/`D` for polled streaming drivers. A true byte-wide streaming
  mode needs a pinout change and stays future work.
- A deeper prefetch queue stays deferred (see exact-timing note above).

The component boundaries allow later versions to add capabilities incrementally:

- multiple engines sharing program or data memories;
- an event router for pin edges, timers, and inter-engine signals;
- DMA-style movement between host queues, memories, and engines;
- richer wait and wake-up behavior;
- specialized but protocol-neutral datapath operations; and
- debug visibility, tracing, and execution breakpoints.

New hardware operations should accelerate patterns useful to several protocols.
Protocol-specific state machines remain outside the architectural direction.

Near-term orchestration growth already sketched in the ISA:

- richer resource scoreboard (multi-XFER IDs, ready/busy);
- second timer / capture;
- compact register-file ALU for lengths and protocol state;
- stronger GPIO arbitration across concurrent owners.

### CRC engine

Protocol-neutral residue datapath (`crc_engine`): programmable width 1..16,
poly, init-ones, reflect-in on feed, reflect-out/xor on finalize. USB CRC5/CRC16
are configurations, not dedicated modes. IEEE-802.3 CRC-32 is a one-pulse
`CRC32_SETUP` (`E1`) configuration of the same datapath widened to 32 bits;
bytes 2/3 push out via `E2`/`E3`. Ethernet/ZIP CRCs are configurations too.

### Line-pair helper

`line_pair` drives or samples a two-pin state `{SE0, J, K, SE1}` with optional
J/K polarity swap. Intended for differential-style soft buses (e.g. low-speed
USB bitbang). Framing, NRZI, and PIDs stay in SRAM programs.

### Soft low-speed USB (non-compliant demo)

With GPIO/timers alone, or with `line_pair` + `crc_engine`, bytecode can emit
LS line patterns at ~1.5 Mb/s on two `uio` pins. Board notes: wire D+/D− to
`uio[0]`/`uio[1]`, 1.5 kΩ pull-up on D− for LS device idle J, series resistors
as needed. Not USB-IF compliant — analyzer / cocotb host only.

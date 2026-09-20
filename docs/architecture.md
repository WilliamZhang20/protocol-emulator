# Protocol emulator architecture

## Purpose

The chip is a deterministic, SRAM-programmed protocol engine. Protocol behavior
is expressed as programs that manipulate shared timing, serial, FIFO, and GPIO
resources. UART, SPI, and I2C are demonstrations of the programming model, not
fixed-function peripherals in the hardware.

**Direction:** stop growing specialized accelerators. Protocols should compose
from a small CPU plus reusable datapaths steered by a programmable action
engine. New ISA and RTL work must not add protocol-shaped instructions or
FSMs (no further `LINE_*`, SPI/I²C/JTAG modes, USB helpers, etc.).

The implementation is a hazard-aware protocol processor: the control CPU
launches cycle-exact action regions asynchronously, pin and shared-unit
scoreboards stall conflicting instructions, completed results forward into the
CPU, and synchronized events join the two execution paths. It contains one
action engine and no protocol-specific RTL engines.

## Roadmap (Phases A–D)

| Phase | Goal |
| --- | --- |
| **A — baseline** | Lock the reusable core. Keep shipping demos on current RTL. |
| **B — remove baggage** | Removed the transfer and line-pair blocks after migrating demos. |
| **C — action engine** | Eight programmable action slots generate protocol waveforms. |
| **D — CPU ↔ action** | Region launch/join ISA lets the CPU overlap actions. |

### Phase A — baseline (locked)

Keep and maintain:

| Resource | Role |
| --- | --- |
| 8×16 register file | Working values, loop state, protocol temporaries |
| Tiny ALU + zero flag | `SET`/`MOV`/`ADD`/`SUB`/`AND`/`OR`/`XOR`/`SHL`/`SHR` |
| Conditional branches / `DJNZ` | `JZ`/`JNZ`/`DJNZ Rn` |
| SRAM programs | Foundry 1024×8 program memory |
| TX/RX FIFOs | Host payload decoupling |
| Generic CRC datapath | Width/poly/reflect/xor; not protocol modes |
| Configurable GPIO fabric | Value, OE, map, sample, edges/compare |
| Global clock / cycle counter | `GET_TIME`, `WAIT_UNTIL`, blocking `WAIT16` |

Host link, exact fetch timing (`+11` UART overhead), and sticky event-engine
semantics remain frozen as previously characterized. Additive ISA is allowed
only when it serves the action-engine path (Phases C–D) or fixes baseline
gaps (e.g. pin-to-reg read). **Do not add protocol-specific instructions.**

### Phase B — remove architectural baggage (complete)

The protocol-shaped bit-transfer and line-pair engines and their bytecode
instructions were removed. SPI, I²C, JTAG, and two-pin line programs now
compile to action regions. UART and 1-Wire bit-bang instructions use the
shared action shift register for their manual shift path.

### Phase C — action engine (start tiny)

Initial shape (implemented):

- **8 action slots** × 32-bit action words
- **1 action per cycle** (deterministic; `DELAY` holds without advancing)

Each action word has a primary low half `{op[3:0], args[11:0]}` and an independent upper GPIO lane. `EB slot data` and `EC slot data` program upper bytes 0 and 1. The upper lane is `{enable, oe_we, oe_val, out_we, out_val, pin[2:0], sample, reserved[6:0]}`. It can change another pin while the low action shifts or samples on the same clock.

| `op` | Name | Args |
| --- | --- | --- |
| `0` | `NOP` | — |
| `1` | `GPIO` | `[11]=oe_we, [10]=oe_val, [9]=out_we, [8]=out_val, [2:0]=pin` |
| `2` | `SAMPLE` | `[11]=accumulate, [10]=msb_first, [2:0]=pin`; updates `result` and `sample_bit` |
| `3` | `SHIFT` | `[11]=in, [10]=msb_first, [9]=duplex RX, [8]=open-drain TX, [6:4]=RX pin, [2:0]=TX pin` |
| `4` | `COUNT` | `[11:10]=load/inc/dec/djnz`, `[9]=finish region when DJNZ reaches zero`, imm / target slot |
| `5` | `CRC` | feed `shift[7:0]` into the shared CRC datapath |
| `6` | `NEXT` | `[11:8]=cond`, `[2:0]=slot` |
| `7` | `DELAY` | `[7:0]=cycles`; `[11]` also waits for sampled `[10:8]` pin high |
| `8` | `REPEAT` | `[2:0]=slot` (intra-region jump) |
| `9` | `DONE` | clear claims; on final pass pulse `EV_REGION_DONE` (repeats first) |
| `A` | `PAIR` | Sample pins A `[2:0]`, B `[5:3]`, swap J/K `[6]` into SE0/J/K/SE1 result |
| `B` | `PULL_TX` | Pop TX into the shift register; `[4:0]=bits` (0 means 16), `[5]=MSB first`; stalls on empty |
| `C` | `PUSH_RX` | Push a result byte; `[0]=high byte`, `[4:1]=left shift`; stalls on full |

That set is enough to generate surprisingly complex protocols (SPI-like
clocked bytes, open-drain ACK bits, differential line patterns, CRC-framed
packets) without dedicating RTL to any one of them.

### Phase D — CPU ↔ action interface (implemented)

| Encoding | Operation |
| --- | --- |
| `E8 slot data` | `ACTION_WR_LO`: write action `[slot][7:0]` |
| `E9 slot data` | `ACTION_WR_HI`: write action `[slot][15:8]` |
| `EA data` / `EE data` | Preload action shift register low/high byte |
| `E4 id` | `RUN_REGION id` (nonblocking; `id` = start slot) |
| `E5 id count` | `RUN_REGION id, count` (`count` = extra passes after first) |
| `E6` | `WAIT_REGION`: join on `EV_REGION_DONE` (bit 6, token-counted) |
| `E7 rd` | `READ_RESULT Rd`: copy action result into the register file |
| `C8 cfg` | Pop TX FIFO into action shift register; `cfg={2'b0,msb_first,bits[4:0]}` |
| `EF select` | Push selected action result byte, optionally shifted |

The CPU runs while a region executes (`RUN_REGION` is nonblocking). Join with
`WAIT_REGION` or `WAIT_EVENT` mask bit 6. Region completion posts a
token-counted event so overlapped timeouts and multi-resource joins stay
expressible.

### Resource and completion hazards

At launch, the action engine scans the programmed region slots and reserves
every GPIO pin mentioned by a primary or parallel action, including sampled
pins. The claim stays active across repeats and is released on final
completion. A CPU GPIO write or side-set to a reserved pin waits at its
instruction boundary; writes to other pins can overlap. `MAP` swaps the
requested physical pin with its current logical owner, maintaining a
permutation, and waits until a region finishes before changing that map.
Thus distinct logical claims always refer to distinct physical pins.

Action-table writes and shift preloads wait until the region is idle, so the
running region sees a stable control image. CPU manual shifts use the same
rule. A slot becomes launch-ready only after its primary high byte, and a
parallel-lane low byte makes it unready until the lane high byte arrives;
`RUN_REGION` waits for all programmed slots to be ready. `READ_RESULT` and
`PUSH_RESULT` wait for completion and then consume the
finished result. `WAIT_REGION` receives a counted completion token, including
when the region finished before the CPU reached the wait instruction.
`HALT` also waits for an outstanding region so the host cannot disable it
mid-transaction.

The running region owns the shared TX/RX FIFO ports and CRC datapath. CPU FIFO
and CRC operations wait until that ownership ends; action `PULL_TX` and
`PUSH_RX` have valid/ready behavior and hold their PC on empty/full. Action
`CRC` queues one byte and advances the action PC. A second CRC action waits
for queue space, and region completion waits for the queued byte to commit.
This serializes shared-unit use while independent CPU timer, ALU, and
unclaimed-pin instructions continue.

External pins have two sampling paths. A two-flop synchronizer with
`async_reg` attributes supplies waits, edges, compare, and event capture.
An explicit action `SAMPLE`, `SHIFT`, or `PAIR` uses the single-clock timed
sample when protocol timing establishes an input eye; a region's conditional
delay still checks the synchronized input.

## System structure

```text
Host interface ── SRAM program ── Protocol CPU ── Action engine
     │                                │              │
   TX/RX FIFOs                      timer       shift / count / GPIO / CRC
                                                     │
                                              Physical protocol pins
```

The action engine has eight 32-bit slots. Each slot combines a primary
operation with an optional parallel GPIO update. A region runs independently
of the CPU, and completion posts `EV_REGION_DONE`.

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
| `AE rn` | `WAIT_UNTIL Rn`: wait for an absolute 16-bit deadline using modular half-range comparison (deadline within 32767 cycles) |
| `AF` | `EVENT_STAMP`: push one byte; 3 consecutive stamps = time_lo/time_hi/cause |
| `9vppp` | Wait until a logical input pin equals `v` |
| `A0` | Clear the shared action shift register for manual receive |
| `A1 cfg poly_lo poly_hi` | `CRC_SETUP`: width/ref/xor/init in `cfg`, 16-bit poly |
| `A2 data` | `CRC_FEED`: absorb one byte |
| `A3` | `CRC_FINALIZE`: apply refout/xorout to residue |
| `A4` / `A5` | Push CRC low/high byte to RX FIFO |
| `Bppp qq` | Swap logical pin `ppp` onto physical pin `qq` (preserves a permutation) |
| `D0 mask` | `WAIT_EVENT`: stall until any pending event in `mask`; clear matches |
| `E0 ll hh` | `START_TIMER`: nonblocking timer; sets `EV_TIMER_DONE` on expiry |
| `E1` | `CRC32_SETUP`: one-pulse IEEE-802.3 CRC-32 init (width 32, poly `0x04C11DB7`) |
| `E2` / `E3` | Push CRC residue byte 2 / byte 3 (`A4`/`A5` push bytes 0/1) |
| `E4 id` | `RUN_REGION`: start action region at slot `id` (nonblocking) |
| `E5 id count` | `RUN_REGION` with `count` extra repeats after the first pass |
| `E6` | `WAIT_REGION`: join on `EV_REGION_DONE` |
| `E7 rd` | `READ_RESULT`: action result → `Rd` |
| `E8 slot data` / `E9 slot data` | Program action low half lo/hi byte |
| `EB slot data` / `EC slot data` | Program parallel lane lo/hi byte |
| `ED` | Push source and pin detail captured with the most recent `EVENT_STAMP` |
| `EE data` | Preload action shift register high byte |
| `EF select` | Push selected action result byte; `[0]` selects high, `[4:1]` left-shifts that byte |
| `EA data` | Preload action shift register low byte |
| `C8 cfg` | Pop TX FIFO to action shift register; `cfg={2'b0,msb_first,bits[4:0]}` (`bits=0` means 16) |
| `F0 rise fall` | `ARM_EDGE`: arm rise/fall masks (`imm0` also arms compare) |

### Orchestration model

The CPU programs action slots and launches a region with `E4`. A region can
pull and push payload bytes itself. The CPU can start a timer or update
unclaimed GPIO while the region runs. `WAIT_REGION` or `WAIT_EVENT` bit 6
joins completion; `READ_RESULT` and `EF` access the completed result.

```text
program action slots
ACTION_LOAD_TX
RUN_REGION
START_TIMER
WAIT_EVENT REGION_DONE
WAIT_EVENT TIMER_DONE
ACTION_PUSH_RESULT
```

`WAIT_EVENT` ORs its mask against the pending vector. Timer and region
completions are token-counted; edge and compare sources are sticky.

| Bit | Name | Source |
| --- | --- | --- |
| 0 | Reserved | — |
| 1 | `EV_TIMER_DONE` | async timer expiry |
| 2 | `EV_PIN_RISE` | armed rising edge |
| 3 | `EV_PIN_FALL` | armed falling edge |
| 4 | `EV_COMPARE` | armed GPIO compare |
| 5 | Reserved | — |
| 6 | `EV_REGION_DONE` | action region completion |

`EVENT_STAMP` (`AF`) still emits time low, time high, and pending cause in
three calls. `EVENT_DETAIL` (`ED`) then pushes the detail latched with the
first stamp: source in bits 7:4 and logical pin in bits 2:0. Source values are
1 timer, 2 rise, 3 fall, 4 compare, and 6 region; non-pin sources report pin 0.

Action regions claim pins as they drive them. VM writes and side-set updates
on claimed pins are ignored. The shared 16-bit shift register also serves
manual UART and 1-Wire bit operations while no region is running.

The synchronous SRAM path has deterministic instruction overhead. In the
supplied UART programs each symbol lasts `WAIT16 + 11` engine clocks. At
50 MHz, a wait operand of 423 yields approximately 115,207 baud.

Exact per-opcode cost (engine clocks, excluding stall cycles): every
instruction byte costs 3 cycles (`FETCH_REQUEST` + `FETCH_WAIT` + `EXECUTE`)
and every operand byte costs 2 (`REQUEST` + `WAIT`). So single-byte ops
(`GPIO_WRITE`, `SHIFT_OUT/IN`, `TX_LOAD` hit, `RX_PUSH` hit, `SET`-prefix
`SIDESET`) cost 3; one-operand ops (`MAP`, `CRC_FEED`, `MOV`, `GET_TIME`,
`WAIT_UNTIL` entry) cost 5; two-operand ops (`WAIT16`/`START_TIMER`/`ARM_EDGE`
entry, `JMP`/`JZ`/`JNZ`/`DJNZ`, `SET`, ALU) cost 7; `CRC_SETUP`
cost 9 plus resource-busy stall. `WAIT16(N)` totals `N + 11` including the
following bit operation's fetch. Stalls (`TX` empty, `RX` full, `WAIT_PIN`,
`WAIT_EVENT`, `WAIT_UNTIL`, `TIMER_WAIT`) add one cycle per waiting clock.

A deeper prefetch queue is intentionally deferred: fetching ahead during
`EXECUTE` would change every count above and invalidate the characterized
baud rates, so it is scheduled after the streaming-host cutover when all
programs are re-timed together.

Baseline lock (Phase A): this `+11` overhead, the single-port 1024x8 SRAM
behind `program_memory.sram`, the nibble host commands `1`-`B` (extended by
level/peek reads `C`/`D`), the sticky `event_engine` semantics, and the keep
list above are frozen. New ISA work serves Phases C–D or baseline gaps only —
not new protocol-specific accelerators. `make verify` must stay green after
every phase.

### Register and state storage

An 8x16 register file holds working values, flags, loop state, addresses, and
temporary protocol data, driven by a tiny ALU (`SET`/`MOV`/`ADD`/`SUB`/`AND`/
`OR`/`XOR`/`SHL`/`SHR`) with a zero flag feeding `JZ`/`JNZ`/`DJNZ` branches.
Dedicated counters and shift storage handle operations that would otherwise
require long software sequences while remaining reusable across protocols.
The action words steer shared shift and count state.

### Clocked transfer regions

Clocked transfers use an eight-slot template: load count, launch TX and idle
clock, delay, activate clock, delay or wait for a released clock, accumulate
RX, restore idle clock, and decrement or finish. The same template expresses
SPI clock polarity/phase, open-drain I²C, and JTAG. `OP_PAIR` samples a
SE0/J/K/SE1 two-pin state for differential-style line programs.

### Event engine

Sticky pending bits from resources and pin activity. `WAIT_EVENT` is the join
primitive that turns the VM into an orchestrator. Edge and compare sources are
armed with `ARM_EDGE`. Region completion posts the dedicated bit-6 token.

### Timers and counters

`WAIT16` remains a blocking delay. `START_TIMER` runs the same counter
autonomously and posts `EV_TIMER_DONE`, enabling overlapped timeouts. Action
count and delay primitives handle protocol-rate timing within regions.

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

### CRC engine

Protocol-neutral residue datapath (`crc_engine`): programmable width 1..16,
poly, init-ones, reflect-in on feed, reflect-out/xor on finalize. USB CRC5/CRC16
are configurations, not dedicated modes. IEEE-802.3 CRC-32 is a one-pulse
`CRC32_SETUP` (`E1`) configuration of the same datapath widened to 32 bits;
bytes 2/3 push out via `E2`/`E3`. Ethernet/ZIP CRCs are configurations too.

**Pipelined for timing:** `CRC_FEED` processes two bits per clock (four
cycles per byte). Reflect-out `CRC_FINALIZE` remains bit-serial. The VM
waits on `busy`; the action engine uses a one-byte issue queue so following
actions can proceed while the CRC byte is processed.

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

## Soft low-speed USB (non-compliant demo)

With GPIO actions, timers, and the generic CRC datapath, bytecode can
emit LS line patterns at ~1.5 Mb/s on two `uio` pins. Board notes: wire D+/D−
to `uio[0]`/`uio[1]`, 1.5 kΩ pull-up on D− for LS device idle J, series
resistors as needed. Not USB-IF compliant — analyzer / cocotb host only.
The LS examples use parallel GPIO actions for J/K/SE0 states.

## Growth path

### Further work

- Configure logical-to-physical pin bindings once at load time where possible.
- A byte-wide host streaming mode needs a pinout change.
- A deeper instruction prefetch queue could reduce VM instruction overhead.
- Multi-engine event routing and DMA remain future options.

### Explicit non-goals

- New protocol-specific opcodes or FSMs (USB, 1-Wire, CAN, …).
- Specialized accelerators that duplicate what action words + CRC/shift/count
  can already express.

Component boundaries still allow later versions to add multiple engines, DMA,
and debug/trace — but those build on the simplified CPU + action + datapath
shape, not on a pile of protocol helpers.

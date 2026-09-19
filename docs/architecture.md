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

The first implementation contains one engine. Execution resources and external
interfaces stay separable so later versions can add engines, event routing, and
autonomous data movement without replacing the programming model.

## Roadmap (Phases A–D)

| Phase | Goal |
| --- | --- |
| **A — baseline** | Lock the reusable core. Keep shipping demos on current RTL. |
| **B — remove baggage** | Deprecate specialized blocks once the action engine covers them. |
| **C — action engine** | Tiny programmable action slots replace protocol-shaped FSMs. |
| **D — CPU ↔ action** | Region launch/join ISA so the CPU can overlap with actions. |

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

### Phase B — remove architectural baggage

Eventually remove or deprecate once the action engine can implement the same
patterns in programs:

| Legacy block | Why it goes |
| --- | --- |
| `line_pair` + `LINE_*` (`A6`–`A9`) | Differential SE0/J/K/SE1 is GPIO + timing |
| SPI-shaped bit-transfer FSM + `START_XFER` | Clocked shift is actions + counter/shifter |

These blocks still work and stay tested until cutover. New programs should
prefer GPIO/timer/CRC composition (and, once available, action regions) over
`LINE_*` / `START_XFER`.

Target conceptual silicon:

```text
BEFORE                              AFTER
CPU                                 CPU
 ├─ bit-transfer engine              ├─ programmable action engine
 ├─ line-pair engine                 ├─ CRC datapath
 ├─ timer                            └─ generic shift/counter datapath
 └─ CRC
```

CRC, shifter, and counter become reusable functional units controlled by
action words, not autonomous protocol-shaped FSMs. A simple timer may remain
as a counter configuration or a thin CPU-visible wrapper; it must not grow
into another protocol accelerator.

### Phase C — action engine (start tiny)

Initial shape (implemented):

- **8 action slots** × 16-bit action words
- **1 action per cycle** (deterministic; `DELAY` holds without advancing)

Each action word is `{op[3:0], args[11:0]}`:

| `op` | Name | Args |
| --- | --- | --- |
| `0` | `NOP` | — |
| `1` | `GPIO` | `[11]=oe_we, [10]=oe_val, [9]=out_we, [8]=out_val, [2:0]=pin` |
| `2` | `SAMPLE` | `[2:0]=pin` → `result` / `sample_bit` |
| `3` | `SHIFT` | `[11]=in, [10]=msb_first, [2:0]=pin` |
| `4` | `COUNT` | `[11:10]=load/inc/dec/djnz`, imm / target slot |
| `5` | `CRC` | feed `shift[7:0]` into the shared CRC datapath |
| `6` | `NEXT` | `[11:8]=cond`, `[2:0]=slot` |
| `7` | `DELAY` | `[7:0]=cycles` |
| `8` | `REPEAT` | `[2:0]=slot` (intra-region jump) |
| `9` | `DONE` | clear claims; on final pass pulse `EV_REGION_DONE` (repeats first) |

That set is enough to generate surprisingly complex protocols (SPI-like
clocked bytes, open-drain ACK bits, differential line patterns, CRC-framed
packets) without dedicating RTL to any one of them.

### Phase D — CPU ↔ action interface (implemented)

| Encoding | Operation |
| --- | --- |
| `E8 slot data` | `ACTION_WR_LO`: write action `[slot][7:0]` |
| `E9 slot data` | `ACTION_WR_HI`: write action `[slot][15:8]` |
| `EA data` | `ACTION_LOAD_SHIFT`: preload shift register low byte |
| `E4 id` | `RUN_REGION id` (nonblocking; `id` = start slot) |
| `E5 id count` | `RUN_REGION id, count` (`count` = extra passes after first) |
| `E6` | `WAIT_REGION`: join on `EV_REGION_DONE` (bit 6, token-counted) |
| `E7 rd` | `READ_RESULT Rd`: copy action result into the register file |

The CPU runs while a region executes (`RUN_REGION` is nonblocking). Join with
`WAIT_REGION` or `WAIT_EVENT` mask bit 6. Region completion posts a
token-counted event so overlapped timeouts and multi-resource joins stay
expressible.

## System structure (current silicon)

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

Target structure after Phases C–D (baggage removed):

```text
                    +---------------------+
                    |   Protocol CPU      |
                    | RF + ALU + branches |
                    +----------+----------+
                               |
                    +----------v----------+
                    |  Action engine      |
                    |  8 slots, 1 act/cyc |
                    +--+--------+-------+-+
                       |        |       |
                  +----v--+ +---v---+ +-v------+
                  | shift | | CRC   | | GPIO   |
                  |/count | | path  | | fabric |
                  +-------+ +-------+ +--------+
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
| `A6 pins` | `LINE_CFG`: `{jk_swap, pin_b[2:0], pin_a[2:0]}` *(legacy; Phase B)* |
| `A7 state` | `LINE_DRIVE`: `state` in `{SE0,J,K,SE1}` *(legacy; Phase B)* |
| `A8` | `LINE_RELEASE`: drop OE/claim on the pair *(legacy; Phase B)* |
| `A9` | `LINE_SAMPLE`: push sampled state code to RX *(legacy; Phase B)* |
| `Bppp qq` | Map logical pin `ppp` to physical pin `qq` |
| `Cppp cfg pins half` | `START_XFER`: configure and launch bit-transfer *(legacy; Phase B)* |
| `D0 mask` | `WAIT_EVENT`: stall until any pending event in `mask`; clear matches |
| `E0 ll hh` | `START_TIMER`: nonblocking timer; sets `EV_TIMER_DONE` on expiry |
| `E1` | `CRC32_SETUP`: one-pulse IEEE-802.3 CRC-32 init (width 32, poly `0x04C11DB7`) |
| `E2` / `E3` | Push CRC residue byte 2 / byte 3 (`A4`/`A5` push bytes 0/1) |
| `E4 id` | `RUN_REGION`: start action region at slot `id` (nonblocking) |
| `E5 id count` | `RUN_REGION` with `count` extra repeats after the first pass |
| `E6` | `WAIT_REGION`: join on `EV_REGION_DONE` |
| `E7 rd` | `READ_RESULT`: action result → `Rd` |
| `E8 slot data` / `E9 slot data` | Program action slot lo/hi byte |
| `EA data` | `ACTION_LOAD_SHIFT`: preload action shift register |
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

After Phase D, the preferred pattern is the same shape with regions:

```text
TX_LOAD
RUN_REGION spi_byte
START_TIMER          ; optional overlapped timeout
; CPU may continue useful work here
WAIT_REGION          ; or WAIT_EVENT REGION_DONE
READ_RESULT
```

`WAIT_EVENT` ORs its mask against a sticky pending vector. `XFER_DONE` and
`TIMER_DONE` are **token-counted** (so back-to-back completions are not lost);
edge/compare sources are level-sticky. Typical bits:

| Bit | Name | Source |
| --- | --- | --- |
| 0 | `EV_XFER_DONE` | bit-transfer engine done pulse *(legacy join)* |
| 1 | `EV_TIMER_DONE` | async timer expiry |
| 2 | `EV_PIN_RISE` | armed rising edges |
| 3 | `EV_PIN_FALL` | armed falling edges |
| 4 | `EV_COMPARE` | armed GPIO compare match |
| 5 | `EV_LINE_CHANGE` | `line_pair` sampled state changed *(legacy)* |
| 6 | `EV_REGION_DONE` | action-engine region done pulse |

`WAIT_EVENT(XFER_DONE \| TIMER_DONE)` wakes on the first of the two (timeout-or-
complete). To require both, issue two waits with single-bit masks (events are
sticky).

`START_XFER` claims the TX and CLK pins for the duration of the transfer; VM
GPIO writes to claimed pins are ignored so two drivers cannot fight. Blocking
`WAIT16` remains for UART-style bit bang.

`Cppp cfg pins half` operand layout (legacy bit-transfer engine):

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
Phase C folds those dedicated paths under action-word control.

### Bit-transfer engine *(legacy; Phase B)*

Autonomous FSM for repetitive clocked transfers:

`IDLE → DRIVE_DATA → CLOCK_ACTIVE → SAMPLE → CLOCK_IDLE → … → DONE`

Launched with `START_XFER` (nonblocking). Completion is observed through
`EV_XFER_DONE` and `WAIT_EVENT`. The same resource covers SPI and I²C data
bytes; framing stays in bytecode. Clock idle/phase, open-drain, and
stretch-wait bits are generic shift primitives, not SPI/I²C modes.

**Replacement:** action-engine sequences of GPIO / shift / counter / sample /
done. Until that lands, existing programs and tests may keep using
`START_XFER`. New demos should not depend on extending this FSM.

### Event engine

Sticky pending bits from resources and pin activity. `WAIT_EVENT` is the join
primitive that turns the VM into an orchestrator. Edge and compare sources are
armed with `ARM_EDGE`. Phase D adds region-done as a first-class join source
(or reuses a dedicated event bit).

### Timers and counters

`WAIT16` remains a blocking delay. `START_TIMER` runs the same counter
autonomously and posts `EV_TIMER_DONE`, enabling overlapped timeouts. Longer
term, count/delay primitives in the action engine should absorb most
protocol-rate timing that today uses the SPI-shaped transfer FSM.

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

**Pipelined for timing:** each `CRC_FEED` / reflect-out `CRC_FINALIZE` runs
bit-serially (one CRC bit per clock) with `busy` asserted. The VM and action
engine stall on `busy` so the old 8-bit combinational unroll cannot miss the
20 ns setup budget. Phase C still exposes CRC update as an action primitive.

### Line-pair helper *(legacy; Phase B)*

`line_pair` drives or samples a two-pin state `{SE0, J, K, SE1}` with optional
J/K polarity swap. Intended for differential-style soft buses (e.g. low-speed
USB bitbang). Framing, NRZI, and PIDs stay in SRAM programs.

**Replacement:** GPIO value/OE actions (or plain `GPIO_WRITE` + waits today).
See `line_state_smoke_program` for the CPU-only path already in tree.

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

With GPIO/timers alone, or with legacy `line_pair` + `crc_engine`, bytecode can
emit LS line patterns at ~1.5 Mb/s on two `uio` pins. Board notes: wire D+/D−
to `uio[0]`/`uio[1]`, 1.5 kΩ pull-up on D− for LS device idle J, series
resistors as needed. Not USB-IF compliant — analyzer / cocotb host only.
Prefer GPIO-composed programs for new work; retire `LINE_*` with Phase B.

## Growth path

### Cutover notes: deprecate, don't delete (until Phase B complete)

The following older blocks still work and stay covered by tests; new
programs should avoid them:

- `line_pair` + `LINE_*` (`A6`-`A9`): kept for existing USB-LS images.
  New differential buses should drive pin pairs with `GPIO_WRITE` + `WAIT`
  (see `line_state_smoke_program`) — and later with action regions.
- Bit-transfer FSM + `START_XFER` (`Cppp…`): kept for SPI/I²C demos until
  action-engine shift/counter sequences replace them.
- Per-instruction `MAP` (`Bppp qq`): configure logical-to-physical bindings
  once at load time; rebinding mid-program stays legal but is discouraged.
- Nibble host commands `1`-`B` are extended (not replaced) by level/peek
  reads `C`/`D` for polled streaming drivers. A true byte-wide streaming
  mode needs a pinout change and stays future work.
- A deeper prefetch queue stays deferred (see exact-timing note above).

### What to build next

1. **Action engine MVP (Phase C):** 8 slots, 1 action/cycle, primitives listed
   above; CRC and shift/counter as shared units under action control.
2. **CPU interface (Phase D):** `RUN_REGION` / `WAIT_REGION` / `READ_RESULT`
   with overlapped CPU execution where practical.
3. **Prove replacements:** reimplement SPI byte, I²C ACK bit, and LS line
   patterns as action regions; then deprecate `START_XFER` / `LINE_*`.
4. Only then consider multi-engine, DMA, or richer event routing.

### Explicit non-goals

- New protocol-specific opcodes or FSMs (USB, 1-Wire, CAN, …).
- Growing the bit-transfer or line-pair engines with more modes.
- Specialized accelerators that duplicate what action words + CRC/shift/count
  can already express.

Component boundaries still allow later versions to add multiple engines, DMA,
and debug/trace — but those build on the simplified CPU + action + datapath
shape, not on a pile of protocol helpers.

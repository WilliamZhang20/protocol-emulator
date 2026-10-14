# Protocol emulator architecture

## Overview

The chip is a deterministic, SRAM-programmed protocol engine. A host loads a
bytecode program into the on-chip SRAM, exchanges payload bytes through TX
and RX FIFOs, and starts the engine. Programs drive the GPIO pins with
cycle-exact timing. UART, SPI, I²C, JTAG, 1-Wire, and low-speed USB line
patterns are all programs; none of them has dedicated hardware.

The engine has two parts:

- A **control CPU** that executes bytecode from SRAM. It does arithmetic,
  branches, waits, CRC, and moves bytes between the FIFOs and the pins.
- Two **action lanes** that execute short tables of 32-bit action words, one
  action per cycle, for the timing-critical part of a protocol. The CPU
  programs a lane, launches it, keeps running, and later joins on its
  completion.

### Design rules

- **No protocol-specific hardware.** New instructions and RTL must be
  generic primitives (shift, count, sample, CRC, events), not protocol modes
  or protocol FSMs.
- **Frozen timing.** The instruction timing (see
  [Instruction timing](#instruction-timing)) is characterized by existing
  programs, for example the `WAIT16 + 11` UART bit period. Changes that alter
  instruction cycle counts must re-time every program.
- **Frozen interfaces.** The host command set, the event semantics, and the
  `program_memory.sram` instance name used by the ASIC flow do not change
  without updating every consumer.

## System structure

```text
              ui_in / uo_out
                    │
              host_interface ───── program SRAM (1024×8)
                │        │                │
             TX FIFO   RX FIFO      vm_sequencer (control CPU)
                │        │           │   │   │   │    │
                │        │         regs timer CRC events serial shifter
                │        │           │
                └──── action_engine ─┘
                       │      │
                    lane 0  lane 1
                       │      │
              gpio_arbiter ── CPU GPIO writes
                       │
                gpio_datapath (pin map, sampling)
                       │
              uio_in / uio_out / uio_oe
```

| Module | Role |
| --- | --- |
| `project.v` | Tiny Tapeout top: host link, SRAM, FIFOs, engine |
| `host_interface` | Nibble command link, program load/readback, FIFO access, status |
| `program_memory` | Wrapper around the foundry SRAM macro |
| `byte_fifo` | 4-entry TX and RX FIFOs |
| `protocol_emulator_core` | Connects the CPU to its resources |
| `vm_sequencer` | CPU fetch/execute state machine and resource strobes |
| `register_file` | 8×16 registers |
| `timer_counter` | `WAIT16` and `START_TIMER` |
| `crc_engine` | Configurable CRC (width 1–16, or CRC-32) |
| `serial_shifter` | CPU bit-banging shift register |
| `event_engine` | Pending-event scoreboard for `WAIT_EVENT` |
| `action_engine` | Two lanes plus `action_dispatcher` |
| `action_lane` | One lane: action table, shifters, counter, delay, LFSR |
| `gpio_arbiter` | Merges CPU and lane pin drives |
| `gpio_datapath` | Logical-to-physical pin map, synchronizers, edges |

## Host interface

The host drives a command byte on `ui_in` for one clock, then `0x00`. The
upper nibble is the command and the lower nibble is its payload. A byte equal
to the previous command is ignored until `0x00` is seen, so repeated
commands must be separated by `0x00`. Responses appear on `uo_out`.

| Command | Operation |
| --- | --- |
| `1`, `2`, `3` | Set address bits 3:0, 7:4, 9:8 |
| `4` | Stage the low program nibble |
| `5` | Stage the high program nibble, write the byte to SRAM, increment the address |
| `6` | Stage the low TX nibble |
| `7` | Stage the high TX nibble and push the byte to the TX FIFO (dropped if full) |
| `8` | Payload bit 0 starts the engine; bit 1 stops it (stop wins) |
| `9` | Pop one RX byte to `uo_out` (no-op if empty) |
| `A` | Status: `{running, halted, tx_full, rx_empty, 4'b0}` |
| `B` | Read the SRAM byte at the current address (address does not advance) |
| `C` | FIFO levels: `{tx_full, rx_empty, tx_level[2:0], rx_level[2:0]}` |
| `D` | Peek the next RX byte without popping (no-op if empty) |

- Program writes (`5`) and reads (`B`) are ignored while the engine runs, so
  host traffic never disturbs instruction timing.
- Responses to `9`, `A`, `B`, `C`, and `D` have the same latency: the host
  can sample `uo_out` one clock after the command.
- When the program executes `HALT`, the engine clears its own enable, so
  `running` falls. `halted` is not sticky; wait for `running == 0`.

## Program memory

A foundry 1024×8 single-port SRAM (`RM_IHPSG13_1P_1024x8_c2_bm_bist`) holds
the program. Reads are synchronous: the byte is valid in the cycle after the
request. The CPU owns the port while the engine runs; the host owns it while
the engine is stopped. `program_memory` hides the macro's BIST and delay
pins, so simulation and formal can substitute their own models.

## Control CPU

### Instruction timing

Every SRAM access takes a request cycle and a wait cycle. An instruction byte
costs 3 cycles (`FETCH_REQUEST`, `FETCH_WAIT`, `EXECUTE`) and each operand
byte 2 more, so:

| Length | Cycles | Examples |
| --- | --- | --- |
| 1 byte | 3 | GPIO writes, shifts, `TX_LOAD`, `RX_PUSH`, side-set |
| 2 bytes | 5 | `MAP`, `CRC_FEED`, `MOV`, `GET_TIME`, `RUN_REGION`, `WAIT_UNTIL` entry |
| 3 bytes | 7 | jumps and branches, `SET`, ALU, `WAIT16`/`START_TIMER`/`ARM_EDGE` entry |
| 4 bytes | 9 | `CRC_SETUP` |

Each cycle spent waiting on a resource (empty TX, full RX, a busy CRC or
lane, a pin wait, an event, a deadline, or `WAIT16`) adds one cycle. A
`WAIT16 N` followed by a one-byte pin operation produces a pin period of
`N + 11` cycles; at 50 MHz, `N = 423` gives 115,207 baud.

There is no prefetch. Fetching ahead would change every count above and
invalidate characterized programs.

### Instruction set

`p` is a logical pin (0–7) and `v` a pin value. Multi-byte instructions list
their operand bytes in order.

**System and side-set**

| Encoding | Name | Operation |
| --- | --- | --- |
| `00` | `NOP` | |
| `01` | `HALT` | Waits until both lanes are idle, then halts |
| `02`–`0F` | `SIDESET` | Latch `{v, p}` from the low nibble; it is applied on the same cycle as the next instruction's execute. Consecutive prefixes chain. `{0, 0}` and `{0, 1}` are not encodable. |

**GPIO and CPU shifter**

| Encoding | Name | Operation |
| --- | --- | --- |
| `2x` | `PIN_WRITE` | Drive logical pin `x[2:0]` to `x[3]` |
| `3x` | `OE_WRITE` | Set output enable of pin `x[2:0]` to `x[3]` |
| `9x` | `WAIT_PIN` | Wait until synchronized pin `x[2:0]` equals `x[3]` |
| `Bx qq` | `MAP` | Swap logical pin `x[2:0]` onto physical pin `qq[2:0]`; the map stays a permutation. Waits for idle lanes |
| `40` | `TX_LOAD` | Pop a TX byte into the CPU shifter; waits for data and idle lanes |
| `5p` | `SHIFT_OUT` | Drive pin `p` with the shifter LSB, then shift right |
| `6p` | `SHIFT_IN` | Shift synchronized pin `p` into the shifter MSB |
| `70` | `RX_PUSH` | Push shifter bits 15:8 to RX; waits for space and idle lanes |
| `A0` | `SHIFT_CLEAR` | Clear the CPU shifter |

**Timing, branches, and registers**

| Encoding | Name | Operation |
| --- | --- | --- |
| `1x ll hh` | `WAIT16` | Block for `{hh, ll}` cycles (plus the fixed overhead) |
| `80 ll hh` | `JMP` | Jump to `{hh[1:0], ll}` |
| `81 ll hh` | `JZ` | Jump if the zero flag is set |
| `82 ll hh` | `JNZ` | Jump if the zero flag is clear |
| `88+n ll hh` | `DJNZ Rn` | Decrement `Rn`; jump if the result is nonzero |
| `AA rd ii` | `SET` | `R[rd] = ii` (zero-extended) |
| `AB {rs,rd}` | `MOV` | `R[rd] = R[rs]`; operand is `{2'b0, rs[2:0], rd[2:0]}` |
| `AC op {rs,rd}` | ALU | `R[rd] = R[rd] op R[rs]`; `op`: 0 ADD, 1 SUB, 2 AND, 3 OR, 4 XOR, 5 SHL, 6 SHR (shift by `R[rs][3:0]`) |
| `AD rd` | `GET_TIME` | `R[rd]` = cycle counter bits 15:0 |
| `AE rn` | `WAIT_UNTIL` | Wait until the cycle counter reaches `R[rn]` (modulo 2¹⁶; deadline less than 32768 cycles ahead) |
| `E0 ll hh` | `START_TIMER` | Start the timer for `{hh, ll}` cycles without blocking; posts `EV_TIMER_DONE` |

Other `8x` immediates jump unconditionally. `SET`, `MOV`, ALU, `GET_TIME`,
and `READ_RESULT` update the zero flag; `DJNZ` does not. The cycle counter
starts at zero when the engine is started.

**CRC**

| Encoding | Name | Operation |
| --- | --- | --- |
| `A1 cfg pl ph` | `CRC_SETUP` | `cfg = {init_ones, xor_out, reflect_out, reflect_in, width-1[3:0]}`, polynomial `{ph, pl}` |
| `A2 data` | `CRC_FEED` | Absorb one byte (4 cycles of CRC busy) |
| `A3` | `CRC_FINALIZE` | Apply reflect-out and xor-out |
| `A4`, `A5` | | Push CRC bits 7:0, 15:8 to RX |
| `E1` | `CRC32_SETUP` | Configure IEEE 802.3 CRC-32 (poly `0x04C11DB7`, reflected, init and xor all ones) |
| `E2`, `E3` | | Push CRC bits 23:16, 31:24 to RX |

**Events**

| Encoding | Name | Operation |
| --- | --- | --- |
| `Fx rise fall` | `ARM_EDGE` | Arm rising/falling-edge pin masks and clear edge/compare flags. A nonzero `x` also arms the compare on logical pin `x[2:0]` reading `x[3]`; `F0` disarms it, so "pin 0 low" cannot be a compare target |
| `D0 mask` | `WAIT_EVENT` | Wait until `pending & mask` is nonzero, then consume the matched sources |
| `AF` | `EVENT_STAMP` | Push one byte; three consecutive stamps give time bits 7:0, time bits 15:8, and the pending vector, captured together |
| `ED` | `EVENT_DETAIL` | Push the event detail captured with the most recent stamp |

**Action lanes**

| Encoding | Name | Operation |
| --- | --- | --- |
| `E8 target data`, `E9 target data` | `ACTION_WR_LO/HI` | Write the primary half of a slot, low/high byte |
| `EB target data`, `EC target data` | `ACTION_WR_BUNDLE_LO/HI` | Write the bundle half of a slot, low/high byte |
| `EA data`, `EE data` | | Preload lane 0's TX shifter low/high byte |
| `C8 cfg` | `LANE_TX_LOAD` | Pop a TX byte into a lane's TX shifter; `cfg = {lane, 0, msb_first, bits[4:0]}` (bits 0 means 16) |
| `E4 target` | `RUN_REGION` | Launch a region (nonblocking) |
| `E5 target count` | `RUN_REGION` | Launch a region that repeats `count` extra times |
| `E6` | `WAIT_REGION` | Wait for and consume one region-completion token |
| `E7 select` | `READ_RESULT` | `R[select[2:0]]` = result of lane `select[7]` |
| `EF select` | `PUSH_RESULT` | Push a result byte of lane `select[7]`: `select[0]` picks the high byte, `select[4:1]` shifts it left |

`target = {3'b0, lane, slot[3:0]}`. Lane operations wait until the selected
lane is idle; `RUN_REGION` also waits for admission (see
[Hazards](#hazards-and-arbitration)).

All other encodings (`A6`–`A9`, `Cx` other than `C8`) are `NOP`s.

## Action lanes

Each lane has a 16-slot action table, separate 16-bit TX and RX shift
registers, a 16-bit counter, an 8-bit delay timer, a sample bit, a 16-bit
result, and a configurable 16-bit LFSR (initial state `0xFFFF`, polynomial
`0x1021`). A lane executes one slot per cycle until a `DELAY` or a FIFO
stall holds it.

### Slot format

A slot is a 32-bit word: a primary action `{op[3:0], args[11:0]}` in bits
15:0 and a side-set **bundle** in bits 31:16. The bundle executes on the same
cycle as the primary action:

| Bundle bits | Field | Effect |
| --- | --- | --- |
| 15 | `enable` | Bundle is active |
| 14, 13 | `oe_we`, `oe` | Set the bundle pin's output enable |
| 12, 11 | `out_we`, `out` | Set the bundle pin's output value |
| 10:8 | `pin` | Bundle pin |
| 7 | `sample` | Sample the bundle pin into the sample bit and result (not with `SAMPLE` or `SHIFT`) |
| 6 | `lfsr` | Step the LFSR with the shifted bit (`SHIFT`) or the bundle pin |
| 5 | `count_dec` | Decrement the counter |
| 4:0 | `delay` | Stall `delay` extra cycles after this slot (ignored on `DELAY`, `NEXT`, `REPEAT`, `DONE`, and `COUNT` DJNZ) |

### Primary actions

| `op` | Name | Arguments |
| --- | --- | --- |
| `0` | `NOP` | |
| `1` | `GPIO` | `[11]` oe_we, `[10]` oe, `[9]` out_we, `[8]` out, `[2:0]` pin |
| `2` | `SAMPLE` | `[11]` shift into result (else replace), `[10]` MSB first, `[2:0]` pin |
| `3` | `SHIFT` | `[11]` receive only from `[2:0]`, `[10]` MSB first, `[9]` also receive from `[6:4]`, `[8]` open-drain transmit, `[7]` byte stream, `[6:4]` RX pin, `[2:0]` pin |
| `4` | `COUNT` | `[11:10]`: 0 load `[7:0]`, 1 increment, 2 decrement, 3 DJNZ to slot `[3:0]`; `[9]` finishes the region when DJNZ reaches zero |
| `5` | `LFSR` | `[11:10]`: 0 step with TX bit 0, 1 set polynomial byte, 2 set state byte, 3 copy LFSR to result; `[9]` high byte, `[7:0]` value |
| `6` | `NEXT` | Jump to slot `[3:0]` if `[11:8]` is 0 always, 1 counter zero, 2 counter nonzero, 3 sample bit set, 4 sample bit clear |
| `7` | `DELAY` | Stall `[7:0]` cycles; with `[11]`, then wait for synchronized pin `[10:8]` high |
| `8` | `REPEAT` | Jump to slot `[3:0]` |
| `9` | `DONE` | Release pins; repeat from the start slot or finish the region |
| `A` | `PAIR` | Classify pins `[2:0]` and `[5:3]` into result: both low 0, both high 3, else 1 when pin `[2:0]` equals `[6]` and 2 when not |
| `B` | `PULL` | Pop a TX byte into the TX shifter; `[5]` MSB first, `[4:0]` bits (0 means 16); stalls while empty |
| `C` | `PUSH` | Push a result byte to RX; `[0]` high byte, `[4:1]` left shift; stalls while full |

Opcodes `D`–`F` are `NOP`s.

**Streaming.** With `SHIFT[7]` set, the lane pops a TX byte on the first bit
of each byte and pushes the received byte on the eighth, with FIFO
backpressure. A full-duplex byte stream therefore needs one `SHIFT` per bit
and no explicit `PULL` or `PUSH`. Those remain useful for non-byte framing.

### Regions

`RUN_REGION` starts the lane at a slot. It runs until a `DONE` (or a
finishing `COUNT` DJNZ) with no repeats left, then posts one
`EV_REGION_DONE` token. With `E5`, each `DONE` before the last jumps back to
the start slot. The lane stops driving its pins at every `DONE`.

A typical clocked transfer (SPI, I²C, JTAG) is an eight-slot template: load
the bit count, launch TX with the idle clock, delay, activate the clock,
delay or wait for a released clock, sample RX, restore the idle clock, and
decrement or finish. Clock polarity and phase, open drain, and clock
stretching are slot-level choices.

### Table storage

The table is a 16×32 latch array per lane, written one byte at a time. A
write is staged on the rising edge, held across the falling edge, and
written into the latches during the next high phase. The lane reads a write
through the staging register in the cycle before it lands. Latches have no
reset: a slot reads as `NOP` until its primary low byte has been written
since the last slot-0 primary low write.

## Hazards and arbitration

**Pin claims.** Each lane keeps the set of pins its table drives or samples,
including bundle pins. A slot's pins are added when its primary or bundle
high byte is written; a primary low write to slot 0 starts a new table and
clears the set. Rewriting a nonzero slot in place can only widen the claim.

**Admission.** `RUN_REGION` waits until the selected lane is idle, every
slot in the table is complete (a primary low or bundle low write makes a slot
incomplete until a primary or bundle high byte is written), and its claim
does not overlap the other lane's active claim. A claim is active from launch until the region
finishes, across repeats.

**CPU stalls.**

- A CPU pin write, OE write, shift-out, or side-set to a claimed pin waits in
  execute. Writes to other pins proceed.
- Table writes, shifter preloads, `READ_RESULT`, and `PUSH_RESULT` wait until
  the selected lane is idle.
- `TX_LOAD`, `RX_PUSH`, CRC pushes, and event stamps wait until both lanes
  are idle, since a running lane may use the FIFOs.
- `MAP` and `HALT` wait until both lanes are idle, since a running lane
  drives and samples through the pin map.
- The CPU timer, ALU, CRC, and shifter continue while regions run.

**FIFO ports.** Each FIFO has one port. The dispatcher grants it to at most
one lane per cycle, round-robin when both request, and only when the FIFO
can serve the request; a lane without a grant holds its slot. A lane
transfer makes the port unavailable to the CPU that cycle, so `C8` and `EF`
on one lane retry instead of colliding with the other lane. `READ_RESULT`
and `PUSH_RESULT` are accepted on their operand cycle and complete one cycle
later from the latched operand; a deferred push owns the RX port for that
cycle. This keeps the SRAM output off the result paths without changing
instruction timing.

## Events

`WAIT_EVENT` matches when `pending & mask` is nonzero, then consumes one
token, or clears the flag, for every masked source. Timer and region
completions are counted (saturating at 7), so completions that arrive before
the wait are not lost. Edge and compare sources are sticky flags, cleared by
`ARM_EDGE` or a matching wait.

| Bit | Name | Source |
| --- | --- | --- |
| 1 | `EV_TIMER_DONE` | `START_TIMER` expiry |
| 2 | `EV_PIN_RISE` | Armed rising edge |
| 3 | `EV_PIN_FALL` | Armed falling edge |
| 4 | `EV_COMPARE` | Armed pin compare: set while the target latched by `ARM_EDGE` matches (level, re-asserts after a wait if still matching) |
| 6 | `EV_REGION_DONE` | Region completion (both lanes finishing together post two tokens) |

Bits 0, 5, and 7 are always zero.

The event detail byte records the most recent event as `{source[3:0], low[3:0]}`, where
`source` is the bit number above. `low` is the lowest matching logical pin
for edges, the lane for regions, and 0 otherwise. Edges take priority when
several sources fire in one cycle.

## GPIO fabric

Programs address logical pins. A permutation maps each logical pin to a
physical `uio` pin; `MAP` swaps two entries, so distinct logical pins always
refer to distinct physical pins. Output value and output enable are
independent, which open-drain protocols such as I²C need.

Inputs have two sampling paths:

- A two-flop synchronizer (with `async_reg`) feeds `WAIT_PIN`, `SHIFT_IN`,
  edge and compare events, and the lane `DELAY` pin wait.
- A single-flop sample feeds lane `SAMPLE`, `SHIFT`, and `PAIR`, for inputs
  whose protocol timing guarantees a stable window around the sampling edge.

## CRC

`crc_engine` is the CPU's CRC: width 1–16 with any polynomial, init value,
reflect-in, reflect-out, and xor-out, or IEEE 802.3 CRC-32 via `E1`. USB
CRC5/CRC16 and Ethernet CRC-32 are configurations. A feed processes two bits
per clock; a reflected finalize emits one bit per clock. The CPU waits on
`busy`. Each lane has its own LFSR, so lanes never contend for this engine.

## Soft low-speed USB demo

Bytecode with parallel GPIO actions emits low-speed USB line states (J, K,
SE0) at about 1.5 Mb/s on two `uio` pins. Wire D+/D− to `uio[0]`/`uio[1]`,
add a 1.5 kΩ pull-up on D− for a low-speed device's idle J, and add series
resistors as needed. This is not USB-compliant and is intended for an
analyzer or the cocotb host model.

## Future work

- A deeper instruction prefetch queue, once all programs can be re-timed.
- A byte-wide host streaming mode (needs a pinout change).
- DMA, richer completion routing, and debug trace on top of the CPU,
  dispatcher, and lanes.

Protocol-specific opcodes or FSMs (USB, 1-Wire, CAN, …) and accelerators
that duplicate what action words already express are out of scope.

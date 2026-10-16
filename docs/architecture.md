# Spatial protocol fabric

## Idea

Most programmable protocol engines are temporal: a processor executes one
instruction after another, and protocol timing is the sum of instruction
latencies. This design is spatial. Bit-level behavior is built by connecting
hardware tiles once, and the configured circuit then runs every clock cycle
with no instruction fetch.

- **Coarse tiles** do the expensive, common work: timers (clocks, baud
  ticks, timeouts, clock recovery), shifters (framing, serialization,
  sampling), counters (run lengths, frame counts), and a CRC engine.
- **Glue cells** (a 4-input LUT plus an optional flip-flop) supply the
  per-bit logic the coarse tiles do not: NRZI, Manchester, stuffing gates,
  line-state decoding, inversions.
- **One signal space** connects everything. Every tile input is a 6-bit
  select over 64 lines, so "the SCK falling edge advances the shifter" is a
  configuration value, not code.
- **A byte layer** sits between each shifter and its FIFO channel: stream
  tiles that work on tagged bytes `{err, eop, data}` with valid/ready
  handshakes (byte stuffing, packet delimiting, checksums, filtering).
  Bits stay in the bit fabric, where the wire's timing is; packets exist
  only from the byte layer up, where stalling a byte is possible.
- **A small controller (PX8)** writes the configuration and makes
  transaction-level decisions (which I2C condition or byte is next, EOP sequencing, CRC verdicts).
  It never times a bit.

UART, SPI, I2C, PS/2, low-speed USB, and 10BASE-T transmit are all
configurations in SRAM. There is no protocol-specific RTL.

```text
host link (ui/uo) ── SRAM 1024x8 ── PX8 controller ── cfg / readback / wait
        │                                   │
  TX FIFO ×2 ────┐              ┌─────────┴──────────┐
  RX FIFO ×2 ◀──┐ │              ▼                    ▼
                │ │   ┌───────────── 64-line signal space ─────────────┐
                │ └──▶│ timers ×4   shifters ×2   counters ×2   CRC ×1 │
                └─────│ glue cells ×8 (LUT4+FF)   pin rise/fall/level  │
                      └────────────────┬───────────────────────────────┘
                                 pin cells ×8 (registered)
                                       │
                                    uio[7:0]
```

## Signal space

Lines 2–31 are registered one-cycle pulses. The controller sees them through
sticky flags. The other lines are levels.

| Line | Signal |
| --- | --- |
| 0, 1 | constant 0, constant 1 |
| 2, 3 | controller `FIRE 0/1` |
| 4 + 2k, 5 + 2k | timer k rise, fall |
| 12 + 2k, 13 + 2k | shifter k word (every frame end), stop (went idle) |
| 16 + p, 24 + p | pin p rise, fall (synchronized) |
| 32 + p | pin p level (synchronized) |
| 40 + k | timer k output |
| 44 + k, 46 + k | shifter k output, active |
| 48 + k, 50 + k | counter k ≥ threshold, hit (registered pulse) |
| 52, 53 | CRC output bit, CRC matches check residue |
| 54, 55 | controller flags 0, 1 |
| 56 + k | glue cell k output |

Selects come in three kinds, chosen per input by what it can ever need:
**full** (6-bit, any line), **level** (5-bit, lines 32–63) and **pulse**
(5-bit, lines 0–31, which include the constants). Narrowing 49 of the 75
selects to 32-way cut combinational logic area by 17%, with no loss for any
program here. Level-only inputs that also need an "off" state (timer hold
and resync) carry an explicit enable bit.

The timing rules are simple and fixed:

- **Pulses** cost one cycle per hop.
- **Pin outputs** are registered: one cycle of uniform latency, glitch-free.
- **Inputs** pass a two-flop synchronizer.

Programs absorb these latencies in timer phase values. Timing is exact and
repeatable. For example, `test_10baset_frame` checks that every 10BASE-T
half-bit is exactly 2 cycles.

**No combinational loops, and bounded depth, by construction.** Tile
outputs depend only on their own registers (the CRC match flag included).
Glue cells see each other only as *registered* values. No configuration can
create a loop, and no combinational path crosses more than one glue cell.

This matters for timing closure because static timing analysis times every
structural path, not only the ones a program uses. Every select costs about
8 ns in the signoff slow corner, so the depth bound sets the clock. An
earlier two-rank structure (cells 4–7 saw cells 0–3 live) signed off at
+0.96 ns typical but −10.3 ns slow at 50 MHz, all from one chain:
CRC match → glue cell → glue cell → shifter start → TX FIFO write. A
program that needs two levels of logic either repeats terms inline (the
USB gated tick) or registers the first level and accepts a uniform cycle
of latency (the 10BASE-T Manchester and window cells).

**Arm.** Tiles and pin outputs stay idle until the program writes the arm
bit (config `0x31`). A partially written configuration can therefore never
act. Before arming, a counter whose threshold is still 0 reads as "≥". The
10BASE-T test caught exactly that hazard before arming existed. Tiles can
still be reconfigured after arming; the I2C master does this to hand pins
between the controller and the fabric.

## Tiles

All tile registers are written by the controller (`WCF address`). Program a
tile's period and select registers while it is stopped.

### Timer (×4), config `0x00 + 4k`

| Reg | Field |
| --- | --- |
| 0 | `reload` (period − 1) |
| 1 | `phase` (first interval − 1 after a start or resync) |
| 2 | `[5:0]` start line, `[11:6]` stop line, `[12]` idle level, `[13]` pulse mode |
| 3 | `[4:0]` resync level, `[5]` resync enable, `[10:6]` hold level, `[11]` hold enable, `[12]` hold invert |

Priority per cycle: stop, start (only while stopped), resync (restart the
interval at `phase`, for clock recovery), hold (freeze while the output is
high and the hold line, optionally inverted, is high; this implements I2C
clock stretching), then count. Toggle mode flips the output on every tick;
pulse mode reports every tick as a rise.

### Shifter (×2), config `0x10 + 4k` (burst register at `0x32 + k`)

| Reg | Field |
| --- | --- |
| 0 | transmit word (ignored while active) |
| 1 | `[3:0]` length − 1 (1..16), `[5:4]` pre count, `[6]` pre value, `[8:7]` post count, `[9]` post value, `[11:10]` parity (none/even/odd), `[12]` MSB first, `[13]` lead, `[14]` end on sample, `[15]` idle level |
| 2 | `[5:0]` shift line, `[11:6]` sample line |
| 3 | `[5:0]` start line, `[10:6]` input level, `[11]` auto-pull TX FIFO, `[12]` auto-push RX FIFO |
| 4 | `[4:0]` burst-end level, `[5]` burst mode |

- The output bit is a register. The next bit for each case (hold, advance,
  new frame) is precomputed, and the shift line only selects among them, so
  downstream paths start at a flop. Frame boundaries are registered
  alongside the frame register.
- Frames are `[pre][data][parity][post]`. Data bits land in `rx_data` at
  their natural position. Parity and post bits (stop bit, I2C ACK) are
  captured in `status[3:0]`.
- A new frame can start in the same cycle the previous one ends, so streams
  are gapless. A start line of 0 with auto-pull means "start whenever the TX
  FIFO has a byte". A start line of 1 means "run continuously".
- **Burst mode** frames a run of words once: `[pre][word][word]…[parity]
  [post]`. Where a word's last data bit would end the frame, the next word
  starts at its first data bit, pulled from the TX FIFO (auto-pull) or the
  data register again. The word during which the burst-end line has been
  high is the last one; so is a word whose successor the TX FIFO cannot
  supply. Parity covers the last word only. Every word pulses `word` and is
  auto-pushed, so a counter stepping on the word line with threshold
  N − 1 ends an N-word burst.
- Shifter k owns FIFO channel k: it pulls from TX FIFO k and pushes to RX
  FIFO k, so the two shifters never contend. While it auto-pulls, the
  controller's `PULL` on that channel waits (see below).
- A received word waits in a one-byte slot for the RX FIFO. A second word
  before then sets `status[14]` (overrun).

### Counter (×2), config `0x20 + 4k`

| Reg | Field |
| --- | --- |
| 0 | `[7:0]` threshold |
| 1 | `[5:0]` step line, `[10:6]` data level, `[12:11]` mode |
| 2 | `[4:0]` clear pulse line (priority over step) |

Modes: 0 count steps; 1 run of ones (data 0 clears); 2 run of zeros; 3 run
of equal bits (a change restarts at 1). The count saturates at 255. The
counter exports a ≥-threshold level and a hit pulse on the step that first
reaches the threshold. Run of ones is USB bit stuffing; run of equal bits is
CAN bit stuffing.

### CRC (×1), config `0x28`–`0x2E`

| Reg | Field |
| --- | --- |
| 0, 1 | polynomial `[15:0]`, `[31:16]` |
| 2, 3 | check residue `[15:0]`, `[31:16]` |
| 4 | `[5:0]` absorb line, `[10:6]` data level |
| 5 | `[5:0]` emit line, `[10:6]` init pulse line |
| 6 | `[4:0]` width − 1 (1..32), `[5]` init to all ones |

A bit-serial LFSR in wire order. *Absorb* folds in a data bit. *Emit*
shifts out the complemented register MSB first, which appends the FCS of
USB, CAN, Ethernet and similar protocols. *OK* compares the register with a
check residue (USB CRC16 `0x800D`, Ethernet CRC32 `0xC704DD7B`). While the
fabric is disarmed the register holds its init value.

### Glue cell (×8), config `0x40 + 4k`

| Reg | Field |
| --- | --- |
| 0 | truth table, indexed by `{in3, in2, in1, in0}` |
| 1 | `[5:0]` in0 line, `[11:6]` in1 line (any line) |
| 2 | `[4:0]` in2 level, `[9:5]` in3 level |
| 3 | `[4:0]` enable pulse line, `[5]` registered |

Only inputs 0–1 accept pulse lines. The configuration helper moves pulse
inputs there and permutes the truth table to match, so programs never
notice.

A registered cell loads its LUT output on cycles where the enable line is
high. That makes it a D flip-flop with enable: NRZI state, a sampled
previous bit, an SE0 latch.

### Pin cells (×8), config `0x18 + p`

`[4:0]` source level, `[5]` use controller pin, `[7:6]` mode (0 input,
1 push-pull, 2 open-drain). Any level line can drive any pin. A constant 0
is the controller pin left at 0.

### Byte tiles (×8), config `0x60 + 4t`

Tile `t = {channel, rx, stage}`. Each FIFO channel has two TX stages
(TX FIFO → stage 0 → stage 1 → shifter) and two RX stages (shifter →
stage 0 → stage 1 → RX FIFO). Every stage is the same tile and can be any
function, so the order of operations is chosen by configuration. A tile in
`PASS` (the reset state) is transparent.

| Reg | Fields |
| --- | --- |
| 0 | `[2:0]` function, `[3]` ESCAPE: append delimiter, `[4]` ESCAPE: delimiter before a packet, `[5]` CHECK: xor (else add), `[6]` CHECK: verify (else generate) |
| 1 | ESCAPE/UNESCAPE `{c1, c0}`; MATCH `{mask, value}`; CHECK initial value; TAG packet length |
| 2 | ESCAPE/UNESCAPE `{m1, m0}`; TAG `[5:0]` end line, `[11:6]` error line |
| 3 | ESCAPE/UNESCAPE `{F, E}` (delimiter, escape) |

| Function | Behavior |
| --- | --- |
| 0 `PASS` | Bytes and tags unchanged. |
| 1 `ESCAPE` | `c0` → `E m0`, `c1` → `E m1`; optionally frames each packet with `F`. |
| 2 `UNESCAPE` | The inverse: `F` ends a packet (eop on the byte before it), escapes are undone, a bad escape or a packet ended inside one is tagged err. |
| 3 `TAG` | Packets from fabric events: a packet ends when the end line fires, after `length` bytes, or on an input eop; err if the error line was high during it. |
| 4 `CHECK` | 8-bit add or xor checksum per packet. Generate appends the byte that makes the total zero (or a wrong one if the last byte is tagged err: error injection); verify tags err on a packet whose total is not zero. |
| 5 `MATCH` | Keeps packets whose first byte matches `value` under `mask`. |

- **Handshake.** A tile's output is one register and its `in_ready`
  depends only on its own registers, never on the downstream ready, so no
  combinational path crosses a tile. That halves throughput (one byte every
  two cycles) instead of adding a two-entry skid buffer; the fastest serial
  byte here (10BASE-T) takes 32 cycles.
- **Tags at the ends.** Host bytes are tagged eop with command `F`; the
  controller tags `TXP`/`PUSH` bytes with `opnd[5]` (eop) and `opnd[6]`
  (err) and sees a pulled byte's tags in `A[9:8]`. The shifter tags what it
  receives (eop at the end of a burst frame, err on a wrong parity or post
  bit) and, on TX, ends a burst on an eop byte (burst register `[6]`) and
  inverts the parity bit of a byte tagged err.
- **Across layers.** Byte tiles read fabric lines (TAG's end and error
  lines, e.g. an idle timer), the eop tag ends shifter bursts, and each
  tile's event (a packet passed, matched, or failed its check) is a sticky
  controller event at `WEV 64 + t`.
- **Ownership.** A shifter that auto-pulls owns its TX FIFO through its
  TX stages. The controller's `PUSH` waits while a byte is in flight from
  the shifter, so it never overtakes stream bytes.
- **Valid escape maps** have `{c0, c1} = {F, E}`, `F ≠ E`, `m0 ≠ m1`, and
  neither `m0` nor `m1` equal to `F` or `E`. Async HDLC/PPP is
  `7E→7D 5E, 7D→7D 5D`; SLIP is `C0→DB DC, DB→DB DD`.

## PX8 controller

One-byte instructions `{op, n}`. Wider operands are built with
Transputer-style prefixes (`opnd = O | n`; `PFIX` does `O = opnd << 4`).
Each instruction takes 2 cycles plus any stall; `LDM` takes 3.

The controller's job is to load the fabric and react to it, and the ISA
is shaped around that rather than around computation:

- **Block config load.** `CFG` writes `C` config words stored in SRAM at
  `P` as `{addr, data[7:0], data[15:8]}` triples, at 3 cycles a word
  (`LDC` + `WCF` with prefixes takes about 10). It leaves `P` past the
  block, `C = 0` and `A` = the last word. The assembler turns every run
  of two or more consecutive config writes into one block placed after
  the code.
- **Data pointer.** `LDM` reads `SRAM[P]` and advances `P`, so `C` stays
  free as a loop counter: `SETP src; SETC n; loop: LDM; TXP; DJNZ loop`
  streams data stored after the code (for example an Ethernet frame) into
  a TX FIFO at 11 cycles a byte. While a program feeds a TX FIFO, the host
  must not push to that channel.
- **Waits see registered inputs.** Bit timing lives in the fabric, so the
  controller never needs to react in the cycle a line changes. A `WEV` on
  a level line (32–63) sees the level one cycle late and never retires in
  its first execute cycle; pulse lines (2–31) are already sticky
  registers. The controller's `PULL` never contends with a shifter: a
  shifter that auto-pulls owns its TX FIFO outright, and the controller
  pulls only channels whose shifter does not. On RX, the controller's
  `PUSH` yields to a pending shifter push. No fabric line reaches the
  controller's state in the same cycle.

`PULL`, `PUSH` and `TXP` act on FIFO channel `opnd[4]` (a `PFIX 1` prefix
selects channel 1).

| op | Name | Effect |
| --- | --- | --- |
| 0 | `PFIX` | `O = (O \| n) << 4` |
| 1 | `LDC` | `A = opnd` |
| 2 | `SETP` | `P = opnd` (data pointer) |
| 3 | `XRC` | `A = A ^ opnd` |
| 4 | `J` | `pc = opnd` |
| 5 | `JZ` | if `A == 0`: `pc = opnd` |
| 6 | `DJNZ` | `C -= 1`; if `C != 0`: `pc = opnd` |
| 7 | `SETC` | `C = opnd` |
| 8 | `WCF` | `cfg[opnd] = A` |
| 9 | `RD` | `A = rd[opnd]` |
| A | `WEV` | wait for line `opnd`; pulse lines are sticky and consumed, level lines are seen one cycle late |
| B | `FIRE` | pulse line `2 + opnd[0]` |
| C | `PIN` | controller pin `n[2:0]` := `n[3]` |
| D | `DLY` | stall `opnd` extra cycles |
| E | `OPR` | 0 NOP, 1 HALT, 2 PULL, 3 PUSH, 4 CLREV, 5 `A = C`, 6 `C = A`, 7 TXP (TX FIFO = `A`), 8 LDM (`A = SRAM[P]`, `P += 1`), 9 CFG (block config load of `C` words at `P`); PULL/PUSH/TXP use channel `opnd[4]` |
| F | `ANDC` | `A = A & opnd` |

Readback: 0 pins, 1/3 shifter data, 2/4 shifter status, 5/6 counter
values, 7/8 CRC, 9/10 sticky flags. Config `0x30` sets controller flags
`[1:0]`; `0x31` arms the fabric.

## Verified protocols

All of these are in `test/cocotb_tests/protocols.py` and are checked
against independent reference models through the top-level pins only.

| Protocol | Tiles used | What is checked |
| --- | --- | --- |
| Framed burst (TX and RX) | 2 timers, 2 shifters in burst mode, 2 counters | one start bit, three bytes with no inner framing, parity over the last byte, one stop bit; the receiver pushes every byte |
| Two independent UART transmitters | 2 timers, 2 shifters | each shifter streams its own FIFO channel at its own bit rate |
| UART 8N1, full duplex | 2 timers, 2 shifters | every edge exactly one bit period; TX and RX concurrently |
| SPI master, modes 0–3 | timer (SCK), shifter | full-duplex bytes against a reference slave |
| I2C master | 2 timers (SCL + hold; condition slots + hold), 2 shifters (SDA/SCL patterns), 6 glue cells; START/STOP fabric-timed | write, repeated START, read, ACK/NACK, clock stretching in bytes and conditions; SDA changes while SCL is high only as START/STOP, each with a half-period setup and hold |
| PS/2 receive | shifter clocked by the device | 11-bit frames with odd parity |
| USB low speed, transmit | timer, shifter, 2 counters, CRC16, 8 glue cells | NRZI, bit stuffing (incl. in the CRC), CRC16, EOP; every transition on the bit grid |
| USB low speed, receive | timer with resync, counter, CRC16, 6 glue cells | clock recovery from a 3% slow sender, destuffing, CRC16 residue verdict, bad-CRC detection |
| 10BASE-T link session (40 MHz clock) | 4 timers, shifter, 2 counters, CRC32, 8 glue cells, controller streaming the frame from SRAM | link pulses exactly 100 ns wide and exactly 16 ms apart; a frame on the same TD± pair with exact 2-cycle half bits, preamble/SFD, FCS equal to `zlib.crc32`, and 300 ns TP_IDL |
| Async HDLC / PPP framing over UART | 2 timers, 2 shifters, 4 byte tiles (CHECK, ESCAPE; UNESCAPE, CHECK) | 7E delimiters and 7D escapes on the wire exactly as the reference stuffer produces them; received back unstuffed, checksum verified, last byte tagged eop |
| SLIP framing over UART | the same tiles, reconfigured | C0 / DB DC / DB DD stuffing, xor checksum |
| Injected checksum error | the same tiles; controller sends the packets | a packet whose last byte the controller tagged err goes out with a wrong checksum and is received tagged err; a clean packet is not |
| Modbus-RTU-style idle framing + address filter | timer (idle gap, restarted by a glue cell on every RX edge), shifter, 2 byte tiles (TAG, MATCH), controller | packets delimited only by line idle time; only packets for address 0x11 reach the host; the match event reaches the controller, which raises a pin |
| Packet bursts | timer, shifter in burst mode ended by the eop tag | each host packet is exactly one frame: start bit, bytes back to back, parity over the last byte, stop bit |
| UART 8E1 framing errors | timer, shifter | wrong parity and wrong stop bits reach the host tagged err; clean bytes do not |

### How USB transmit composes

At each bit tick E, the NRZI glue cell latches the current bit X. X is
registered every cycle; nothing it depends on changes in the cycle before
a tick, so the NRZI cell and the stuffing counter see the right bit. X is a
stuffed 0 if counter 0 (run of ones) has reached 6; otherwise it's the
shifter bit, or the CRC bit once the shifter runs dry. Gated tick G = E and
not stuffing: it advances the shifter and either absorbs (after SYNC/PID)
or emits (after the data) in the CRC tile. Counter 1 counts emitted FCS
bits. The controller then raises the SE0 flag, and a registered glue cell
applies it at the next tick, never in place of a pending stuffed bit.

### 10BASE-T scope

What is verified is a transmit-only link session: link pulses every 16 ms
and a frame streamed from SRAM, both on the same TD± pair.

- **Frame source:** the controller copies the frame from SRAM into the TX
  FIFO (`LDM`/`TXP`), so host bandwidth does not matter. A minimum 64-byte
  frame fits after the program in the 1 KB SRAM.
- **Clock:** 10 Mb/s Manchester has 50 ns half bits, which needs a 40 MHz
  clock (±100 ppm from the board). At 50 MHz a half bit would be 2.5 cycles.
- **Analog front end:** TD± needs an external resistor network and pulse
  transformer. There is no waveform pre-distortion, so this is the
  hobby-grade "bit-banged" class of transmitter, not a compliant PHY.
- **Receive:** not attempted. It needs clock recovery at 2 samples per half
  bit plus an analog receiver.

## Programmability

**Expressible:** framed serial protocols with any timing, bit order,
parity, and pre/post bits; device-clocked or self-clocked links; clock
stretching; edge-based clock recovery; NRZI and Manchester; bit stuffing;
any CRC up to 32 bits. CAN (equal-bit stuffing, CRC15), JTAG, SWD and
1-Wire fit the same tiles but are not yet tested.

**Not expressible yet:**

- **Long frames:** a data field longer than 16 bits that is not a whole
  number of words (burst mode covers whole words).
- **Bit-time arbitration:** CAN or I2C multi-master arbitration is
  composable from glue cells but untested.
- **Capacity:** more than 2 simultaneous streams (one FIFO channel per
  shifter).
- **Fast front ends:** anything that needs more than 2 samples per half bit
  at the clock rate.

**Versus an eFPGA:**

- **Granularity:** this fabric is coarse. A 16-bit timer or a framed
  shifter is one tile with about 60 config bits, where an eFPGA builds
  everything from LUTs and pays mostly for routing.
- **Timing:** every configuration meets the clock that was signed off once
  at tapeout. There is no per-design place-and-route or timing closure.
- **Reconfiguration:** a register write, possible mid-transaction.
- **Generality:** the eight glue cells buy back most of the eFPGA's
  flexibility for the per-bit logic coarse tiles miss.

## Host interface

The Tiny Tapeout host link, 1024×8 SRAM macro, and two FIFO channels (a
4-deep TX and RX FIFO per shifter). Command `E` selects the channel that
the TX, RX, status and level commands use (0 after reset). `ui_in` passes a two-flop synchronizer, and a byte
counts only once it is stable for two cycles, so the host may drive the
pins asynchronously. Hold each command byte, and the `8'h00` that follows
it, for at least 2 clocks (see [hardware.md](hardware.md)):

| Command | Operation |
| --- | --- |
| `1`, `2`, `3` | Set address bits 3:0, 7:4, 9:8 |
| `4`, `5` | Stage program low nibble; high nibble + write + increment |
| `6`, `7` | Stage TX low nibble; high nibble + push |
| `8` | bit 0 start, bit 1 stop |
| `9` | Pop RX byte to `uo_out` |
| `A` | Status `{running, halted, tx_full, rx_empty, 4'b0}` (FIFO bits: selected channel) |
| `B` | Read SRAM at the current address |
| `C` | Selected channel levels `{tx_full, rx_empty, tx_level[2:0], rx_level[2:0]}` |
| `D` | Peek RX without popping |
| `E` | Select FIFO channel `payload[0]` |

Every command must be followed by `8'h00`. A command held for several
cycles acts once, and `8'h00` re-arms the decoder. A byte seen for a single
cycle while the pins change never acts. Commands `4` and `6`
share one low-nibble stage, so stage and commit one byte at a time.

`HALT` makes the host clear `enable`, which returns every tile and pin to
idle.

## Verification

- `make dead-check`: Verilator `-Wall` unused/undriven signals plus yosys
  constant or never-active flip-flops (including `opt_dff -sat`). Currently
  0 findings.
- cocotb: 22 tests covering the protocols above, using pins and host
  commands only, so they are gate-level safe.
- Formal (`make formal`, details in [formal/README.md](../formal/README.md)),
  ten targets, each against an independent reference:
  - whole core: no pin driven before an arm write is possible, pins
    released when stopped, FIFO channel handshakes, for any program;
  - PX8: an ISA reference model running a symbolic program;
  - host link: the pin contract under an asynchronous, glitching host
    (unbounded proof);
  - timer: a cycle-count model; shifter: a frame builder (including burst
    mode) with a loopback round-trip check;
  - counter, CRC, glue cell, FIFO and SRAM: unbounded proofs against a
    per-mode reference, the reflected software LFSR, the truth table, an
    age-ordered queue, and a tracked-address abstraction.

  `mutation_check.py` confirms the harnesses reject 17 representative RTL
  bugs, at least one per target.
- Area (liberty-mapped synthesis, IHP sg13cmos5l): about 194k µm². That
  includes the register-output shifter and CRC changes, which traded about
  12k µm² for shorter paths.

## Known limits and next steps

- **Timing at signoff.** The first spatial fabric (v1, timers and shifters
  only) passed the full GDS flow, including the gate-level test, with
  +3.83 ns setup slack at 50 MHz in the slow corner (1.08 V, 125 °C). Its
  critical path starts at the SRAM macro. The earlier CPU design failed the
  same corner by 5.28 ns. v2 with two glue ranks passed CI (which gates on
  the typical corner, +0.96 ns) but failed the slow corner by 10.3 ns
  through a CRC match → glue → glue → shifter → TX FIFO chain. The fixes
  are a registered CRC match, glue cells that see each other registered,
  and a FIFO that no longer accepts a push into a full FIFO on a
  same-cycle pop. The SRAM paths keep +3.2 ns slow-corner slack.
- **Formal depth:** the timer, shifter, controller and core targets are
  bounded. PDR and k-induction did not converge on the timer or shifter
  within 30 minutes, and the controller and core are too large for PDR.

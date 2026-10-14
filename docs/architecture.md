# Spatial protocol fabric

## Idea

Most programmable protocol engines are temporal: a processor executes one
instruction after another and protocol timing is the sum of instruction
latencies. This design is spatial. Bit-level behavior is built by wiring
small hardware tiles together once, and the configured circuit then runs
every clock cycle with no instruction fetch at all.

- **Tiles** do the bit-level work: timers make clocks, baud ticks and
  timeouts; shifters frame, serialize, sample and deserialize; pin cells
  route a tile to a pad as push-pull or open-drain.
- **A registered event bus** connects them. A tile's trigger inputs are
  5-bit selects onto 32 event lines, so "SCK falling edge advances the
  shifter" is a configuration value, not code.
- **A small controller (PX8)** writes the configuration and makes
  transaction-level decisions (I2C START/STOP/ACK handling, byte counts).
  It never touches bit timing.

UART, SPI, and I2C differ only in configuration words held in SRAM. There is
no protocol-specific RTL.

```text
                         host link (ui/uo) ── SRAM 1024x8 ── PX8 controller
                                   │                             │ cfg / rd / wait
                                TX FIFO   RX FIFO                ▼
                                   │        ▲        ┌──── config registers ────┐
                                   ▼        │        ▼                          ▼
 events[31:0] ◀─ reg ◀─┬─ timer 0..3  (rise/fall)   shifter 0..1 (start/done)
     │                 └─ pin 0..7 rise/fall (2-flop synchronized)
     └──────▶ every tile's start / stop / shift / sample select
                                   │                      │
                                pin cells: source × {input, push-pull, open-drain}
                                   │ (registered)
                                 uio[7:0]
```

## Why spatial

| Property | Temporal CPU (previous `cmos5l`) | Spatial fabric |
| --- | --- | --- |
| Bit timing | instruction-count accounting (`+11` per UART bit) | timer reload value, exact |
| Concurrency | CPU + 2 lanes sharing pins, with claim scoreboards | every tile runs in parallel; ownership fixed by config |
| Hazard logic | pin claims, launch scan, FIFO round-robin, stall rules | none needed; one pin cell selects one source |
| Generic cells (yosys `synth`) | 18,961 | **4,363** (−77%) |

Two protocols at once falls out naturally: the full-duplex UART test runs an
independent transmitter (timer 0 + shifter 0) and receiver (timer 1 +
shifter 1) concurrently with the controller idle.

## Timing model

Everything is synchronous to `clk` (50 MHz target).

- **One cycle per hop.** Every event line is registered, so a tile reacts one
  cycle after the event it selects. A configuration cannot form a
  combinational loop, and every latency is a fixed number of cycles.
- **Registered pins.** Pin outputs and output enables are registered after the
  source mux: one cycle of uniform latency and glitch-free pads.
- **Synchronized inputs.** Pins pass through a two-flop synchronizer; pin rise
  and fall events come from the synchronized value.

Programs absorb these fixed latencies in timer phase values. For example, the
UART transmitter uses `phase = bit − 3` so that the start-bit length equals
every other bit, and the receiver uses `phase = bit/2 − 2` to sample
mid-bit after synchronizer and hop delays. `test_uart_tx_bit_period_is_exact`
checks every edge interval of a frame to the cycle.

## Tiles

All tile registers are 16 bits wide and written by the controller (`WCF`).
Program reload, phase and ctl only while the tile is stopped. A start always
uses the previously written phase.

### Timer tile (×4)

A reload counter. After a start, the first tick comes `phase + 1` cycles
later and then one every `reload + 1` cycles. In toggle mode the output flips
on each tick and the tick is reported as a rise or fall event; in pulse mode
the output stays idle and every tick is a rise event.

| Reg | Field |
| --- | --- |
| 0 | `reload` (period − 1) |
| 1 | `phase` (first interval − 1) |
| 2 | `[4:0]` start select, `[9:5]` stop select, `[10]` idle level, `[11]` pulse mode, `[14:12]` hold pin, `[15]` hold enable |
| 3 | `[0]` start now, `[1]` stop now (strobes) |

Stop has priority over start and tick. **Hold** implements clock stretching
generically: while the output is high but the selected pin still reads low,
the counter freezes, so a high phase is never shorter than programmed.

### Shifter tile (×2)

Emits and captures one framed word: `[pre bits][data bits][parity][post bits]`.
The frame index advances on the shift event; the input pin is captured on the
sample event. Separate shift and sample selects give every CPOL/CPHA
combination and full duplex.

| Reg | Field |
| --- | --- |
| 0 | transmit word (ignored while active) |
| 1 | `[3:0]` length − 1 (1..16), `[5:4]` pre count, `[6]` pre value, `[8:7]` post count, `[9]` post value, `[11:10]` parity (none/even/odd), `[12]` MSB first, `[13]` lead, `[14]` end on sample, `[15]` idle level |
| 2 | `[4:0]` shift select, `[9:5]` sample select, `[14:10]` start select |
| 3 | `[2:0]` input pin, `[3]` auto-pull TX FIFO, `[4]` auto-push RX FIFO, `[5]` start now (strobe) |

- Data bits land in `rx_data` at their natural bit position, so an 8-bit word
  is always `rx_data[7:0]` whatever the bit order. Parity and post bits (UART
  stop bit, I2C ACK) are captured into `status[3:0]`, newest in bit 0.
- **Lead** makes the first shift event present bit 0 (CPHA = 1). **End on
  sample** finishes the frame on the last sample instead of the last shift.
- With auto-pull and start select 0, the shifter starts whenever the TX FIFO
  has a byte, so streams run back to back without controller involvement.
- A completed receive waits in a one-byte push slot until the RX FIFO accepts
  it. A second completion before then sets `status[14]` (overrun).

### Pin cells (×8)

Config `0x18 + p`: `[2:0]` source (0 controller, 1–4 timer 0–3, 5–6
shifter 0–1, 7 zero) and `[4:3]` mode (0 input, 1 push-pull, 2 open-drain).
Open-drain drives low for 0 and releases for 1. Pins reset to input and
return to input whenever the engine is disabled.

### Event bus

| Index | Event |
| --- | --- |
| 0 | never |
| 1 | always |
| 2, 3 | controller `FIRE 0/1` |
| 4 + 2k, 5 + 2k | timer k rise, fall |
| 12, 13 | shifter 0 start, done |
| 14, 15 | shifter 1 start, done |
| 16 + p | pin p rise |
| 24 + p | pin p fall |

The controller sees the bus through 32 sticky flags: `WEV e` waits for flag
`e` and consumes it; `CLREV` clears all of them.

## PX8 controller

One-byte instructions `{op[3:0], n[3:0]}`. Wider operands are built with
Transputer-style prefixes: `opnd = O | n`, `PFIX` does `O = opnd << 4`, and
every other instruction clears `O`. Each instruction takes 2 cycles (fetch +
execute) plus any stall.

| op | Name | Effect |
| --- | --- | --- |
| 0 | `PFIX` | `O = (O \| n) << 4` |
| 1 | `LDC` | `A = opnd` |
| 2 | `ADC` | `A = A + opnd` |
| 3 | `XRC` | `A = A ^ opnd` |
| 4 | `J` | `pc = opnd` |
| 5 | `JZ` | if `A == 0`: `pc = opnd` |
| 6 | `DJNZ` | `C -= 1`; if `C != 0`: `pc = opnd` |
| 7 | `SETC` | `C = opnd` |
| 8 | `WCF` | `cfg[opnd] = A` |
| 9 | `RD` | `A = rd[opnd]` |
| A | `WEV` | wait for sticky event `opnd`, consume it |
| B | `FIRE` | pulse controller event `opnd[0]` |
| C | `PIN` | controller pin `n[2:0]` := `n[3]` |
| D | `DLY` | stall `opnd` extra cycles |
| E | `OPR` | `0` NOP, `1` HALT, `2` PULL (`A` = TX byte), `3` PUSH (RX = `A[7:0]`), `4` CLREV, `5` `A = C`, `6` `C = A` |
| F | `ANDC` | `A = A & opnd` |

Readback (`RD`): 0 pins, 1/3 shifter 0/1 data, 2/4 shifter 0/1 status
`{active, overrun, push pending, 9'b0, post bits[3:0]}`, 5 timers running,
6/7 sticky flags `[15:0]`/`[31:16]`.

Configuration addresses: `0x00–0x0F` timer `addr[3:2]` register `addr[1:0]`,
`0x10–0x17` shifter `addr[2]` register `addr[1:0]`, `0x18–0x1F` pin cells.

## Protocol mappings

These live in `test/cocotb_tests/protocols.py`, built with the assembler in
`test/cocotb_tests/fabric.py`.

**UART 8N1, full duplex.** TX: shifter 0 auto-pulls, frame `pre 1×0`,
`post 1×1`, LSB first; its start event starts timer 0 (pulse mode), whose
ticks shift. RX: a falling edge on the RX pin starts timer 1 (first tick
mid-start-bit) and shifter 1. Each tick samples and shifts, and the frame
auto-pushes. The controller just spins.

**SPI master, modes 0–3.** Timer 0 is SCK (toggle mode, idle = CPOL), started
and stopped by shifter 0's start/done events. CPHA 0 samples on the leading
edge and shifts on the trailing edge. CPHA 1 uses lead mode and ends on the
last sample. The controller drives CS and counts done events.

**I2C master.** Timer 0 drives SCL open-drain, with hold on the SCL pin for
clock stretching. Shifter 0 drives SDA open-drain, shifts on the timer fall,
and samples on the *observed* SCL rise event (pin 1 rise). A 9-bit frame (8
data + 1 post bit) carries the ACK both ways: post value 1 releases SDA so the
slave's ACK is captured in `status[0]`, and post value 0/1 sends ACK/NACK
after a read. START, repeated START and STOP are controller pin sequences
that hand the pins back and forth by rewriting pin-cell sources. Releasing SCL
waits for the SCL rise event, so a stretching slave is honored there too.

## Host interface (unchanged boundary)

The Tiny Tapeout host link, 1024×8 SRAM macro, and 4-deep TX/RX FIFOs keep
their existing behavior. A command byte is presented on `ui_in` for one
clock, followed by `8'h00`; the upper nibble is the command:

| Command | Operation |
| --- | --- |
| `1`, `2`, `3` | Set address bits 3:0, 7:4, 9:8 |
| `4`, `5` | Stage program low nibble; high nibble + write + increment |
| `6`, `7` | Stage TX low nibble; high nibble + push |
| `8` | bit 0 start, bit 1 stop |
| `9` | Pop RX byte to `uo_out` |
| `A` | Status `{running, halted, tx_full, rx_empty, 4'b0}` |
| `B` | Read SRAM at the current address |
| `C` | FIFO levels `{tx_full, rx_empty, tx_level[2:0], rx_level[2:0]}` |
| `D` | Peek RX without popping |

`HALT` makes the host clear `enable`, which returns every tile and pin to
idle. Program memory is host-accessible only while stopped.

## Verification

- `make dead-check`: Verilator `-Wall` unused/undriven signals plus yosys
  constant/never-active flip-flop detection. Currently 0 findings.
- cocotb (pins and host commands only, so gate-level safe): exact UART bit
  period, UART streaming, full-duplex UART, SPI modes 0–3 against a reference
  slave, I2C write + repeated START + read, I2C clock stretching, I2C NACK.
- Formal (`make formal`): timer tile against an independent cycle-count
  model; shifter tile against an independently built frame model with a
  loopback round-trip check; FIFO and SRAM proofs. `mutation_check.py`
  confirms the harnesses reject six representative RTL bugs.

## Known limits and next steps

- Tile counts (4 timers, 2 shifters) are a starting point. At about 4.4k
  generic cells there is room for more tiles inside 6×4.
- Both shifters share one TX/RX FIFO pair (fixed priority). Two simultaneous
  streaming protocols need per-tile FIFO channels plus a host channel select.
- Candidate generic tiles: CRC/LFSR fed by a shifter's bit stream (USB CRC5/16,
  Ethernet CRC32), a run-length/pattern matcher (USB bit stuffing, 1-Wire
  presence), and an NRZI/Manchester line coder.
- The tile formal targets are BMC + cover. Unbounded PDR proofs did not
  converge on the 16-bit counters within 15 minutes.

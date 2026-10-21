# Tiles

Each tile does one kind of job. The program sets a tile up by writing its
configuration registers (instruction `WCF`, or a block load `CFG`). Every
field that says "line" is a number from the [signal space](signal-space.md).

Contents: [Timer](#timer) · [Shifter](#shifter) · [Counter](#counter) ·
[CRC](#crc) · [Logic cell](#logic-cell) · [Pin cell](#pin-cell)

---

## Timer

**What it is for:** bit clocks, baud rates, timeouts, one-shot delays, and
following an incoming clock (clock recovery).

**How it works:** once started, it ticks every `reload + 1` cycles. The
first tick comes `phase + 1` cycles after a start. In *toggle* mode its
output flips on each tick; in *pulse* mode every tick is a rise pulse.

- **Resync:** a line can restart the count from `phase`. Used to lock onto
  an incoming clock.
- **Hold:** a line can freeze the timer while its output is high. Used for
  I2C clock stretching.

While stopped, and while the fabric is not yet armed, the output rests at
the idle level, so a clock that rests released (an open-drain PS/2 clock)
never glitches when the fabric starts.

There are 4 timers, at configuration `0x00 + 4k`:

| Reg | Field |
| --- | --- |
| 0 | `reload` (period − 1) |
| 1 | `phase` (first interval − 1) |
| 2 | `[5:0]` start line, `[11:6]` stop line, `[12]` idle level, `[13]` pulse mode |
| 3 | `[4:0]` resync level, `[5]` resync on, `[10:6]` hold level, `[11]` hold on, `[12]` hold inverted |

Each cycle, in priority order: stop, start (only while stopped), resync,
hold, count.

---

## Shifter

**What it is for:** sending and receiving framed words, such as a UART byte
with start and stop bits, an SPI byte, or an I2C byte with its ACK bit.

**How it works:** a *frame* is `[pre bits][data bits][parity][post bits]`.
On each tick of its *shift line* the shifter moves to the next bit. On each
tick of its *sample line* it reads its input line. It can take bytes from
its TX FIFO (*auto-pull*) and give received bytes to its RX FIFO
(*auto-push*).

There are 2 shifters, at configuration `0x10 + 4k` (register 4 at
`0x32 + k`):

| Reg | Field |
| --- | --- |
| 0 | word to send |
| 1 | `[3:0]` data length − 1 (1 to 16 bits), `[5:4]` pre count, `[6]` pre value, `[8:7]` post count, `[9]` post value, `[11:10]` parity (none / even / odd), `[12]` MSB first, `[13]` lead, `[14]` end on sample, `[15]` idle level |
| 2 | `[5:0]` shift line, `[11:6]` sample line |
| 3 | `[5:0]` start line, `[10:6]` input line, `[11]` auto-pull, `[12]` auto-push |
| 4 | `[4:0]` burst-end line, `[5]` burst mode, `[6]` end burst on an end-of-packet byte, `[12:7]` abort line |

Good to know:

- **Gapless:** a new frame can start in the same cycle the last one ends.
- **Start line:** 0 with auto-pull means "start whenever a byte is
  waiting"; 1 means "run continuously".
- **Burst mode:** puts several words inside one frame:
  `[pre][word][word]…[parity][post]`. The burst ends after the word during
  which the burst-end line was high, after a byte tagged end-of-packet, or
  when the FIFO runs out.
- **Abort line:** while high, the shifter drops a frame in progress. Used
  when an Ethernet signal disappears in the middle of a byte.
- **Tags:** received bytes are tagged *err* if the parity or stop bit was
  wrong, and *eop* at the end of a burst frame. A byte to send that is
  tagged *err* goes out with its parity bit flipped on purpose (error
  injection).
- **Overrun:** if a second byte arrives before the first was taken,
  `status[14]` is set.

---

## Counter

**What it is for:** counting events, and detecting runs of equal bits (for
example 6 ones in a row, which triggers USB bit stuffing).

There are 2 counters, at configuration `0x20 + 4k`:

| Reg | Field |
| --- | --- |
| 0 | `[7:0]` threshold |
| 1 | `[5:0]` step line, `[10:6]` data line, `[12:11]` mode |
| 2 | `[4:0]` clear line |

Modes:

| Mode | Counts |
| --- | --- |
| 0 | steps |
| 1 | a run of ones (a 0 resets it) |
| 2 | a run of zeros (a 1 resets it) |
| 3 | a run of equal bits (a change restarts at 1) |

The count stops at 255. The counter outputs "at or above threshold" (a
level) and "just reached it" (a pulse).

---

## CRC

**What it is for:** the checksums that USB, Ethernet, CAN and others put at
the end of a packet.

**How it works:** one bit at a time, in the order the bits are on the wire.

- **Absorb:** fold one data bit in.
- **Emit:** shift the checksum out.
- **OK line:** high when the register equals the expected *check residue*
  (for example USB CRC16 `0x800D`, Ethernet CRC32 `0xC704DD7B`).

There is 1 CRC engine, at configuration `0x28`–`0x2F`:

| Reg | Field |
| --- | --- |
| 0, 1 | polynomial, low and high 16 bits |
| 2, 3 | check residue, low and high 16 bits |
| 4 | `[5:0]` absorb line, `[10:6]` data line |
| 5 | `[5:0]` emit line, `[10:6]` restart line |
| 6 | `[4:0]` width − 1 (1 to 32 bits), `[5]` start at all ones |
| 7 | `[4:0]` absorb gate level, `[5]` absorb gated, `[10:6]` emit gate level, `[11]` emit gated |

A gated absorb or emit acts only while its gate level is high. A raw timer
edge can then step the CRC in the same cycle as the shifter it follows;
gating the edge in a logic cell instead would cost that cell's cycle.

---

## Logic cell

**What it is for:** the small pieces of logic the bigger tiles don't cover,
such as NRZI and Manchester line codes, "this AND not that", or remembering
one bit.

**How it works:** a 4-input lookup table feeding a flip-flop, the logic
cell of an FPGA. The truth table gives the next value for each of the 16
input combinations; the flip-flop loads it on cycles when the enable line
is high (the constant 1 line: every cycle, so the output is the function
one cycle late). While the fabric is stopped the flip-flop holds a
configured start value, so an inverted output such as a chip select is
already at its idle level when the fabric starts.

The output is always the flip-flop, like every other line in the signal
space. A path therefore crosses the fabric at most once per cycle, so
timing closes for every configuration, and a logic cell costs exactly one
cycle, which programs account for like any other pulse delay.

There are 8 logic cells, at configuration `0x40 + 4k`:

| Reg | Field |
| --- | --- |
| 0 | truth table, indexed by `{in3, in2, in1, in0}` |
| 1 | `[5:0]` input 0 line, `[11:6]` input 1 line |
| 2 | `[4:0]` input 2 line, `[9:5]` input 3 line (levels only) |
| 3 | `[4:0]` enable line, `[5]` start value |

The configuration helper builds truth tables from a Python function, for
example `truth(lambda a, b: a and not b, 2)`.

---

## Pin cell

**What it is for:** driving a pin.

There are 8 pin cells, at configuration `0x18 + p`:

| Field | Meaning |
| --- | --- |
| `[4:0]` | which level line drives the pin |
| `[5]` | constant: drive bit `[4]` instead of a line |
| `[7:6]` | mode: 0 input (not driven), 1 push-pull, 2 open-drain (only pulls low) |

Next: [Contexts](contexts.md).

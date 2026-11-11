# Tiles

Each tile does one kind of job. The program sets a tile up by writing its
configuration registers (instruction `WCF`, or a block load `CFG`). Every
field that says "line" is a number from the [signal space](signal-space.md).

Contents: [Timer](#timer) · [Shifter](#shifter) · [Counter](#counter) ·
[CRC](#crc) · [Logic cell](#logic-cell) · [Edge cell](#edge-cell) ·
[Pin cell](#pin-cell)

---

## Timer

**What it is for:** bit clocks, baud rates, timeouts, one-shot delays, and
following an incoming clock (clock recovery).

**How it works:** once started, it ticks every `reload + 1` cycles. The
first tick comes `phase + 1` cycles after a start. In *toggle* mode its
output flips on each tick; in *pulse* mode every tick is a rise pulse.

- **Resync:** a line (any line, so an [edge cell](#edge-cell)'s pulse
  directly) can restart the count from `phase`. Used to lock onto an
  incoming clock.
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
| 3 | `[5:0]` resync line, `[6]` resync on, `[11:7]` hold level, `[12]` hold on, `[13]` hold inverted |

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
`0x32 + k`, the bit coder's registers 5 and 6 at `0x36 + k` and `0x38 + k`):

| Reg | Field |
| --- | --- |
| 0 | word to send |
| 1 | `[3:0]` data length − 1 (1 to 16 bits), `[5:4]` pre count, `[6]` pre value, `[8:7]` post count, `[9]` post value, `[11:10]` parity (none / even / odd), `[12]` MSB first, `[13]` lead, `[14]` end on sample, `[15]` idle level |
| 2 | `[5:0]` shift line, `[11:6]` sample line |
| 3 | `[5:0]` start line, `[10:6]` input line, `[11]` auto-pull, `[12]` auto-push |
| 4 | `[4:0]` burst-end line, `[5]` burst mode, `[6]` end burst on an end-of-packet byte, `[12:7]` abort line |
| 5 | bit coder: `[2:0]` stuff after N bits (0: off), `[3]` runs of ones (else equal bits), `[4]` NRZI, `[5]` code received bits (else sent ones), `[6]` arm at the first 0, `[7]` invert tail, `[8]` word line pulses every bit, `[14:9]` tail length, `[15]` Manchester (sending) |
| 6 | bit coder: `[4:0]` stuffing gate level, `[5]` gated, `[12:6]` bits kept from the CRC link |

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

### Bit coder

**What it is for:** the bit-level glue that USB, CAN, HDLC and 10BASE-T
wrap around their bytes (bit stuffing, NRZI or Manchester, and the CRC sent
after the data). Without it, that glue takes logic cells and counters: CAN,
USB and HDLC transmit and the 10BASE-T link use all 8 logic cells and both
counters. With it, CAN transmit uses none of either and none of the others
more than 4 cells or any counter (see [protocols](protocols.md)).

The coder sits between the frame and the line, inside the shifter. With
registers 5 and 6 at 0 it is off and the shifter behaves exactly as above.

- **Stuffing.** After N equal bits in a row (CAN: 5) or N ones (USB: 6,
  HDLC: 5), a sender puts out one opposite bit without moving on in the
  frame; a receiver drops that sample, and tags the frame *err*
  (`status[4]`) if it was not the opposite bit. Runs carry across words,
  burst words and back-to-back frames, and restart when the shifter
  starts from idle. *Arm at the first 0* waits for CAN's start-of-frame;
  the *gate* level turns stuffing on and off (CAN's tail is not stuffed).
- **NRZI.** Sending, a 0 flips the line and a 1 keeps it. Receiving, a
  bit is 1 when the line kept its level since the last sample.
- **Manchester** (sending). The shift line ticks every half bit; each bit
  goes out as its complement, then as itself (a 1 is low-high, as in IEEE
  802.3), so every bit has a transition in its middle. Only every second
  tick moves on in the frame, so stuffing, the tail and the CRC link
  still work per bit.
- **Tail.** After the last word, the sender puts out *tail length* bits
  from CRC engine k (shifter k's own), stuffed too, then ends. CAN's CRC
  goes out as it is (*invert tail*); the CRC engine already inverts USB's,
  HDLC's and Ethernet's.
- **CRC link.** The coder hands the CRC engine every frame bit (never a
  stuff or tail bit) and steps it once per tail bit, over a direct wire
  rather than signal-space lines (CRC register 6 `[6]`). The first
  `register 6 [12:6]` bits are not handed over (USB: 16, SYNC and PID;
  10BASE-T: 64, preamble and SFD).
- **Bit pulse.** With `[8]` the word line pulses once per received bit
  instead of once per word, so a counter can count destuffed bits (CAN
  finds the DLC and the CRC delimiter that way). FIFO pushes stay per word.

A receiving coder needs the shift and sample lines to be the same.

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

There are 2 CRC engines, CRC 0 at configuration `0x28`–`0x2F` and CRC 1
at `0x88`–`0x8F` (lines 52/53 and 50/51), so both directions of a link,
or two links, each have their own. Shifter k's coder tail reads CRC k;
either engine can take its bits from lines or from either shifter's
link:

| Reg | Field |
| --- | --- |
| 0, 1 | polynomial, low and high 16 bits |
| 2, 3 | check residue, low and high 16 bits |
| 4 | `[5:0]` absorb line, `[10:6]` data line |
| 5 | `[5:0]` emit line, `[10:6]` restart line |
| 6 | `[4:0]` width − 1 (1 to 32 bits), `[5]` start at all ones, `[6]` linked to a shifter's bit coder, `[7]` which shifter |
| 7 | `[4:0]` absorb gate level, `[5]` absorb gated, `[10:6]` emit gate level, `[11]` emit gated |

Linked to a shifter's [bit coder](#bit-coder), the CRC takes absorb, data
and emit from the coder instead of registers 4 and 5; the gates still apply.

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

## Edge cell

**What it is for:** turning a pin's changes into pulses: a clock edge to
shift on, an edge to start or resync a timer, a start condition.

**How it works:** it compares a pin's synchronized level with its value a
cycle earlier and pulses on a rise, a fall or either, optionally only while
a level line is high (or low). An I2C START is "SDA falls while SCL is
high"; a USB receiver's clock recovery wants "any edge of D+". Its pulse is
registered like every other pulse line.

There are 8 edge cells, at configuration `0x80 + e` (line 16 + e). They
keep one configuration (no contexts):

| Field | Meaning |
| --- | --- |
| `[2:0]` | pin |
| `[3]`, `[4]` | pulse on a rise, on a fall |
| `[9:5]` | qualifying level line |
| `[10]` | qualified: only while that level is high |
| `[11]` | ... while it is low instead |

The configuration helper allocates them as a program asks for edges
(`p.rise(pin)`, `p.fall(pin)`, `p.edges(pin, when=line, when_low=True)`),
shares a cell between identical requests and fails a program that needs
more than 8 when it is assembled.

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

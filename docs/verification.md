# Verification

The design is checked in five independent ways. `make verify` runs all of
them.

## 1. Simulation tests (cocotb)

- **58 tests** drive the chip only through its pins and host commands,
  exactly as a real board would.
- **Each protocol test** has its own reference model of the other device,
  written the usual software way, so the chip is compared against
  something it did not produce.
- **They also run on the gate-level netlist** (the chip after synthesis),
  because they never look inside the design.

Details: [test/README.md](../test/README.md).

## 2. Formal checks

A formal tool explores **every possible input sequence** up to a number of
clock cycles, instead of a few chosen ones.

| What | Checked against |
| --- | --- |
| Each tile, the controller, the host link, FIFO, SRAM | A separate model of what that block should do |
| Logic cell with both contexts | Writes to either or both contexts, switching at any time |
| Byte tiles | Escape then unescape returns exactly the original bytes; a corrupted byte is always caught |
| Whole core | No pin is driven before the arm write; no FIFO is ever overfilled or over-read |

Some checks are full proofs (true for any length of time). Others are
checked up to 16–32 cycles.

Details: [formal/README.md](../formal/README.md).

### Protocol proofs

The checks above prove tiles. A protocol proof checks a whole protocol as
the chip will run it. The harness runs the complete core (controller,
every tile, the pin cells) with the program memory holding exactly the
bytes the cocotb test loads. The ROM is regenerated from
`protocols.py` on every run. The FIFOs and input pins are symbolic: any
bytes, arriving at any time, and any input levels. The solver then shows
that no input sequence breaks the protocol:

| Proof | For every input |
| --- | --- |
| `uart_tx` | the pin carries the bytes' 8N1 frames in order, every bit exactly 4 cycles; no frame without a byte; a waiting byte starts within 8 cycles; idle high; once armed, always driven |
| `ws2812` | every high pulse is exactly T0H for a 0 and T1H for a 1, MSB first, in byte order; bits of a byte exactly one bit period apart; no pulse without a byte |
| `spi_master` | (two-byte transactions, 2-cycle half periods, bytes arriving at any times, including bytes for a later transaction, any MISO) SCK rests low and never moves while CS is high; CS falls at least a half period before SCK's first edge; half periods exact within a byte, SCK only pausing between bytes; CS rises only between bytes, after exactly two; MOSI never moves while SCK is high; at every rising edge MOSI is the next bit of the popped bytes, MSB first |
| `gpio_expander` | (a 74HC595 and a 74HC165 modelled at the pins, inputs changing at will) every RCLK rise latches exactly the next popped byte after exactly 8 SRCLK rises; every byte read back is the inputs present when SH/LD# rose; SRCLK never moves while the 165 loads; SER stable at every edge |
| `quadrature_decoder` | (A and B changing at any times at least 2 cycles apart) each step pushes exactly one byte, its direction, in order; each double change one byte on the other channel; nothing else; none later than 8 cycles |
| `vga` | (small timing) HSYNC low exactly SYNC cycles every LINE; every pixel cell of every visible line is the next popped byte's bit, MSB first, exactly CELL cycles; black in the porches, blank lines and before line 0; VSYNC low exactly in its rows; a whole frame and the next frame's first line |
| `vga_framebuffer` | (small timing, any image in SRAM) the same HSYNC, VSYNC and black-porch checks; every pixel cell of every visible line is the matching bit of its row's image byte, each row on two lines, and that byte was read from SRAM; a whole frame and the next frame's first line |
| `hdlc_receive` | (RXC a regular clock, any RXD) every byte pushed is the next byte of an independent reference receiver (destuffing, flags, aborts, bytes LSB first), with *eop* exactly on a frame's last byte and *err* exactly when its FCS check fails |
| `hdlc_transmit` | (any frames, arriving at any time; 300 cycles, so a frame's bytes but not its closing flag) TXC rises every 10 cycles; TXD stable 2 cycles either side of every TXC rise; after the first flag only flags and frames; never six 1s but in a flag; each frame's bits, destuffed, are the next popped frame's bytes, LSB first. The FCS is not reached: the tests check it, including a loopback into the proven receiver |

These are bounded proofs: 60 to 190 cycles after the program arms the
fabric, 640 for `vga_framebuffer` (a whole frame; its cover takes over an
hour, so it runs on Slurm). `hdlc_transmit` is bounded at 300, which takes about 12 hours, so
it runs on a Slurm cluster (`formal/slurm/deep.sh`) rather than in CI; the
end of a frame (about 470) is out of reach. Until arming, the harness supplies no bytes and holds the inputs
constant, so the configuration phase is a single deterministic run.
`prearm.py` simulates it and the solver starts from the armed state, which
spends the whole bound on the protocol. The proofs use small timing
parameters, such as 6-cycle WS2812 bits, to fit more frames into the
bound, and each proof's cover statements show complete frames within it.

The proofs found real bugs the simulation tests had missed:

- **WS2812:** if the FIFO ran dry and the next byte arrived just as a byte
  ended, the transmitter restarted its bit timer at once, so the last
  bit's low time was cut from 4 cycles to 2. A restart now waits a full
  bit period; `test_ws2812_starved_fifo` sweeps the arrival time cycle by
  cycle.
- **SPI master:** the program ended a transaction when the FIFO ran dry
  at a byte boundary, so a byte arriving just as chip select was about to
  rise restarted SCK under it. A transaction now has a byte count, and CS
  stays low through pauses; `test_spi_starved_fifo_pauses_sck` sweeps the
  late byte's arrival.
- **SPI master and GPIO expander:** the controller closed a transaction
  a few cycles after its last byte, so a byte the host had already pushed
  for the next one started inside it (a 595 chain latched 32 bits for 24).
  Found while writing the `gpio_expander` proof, whose host may push ahead;
  the fabric now closes the transaction itself as the last byte starts
  (counter 0 counts them). `test_gpio_expander_host_pushes_ahead` fails on
  the old program.
- **HDLC transmitter:** the controller marked a frame pending before
  copying its first byte. When it was slow, the flag in progress ended
  with no byte to start, and the line idled at 1 inside the frame (seven
  1s, an abort). It now copies first; `test_hdlc_tx_arrival_sweep` moves
  the moment across a whole flag.
- **GPIO expander:** inputs pass a synchronizer, so the fabric samples
  QH about 3 cycles before its SRCLK edge reaches the pin. At a half
  period of 2 the first bit was sampled while the 165s were still loading,
  from a different instant than the others. Readback needs a half period
  of at least 4 (the program checks it); the proof runs at 4.

A proof that passes because it checks too little would be worthless, so
`make -C formal protocol-negative` reruns each proof on a wrong program:
one cycle more per UART or WS2812 bit, a longer SPI half period, two
chained chips for one, the encoder's pins swapped, two VSYNC lines for
one, the receiver checking the plain FCS residue (forgetting the flag
bits its CRC also takes), the transmitter using USB's polynomial. Each
must fail.

## 3. Mutation testing

How do we know the checks would catch a real bug? We plant one.

`formal/mutation_check.py` makes **33 small deliberate bugs** in copies of
the design, for example:

- a parity bit flipped;
- a counter off by one;
- a context write going to the wrong context.

It then confirms the formal checks reject **every** one.

## 4. Timing independence from the controller

The claim "the controller never affects bit timing" is tested directly
(`test_determinism.py`):

1. Run a protocol from reset with the controller **idle** after it arms
   the fabric, and record every pin output on every cycle.
2. Run it again with identical host input at identical cycles, but with
   the controller **busy** on unrelated work (maths, status reads,
   counting loops).
3. The two recordings must match **cycle for cycle**, and so must
   everything received.

This is checked for UART (both directions), burst frames, the fabric
switching its own contexts, and HDLC framing in the byte layer. To show
the check has teeth, one more run uses a controller that *does* interfere
(it keeps rewriting a timer); the comparison must fail, and it does.

Limit: this covers the programs tested, not every possible program. A
formal version would compare two copies of the chip for any program.

## 5. Dead-logic check

`make dead-check` fails if any signal is unused, any input is undriven, or
any flip-flop can never change. It currently finds nothing.

Next: [Limits](limits.md).

## 6. One hop per cycle

`make one-hop-check` (`tools/one_hop_check.py`) proves the timing rule
structurally on the RTL. No signal-space line depends combinationally on
another line, so every path is register, line, selector, tile logic,
register, whatever the program configures. Per tile, the outputs the core
places on the signal space have no combinational path from the tile's line
inputs. In the core, the logic assembling the lines does not read them.
Run on the earlier design with combinational glue cells, it reports
exactly the glue outputs and the lines they drive.

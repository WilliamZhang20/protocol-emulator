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
`protocols.py` on every run. The TX FIFO is symbolic: any bytes, arriving
at any time. The solver then shows that no input sequence breaks the
protocol:

| Proof | For every byte stream |
| --- | --- |
| `uart_tx` | the pin carries the bytes' 8N1 frames in order, every bit exactly 4 cycles; no frame without a byte; a waiting byte starts within 8 cycles; idle high; once armed, always driven |
| `ws2812` | every high pulse is exactly T0H for a 0 and T1H for a 1, MSB first, in byte order; bits of a byte exactly one bit period apart; no pulse without a byte |
| `spi_master` | (two-byte transactions with the bytes arriving at any times, any MISO) SCK rests low and never moves while CS is high; CS falls at least a half period before SCK's first edge; half periods exact within a byte, SCK only pausing between bytes; CS rises only between bytes; MOSI never moves while SCK is high; at every rising edge MOSI is the next bit of the popped bytes, MSB first |

These are bounded proofs: 110 to 130 cycles after the program arms the
fabric. Until arming, the harness supplies no bytes and holds the inputs
constant, so the configuration phase is a single deterministic run.
`prearm.py` simulates it and the solver starts from the armed state, which
spends the whole bound on the protocol. Each bound covers at least two
complete frames, and each proof's cover statements show such traces. The
proofs use small timing parameters, such as 6-cycle WS2812 bits, to fit
more frames into the bound. That covers the program loading its configuration and then at
least one complete frame with more bytes queued (each proof's cover
statement shows such a trace).

The `ws2812` proof found a real bug the simulation tests had missed. If
the FIFO ran dry and the next byte arrived just as a byte ended, the
transmitter restarted its bit timer at once, so the last bit's low time
was cut from 4 cycles to 2. The tests always kept the FIFO full, so they
never hit that window. The fix: a restart waits a full bit period. Now
`test_ws2812_starved_fifo` sweeps the arrival time cycle by cycle. It
fails on the old program and passes on the fixed one.

The `spi_master` proof found a second one. The program ended a
transaction when the FIFO ran dry at a byte boundary. A byte arriving
just as chip select was about to rise restarted SCK under it, so CS rose
in the middle of a byte. Real SPI masters pause SCK on an underrun, so
the program now does the same. A transaction has a byte count, and CS
stays low through pauses. `test_spi_starved_fifo_pauses_sck` sweeps the
late byte's arrival cycle by cycle.

A proof that passes because it checks too little would be worthless, so
`make -C formal protocol-negative` reruns each proof on a program that
differs only in its timing (one cycle more per UART bit or WS2812 bit, a
longer SPI half period). Each must fail.

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

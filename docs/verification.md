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
| Glue cell with both contexts | Writes to either or both contexts, switching at any time |
| Byte tiles | Escape then unescape returns exactly the original bytes; a corrupted byte is always caught |
| Whole core | No pin is driven before the arm write; no FIFO is ever overfilled or over-read |

Some checks are full proofs (true for any length of time). Others are
checked up to 16–32 cycles.

Details: [formal/README.md](../formal/README.md).

## 3. Mutation testing

How do we know the checks would catch a real bug? We plant one.

`formal/mutation_check.py` makes **30 small deliberate bugs** in copies of
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

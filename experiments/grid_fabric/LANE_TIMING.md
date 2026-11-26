# Lane controller timing

Measured at the pins by `test/cocotb_tests/test_lane_timing.py`, which
asserts these numbers so a timing change fails the regression. Clocks are
the chip clock (50 MHz in the compiled designs).

## Program load (fetch occupancy)

| Program | Start strobe to done |
|---|---|
| 1 instruction | 9 clocks |
| 8 | 30 |
| 32 | 102 |
| 64 | 198 |

**Start to done = 6 + 3n clocks** for n instructions that each retire in
one clock: 6 clocks of host-strobe synchronization and start, 2n clocks
to load (two bytes per instruction, one byte per clock, pipelined on
memory client 0), n clocks to run. The load occupies client 0 for 2n
consecutive clocks and nothing else: after it the program runs from the
local buffer and never fetches. A 64-instruction program is ready 2.6 us
after start. Under a host read storm the 64-instruction case is still 198
clocks: the lane owns the port while loading, and the host waits.

## Decision time (input edge to pad)

| Decision path | Edge to pad |
|---|---|
| `WAIT` pulse event; `ACT` | 5 clocks |
| `WAIT` level; `ACT` | 5 |
| `WANY`; `AND`; `JNZ`; `ACT` | 7 |
| I2C STOP check: `WANY`; `AND`; `JNZ`; `RD`; `AND`; `JZ`; `ACT` | 10 |

**Edge to pad = 5 + k clocks**, k the instructions between the wait and
the `ACT`: two synchronizer flops, the lane core's input register (every
core line is a register output, so no selection can close a loop; this
clock was added with the lane core, step 2.4b), the wait retiring on the
clock it sees its condition, and the `ACT` register driving the pad
directly (lane mode drives the pins from the core). There is no fetch
and no stall, so this is also the worst case; the only variable is which
path the program takes, which the compiler knows.

## What it means for the designs

Derived from the measured model above (the per-design gaps are not
measured separately).


- **I2C target**: the ACK is driven about 5 clocks after SCL falls
  following the eighth bit (the program waits on the SCL fall event, then
  `ACT`). At
  400 kHz SCL is low for at least 1.3 us = 65 clocks, so the response lands
  in the first 6% of the window. STOP is decided 10 clocks after SDA rises;
  SCL stays high at least 0.6 us = 30 clocks.
- **SPI target**: between the eighth SCLK rise and the next reply's first
  bit the program runs `RD`, `PUSH`, `RD`, `JNZ`, `PULL`, `SHIFT` and the
  coded shifter starts on the shift line the clock after: about 5 + 6 + 2
  = 13 clocks. The controller must leave that long before the next byte's
  first rise; the pin tests use at least 24.
- **SLIP UART TX**: bits are timed by the core's timer0 and coded shifter,
  which also adds the start and stop bits. Between frames the plain-byte
  path runs 11 instructions after the stop event (`J`, `RD`, `JZ`, `PULL`,
  `ATOC`, `XOR`, `JZ`, `XOR`, `JZ`, `CTOA`, `SHIFT`), so frames are
  separated by about 13 idle (high) clocks after each stop bit, which UART
  permits; a gapless stream uses the coded shifter's auto pull instead
  (no controller work per byte).
- Contention never moves these numbers (`test_lane_determinism.py`):
  arbitration is round-robin per bank (a stream request waits at most two
  clocks) and each `PULL` takes a byte prefetched a frame earlier.

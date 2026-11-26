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
| `WAIT` pulse event; `ACT` | 4 clocks |
| `WAIT` level; `ACT` | 4 |
| `WANY`; `AND`; `JNZ`; `ACT` | 6 |
| I2C STOP check: `WANY`; `AND`; `JNZ`; `RD`; `AND`; `JZ`; `ACT` | 9 |

**Edge to pad = 4 + k clocks**, k the instructions between the wait and
the `ACT`: two synchronizer flops, the wait retiring on the clock it sees
its condition (pulse events and levels both come from the synchronized
pin), and the `ACT` register driving the routed pad. There is no fetch
and no stall, so this is also the worst case; the only variable is which
path the program takes, which the compiler knows.

## What it means for the designs

Derived from the measured model above (the per-design gaps are not
measured separately).


- **I2C target**: the ACK is driven 4 clocks after SCL falls following the
  eighth bit (the program waits on the SCL-low level, then `ACT`). At
  400 kHz SCL is low for at least 1.3 us = 65 clocks, so the response lands
  in the first 6% of the window. STOP is decided 9 clocks after SDA rises;
  SCL stays high at least 0.6 us = 30 clocks.
- **SPI target**: between the eighth SCLK rise and the next reply's first
  bit the program runs `RD`, `PUSH`, `RD`, `JNZ`, `PULL`, `SHIFT` and the
  shifter starts the clock after `SHIFT`: about 4 + 6 + 2 = 12 clocks. The
  controller must leave that long before the next byte's first rise; the
  pin tests use at least 24.
- **SLIP UART TX**: bits are timed by timer0 and shifter0. Between frames
  the plain-byte path runs 13 instructions after the done event (`J`,
  `RD`, `JZ`, `PULL`, `ATOC`, `XOR`, `JZ`, `XOR`, `JZ`, `CTOA`, `SHL`,
  `ADD`, `SHIFT`), so frames are separated by about 15 idle (high) clocks
  after each stop bit, which UART permits; a back-to-back stream would
  need the next frame loaded before the stop bit ends.
- Contention never moves these numbers (`test_lane_determinism.py`):
  arbitration is round-robin per bank (a stream request waits at most two
  clocks) and each `PULL` takes a byte prefetched a frame earlier.

# Signal space

## What it is

Every tile output is put on one of **64 shared wires**, called *lines*.
Every tile input picks one line by its number. Connecting two tiles is just
writing a number into a configuration register.

For example, to make shifter 0 move to its next bit on timer 0's ticks, set
shifter 0's "shift line" register to 4 (timer 0's rise line).

## The lines

| Line | Signal |
| --- | --- |
| 0, 1 | constant 0, constant 1 |
| 2, 3 | controller `FIRE 0` / `FIRE 1` (a one-cycle pulse when the program asks) |
| 4 + 2k, 5 + 2k | timer k rise, fall |
| 12 + 2k, 13 + 2k | shifter k *word* (a word just finished), *stop* (went idle) |
| 16 + p, 24 + p | pin p rise, fall |
| 32 + p | pin p level |
| 40 + k | timer k output |
| 44 + k, 46 + k | shifter k output, shifter k active |
| 48 + k, 50 + k | counter k at or above threshold, counter k just reached it |
| 52, 53 | CRC output bit, CRC matches its check value |
| 54, 55 | controller flags 0, 1 (levels the program sets) |
| 56 + k | glue cell k output |

(k is the tile number, p the pin number.)

## Two kinds of lines

- **Pulses** (lines 2–31) are high for exactly one cycle when something
  happens: a tick, a word ending, a pin edge.
- **Levels** (lines 32–63) stay high or low: a pin's value, a timer's
  output, "shifter is busy".

Some inputs only ever need one kind, so they can only select that kind
(this saves area). The configuration helper handles this for you.

## Timing rules

These are fixed, so programs can rely on them:

- A **pulse** costs one cycle to reach its user.
- **Pin outputs** are registered: one cycle of delay, no glitches.
- **Pin inputs** pass a two-stage synchronizer (two cycles of delay), so
  outside signals can change at any time safely.

Programs account for these delays in their timer settings. The result is
exact and repeatable: for example, every 10BASE-T half bit is exactly 2
cycles.

## Safety by construction

- **No loops.** Glue cells only see each other's *registered* outputs. No
  configuration can create a combinational loop, and no path passes
  through more than one glue cell. This also keeps the worst timing path
  short.
- **Arm before acting.** Tiles and pins stay idle until the program writes
  the *arm* bit (configuration address `0x31`). A half-written
  configuration can never drive a pin.

Next: [Tiles](tiles.md).

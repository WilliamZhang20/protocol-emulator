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
| 16 + e | edge cell e: a pin edge the program chose (rise, fall or both, optionally only while a level is high or low) |
| 24 + k | counter k just reached its threshold |
| 26–31 | spare (read 0) |
| 32 + p | pin p level |
| 40 + k | timer k output |
| 44 + k, 46 + k | shifter k output, shifter k active |
| 48 + k | counter k at or above threshold |
| 50, 51 | CRC 1 output bit, CRC 1 matches its check value |
| 52, 53 | CRC 0 output bit, CRC 0 matches its check value |
| 54, 55 | controller flags 0, 1 (levels the program sets) |
| 56 + k | logic cell k output |

(k is the tile number, p the pin number.)

Pin edges used to have 16 fixed lines (every pin's rise and fall), but no
program used more than 5 of them. Eight edge cells take 8 lines instead and
each can be any pin, either or both directions, and qualified by a level:
an I2C START ("SDA falls while SCL is high") is one edge cell rather than a
logic cell. The configuration helper allocates them (`p.rise(pin)`,
`p.fall(pin)`, `p.edges(pin, when=line)`), sharing identical requests, and
refuses a program that needs more than 8.

## Two kinds of lines

- **Pulses** (lines 2–25) are high for exactly one cycle when something
  happens: a tick, a word ending, a pin edge.
- **Levels** (lines 32–63) stay high or low: a pin's value, a timer's
  output, "shifter is busy".

Some inputs only ever need one kind, so they can only select that kind
(this saves area). The configuration helper handles this for you.

## Timing rules

These are fixed, so programs can rely on them:

- A **pulse** costs one cycle to reach its user.
- A **logic cell** costs one cycle: its output is its flip-flop.
- **Pin outputs** are registered: one cycle of delay, no glitches.
- **Pin inputs** pass a two-stage synchronizer (two cycles of delay), so
  outside signals can change at any time safely.

Programs account for these delays in their timer settings. The result is
exact and repeatable: for example, every 10BASE-T half bit is exactly 2
cycles.

## Safety by construction

- **One hop per cycle.** Every line is a register output: tiles, pins,
  pulses and logic cells alike. No configuration can create a
  combinational loop, and every path is register, line, selector, tile
  logic, register. Timing closes for any configuration, not just the
  ones we tested.
- **Arm before acting.** Tiles and pins stay idle until the program writes
  the *arm* bit (configuration address `0x31`). A half-written
  configuration can never drive a pin.

Next: [Tiles](tiles.md).

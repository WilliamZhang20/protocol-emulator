# 8×4 architecture review

## Routed timing baseline

The completed [50 MHz GDS run for `97af92c`](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/43270161978)
reports +5.636 ns worst setup slack at `nom_slow_1p08V_125C` after routing,
with zero setup violations. This is the baseline for any timing edit. The
worst register path starts at shifter 0's `out_r` (shown as
`core.counter[0].tile.lines[44]` after netlist flattening) and ends at
`shifter0.skip_left[4]`. The netlist mapping confirms the endpoint. The
route traverses the shared line-44 fanout tree, the shifter's level selector,
bit-coder control and the `skip_left` update. The path report shows about
5.5 ns from the launch flop Q to the level-selector input, so routing and
fanout consume a substantial part of its budget.

The active context registers keep context selection off this path. The
registered CFG write bus keeps SRAM output off tile decode paths. Changes to
either mechanism need a routed timing comparison, not just an RTL estimate.
The local context-bank cleanup expresses writes and swaps as separate
register updates while preserving `next` for tiles that precompute. The
arbitrary-context logic-cell proof and timer and shifter formal checks pass;
a new routed result is still needed before assigning any slack change to
this edit.

## Resource and latency observations

- PX8 instructions take two clocks in the usual case; a CFG table loads one
  word every three clocks. These are setup or transaction costs. Bit timing
  runs in tiles after arming.
- Signal-space pulses, logic cells and registered pin outputs each add a
  clock where used. Pin inputs also cross a two-flop synchronizer. Protocols
  with short turnarounds need the direct edge cells and shifter coder links.
- The shifter bit coder supports stuffing, NRZI, Manchester transmit and CRC
  tail. The original Spatial Ethernet example fills all eight logic cells
  and both counters. The local compiler branch now exposes the coder and
  compiles a coded Ethernet variant using three logic cells, no counters and
  363 SRAM bytes, compared with eight logic cells, two counters and 433 bytes
  in the original. The accelerated RTL peer test passes frame timing,
  Manchester symbols, FCS, TP_IDL and repeated sessions at 40 MHz.
- The byte tiles accept one byte every two clocks. The fastest documented
  serial byte here takes 32 clocks, so this is not currently the serial
  throughput limit.

The cell setup is regular for bit timing: numbered timers, shifters,
counters, CRCs, logic and edge cells all use the same 64-line space, and
two contexts let a phase change switch their configuration together.
Flexibility still has specific bounds: four timers, two shifters, two CRCs,
eight logic and edge cells, and two contexts. Logic cells accept at most two
pulse inputs. The RTL edge cell can qualify a pin edge by another level,
but Spatial currently exposes only plain `.rise` and `.fall`; logic-cell
context overrides and Manchester receive are also unavailable. These are
compiler or hardware capabilities to decide explicitly for each new
protocol, rather than assuming any protocol fits automatically.

## Cycle occupancy from compiled examples

An RTL-only probe sampled the PX8 state and shifter-active lines each clock
after engine start. The figures below are for one named test per protocol;
initial configuration and test transactions are included. Event-wait and
shifter-active cycles overlap: the controller commonly waits while the
fabric is doing useful wire work.

| Compiled example | Sampled cycles | Shifter active | Event wait | FIFO wait |
| --- | ---: | ---: | ---: | ---: |
| UART loopback | 1,978 | 1,911 (96.6%) | 0 | 0 |
| SPI device exchange | 604 | 386 (63.9%) | 372 | 31 |
| I²C register read | 25,536 | 24,967 (97.8%) | 24,977 | 12 |
| Coded Ethernet, one session, accelerated link gaps | 123,104 | 2,304 (1.9%) | 120,872 | 1,104 |

The Ethernet result includes three intentional link pulses 40,960 clocks
apart; the shipped version spaces them 640,000 clocks apart. Its long idle
time is therefore protocol cadence. The shifter is busy for exactly 2,304
clocks, the 72 on-wire bytes including FCS at four clocks per bit. During
that frame, the controller spends about 1,100 clocks stalled by TX FIFO
backpressure; it can feed the line without a gap. SPI's lower active share
includes initial setup and pauses between its tested transactions. These
small examples do not establish a universal protocol average, but they
identify where reducing controller latency would affect the wire and where
it would only remove deliberate wait time.

Any proposed RTL timing rewrite should rerun the routed flow and compare
slow-corner path and slack against the baseline above.

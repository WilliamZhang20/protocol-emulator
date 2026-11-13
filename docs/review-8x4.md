# 8×4 architecture review

## Routed timing baseline

The completed [50 MHz GDS run for `97af92c`](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/43270161978)
reports +5.636 ns worst setup slack at `nom_slow_1p08V_125C` after routing,
with zero setup violations. The
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
The context-bank cleanup expresses writes and swaps as separate register
updates while preserving `next` for tiles that precompute. The
[routed `4aa9c34` run](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/43379353470)
reports +5.770 ns at the same slow corner, a +0.134 ns change; gate-level
tests and precheck pass. Its worst path starts at logic cell 3's output
(line 59) and ends at `shifter1.skip_left[3]`. The changed path and small
margin do not establish a general speedup from the context-bank rewrite.

A subsequent shifter cleanup separates the CRC frame-bit event from coder
state updates. Shifter-only generic synthesis uses 1,793 cells versus 1,800
before it, and Yosys's longest shifter logic path falls from 39 to 36 steps.
Those are pre-route proxies; its routed slack has not been measured. A further
skip-count rewrite computes initial and live decrements separately. With
`synth -flatten; ltp -noff`, the longest shifter path endpoint moves
from `skip_left` to `run_len` while its length stays 34 logic steps. Its routed
slack also remains to be measured.

A one-bit-per-clock black-box test found a CRC-tail error in the registered
shifter-to-CRC link: with byte `0x01` and CRC-8 polynomial `0x07`, the pin sent
`00000011` instead of `00000111`. The CRC tile now provides the shifter with
the tail bit it will have after this cycle's pending absorb or emit. Its CRC
state update remains registered. Both CRC/shifter pairs pass the new test,
and a formal reference model checks that predicted bit. In matched full-core
generic synthesis, the longest path changes from 46 to 45 logic steps while
the cell count rises from 29,220 to 29,680. These figures are not routed
timing or area results; the new build still needs a slow-corner route.

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
  in the original. Both accelerated and real-time RTL peer tests pass frame
  timing, Manchester symbols, FCS, TP_IDL and repeated sessions at 40 MHz.
- The byte tiles accept one byte every two clocks. The fastest documented
  serial byte here takes 32 clocks, so this is not currently the serial
  throughput limit.

The cell setup is regular for bit timing: numbered timers, shifters,
counters, CRCs, logic and edge cells all use the same 64-line space, and
two contexts let a phase change switch their configuration together.
Flexibility still has specific bounds: four timers, two shifters, two CRCs,
eight logic and edge cells, and two contexts. Logic cells accept at most two
pulse inputs. The RTL edge cell can qualify a pin edge by another level,
but Spatial currently exposes only plain `.rise` and `.fall`; Manchester
receive is also unavailable. The local 8×4 compiler branch supports
logic-cell context overrides, reusing the cell and inheriting its update
settings. Each new protocol still needs a resource and timing check.

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
| USB data packet | 3,152 | 2,247 (71.3%) | 2,841 | 22 |
| JTAG IDCODE scan | 3,344 | 1,406 (42.0%) | 1,421 | 674 |
| SWD register exchange | 13,920 | 9,614 (69.1%) | 9,653 | 1,691 |
| PS/2 keyboard receive | 138,032 | 138,005 (100.0%) | 0 | 0 |
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

Across the seven examples other than Ethernet, the unweighted mean of each
example's shifter-active share is 77.2%; the range is 42.0% to 100.0%.
The remaining clocks are not all idle fabric clocks: they include host setup,
controller work and other tiles. JTAG's single-bit `step` calls and SWD's
turnaround chunks account for much of their transaction overhead; both pause
the clock between calls by design. PS/2 reception stays active while its
external keyboard sends bits. An architecture change aimed at generic
controller throughput should first show that the wire is starved during a
frame, rather than counting protocol gaps as lost cycles.

Any proposed RTL timing rewrite should rerun the routed flow and compare
slow-corner path and slack against both measured runs above.

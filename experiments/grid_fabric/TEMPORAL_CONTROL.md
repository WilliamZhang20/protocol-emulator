# Programmable temporal-control experiment

This was the stage 4 experiment on the original 3×3 grid (now rows 0–2 of the
5×3 grid); it is not a final area or protocol-coverage decision. Stage 5 added
routed event inputs (sinks 41/42, word 184); see
[PROTOCOL_COVERAGE.md](PROTOCOL_COVERAGE.md). The generic sequencer has 16 configurable rows of
16 bits, eight selectable event inputs and four action outputs. Each row selects
an event, a true/false successor and a halt flag. The table is one page of the
program. Without paging it is loaded from configuration and there is no
runtime memory access. Unwritten state transitions, frame errors and
overlapping frame requests fail closed. Its configuration words and event
assignments are in [the hardware contract](../../architecture/grid_3x3.json).

## Descriptor rows

A plain row does one thing per state: set actions and branch on one event.
The compiled programs spend many rows on two patterns, a wait that runs
straight into another wait on the same event (waveform phases), and a
one-clock pulse followed by a hold-until-event (a frame request held until
`frame_done`, which is how the stream engine runs a whole field). Descriptor
rows encode each pattern in one row and fall through to the next row, as a
descriptor list does. They use the encodings that were reserved under page
rows (`{1,1,mode,...}`, mode nonzero):

| Mode | Row | Behaviour |
|---|---|---|
| 01 phases | `{1,1,01,a0[3:0],a1[3:0],event[2:0],0}` | drive a0 until the event, then a1 until the event, then the next row |
| 10 entry-wait | `{1,1,10,pulse[3:0],hold[3:0],event[2:0],0}` | drive pulse for one clock, then hold until the event, then the next row |

Each is cycle-for-cycle equal to the two plain rows it replaces, so a
program can be folded after lowering without changing its timing
(`test/cocotb_tests/descriptor_fold.py`). Folding the programs in the tree:
temporal I2C 14 live rows to 12, compiled I2C write-read 15 to 13, SPI 7
to 5. `sequencer_tb` runs each legacy program beside its folded form on
random events and requires identical actions, halts, done and error on
every clock; `test_temporal_i2c.programmed_i2c_write_descriptors` runs the
folded I2C transaction at the pins in exactly the same time as the plain
one. Mode 11, bit 0 set, and falling through row 15 or into an unwritten
row halt with error. Both lanes share `grid_sequencer`, so both accept
descriptors. Cost: about 1.3k um2 for both lanes (one phase flop each and
the action mux).

A count field ("wait for N events") was considered and left out: no program
in the tree waits on a repeated event, because timers and the stream
engine's byte count already absorb counting.

## Lane B: a second sequencer in the fabric

Lane A is the sequencer in cell 6 that drives the frame, packet and coded
engines. Lane B is a second 16-row sequencer placed in cell 13, among the
timers and LUT cells it drives, and runs beside lane A from the same host
start. It is fabric-native: its events are timer 2/3 ticks, three routed
sinks (43-45, selectors at words 185-187) and "lane A running"; its four
actions are source bits 3:2 of LUT cells 12 and 14, routed through the mesh
like any other cell output. Cell 11 exposes "lane B active" so lane A can
route it into its own event sinks 41-42.

Rows are words 192-207 (lane A's row encoding, no page rows). Word 188 is
`{reserved[15:10]=0, clear[9], enable[8], idle_actions[7:4], entry[3:0]}`.
The host sees one transfer: done waits until both lanes have finished, and
either lane's error is reported and held until the next start. Lane A
failing aborts lane B; lane B halting with error aborts a temporal lane A.

The first use is a bus watchdog (`test_temporal_i2c.i2c_bus_hang_watchdog`):
lane B starts timer 3 through the fabric, then loops between "lane A
running?" and "timer 3 level?". A target that holds SCL low forever is cut
off after the programmed time with an error, and both pins are released.
A single sequencer cannot do this because it is busy waiting on the stretch.

## Lane controller mode

Configuration word 91 bit 2 replaces the row sequencer with a lane core
(`src/grid_lane_core.v`, step 2.4; bits 0 and 2 together are invalid): the
lane controller (`src/grid_lane_controller.v`) with its own two timers,
coded shifter and CRC, wired through the core's local lines and configured
on page 1 (host addresses 256-319, lane 0; see
experiments/grid_fabric/LANE_CORE.md and the contract's `lane_core`
section). Core word 36 is `{last[5:0], base[9:0]}`: the program is
`last + 1` 16-bit instructions, little-endian, at host-bank byte `base`.
Start copies it into the controller's local buffer over memory client 0;
then the lane pulls and pushes bytes through the stream reader and writer
(words 66/67 lengths, 89/90 bases, as in frame mode), drives the three
pins from the core's output selectors, and may write its timers' first
and period while armed (WCFG, to the timer's shadow). Lane B still runs
beside it.

The controller's eight events and eight levels are selectors over the
core's lines (`event0`..`event7`, `level0`..`level7`); the compiler
allocates them from the program's `event:<line>` and `level:<line>`
operands. Readback slots: 0 coder rx word, 1 coder status, 2/3 timer 0/1
capture, 4/5 CRC value, 6 inputs, 7 stream bytes left, 8 bytes written,
9 stream status.

Levels are numbered 8-15 in `WAIT`; `WANY m` waits for any pulse event in
the mask `m` and leaves the ones that fired in A.

Each lane run is one transfer. It finishes when the controller halts and
the bytes it pushed are in SRAM; then the reader and writer close, so the
next start begins both at their bases. A `PUSH` once the destination's
capacity is used, or a `PULL` with no source bytes left, fails the
transfer rather than waiting forever. With bit 6 of its configuration
word set (word 2 or 55), a shifter start while the shifter is busy
abandons the current word and starts again, so a receiver can
resynchronize on a framing event (an I2C STOP right after the next byte
was armed); with it clear a start while busy is ignored, which receivers
started by every input edge (the UART images) rely on.

`test/data/lane/i2c-target.*` is an I2C target compiled from the
compiler's `circt_lab/lanes/i2c_target.json`: shifter0 samples SDA on
SCL rises, the lane detects START/STOP, matches address 0x48, ACKs in
the window after the eighth bit and streams bytes to SRAM; transfers to
other addresses get no ACK and are skipped. `test_lane_i2c_target.py`
plays an I2C controller on an open-drain bus at the pins. `spi-target.*` (mode 0, no
chip select) and `slip-uart-tx.*` (SLIP framing on an 8N1 transmitter) are
built the same way and tested at the pins by `test_lane_spi_target.py` and
`test_lane_slip_tx.py`.

A live write is checked by grid_core
against the rules static configuration is checked against (the word is
valid and no other override names its sink); a refused write fails the
transfer, so the armed configuration never leaves the validity it was
armed with. `test/cocotb_tests/lane_asm.py` assembles programs;
`test_lane_controller.py` exercises the mode at the pins.

## Paged programs

Every protocol program fit in 16 rows until `i2c-write-read` filled all 16
(Ethernet session and temporal I²C use 15). Word 94 bit 15 enables paging:
the program and its alternate contexts then live in the host SRAM bank as up
to 16 pages at `base + 64*page` (base in word 94 bits 9:0). Each page is 16
rows followed by the 5 context words, little-endian (42 bytes). Start loads
page 0. A halt row with bit 14 set is a page row,
`{1,1,00,page[3:0],entry[3:0],action[3:0]}`: it holds its action while the
page loads and then continues at `entry`. All existing halt rows have bit 14
clear, so unpaged images are unchanged.

Rows always execute from the register table, so timing inside a page is exact
and never waits on memory; only a page change takes time (42 reads, about 45
clocks plus any wait for the host port, which the loader borrows). The
compiler should therefore place page rows where a phase can stretch, such as
before a STOP. The five contexts commit together after the last byte, so
validity checks never see a partly loaded set, and each page can carry its
own five contexts. A page row without paging, or with bits 13:12 set, halts
with an error.

`make grid-sequencer-test` loads two pages from a modelled SRAM with random
port stalls, checks held actions, contexts, return to page 0 and cancel on
abort. The pin-level `programmed_i2c_write_paged` test runs the I²C
transaction with its STOP sequence on page 1, through clock stretch and both
NACK cases. The compiler pages programs longer than 16 rows itself (sibling
repo `circt_lab/grid_pager.py`), cutting only in front of rows its lowering
marks as safe to stretch; `test/data/compiled/i2c-write-read-paged` is
`write_read` forced onto two pages, and `test_compiled.py` replays the I²C
source's own tests on it at the pins. Pages occupy the top of the host bank
(bytes 896–1023 for two pages), which such programs must leave free.

Five independently programmed sparse context overrides can redirect any five
eligible tile-input selectors between two runtime contexts; the four tracks
and the remaining routes stay shared. This is more flexible than a fixed I²C
controller, but it is **not** arbitrary full-fabric context switching. Actions
are also exposed to the fabric and can trigger a generic SRAM-backed frame.
The existing stream scheduler remains available in legacy mode.

## Source and validation

The sibling compiler's `circt_lab/compile_i2c_write.sh` uses the Rust frontend,
a restricted CIRCT source-profile lowering, the CIRCT grid router and the
shared architecture contract. It specializes the source's `write_only`
function for a seven-bit address and payload, producing a configuration image
and the bytes to preload in SRAM. It handles address, data, ACK/NACK, clock
stretch, START and STOP for this profile. It explicitly rejects changed source
semantics it cannot handle. Reads, repeated starts, general function lowering,
runtime-variable arguments and a general temporal scheduler are not supported.
The source profile and mapping are a bounded first compiler, not evidence that
arbitrary protocol source can map to this fabric.

The checked-in image `test/data/temporal-i2c.mem` is generated from
`examples/i2c.spt`, address 0x48, payload 0xa6; the compiler test checks it is
reproducible. The pin-only cocotb test runs a target model, checks both bytes,
ACK and first/second-byte NACK, a 600-cycle stretch, STOP, received SRAM data,
and a minimum SCL low period. It also passed for address 0x50/payload 0x3c.
A generic flattened Yosys netlist passed the same pin test; this is not a
standard-cell, post-layout or pad-timing simulation. The existing compiler-routed
SPI and concurrent UART grid test passes in legacy mode.

At 50 MHz and HALF=250 cycles the minimum observed SCL low period was 5,000 ns.
From the final ACK sampling edge to STOP the simulation measured 15,320–15,340 ns
for the tested cases. Stretch was injected for 600 cycles (12 µs). These are
specific RTL simulation measurements, not worst-case timing guarantees.

## Area and physical status

Like-for-like flattened SG13G2 standard-cell synthesis with two SRAM macros
black-boxed (same library/tool setup as `../grid_stream/BASELINE.md`):

| Design | Cell area |
| --- | ---: |
| Baseline `4feed15` | 151,322.36 µm² |
| Temporal experiment | 198,308.78 µm² |
| Change | +46,986.42 µm² (+31.05%) |

The sequencer synthesized alone to 23,606.97 µm²; that isolated number is not
an additive partition of the top-level result. The rest of the increase includes
context selection, controls, and integration after cross-module optimization.
These estimates exclude both SRAM macros, placement/routing, PDN and margin.
They do not prove that the design fits or meets timing. The increase is large
enough that an area/physical feasibility decision and potentially a cheaper
context/sequencer design are needed before treating this as the final fabric.

Reproduce the area comparison with `tools/compare_grid_area.py` and the SG13G2
liberty; run `make grid-contract-check grid-sequencer-test grid-fabric-experiment`
and the standard cocotb regression. The sibling compiler provides
`circt_lab/test_i2c_temporal.sh CIRCT_MAP` for source/profile and routing tests.

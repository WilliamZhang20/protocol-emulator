# Structured 5 × 3 grid experiment

The experimental Tiny Tapeout top instantiates this grid, not the older
shared-selector fabric. It has no instruction fetch. Configuration is static
while armed; the grid is an architecture experiment, not a final floorplan or a
complete protocol compiler.

The machine-readable [grid contract](../../architecture/grid_5x3.json) (the file
name predates the two extension rows; it describes the 5 × 3 grid) records
the current tile inventory, coordinates, ports, routing, memory, configuration,
and programmable temporal sequencer. `make grid-contract-check` compares elaborated
RTL instances and neighbor links against it and proves all switch selector
combinations with Yosys SAT. This check does not yet prove every configuration
word, tile behavior, SRAM arbitration rule, or physical timing against the
contract; the functional and synthesis regressions cover additional behavior.

```text
              col 0          col 1            col 2
row 0       [input IO] ---- [output IO] ---- [timer 0]
                |                |                |
row 1       [shift 0] ----- [2-input LUT] --- [timer 1]
                |                |                |
row 2       [SRAM 0 + temporal control] -- [shift 1] -- [SRAM 1 + CRC + coded shift]
                |                |                |
row 3       [LUT4 reg 0] ------ [timer 2] ------ [LUT4 reg 1]
                |                |                |
row 4       [LUT4 reg 2] ------ [timer 3] ------ [LUT4 reg 3]
```

Rows 3–4 extend the grid by a repeating column pattern (registered logic in
columns 0 and 2, timers in column 1) using the same switch, track and
tile-input-selector structure as every other cell. A LUT4 cell drives only its
flop output (and its complement), so routed feedback cannot form a
combinational loop; a cell may read its own output. The sequencer's events 3
and 4 can be replaced by two routed inputs in its own cell (6). The grid is
physically placed by the flow, not by these logical coordinates.

Each line represents **four independent one-bit tracks in each direction**.
Every directed outgoing track has a configuration mux: it may originate at
one of that cell's local signals or continue from a neighbor on the same
track. Tracks 0–1 route horizontally then vertically; tracks 2–3 route vertically
then horizontally. There are no U-turns or track changes. Tile input
selectors choose local signals, constants or the four incoming tracks of any
neighbor. The combinational LUT's inputs accept constants or neighbor tracks, but
not its own local output; together with the turn restrictions this prevents
combinational feedback through the programmable network. Synthesis checks for combinational loops. These restrictions make the
RTL's route graph concrete and finite; they do not establish that the graph can
fit every useful placement or protocol. Signals can share a route only when
identical. Registered timers and shifters break protocol feedback loops.

The two row-2 corner cells (cells 6 and 8) each instantiate a separate single-port 1024×8
IHP SRAM macro with local host/actor arbitration. The actor word bus follows
dedicated point-to-point links from shift 0 down and across row 2;
static configuration chooses either bank. These word links and the host access
bus are **not** a general configurable data mesh, and the SRAM macros are not
physically distributed throughout the full floorplan. SPI and UART reuse the
same credit-based stream reader and writer. Each has a two-byte FIFO;
the bank arbitrates host, reader and writer independently. The shifter frame
packer is configured by format words and consumes the same reader stream for
SPI, UART and the JTAG component. Only the restricted source profiles listed in
[PROTOCOL_COVERAGE.md](PROTOCOL_COVERAGE.md) are lowered; arbitrary `.spt`
functions are not.

## Image contract

The sibling CIRCT mapper's `--compile-grid-spi` and `--compile-grid-uart`
accept restricted, source-validated examples and allocate one of four tracks
per signal using either legal turn class with conflict checks and backtracking.
`--lower-temporal-function` compiles the whole exported SPI `transfer()`, I²C
`write_read()` and Ethernet `transmit()` bodies into sequencer rows and
extension-cell configuration. Tile placement is currently fixed; this is not a
general placer, general source lowering or proof of timing. The original component images use words 0–65; extended compiler images write
all 185 words (0–184):

* 0–4: timer 0 first/period, shift 0 width/order, LUT truth table, pin enables,
  open-drain mask, input-event polarities and CRC enable (word 4 bit 8).
* 5–40: four 12-bit switch words per row-major cell, ordered north, south,
  west, east. Each word contains four 3-bit per-track selectors. For each
  track, selector 0 is zero, 1–4 local outputs, 5 straight incoming, and
  6/7 west/east incoming for vertical turns on tracks 0–1 or north/south incoming for horizontal turns on tracks 2–3.
* 41–52: timer 0, shift 0, output IO and LUT input selectors. Values 0/1 are
  constants; 2–5 are local signals; 6–9 north, 10–13 south, 14–17 west and
  18–21 east incoming tracks. LUT inputs permit constants or neighbor inputs, excluding local output.
* 53–55: timer 1 first/period and shift 1 width/order.
* 56–62: timer 1 and shift 1 input selectors, using the same encoding.
* 63–65: frame format, OR mask and autonomous-RX enable (word 65 bit 0).
  There is no SPI/UART memory mode. Word 63 bit 13 enables a second loaded shift
  lane; bit 14 selects two bytes for it instead of one. Its bytes immediately
  follow lane 0's bytes in the selected SRAM bank. The scheduler checks ranges
  and waits for both lanes. A frame can be repeated across a longer TX stream.
* 69–76: optional CRC tile registers, reusing the legacy configurable 1–32 bit
  `fabric_crc` contract. The coded shifter has a direct registered CRC link.
  Words 77–80 select its absorb, emit, reset and data inputs from the SRAM 1
  cell's local or neighboring signals. In the CRC's internal 64-line inputs,
  these are lines 0, 1, 2 and 32 respectively. When enabled, all 12 words
  must be written and routes must be valid. Direct-link bit 6 selects the
  coded shifter; bit 7 and upper reserved bits must be clear.
* 88: optional independent bank routes for host, reader and writer in bits
  0–2. Leaving configuration mode preserves this setting; the ordinary bank
  command assigns both streams together.
* 89–90: full 10-bit TX and RX base offsets. Reserved upper bits must be zero.
  Word 88 supplies their starting banks; a stream may cross from bank 0 into
  bank 1 but cannot wrap beyond the two-bank capacity.
* 91–92: temporal sequencer enable and entry/idle actions; 93 selects the
  generic coded-stream path; 94 enables sequencer paging from SRAM and sets
  the page base ([paged programs](TEMPORAL_CONTROL.md#paged-programs)).
  Words 96–111 hold its 16 rows (page 0 when not paged), 112–116 hold
  sparse alternate-context selectors, 117–122 configure the coded shifter,
  and 123 controls temporal gating of output enables.
* 128–184 (extension, reset to zero; configuration addresses are 8 bits):
  128–151 switch words for cells 9–14 (four per cell, as above); 152–155 LUT4
  truth tables, indexed `{d,c,b,a}`; 156–171 LUT4 input selectors (cell k input
  j at 156+4k+j, sinks 25–40); 172–175 timer 2/3 first and period; 176–181
  timer 2/3 start, stop and hold selectors (sinks 19–24); 182–183 sequencer
  event-input selectors (sinks 41–42); 184 bits 0/1 replace sequencer events
  3/4 with those inputs. Extension sinks have no alternate-context override.

Words 66, 67 and 68 set TX length, RX capacity and pad feedback. Extended
compiler images include them; the original 66-word component images do not.
Configuration storage is distributed. `grid_config_tree` registers each
accepted write once at the root, next to the host link, and once more in a
leaf for each cell (0–14) plus one for the stream scheduler. Every
configuration register is written only from its own cell's leaf, so no
configuration net spans the chip. In the 1aa32b5 layout the old global write
bus and its address decode accounted for over half of the routed wire. A
write lands three clocks after it is accepted. Configuration validity is a
deep check over static words, so it is registered twice (in the grid core and
in the scheduler). The fabric arms only five clocks after the last accepted
write, once that registered result is current, and a start received in that
window is held. Disarm is immediate. Bank-route commands use the same path, so they
stay ordered with word 88. The image format, word addresses and host
commands are unchanged.

Before a configuration write, the host must clear address bits 9:8: opcode 0
changes only the low eight bits, so issue opcode 1 with zero first after any
SRAM access above address 255. A configuration write with nonzero high bits is
ignored. The per-call host words (66 and 67, TX length and RX capacity; 89
and 90, TX and RX bases) may also be written while armed and idle (arm with
opcode 4 value 0x0C to keep configuration mode), so a program's calls keep its
pins driven; every other word is accepted only while disarmed. While the host
link idles on opcode 5, `uo_out` shows the low byte of the received-byte count
(opcode 4 shows status, opcode 7 the third output pin). Bits 0 and 1 of word 68 select uio[6]
for input 1 and uio[5] for input 0; clear bits select uio[0]. This setting
persists across disarm and must be explicitly reset to zero for the supplied
SPI/UART images. An enabled open-drain output drives only zero and releases on
one; an external pull-up is required.

For frame-coupled RX, the host must provide exactly the number of bytes to be
written; mismatched frame lengths report an error rather than silently wrap.
For autonomous RX, the non-wrapping region bounds receive data and overflow is
sticky until disarm. The credit counter reserves space for all accepted reads;
responses must be ordered and cannot be backpressured. The local fair arbiter
services three persistent clients with at most two denied cycles. In the
tested periodic workload, reader request-to-FIFO latency reached two cycles;
this does not include physical routing or additional masters.

`make grid-fabric-experiment` runs compiler-image-driven SPI and independent
UART TX/RX on the same RTL, both SRAM banks, SRAM contention, bounded RX
overflow and assertions, followed by synthesis and a two-macro count check.
`make grid-stream-test` also tests two outstanding reads with a four-cycle
return, shared-bank contention at one byte per 16 clocks, and an isolated
two-alternative prefetch primitive. The branch primitive is not connected to
the chip top yet. See [the stream contract](../grid_stream/README.md).
`make sim` checks the chip interface with only top-level pins, including
`test_compiled.py`, which runs any compiled program's own source tests. The current
[JTAG, I²C, USB and Ethernet coverage and limitations](PROTOCOL_COVERAGE.md)
include temporal transactions and source-derived coded-stream images. The
physical flow and placed gate-level tests are separate from RTL simulation.

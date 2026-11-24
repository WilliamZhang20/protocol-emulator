# Structured 3 × 3 grid experiment

The experimental Tiny Tapeout top instantiates this grid, not the older
shared-selector fabric. It has no instruction fetch. Configuration is static
while armed; the grid is an architecture experiment, not a final floorplan or a
complete protocol compiler.

```text
              col 0          col 1            col 2
row 0       [input IO] ---- [output IO] ---- [timer 0]
                |                |                |
row 1       [shift 0] ----- [2-input LUT] --- [timer 1]
                |                |                |
row 2       [SRAM 0] ------ [shift 1] ------ [SRAM 1 + CRC]
```

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

The two bottom-corner cells each instantiate a separate single-port 1024×8
IHP SRAM macro with local host/actor arbitration. The actor word bus follows
dedicated point-to-point links from shift 0 down and across the bottom row;
static configuration chooses either bank. These word links and the host access
bus are **not** a general configurable data mesh, and the SRAM macros are not
physically distributed throughout the full floorplan. SPI and UART reuse the
the same credit-based stream reader and writer. Each has a two-byte FIFO;
the bank arbitrates host, reader and writer independently. The shifter frame
packer is configured by format words and consumes the same reader stream for
SPI, UART and the JTAG component. Protocol functions are not fully lowered.

## Image contract

The sibling CIRCT mapper's `--compile-grid-spi` and `--compile-grid-uart`
accept restricted, source-validated examples and allocate one of four tracks
per signal using either legal turn class with conflict checks and backtracking. Tile placement is currently fixed; this is not a general placer,
full source lowering or proof of timing. The 66 16-bit words are:

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
  `fabric_crc` contract. Direct legacy shifter links are not present here.
  Words 77–80 select its absorb, emit, reset and data inputs from the SRAM 1
  cell's local or neighboring signals. In the CRC's internal 64-line inputs,
  these are lines 0, 1, 2 and 32 respectively. When enabled, all 12 words
  must be written, routes must be valid and direct-link bits must be clear,
  otherwise the grid does not arm.
* 88: optional independent bank routes for host, reader and writer in bits
  0–2. Leaving configuration mode preserves this setting; the ordinary bank
  command assigns both streams together.
* 89–90: full 10-bit TX and RX base offsets. Reserved upper bits must be zero.
  Word 88 supplies their starting banks; a stream may cross from bank 0 into
  bank 1 but cannot wrap beyond the two-bank capacity.

The host additionally writes word 66 TX length, 67 RX length and 68 pad
feedback; these are not in the image. Bits 0 and 1 of word 68 select uio[6]
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
`make sim` checks the chip interface with only top-level pins, including a
reconfigured signal route, bidirectional pads, observed input edges and a
clock-stretch primitive and a nine-bit I2C byte phase with ACK, NACK and a
stretched clock. START, STOP and source transaction lowering are not covered.
It checks a source-validated JTAG `scan8` component with distinct SRAM-loaded
TDI and TMS lanes and TDO sampling. Full TAP transactions, dynamic `step` and
the source function's exact cycle semantics remain open.
It also checks the reused CRC using USB and Ethernet
vectors and payloads from the earlier protocol tests. The sibling compiler
can regenerate the images and extract a partial source-derived CRC profile;
it does not yet lower packet control or CRC connections.
`make grid-coder-reuse-test` separately tests the old coded-shifter and CRC
blocks together against the existing USB NRZI/stuffing encoder and Ethernet
Manchester/FCS reference. It verifies the encoded packet bitstreams in an
isolated reuse harness; these coded blocks are not yet connected to the grid's
SRAM stream or pin tiles, and link-pulse/USB end-of-packet control is not tested
there.
Physical placement, routed timing, pad timing, full-program compilation,
I2C/JTAG/Ethernet/USB support and a broader topology comparison remain open.

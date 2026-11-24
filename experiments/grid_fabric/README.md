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
same tiles and banks through hand-written finite/stream adapters.

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
* 63–65: hand-written adapter format, OR mask and SPI/UART mode.
* 69–76: optional CRC tile registers, reusing the legacy configurable 1–32 bit
  `fabric_crc` contract. Direct legacy shifter links are not present here.
  Words 77–80 select its absorb, emit, reset and data inputs from the SRAM 1
  cell's local or neighboring signals. In the CRC's internal 64-line inputs,
  these are lines 0, 1, 2 and 32 respectively. When enabled, all 12 words
  must be written, routes must be valid and direct-link bits must be clear,
  otherwise the grid does not arm.

The host additionally writes word 66 TX length, 67 RX capacity and 68 pad
feedback; these are not in the image. Bits 0 and 1 of word 68 select uio[6]
for input 1 and uio[5] for input 0; clear bits select uio[0]. This setting
persists across disarm and must be explicitly reset to zero for the supplied
SPI/UART images. An enabled open-drain output drives only zero and releases on
one; an external pull-up is required.

`make grid-fabric-experiment` runs compiler-image-driven SPI and independent
UART TX/RX on the same RTL, both SRAM banks, SRAM contention, bounded RX
overflow and assertions, followed by synthesis and a two-macro count check.
`make sim` checks the chip interface with only top-level pins, including a
reconfigured signal route, bidirectional pads, observed input edges and a
clock-stretch primitive. It also checks the reused CRC using USB and Ethernet
vectors and payloads from the earlier protocol tests. The sibling compiler
can regenerate the images and extract a partial source-derived CRC profile;
it does not yet lower packet control or CRC connections.
Physical placement, routed timing, pad timing, full-program compilation,
I2C/JTAG/Ethernet/USB support and a broader topology comparison remain open.

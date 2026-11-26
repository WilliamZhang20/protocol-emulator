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

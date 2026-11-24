# Stream experiment baseline — 2026-11-24

## Decision

Retain the generic reader/writer, cross-bank addressing, and shared frame
scheduler as the **experimental baseline**, subject to physical validation.
They remove separate SPI/UART memory adapters, pass the checks below, and map
to fewer standard cells in the comparison below. Keep the older committed grid
as the reference. Do not treat the fixed scheduler, combinational word links,
or isolated branch-prefetch experiment as the final temporal layer or network.

## Inventory

- Hardware baseline: `168f958` on `experiment/two-sram-placement`.
- Working tree: `src/grid_stream_tiles.v` implements one credited reader and
  one writer with two-entry FIFOs. `src/grid_stream_memory.v` has two
  three-client round-robin banks; stream bank addresses can cross from bank 0
  into bank 1. Its word links are wire aliases, not placed or pipelined paths.
  `src/grid_stream_fabric.v` uses a common hand-written frame scheduler.
- `src/project.v` switches the experimental top to that fabric and adds full
  ten-bit base configuration. Host, pin test, source lists, build, CI, and
  documentation changes accompany the replacement.
- The sibling compiler's `work/tile-fabric-codesign` branch has uncommitted
  host-word reporting and a FIFO bound model. Its CIRCT compiler still produces
  restricted SPI/UART images; it does not compile full protocol transactions.
- `branch_prefetch.v` is a separate one-byte two-choice prototype, not connected
  to the chip. The synthetic multi-reader test models a shared return path; the
  actual chip does not instantiate that multi-reader network.

## Validation

The following passed locally on the working tree:

- `make verify grid-stream-test grid-fabric-experiment`: lint, flattened
  synthesis and two macro instances, SRAM/PDN configuration checks, pin-level
  RTL cocotb, memory assertions and randomized bank tests, stream tests, and
  source-image grid SPI/UART tests.
- The stream tests cover a three-client arbitration bound, depth-two FIFO
  credits under delayed reads and backpressure, disarm/drain, a slower first
  bank at the boundary, a 1,518-byte read and a 200-byte write crossing banks,
  and a synthetic two-reader tagged-return scenario. An intentional credit
  reservation mutation is required to fail the reader assertion. The branch
  prefetch prototype is tested separately.
- Yosys flattened generic gates, with the behavioral SRAM macro models, passed
  `test/cocotb_tests/test_memory_placement.py` at Tiny Tapeout pins. This is a
  functional generic-netlist test, not the placed IHP gate-level signoff.
- Rebuilt CIRCT mapper and dialect; `circt_lab/test.sh` passed with the current
  grid testbench and checked-in SPI/UART fixtures. Other optional image tests
  without supplied testbench environment variables were skipped. The reused
  USB/Ethernet coder test also passed with Icarus.

Committed baseline `168f958` passed its [GDS, precheck and gate-level CI
jobs](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/45318791776).
Its separate test job failed because Ubuntu's Verilator 5.020 is older than
cocotb's 5.036 minimum; the uncommitted workflow switches that standalone coder
test to Icarus. The working tree has not been physically routed or checked by
remote CI. Existing electrical-limit observations remain separate from a GDS
workflow pass.

## Like-for-like synthesis area

Both flattened Tiny Tapeout tops were synthesized with the same Yosys/ABC
flow and IHP **SG13G2** typical standard-cell liberty as a proxy. This is not
the exact Tiny Tapeout CMOS5L physical flow. Both SRAM macros are black boxes.
The absolute values exclude macros, placement, routing, clock tree, buffers,
and keepouts, and do not establish fit or timing closure.

| Top | Mapped standard-cell area | Sequential cell area |
| --- | ---: | ---: |
| Committed `168f958` | 158,125.34 µm² | 86,955.12 µm² |
| Current stream work | 151,322.36 µm² | 82,644.11 µm² |
| Difference | −6,802.98 µm² (−4.30%) | −4,311.01 µm² |

The two existing SRAMs each occupy approximately 146.88 × 336.46 µm before
keepouts; they are unchanged in this comparison. This comparison is a useful
relative synthesis proxy, not a total die-area budget or physical estimate.
Yosys version: `0.67+111 (4821ed17b-dirty)`; liberty SHA-256:
`7677a8918689f452e80405ad16a83e744709342574f2aedcc507c2758986b396`.
The liberty was `sg13g2_stdcell_typ_1p20V_25C.lib` from IHP's public
IHP-Open-PDK. Reproduce with that library and:

```sh
python3 tools/compare_grid_area.py --baseline 168f958 \
  --liberty /path/to/sg13g2_stdcell_typ_1p20V_25C.lib --yosys /path/to/yosys
```

Logs are written to `build/area-comparison/`. Results can vary with tool and
library versions or later working-tree changes.

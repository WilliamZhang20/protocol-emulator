# Lane core (step 2.4): design

A lane core is the replicated unit of the lane architecture: one lane
controller with the tiles it times bits with, wired to each other by
construction, plus a narrow interface to the pads and the mesh. Step 2.4
builds one and runs every existing lane design on it; step 2.6 places two.

## Why a core, not lane control over shared tiles

Today the lane controller (step 1) drives grid tiles shared with the row
sequencer: timer0/1 and shifter0/1 are plain tiles in the mesh, the coded
shifter and CRC sit in cell 8 and run only in packet mode with their
receive path unconnected (CODER_INVENTORY.md). Every lane design spends
mesh routes on wiring that never changes between protocols (timer tick
to shifter shift, shifter done to timer stop, frame start to both), and
the coded shifter's parity, destuffing, Manchester and CRC link are out of
reach. Five self-sufficient lanes (the plan's concurrency objective) need
each lane to own its timing tiles.

## Composition

| Part | Module | Notes |
|---|---|---|
| Controller | `grid_lane_controller` | unchanged ISA; events, levels and readback come from the core |
| Timer pair | 2 x `grid_timer` | modes from step 2.1 |
| Coded shifter | `fabric_shifter` | parity, stuffing, NRZI, Manchester both ways, receive decode, CRC link |
| CRC | `fabric_crc` | polynomial or additive (step 2.3), linked to the coded shifter |
| Stream port | the lane's reader and writer | the controller's PULL/PUSH, and the coded shifter's auto pull/push |
| Local signal set | 64 lines (32 pulses, 32 levels) | every tile input selects any line, like `fabric_shifter`'s and `fabric_crc`'s existing `lines` |

The local signal set is the arch/spatial idea kept where it is cheap: one
lane's worth of lines (step 1.6 measured a single lane's signal space at
0.74x the mesh), while lanes reach each other and the pads through the
mesh. `fabric_shifter` and `fabric_crc` already select from 64 lines with
6-bit indices (pulses 0-31, levels 32-63), so they drop in unchanged; the
timers get three 6-bit selectors each.

### Lines (draft; the contract will own the table)

Pulses 0-31: 0 never, controller FIRE, controller SHIFT (tx word loaded),
timer0 tick/rise/fall, timer1 tick/rise/fall, shifter word/stop pulses,
pad-input edges (rise and fall per input), mesh-input edges.

Levels 32-63: 32 low, 33 high, controller actions 0-3, timer0/1
level and running, shifter serial out and active, CRC out and ok, pad-input
levels, mesh-input levels.

### Interface

- **Inputs:** N pad inputs (synchronized levels; edges made inside the
  core) and M mesh inputs (soft tiles: LUT4 cells, other lanes).
- **Outputs:** K output lines, each `{value line, enable line}` selected
  from the local set, so open drain, push-pull and tristate are all a
  selection (I2C: value low, enable = action; UART: value = shifter out,
  enable high). In today's grid these replace the cell-6 action sources.
- **Controller events/levels/readback** come from the local set by fixed
  assignment (the contract names them), plus readback of the timer
  captures, shifter rx word and status, CRC value.

## Configuration

Lane words do not fit the 8-bit configuration space (0-215 used). The host
already has address bits 9:8 (`command(1, x)`), today required to be 0 for
configuration writes. Page 1 (addresses 256-511) holds lane cores, 64
words each (lane k at 256 + 64k), delivered by its own leaf of the
configuration tree with the same validity-before-arming rule. Legacy pages
and images are untouched.

## Sub-steps (each sturdy before the next)

1. **2.4a `src/grid_lane_core.v`, standalone.** The core with its local
   signal set and its configuration words on a lane leaf interface; a
   standalone testbench (memory model for program load and streams) that
   runs a UART transmit, a UART receive with parity and resync, and a
   capture, all through local lines only; a formal check of the line table
   (each selector value reaches exactly its line; reserved values are
   invalid configuration); contract `lane_core` section and checker.
2. **2.4b in the chip.** Configuration page 1 (10-bit addresses through
   the host link; page-0 writes and images unchanged; host words 66/67/89/90
   only on page 0) feeding a lane leaf; lane mode uses the core (its output
   lines become cell 6's local sources, mesh inputs from sinks 41-42, pads
   direct). Compiler: lane design schema v2 naming core tiles and lines
   (`timer0.aux <- in0.fall`), encoded from the contract. The five lane pin
   tests (I2C target, SPI target, SLIP TX, pulse period, UART resync) move
   to core designs and must pass unchanged at the pins.
3. **2.4c what only the core can do,** at the pins: UART 8E1 receive with
   the parity check tagging bad bytes; Manchester receive; the coder link
   carrying data bits only, so a LIN checksum (additive CRC) checks a
   received frame.

## 2.4a status: done

- `src/grid_lane_core.v`: 38 configuration words, 64 lines (pulses 0-18,
  levels 32-50 defined; the rest reserved), three outputs, ten readback
  slots. Every line is a register output, so no selection closes a loop.
- `make lane-core-test` (CI, test workflow): `-Wall` lint, the
  pure-function and part-select rules, and four cocotb tests:
  - UART 8E1 transmit, the coded shifter pulling bytes itself (six bytes
    including 0x00, 0xFF; no controller work per byte).
  - UART 8E1 receive at 0, +5 and -5 % drift with timer0 resync on in0
    falls; the controller checks status bit 6 (word bad) and pushes good
    bytes; a wrong parity bit fails the lane after the earlier bytes.
  - Timer1 capture of in1 rising-edge periods (100, 333, 1000 clocks).
  - Invalid configurations refused (reserved lines, reserved bits, N=1
    stuffing, Manchester with NRZI, CRC shape, half-set timer).
- `formal/grid_lane_core` (CI): k-induction that a configured core has no
  selector on an undefined line and no reserved bit set, over every word
  state; 10 mutations of the validity logic all give counterexamples.
- Contract `lane_core`: line table (index, name, RTL source), selector
  fields with kinds, reserved bits, word layout, readback. The checker
  matches the RTL `lines` vector bit by bit, the `line_ok`/`level_ok`
  bounds, the selector wiring, the readback order, and the proof's mask
  and field lists; 8 contract mutations are rejected.

Two findings worth keeping:

- **Impure functions lie in simulation.** `fabric_shifter`'s
  `frame_bit_at` read frame registers directly while called from
  continuous assignments. Icarus re-evaluates those only when the
  arguments change, so with `index` and `tx_word` at their reset values the
  transmit bit stayed X after configuration. Synthesis and verilator were
  fine; the chip tests passed by ordering luck. The function now takes a
  packed shape argument, and `tools/check_pure_functions.py` (in
  `make lint`) refuses any function that reads a module signal.
- **Sample latency.** A tick and the coder's sample are each one register,
  so a receiver's sample lands 2 clocks after the timer count ends. The
  first-tick count and the resync phase both subtract it (the compiler's
  UART receive templates must do the same when they move to the core).

## 2.4b plan: the core in the chip (one sub-step at a time)

Lane mode (word 91 bit 2) runs the core instead of today's lane
controller over shared grid tiles; one controller per lane, no second
path to keep alive. The row sequencer, packet engine and lane B are
untouched.

1. **b1 configuration page 1.** `grid_config_tree` gains a page input and a
   dedicated lane leaf: the root splits `valid` by page, so the 16 existing
   leaves never see a page-1 write (no consumer changes) and the lane leaf
   sees only page-1 writes. `project.v` accepts image writes with
   `host_addr[9:8]==1` while disarmed (host words 66/67/89/90 stay page 0
   only). Lane k's words are at 256 + 64k (k = 0 for now). The fabric's
   `configured` requires the core's validity when lane mode is set.
   Contract `configuration.pages`; a pin-level test writes page 1, checks
   validity gating and that page-0 images are unchanged.
2. **b2 core in the fabric.** `grid_lane_core` replaces `lane_ctl`: same
   memory port, stream reader/writer, start/abort, drain-before-done and
   stream-fail logic; `fabric_readback` = {stream status, bytes written,
   bytes left}. Pads: the synchronized `pin_in`. Mesh inputs: sinks 41-42
   (today the sequencer events, unused in lane mode). Outputs: the core's
   three value lines become cell 6's local sources in lane mode and its
   enable lines gate the matching pins' output enables, so open drain is a
   selection. Controller WCFG targets the core's timer shadows (live first
   and period through `grid_timer`'s `live_we`); any other word is refused,
   keeping the write fence.
3. **b3 compiler schema v2** (`spatial.lane-design.v2`): core tiles and
   lines by contract name (`timer0.aux <- in0.fall`, `out0 = coder.serial
   enable high`), encoded from the contract's `lane_core` table into page-1
   words; v1 designs are rejected with a pointer to v2.
4. **b4 tests at the pins.** Every lane test (controller, timer capture
   and resync, I2C target, SPI target, SLIP TX, determinism, timing) runs a
   v2 design and passes unchanged at the pins; then gate level locally.

## 2.4b status: done (gate level confirmed by CI's gl_test)

- **Page 1.** `grid_config_tree` splits validity at the root by page: the
  16 cell leaves see only page 0, the new lane leaf only page 1, so no
  page-0 consumer changed. `project.v` takes page-1 image writes while
  disarmed; host words stay page 0. Lane mode's readiness is the core's
  validity (the row sequencer's settings and contexts are not required).
- **The core in the fabric.** `grid_lane_core` replaces the lane
  controller over shared grid tiles; word 95 is retired (the program word
  is core word 36). Pads: the grid's synchronized pins. Mesh inputs: sinks
  41-42. The core drives the three pins directly (value and enable lines)
  and its values are cell 6's local sources. WCFG owns core words 0-7 (a
  controller parameter now; the default stays 112-116) and the core
  accepts timer first/period, nonzero, of a timer in use, into the timer's
  shadow.
- **Compiler v2** (`spatial.lane-design.v2`, protocol-emulator-compiler
  `circt_lab/grid_lane.py`): connections by contract name, timers and
  coder/CRC registers by named field (the contract's `lane_core.registers`,
  checked against the tile decodes), event and level slots allocated from
  the program's operands, `word:<name>` WCFG operands, the core's validity
  rules enforced at build time, an inert page-0 grid from the contract.
  v1 designs are refused with a pointer to v2. Its test rebuilds every
  shipped design and compares it byte for byte with the RTL pin-test data.
- **Tests at the pins** (41/41 with the rest of the suite): the five
  designs (I2C target, SPI target, SLIP TX, pulse period, UART receive with
  and without resync) and the controller, determinism and timing tests run
  on the core; a new test checks that page-1 validity gates arming.

Found and fixed on the way:

- **Resync double-sampled a late edge** (`grid_timer`). With a slow sender
  the sampler runs early; an edge arriving just after the tick that sampled
  its bit was pulled to `phase`, sampling the same bit twice. The phase
  error is now cyclic: an edge with more than `phase + period/2` clocks
  remaining targets `phase + period` (the next bit), then the limit clamp,
  then saturation. The timer's reference model was rewritten
  independently; two new mutations (double sample, wrap) are caught.
- **SHIFT sent the previous byte** (the core). The controller registers
  its tx word on the SHIFT clock; the core wrote the coder one clock early.
  It now writes on the registered shift line. The FIRE line is now the
  FIRE instruction only (the controller's internal fire after a SHIFT, for
  the old grid shifter, no longer reaches it).
- **Inputs are registered at the core boundary**, so "every line is a
  register output" holds for any input; in the chip the mesh is
  combinational and a core output routed back to sink 41 would otherwise
  close a loop through a selector. Edge to pad is now 5 + k clocks
  (LANE_TIMING.md).
- **Sample timing rule:** a receiver's first count and resync phase are
  half a bit less the 2-clock tick-to-sample latency; input latency
  delays the edge and the sampled level alike and cancels.

## 2.4c status: done locally (awaiting CI)

Three receive modes only the core can do, as compiled designs at the pins
(`test/cocotb_tests/test_lane_receive.py`, designs in the compiler's
`circt_lab/lanes/`):

- **UART 8E1 receive, tagged** (`uart_rx_8e1`): timer0 resync, the coded
  shifter checks even parity and the stop bit. The `rx_tagged` program
  pushes every byte followed by a tag byte (coder status bit 6: 0 good,
  0x40 bad), so a bad frame is kept and marked rather than ending the
  transfer. A flipped-parity frame and a low-stop frame are tagged; all
  bytes arrive at 0 and +-5 % baud.
- **Manchester receive** (`manchester_rx`): timer0 ticks every half bit
  (10 clocks), resyncs on every falling edge (always on a half-bit
  boundary), first count and phase 3 (a quarter bit less the 2-clock
  sample latency). Each frame is a sync 1 then 8 data bits. Equal halves
  in a data bit tag the byte; good frames decode at 0 and +-5 %.
- **LIN classic checksum in the CRC tile** (`lin_checksum`): 8N1 receive,
  the CRC tile additive one's complement over 8-bit words, linked to the
  shifter. Four data bytes and the checksum sum to 0xFF (checked with
  carries wrapping twice, all-FF and 0x01); the lane pushes the sum and
  fails on a corrupted checksum.

New in the RTL: **coder register 6 bit 13, CRC link data bits only.** The
link used to carry every frame bit, start, parity and stop included, so a
UART checksum summed its framing. With the bit set only data bits reach
the CRC tile (the skip count counts data bits too). Sent bits are
classified at the index they are presented at (a new frame at 0, the next
burst word at its first data bit, an advance at index + 1); received bits
at the sample's index. A new bounded check (`formal/fabric_shifter`
`link_bmc`, depth 40, plus cover) proves on the transmit side that for any
framing (0-3 pre bits, any parity, 0-3 post bits, 1-16 bit words, either
order, bursts or single frames) the link carries exactly each word's data
bits in wire order; 4 mutations (`make -C formal fabric_shifter-mutations`,
CI) are each caught. The lane core's validity rule, the contract
(`coder.coder2.link_data_only`, reserved bits 15:14) and its checker, and
the core's formal reserved-bit property follow.

Compiler: a linked CRC on a shifter that samples (`coder.sample`
connected) now needs `coder.coder.receive`: without it the link carries the
coded *sent* bits and sums the idle output, which is what the first LIN run
did (sum 0). The compiler suite checks all nine shipped designs build to
the exact RTL test data.

Also fixed: the tile experiment's timer testbench still expected the old
non-cyclic resync (CI failure on 9a3e66e); it now checks both the late-edge
(target phase + period) and the near-edge cases.

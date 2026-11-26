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
  the bit's centre clock, (bit - 1) // 2 after the edge, less the
  edge-to-sample offset. *Corrected 2026-11-26 by measurement* (lane-core
  test `sample_latency_matches_contract`): the offset is 1 clock, not the
  2 stated here before. The tick and the sample are two registers, but
  the edge path (edge detect) is one register longer than the level path,
  so they do not cancel fully. The old `bit/2 - 2` gives the same counts
  for even bits (8 for 20 clocks), so no design changed. The contract
  states the measured value (`lane_core.edge_to_sample_cycles`) and the
  compiler derives the counts from `sample_first`/`sample_phase`.

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
  boundary), first count and phase 3 (the half bit's centre clock, 4,
  less the 1-clock edge-to-sample offset). Each frame is a sync 1 then 8 data bits. Equal halves
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

## Routing gate result and decision (2026-11-26): clusters, no duplication

**Result.** 9a3e66e (the lane core beside the grid fabric) cannot route:

| | d628e18 (routed) | 9a3e66e |
|---|---|---|
| synth area (local, IHP liberty) | 350k um2 | 614k um2 |
| instances | 24,800 | 44,434 |
| utilisation | 38.4% | 67.1% |
| DRT violations | 10,827 -> 0 by iteration 4 | 122,615 -> 100,434 in 2 iterations (about 4 h) |
| global-route overflow | cleared | 24,724 |

Utilisation follows synth area linearly on this die (about 0.11% per
1k um2: 350k gives 38.4%, 614k predicts 67.4%). The lane core
(224k; 145k plus a 15k macro with the program store) duplicates
timers, a coded shifter and a CRC the grid already has, which idle in
lane mode. The 16-entry buffer probe (c38b62b) also stayed in Build GDS
past 2.7 h, and 7193f31 failed at 49%. Shrinking the core alone would
leave about 59%: not credible.

**Decision (user, 2026-11-26): clusters with no duplication.** The
fabric's timers, shifters and CRC become cluster resources, each
assignable at the bit level. Words stay on a cluster's bus or go
through stream ports. The lane core's bundle replaces the grid's
separate tiles instead of sitting beside them. This replaces the 2.5
plan below (two fixed lane cores), which is kept only as history.

### Target

- **Budget.** At most about 40% utilisation, about 365k um2 synth, the
  same as the design that routed. Every sub-step measures synth area
  with the calibrated local flow before its GDS.
- **Cluster** (one type first, instances by budget):
  - the lane controller (ISA unchanged) with its 64x16 program-store
    macro (lane/prog-store-macro);
  - 2 timers, 2 coded shifters, 1 CRC (`grid_timer`, `fabric_shifter`,
    `fabric_crc` unchanged);
  - one stream port (reader and writer on the SRAM arbiter);
  - the word bus: controller readback, tx word and WCFG reach only the
    cluster's own resources and words (ownership by construction inside
    a cluster).
- **Local lines, sparse (VPR Fc_in < 1).** Each resource input selects
  from the subset of the cluster's lines that the contract lists for it,
  not from all 64. The subsets come from what the shipped protocols use
  (the compiler's census), with headroom. This bounds the local crossbar
  by construction. Today's ~40 selectors x 64 lines all-to-all is the
  largest remaining wiring structure.
- **Mesh (bit level, independent assignment).** Each cluster exports a
  fixed set of resource outputs to the switch mesh and takes mesh inputs
  as lines. A protocol's bit nets may cross clusters (a timer in one
  driving a shifter in another), with the latency the router accounts
  for (R5 constraints). The LUT4 cells and switches stay as soft logic.
- **Removed, after migration:** both `grid_sequencer`s, the page loader,
  the grid's 4 standalone timers, its coded and CRC tiles, and the
  frame, packet and temporal modes. Each existing protocol is re-lowered
  to cluster programs first (below); nothing is deleted while a test
  depends on it.

### Sub-steps (each sturdy, with its own evidence, before the next)

1. **Inventory and budget.**
   - Per-instance synth area of every block in the current chip.
   - The census of which lines each resource input uses across all
     shipped and compiled designs.
   - The cluster's estimated area with sparse selectors, and the number
     of clusters that fit in 365k.
   - Gate: the budget closes on paper.
2. **Contract v2: clusters as resources.**
   - Cluster type, resources, per-input line subsets, mesh exports and
     word-bus reach.
   - The checker reads it.
   - The compiler RRG gains the cluster-local crossbar as routing nodes
     (VPR's intra-cluster routing), so the router and placer see one
     graph.
3. **Cluster RTL (one cluster) beside the existing fabric.**
   - Measured standalone: area, sparse-selector proof (each input reaches
     exactly its listed lines), lane-controller and lane-core proofs
     ported, pin tests of every lane design.
   - No chip GDS yet.
4. **Migration, one feature at a time.** Each sequencer, packet or frame
   protocol (temporal I2C, JTAG TAP, coded USB/Ethernet streams,
   Ethernet session, compiled images, memory placement) is lowered to
   cluster programs, and its cocotb test is ported to run on clusters at
   the pins. The old path stays until its replacement passes.
5. **Delete the duplicates, then the chip GDS.**
   - Remove the old paths; synth must meet the budget.
   - One GDS (with the DRT fail-fast) must route, with DRC/LVS clean.
   - Only then is the second cluster placed.
6. **Compiler: pack stage.**
   - Protocol resources go into clusters under the word-domain
     constraint (every resource a controller reads or writes is in its
     cluster), then the annealing placement and PathFinder over the
     cluster-aware RRG.
   - R7 lowering maps to resources, not fixed slots.
   - Two-shifter protocols (full-duplex UART, I2C) lower to one cluster.

### Sub-step 1 status: inventory (2026-11-26, f233e68, local yosys + IHP liberty)

Per-instance areas from the hierarchical synthesis, in um2 unflattened.
Flattening merges logic across modules: 716k unflattened against 614k
flattened, about 1.17x.

| Block | Area | Contents |
|---|---|---|
| `grid_core` | 358k | own 177k (mesh, cell configuration: 1152 DFFE + 852 SDFFE, sink selectors); 4 `grid_timer` 65k; coded shifter + config banks 34k; CRC 24k; 15 switches 20k; `grid_sequencer` (lane B) 26k; 2 `fabric_v2_shift` 11k; 4 LUT4 1k |
| lane core | 241k | own 53k (38 config words, 64-line selectors); controller 97k (about 78k of it the flop program buffer); 2 timers 32k; coded shifter 34k; CRC 24k |
| top-level | 96k | stream fabric 30k; config tree 22k; `grid_sequencer` (lane A) 26k; page loader 7k; readers, writers and banks 11k |

**Budget, first pass** (target about 365k flattened, about 425k
unflattened):

- One cluster: the lane core with the program-store macro (about 163k:
  standard cells 145k + macro 15k flattened, or about 170k unflattened)
  plus a second coded shifter (+34k), about 204k.
- The fabric with its duplicates removed (4 timers, coded and CRC tiles,
  both sequencers, the v2 shifters, the page loader): about
  358 - 160 + 96 - 33 = 261k.
- Fabric + one cluster: about 465k unflattened, about 397k flattened,
  about 44% utilisation. That is above the 40% estimate, but the
  estimate is only what one earlier design (d628e18) routed at. It is
  not a physical limit: no run has tested two clusters at a higher
  density, or with an orderly floorplan.
- The largest remaining block is the 5 x 3 mesh's own configuration
  and selectors (177k).

Sub-step 1 continues:
- the census of which lines each resource input uses (to size the sparse
  local selectors);
- what the mesh must still carry once clusters hold their own wiring
  (inter-cluster bit nets, LUT4 inputs, pins), from the compiler's
  channel-width study (2 tracks suffice for every shipped protocol).

**Census of local-line use** (the 10 shipped lane designs, compiler
`circt_lab/lanes/*.json`):

| Input | Distinct lines used | Lines |
|---|---|---|
| timer0.start | 3 | coder.active, in0.fall, shift |
| timer0.stop | 1 | coder.stop |
| timer0.aux | 2 | in0.fall, in0.rise |
| coder.start | 3 | fire, in0.fall, shift |
| coder.shift / coder.sample | 2 each | in0.rise, timer0.tick |
| coder.in | 2 | in0, in1 |
| coder.abort | 1 | action1 |
| outK.value / outK.enable | at most 2 | coder.serial, low / action0, high |
| controller events | 6 kinds | coder.word, coder.stop, in0/in1 rise/fall |
| timer1, CRC selectors | 0 | unused (LIN reaches the CRC through the shifter link) |

No input uses more than 3 of its 64 lines. Ten designs are a small
sample, and the migrated sequencer protocols (sub-step 4) will add more,
so the subsets are typed rather than taken from this list alone:
- timer start, stop and aux: pulses plus coder.active;
- shifter shift and sample: timer ticks, pad edges, mesh edges;
- data inputs: pad and mesh levels;
- outputs: shifter serial outputs, actions, constants.
That is a small fraction of 64 per input. Sizing these sets with the
compiler's census tool is the next part of sub-step 1.

**Mesh sizing: open; compare alternatives before deciding (user, 2026-11-26).**
An earlier note here proposed shrinking the mesh to cluster joins to
meet the 40% estimate. That trades away connectivity without measuring
what it costs. With independent assignment, the mesh is what lets a
resource in one cluster serve a protocol in another: a timer in cluster
A driving a shifter in cluster B, and how many such connections can
coexist. That decides how much flexibility the chip has. Removing
duplicated hardware stands. Reducing connectivity has to be justified
against the flexibility wanted.

Alternatives to compare, each with real multi-protocol mappings and
physical results:

1. **Higher density, current connectivity.** Duplicates removed, the
   5 x 3 mesh kept (4 tracks, its sinks), two clusters: about 46-50%
   by the estimate. Does it route?
2. **Orderly floorplan.** The same logic with placement regions per
   cluster and the mesh between them (step 4.3), so each cluster's
   local wiring stays local.
3. **A smaller but sufficiently connected mesh.** Size tracks, cells
   and sinks from what multi-protocol mappings need, with margin, not
   from the area target.

Evidence for each:
- **Mappings (compiler):** multi-protocol workloads with protocols
  running together and cross-cluster bit nets (timer in A, shifter in
  B), routed by PathFinder on each candidate's routing graph. Measure
  the maximum number of coexisting cross-cluster connections, which
  workloads route, and track use.
- **Physical:** synth area, then a GDS per candidate (with the DRT
  fail-fast): utilisation, detailed-routing convergence, wirelength,
  DRC/LVS.

No candidate is chosen before both kinds of evidence exist.

**Baseline mapping, the current 5 x 3 mesh (2026-11-26).** `grid_chanwidth.py --combine` placed and routed the six routing workloads (SPI, UART, I2C, JTAG, USB, Ethernet TX bit slices) on the contract's graph:
- Alone, every protocol routes in at most 2 of the 4 tracks (USB and Ethernet TX in 1).
- Of all combinations, only two fit the resource instances at all (SPI + USB, SPI + Ethernet TX), and both route in 2 tracks.

Today concurrency is limited by resource counts (timers, shifters), not by mesh connectivity. Clusters add resources, so more combinations fit, and only then does cross-cluster connectivity bind. The candidates must therefore be compared on the combinations that clusters make possible, with nets crossing clusters, not on today's single protocols. That needs each candidate's routing graph (contract v2 with clusters) in the compiler: the next piece of this comparison.

## 2.5 plan (superseded 2026-11-26 by clusters, above): two lane cores, ownership by construction, per-lane status

Decisions (each with its reason):

- **Ownership is structural, not a table.** A core's WCFG reaches only its
  own words (timer shadows, `live_write_accepted`) through a port inside
  the core; there is no shared live-write path, so no lane can write
  another's words and nothing needs checking at run time. Lane writes into
  soft-tile contexts are not added to this grid: the fabric-wide lane
  wiring of 7193f31 (readback gathered from cells, WCFG into grid
  contexts) is what stopped detailed routing converging, and step 4.2
  rebuilds soft tiles with per-cell leaves and an arbiter for the host
  plus three clients per lane, which is where such writes belong. The
  contract states, per lane, the words its WCFG reaches.
- **Lane 1 is a second `grid_lane_core`** on page 1 words 64-101 (lane k
  at 64k, as the leaf already decodes), with its own leaf from the tree
  root, so page-1 validity is per lane. Lane 1 reaches SRAM through the
  same port arbiter as lane 0 (its program load is one client more).
  PULL/PUSH are stream operations (the controller has no load/store), so
  lane 1 needs its own stream pair: a reader and a writer over host words
  of its own (base, length, capacity on page 1), arbitrated with lane 0's
  on the SRAM port. Each lane's stream faults fail only that lane.
- **Pins.** Lane 0 keeps in0/in1 (uio5/uio6) and the three outputs.
  Lane 1 reads uio0 and lane 0's in0/in1 as its pad inputs, and lane 0's
  outputs as its mesh inputs; its outputs drive a pin only where a page-1
  pin-owner word gives it that pin (one owner per pin, checked by the
  validity rule). Step 3's eight pads replace this.
- **Host.** Command 5's data selects the lanes to start (bit k lane k;
  0 keeps today's behavior: lane 0). Status view (opcode 4) gains lane 1
  done (sticky until its next start), error and active in bits 2:0; the
  finish pin stays lane 0's (and the merged completion goes in 2.7).
- **Tests.** Formal: lane 1's validity proof is the same proof (one core
  module); a new bounded check that a lane-1 WCFG never changes a lane-0
  word and vice versa. Pins: two programs at once, each finishing on its
  own and reporting its own error; start masks; status bits.

Gate before writing RTL: the 9a3e66e GDS must show whether one core
routes. If detailed routing still does not converge, placement regions
per lane core (step 4.3) come before a second core.

## First protocol from source by general lowering: PS/2 (step 5, R7)

`examples/ps2.spt` (the compiler repository) lowers by rule, with no
hand-written lane design, to `test/data/lane/ps2-rx.*`
(`circt_lab/grid_lower.py`); the pin test `ps2_lowered_from_source`
receives make/break codes and all-zero/all-one/alternating bytes at two
clock rates, and a wrong parity bit fails the lane.

Found on the way, fixed in the shifter: the receive readback
(`coder.rx_word`) was the live shift register, which a frame restarting
on its end clock (start held high, as PS/2's `start: 1` lowers) clears
before a controller can read it, while the word's status bit (word_bad)
was already latched at the word's end. The readback is now the word as
of the last word pulse, latched with its status (live only with the bit
strobe, where the pulse is per bit). New bmc property: the readback
changes only on the clock after a word pulse; the old live readback is
one of the shifter's CI mutations and is caught.

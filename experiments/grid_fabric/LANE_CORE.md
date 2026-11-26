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

## Program store: design (2026-11-26)

**Problem.** Every GDS since 7193f31 stalls in detailed routing, including
9a3e66e, where the fabric-wide lane wiring was already gone. What 7193f31
added and the lane core kept is the controller's program buffer:
`reg [15:0] prog[0:63]`. That is 1024 storage flops, each with a write
enable, all written from one 16-bit broadcast (`{mem_rdata, low}`), and
read through a combinational 16-bit 64:1 mux:
`pc -> prog[pc] -> decode -> fire, cfg_we, wr_valid, rd_consume`. It is
about 80k of the core's 247k um2 synthesized, and its wiring is fan-in
everywhere: every bit of storage goes to one mux, every write goes to
every bit. The probe `probe/route-buffer16` (c38b62b, 16 entries, never
merged) tests whether this is the congestion.

**Requirements.**
1. One instruction per clock, waits hold. The decision time stated in
   the ISA does not change.
2. Capacity: the largest shipped programs are i2c-target (38
   instructions) and slip-uart-tx (27); the receive programs are 8-17.
   64 entries keep headroom; 16 would drop two shipped protocols.
3. Routing demand bounded by construction, not by placement luck.
4. The lane-controller reference proof still applies.
5. Per controller, so it still works when controllers are independent
   resources (next section).

| Option | Routing demand | Capacity | Timing | Verdict |
|---|---|---|---|---|
| 64 flops + 64:1 mux (today) | 1024 placed bits into one mux tree, one broadcast write | 64 | pc -> mux -> decode | suspect |
| 16 flops (the probe) | 256 bits | 16: i2c-target, slip-uart-tx no longer fit | shorter | probe only |
| Latches instead of flops | ~30% less storage area, same mux and broadcast | 64 | same | does not change the wiring |
| Registered read (prefetch into an `ir` flop) | same storage and mux | 64 | adds a bubble on taken branches | changes decision time: no |
| One shared program SRAM, controllers in turn (barrel) | one macro | large | decision time x N controllers | breaks requirement 1 |
| **Per-controller `RM_IHPSG13_1P_64x16_c2` macro** | 16 DIN + 16 DOUT + 6 ADDR + 4 control pins at fixed places; no storage or read mux in placement | 64 | clk -> DOUT 5.0-5.2 ns (slow corner, 1.08 V, 125 C) of the 20 ns clock; address setup negative | **chosen** |

The macro is 236.8 x 64.36 um (15.2k um2, against ~80k for the flops
and mux). It is in the same IHP SRAM family as the 1024x8 banks, so it
takes the same integration rules: halo, Metal2-4 body obstructions,
power from ExtendPowerStripes, and buffered DOUT (the 1024x8 notes on
weak DOUT pins).

**Fetch (the invariant).** Whenever the controller is running and not
loading, the macro's DOUT is `prog[pc]`. The macro reads synchronously,
so this clock presents the address of the next instruction:
`addr = !retire ? pc : taken ? arg[5:0] : pc + 1`, and DOUT holds the
instruction for the new pc on the next clock. Waits present `pc` again,
so DOUT holds. Branch, wait and retire behaviour, and with them the
decision time, are unchanged. The path is DOUT (5.1 ns) -> decode ->
next-address mux -> ADDR, which replaces today's pc -> 64:1 mux ->
decode.

**Load.** As today: the loader writes word `got >> 1` with WEN. After the
last word, `loading` stays high one more clock to read address 0, so the
first instruction issues one clock later than today. The contract and
the pin tests are checked for any stated start latency, and it is
restated if one exists.

**Simulation and formal model.** A wrapper `lane_prog_store #(ABITS)`
instantiates the macro in synthesis (ABITS=6 only). In simulation and
formal it is a behavioural synchronous RAM with the macro's cycle
semantics, at ABITS=3 for the proof, as today. Tying the model to the
macro:
- A Verilator test drives the IHP behavioural model and the wrapper
  model with the same random write/read sequences, then compares DOUT
  every clock.
- The gate-level test runs the real netlist with the IHP model, as the
  1024x8 banks already do.

**Tests and proofs.**
- The reference-model proof is unchanged, because the ISA semantics do
  not change.
- New property: running and not loading implies `ir == model_prog[pc]`.
- New mutations, each of which must be caught:
  - the address presents `pc` instead of the next pc (stale fetch);
  - no prefetch clock after the load;
  - the taken-branch target is not fed to the address;
  - a write lands during execution.
- Pin tests: all lane programs, i2c-target and slip-uart-tx included.

**Gate.**
- If the probe routes, the buffer was the congestion, and the macro
  removes it by construction.
- If the probe does not route, the buffer is not the only cause. The
  macro still removes 80k um2 and the 64:1 mux, but the next suspect
  (the core's 64-line local set, or placement regions, step 4.3) is
  diagnosed first, with the fail-fast run's (dc539bf) DRT artifacts.

### Program store: status (RTL done locally, physical integration next)

- `src/lane_prog_store.v`: the macro (`USE_MACRO`, ABITS 6) or the
  behavioural model with its cycle semantics. `USE_MACRO` is threaded
  `project -> grid_stream_fabric -> grid_lane_core -> grid_lane_controller`.
- Controller fetch: `fetch_pc` comes from the same `jump_taken` term the
  sequential branch uses, so fetch and execute cannot disagree. Loading
  ends with one priming clock.
- Proof: a priming phase in the reference model, the fetch invariant, and
  "pc is 0 through loading" (induction needed it). Prove and cover pass;
  12/12 mutations are caught (4 new: stale fetch, no priming clock, taken
  branch fetching pc + 1, last word not written). The `grid_lane_core`
  proof passes, 10/10 mutations.
- `prog_store_tb` (in `make lane-core-test`): the model against the IHP
  vendor model (`test/models`, FUNCTIONAL). 10k reads, 5k writes and 5k
  held clocks agree, and a write-through mutant is caught at cycle 3.
- Full cocotb regression 47/47, including i2c-target and slip-uart-tx;
  lane-core tests 5/5; lint; `synth-check` (exactly one
  `RM_IHPSG13_1P_64x16_c2`); `grid-contract-check`. The checker now
  accepts yosys's parameterized module names (`is_module`).
- The macro's views (lef, gds, lib, cdl, verilog) exist at the PDK
  revision the GDS action pins (2bbec755, 2026-09-08; the macro was added
  2026-08-11). `sg13cmos5l_sram` is a symlink to `sg13g2_sram`.
- **Next, physical:** a `MACROS` entry with a fixed location, Metal2-4 body
  obstructions and placement keep-outs, `PDN_MACRO_CONNECTIONS`, and
  `odb_sram_stripes.py` generalized per macro type. The 64x16 LEF declares
  every supply column as a Metal4 pin (20 VDD!, 20 VSS!, 16 VDDARRAY!,
  5.62 um alternation, the same VDD!/VDDARRAY! break near y 39-45), so
  the tile stripes snap onto declared pins. Signal pins are Metal2 on the
  bottom edge. Verified only by GDS runs.

## Independent assignment of resources: assessment (2026-11-26)

**The proposal.** Every controller, timer, shifter, CRC and stream port
is a separate resource that the compiler selects and connects for a
protocol. A lane becomes a logical grouping the compiler forms, not a
fixed hardware bundle: a protocol needing two shifters and one CRC gets
exactly those, and another gets a different mix. The switch-box mesh
connects them; word-wide transfers may need data paths of their own.

**What it fixes.**
- Fit:
  - A full-duplex UART needs two shifters. Today `grid_lower.py`
    refuses it ("a lane core has one coded shifter").
  - A receive-only design wastes its core's second timer.
  - A protocol with no decisions (a timer, a shifter and auto push/pull)
    still occupies a controller.
- Co-design: this is VPR's own model, heterogeneous blocks that are
  packed, placed and routed. The compiler pieces already built apply
  directly: the RRG from the contract, PathFinder, the annealer, and
  latency constraints.

**What it costs: three risks.**
1. *Word paths.*
   - Today these are fixed wires inside the core:
     - controller -> shifter tx word (16 bits);
     - shifter rx word and status, CRC value and timer captures ->
       controller readback (16 bits each);
     - stream bytes -> shifter auto pull/push;
     - WCFG -> timer shadows.
   - Over the bit mesh, each becomes a 16-bit bus. Fabric-wide word
     wiring (7193f31: readback gathered from cells, WCFG into
     contexts) is what first stopped routing converging.
2. *Bit-path latency.*
   - Tick -> shift and done -> stop are 1-clock local paths today.
   - On the mesh they cost what the route costs. The compiler can hold
     them exact (R5 `exact` constraints), and pin-referenced timing
     must add the route's latency to the class latencies (`hardware.rs`,
     contract).
   - That is more for the compiler to get right, but every part of it
     is already in the router.
3. *Ownership.*
   - 2.5 makes ownership structural: a core's WCFG reaches only its own
     words.
   - Independently assigned resources need ownership by configuration:
     a compiler-written owner per resource, checked by the static
     validity rule, as pin owners are.

**Recommendation: independent at the bit level, bounded at the word
level (VPR clusters).**
- *Cluster.* A cluster is a word domain. It contains:
  - one controller with its program-store macro;
  - a small word bus (address plus 16-bit data, owned by the
    controller);
  - a typed set of resources attached to that bus. The first cluster
    type is today's core with a second coded shifter: 2 timers, 2
    shifters, 1 CRC, 1 stream pair.
- *Bit level.* Every resource's bit inputs and outputs reach the mesh
  through the cluster's line set, which serves as its local crossbar.
  Any resource in any cluster can be assigned to any protocol for
  bit-level work: a timer driving a pin, an edge detector, a shifter
  with auto push/pull and no controller. That is the independent
  assignment.
- *Word level.* Words never cross the mesh. A word moves only:
  - on the bus of the cluster it is in; or
  - through a stream port (SRAM-backed).

  The packer therefore keeps every resource whose word a controller reads
  or writes in that controller's cluster. That is one packing
  constraint, and the "additional data paths" the proposal mentions are
  the cluster bus plus stream ports, both bounded by construction.
- *Ownership.* Per-resource owner fields written by the compiler and
  checked statically. Inside a cluster, word-bus reach is structural.

**Plan effect, if adopted.**
1. The program-store macro, needed in any case. It lands first.
2. 2.5 becomes two clusters, not two fixed cores: the same core module
   with resources addressed individually in the contract, and owner
   fields replacing structural lane ownership for bit-level resources.
3. The compiler gains a pack stage before placement (VPR's pack):
   protocol resources go into clusters under the word-domain constraint.
   R7 lowering then maps to resources, not fixed slots.
4. Two-shifter protocols (UART full duplex, I2C) lower to one cluster
   instead of waiting for step 2.6's two-lane pairing.

## 2.5 plan: two lane cores, ownership by construction, per-lane status

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

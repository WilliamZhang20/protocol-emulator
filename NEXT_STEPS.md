# Next steps and experiment status

**Goal:** replace the submitted design with the 5 × 3 grid as a protocol
CGRA: a fabric of protocol-pattern processing elements (timers,
serializers, line coders, checks, match, state, per-lane descriptor control,
streams) that a general compiler targets, so that protocols it has never seen
compile from source and run at the pins. Method: Betz's research flow
(architecture file, corpus, retargetable compiler, measure); evidence:
[PROTOCOL_CENSUS.md](experiments/grid_fabric/PROTOCOL_CENSUS.md).

- Hardware branch: `experiment/two-sram-placement` (5 × 3 grid, two SRAM
  macros); physical results come from the GDS CI run of each commit.
- Compiler: sibling `protocol-emulator-compiler`, `circt_lab/`; paging on
  branch `work/sequencer-paging`.
- Coverage evidence: [PROTOCOL_COVERAGE.md](experiments/grid_fabric/PROTOCOL_COVERAGE.md);
  temporal control: [TEMPORAL_CONTROL.md](experiments/grid_fabric/TEMPORAL_CONTROL.md).

## Finish line (2026-11-26)

### Where we are

| Gate | Status |
|---|---|
| Timing closure | Done: slow-corner setup +2.27 ns, hold positive (`18fd40a`). |
| Repeatable layout | Done: `18fd40a` and `7c9ee08` both pass GDS, precheck and post-layout GL. Re-check after each hardware step. |
| Sequencer capacity | Done: SRAM paging (`ffb3618`), descriptor rows (`f093ade`), second lane (`87f6674`). |
| Protocol coverage | 4 of 38 census protocols run at the pins, 7 more with workarounds, 12 need only compiler work, 15 are blocked by missing hardware. |
| General compiler | Not started for the grid: every running image comes from a per-protocol lowering. |
| Head-to-head, packaging | Not started. |
| Earlier fabric (baseline) | `arch/spatial`: 24 protocols at the pins, GDS passes; its data-capable controller is what the grid lacks. |

### What "done" means

0. At least the earlier fabric's coverage: a replacement that runs fewer
   protocols than the design it replaces is not a replacement.
1. Every census protocol that maps is compiled from `.spt` source by general
   lowering, with no per-protocol code, and passes its own tests at the pins
   in RTL and at gate level. Target: all 24 inherited protocols (the earlier
   fabric's set), at least 8 of the 14 held-out classes.
2. Held-out check: protocols written from specifications after the compiler
   freezes compile and pass with zero compiler or hardware edits; failures are
   classified (compiler gap or missing PE) and reported, not patched.
3. Physical: slack ≥ 0 at all corners, routing converges, precheck and
   post-layout GL pass on the submission commit; area tracked per step.
4. A head-to-head table against the earlier fabric (area by function, slack,
   protocols at gate level, host interface) records the decision.

### The lane-controller thesis, and what the redesign lost

The earlier fabric (`arch/spatial`; its controller was called PX8 there,
`src/controller.v` here) stated its thesis plainly:
tiles do all timing, and a tiny controller "loads the setup and makes the
step-by-step decisions, but it never drives a pin or times a bit"; every
block holds two setups. That is already the spatio-temporal middle Betz
argues for, and it covered 24 protocols at the pins (targets, receivers, CAN,
USB receive, HDLC, PPP, SLIP among them) on eight `uio` pins, with the host
link on `ui_in`, and it passes GDS (`016f736`; `arch/spatial8x4` `7dd2f41`).

The 5 × 3 redesign replaced that controller with a row sequencer that has no data
path, and moved the host link onto `uio[4:0]`. The census traces almost every
blocked protocol to exactly what that removed: decisions on received values
(`XRC`/`JZ`), counters and loops (`DJNZ`), data moves (`P`), per-block
setups, byte tiles, counters, and six pins. Its real gains are structural:
registered per-cell configuration distribution and registered validity
(timing closed, layout repeatable), paging and descriptor rows, a lane placed
in the fabric, credit-based streams, and a compiler routing model.

**Decision (2026-11-26): keep the grid, give each lane a lane controller
built from that controller.** Measured in local synthesis (same library): the controller
is 11.4k um2, one lane sequencer 25.9k um2 (its 16 x 16 row flops), a timer
4.8k, a shifter 5.2k, a switch box 1.4k per cell, the CRC tile 20.3k. The
The controller is the smaller and more capable control element: compare and branch on
received values, a loop counter, a data pointer, sticky events, block
configuration writes. The grid keeps everything spatial: timing tiles,
decentralized switch boxes, registered configuration tree. The row
sequencer, descriptors and paging retire once the lanes run on lane controllers;
lane B's placement, merged completion and the page loader's port borrowing
carry over.

Why the grid rather than the lineage's 64-wire signal space: local switch
boxes cost roughly per cell, a shared signal space roughly per tile times
lines, so the mesh is what makes more lanes affordable and routable. Step
1.6 measures this instead of assuming it.

Lanes are the replicated unit (Cerebras-style: own control, datapath,
memory port; the switch-box mesh between them). **Target: five lanes.**
Priority order for every decision: functionality, then a clean design;
area is measured and reported each step but is not a gate for now.

### Kept, dropped and new (thesis check, part 1)

From the earlier fabric (`arch/spatial`):

| Idea | Earlier fabric | Plan |
|---|---|---|
| Tiles time every bit; a controller decides and never drives a pin or times a bit | thesis | **kept**, enforced by a compiler rule and a determinism test |
| Decisions on received values, loop counter, data pointer, stream moves | PX8 instructions | **kept** as lane-controller operations |
| Sticky (latched) events, consumed by a wait | PX8 `WEV`/`CLREV` | **kept** |
| Two setups per block, switched at run time | `config_bank` per tile | **kept** as lane-owned live configuration writes through the configuration tree |
| Coded shifter: parity, stuffing, NRZI, Manchester, receive decode, CRC link | per shifter | **kept**, one per lane |
| Programmable CRC 1-32 | one tile | **kept**, one per lane |
| Host link on `ui_in`, eight protocol pins | yes | **kept** (restored) |
| Program held in SRAM; protocols as programs tested against peers | yes | **kept** |
| Formal reference model of the controller | `formal/` | **kept**, ported to the new encoding |
| The name PX8 and its encoding: one-byte ops, prefix chains, accumulator idioms | PX8 | **dropped**: fixed-width 16-bit lane instructions with named fields |
| One central controller for the whole chip | PX8 | **dropped**: one controller per lane |
| Global 64-wire signal space | yes | **dropped**: switch-box mesh |
| Byte tiles (escaping, filtering, checksums) | 8 tiles | **dropped**: escaping and filtering are lane-controller compares; checksums in the CRC tile's additive mode |
| Counter tiles | 2 | **dropped**: lane-controller counter and timer count mode |

From the 5 x 3 grid:

| Idea | Plan |
|---|---|
| Decentralized switch boxes, regular cells, compiler router | **kept**: lanes wind through the mesh |
| Registered per-cell configuration tree and registered validity | **kept**, and extended as the live-configuration path |
| Credit-based SRAM streams | **kept**, one pair per lane |
| Row sequencer, descriptor rows, SRAM paging, lane B as built, merged two-lane completion | **dropped** once lane controllers run (per-lane status replaces merged completion) |

### What a lane is

A lane is defined by ownership, not geometry:

1. **Lane core (hard, adjacent cells):** lane controller; timer pair with
   capture, resync, shadowed period and count mode; coded shifter; CRC tile;
   reader and writer stream port; latched event inputs; a readback window.
   These are fixed together because they exchange words (received data,
   stream bytes, live configuration), which the 1-bit mesh cannot carry.
2. **Soft tiles (anywhere):** extra timers, extra shifters (I2C's pattern
   shifter, JTAG's TMS shifter), LUT4 state cells and pad cells are placed
   by the compiler wherever they route; a lane's shape is whatever its
   routing takes, in any direction.
3. **Ownership:** the compiler assigns soft tiles to lanes; a lane
   controller writes live configuration only to cells it owns (an ownership
   table checked at the configuration tree) and reads only its core.
4. **Lanes communicate** through routed mesh signals (cross-lane events),
   never shared state.
5. **Host interface per lane:** start, done and error.

A lane is not a protocol: a protocol may use two lanes (separate transmit and
receive, a responder beside a controller), and a lane may drive no pins
(watchdog, supervisor).

### Floorplan

Heterogeneous columns, as in an FPGA: a column of five lane cores along the
SRAM side, columns of soft timers/shifters and of LUT4 state cells, pad
cells on the outer edge with a lane select each. Track count and column
sizes come from a concurrent minimum-channel-width sweep (step 4), not from
the current 4. Each lane core gets a placement region in the layout flow.

### The lane controller

A small state machine with data operations, fetched per lane:

- Fixed 16-bit instructions with named fields (no prefix chains):
  `wait event`, `act levels`, `fire pulse`, `branch if (received byte &
  mask) == K`, `loop with counter`, `pull/push stream byte`, `write own
  configuration word`, `read core register`, `halt ok/fail`.
- Built from `controller.v`'s datapath and its formal reference model;
  the compiler's existing backend for that controller keeps its lowering and
  gets a new encoder.
- **Thesis rule:** an `act`/`fire` never produces a timed edge. Every edge
  with a timing requirement comes from a tile (timer, shifter, coder); the
  compiler rejects lowerings that violate this.

### Thesis check, part 2: every named gap traced to a fix

| Gap (protocols blocked / workaround) | Fix | Step |
|---|---|---|
| Value match, 11 blocked (I2C/SPI/Modbus targets, CAN/USB/HDLC receive, SWD, SD, LIN, PPP, SLIP) | lane-controller compare-and-branch on the received byte; escaping and filtering in the controller | 1 |
| Respond in window (7) | controller decision latency bounded by fetch: a per-lane local instruction buffer for responder programs | 1, 4 |
| Pins, 3 blocked + 4 workarounds (SPI, JTAG, I2S, VGA, SPI target, GPIO chain, SD) | host link on `ui_in`, eight pads with lane select | 3 |
| Receive line decode, 3 blocked (USB, CAN, HDLC receive) | coded shifter receive path in every lane core; timer resync for clock recovery | 2 |
| Parity, 2 blocked + 3 workarounds (SWD, I3C, PS/2, LIN PID) | coded shifter parity in every lane core | 2 |
| Additive checksum (LIN) | CRC tile additive mode | 2 |
| Capture (LIN autobaud) | timer capture, read by the controller | 2 |
| Duration from data (SENT) | controller writes the timer's shadowed period, applied at the next reload | 2 |
| Tile-parameter contexts (CAN FD bit-rate switch, I3C drive mode) | live writes to own timer periods (shadowed, bit-exact) and own pad mode | 2, 3 |
| No general compiler (12 mappable, 4 running via per-protocol code) | retargeted backend, cluster placement, routing, LUT mapping | 5 |
| Concurrency | five lane cores, each with its own coder and CRC; limited by pins (8) and SRAM bandwidth | 4 |

Holes found by the check, now in the steps:

1. **Response-window latency.** Five lanes fetching from two single-port
   banks can delay a decision past an SPI-target byte boundary. Fix: local
   instruction buffer per lane; acceptance includes a worst-case
   decision-time bound per responder protocol.
2. **Thesis violation by jitter.** Fetch stalls shift `act` timing. Fix: the
   compiler rule above, and a determinism test that randomizes SRAM
   contention and requires identical pin waveforms (as the earlier fabric's
   `test_determinism.py`).
3. **Clock recovery** needs a timer resync input (restart phase on an edge,
   optionally only inside a window); now part of the timer.
4. **Bit-exact parameter switches** need shadowed timer periods applied at
   reload; now part of the timer.
5. **Live writes to soft tiles** go through the configuration tree with an
   ownership check (3-cycle latency), so no separate word network is needed.
6. **Census omission:** PPP and SLIP (byte escaping) are now in the census
   and covered by step 1.

Objectives, checked: the earlier fabric's thesis (kept, enforced); coverage
of at least its 24 protocols (every gap above has a fix and an acceptance
test; proven only by step 7); held-out protocols through the compiler (step
5, then a frozen-compiler run); spatial advantage (mesh scaling measured in
step 1.6, lanes routed through it); simultaneous protocols (five
self-sufficient lanes); physical closure (checked every step).

### Roadmap (concrete)

Every step ends with: regression, local area (reported), push, GDS,
2-hour CI check.

**1. Lane controller in today's grid (one lane).**

Status (2026-11-26), one sub-step at a time; the next starts only when the
previous one is sturdy:

| Sub-step | Status |
|---|---|
| 1.1 `src/grid_lane_controller.v` | **Done.** 16-bit instructions, 64-instruction local buffer loaded at start (no fetch at run time, so decision time is fixed), 8 latched pulse events + 8 live levels, 16 readback words, live writes fenced to context words 112-116; buffer depth is a parameter. The proof found three bugs, all fixed: outputs live while disabled, FIRE fell to the fail case, outputs decoded past the program end. |
| 1.2 formal reference model | **Done.** `formal/lane_controller/`: an independent ISA model over a symbolic 4-instruction program at a symbolic base, arbitrary start/abort/enable, events, levels, readback, stream handshakes and port stalls. Every controller register is asserted equal to the model's, so k-induction proves every output prediction for all time (8 s); 6 covers reached; 7 injected RTL bugs all give counterexamples (`make -C formal lane_controller-mutations`). Bounded checking alone did not scale (1.6x per step, 3 engines timed out at 10 min), hence induction. CI: `grid formal` job on every push (30-minute limit) runs this, the mutations, `fabric_shifter` (6 min) and `fabric_crc` (12 s). |
| 1.3 fabric select | **Done.** Full regression green (lint, contract, synth, gds-config, all grid tests, 24/24 cocotb on Verilator and Icarus). Word 91 bit 2 selects the lane controller instead of the row sequencer (bits 0 and 2 together are invalid); word 95 = `{last[5:0], base[9:0]}`. The lane drives the grid's actions, start and tx word, borrows memory client 0 for its program load, pulls/pushes through the stream reader and writer, and writes context words 112-116 live. `test_lane_controller.py` (pins only): XOR-transform stream of 6 bytes (51 clocks after load, rerun on new data), a live write releasing SDA mid-run then restored, a refused write, a fenced write, and the row sequencer still selectable. Found and fixed: a live write that duplicated a sink or set reserved bits dropped grid validity, which silently disabled the whole fabric mid-run. Now grid_core checks each live write against the static rules (`ctx_word_ok`: word valid, no other override on its sink); a refused write fails the transfer and nothing changes. Formal: `cfg_ok` is an arbitrary input in the model, plus a sixth mutation (refused value still written), all caught. Follow-up: sequencer page loads write contexts unchecked the same way (pre-existing; dropped with the row sequencer in step 3, so not fixed there). Assembler: `test/cocotb_tests/lane_asm.py`. |
| 1.4 pin tests | In progress, split so each part is sturdy before the next: **1.4a Done.** `WANY m` wait-any instruction (opcode F, was reserved): waits until any latched event in mask `m[7:0]` is set, A = the set bits, consumes them; reserved bits or an empty mask fail. Proof passes with a 7th cover (partial-mask hit) and a 7th mutation (WANY clears every latch), all caught; pin test `lane_wait_any` tells an SDA edge from an SCL edge. Gap found designing the I2C target, which must wait for "byte done" or "STOP" at once; polling cannot see a latched edge. Controller, reference model, mutation, assembler. **1.4b Done.** Lane image generator in the compiler (`circt_lab/grid_lane.py`, branch `work/lane-controller` 8e9f355): a `spatial.lane-design.v1` file (nets, tile settings, idle actions, program source, program base) becomes a .mem plus a .program.json, routed by `grid_route.py`, sharing `route_words()` with the temporal encoder (temporal output unchanged byte for byte). Every number comes from the contract's new `lane` section (`architecture/grid_3x3.json`), which `make grid-contract-check` checks against the elaborated RTL (instance, event/level/readback widths, buffer depth, mode and program words, write fence, opcode table) and which rejects 5 lane mutations. `test_grid_lane.py`: assembler equals the RTL test assembler word for word, contract names (`event:`, `level:`, `readback:`) resolve, 8 bad programs refused, lane image routes exactly like the temporal image. Images will be checked in under `test/data/lane/` with their generator command, starting with 1.4c. **1.4c** I2C target, write: START, address match (NACK on mismatch), ACK per byte, bytes to the stream, STOP; pin test against a host-side controller model. **Done.** Full regression green (every target, 29/29 cocotb on Verilator and Icarus, tile experiment with restart checks). Also fixed the test helper: `Chip.configure` from an armed chip silently dropped every image write (configuration mode is only taken while disarmed), so it now disarms first. Design `circt_lab/lanes/i2c_target.json` (compiler 2aa313d): 35 instructions, 6 routes, built to `test/data/lane/i2c-target.*`. `test_lane_i2c_target.py`: skip a foreign address then ACK and store a 5-byte write, two back-to-back runs, seeded random addresses/payloads/bus speeds (RTL only). Three gaps found and fixed: (1) a STOP right after the next byte was armed left shifter0 busy forever (start was ignored while busy, only disarm cleared it). A receiver must be able to resynchronize, so shifter word bit 6 (words 2 and 55) now selects "a start while busy restarts the word"; it is opt-in because an unconditional restart broke the UART images, whose receiver is started by every RX edge (caught by the full regression). Tile test covers both settings; the contract describes the fields and the checker ties them to the RTL; without the bit the back-to-back test hangs, with it it passes. (2) Lane runs did not close their streams, so a run that left capacity unused made the next run write after the old bytes; a run now finishes only when its pushed bytes are in SRAM, then both streams close. (3) PUSH past capacity or PULL past the source waited forever; both now fail the transfer (controller output `rd_want`, proved), pin test `lane_stream_limits_fail`. **1.4d** SPI target without CS (mode 0, MISO from the shifter). **1.4e** SLIP-escaping UART TX (END/ESC substitution decided per byte by the lane). **1.4f** determinism: each of the above with random SRAM-port contention gives identical pin traces. |
| 1.5 fetch/decision measurement | Not started. |
| 1.6 mesh vs signal space | Not started. |

1. `src/grid_lane_controller.v`: the 16-bit instruction set above, built
   from `controller.v`'s datapath; fetch through the host-bank client with
   ready/valid stall and a local instruction buffer; 16 sticky events;
   16-entry readback; `act`/`fire`; live configuration writes limited to
   owned cells; streams; halt ok/fail.
2. Formal reference model ported from `formal/` (`arch/spatial`) to the new
   encoding; bounded proof of fetch, events, readback and the write fence.
3. `grid_stream_fabric.v`: control select (row sequencer or lane
   controller) so existing images keep running until step 2 removes it.
4. Pin tests: I2C target, SPI target, SLIP escaping; determinism under
   random SRAM contention.
5. Measure fetch occupancy and worst-case decision time.
6. Measure switch-box mesh against the earlier 64-wire signal space at
   1, 3 and 5 lanes.

**2. Lane core and soft tiles (two lanes).**

1. Timer: capture, resync (windowed), shadowed period, count mode.
2. `src/grid_lane_core.v`: lane controller, timer pair, coded shifter
   (parity, stuffing, NRZI, Manchester, receive decode, CRC link), CRC tile
   with additive mode, stream port, events, readback.
3. Configuration tree: live writes from lane controllers with the ownership
   table; per-lane start, done, error in the host status.
4. Two lane cores plus today's soft tiles; pin tests: UART receive on lane
   B during I2C on lane A; USB low-speed receive; CAN receive; PS/2 with
   parity in the coder; SENT; LIN with autobaud and checksum.
5. Remove the row sequencer, descriptors, paging and merged completion.

**3. Host link and pads.**

1. `project.v`: host link on `ui_in` alone (`ui[7]` strobe, `ui[6:4]`
   opcode, `ui[3:0]` data), status on `uo_out`; `uio[7:0]` all pads.
2. Eight pad cells with lane select and lane-writable drive mode.
3. Host helpers (`command()`, `test_compiled.py`), `info.yaml`.
4. Pin tests: SPI with CS on a pad, 4-wire JTAG, SPI target, GPIO chain,
   I3C drive-mode switch.

**4. Five lanes and the floorplan.**

1. Concurrent minimum-channel-width sweep with the existing router: five
   census protocols at once; set track count and soft-tile columns from it.
2. Five lane cores, soft-tile columns, configuration leaves per cell,
   arbiter for host plus three clients per lane; local instruction buffer
   size from step 1.5.
3. Placement regions per lane core; GDS checkpoint.
4. Pin test: five protocols at once (UART, I2C, 1-Wire, WS2812, DMX), each
   checked by its own peer.

**5. Compiler.**

Replace protocol-specific recipes with general CIRCT lowering, placement, routing and scheduling against the architecture contract.

1. New encoder for the lane controller; lowering kept from the existing
   backend.
2. Lane assignment (a protocol may take two lanes), cluster placement of
   soft tiles, mesh routing, configuration words from the contract.
3. `reg` expressions to LUT4 cells; `if received == K` to compare-and-branch;
   the timed-edge rule.
4. Resource report and unmappable-construct diagnostics.
5. Accept: the six running protocols compile and pass; delete the
   per-protocol `circt_lab/*.inc` lowerings and `descriptor_fold.py`.

**6. Evidence and submission.**

1. Port all 24 inherited tests to grid pins, compiled from source; record
   per-protocol status in PROTOCOL_COVERAGE.md; regenerate the census.
2. Freeze the compiler; held-out classes from specifications; report
   pass/fail with classified causes.
3. Five-lane concurrency demo; head-to-head with `arch/spatial`; Tiny
   Tapeout packaging; final precheck.

## Foundations: spatial-architecture direction (2026-11-24)

Sources: V. Betz, *Spatial Computing Architectures: Opportunities and CAD
Flows in the Deep Learning and More-than-Moore Era*, ICCAD 2026 keynote
(<https://www.eecg.utoronto.ca/~vaughn/papers/iccad26_dl_and_spatial_keynote.pdf>),
and H2PIPE (Doumet et al., FPL 2024, arXiv 2408.09209), which appears in the
keynote as one example.

### Framing: a spatio-temporal architecture

Protocols are spatial at the bit level (timers, shifters, CRC and pins run in
parallel with exact cycle timing) and temporal at the packet level
(sync → PID → data → CRC → EOP; start → address → ACK → data → stop). The
branches have sat at the two ends of the keynote's spatial/temporal spectrum:
`main`/`8x4` use a CPU with instruction fetch (temporal, an overlay), while
this grid is fully spatial, and its temporal control returned as two
hand-written state machines in `grid_unified.v`. Target the middle, as
Cerebras does:

- **Spatial layer:** a static bit fabric with registered hops for everything
  timing-exact.
- **Temporal layer:** a small per-lane sequencer executing **descriptors**,
  not instructions. One descriptor covers a whole field ("stream N bytes, CRC
  on, stuffing on, then emit CRC"), following the keynote's NPU lesson of
  amortizing control. A descriptor may switch the lane's routing/config
  **context** between phases. `fabric_timer.v` still has `config_bank`
  contexts (`ctx_next`); the grid dropped them, which is why it needs adapters.

### Ideas to apply

| Source idea | Application here |
|---|---|
| Programmable routing for logic plus a hardened NoC for system traffic | Keep 1-bit static tracks for timing signals. Replace the wire-alias word links in `grid_memory.v` with a small word mesh with a register at each router and colours = stream IDs. Do not time-multiplex bit tracks (adds jitter). |
| Direct block-to-block links (VTR) | Dedicated neighbour links for timer→shifter pairs. The UART image's shift clock currently crosses 3 hops. |
| Hard blocks vs soft fabric | Harden by corpus frequency. The 8x4 census found logic cells binding, mostly spent on stuffing and sequencing glue; the bit coder was the right move. The LUT is for leftover glue only. |
| VTR research flow: architecture file, benchmarks, retargetable CAD, area/delay models | This is the laboratory (steps 2–4 below). Use VTR's minimum-channel-width method: find the smallest track count W at which every corpus protocol routes per layout, then size at about 1.3×W instead of guessing 4. Evaluate VPR as the mapper's placer/router on the 5×3 before writing a custom one. |
| Architecture file → generated fabric (OpenFPGA) | Generate `grid_core` from the architecture file (dimensions, tile type per cell, track count); today cell positions and config addresses are hard-coded. Use OpenFPGA's scan-chain configuration as a reference, not the tool itself (generic LUT fabric would exceed the TT area budget). |
| "A pipeline is as slow as its slowest stage" (HPIPE) | The mapper reports each stage's slack against the protocol's wire rate. |
| Choose your precision | Shifter width 1–16 and CRC width 1–32 already do this; also make the bit/byte split a mapping choice. |
| Streaming dataflow: fire on data arrival, latency-insensitive | Word-level firing rule: a shifter starts when its stream FIFO has a byte and the timer ticks; when the chip drives the clock, a stall feeds the timer's `hold` input. |
| Programmable I/O tile | Make pad logic (synchronizer, edge polarity, open-drain, feedback) a uniform edge I/O tile type. It is currently split between `project.v` and `grid_core`, and CS never reaches a pad. |
| Open problem: evaluation tools for spatio-temporal architectures | The laboratory is an instance of this; present it as a contribution. |

Does not transfer: wafer-scale redundancy, multi-chip pipelines, 3D
stacking, learned LUT functions, and layer pipelining's throughput-for-latency
trade. Reply latency (USB turnaround, I2C ACK window) is a correctness
constraint.

### H2PIPE lessons for the memory path

- Characterize under contention, not idle: SRAM arbitration latency with host,
  TX and RX competing; per-hop route delay after place-and-route; pad timing.
  Report each protocol against its wire-rate floor and an unlimited-resource
  bound, plus a data-movement metric (Σ hops × toggle rate).
- SRAM bandwidth is not the limit: one bank gives 1 byte/cycle (50 MB/s)
  against ≤ about 3 MB/s for a clk/2 serial stream. The second bank is
  justified by capacity, independent ports or locality only.
- Predictable streams run ahead: replace both adapters with a generic
  **stream reader** (base, length, credit counter, FIFO) and **stream
  writer**; SPI becomes TX plus RX streams like UART, removing the mode bit.
  FIFO depth = ⌈worst latency / byte period⌉ + 1 ≈ ⌈4/16⌉ + 1 = 2 (today 4).
  For data-dependent replies (ACK/NAK, I2C register reads) prefetch both
  candidates.
- Credits, not valid/ready, where streams share a bank's return path (avoids
  the head-of-line deadlock in H2PIPE Fig. 5). The UART engine is already a
  one-credit scheme; generalize to per-stream credits.
- Stall locally: classify streams as stallable (chip drives the clock: stall
  via timer `hold`) or real-time (far side drives the clock: rely on the
  latency bound).
- Configuration is used once, so make its path narrow: a shift chain through
  the tiles with legal-by-construction encodings.

### Findings from reading the grid RTL

1. Routes in `grid_switch` are combinational across several hops (and through
   the LUT), dropping the 8x4 "every line is a register output, one hop per
   cycle" rule. Timing depends on configuration. Registering each interior
   switch output costs 24 links × 4 tracks = 96 flops (≈4.7k µm²); the
   mapper matches skew (SCK vs MOSI) and adjusts with the timer `first`
   register.
2. `grid_word_link` is a plain `assign`; after flattening, the "spatial" word
   path is one net the placer can put anywhere. Register at tile boundaries.
3. `cfg[0:62]` keeps about 450 flops (estimate, not synthesized; ≈20k µm²)
   only because `configured` checks unused upper bits, plus duplicated timer
   first/period words.
4. The SPI adapter moves at most 16 bits per host start; UART streams.
5. Timer 0 at (0,2) is 3 hops from shifter 0 at (1,0). Placing timer 0 at
   the centre (1,1) makes it one hop from both shifters and the output pins.
6. Smaller: `pins[2]` (CS) never reaches a pad; host SRAM access requires
   `arm`; TX/RX/SPI base addresses are limited to bytes 0–255.

### Memory banking and distribution

- **Bandwidth does not justify banks.** One bank gives 1 byte/cycle; a fast
  serial stream needs at most one byte per 16 cycles. With round-robin
  arbitration N streams see about N+2 cycles worst-case latency, so a depth-2
  FIFO holds up to about 14 streams per bank. Even 8x4 with every lane active
  does not need banks for bandwidth or latency.
- **Capacity is the real limit.** `grid_unified` rejects `tx_end > 1024` and
  routes each requester to one bank, so a full Ethernet frame (up to 1518
  bytes; 10BASE-T is in the 8x4 corpus) cannot be sent or received. Streams
  must address (bank, offset) and continue into the next bank; 11-bit lengths
  already allow it.
- **Locality is secondary once word hops are registered:** a distant bank
  costs a few cycles of latency, not timing. Per-lane banks would buy only
  isolation (no cross-lane latency interference) and shorter SRAM-pin nets,
  at about 49k µm² per macro plus keepouts and PDN work. Hand-moving SRAMs on
  6x4 broke DPL/PDN (`016f736`).

Plan:

1. Bank count is an architecture-file parameter. Stream tiles address
   (bank, offset), so shared-pool versus per-lane banks does not change the
   programming model.
2. Explicit, compiler-placed buffers, no global address space (Cerebras:
   explicit data movement; H2PIPE: compiler assigns layers to HBM channels).
   The mapper places each buffer by capacity and distance to its lane, then
   checks the latency bound.
3. Three levels: flops (FIFOs, headers, CRC state), optional small scratch in
   each stream tile, shared SRAM for payloads.
4. Keep two banks until the laboratory, extended to report capacity and
   contention per protocol and lane, shows a corpus protocol failing for
   lack of capacity or isolation.
5. Check which other IHP SRAM sizes the Tiny Tapeout flow supports; denser or
   narrower macros change the per-lane versus shared comparison.

### Word mesh

The word-level interconnect between SRAM and lanes, separate from the 1-bit
tracks.

- **Address generation sits beside the SRAM** (Plasticine's memory-unit
  pattern): the stream reader/writer engines live in the SRAM tile, so only
  data words travel (8 data + valid + stream ID, plus a credit return wire),
  never addresses.
- **Each hop is a register.** Latency equals hop count, timing is local
  regardless of distance.
- **Static, compiler-assigned routing.** Preferred: each stream owns a
  dedicated word lane on each link it uses (a registered, word-wide version of
  `grid_switch`), so there is no contention and latency is exact. Only if the
  corpus needs more streams than lanes: share links with a stream-ID route
  table and output arbitration, with end-to-end credits so words never block
  inside the mesh.
- **Build only the links the corpus needs.** A full 2D mesh on the original 3×3 is
  24 directed links × about 11 flops ≈ 264 flops (≈13k µm², close to a CRC
  tile). A registered chain from each SRAM along its row or column to the
  lanes (H2PIPE's daisy chain) is likely enough, especially on 8x4 with one
  lane per row.

### Implementation order for the findings

Grouped so that image-breaking changes regenerate the SPI/UART images once.

0. **Baseline:** synthesize `grid_core` to check the ~450-flop estimate; run
   GDS on the current unified top.
1. **Low-risk cleanups (images unchanged):** validate config on write and
   store only fields plus a valid bit; drop duplicate timer words; allow host
   SRAM access while disarmed; widen TX/RX/SPI base addresses to 10 bits. CS
   to a pad needs a pin decision first (every `uio` pin is used).
2. **Registered hops plus timer 0 at the centre (findings 1 and 5) as one
   batch:** 96 flops, timer 0 to (1,1) and LUT to (0,2), mapper skew
   compensation via timer `first`; regenerate images once.
3. **Stream reader/writer tiles (findings 2 and 4) and memory:** at the SRAM
   tiles, credit-based, FIFO depth 2, registered word chain to the lanes,
   (bank, offset) addressing with cross-bank streams; SPI becomes TX plus RX
   streams, deleting the SPI state machine and mode bit.
4. **Per-lane descriptor sequencer plus config contexts,** removing the rest of
   the adapter logic. Status (2026-11-26) and order for the rest:
   - Done: program storage in local SRAM (paging, `ffb3618`, compiler on
     `work/sequencer-paging`); a second lane placed in the fabric (lane B,
     cell 13, `87f6674`): mesh-routed actions and events, merged completion,
     I2C bus-watchdog pin test. Lane B is still the instruction-style row
     table, so it distributes the bottleneck rather than removing it, and
     costs +29.6k um2 (+8.5%), mostly row flops.
   - a. **Descriptor row format, shared by both lanes** (the keynote's
     amortized control). Done: phases and entry-wait rows (see
     TEMPORAL_CONTROL.md "Descriptor rows"), exact folds of row pairs; an
     entry-wait with a frame request and `frame_done` runs one stream field.
     Folding saves 2 rows per program in the tree (I2C 14 to 12, write-read
     15 to 13, SPI 7 to 5) for +1.3k um2. A count field was dropped: no
     program waits on repeated events. The fold lives in
     `test/cocotb_tests/descriptor_fold.py` until the compiler adopts it (d).
   - b. **Per-lane contexts,** so each lane switches only its own routing.
   - c. **Generalize the lanes** onto the descriptor format; lane B's fabric
     placement and completion logic carry over.
   - d. **Compiler** targets the descriptor format only after (a) is fixed,
     so the lowering and pager are not redone.
   - Harden by corpus frequency only if a descriptor field still needs
     several rows.
5. **Config shift chain (finding 3 full version),** once the tile set is
   stable, since it changes the host protocol and cocotb harness.

In parallel from step 2: the minimum-track-width sweep in the laboratory, and
capacity/contention reporting for the banking decision.

Pitch storyline: protocols are spatial at the bit level and temporal at the
packet level → static registered bit fabric, word mesh to SRAM stream ports,
descriptor sequencer per lane → generated from one architecture file and
evaluated VTR-style against a protocol corpus (minimum track width, wire-rate
slack, hop counts).

## History

Older plans, superseded by the finish line above and kept for their reasoning.

### Earlier planning notes

0. Clean up the loose ends (one session).

- Decide the uncommitted two-input actor RTL change: commit it or drop it.

- Land or close compiler PR #6.

- Move Codex's uncommitted compiler pile onto its own branch.



Why first: right now nobody can tell what's real. Every later step is cheaper on a clean base.



1. Objectives (half a page, from you).

Why: they decide what the laboratory measures and how agents judge. Without them, step 4 is opinion.



2. Arch file: turn today's hardware constants into data.

The existing backend reads counts, sizes, memory banks/ports, FIFO depth and latencies from current.arch instead of hardware.rs.

Why early: it's small, mechanical, and unblocks everything else.

Caveat: the signal-space line numbering is derived from tile counts, so the encoding has to be computed from the file rather than hard-coded. That's the real work in this step.



3. Laboratory v0, on the existing backend.

Compile the example corpus against any arch file and report fit, resource use, memory requests and contention, and wire-rate margins.

Why before the IR: many of your open hardware questions only change parameters (more shifters, SRAM banks, buffer sizes, FIFO depth). The current backend can answer those once it's parameterized. You get evidence in weeks, not after a rewrite.



4. Run the agent loop on the memory question.

Why memory first: you raised it first, it's the most concrete question, and there's already trace data to start from. It also tests the loop end to end on a real decision.



5. IR and mapper rewrite.

Why this late: it's only needed for structural changes: new tile types, a coherent fabric, width as a mapping choice. Doing it after steps 3–4 means the primitive set is designed against architectures that are actually on the table, not guessed. Designing the IR first is how we'd build the wrong one.



6. Structural hardware changes through the loop: fabric coherence, then width.



Throughout: the chip stays programmable. Every step keeps the existing RTL tests passing.



One thing would reorder this: a tapeout deadline. If there is one, step 4 and any parameter-only RTL changes move ahead of everything else, and step 5 slips past the deadline. Is there one?



What changes



- Mapping means compiling a program into a configuration of a given chip (image, tile configs, selectors, controller code), like VTR placing a netlist onto a fixed FPGA. It never produces Verilog.

- The architecture laboratory never touches RTL. It answers "if the chip had X, would the corpus compile, fit and meet timing?" Agents read that evidence, judge it against objectives and rules, and propose hardware changes. Those changes get written by hand in RTL.

- CIRCT/MLIR drops out for now. Its main payoffs were RTL generation and simulating unbuilt hardware, and you've ruled out both. The IR can be plain Rust data structures with MLIR-like discipline: typed values, a checker at each level, explicit lowering steps. Less to build and maintain.



The specs



1. Compiler (one system).

.spt → program IR → mapping (primitives → tile types → tile instances → signal routes → memory layout) → chip configuration.

- The IR's operations are fabric-independent primitives; widths are type parameters; no operation copies a current tile.

- Mapping reads an arch file and nothing else about the hardware.

- Done when every example compiles through it to the same configuration as today's backend, and its RTL tests pass. Then the current backend is deleted.



2. Arch file (the only interface between hardware and software).

- Start by turning hardware.rs into data: tile types (which primitives each implements, width, latency), counts, signal-space/interconnect rules, memories (size, banks, ports), FIFOs, pads.

- The current chip is current.arch. A candidate is a copy with edits.

- Done when the compiler reads all hardware facts from it, with zero hardware constants left in code.



3. Laboratory (evidence, no judgment).

(arch file, workload corpus) → report:

- per program: fits or not, and why;

- resource use;

- memory requests and bank contention (Codex's memory_model slots in here);

- latency and throughput bounds versus the protocol's wire rate.



Done when the current.arch report agrees with measured RTL runs.



4. Agent arch loop (judgment, no software).

Objectives + rules → agent proposes an arch-file edit → laboratory report → accept or reject with written reasoning. An accepted edit becomes a hand-written RTL change, then synthesis/GDS calibration, then current.arch is updated. The "hillclimb" is this written procedure, not code.



Hardware threads Codex raised but never followed up



1. Memory. Try small local stream/row buffers first. Banking the main SRAM only pays off once traces show competing independent requests. Two stored UART streams already run within 0.86% of their two-wire timing floor.

2. Fabric coherence. Define a common tile interface and group tiles around protocol work. Renaming groups alone gains nothing while the global 64-line signal space remains.

3. Width. Make the byte-level/bit-level split a mapping choice, not an architectural layer.

4. Loose ends: the uncommitted two-input actor RTL change, and compiler draft PR #6.



These become the first arch-file experiments in step 4, once 1–3 exist.



What I need from you



The fundamental objectives the agents judge against. My draft:

1. Protocol coverage: which protocols must fit.

2. Wire-rate and latency guarantees.

3. Area/timing budget for the Tiny Tapeout tile.

4. Simplicity of programming.



What's missing, and what's the priority order?



Once you confirm, I'll write spec 1 (IR op set) and spec 2 (arch file schema), each about a page.

### Cleanup status — 2026-11-22

- Compiler PR #6 was merged as `14ddd5f`; its CI passed the example RTL suite.
- Compiler architecture experiments are preserved on local branch
  `work/architecture-laboratory-wip` in commits `8338e15` and `d2c8de2`.
  The implementation checkpoint is large and remains experimental.
- The expanded actor ABI is a separate hardware experiment, not the baseline.
  Full RTL regression passed 134/134; generic actor synthesis grew from 298 to
  632 cells, so routed measurements and workload justification remain open.
- Compiler baseline `main` targets hardware revision `7dd2f41` (actor ABI 1).
  The compiler WIP's actor images target ABI 2 and need matching experimental
  RTL. See `docs/architecture-triage.md` for details.

### Fabric redesign: hardware, compiler, and test plan

**Target:** a structured, heterogeneous 2D fabric grid with configurable
connections and a programmable temporal layer. The compiler maps protocol
operations onto reusable tiles, routes their signals, and schedules their
runtime phases. The precise layout, switch connectivity, and temporal control
are experimental choices constrained by protocol coverage, timing, and area.

The stream reader/writer and cross-bank addressing are parts of the same memory
subsystem: one moves data, the other extends where streams can access it. They
share interfaces, arbitration, compiler allocation, and tests. The current
stream changes are uncommitted work in progress, not a completed architecture.

#### Design requirements

- **Switches:** compiler-selectable tile connections, turns, and fanout where
  workloads need them. Compare track counts, connectivity, direct links, and
  pipeline placement instead of assuming either the current switch or a fully
  connected switch is sufficient. Registered hops cost area and cycles; their
  timing and skew must be represented by the compiler.
- **Temporal layer:** programmable sequencing, input events, branches, and
  configuration contexts where useful, without a hard-coded controller per
  protocol. Evaluate a compact field-level sequencer, its operation set,
  response latency, number of lanes, and storage. Descriptor storage and any
  SRAM fetching are explicit design choices, not free consequences of naming.
- **Width:** support protocol fields of different bit widths through tile and
  routing choices. Byte streams are a memory transport convenience, not a
  requirement that all fields be byte-sized. Bit-banging alone does not solve
  parallel-width or throughput requirements.
- **Memory:** consider SRAM capacity, placement, bank contention, stream
  ordering, and real-time service together. Size FIFOs using measured or proven
  latency bounds, including routing and bank crossing; a depth of two is a
  hypothesis under specific traffic assumptions, not a universal guarantee.
- **Area and timing:** establish the actual Tiny Tapeout baseline, including
  SRAM macros, standard cells, routing overhead, and margin. For each candidate
  report area by function, timing, physical feasibility, and protocol coverage.
  Existing estimates for registered links and the word mesh require measurement.

#### Staged work and decision gates

1. **Baseline and finish the current memory experiment.** Inventory the
   uncommitted hardware and compiler work, complete the interrupted regression,
   synthesize it, and compare against the committed grid. Exercise cross-bank
   ordering, credits under contention, and pin-level behavior. Measure area and
   retain, simplify, or discard changes based on evidence. **Done locally:**
   retain the stream experiment as the experimental baseline; see its
   [inventory, validation, area comparison, and limits](experiments/grid_stream/BASELINE.md).
   Physical validation of the current work remains outstanding.
2. **Establish a shared architecture contract.** Describe tile instances and
   capabilities, ports, switch choices, link latencies, bank capacity,
   configuration, and temporal operations. First represent the actual RTL;
   generate hardware from the model when the contract is stable. The compiler
   reports placement, routes, schedule, memory use, and resource visualization.
   **Local contract baseline:** [grid_3x3.json](architecture/grid_3x3.json)
   and `make grid-contract-check`. The sibling CIRCT lab exports an abstract
   grid target and checks SPI/UART images against this contract. The target
   graph deliberately overapproximates routing and does not model word streams
   or the fixed scheduler; its schedules and touched addresses are not verified
   transaction timing or buffer allocations. Hardware generation and richer
   mapper fidelity remain later work, not proof of protocol fit.
3. **Compare topology and switch candidates.** Sweep a small set of layouts,
   track counts, switch connectivity, direct links, and selective registered
   paths against the same protocol corpus. Report routing success, latency,
   area, timing, and physical feasibility. Distinguish missing hardware from
   compiler mapping limitations before choosing modifications. **Initial
   experiment complete:** keep the current four-track placement as the
   baseline. A center-timer RTL candidate passed physical and gate-level CI,
   but used more cell area and had less setup/hold slack in the measured run.
   [Results and limitations](../protocol-emulator-compiler/circt_lab/GRID_TOPOLOGY_EXPERIMENT.md).
   The six routed cases are component/connection slices, not full USB/Ethernet
   or general protocol compilation; source/control and memory lowering remain
   open. Registered and direct-link candidates are model-only.
4. **Implement and test programmable temporal control.** Start with an I2C
   source-driven transaction covering START, address, ACK/NACK, clock stretch,
   data, and STOP. Measure sequencer and context costs and response timing;
   preserve SPI and concurrent UART as regressions.
5. **Extend protocol coverage on the same fabric.** Reuse the JTAG, CRC, and
   line-coding work where appropriate. Target explicit USB and Ethernet subsets
   first, such as USB low-speed transmit and 10BASE-T digital transmit, then
   expand. These milestones alone do not prove complete standards or physical
   interface support.
   **Functionally complete (RTL pins and generic gate level):** SPI
   `transfer()` and I²C `write_read()` (repeated START, reads, NACK, clock
   stretching) compiled from their whole source functions onto the sequencer,
   UART streams, I²C write, JTAG TAP, USB low-speed DATA0 transmit, Ethernet
   frames up to full MTU and the whole 10BASE-T `transmit()` link session (link
   pulses, frame, TP_IDL) compiled from source. A generic runner
   (`test_compiled.py`) replays each compiled program's own source tests at the
   chip pins with specification-written peers. The session needed a grid extension
   to 5×3 (two timers, four registered LUT4 cells, routed sequencer events);
   earlier images are unchanged. See the
   [coverage record](experiments/grid_fabric/PROTOCOL_COVERAGE.md). The
   physical (GDS/precheck/post-layout GL) result for the extended grid is the
   remaining gate.

**Acceptance gate:** one hardware design, configured by compiler-generated
programs, runs the agreed SPI, UART, I2C, JTAG, USB, and Ethernet workloads
at their required pin timings within the area budget. For every workload report
separately whether it is parsed, mapped, validated at RTL pins, and validated
at gate level or physically. Physical checks should run alongside development
without blocking unrelated compiler and functional work.

### Path to replacing the submitted design with the 5 × 3 grid (2026-11-25, superseded by the finish line)

The grid becomes the submission only when every gate below holds on one
commit; until then `main` stays the fallback. Status at `4b71ece`/`18fd40a`:
DRC/LVS/antenna clean, gate-level test passed, setup −1.13 ns at the slow
corner (fix in CI), sequencer rows full for I²C.

1. **Timing closure.** Setup and hold slack ≥ 0 at all three corners. The
   −1.13 ns paths ran from reserved config bits through the combinational
   `configured` check; `18fd40a` registers validity and delays arm. Treat any
   path that starts at a configuration register as a structural defect, not
   a resizer problem.
2. **Repeatable layout.** Two consecutive GDS runs finish with detailed
   routing converging (no stalls), plus precheck and post-layout GL passing.
   Track routed wirelength, overflowed tiles and runtime per commit.
3. **Routing headroom.** Measure per-net routed length from the final
   database (the earlier reach-based estimate overstated the config bus).
   Then remove the ~6.9k hold-fix delay cells at their source and the tie
   cell per no-reset flop.
4. **Temporal sequencer capacity.** I²C `write_read` uses all 16 rows;
   Ethernet session and temporal I²C use 15. Decoding the programs showed
   no unrolled loops: rows go to timed pin waveforms (I²C START/STOP/restart,
   8 rows), multi-way decisions (3 rows each) and "pulse, then wait" pairs
   (Ethernet, 7 pairs). **Done in RTL:** paged programs. Up to 16 pages of
   16 rows plus 5 contexts each live in the host SRAM bank and load on a page
   row; rows still execute from registers, so timing inside a page is
   exact ([paged programs](experiments/grid_fabric/TEMPORAL_CONTROL.md#paged-programs)).
   Cost: +119 flops, +13.7k µm² in local synthesis. The compiler pages
   programs over 16 rows at rows its lowerings mark stretchable (branch
   `work/sequencer-paging`); a forced two-page `write_read` passes its source
   tests at the pins. Remaining: mark stretchable rows in SPI and the
   Ethernet session, and a later "pulse on entry, then wait" row encoding
   would halve Ethernet-style programs.
5. **Protocol bring-up at the pins.** Agree the demo set (SPI, UART, I²C,
   JTAG, USB low-speed TX, 10BASE-T TX). For each, report parsed, mapped,
   RTL-pin, gate-level and physical status in PROTOCOL_COVERAGE.md, with
   compiler-generated images only.
6. **Compiler.** Lower the demo functions from source without hand-written
   images; report resource use (tracks, sinks, cells, rows, contexts) per
   program so capacity limits show up before hardware changes.
7. **Head-to-head with `main`.** One table: area by function, slack, layout
   runtime, protocols covered at gate level, host-interface changes. The
   decision is recorded here with that table.
8. **Submission packaging.** Tiny Tapeout `info.yaml`, pinout and datasheet
   for the host link and configuration words; GL-safe cocotb tests at
   top-level pins only; final precheck on the merge commit.

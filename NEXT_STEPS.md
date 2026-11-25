# Next steps and experiment status

**Current direction:** The numbered notes below are historical planning notes;
in particular, the later statement dropping CIRCT has been superseded by the
decision to reuse the Rust frontend and experiment with CIRCT lowering.

- Current hardware branch: `experiment/two-sram-placement`, described in
  `PLACEMENT_EXPERIMENT.md`. `work/tile-routing-experiment` retains the prior
  chip top and the standalone tile experiments.
- Compiler experiment: sibling `protocol-emulator-compiler` branch
  `work/tile-fabric-codesign`, described in `circt_lab/README.md`.
- The experimental Tiny Tapeout top now uses the [structured 3 × 3 grid](experiments/grid_fabric/README.md).
  Two timers and shifters, a logic tile, I/O and two SRAM tiles communicate
  through finite configurable neighbor links. A reused programmable CRC tile
  handles USB CRC-16 and Ethernet CRC-32 reference data through those links.
  An observed SCL hold primitive is verified for clock stretching; neither
  a complete I2C transaction nor USB/Ethernet packets have been compiled for
  the grid. Restricted source-derived SPI
  and UART images exercise the same grid. Its SRAM word paths are dedicated,
  SPI, UART and the JTAG component now share credit-based SRAM reader and
  writer tiles; a two-alternative prefetch block is tested separately but not
  integrated. Placement is fixed, and source transaction lowering remains incomplete. Physical CI for the
  grid revision is required; prior passing results apply to the older top.
- Next: compare protocol workloads and alternative grid layouts, extending the
  compiler's actual port/link model and source transaction/stream lowering.
  Distinguish mapping limitations from missing hardware, then implement the
  highest-impact gap. Track physical area/timing and electrical checks for each
  candidate; the grid must also preserve UART concurrency and SRAM arbitration.
- The control-only end-to-end example is deliberately small. Corpus export or
  a component table is not evidence that an entire protocol fits.

## Spatial-architecture direction (2026-11-24)

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
| VTR research flow: architecture file, benchmarks, retargetable CAD, area/delay models | This is the laboratory (steps 2–4 below). Use VTR's minimum-channel-width method: find the smallest track count W at which every corpus protocol routes per layout, then size at about 1.3×W instead of guessing 4. Evaluate VPR as the mapper's placer/router on the 3×3 before writing a custom one. |
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
- **Build only the links the corpus needs.** A full 2D mesh on the 3×3 is
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
   the adapter logic.
5. **Config shift chain (finding 3 full version),** once the tile set is
   stable, since it changes the host protocol and cocotb harness.

In parallel from step 2: the minimum-track-width sweep in the laboratory, and
capacity/contention reporting for the banking decision.

Pitch storyline: protocols are spatial at the bit level and temporal at the
packet level → static registered bit fabric, word mesh to SRAM stream ports,
descriptor sequencer per lane → generated from one architecture file and
evaluated VTR-style against a protocol corpus (minimum track width, wire-rate
slack, hop counts).

## Earlier planning notes

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

## Cleanup status — 2026-11-22

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

## Fabric redesign: hardware, compiler, and test plan

**Target:** a structured, heterogeneous 2D fabric grid with configurable
connections and a programmable temporal layer. The compiler maps protocol
operations onto reusable tiles, routes their signals, and schedules their
runtime phases. The precise layout, switch connectivity, and temporal control
are experimental choices constrained by protocol coverage, timing, and area.

The stream reader/writer and cross-bank addressing are parts of the same memory
subsystem: one moves data, the other extends where streams can access it. They
share interfaces, arbitration, compiler allocation, and tests. The current
stream changes are uncommitted work in progress, not a completed architecture.

### Design requirements

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

### Staged work and decision gates

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

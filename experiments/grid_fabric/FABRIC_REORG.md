# Fabric reorganisation (2026-11-26)

**Why.** After "reconfigurable lanes" the design grew a second fabric
beside the first. `grid_lane_core` is a controller plus its own two
timers, coded shifter and CRC, all joined by a private 64-line crossbar.
It sits outside the 5 x 3 cells and switch boxes. The inter-cell contract
gained `temporal`, `lane` and `lane_core` sections that describe three
overlapping control schemes. This is not the spatial fabric the project
set out to build (Betz-style: individual resources in cells, joined only
by configurable switch boxes). The lane-core chip also failed to route.
The evidence is severe global-routing congestion (Metal3 at 94-111%) and
detailed routing that never converged, at 67% utilisation (LANE_CORE.md
"Routing gate result"). The duplicated fabric is a credible contributor.
The runs do not show that utilisation alone caused it, or that 67% cannot
route with a different structure or floorplan. The cluster plan
that followed (one big controller-plus-resources block per cluster) kept
the same shape, so it is withdrawn too.

**Rule for the reorganisation.** Every piece of state or logic is one of:
- a resource in a cell;
- part of a switch box;
- on a word or stream path with an explicit interface (step 4).

Resources connect through three kinds of path, all documented in the
contract and visible to the compiler:
- the bit mesh (switch boxes);
- the word and stream network;
- **local fast paths**: named point-to-point links between specific
  resources where a mesh hop would cost latency or tracks for no
  flexibility, for example a coded shifter's serial output into the CRC
  (today's `crc_link`). Each such link is one fixed connection (or a small
  listed choice) that the compiler models as an edge of its own.

What is ruled out is a private network: an all-to-all or
many-to-many selector set among a group of resources that bypasses the
mesh, which is what the lane core's 64-line crossbar was.

## Active plan (the only current meaning; everything under "History" is superseded where it differs)

**Thesis (user, 2026-11-26).**
- Coarse-grained protocol tiles (timers, shifters/coders, CRCs, SRAM
  streams, I/O) are the foundation. The work is to find the smallest
  distributed control and interconnect that coordinates them.
- A little programmable logic connects blocks and makes decisions ("if
  START occurs, enable the receiver"). It never rebuilds a protocol
  datapath, and the fabric is not redesigned around LUTs.
- Event and route-latency guarantees are made only after verification.
  (Control: in the interconnect, below.)

**Kept from v2 (the prototype baseline; the fabric size and resource mix
are decided by the grid-size study below, not fixed here):**
- **Tiles.** Timers (`grid_timer`), coded shifters (`fabric_shifter`;
  it also does plain frames, so the two plain shifters go), the CRC
  (`fabric_crc`), and I/O. Pads grow towards 8.
- **Bit mesh.** One tile plus one switch per cell, on the 5 x 3 grid
  today (prototype baseline; 3 x 4 and 3 x 5 candidates are compared in
  the grid-size study before the size is final):
  - 1-bit tracks, 4 per direction;
  - today's switch (straight, two turns, no track change), with the
    width and turn rules still to be measured;
  - tiles drive their cell's 4 local outputs.
- **Word network beside the mesh** (`reorg/wnet.v`; a *candidate*, tested
  only as a block with its own bench and in the I2C slice):
  - valid/ready flow control and per-sink reach lists (not all-to-all);
  - stages: escape, compare -> bit, gate <- bit, split, interleave;
  - proposed, untested: two readers and two writers (one pair per SRAM
    bank), and the shifter -> CRC fast path.

  Not yet shown: the topology and its reachable combinations against
  complete workloads, two protocols at once each through its own SRAM
  writer, and bank contention. The concurrent I2C + UART tests take the
  UART's bytes straight from its shifter (no SRAM writer).

  Words cross into the bit mesh only through compare -> bit and gate <-
  bit.
- **Configuration** is loaded by the host and static during a run.
  Runtime changes come only where a protocol and a test need them.
- **Removed** as protocols migrate, never while a test depends on them:
  - the lane core (controller, private crossbar, duplicated tiles);
  - the page loader;
  - the frame and packet FSMs;
  - the plain shifters and the LUT2.

**Control lives in the interconnect (2026-11-26, after re-reading Betz,
ICCAD'26 keynote, slides 27-44).** The keynote's spatio-temporal model:
- each tile is a router plus compute, and the router holds a route table
  ("each router programmed with per-colour table", slide 41);
- static routes "can [be modified] over time -> like partial
  reconfiguration" (slide 44);
- computation is "triggered by data arrival" (slide 42).

Here this means:
1. **Contexted switches.** A switch holds a few routing contexts (its
   track and sink selections) and a small local state that changes
   context on events arriving at that switch (two event -> next rows per
   context). A protocol phase is a routing context; a condition is
   whether a route exists in the current context. Prototype:
   `reorg/ctx_switch.v` (today's `grid_switch` semantics, 4 contexts).
2. **Dataflow triggering.** Tiles start, shift and stop on arriving
   events; words move on valid/ready. Nothing needs a sequencer to say
   *when*.
3. **I/O tiles have configurable outputs.** Each of 4 outputs is any
   pin's level, rise or fall, optionally qualified by another pin's
   level: I2C START = SDA fall while SCL high, or SPI SCK edge while CS
   low.
4. **Word stages tap channels.** Compare observes a channel's
   handshakes and emits match and mismatch pulses without sitting in the
   chain. In a chain, the I2C address byte would reach the gate after
   the context had already changed.

There is no sequencer, no controller and no LUT logic for control.

The I2C target as tested (slice and compiled mesh):

| Switch | Contexts (transitions) | Routing that changes |
|---|---|---|
| I/O cell | RELEASE -(ACK-GO)-> WAIT -(SCL fall)-> DRIVE -(SCL fall)-> RELEASE | DRIVE: SDA enable sink = 1 |
| shifter cell | IDLE -(START)-> ADDR -(match)-> ON / -(mismatch)-> OFF; ON, OFF -(STOP)-> IDLE | ADDR: match pulse -> ACK-GO; ON: word -> ACK-GO, gate sink = 1 |

A repeated START inside a transaction is **not supported** by either
tested mapping: ON and OFF have no START transition (in the hand mapping
the START track carries ACK-END during DRIVE; in the compiled design the
shifter would also need aborting mid-frame).

The shifter does bits, frames, the byte loop (burst) and abort on STOP.

**Area (IHP liberty from a CI artifact; one cell's switch, 5 sink
selectors and their configuration flops):**

| Contexts | Area (µm²) |
|---|---|
| 1 (today) | 8,180 |
| 2 | 17,512 |
| 4 | 31,000 |

Configuration storage dominates.

Extrapolated synth area (at about 0.11% utilisation per 1k µm²):
- **Without contexts.** About 377k (about 41%):
  - switches 123k;
  - timers 4 x 16.4k;
  - coded shifters 2 x 34k;
  - CRC 24k;
  - word network 21k (measured);
  - streams about 20k;
  - configuration tree, host link and glue about 55k.
- **With contexts.**
  - 4 temporal cells at 4 contexts: +91k, about 51%;
  - every cell at 2 contexts: +140k, about 57%;
  - every cell at 4 contexts: +342k, about 79%;
  - every cell at 4 contexts with latch configuration: about 65%.

Proposal: contexts on a few cells (4-6 temporal cells, the way FPGAs put
hard blocks in columns), an *estimated* 51-55% synth utilisation. This
is an estimate from synthesis area only, not evidence of physical
headroom: routing, timing and the physical checks have to be shown by
a GDS (criterion 5), including at a higher placement density (the user
suggested 60 -> 80). Concurrency tests and the grid-size study decide
how many cells need contexts.

**Promotion criteria (user, 2026-11-26).** The contexted switch is a
prototype until all six hold, each with its evidence recorded here:

1. **Correctness.** The real shifter and word network pass I2C START,
   address, ACK/NAK, STOP, back-to-back transactions, and simultaneous
   or closely spaced events, across the timing sweep.
2. **Concurrency.** Two protocols run together without one switch's
   context changes disrupting the other's routes or state.
3. **Compiler support.** The compiler assigns contexts, detects
   conflicts, routes the design and emits a working configuration from
   source, not by reproducing a hand-authored mapping.
4. **Broader coverage.** At least one other control-heavy protocol
   (JTAG) is mapped and tested, with a streaming protocol alongside it.
   Each failure is classified as hardware, compiler, or insufficient
   resources.
5. **Physical viability.** With the logic it replaces removed, the design
   routes and meets timing and physical checks. Configuration storage,
   transition logic and area are measured at the intended scale.
6. **Advantage over the sequencer.** On the same workloads and
   constraints, it gains meaningfully in flexibility, area, timing or
   protocol coverage, without a material regression elsewhere.

**Criterion 1 evidence (2026-11-26): `reorg/slice_i2c_tb.sv`, `make reorg-proto-test`.**
The I2C target runs on a 1 x 3 strip of the mesh with:
- two contexted switches (`ctx_switch.v`) and one static switch;
- two I/O tiles (`io_tile.v`: qualified outputs, START = SDA fall while
  SCL high);
- the **real `fabric_shifter`** (8-bit receive frames on SCL rise, auto
  push, abort on STOP);
- the word network: rx -> gate -> writer, with compare as a tap on rx.

There is no sequencer, controller or LUT. The routes and contexts:
- The I/O switch steps RELEASE -> WAIT -> DRIVE. DRIVE pulls SDA low and
  puts SCL fall on the START track as ACK-END, which restarts the shifter
  for the next byte. The track is shared in time, as the keynote's
  colours are.
- The shifter switch steps IDLE -> ADDR -> ON/OFF. It routes the match
  pulse (ADDR) or the word pulse (ON) as ACK-GO and opens the gate in ON.

Passed:
- a NAK for another address, with nothing stored;
- 0x48 with 4 bytes: 5 ACKs and 4 bytes stored, the address byte dropped;
- back-to-back transactions, including a data byte equal to the address,
  then a transaction for another device;
- contexts back at idle after every STOP.

Timing sweep, 245 points: **215 pass**. Every failure has SCL low for
4 clocks or fewer, where the ACK (about 5 clocks after the SCL fall)
cannot be driven in time. The best sequencer variant (the LUT-qualified
program B) showed the same pass/fail envelope **on this test**
(cycle-level behaviour in RTL simulation). That says nothing about
post-route delay, Fmax, or other mappings. A 1-clock SDA setup passes, because
qualification happens in the I/O tile in the same clock.

Found on the way:
- The shifter pushes and pulses its word only at frame end, after any
  post bit. The mapping therefore uses 8-bit frames and handles the ACK
  clock in the contexts.
- A context's sink entry placed at the wrong context index drove SDA
  during a data bit. Context tables need the compiler's conflict and
  order checks (criterion 3).

Not yet covered:
- a repeated START inside a transaction (ON has no START transition,
  because the START track carries ACK-END there);
- simultaneous events by construction (two events into one transition
  row in the same clock: priority A over B, untested);
- the existing pin-level cocotb test against a chip build.

**Criterion 2 evidence (2026-11-26): `reorg/slice_i2c_tb.sv +UART`, `make reorg-proto-test`.**
A UART receive runs beside the I2C target on its own tiles:
- cell 4: a `grid_timer` (start <- RX fall, stop <- shifter stop; the
  shipped uart-rx-plain timer words, first 8, period 20);
- cell 7: a second real `fabric_shifter` (uart-rx-plain's frame word
  0x8297; shift = sample = timer tick, start <- RX fall, in <- RX level).

Its RX level and RX fall come from I/O tile B in cell 0 and pass
**through cell 1's contexted I/O switch** (west t0/t1 turn south), then
straight through the timer's switch to the shifter. The UART's own
switches are static; the I2C's context changes happen under its live
route.

Passed:
- a continuous pseudo-random byte stream (1 stop bit, 0-3 idle bits)
  for the whole I2C sequence: 26 bytes at the nominal point, with 396
  DRIVE clocks inside UART frames, every byte correct;
- the 245-point sweep with the UART running: **215 pass, the same points
  as alone**; the UART changes no I2C outcome, and every passing run had
  DRIVE overlapping a UART frame (a run without overlap fails, so the
  test cannot pass vacuously);
- the negative case `+BAD`: DRIVE drops the RX level route (south t0 = 0
  in that one context). The UART corrupts (byte 6: 0x31 for 0x39) and
  the I2C is intact. A route that is not identical in every context is
  a real fault, so the compiler must check it.

What this shows: a route that changes with another protocol's context
corrupts that protocol. What it does **not** show: that two
context-dependent protocols can never share a switch (e.g. through a
product of their states, or disjoint selectors that each follow one
design's register).

The compiler therefore adopts, as a **proposed restriction** (a safe
model, not a proven necessity), that a switch's context register belongs
to one design, and every other design uses only selectors of that switch
that are identical in all its contexts (a pass-through or a static
sink). Its cost has to be measured: how often the restriction forces a
worse placement or a failure on complete workloads and concurrent
combinations (the grid-size study reports it).

Not covered: two contexted designs in neighbouring switches exchanging
events (both stepping contexts on shared tracks), and a second
word-network writer (the UART's bytes are taken straight from its
shifter's FIFO port here).

**Criterion 3 evidence, partial (2026-11-26): `reorg/mesh.v`,
`reorg/mesh_tb.sv`; compiler `circt_lab/fabric_arch.py`,
`fabric_map.py`, `fabric_designs/`.**

- **Hardware.** `mesh.v` is a parameterised grid of the prototype
  cells: `ctx_switch` beside an `io_tile`, `grid_timer` or
  `fabric_shifter`, plus `wnet` at a word-port cell. The cell kinds,
  context counts and word-port cell are parameters. A mesh contract
  (written by `fabric_arch.make_contract`) holds the same values and is
  the only hardware description the compiler reads.
- **Source.** `i2c_target.json` and `uart_rx.json` are netlists of pin
  events, drivers, tiles, the word path, FSMs and muxed signals. They
  name no cell, track or context number.
- **Compiler.**
  - It places by annealing, then routes with PathFinder plus mux points.
    A muxed signal switches only at a selector in its FSM's switch: a
    sink there, or one track X leaving it. The nets feeding a mux must
    reach a node that drives X.
  - It assigns contexts: the reset state is context 0, with at most 2
    transitions per state.
  - It emits the vector, then checks it independently. `ConfigSim`
    decodes the bits with its own code. Under every combination of FSM
    states it compares every sink and transition row with the source's
    meaning, and every unused sink must read 0.
- **Result.** The first runs used a small 3 x 3 test configuration (a
  test fixture only, never a fabric proposal). The test configuration is
  now a wide 3 x 5 candidate (rows x columns, like the 8 x 4 Tiny
  Tapeout die), `test_3x5b`:
  - row 0: timer, io, timer, io, timer;
  - row 1: shifter, crc (word port), shifter, crc, shifter;
  - row 2: timer, io, timer, io, timer;
  - contexts on the io and crc cells.

  On it:
  - The compiler places the ACK FSM on an I/O cell and the address FSM
    at the word port, routes, and the check passes.
  - At the pins, the I2C target plus UART pass the slice's stimulus. The
    245-point sweep with the UART running gives **215 pass, the same 30
    failures as the hand mapping** (SCL low for 4 clocks or fewer).
  - The 3 x 3 configuration gave the same 215 before.
- **Found on the way.** A mesh RTL bug: the shifter's line vector was
  65 bits, so `in` landed on line 34. The pin test caught it; the
  configuration check could not, because it models the switch, not the
  tile wiring.

Not yet covered by criterion 3:
- the source is a JSON netlist, not `.spt` through CIRCT (step 4);
- the exhaustive oracle and its failure classification (proven against
  heuristic);
- protocols beyond these two;
- what the ownership restriction costs.

**Targets to verify, not guarantees:**
- **Timing.** Every tile output is a register, so tile to tile is one
  clock, whatever the route. To verify: Fmax across the longest
  combinational mesh path, and every route's latency in simulation.
- **Events.** Pulses are one clock wide, and every always-active
  consumer sees every pulse. The I2C prototype sweep found no case where
  event latches changed a result. To verify: on JTAG, USB, Ethernet and
  concurrent runs before latches are ruled out.

## Steps (in order; each sturdy, with its own evidence, before the next)

1. **Inventory**: the existing tiles, switch boxes, SRAM paths and
   lane-core logic, with what each does. *(This section, below.)*
2. **Placement of lane-core functions**: decide where state, sequencing,
   edge detection and events go: existing tiles, switch boxes, or small
   distributed control resources. Each decision comes with its reason.
3. **Vertical slice: an I2C target on distributed logic** (replaces the
   earlier steps 3-7; user, 2026-11-26). One narrow slice instead of a
   full rewrite, with each sub-step sturdy before the next:
   - **3a. Clocked bit/event interface.** Define:
     - pulse capture;
     - simultaneous events;
     - reset;
     - the latency of a route (which hops are registered);
     - configuration ownership.
   - **3b. Contexted switch** (`reorg/ctx_switch.v`) and the
     primitive features the I2C mapping needs (I/O output qualification,
     compare as a tap, the shifter's word event before the ACK bit).
   - **3c. Map the I2C target** onto contexted switches, the real
     shifter, an I/O tile and the word path: START, address match, ACK,
     byte reception, STOP. Test it at the pins. *Done as a word-network
     test* (the network's writer port is the bench's sink); a full
     SRAM-backed pin test, with both concurrent protocols completing
     through real SRAM banks, is a separate step and not done.
   - **3d. Compare** against:
     - the existing lane-core implementation (pin behaviour, resources,
       area, routing, timing);
     - a table state-machine implementation (mapping success, area,
       routing, timing, concurrency).

     Then add a second concurrent workload. A table tile is added only if
     the results show a meaningful need, and then independently
     assignable through the mesh.
4. **Compiler: lowering from `.spt` (user, 2026-11-26: protocol mapping
   is compiler work; the interconnect is finished).**

   The frontend exports every item of a program:
   - resources with their fields;
   - registers as boolean expressions;
   - flags and the contexts they select;
   - pins, events;
   - exported functions as statement lists.

   The compiler lowers these to the fabric IR that `fabric_map.py`
   places and routes. Hand-written fabric IR is only a test fixture.
   Each lowering stage is tested at the pins before the next:
   - **L0, cell-side hardware** (no interconnect change): the shifter's
     `out`/`active` as local outputs; a CRC cell (`fabric_crc`, linked
     to its neighbouring shifters) carrying the word-network bit port;
     I/O cells with two pad drivers (open drain or push-pull, polarity).
     *Done (2026-11-26)*, on the test configuration above. The compiler checked each fixture before it ran, and each passes at
     the pins (`run_mesh.sh`, `test_fabric_map.py`):
     - UART TX: 12 bytes from the reader, gapless 8N1, on a push-pull pad;
     - `crc_tx`: a 6-word burst plus the linked CRC cell's CRC-16 tail,
       recomputed by the bench, on a complementary pad pair with a clock
       pad;
     - the I2C target + UART, with the word port now at the CRC cell.

     Pads are not driven until the fabric runs (found by the TX test).
     The checker caught an emitter bug: a sink tied to a static constant
     was never written.
   - **L1, resources -> tiles.** Timer, shifter and CRC fields become
     register words; `a until b` becomes start <- a, stop <- b.
   - **L2, pins and flag contexts -> drivers and muxed signals.**

     *L1 and L2 without contexts, done (2026-11-26), roadmap item 1
     ("a complete protocol from source to pins through actual SRAM
     streams").* `fabric_lower.py` lowers the frontend's logical IR
     (`spatial model-ir`) to fabric IR; `fabric_build.py` places, routes,
     emits and checks it, and writes the vector, the source's test plan
     and the stream interface. `loopback.spt`, `ps2.spt` and `uart.spt`
     pass every one of their own source `test` blocks at the pins of
     `reorg/mesh_soc.v`, the mesh with the existing stream reader,
     writer and two-bank SRAM (`make reorg-compiled-test`,
     `test/cocotb_tests/test_mesh_compiled.py`):
     - host -> pins: the host writes the bytes into SRAM bank 0 and the
       reader sends them into the shifter;
     - pins -> host: the shifter's receive word goes through the writer
       into bank 1 and is read back through the host port;
     - loopback does both at once.

     The runner knows no protocol: it attaches the plan's peers, plays
     the host, and checks each invariant every cycle. Two bugs were found
     in the SoC wrapper, not the mesh:
     - a host access right after a bank switch went to the old bank;
     - the one-clock memory disarm for the route change reset the open
       receive region, because the stream tiles' enable is a reset.

     Coverage of the 35 examples on test_3x5b (`test_fabric_lower.py`;
     every program compiles or is refused with a class; after L3/L4 SPI
     on test_3x5c: 4 compiled with spi, 1 hardware refusal, 30 compiler):
     - compiled: loopback, ps2, uart;
     - refused, hardware: `spi` (a counter resource has no tile),
       `io_saturation` (two transmit streams, one reader);
     - refused, compiler (30): functions, register/event/flag signals
       (L3/L4), `timer.run`/`resync` inputs, stream stages (L5), and
       context-dependent inputs (L2 contexts).
   - **L3/L4, first function: SPI `transfer` (2026-11-26).**

     *Execution model (user, 2026-11-26).* The host may act before or
     between transactions (write configuration and parameters, provide
     arguments, start work, read results), and at points where the source
     allows a pause and the measured latency is acceptable. Where wire
     timing requires a reaction (an I2C target's address match and ACK
     against an external clock), the configured tiles react locally. The
     compiler decides per step; nothing assumes one method for every
     function.

     *Hardware, cell-side only* (`ctx_switch`, tracks and `wnet`
     unchanged):
     - a **counter** cell kind (`src/fabric_counter.v`, already formally
       checked: count, streak modes, clear, `at_least` true at limit 0,
       `reached`), marked by mesh.v's `CNT` parameter. The count-mode
       timer could not serve: a limit of 0 (`transfer([0x10])`) needs
       `at_least` true at once, and the timer refuses `first` = 0.
     - **host events**: io output mode 3 reads `host_ev[k]`, a one-clock
       pulse the host fires;
     - **sticky flags** (`seen`, 4 per cell, `seen_clear`) on every local
       output, for the host's waits;
     - a **parameter port** (`param_*`): a register write into a counter
       while the fabric runs; the compiler emits it only while the tile is
       idle (before the transaction's first fire).
     - fix found by the move to test_3x5c: a shifter between two CRC
       cells took its CRC tail from the east one whatever the link
       registers said; it now takes it from the CRC whose link names it.

     *Compiler rules* (`fabric_lower.py`): set/clear registers become
     FSMs; `!s` of an FSM register is a mux; `open = begin || (open &&
     !(sent.at_least && bits.busy))` is OFF -> ON -> ARMED -> OFF, exact
     because `at_least` only rises between two `begin`s (its clear). The
     function becomes a host plan: clear flags; send `data` through SRAM
     and the reader; write `sent.limit = data.len - 1`; fire `begin`; wait
     for `data.len` result bytes (each word pushes one); fire `finish`;
     wait `cs_off.tick` and `gap.tick` flags; read the result from SRAM.

     *Evidence* (`make reorg-compiled-test`): both `spi.spt` source tests
     pass at the pins with the device peer and the invariant "SCK only
     moves while CS is low" checked every cycle, and pass again with 997
     host clocks before every host step (the steps tolerate host latency,
     measured, not assumed).

     *Measurements* on test_3x5c:
     - cells: 7 of 15 (shifter 5, counter 12, timers 4, 10 and 14, io 11
       and 13); 23 track segments; 2 host events of 4;
     - contexts: `selected` 2 states (io cell 13, its mux drives CS),
       `open` 3 states (shifter cell 5, its mux is the shifter's start);
     - timing: a call takes the wire time plus 25-33 clocks of host steps
       at no host delay (1 byte 165 clocks for 140 on the wire; 3 bytes
       429 for 396);
     - area (yosys + IHP liberty, logic only; the configuration bits are
       an input bus here, their storage not counted): the host hooks add
       5.6k um2 to the mesh (246.2k -> 251.8k, +2.3%); test_3x5c's mix
       (a counter for a timer, contexts on three shifter switches) adds
       5.2k more (257.0k). The counter is 7.9k against the timer's 16.3k;
       a 4-context switch costs about 4.5k over a 1-context one.

   - **Externally driven I2C target from source (2026-11-26).** The
     SPI result shows host sequencing works for a function whose source
     allows pauses; it says nothing about a target's response deadline.
     The target therefore runs entirely in the fabric: no host step in
     its time loop.

     *Language* (compiler README, "State machines and word compares"),
     defined by behaviour, not by the switch encoding:
     - `compare C on S { value, mask }`: every word S receives pulses
       `C.match` or `C.mismatch` once, after S's `word` and before its
       next;
     - `machine M { state S { on E -> T ... } }`: the first state is the
       reset state. The first `on` line (in source order) whose signal is
       high is taken; the others are ignored in that clock. A transition
       takes effect at the end of the clock: `M.S` is 1 in exactly the
       clocks M is in S. `if M.S { a } else { b }` selects by state;
     - a stream's `gate { open: L }` passes only words received while L.

     A machine over the fabric's bounds (4 states, 2 `on` lines per
     state) is refused as a hardware limitation, never reshaped.
     `spatial build`/`check` refuse these constructs (the old fabric
     cannot implement them); `spatial test-plan` accepts them.

     *Program* (`examples/fabric/i2c_target.spt`): `bus` (IDLE, STARTED,
     ADDRESS, SELECTED), `ack` (RELEASED, WAIT, DRIVE), a compare on the
     receive shifter, and the gate. Peer: a new `i2c_controller` (drives
     SCL/SDA; one message per `write`; a message queued during another
     follows it with a repeated START; records ACK/NAK per byte; fails
     the test if the target pulls SDA low outside an acknowledge or moves
     it during one).

     *Evidence* (`make reorg-compiled-test`), all four source tests pass:
     - address match with ACK, then data bytes to SRAM;
     - another address and a read are not acknowledged, and nothing is
       stored;
     - repeated STARTs readdress within one transaction (to the target,
       to the target, to another address that is NAKed, to the target),
       with a final STOP;
     - a fast bus.

     *Timing envelope* (swept, half-period 4-10 clocks, hold 1 to
     half-1): every case passes at a half-period of 5 clocks or more (10
     clocks per SCL period, 5 MHz SCL at 50 MHz). At 4 the address is
     still acknowledged (the compare tap), but every data byte's
     acknowledge comes after SCL has fallen: the shifter's word event
     follows the synchronised SCL rise too late. This limit is measured,
     not yet computed: the compiler does not check response deadlines
     statically (open).

     *Compiler rule found here: exact machine replication.* The gate's
     constant-1 case pins `bus` to the word-port cell, so the shifter's
     two selections had to leave that cell on tracks, and they did not
     route. The compiler now gives a machine that a constant-1 selection
     pins to one cell, while its other selections are read elsewhere, one
     copy per pinned site (one more contexted switch). The copies are
     always in the same state because they have the same reset state and
     rows **and routes are combinational, so every copy sees every event
     in the same clock**. That precondition is explicit: if routes get
     registered hops, replication must equalise latency to every copy or
     be refused.

     Also fixed: colocation (a machine with a constant-1 case at its
     reader's cell) is now a hard placement constraint. And
     `test/Makefile.mesh` keys its build directory on the mesh
     parameters, after a reused build with stale parameters (shifter
     cells without contexts) made a correct vector fail at the pins.
   - **L3, exported functions -> control FSMs.** `wait X` is a state
     left on X; `fire E` is the triggering event muxed by state;
     `repeat N { wait next X }` is a count-mode timer; `set_flags`
     selects contexts; `send` is a reader stream. A function longer than
     a switch's 4 contexts is a chain of FSMs on several switches, with
     the exit event as the token.
   - **L4, registers -> FSMs where possible.** A feedback register (set
     by one event, cleared by another) is a 2-state FSM, and a selection
     on a tracked level is a mux. Anything else is a classified failure
     ("needs logic"), not hand-mapped.
   - **L5, streams -> word paths.**

   Baseline workloads, the `.spt` examples: `uart`, `spi`, `i2c`, `jtag`,
   `usb`, `ps2`, `swd`, and `ethernet_tx_coded` (the defined Ethernet
   workload: the whole `transmit()` link session).
   *Two protocols through their own SRAM streams, under contention
   (roadmap 2, 2026-11-26).* `examples/fabric/i2c_uart_tx.spt` (compiler
   repository): the I2C target's bytes go into SRAM through the stream
   writer while a UART transmitter sends bytes from SRAM through the stream
   reader, on 4 pads; compiled from source (26 track segments, longest
   route 3 hops). Tests: a fast I2C bus (10 clocks per SCL period, a NAK
   and a repeated START) beside a 2.5 Mbaud UART stream, and a slow bus
   beside a 16-byte stream. Both pass at the mesh ports and at the chip's
   pins.
   - Concurrency is not contention: with the reader on bank 0, the writer
     on bank 1 and a byte every ~200 clocks per stream, the memory saw no
     clock with two requests. `make reorg-contention-test` adds a host
     storm (continuous SRAM reads) and, in a second run, the receive region
     in the send bank (one single-port bank for reader, writer and host):
     13 clocks with two or more requests, 13 requests waited, 1,028 storm
     reads in the fast test; both protocols still complete exactly. The
     protocol streams are slow next to the memory, so collisions stay few
     even then.
   - The pairing is forced by the hardware: the word network has one reader
     and one writer port, so two receiving protocols (the I2C target and a
     UART receiver) cannot both reach SRAM. That is a resource-mix input
     for right-sizing (a second writer against, for example, a third
     shifter), decided by the workload study.

5. **Registered routing study (user, 2026-11-26), before deciding where
   registers belong.** Routes are combinational today (`ctx_switch`
   track and sink selectors are muxes, `hop_cycles 0`), so "one clock
   tile to tile" is a target, not a demonstrated guarantee.
   - **Loop freedom across every legal configuration:** prove it on the
     synthesized mesh with the configuration as free inputs (a
     structural check: no combinational cycle in the netlist means none in
     any configuration of any context). The turn classes and the
     registered context state are the argument; the proof replaces it.

     *First result (2026-11-26): the hardware is not loop-free by
     construction.* Yosys `check` on the synthesized test_3x5c mesh
     (configuration as free inputs) reports 88 combinational loops. They
     do not go through tracks alone (the turn classes hold) but through
     tiles whose local outputs are combinational in their inputs: the
     shifter's `word` and `stop` (`fabric_shifter` word_pulse and
     stop_pulse) and the counter's `reached`. All other locals are
     registers (timer, io, CRC `ok`, compare tap, context state). A
     configuration that routes such an output back to its own tile's
     inputs, directly or through others, is a loop.

     Until the study decided, the compiler refused any configuration with
     a combinational loop through tiles (the contract listed each kind's
     combinational sink -> local paths). The study's first candidate was
     those three outputs registered at the cell boundary; the clock it
     adds on `word`/`stop` was measured, not assumed (below: no compiled
     program's pins move, and the I2C fast bus still passes).
   - **Compare** (done 2026-11-26). Study parameter `REG` in `mesh.v`
     (`MESH_REG=n` for `test/Makefile.mesh`), the same compiled programs
     (every `compiled/*.plan.json`, bit-identical configurations) at each
     point:
     - 0 combinational tile outputs (the mesh before the study);
     - 1 boundary: shifter `word`/`stop` and counter `reached` registered
       where they leave the tile;
     - 2 sinks: every sink registered where it enters its tile;
     - 3 per hop: every switch output to a neighbour registered.

     Measured with yosys and the IHP liberty (logic only; configuration
     storage not counted; `reorg/reg_study.py`). Loops: `scc` on the netlist with the
     configuration as free inputs, so a count of 0 holds for every
     configuration of every context, legal or not. Worst path: ABC `stime`
     after delay mapping, configuration free (every configuration) and
     with each program's configuration as constants (that mapping).
     Protocol latency: the pin-level tests through real SRAM.

     | point | loops | area (µm²) | worst path, any configuration | per program | I2C at 10 clocks per SCL period | SPI call clocks |
     |---|---|---|---|---|---|---|
     | 0 combinational | 1 SCC | 255,981 | none (loops: no static bound) | 1.58-2.25 ns | pass | 429 / 165 / 299 |
     | **1 boundary** | **0** | **256,770 (+0.3%)** | **8.14 ns** | 1.66-2.21 ns | **pass** | **429 / 165 / 299** |
     | 2 sinks | 0 | 258,906 (+1.1%) | 8.92 ns | 1.69-2.25 ns | **fail** (ACK late) | 434 / 170 / **fail** |
     | 3 per hop | 4 SCCs | 261,394 (+2.1%) | 8.86 ns | 1.70-2.18 ns | **fail** (ACK late) | 436 / 172 / 306 |

     (Areas from the default area mapping; delays from a delay mapping.
     UART, loopback and PS/2 pass at every point. At 2 the SPI
     back-to-back transfer loses its second call's result bytes: the
     mapping's same-clock relations between routed events no longer hold
     when every sink lags by a clock.) Per hop: a chain of
     ctx_switch track paths measures 1.60 ns for one switch, 3.53 ns for
     15, so about 137 ps per hop before layout; most of the first 1.6 ns is
     the context register driving the selector muxes. The 8 ns worst case
     is tile logic with the configuration free, not routes. Every compiled
     program's longest route is 2 or 3 hops (the I2C target's `scl_fall`).

     Per hop (3) is not loop-free: a tile output reaches its own sinks
     through its own switch without crossing a hop register. Sinks (2) is
     loop-free but puts a clock on every route, which costs the I2C target
     its fast-bus acknowledge. Boundary (1) is loop-free, adds no clock to
     any compiled program's pins, and costs 0.3%.

   - **Decision (2026-11-26): boundary registers (REG=1) are the mesh.**
     Every tile local output is a register, so the hardware is loop-free
     by construction (the netlist proof above), and the worst path over
     every configuration is defined: 8.14 ns before layout. Routes stay
     combinational; their length is bounded by the compiler instead: the
     contract's `timing.max_route_hops` (12, from 137 ps per hop with a
     0.5 ns allowance per hop after layout: 8.9 + 12 x 0.5 < 20 ns), and
     the mapper refuses a placement whose longest route is longer (class
     `timing`; it tries other placements first). The contract's `comb`
     lists are now empty; the mapper's loop check stays for any kind that
     declares a combinational path, and is tested that way. Step 6's
     post-layout STA recalibrates the per-hop allowance.
6. **Replacement chip top (user, 2026-11-26), the next physical
   milestone.** Integrate the contexted mesh, the host interface (streams,
   host events, flags, parameters) and the real SRAM macros into a
   candidate chip top, without the duplicated old fabric. Run GDS,
   timing, DRC/LVS, precheck and gate-level tests (top-level pins only).
   Step 5 decided where registers go (boundary). On branch
   `experiment/mesh-chip`, so the existing chip stays as the comparison:
   - 6.1 host interface (`mesh_host.v`): today's 12-pin link (8 data, strobe,
     3 opcode bits) as an address register with auto-incrementing write
     and read over one map: SRAM, mesh configuration words, control
     registers (run, stream descriptors and starts, host events, sticky
     flags and their clear, parameters, status);
   - 6.2 configuration storage: word-written, only the words each cell's
     kind and context count use, written while the mesh is stopped; it
     replaces the bench's flat vector;
   - 6.3 chip top: `tt_um_protocol_emulator` = host interface + storage +
     `mesh_soc` on the SRAM macros; 4 protocol pads (uio 0, 5, 6, 7, the
     pins the link leaves); no old fabric;
   - 6.4 a chip contract (the test configuration with 4 pads) and
     pin-level cocotb tests that load compiled programs through the host
     link only (gate-level safe);
   - 6.5 sources, info.yaml, local synthesis (area, lint), then CI: GDS,
     STA, DRC/LVS, precheck, GL.

   *Candidate 1 (2026-11-26, branch experiment/mesh-chip), frozen for the
   physical flow.* The mesh RTL moved to `src/` (Tiny Tapeout builds only
   from there); `src/project.v` is the mesh chip; `test/Makefile` runs
   `cocotb_tests.test_chip`.
   - Host interface `src/mesh_host.v` (commands and map in its header);
     configuration store `src/mesh_cfg.v`; `mesh_soc` gains `mesh_hold`
     (the mesh alone held in reset while the host writes its
     configuration) and `USE_MACRO`.
   - The bench (`test_mesh_compiled.py`) now drives the host through a
     port object; `test_chip.py` is the same runner over the chip's pins
     (host link, pads on uio 0/5/6/7). All five compiled programs pass at
     the pins, 11 tests with the host-delay repeats. Host-link cost,
     measured: an SPI three-byte call takes 773 clocks at the chip's pins
     against 429 on the direct ports (+344, every host step a link
     command); outside every wire-timed loop.
   - Repository lint rules applied to the moved RTL: no run-time
     part-select base (`ctx_switch` context rows are a 4-way choice of
     constant slices; `mesh.v` tile words an array index), pure functions.
     Behaviour unchanged (all mesh suites pass).
   - Configuration store: flops with an enable cost 67 µm² per bit here
     (no flop without reset, no clock gate in the library); the first
     version was 383k µm² of a 588k chip. Now one IHP reset latch per stored
     bit (27 µm², `sg13cmos5l_dlhrq_1` instantiated under SYNTHESIS), with
     a staged write so every latch enable is glitch-free by construction
     (address and data registered a clock before the enable strobe; the
     host waits on `busy`). 4,238 latches.
   - Local synthesis (yosys, IHP liberty, logic only): 396k µm², 0 SCCs
     (`check -assert` passes), both SRAM macros at the configured instance
     paths. The 8x4 die is 1724 x 711 µm, core 1,208,173 µm² (floorplan
     log); with the macros that is about 41% effective utilization, against
     63% for the old chip that fails routing on the same die. A planning
     estimate only: placement, routing demand, SRAM obstructions, latch
     handling and timing repair decide, so the real flow runs before any
     flexibility is cut.
   - Gate-level subset (GATES=yes): i2c_target, spi (no host-delay
     repeat), uart.
   - To verify in CI: latch mapping and timing in the real flow (STA of
     latch enables), DRC/LVS, precheck, GL. Latches are less safe than
     flops (a glitching enable corrupts silently; STA must treat the
     enables as clocks; weaker test/DFT tooling): the staged write removes
     the glitch by construction, and the flow's STA and GL must confirm it.
     If they do not, flops return (at their area) rather than patching.
   - Coverage (user, 2026-11-26) is to be proven, not sampled: at the level
     of the communication protocols themselves, the resources each needs,
     how much the fabric covers, and whether everything that can be mapped
     onto the I/O has been mapped (step 9).

   *More complete protocols while CI runs (2026-11-27).* SWD, JTAG,
   stored_bytes and memory_bandwidth (with its bit2 and fast variants)
   now compile from their `.spt` and pass, with and without the
   host-delay repeat, both on the mesh's direct ports and through the
   chip top's pins: all 12 compiled programs, 29 tests each way, plus the
   contention run. Coverage on test_3x5c: 12 compiled, 1 refused by the hardware
   (io_saturation: two transmit streams, one reader), 24 refused by the
   compiler. What it took:
   - Host-sequenced lowering (compiler L3) of a function's host steps:
     `set`, `load`, `drive`/`release`, register fields and `send` only
     before the call's first fire; a tile changed by them is waited idle;
     route fields (`sample`) and pad drive become a generated mode
     machine switched by host events; register fields become parameter
     writes; `send(const)` becomes stored bytes through the reader;
     `reply X.received & m` a result through the writer with a mask; a
     transaction on the result shifter without a reply drains one word.
     Output pins switched by drive/release are bidirectional (readable).
   - One hardware addition, a behaviour-preserving extension of the
     shifter's host port: shifter parameter registers 1-6 writable while
     the mesh runs (the tile idle), and register 7, a one-byte holding
     register the shifter sends when its transaction starts if the word
     network does not feed it. JTAG needs it: its TMS and TDI shifters both
     transmit, and the word network has one reader into one shifter.
     Cost (local synthesis, flop store): 587.9k -> 598.7k µm², +10.8k
     (+1.8%), most of it the run-time write path into each shifter's
     registers rather than the 27 holding flops; an item for the
     right-sizing table (R1), weighed against the JTAG and SWD it enables.
   - Next blockers (from the refusal table): USB and the Ethernet
     transmit need fabric-fired events and flags (`clear_flags`,
     `set_flags`) and repeated waits on one word in a call, that is
     function-to-FSM lowering for wire-timed functions; `parallel`
     (memory_dual_channel) needs a second reader; i2c (controller) and
     packets need helper inlining and register logic, some likely hardware
     refusals; stream stages (L5) are not lowered.

   *Every blocker, not the first (2026-11-27; compiler
   `circt_lab/blocker_survey.py`, each register, function, machine,
   resource, pin and the streams lowered on their own).* The 24 compiler
   refusals split three ways:
   - **Logic the mesh does not have** (hardware, 8 programs): USB (8 of its
     registers: NRZI, stuffing gate, SE0, the D+/D- pair), Ethernet TX and
     its coded variant (Manchester select, the TP_IDL pair), the I2C
     controller (SCL drive select, OR of two start events, OR of two step
     clocks, the stretch gate), packets, packet_errors, contexts_logic,
     byte_tag_gap. The mesh has set/clear registers and FSM-selected
     levels, but no AND/OR/mux of independent signals. This is the
     largest single coverage lever, and a hardware decision: a small
     logic resource (for example a registered LUT per cell or a logic tile
     kind) costed in the right-sizing table, not a compiler step.
   - **A second stream reader** (hardware, 5 programs): io_saturation and
     the four memory_dual_channel / unequal_parallel programs send two
     streams at once; the word network has one reader into one shifter.
     The resource-mix question R-study already names.
   - **Compiler only** (12 programs, no hardware blocker found): the four
     byte-stream stage programs (L5 stages on the word network), contexts
     and contexts_initial_one (flags and context selectors, L2), crc_link_trace
     (flags, shifter end, the CRC link), the five protocol_control
     programs (waits on pin levels and protocol signals).
   The survey is a lower bound per part (a part refused early hides its
   later statements), so a "compiler only" program can still meet a
   hardware limit once lowered further.

   *Which compiler path is durable (2026-11-27).* The mesh is compiled
   only by the Python path (`circt_lab/fabric_lower.py`, `fabric_map.py`,
   `fabric_build.py`, 2.7k lines): lowering, annealed placement,
   PathFinder routing with mux nets over the contexted switches, the
   route-length bound, emission and an independent check of the emitted
   bits; its programs pass at the chip's pins. The CIRCT path (`map.cpp`,
   `dialect.cpp`, the `grid_*` scripts) targets the old grid and lane core
   and knows nothing of contexts, the word network or the mesh's cells.
   Decision: the Python fabric compiler is the reference and the path the
   chip ships with; the CIRCT path stays frozen with the old chip. Moving
   the fabric IR into the Spatial dialect is worth doing only once the
   fabric is final (after step 8), as a port checked bit-for-bit against
   the Python output on every compiled program, not a second design.

   *Against the old chip (2026-11-27; experiment/two-sram-placement @
   75ef0a6, its own compiled programs and runner, at the pins, same plan
   clock).*

   | | old chip (grid + lane core) | mesh chip |
   |---|---|---|
   | logic area, local synthesis | 613.5k µm² | 598.7k flop store; ~407k latch store (396.4k + the holding register) |
   | GDS on the 8x4 die | fails routing (DPL-0036 after GRT overflow), every run since 7193f31 | in CI (flop store: 0.591 effective utilization, global routing overflow 1,463 after repair, so likely the same failure; latch store pending) |
   | SPI `transfer`, 3 / 1 / 2 bytes | 916 / 466 / 692 clocks | 773 / 463 / 652 clocks |
   | from source, at the pins | i2c controller (write_read, plain and paged), spi, uart | i2c target, i2c target + UART TX together, jtag, swd, ps2, spi, uart, loopback, stored bytes, memory bandwidth x3 |

   Both pass every test they compile. The old chip runs the I2C
   controller from source, which the mesh compiler still refuses (helper
   inlining, register logic: L3); the old chip's JTAG TAP, I2C/SPI targets,
   SLIP and Ethernet session tests are hand-written lane programs, not
   compiled, so they are not a like-for-like row. STA comparison waits for
   a mesh GDS that completes; the old chip has none.

   **Right-sizing (user, 2026-11-26), after the physical result.** Simplify
   flexibility the workloads do not need (context counts on selected
   switches, unused selector choices, shared word-path stages) and
   right-size the resource mix (for example a second stream writer
   against a third shifter), each cut verified against complete protocols
   and concurrent mappings, chosen by the workload study, not by counting
   cells:
   - R1 a measured cost table per item of flexibility;
   - R2 each candidate cut expressible in the contract, so the compiler
     respects it (contexts and kind mix today; selector subsets, word
     stages, stream ports to add);
   - R3 the workload: every compiling program, every concurrent pair that
     fits the pads, the concurrent fixtures; it grows with coverage
     (roadmap 2 and 3), and a cut decided on today's five programs is
     recorded with that workload and rechecked as it grows;
   - R4 sweep: recompile the whole workload under each cut contract, pin
     tests for every changed configuration, area from synthesis;
   - R5 zero-loss cuts first, then area saved per workload lost.
7. **Placement regions.** Experiment with rectangular placement regions
   (physical), then a GDS.
8. **Grid-size study (user, 2026-11-26), before the fabric size is
   final.** Compare 3 x 4 (12 cells) and 3 x 5 (15 cells) with candidate
   resource mixes on the same complete workloads:
   - a defined Ethernet workload (the 10BASE-T link session: NLP
     cadence, Manchester, CRC32, TP_IDL, frame from SRAM);
   - the baseline protocols;
   - representative concurrent combinations.

   For each mapping, report:
   - the resource types and cells used, and the unused resources;
   - routing demand and timing;
   - SRAM bandwidth;
   - why any mapping fails.

   First finding: arrangement matters, not just counts. In a 3 x 5
   arrangement with the io cells in the corners (row 1 all timers;
   shifter, crc, shifter between corner io cells in rows 0 and 2), the
   I2C target + UART did not route in 400 placements:
   - The address FSM is pinned to the word-port crc cell, because the
     constant-1 word gate is read there.
   - Its `rx.start` mux must take START and ACK-END from two different
     sides on the same track index.
   - Tracks 2-3 end travelling horizontally, so a corner io cell cannot
     supply the second side.

   With io cells directly above and below the crc cells (`test_3x5b`) it
   routes.

   This failure is heuristic, not proven: the exhaustive oracle is still
   to run. It points at a placement rule for the mix: io beside contexted
   crc cells.

   User's refined brief (2026-11-26):
   - Spare capacity is not waste; it may carry protocol combinations or
     routing. Maximum utilisation is not the goal.
   - Classify each failure as a hardware limit, a compiler limitation or
     a heuristic failure.
   - Measure area and physical feasibility for the promising candidates.
   - Recommend a size and mix, and state for each candidate the
     workloads it can and cannot support, plus the requirements still to
     be decided.

   Failures from the exhaustive oracle (where it is feasible) or from
   resource counting are proven; failures from the heuristic flow are
   not. Area comes from the measured tile costs, as estimates until a
   GDS.
9. **Coverage (user, 2026-11-26; also a study metric).**
   - Define a protocol space: designs generated from the chip's
     primitives within its limits (timers, shifters, CRC, pin events and
     drivers, FSMs of up to 4 states with 2 transitions each, muxed
     signals, word paths), with their sizes swept.
   - Measure the fraction the compiler maps on each candidate chip,
     with failures split into proven (counting or oracle) and heuristic.
   - Report it beside area as the chip's flexibility figure. Every
     candidate's coverage limit is stated, not assumed.

Workflow (user, 2026-11-26): RTL changes do not wait for review; RTL
experiments settle decisions, and the evidence is recorded here. Existing
protocol tests move over one at a time, and nothing old is deleted while
a test depends on it.

# History (superseded where it differs from the Active plan)

## Step 1: inventory (2026-11-26, branch experiment/two-sram-placement @ 4470df8)

Chip top: `tt_um_protocol_emulator` -> `grid_stream_fabric` (USE_MACRO=1).
Areas are hierarchical synth, unflattened, µm² (local yosys, IHP
liberty; flattened total 614k, about 1.17x smaller).

### A. The 5 x 3 grid (`grid_core`, 358k)

Cells (row-major, id = 3*row + column), with what each holds and its
4 local outputs onto the switch:

| Cell | Resource | Local outputs | Inputs (sinks) |
|---|---|---|---|
| 0 | input pads (2, synchronised; edge polarity per pin) | in0, in1 levels; in0, in1 edges | none |
| 1 | output pads (3, open drain) | none | 3 values (sinks 7-9) |
| 2 | timer0 (`grid_timer`) | tick, rise, fall, level | start, stop, aux |
| 3 | shifter0 (`fabric_v2_shift`, plain, ≤16 bit) | busy, done, serial, serial_or_idle | start, shift, sample, serial_in |
| 4 | 2-input LUT | logic | a, b (no local feedback) |
| 5 | timer1 | tick, rise, fall, level | start, stop, aux |
| 6 | sram0 bank + sequencer A's actions (`grid_sequencer`, the "temporal" engine) | trigger/action0, action1, action2, frame_fire | event3, event4 |
| 7 | shifter1 (plain) | busy, done, serial, serial_or_idle | start, shift, sample, serial_in |
| 8 | sram1 bank + CRC (`fabric_crc`) + coded shifter (`fabric_shifter`, the "packet" engine) | crc_out, crc_ok, coded_serial, coded_active | CRC absorb, emit, init, data (selector sinks 77-80) |
| 9, 11, 12, 14 | LUT4 + register (one each) | q, q_n (11, 12, 14 also carry lane B status/actions) | a-d |
| 10 | timer2 | tick, rise, fall, level | start, stop, aux |
| 13 | timer3 + sequencer B (`grid_sequencer`, "lane B") | tick, rise, fall, level | start, stop, aux; lane B events 43-45 |

Switch box (`grid_switch`, one per cell, 15 in total, 20k):
- 4 tracks per direction, 1 bit wide, combinational (`hop_cycles 0`).
  No hop is registered, and nothing in the switch holds a pulse. Where to
  register routes, and how an event survives a registered or multi-hop
  path, is design work for step 3, not something today's switches provide.
- Each output picks zero, one of the 4 local outputs, straight, or one of
  two turns. That is a 3-bit selector per track per direction.
- Tracks 0-1 turn only horizontal-then-vertical and tracks 2-3 only
  vertical-then-horizontal. There are no track changes and no U-turns, so
  no combinational cycle is possible.
- Sink selectors (`route_input`) are 5-bit: constant 0/1, own cell's 4
  local outputs, or any of the 16 arriving tracks.

The grid's own logic (177k of the 358k) is mostly configuration storage:
1152 DFFE + 852 SDFFE for switch words, sink selectors, LUT truth tables
and timer words. It is reached through `grid_config_tree`, which has one
leaf per cell. The word map is scattered:
- base words 0-65;
- extension words 128-187;
- timer mode words 208-215;
- alternate contexts 112-116;
- lane core words on page 1.

### B. Control engines (four, overlapping)

| Engine | Where | What it does | Area |
|---|---|---|---|
| frame mode | `grid_stream_fabric` FSM (IDLE/READ/FIRE/TRANSFER/WRITE) | reads 1-2 words from SRAM, fires shifter0/1, writes the result back; SPI and UART frames | inside stream fabric 30k |
| packet mode | `grid_stream_fabric` + cell 8 coded shifter | streams a byte sequence through the coded shifter (USB, Ethernet) | inside the stream fabric and coded tile |
| temporal mode | `grid_sequencer` lane A (cell 6 outputs) + `grid_page_loader` | a 16-row Moore table (event -> next row, actions), paged from SRAM, with alternate configuration contexts; I2C, JTAG | 26k + 7k |
| lane B | `grid_sequencer` in cell 13 | a second Moore table running beside lane A | 26k |
| lane mode | `grid_lane_core` (outside the grid) | the lane controller (A/C registers, 16 ops, WAIT/WANY on events, PULL/PUSH stream bytes, WCFG live writes) with its own timers, coded shifter and CRC | 241k |

Legal mode combinations (`grid_stream_fabric`: word 91 holds temporal
bit 0 and lane bit 2; word 93 holds packet bit 0):

| Combination | Legal? | Datapath |
|---|---|---|
| none (frame) | yes | host start -> frame FSM: reader -> shifter0 tx, shifter1 rx -> writer |
| frame + rx autostart | yes (excluded with temporal, lane and packet) | writer takes every received word |
| temporal | yes | sequencer A's actions 3:2 request frames; the cursors advance per frame; events include frame done |
| packet | yes | host start -> reader -> coded shifter (packet grant); the writer is not started |
| temporal + packet | yes | sequencer A runs alongside the packet engine; frame requests are suppressed; its events include packet stop and the first grant; a packet error aborts it |
| lane | yes | the lane core owns the pins, the reader/writer and the program load |
| lane + temporal | **rejected** (word 91 invalid) | none |
| lane + packet | accepted by validity, but inconsistent: lane wins the reader and done, while `!packet_mode` keeps the writer from starting | latent bug, not a supported mode |
| lane B (cell 13 sequencer) | alongside any of the above, from the same start; the host's done waits for both | |

So at most one of frame, packet and lane drives the stream ports at a
time, but temporal and packet work together, and lane B runs with
anything. Before any deletion, each legal combination's datapath must
have a replacement with a passing test, not just an idleness argument.

### C. Lane-core logic (`grid_lane_core`, 241k), function by function

| Function | Implementation | Area |
|---|---|---|
| sequencing | `grid_lane_controller`: pc, 64-instruction flop program buffer (loaded from SRAM at start), decode | 97k (about 78k of it the buffer) |
| state | A (16 bit), C (8 bit), action levels (4) | in controller |
| event detection | 8 event selectors over the 64 lines, latched pulse flags, WAIT/WANY consume | own 53k (shared with below) |
| edge detection | rise/fall registers on in0, in1, mesh0, mesh1 | small |
| local interconnect | 64-line set (pulses 0-31, levels 32-63) and about 15 six-bit selectors; every line registered | in own 53k |
| bit timing | 2 `grid_timer` (count, capture, resync) | 32k |
| bit/word conversion | `fabric_shifter` (parity, stuffing, NRZI, Manchester, CRC link) | 34k |
| CRC | `fabric_crc` (polynomial or additive) | 24k |
| word access | RD of 10 readbacks (rx word, status, captures, CRC, inputs, stream counters); SHIFT (tx word = A); WCFG of the core's own words | in controller |
| stream access | PULL/PUSH through the shared reader/writer | in controller |
| mesh interface | 2 mesh inputs, 3 pad outputs with value/enable selectors | small |

Shipped lane designs use 1 timer, 1 coder and at most 3 lines per input
(census, LANE_CORE.md).

### D. SRAM and stream paths (top-level, 96k)

- **Memory:** 2 x 1 KiB SRAM macros (`grid_stream_memory`). Each bank
  has one port, arbitrated among the host, the page loader or lane
  program load (which borrow the host port), the stream reader and the
  stream writer. Bank routes are set by a configuration word.
- **Stream reader / writer** (`grid_stream_reader/_writer`, 2-byte FIFOs):
  - one reader feeds shifter0's tx word (frame mode), the coded shifter
    (packet mode) or the lane controller's PULL;
  - one writer takes shifter1's rx word, coded rx or PUSH.
- **Word links:** shifter tx/rx words travel by dedicated wires from the
  stream fabric to the shifters in cells 3, 7 and 8 and to the lane
  core. They are not part of the mesh, and the contract describes them
  per mode.
- **Host link:** `grid_config_tree` for configuration (root plus 16
  leaves, 3-cycle latency); host byte access to SRAM through the arbiter.

### E. Duplication and dead weight

- Timers: 4 in the grid + 2 in the lane core.
- Shifters: 2 plain + 1 coded in the grid + 1 coded in the lane core.
- CRC: 1 in the grid + 1 in the lane core.
- Sequencing: 2 Moore sequencers + 1 lane controller + the frame FSM +
  the packet FSM: five control engines. The legal combinations are in the
  table under B; at most one of frame, packet and lane drives the stream
  ports at a time.
- Interconnect: the mesh (tracks + 43 sink selectors + 4 CRC selectors)
  and the lane core's private 64-line crossbar.

### F. What the contract has become

`architecture/grid_5x3.json` has these top-level sections: `grid`,
`bit_network`, `resources`, `memory`, `configuration`, `temporal`,
`lane`, `lane_core`.
- `grid`, `bit_network` and `resources` describe the spatial fabric.
- `temporal`, `lane` and `lane_core` each describe a control scheme with
  its own events, actions, lines and word ranges.
- `configuration` has 38 keys of special-case word ranges.

The compiler has to know all of them: the routing model covers only the
mesh, and lane designs bypass it entirely (`grid_lane.py` never routes).

## Step 2: where the lane-core functions go

### Decisions D1-D6 (SUPERSEDED by the Active plan; kept for the record)

Target picture (illustrative; the real arrangement is the 5 x 3 grid,
drawn in step 5):

```
                 configurable bit/event routes
       ┌─────────────┬─────────────┬─────────────┐
       │ timer       │ logic+state │ shifter     │
       │      [switch + local logic/state]       │
       ├─────────────┼─────────────┼─────────────┤
       │ logic+state │ CRC         │ I/O         │
       │      [switch + local logic/state]       │
       ├─────────────┼─────────────┼─────────────┤
       │ shifter     │ timer       │ logic+state │
       │      [switch + local logic/state]       │
       └─────────────┴─────────────┴─────────────┘
                │                 │
          explicit word/stream connections
                │                 │
              SRAM 0            SRAM 1
```

- **D1. Mesh.** The 5 x 3 switch mesh with configurable neighbour
  connections stays as the starting point. There is no global all-to-all
  crossbar. The turn restrictions and the four-track width are
  candidates to measure (steps 3 and 6), not fixed assumptions.
- **D2. Control is distributed logic + state.**
  - The control primitive is the **logic+state cell**: the existing LUT4 +
    register, extended so one cell can do a Boolean decision, remember
    state (hold, set/clear), detect an edge, or capture an event.
  - The compiler connects several such cells through the mesh to make a
    protocol's state machine.
  - There is **no instruction fetch**. The lane controller, the page
    loader and the frame and packet FSMs retire as their protocols
    migrate. (Refined below: a table state-machine tile is kept for
    sequencing.)
  - Whether to merge a cell physically with a switch box is an
    implementation choice to measure, not a prerequisite.
  - (Refined below: the two-event table becomes the state-machine
    tile.)
- **D3. Time-critical work stays in specialised tiles.** Timers generate
  timed events; shifters serialise, frame and code; the CRC computes
  checksums. They run concurrently. Logic+state cells connect their
  events and decide what happens next.
- **D4. Word and stream paths are explicit and bounded.**
  - SRAM, shifters, CRCs and word-processing resources connect through
    documented paths with valid/ready flow control.
  - Each word sink lists the sources it can take: there is **no
    all-to-all word crossbar**.
  - Useful direct links (coded shifter -> CRC) are local fast paths the
    compiler sees.
  - Word-processing resources (compare -> bit, gate <- bit, escape,
    split, interleave) are prototyped in `reorg/wnet.v`. Their reach is
    a listed set per sink.
- **D5. Configuration defines the circuit; distributed state runs it.**
  - The host loads switch and tile settings.
  - During a run only registers and tile state change.
  - Runtime configuration changes (WCFG, alternate contexts) are added
    only where a protocol and a test show the need.
- **D6. No logic on every track.** Sticky events, edge detectors and
  general computation are not added to every track or sink by default.
  - First provide enough independently routable logic+state sites to
    express the protocols.
  - Then measure where adding capability to a switch or sink improves
    mappings.
  - The sink edge modes proposed earlier in this section are withdrawn
    as a default.

### Critique of D1-D6, with measurements, and the refinement

**Measured (D2 sizing).** The I2C target's control (program B, 13
states; `reorg/i2c_target_fsm.v` and `i2c_target_onehot.v`, yosys
`abc -lut 4`):

| | Logic+state cells only | Table state-machine tile |
|---|---|---|
| cells | 13 registered + 6 combinational = 19 LUT4 cells (binary encoding: 4 FF + 41 LUTs) | 1 |
| mesh nets | about 50 (every cell input is routed) | 11 (7 events in, 4 actions out) |
| configuration flops | about 19 x (16 truth + 4 x 5-bit selects) = 680 | 16 rows x 19 = 304 |

The grid has 4 LUT4 cells today, and the heaviest shipped workload
routes 9 nets in 2 tracks.

**Problems this exposes.**

1. **Pure LUT composition does not fit (D2 as written).** One
   control-heavy protocol needs about 5x today's LUT cells and about 5x
   the heaviest mesh load; two at once do not fit 15 cells. FPGAs make
   this work with thousands of LUTs. A 15-cell fabric cannot.
   Control-flow-heavy machines need a denser primitive.
2. **"No controller tiles" and "specialised tiles for time-critical
   work" (D3) are the same argument.** A table state machine (states x
   two conditions -> next, actions from the state) is a fixed-function
   tile like a timer:
   - it has no instruction set, no word datapath, no fetch from SRAM,
     and no private wiring;
   - its events and actions are mesh pins;
   - its table is configuration (D5).

   What made the lane controller wrong was its CPU shape (A/C
   registers, readback of every tile's words, WCFG, a 64-instruction
   buffer) and its position beside the mesh, not the existence of a
   state-holding tile.
3. **Simultaneous conditions belong in LUT cells, not rows** (the
   prototype sweep): START/STOP qualification fixed a latency bug that
   a row-based check has. So the two primitives have different jobs.
   - **Glue:** qualify, gate, edge-capture, sticky event, small
     counters' compare. This goes in logic+state cells.
   - **Sequence:** wait, branch, emit actions. This goes in a
     state-machine tile.
4. **Mesh load and timing (D1).** Today's mesh is 1 bit, 4 tracks and
   combinational. More control nets mean longer combinational paths
   (cell -> several switches -> cell). Step 3 must register at least
   every logic+state cell output, so any path is one mesh traversal per
   clock. The latency the compiler sees is then a fixed number of clocks
   per cell boundary crossed.
5. **Concurrency is bounded by the stream ports, not just the mesh
   (D4).** There is one reader and one writer today, so two concurrent
   protocols can only stream one direction each. Two readers and two
   writers (one pair per SRAM bank) are needed for two full protocols.
6. **Word stages can grow into a zoo (D4).** Compare, gate, split,
   interleave and escape are justified by the 8 shipped programs. A new
   stage must come from a protocol census, not per protocol. The reach
   of each is a listed set, not all-to-all (the `wnet.v` prototype's
   any-to-any selection is to be restricted to those lists).
7. **Pins.** There are 2 inputs and 3 outputs today. Two concurrent
   protocols (for example an I2C target and a UART) already need 4
   inputs and 3 outputs. The I/O tile has to grow (step 3's eight pads).

### Refined decisions (SUPERSEDED: the table tile and the LUT-tile turns were both withdrawn; see the Active plan)

- **D1** as above. In addition, every logic+state cell output and
  every tile output is registered (step 3 fixes the per-hop rule).
- **D2 (refined; the table-tile half VETOED by the user, 2026-11-26).**
  Distributed logic+state is the **baseline**. A table state machine
  still bundles state and transitions into a specialised cell. Two fixed
  instances could become a bottleneck or steer the compiler back to
  centralised control. So it is only a **comparison** in step 3d, added
  only if the results show a meaningful need, and then independently
  assignable through the mesh. The 19-cell / 50-net estimate above is
  what the slice tests on real hardware. The text below is kept as the
  vetoed proposal:
  - **logic+state cells**: the existing LUT4 + register, extended with
    a set/clear (sticky) mode, for glue: qualification, gating, edge and
    event capture, small decisions. Target count: enough for two
    protocols' glue at once. The I2C target needs 2 (START, STOP); the
    count is set by the step 6 mappings.
  - **state-machine tiles**: a table of 16 rows. Each row holds 4
    actions and two (event -> next) conditions, otherwise stay; there is
    a halt row. Each tile has 7 event sinks and 4 action outputs. It has
    no instruction fetch, no word datapath and no configuration writes.
    There are two, at the positions of today's two sequencers.

  Event storage (latching) is not built in. Where a protocol needs it, a
  logic+state cell in sticky mode provides it, so it is paid only where
  used.
- **D3, D5, D6** as above.
- **D4 (refined).**
  - The word network has explicit reach lists.
  - There are two readers and two writers, one per SRAM bank.
  - The coded shifter -> CRC link is a local fast path.
  - The word stages are compare -> bit, gate <- bit, split, interleave
    and escape, each a placeable resource with its own reach list.
- **I/O.** Pads grow to the step-3 count (8). This is a constraint on
  steps 3 and 5.




### What the lane programs actually do

The 8 shipped lane programs (compiler `circt_lab/lanes/*.lane`), broken
down by operation:

| Operation | Programs | Kind of work |
|---|---|---|
| move a byte stream -> shifter (PULL, SHIFT, WAIT coder.stop) | uart_tx, spi_target, slip_uart_tx | word flow |
| move a shifter -> stream byte (WAIT coder.word, RD rx_word, PUSH) | uart_rx, rx_tagged, spi_target, i2c_target, lin_checksum | word flow |
| count words, stop at the end (SETC/LOOP, RD stream_bytes_left, JZ/JNZ) | all but i2c_target | word flow (a length) |
| fail on a bad word (status bit 6 -> FAIL) | uart_rx, lin_checksum | bit event: `coder.word_bad` is already a line |
| tag each byte with its status (push status AND 0x40) | rx_tagged | word flow (a second byte per word) |
| check a checksum (push the CRC value, compare with 0xFF) | lin_checksum | bit event: `crc.ok` is already a line |
| send a 16-bit capture as 2 bytes (RD capture, PUSH, SHR x8, PUSH) | pulse_period | word flow (width 16 -> 2 x 8) |
| compare a received byte with a constant, branch (XOR 0x90, JNZ) | i2c_target | word -> bit predicate, then bit control |
| replace bytes by escape pairs (0xC0 -> DB DC, 0xDB -> DB DD) | slip_uart_tx | word transform (stream filter) |
| wait for pin edges and levels, set an output level, start a shifter (WAIT in1.fall, ACT, FIRE) | i2c_target | bit control (events -> actions) |

Only i2c_target uses bit-level control flow. Everything else is
**word flow** with a little word processing (length, tag, split,
compare, escape) or a **bit event** the fabric already produces. The
lane controller mixes the two in one 16-bit CPU-like engine with a 64-entry
program buffer. That is why it ended up beside the mesh: it needs every
tile's words *and* every tile's bits.

### Proposal: split bit control from word processing (the word split stands, in the Active plan; the control placement is open there)

| Lane-core function | Goes to | Reason |
|---|---|---|
| bit timing, bit/word conversion, CRC | the existing tile resources in their cells (timers 2/5/10/13, shifters, CRC); the lane core's copies are removed. The coded-shifter -> CRC link stays as a documented local fast path | they already exist in the grid; duplication is a credible cause of the congestion |
| edge detection (rise/fall of a routed signal) | **sink selectors**: each sink selector gets a mode (level, rise, fall) and one flop | the consumer chooses which edge it needs; this costs one flop per sink and no extra mesh tracks. Pads (cell 0) and timers keep their own edge outputs. |
| events (a pulse held until it is consumed) | **inside the control resource that consumes it**, at its event sinks | holding a pulse is part of how a waiting state machine reads it; the mesh stays stateless |
| bit sequencing (state, wait on an event, set action levels, start a tile) | **small distributed control resources**: a Moore sequencer as a cell resource (like today's `grid_sequencer` in cells 6 and 13): event sinks from the mesh, action local outputs onto the switch, rows held in the cell. For very small state machines, LUT4 + register cells. | this is a spatial resource like a timer: it is placed and routed by the compiler, and there can be several, each in its own cell. It holds no words. |
| word flow between a shifter and SRAM (PULL/PUSH, counting) | **the word path** (step 4): the stream reader feeds a shifter's tx word, and a shifter's rx word feeds the stream writer, with valid/ready flow control. The shifter's `auto_pull`/`auto_push` already do this. The descriptor length ends the stream and raises `done`. | no instruction is needed to move a byte; flow control replaces WAIT + PULL |
| word processing (tag, split 16 -> 8, compare with a constant, escape) | **word-path stages** between the stream ports and the tiles (step 4 defines them): a compare stage whose result (`match`) is a **bit local output** onto the mesh; a tag/split stage at the writer; an escape stage at the reader | each is a fixed, small function on the word path; its result reaches bit control only as a bit through the mesh |
| done / error of a run | **status sinks** in the host-interface cell: `done` and `error` are mesh sinks any resource can drive (a sequencer's halt, `coder.word_bad`, `crc.ok` low) | a run's end is a bit event like any other; no engine owns it |
| live configuration writes (WCFG) | **not carried over**; alternate configuration contexts selected by a sequencer's action bits instead (as today's temporal contexts) | a write port into other cells' words is the fabric-wide wiring that broke routing in 7193f31 |
| program buffer (64 x 16 flops, 78k) | **removed**; sequencer rows live in their cell (16 x 16 today) | a Moore table per sequencer is enough for bit control once word work leaves it |

### What this removes

- The lane core: its controller, private 64-line crossbar and duplicated
  tiles.
- The frame FSM and packet FSM in `grid_stream_fabric`. They become word
  paths (reader -> shifter, shifter -> writer) plus a sequencer where
  ordering is needed.
- The `temporal`, `lane` and `lane_core` contract sections, collapsed
  into:
  - resources (sequencers among them);
  - sink modes (edges);
  - the word-path description.

### Evidence: i2c_target as a sequencer (the only real bit-control program)

**Today's row format** (`grid_sequencer`: one event per row, true/false
next) does not carry it:
- The byte loop waits for `coder.word` *or* a STOP edge (`in1.rise` with
  SCL high).
- Two rows alternating between those tests miss a one-clock pulse that
  arrives while the other row is current. Fixing that needs pulse
  latches plus a CLEAR operation, which is lane-controller state again.
- The encoding also comes out at about 18 rows.

**A two-event row fits.** Each row is: actions, (event A -> next A),
(event B -> next B), otherwise stay; A has priority. Event 0 is
`always`. That is 4 + 2 x (3 + 4) + 1 (halt) = 19 bits. The encoding
uses 8 event choices (a 3-bit select): `always` plus 7 routed events
(in0 level, in1 level, in0.fall, in1.fall, in1.rise, coder.word, match).
It has 4 actions (a0 drive SDA low, a1 start
the coder, a2 error, a3 gate the rx word into the stream writer):

| Row | Actions | A -> | B -> | Program lines |
|---|---|---|---|---|
| 0 free | none | in1 level -> 1 | | WAIT level:in1 |
| 1 | none | in0 level -> 2 | | WAIT level:in0 |
| 2 idle | none | in1.fall -> 3 | | WAIT event:in1.fall |
| 3 | none | in0 level -> 4 (START) | always -> 0 | RD inputs, AND 1, JZ free |
| 4 | a1 | always -> 5 | | FIRE |
| 5 | none | coder.word -> 6 | | WAIT event:coder.word |
| 6 | none | match -> 7 | always -> 11 (skip) | XOR 0x90, JNZ skip |
| 7 ack | a3 | in0.fall -> 8 | | WAIT event:in0.fall |
| 8 | a0 a3 | in0 level -> 9 | | ACT 1, WAIT level:in0 |
| 9 | a0 a3 | in0.fall -> 10 | | WAIT event:in0.fall |
| 10 | a1 a3 | always -> 12 | | ACT 0, FIRE |
| 11 skip | none | in1.rise -> 14 | | WAIT event:in1.rise |
| 12 byte | a3 | coder.word -> 7 (pushed: a3 gates the rx word into the writer) | in1.rise -> 13 | WANY word or in1.rise |
| 13 | a3 | in0 level -> 15 (STOP) | always -> 12 | RD inputs, AND 1, JZ byte |
| 14 | none | in0 level -> 0 | always -> 11 | skip's STOP check |
| 15 | none | halt | | HALT |

Exactly 16 rows. `match` is the word-path compare stage's bit output
(rx word == 0x90). The address byte arrives in row 5 with a3 low, so it
is not pushed. Every data byte arrives in row 12 with a3 high, so it is.

Each row is evaluated on every clock, so a pulse that arrives *while the
row that tests it is current* is seen. Whether that is enough is
**not yet shown**:
- a pulse can arrive while a different row is current (for example, a
  one-clock pass through a check row);
- two events can arrive in the same clock, and priority drops one.

Whether to remove the latches has to be settled by tests (STOP, byte
completion, closely spaced and simultaneous edges), with and without
latches. The first such test is below ("Prototype test").

**Hypothesis (prototype, not decided).** The sequencing resource is a
two-event Moore sequencer:
- 16 rows of 19 bits;
- 7 routed event sinks plus `always`;
- 4 action local outputs;
- event storage to be settled by test.

It is a cell resource like a timer. Today's one-event rows are the
special case B = always. One hand-worked I2C target does not establish
that 16 rows, two conditions per row and the event semantics cover
JTAG, USB, Ethernet or concurrent protocols. Each is re-encoded and
tested before this becomes the architecture. What is still to settle: the count (two, as
today, or more) and whether pages stay. The paging question is decided
by whether any migrated sequencer protocol (temporal I2C, JTAG) needs
more than 16 rows; that is checked when each is re-encoded.

### Prototype test (2026-11-26): `make reorg-proto-test`

Files:
- `experiments/grid_fabric/reorg/seq2.v`: the two-event sequencer.
  `LATCH=1` adds event storage: flags clear on a state change, except
  pulses arriving that clock other than the one taken.
- `seq2_i2c_target_tb.sv`: an I2C controller model on open-drain
  SCL/SDA, with:
  - 2-flop synchronisers and registered edge pulses (the proposed sink
    edge modes);
  - a shifter stand-in (start on a1, sample on SCL rise, word pulse after
    8 bits);
  - the compare stage (`match` = rx word == 0x90);
  - the writer gate (word with a3 pushes).

  The scenario: a write to another address (no ACK, back to idle), then
  a write to 0x48 with four bytes (every byte ACKed and pushed, the
  address byte not pushed), then STOP right after the last ACK (a clean
  halt).
- Two programs:
  - **A**, the table above: SDA edges as events, then a row checks the
    SCL level, which is the lane program's shape;
  - **B**, 13 rows: START and STOP made by a **LUT4 + register cell**
    from routed SDA, SDA-delayed and SCL (an SDA edge while SCL is high,
    in the same clock). The events are then SCL level, SDA level, SCL
    fall, START, STOP, word and match.

Sweep of 245 timing points: SCL high 4-20 clocks, SDA setup before the
SCL rise 1-8, SDA hold after the SCL fall 1-8.

| Variant | Pass | Fails only when |
|---|---|---|
| A, no latches | 145 | setup <= 2 clocks (a data change just before the SCL rise is read as START or STOP), or setup + hold <= 6 |
| A, latches | 145 | the same points |
| B, no latches | 215 | setup + hold <= 4 (SCL low for 4 clocks or less: the ACK is driven about 5 clocks after the SCL fall, which is synchroniser + edge register + row) |
| B, latches | 215 | the same points |

Findings:
- **Event storage made no difference at any timing point**, for this
  protocol. Two events never coincide in a way priority drops: a word
  pulse comes on an SCL rise, and STOP needs SCL already high. No pulse
  arrived while another row was current.
- This is evidence for one protocol, not a general rule. Latches stay
  an option (the prototype keeps `LATCH`) until JTAG, USB, Ethernet and
  concurrent runs are tested.
- **The failure that mattered was sampling latency, and the lane
  program has it too.** "SDA edge, then check SCL one row later" misreads
  a data change that comes within 2 clocks of the SCL rise. Qualifying
  the edge in the same clock in a LUT4 cell removes it and shortens the
  program from 16 rows to 13. The general point: **conditions that must
  be simultaneous belong in combinational/LUT logic at the event's
  source, not in sequencer rows.**
- The remaining limit is response latency: SCL must be low for at least
  5 clocks. I2C fast mode's t_LOW of 1.3 us is 13 clocks even at 10 MHz.
- The shifter is a stand-in, not `fabric_shifter`. Porting to the real
  shifter, and running the existing pin test (`test_lane_i2c_target.py`)
  against the reorganised fabric, belongs to step 7.

### Word network prototype (2026-11-26): `reorg/wnet.v`, `make reorg-proto-test`

Structure:
- Sources: reader, shifter rx, shifter status, timer capture, and the
  output of each of 5 stages (escape, compare -> bit, gate <- bit, split
  16 -> 8, interleave).
- Sinks: writer, shifter tx, and the stage inputs.
- Flow control: valid/ready.
- Reach: each sink selects from **its reach list** (not all-to-all), and
  a source feeds at most one sink.
- Every stage registers its output, so no selection closes a
  combinational loop.

Under random backpressure on every endpoint (9 seeds) these all pass:
- SLIP tx and HDLC tx (one escape stage, two constant sets);
- a chain of escape -> compare -> tx;
- an I2C receive: compare drops the address while the gate bit is low
  and passes data while it is high, and `match` follows each word;
- status tagging by interleave;
- a 16-bit capture split into bytes;
- two configurations running at once;
- refusals: a source outside a sink's reach list, and one source to two
  sinks. The test found that an invalid configuration still drained
  sources, **losing words**. Each source's ready is now gated by
  validity.

**Step 2 status:** the word network and the coarse-tile foundation are
settled (Active plan). Control is an open comparison in step 3. This
paragraph previously called the distributed-logic baseline decided; that
is superseded.

### Open questions (SUPERSEDED list; the open items are in the Active plan)

1. ~~Sequencer size~~ (two-event rows, 16 rows, above). **Paging: not
   carried over.** No shipped program needs more than 16 rows:
   - JTAG IDCODE/USER: 3 rows (`test/data/grid-jtag-*.json`);
   - temporal I2C: one page (the pager's I2C test splits it into 8-14 row
     pages only to exercise paging);
   - i2c_target: 16;
   - paging was exercised otherwise only on synthetic 20-150 row
     programs.

   Proposed: the page loader (7k) and SRAM context loads go; reopen
   this if a migrated program exceeds 16 rows. **Count (proposed): two**, in cells 6 and 13
   as today. Pure word-flow protocols (UART RX/TX, SPI target, LIN,
   pulse period) need no sequencer, since their end is the stream length
   and a status sink. So two sequencers allow two control-heavy protocols
   at once. The concurrency tests in step 7 revisit this.
2. **Word-path stages** (open; fixed stages risk recreating hardwired
   special paths, so the test is whether each stage can be independently
   assigned and connected like any other resource). Should they be a fixed set (compare, tag/split,
   escape), with each new protocol need adding a stage? Or a single
   small word processor on the stream path (not on the bit mesh) for
   the rare transforms (SLIP), with the fixed stages for the common ones?
3. **Edge modes on every sink, or a subset?** A subset could be timer
   start/stop/aux, shifter shift/sample, sequencer events.

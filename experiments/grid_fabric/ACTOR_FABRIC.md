# Actor fabric: a stateful dataflow CGRA for protocols (2026-11-28)

**Status: the active architecture direction (user, 2026-11-28).** It evolves
the existing 3 x 5 / 3 x 4 mesh (FABRIC_REORG.md); it is not a new design
from scratch. The current chip (`mesh_3x5_L3S`) stays the physical
baseline until each step below is measured against it.

**Aim.** The Plasticine of communication protocols: specialise around the
recurring patterns of protocol work, which are irregular, stateful,
event-driven and bound to real-time external timing. Not a Cerebras-style
array, and not a miniature FPGA.

## 1. The model: stateful actors, not instructions

Every resource is an actor:

    inputs + state  ->  outputs + updated state      (every clock)

configured once, then running on its own. A timer generates events, a
shifter consumes and produces bits and bytes, a CRC absorbs and emits, a
control actor decides what happens next. Nothing needs a program counter
or an instruction fetch, and no central entity tells the shifter to shift.
This is one abstraction for the hardware (a PE) and for the compiler (a
node with typed ports and a state machine).

Execution styles, chosen per computation by the compiler:
1. **spatial**: dedicated actors in a pipeline (a shifter feeding a CRC);
2. **temporal**: one actor steps through phases over time (a control
   actor's states);
3. **spatio-temporal**: spatially connected actors, one of them reused
   over time (the shifter reused per byte while a control actor steps the
   transaction).

Temporal execution is **localised**: it lives in an actor's own state,
never in the network.

## 2. State in the PEs, not in the network

Routing is static: connections are fixed for the run; local actor state
decides whether data passes and what it means.

- *The network decides where information goes; the PEs decide what it
  means.* When the routing network also implements the protocol FSM
  (today's contexted switches), the two concerns entangle: a route is
  correct only in some states, routes through an FSM's switch must stay
  identical in every context, FSMs get replicated to the cells that read
  them, and every switch pays for per-context selector storage.
- **Dynamic routing only where it saves real communication resources.**
  The measurement says it does not today (FABRIC_REORG.md O2): across all
  19 mapped programs only I2C, SPI and SWD use switch contexts, and the
  contexts change at most 3 of a cell's 22 selectors, always the FSM's
  own sinks and one track leaving its cell. That is an actor choosing
  among its inputs, done in the network because the state lived there.

Evidence that the actor style already works here: USB and Ethernet map only
because their control became stateful logic (LUT sequencers, armed fires)
with static routes; their switches use no contexts.

## 3. PE granularity (the main determinant of success)

Coarse enough that a protocol primitive is one PE and its routes are few;
fine enough that the mix is not rigid. The set:

| PE | State | Role | Today |
|---|---|---|---|
| **Coded shifter** | frame position, bit/word registers, coder state | bits <-> words, framing, NRZI/stuffing/Manchester, abort | `fabric_shifter` |
| **Timer/counter** (merged) | count, threshold, phase | generate time events, or count events; zero threshold, capture, resync | `grid_timer` + `fabric_counter` |
| **CRC** | residue | absorb/emit, check; optional fast path to a shifter | `fabric_crc` |
| **Control actor** | 2-bit state, transitions | the protocol FSM: per state, outputs selected from its inputs | contexted switches (moves here) |
| **Registered LUT logic** | LUT registers, host flags | glue, sequencers, line-state logic | `mesh_logic` |
| **Word actor** | stage registers | escape, compare, gate, split on byte streams | `wnet` stages |
| **I/O** | edge detectors | qualified pin events, pad drive | `io_tile` |

The timer and counter merge (their operations overlap: a counter is a
timer that steps on an event instead of a clock): one assignable
timing/counting PE frees cells for other primitives. Ethernet exhausts the
four timers while USB uses both counters, so a merged pool is used better.
It must keep zero-threshold behaviour, capture and resynchronisation; its
area against a timer plus a counter is measured before the merge.

**Control actor, sized from the workload** (all 19 programs: at most 4
states, 7 transitions, 4 muxed outputs per machine, 3 machines per
program, one of them a replica that exists only because of context
routing): 6 inputs (sinks), a 2-bit state, 2 transition rows per state
({input select, next}), and 4 outputs, each a per-state selection among
its inputs and the constants. This is ctx_switch's transition logic and
per-context sink selection moved out of every switch into one PE kind.
Open question to measure: whether its outputs must be registered (one
clock, the REG=1 rule) or may pass combinationally with the compiler's
loop check (the kind's `comb` paths); the I2C target's fastest bus (10
clocks per SCL period) is the test.

## 4. Interconnect: hybrid, extremely restrained

1. **Local mesh (primary).** Static switches, today's four 1-bit tracks per
   direction and turn rules, one selector set per switch.
2. **Direct fast paths (optional).** Point-to-point links for pairs that
   exchange a bit every clock: shifter -> CRC (today's `crc_link`),
   timer -> shifter (shift/sample tick). The compiler may use or ignore
   each; the shifter and CRC stay independently usable through the mesh.
3. **Sparse global signals.** A handful of global event lines (start,
   abort, selected broadcasts such as a bus clock edge), any PE output can
   drive one by configuration and any sink can read one. Not another
   64-line signal space.
4. **Express links: not planned** unless measurement shows the mesh
   cannot carry a workload.

Words and streams stay a separate, explicit network (the word actor and
the SRAM reader/writer); its reach lists and single source/sink are
reviewed (FABRIC_REORG.md O8): one protocol can need several streams.

## 5. Optimise usable capacity, not installed capacity

Scalability is useful capacity per area: if adding PEs congests the
network so that few can be used, nothing was gained. Today's mesh shows
it: more timers or CRCs without more stream connectivity add little.
Every candidate is reported as
- complete protocols that map and pass at the pins (the workload grows
  with machine-heavy protocols: FABRIC_REORG.md O3 gate);
- PEs used per program (and why the rest cannot be), tracks used,
  configuration bits, area, timing and physical routing;
- failures classified proven (counting, oracle) or heuristic.

## 6. Migration from the current mesh (each step measured; baseline kept)

| Step | Change | Evidence before the next |
|---|---|---|
| A1 | Compiler: lower `machine`s to control actors (an actor IR node: inputs, state, transitions, per-state outputs); muxed signals become actor outputs on static routes. Model the control actor in the contract; map it first onto logic cells (LUT encoding) to measure. | All 19 programs compile with every switch single-context; I2C fast bus timing |
| A2 | RTL: control-actor PE (one kind), static switches (no `ctx_switch` contexts). | Mesh- and chip-pin tests; area against `mesh_3x5_L3S` |
| A3 | Merged timer/counter PE (zero threshold, capture, resync). | Area vs timer + counter; programs map with the merged pool |
| A4 | Fast paths (timer -> shifter) and 2-4 global event lines. | Routing demand with/without; programs map |
| A5 | PE mix for usable capacity on 3 x 4 and 3 x 5 (logic connectivity, CRC count, word actor, streams). | Workload sweep incl. the new protocols |
| A6 | Physical: GDS of the actor mesh beside the baseline's. | Routing, timing, area, run time |

Static switches should also be the physical win: the contexted switches
and their configuration latches are where area and the store's timing
artefacts came from. Measured (local yosys, CI IHP liberty, whole 3 x 5
chip, same tiles):

| Switches | Chip area (µm²) | Config latches |
|---|---|---|
| contexts on 6 cells, every selector per context (`mesh_3x5_L3`) | 404,621 | 4,319 |
| contexts on 4 cells, tracks 0 and 2 per context (`mesh_3x5_L3S`, the chip) | 371,785 | 3,551 |
| **all static** (no contexts; programs with machines do not map yet) | **336,081** | 2,792 |

So the control-actor PEs that take over the machines (at most 3 per
program today, 2 without the replica) must cost less than ~36k against
the current chip, ~69k against the original, to be an area win too.

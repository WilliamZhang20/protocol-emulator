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

## 7. A1 results: machines on logic cells, static routes (2026-11-28)

Compiler `83db3f4` (protocol-emulator-compiler, `Lowering.machines_to_luts`):
on a contract with no contexted cell, every machine becomes one-hot state
registers in logic tiles and every machine-selected signal a registered
LUT output; all switches are single-context. Baseline: the contexted chip
`mesh_3x5_L3S`. Mesh-pin tests (`test_mesh_compiled`), same peers.

**Mapping.** On the chip's own tile mix, all switches static, 17 of 19
programs map (SPI and SWD included); the two I2C programs need 6 logic
cells (44 LUTs: bus 18, ack 11, 15 delay LUTs) and the chip has 3. With
6 logic cells (three timers become logic) both I2C programs map, but the
timer-hungry programs (UART, Ethernet, the controller programs) lose
their timers: the timer pool, not the logic, is then short.

**Pins.**

| Program | Contexted (L3S) | A1 static |
|---|---|---|
| 15 machine-free programs | pass | pass (Ethernet: both tests) |
| SPI | pass | pass |
| SWD | pass | pass, after two compiler fixes (below) |
| I2C target: address, NACK, repeated START (40 clocks/half) | pass | pass |
| I2C target: fast bus, 10 clocks per SCL period | pass | **fail** (NACK) |
| I2C + UART, I2C at 10 clocks per period | pass | **fail** |
| fastest SCL that passes (sweep, hold 1) | 10 clocks per period | 16 clocks per period |

**Latency (moving state does add it).** A contexted switch changes state in
one clock and selects outputs combinationally. A registered-LUT machine:
- SWD mode, SPI select: each state's next value reads ≤ 4 signals, so one
  LUT per state, **one clock** (the compiler's direct path);
- I2C bus and ack, SPI open: **3 / 3 / 2 clocks**. Proven lower bound for
  the I2C bus: IDLE's next value depends on 7 signals, a 4-input registered
  LUT cannot compute it in one level, so ≥ 2 clocks on any LUT encoding.
  The third clock is the compiler's packing (heuristic, improvable).
  This bound holds for registered 4-input LUTs as tested (every LUT output
  a register, no combinational LUT path); it says nothing about a
  purpose-built control actor, which A2 measures;
- every selected output: +1 clock (a register), up to +2 for a nested
  selection (`rx.start`).
The fast-bus failure is this latency: from SCL fall to SDA driven for ACK
is transition (3) + output (1) + pad, longer than the 5-clock SCL low.

**Closely spaced events.** The LUT machine follows its source machine
exactly, `transition_clocks` late, whenever events are at least that far
apart (checked cycle by cycle on random events, now in
`test_fabric_lower`). An event within that window after a transition is
judged against the old state: for I2C, events 2 clocks apart diverge.
Simultaneous events resolve by row priority as before.

**Compiler fixes found by A1 (compiler failures, not hardware):**
derived registers started at 0 (SDA pulled low after reset), now at their
reset-state value; SWD's `sample = mode ? clock.rise : clock.fall` arrived
one clock after its `shift`, now the block's other timing inputs are delayed
to match (latency balance, only for shift/sample/in/CRC sinks).

**Routing.** Moving I2C's machines out of the switches spreads them over 6
cells that exchange their state: tracks 17 -> 67 (wirelength 28 -> 69) for
the I2C target, 25 -> 76 for I2C + UART. SPI 29 -> 31, SWD 18 -> 19.

**What A2's control actor must provide** (measured, not assumed): one-clock
transitions with wide event selection (I2C needs 7 signals per state), and
same-clock output selection (SWD's sample, I2C's ACK): registered outputs
were the open question in section 3, and they fail the fast bus. Its state
must stay in one PE: spreading a machine over LUT cells quadruples its
routes.

## 8. Functional-locality census (2026-11-28)

`locality_census.py` (compiler): every producer -> consumer pair the mesh
carries, per program, on the chip (`mesh_3x5_L3S`), all 19 programs.
Rate classes from the graph: `bit` (per bit or clock), `word`, `txn`.
Critical: a bit-rate signal into a pad, a shifter's shift/sample/in, a CRC,
or a timer/counter step.

| Pair (all programs) | Programs | Pairs | Critical | Mean hops | Max hops |
|---|---|---|---|---|---|
| shifter -> timer (frame start/stop) | 14 | 28 | 0 (word rate) | 1.5 | 3 |
| timer -> shifter (shift/sample tick) | 14 | 21 | 19 | 1.76 | 3 |
| pin -> shifter | 8 | 16 | 11 | 1.62 | 3 |
| shifter -> pad | 13 | 14 | 14 | **2.57** | 4 |
| shifter -> logic | 2 | 8 | 0 | 1.75 | 2 |
| logic -> pad | 2 | 6 | 6 | 1.33 | 2 |
| timer -> logic | 2 | 6 | 0 | 2.83 | 5 |
| timer -> counter | 4 | 4 | 4 | 2.0 | 5 |

The timer <-> shifter pair dominates (49 pairs, 14 of 19 programs, most of
the critical ones): the direct timer -> shifter tick link (A4) is supported.
Shifter -> pad is the longest critical pair. The shifter -> CRC link already
exists (`crc_link`) and is a hard placement rule (the shifter must sit west
or east of its CRC).

**Tile arrangements** (same tile multiset as the chip, all switches static,
the 17 programs that map on every candidate; sums over programs):

| Arrangement (rows top to bottom) | Maps | Tracks | Wirelength | Critical hops | Worst hops |
|---|---|---|---|---|---|
| chip: `T L I L T / S C S C I / T K L K T` | 17 | 234 | 248 | 114 | 5 |
| `T I T I T / S C L C S / K L T L K` | 17 | 215 | 232 | 106 | 5 |
| `T I L I T / S C T C S / T K L K L` | 17 | 214 | 229 | 103 | 5 |
| `T I T I T / C S L S C / K L T L K` | 17 | 224 | 236 | **98** | **4** |
| `I T L T I / C S K S C / L T K T L` | 17 | 223 | 236 | 102 | 5 |
| layouts without a shifter beside a CRC | 15 | | | | |

For these layouts and these 19 programs, on the compiler's routing model
(not physical routing), rearranging is worth 8 % of tracks and up to 14 %
of critical hops and does not change what maps. That does not show that
placement is second order in general: other layouts, a different PE mix,
new workloads or the physical router (congestion, wire length at the pins
and SRAMs) can change it. The first-order limits A1 found are
capacity and flexibility of the PEs: a machine needs one control PE, not
six logic cells, and the timer pool runs short as soon as cells are taken
from it. A1 shows the mix is tight; it does not show that a merged
timer/counter saves area or keeps every timer mode (A3 is a separate
experiment). Arrangement is revisited in A5 with
the new PE mix; the chip keeps its layout until then.

## 9. A2: the control actor, head to head with the contexted switch (2026-11-28)

**Hardware** (`mesh.v` `ACTOR=1`; default 0 keeps the chip unchanged): a
logic cell's second mode. A configurable state machine, independently
placed and connected: four states, two transition rows per state (one
clock, as `ctx_switch`), eight inputs (sinks; 6-7 stored where a
one-context cell's context-1 sinks would be), four locals selected per
state among the inputs and constants **combinationally** (as a contexted
switch's sinks). No program counter, no private timer/shifter/CRC. The
logic cells keep their LUT mode: a cell is either, per program (machine
programs and LUT programs never need the cells at once: I2C/SPI/SWD use
no LUTs, USB/Ethernet no machines).

**Compiler** (`Lowering.machines_to_actors`): one actor per machine; a
selection by another machine is that machine's output, routed as an input;
the mapper's loop check takes each output's combinational inputs (only the
inputs it selects; rows change the registered state) and refuses a
configuration that closes a loop.

**Head to head** (same 15 tiles, 3 x 5; contexted = the chip
`mesh_3x5_L3S`; A2 = every switch static, `ACTOR=1`):

| | Contexted (L3S) | A1 (LUT machines) | **A2 (actors)** |
|---|---|---|---|
| programs mapped (of 19) | 19 | 17 (I2C needs 6 logic cells) | **19** |
| mesh-pin tests | all pass | I2C fast bus fails | **all pass** |
| I2C fastest SCL (clocks per period) | 10 | 16 | **10** |
| transition / selected output | 1 clock / 0 | 3 / +1-2 | **1 / 0** |
| I2C target tracks (wirelength) | 17 (28) | 67 (69) | **25 (25)** |
| I2C + UART tracks (wirelength) | 25 (35) | 76 (80) | **31 (31)** |
| SPI / SWD tracks | 29 / 18 | 31 / 19 | 31 / 19 |
| whole chip area (µm², local yosys, CI IHP liberty) | 371,785 | — | **345,305 (-7.1 %)** |
| configuration latches | 3,551 | — | **2,825** |

All-static without actors is 336,081 µm²: the actor mode in the three
logic cells costs ~9.2k (~3k per cell). Machines use at most 2 actors per
program (the context replica is gone).

**Caveats.** The actor's combinational outputs make a structural loop
possible through the routing (the compiler refuses one per
configuration); static timing must cut those arcs (`set_disable_timing`
or case analysis) before A6, the GDS. The latency bound of A1 (two clocks)
is for registered LUT4s; the actor's one clock is by construction. The
workload is still the 19 programs: the full-protocol workload (receive
paths, handshakes, both directions) is the next gate before promotion.

## 10. The full-protocol workload: USB, Ethernet and I2C, both directions (2026-11-28)

The 19 programs are one demonstration per protocol, mostly one direction.
The workload now grows function by function, each with a peer written
from the specification that transmits and referees, compiled and
pin-tested on the chip (L3S) and every candidate (A2).

**USB low-speed device, receive** (`usb_device_rx.spt`): the host's
tokens, data packets and handshakes, NRZI decoded and destuffed, to the
host with their boundaries. New hardware, each a general mechanism:

- shifter **end lookahead** (`fabric_shifter` burst [13], `end_follows`):
  USB's end (SE0) comes after the last byte, so the tile holds each word
  until the next word's first sample or the end level, which tags it the
  packet's last. Proved for any word length 2-4 and any timing
  (`formal/fabric_shifter` ahead_bmc/ahead_cover: every word pushed once,
  in order, the pushed byte is the word, eop only as the frame ends).
- the shifter's **end level as a mesh sink** (level 34).
- **received packets to the host**: word-network bits 8/9 carry the eop
  and err tags to the writer; `mesh_soc` queues four descriptors {err,
  end}; host register 07 (count, overflow, error; a write pops), 1E/1F
  (end).
- the timer's **resync** input (grid_timer mode 3) from the compiler.

**USB low-speed device, answering** (`usb_device.spt`): after a data
packet with a good CRC16 the device sends the handshake its firmware
armed (ACK, NAK), by itself, inside the turnaround; it answers nothing
else. The bus sees every packet (the device's own answer comes back
through its receiver, so the tests read the whole transaction). New:

- **pins driven while a fabric level is high** (`pin dp: out = v while
  driving`): the drive window is the fabric's, not the host's.
- **packets out**: the reader tags a region's last byte eop and the
  word-port transmitter takes it (`tx_eop`), so a burst ends on a packet.
- the PID classifier is the word network's compare tap (DATA0/1: bits
  0x77 = 0x43), read by a four-state machine; the turnaround and the EOP
  (two bits of SE0, one of J) are a timer and two counters, no host step.
- peer (`usb_host`): transmits SYNC, CRC5/CRC16, NRZI, stuffing and EOP;
  decodes the chip's packets and referees its answer window (2 to
  `timeout` bit times), its EOP, the bit grid and its release of the bus.

| | Contexted (L3S) | A2 (actors) | 3 x 4 (L3) |
|---|---|---|---|
| usb_device_rx: maps / tracks / pins | yes / 14 / 2 of 2 | yes / 14 / 2 of 2 | yes / 14 |
| usb_device (OUT + handshake): maps / tracks / pins | yes / 51 / 3 of 3 | yes / 52 / 3 of 3 | **no**: three timers, two cells |
| usb_device_in (IN + data + CRC16): maps / tracks / pins | yes / 53 / 2 of 2 | yes / 45 / 2 of 2 | **no**: three timers |
| ethernet_rx (frames, FCS check): maps / tracks / pins | yes / 14 / 3 of 3 | yes / 14 / 3 of 3 | yes / 13 |
| i2c_target_rw (writes and reads): maps / tracks / pins | yes / 31 / 4 of 4 | yes / 41 / 4 of 4 | yes / 26 |

The machine's state gates the transmitter's start (`if link.DATA { go }
else { 0 }`), written at the shifter: on L3S the shifter's contexts hold
the states; a logic-cell reg reading the state does not map there (L3S's
logic cells have one context: a proven limit of that chip, which A2's
actor does not have). The 3 x 4 refusal is a resource limit (a receive
bit clock, the turnaround and the transmit bit clock are three timers).

**USB IN** (`usb_device_in.spt`): after an IN token the device sends
the armed data packet itself; the transmitter appends the CRC16 from a
linked CRC cell (`crc_tail_bits`), and its own packet comes back through
the receiver with the CRC bytes, a check of what went on the bus. The
transmitter starts on the transmit bit clock's first tick, so its first
bit is on the grid by construction.

**Ethernet receive** (`ethernet_rx.spt`, 10BASE-T at 40 MHz, four clocks a
bit): every rise of the line is on the half-bit grid, so a half-bit timer
resynchronised on rises samples the middle of each half; the SFD is the
first pair of rises one bit apart (the preamble's come two apart); the
end of frame is TP_IDL's Manchester code violation. New, each general:

- **a resync never removes a due tick** (`grid_timer` mode 3): an edge
  arriving as a tick was due used to reload the count and drop that tick
  (a lost sample per rise on a 2-clock half-bit grid); the tick now
  happens and the edge moves the next one. Formal reference model updated
  (prove and cover pass).
- **a Manchester code violation ends a lookahead burst** (`fabric_shifter`
  burst [13] with Manchester receive): the bit after the last byte, with
  equal halves, ends the frame like the end level and is neither data nor
  given to the CRC link (formal: the lookahead harness runs Manchester
  too, with a cover of a violation-ended packet).
- **a received packet tagged with the CRC check** (`check_crc`, shifter io
  [13]; the mesh wires a linked CRC cell's `ok` back to its shifter): the
  eop byte is tagged err when the FCS is wrong.
- peer `ethernet_station`: preamble, SFD, frame, FCS, Manchester, TP_IDL,
  the inter-frame gap; optionally a wrong FCS.

**I2C target, both directions** (`i2c_target_rw.spt`): writes as before;
a read (R/W 1) is acknowledged and the host-armed bytes go out MSB first,
each bit changing after SCL falls, with the ninth (acknowledge) bit
released for the controller. The direction is a register (SDA at the
address's eighth rise) and a set/clear `reading`; on the contexted chip
these must not read machine states (a logic cell there has one context),
and on A2 the bus actor reads at most eight inputs, so the formulation
keeps registers on pins and events only. It fits one logic cell after a
compiler fix: a LUT now reads `sda.fall && scl` as the I/O cell's
qualified edge (one input, as the machines do), not two. Peer: the I2C
controller reads (ACK each byte, NAK the last) and referees the target's
bits.

**Compiler determinism.** The router's search tree was a set; its order
follows string hashing, which differs per process, and ties in the search
followed it, so `usb_device` on L3S routed three ways depending on the
process. The tree keeps insertion order now; every committed program is
unchanged except that one.

**Bench.** Stream writes are armed, not awaited (a stream queues, as in
the source's model): a transmitter takes the bytes when its frames start
(an armed USB answer, an I2C read). A write waits for the previous one to
leave.

Open, next: the USB device address (one compare tap; a second tap or the
address in an actor is a capacity question), NAK when nothing is armed,
DATA0/1 toggling, a bad-CRC peer for USB; Ethernet link pulses (NLP)
received and the frame-to-host with TX on one chip (full duplex); I2C clock
stretching; then UART/SPI/PS2/JTAG/SWD's missing directions.

## 11. Two communication contracts (north star for A2 and the compiler)

```text
WIRE-TIMED CONTROL                          ELASTIC DATA
pin edge -> event -> control actor -> ACK   SRAM -> FIFO -> shifter
            bounded response                         valid / ready
```

**Events** (wire-timed): the architecture and compiler state when an event
occurs (which clock after the pin edge), how simultaneous events resolve
(row priority in an actor, the timer's tick-versus-resync rule), whether a
pulse can be missed (a pulse is one clock; a consumer that samples it
through a register sees it one clock later, never twice), and the maximum
response time. **Streams** (elastic): queues and backpressure are fine
inside the chip, provided an externally timed sender or receiver never
overruns the buffering; the compiler must check that bound, since a wire
peer does not wait.

What the full-protocol workload (section 10) already shows against this:

- *Event timing is where the bugs were.* The USB answer's first bit, the
  I2C read's first byte and the Ethernet resync each failed by one clock:
  a registered signal arriving after the machine had moved, a start one
  clock before the shift grid, a resync that swallowed a due tick. The
  fixes that held were by construction (start on the bit clock's own
  tick; a resync never removes a due tick; gate with the state the
  register's delay implies), and each needs to become a compiler-checked
  rule, not a source-level comment: per event, the clock it lands on
  relative to the pin, and per consumer the state it is read in.
- *Elastic obligations are real.* The received-packet descriptor FIFO is
  four deep and overflows if the host does not pop (a USB transaction is
  up to five packets with the device's echo); the shifter's single held
  word is the only buffer between a 10 Mb/s line and the word network.
  The compiler should derive the worst-case occupancy from the protocol
  rate and the host's service bound and refuse a mapping that can overrun.
- *Temporal reuse must be proved safe, not assumed.* An I2C target
  receiving a byte also watches for START/STOP; the USB device's receiver
  hears its own answer while the transmitter runs. "One protocol" is not
  "one operation at a time": any reuse of a PE or a route across states
  needs a check that the operations are never needed together and that
  the switch meets the protocol deadline (the contexted chip's context
  switch is exactly such a reuse, checked today only by tests).

Operators, from the workloads, before any new primitive: **event
capture** (I/O qualified edges, the shifter's word/stop), **condition and
branch** (actor rows; LUTs), **merge** (actor output selection), **bounded
repeat and count** (timers, counters, the shifter's frame and burst), and
**termination** (end level, end lookahead, Manchester violation, eop tag).
Each is implemented today by the actor, the timer/counter or the word
network; a dedicated primitive is added only when mappings and
area/timing comparisons justify it. Related work to borrow ideas from,
not designs: Triggered Instructions (events, predicates, several
eligible actions; without an instruction PE), Marionette (whether control
needs its own plane), Ripple and RipTide (queues, steer/merge, ordering
across branches and loops; our wire side cannot back-pressure), RMT
(match-action patterns, not its table scale).

The decisive comparison stays the same program on the contexted baseline
and the actor candidate, now over the I2C target in both directions, the
USB device and Ethernet receive: pin timing, missed or simultaneous
events, buffers, routing and physical area, not only whether the graph
maps.

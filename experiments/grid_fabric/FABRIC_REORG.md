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

## Steps (in order; each sturdy, with its own evidence, before the next)

1. **Inventory**: the existing tiles, switch boxes, SRAM paths and
   lane-core logic, with what each does. *(This section, below.)*
2. **Placement of lane-core functions**: decide where state, sequencing,
   edge detection and events go: existing tiles, switch boxes, or small
   distributed control resources. Each decision comes with its reason.
3. **Neighbour exchange**: how adjacent cells exchange bit signals and
   events, including which hops are registered, the latency the compiler
   sees, and the switch behaviour and its configuration.
4. **Word and stream paths**: separate from the bit mesh, for shifters,
   CRCs and SRAM, with flow control (valid/ready or credit) and who may
   reach what.
5. **The revised 5 x 3 arrangement**: a drawing of every cell's
   resources, switch connections and SRAM interfaces, and the contract
   v2 that states it. The checker reads it.
6. **Compiler architecture model**: build the RRG and resource tables from
   contract v2, and map one real protocol (UART RX from source) onto it.
7. **Implement and test**:
   - that mapping in RTL, tested at the pins;
   - concurrent protocols;
   - constrained physical placement (placement regions), through to a GDS.

Workflow (user, 2026-11-26): RTL changes do not wait for review. Steps
2-5 may each use RTL experiments (standalone modules, synth area, formal,
small sims) to settle a decision. Those decisions are recorded here with
their evidence. Step 7 moves the existing protocol tests over one at a
time, and nothing old is deleted while a test depends on it.

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

## Step 2: where the lane-core functions go (in progress)

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

### Proposal: split bit control from word processing

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

### Prototype test (2026-11-26): `make seq2-proto-test`

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

### Open questions (settled by experiment, recorded here with evidence)

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

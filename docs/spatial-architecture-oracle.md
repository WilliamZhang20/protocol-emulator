# Spatial architecture oracle

This page defines repeatable evidence for two different claims:

1. **What kind of architecture is this?** Describe its actual control and
   compute structure without using “dataflow” or “spatial” as marketing labels.
2. **Is a proposed revision better for protocol emulation?** Compare it with
   a declared workload, timing contract and physical budget.

These are related questions, but they need different evidence. There is no
useful single scalar that certifies both.

## Current classification

The chip is best described as a **statically configured synchronous spatial
bit-timing fabric with a central protocol sequencer**. It does not yet satisfy
the stronger goal that all protocol execution be spatial.

The fabric maps timers, shifters, counters, CRC engines, logic cells, edge
cells and pin cells to fixed hardware. Their configuration selects inputs and
behavior; they operate in parallel on clock cycles. Registered signal-space
lines connect them, and every such line crosses at most one tile per cycle.
PX8 is a project-local name for the program-counter-based processor in
`px8_controller.v`; the RTL does not define an expansion for “PX8.” It loads
configurations, waits for fabric events, selects the next protocol phase, and
issues byte transfers. Those phase and byte decisions are protocol execution,
so they are centralized today. It does not schedule individual bit edges;
timers and shifters generate those edges in the fabric.

That makes bit-level operation spatial, but it is not a fully spatial protocol
engine or a pure dataflow machine in the strict classical sense. Classical
dataflow describes actors firing locally
when their input tokens are available, without a single program counter as
the locus of control. This design instead uses synchronous signal lines,
static selectors and a central sequencer for transaction-level decisions.
Its program image combines controller instructions with tile configuration,
so “bitstream-like” describes the persistent tile setup only, not the whole
programming model. See [Najjar, Lee and Gao](https://ptolemy.berkeley.edu/publications/papers/99/dataflow/dataflow.pdf)
for the dataflow model and [Choi](https://www.jstage.jst.go.jp/article/ipsjtsldm/4/0/4_0_31/_article/-char/en)
for CGRA architecture and mapping terminology.

## Reshape PX8 into a spatial control plane

Keep the useful parts of PX8: loading the program image, configuring tiles,
starting/stopping the engine, and handling exceptional host-facing commands.
Move normal protocol progress out of its single PC loop. Once configured, PX8
should be parked or limited to supervision while protocol-specific control
actors advance from local events and exchange registered action/valid signals.

The current eight `fabric_logic` cells are not enough to do this generally:
each is a one-bit LUT plus a flip-flop, useful for small distributed control
conditions but too small to encode all protocol phases, counters and byte
movement. Add a class of **configured control tiles** with local state and a
small transition table. Each tile should consume nearby registered event,
input-valid and local-state signals; produce next-state, action and
ready/valid signals; and advance independently each cycle. Place actors by
stream or protocol stage (for example, receive framing, packet validation and
transmit response), not as several copies of the same central instruction
stream. Keep links registered and cluster control near the shifter and byte
pipeline it controls.

PX8 would initialize those transition tables and data-path tiles before arm.
During a transaction, event-to-phase changes, byte routing and backpressure
would be resolved by the actors and existing byte tiles. Host FIFO boundaries
remain explicit; a full host FIFO may backpressure its local stream, but must
not freeze unrelated channels. This preserves programmability while moving
protocol decisions into the spatial fabric. It is a spatial actor/control
fabric, not necessarily classical token dataflow, so the oracle should certify
the observed structure rather than require a label.

Migrate incrementally: (1) profile existing protocols and identify PX8
instructions on their critical path; (2) implement one small control-tile
prototype and map one protocol's phase transitions to it; (3) compare full
transaction latency, initiation interval, concurrent tile activity, PX8
wait/issue occupancy, routed control fanout/wire delay, area and correctness;
(4) add actors only when those comparisons show a gain within physical limits.
Keep PX8 for setup and compatibility until the actor design covers the needed
workloads. The acceptance condition is that protocol progress during a normal
transaction no longer depends on PX8 instruction retirement, except at an
explicit host or resource boundary.

## Primary measures: parallelism, locality and latency

Use these as the oracle's main performance axes, always on the same workload
and with the same correctness and area constraints.

- **Parallelism:** report independent tile work that overlaps in time, active
  tile utilization, and how often protocol progress waits for a PX8 decision
  or byte feed. A high tile count alone is not parallelism if a central issue
  loop serializes the useful work. For protocol execution to be spatial, phase
  selection and data movement must also proceed in distributed hardware
  without requiring PX8 to issue each step.
- **Locality:** include both memory locality and communication locality. For
  this chip, report signal-line fanout, routed wire length/capacitance, and
  physical delay between producers and consumers as well as SRAM and host
  traffic. The 64-line selector space gives a one-hop *logical* path; it does
  not guarantee a short *physical* wire. CGRA research treats interconnect
  structure as a performance and energy tradeoff alongside compute resources
  ([Zhang et al., scalable spatial interconnects](https://ppl.stanford.edu/papers/isca19.pdf)).
- **Latency:** report exact cycles and physical time for input-edge-to-output,
  event-to-action, start/configure-to-ready, and end-to-end transactions. Give
  worst case and jitter under event waits, FIFO stalls and host traffic, plus
  throughput or initiation interval. Low average latency alone can hide an
  unbounded or protocol-breaking stall.

Correctness, protocol coverage, reconfigurability and routed area/timing margin
remain constraints and supporting measures. They explain whether a measured
parallelism, locality or latency result is useful and affordable.

### Initial assessment of this design

- **Parallelism:** the configured tiles operate concurrently each cycle, and
  bit timing does not use PX8 instruction cycles. However, phase transitions,
  byte movement and some FIFO service are centrally sequenced. Thus only the
  bit-timing/data-plane portion is spatial today. Measure this dependence per
  protocol; do not call it zero just because the wire clock is autonomous.
- **Locality:** the one-hop selector rule bounds logic depth, but the signal
  space is a shared global bus, not a local-neighbor mesh. Past routed paths
  show fanout and wire delay can dominate. Memory locality is also limited by
  the shared 1 KB SRAM and controller feed rate.
- **Latency:** the fabric has exact cycle timing and one-hop tile behavior.
  End-to-end response still includes input synchronizers, registered edges,
  logic/tile stages and sometimes PX8 event handling or FIFO stalls. The
  oracle must report both the deterministic fabric portion and the complete
  protocol transaction.

## Evidence the oracle should produce

### 1. Structural report from the RTL

Generate a machine-readable inventory from elaborated RTL or a synthesized
netlist, not comments or hand-maintained counts:

- tile instances, state bits and configuration registers by class;
- which blocks have independent state and run each cycle;
- every signal-space producer, selector consumer and register boundary;
- paths from PX8 state and control outputs to fabric configuration, fabric
  operation and external pins;
- the controller's SRAM, instruction and byte-transfer responsibilities.

This report should make the control/data-plane boundary visible. In
particular, it should distinguish “the PX8 configures a shifter” from “the PX8
times a shifter edge.”

### 2. Spatiality and timing invariants

Keep the one-hop rule as a hard structural invariant: each signal-space line
must come from a register, and no configuration may create a combinational
path through multiple tiles. Extend the existing one-hop check to report the
producer and consumers for each line and to flag new controller-to-pin
combinational paths.

At the protocol level, test that an active bit operation keeps its specified
cycle schedule while the controller waits on events or stalls on a FIFO. Use
top-level pins and host-visible status in tests shared with gate-level runs;
put internal-state assertions in RTL-only checks. Formal properties should
cover tile timing and the controller/fabric handshake separately, with
independent pin-level peers checking complete transactions.

### 3. Configuration and compiler fidelity

For every compiled design, report named resources and their physical tile or
pad, configuration address, and signal-space outputs. Reject over-allocation
at compile time and verify that the compiler's hardware manifest matches the
RTL register map for its pinned revision. The compiler's allocation report
must also explain shared hardware: two contexts reuse a physical tile, and a
second context must not count as a second tile.

Configuration guarantees should be explicit and measured: reset-to-armed
latency, cycles per configuration word, context-switch latency, and the
maximum SRAM space for code, configuration and stored data.

### 4. Architecture quality against protocol workloads

“Better” is workload-dependent. Compare revisions on the same checked-in
protocol corpus and include stress cases for resource pressure and host/FIFO
starvation. Organize the comparison around parallelism, locality and latency
as above, and report, per workload:

- whether it compiles and which resources it occupies;
- exact external timing and transaction correctness;
- how much work is performed by the fabric versus PX8;
- configuration/start cost and sustained throughput under host pressure;
- SRAM use, routed area/utilization, setup and hold margin, and power when it
  can be measured reproducibly.

Keep protocol coverage, implementation quality and physical margin as separate
columns. A design that supports more demos but only barely meets timing is not
automatically better. A design with excellent throughput on one protocol is
not automatically more general. CGRA research similarly treats mapping as a
problem over both the application graph and the hardware graph, rather than
counting processing elements alone ([Choi](https://www.jstage.jst.go.jp/article/ipsjtsldm/4/0/4_0_31/_article/-char/en)).

## Pass criteria and use of agents

The structural and temporal checks should be deterministic CI gates. The
workload report should use fixed test inputs, fixed tool versions and retained
physical-design reports. Human or agent reviews can challenge whether the
workloads and metrics are representative, but they cannot replace those gates.

Agents are useful as independent reviewers: one can challenge the taxonomy,
another can look for hidden controller dependence in the RTL, and another can
propose adversarial protocol workloads. Keep their findings as review input;
the oracle passes only when its executable checks pass. Internet sources are
useful for definitions and candidate metrics, especially primary papers and
official tool documentation. They should inform the rubric, not dictate a
universal score or substitute for measurements on this design.

This oracle is necessary for substantiating the architecture claim and for
making architecture changes comparable. It is not a prerequisite for every
small RTL edit: individual changes still need their relevant tests and
physical checks. Start with a source-of-truth hardware map shared by the RTL
and compiler. Then record per-protocol latency, tile overlap and sequencer
waits in the compiler report; add routed fanout and wire-delay data from the
physical flow; then build structural checks for controller-to-protocol
dependence. Prototype distributed phase control and compare it on the same
workload corpus.

# Protocol-oriented tile fabric: first candidate

Status: **proposal, not implemented or measured**. Hardware `7dd2f41` and
compiler `14ddd5f` are the reference. This candidate replaces the rigid
two-cluster premise in [the earlier sketch](cluster-redesign-sketch.md). It
borrows placement and routing ideas from spatial machines without assuming an
FPGA-style lookup-table array or copying a CGRA. Tile counts, wiring, silicon
cost, configuration encoding and protocol coverage are not established by this
document.

## Design thesis

Build a programmable protocol engine from **small, heterogeneous, explicitly
connected tiles**. A timer, a control cell, a shift unit, a memory and a pin
are separate resources. The compiler groups nearby tiles by mapping a
protocol onto them; the hardware does not preassign two timers and two
shifters to a fixed channel. A second protocol can use remaining tiles if
enough tiles, storage and routes exist.

The fabric should make common serial operations cheap and unusual bit widths
natural. It should also make communication explicit: local links first,
selected longer connections only when measurements justify them. The design
does not promise that any tile can reach any other, that every operation fits,
or that the logical drawing predicts physical wire length.

```text
           package pads around the edge
              |       |       |
            [ IO ]  [ IO ]  [ IO ]
               \      |      /
 [logic] -- [switch]--[switch] -- [timer]
     |         |         |           |
 [shift] -- [switch]--[switch] -- [memory]
     |         |         |           |
 [timer] -- [switch]--[switch] -- [logic]
                    |
                host endpoint
```

This picture is conceptual. It does **not** fix a physical floorplan, tile
count, a uniform mesh, or a switch at every intersection. A switch drawn here
represents finite registered routes. A tile might be placed beside a pin,
another tile or a memory macro; physical implementation decides whether that
is actually local. A protocol's resources need not form a rectangular region.

## Concrete candidate tile contracts

These are starting capacities to evaluate, not a final bill of materials.
All tiles share the chip clock, have a configuration interface and use
registered outputs. A configuration is static while armed. Each type has
defined input and output ports; only legal connections in the architecture
description may be selected.

| Tile | Initial proposed capability | Principal ports |
| --- | --- | --- |
| **I/O** | One pad; synchronized input and registered value/OE. Input, push-pull, and open-drain modes; reset and disarm release the pad. | `pad_in`, `drive`, `oe`; fixed physical pad |
| **Logic/control** | Two small independent configurable Boolean functions with registered outputs, plus a small configured state machine or equivalent factored state. Candidate: four selected Boolean inputs and up to eight states. Event matching and actions are explicit, with no instruction fetch. | selected Boolean inputs; registered Boolean outputs and action events |
| **Timer/counter** | One independent timer with initial/repeat intervals, registered level and edge events; start, stop and hold. Counting external events is a selectable alternative mode, not a second free timer. | start, stop, hold/count; level, tick, terminal event |
| **Shift/capture** | One 16-bit storage datapath; independently selected shift and capture events; configured active width 1–16 and bit order; word count/done. Bidirectional operation can time-share it. Full-duplex use requires implementation to retain independent transmit and receive state; if that extra state is omitted, the mapper must allocate two tiles. | serial in/out, shift, sample, start, busy/done; word data and transfer handshake |
| **Memory/queue** | A finite local store, exposed as configured queues or addressed objects, with explicit request ports, arbitration and capacity. Candidate prototype: one 16-bit access per cycle and one-cycle read response, subject to macro implementation. | request/response or stream endpoints; valid/ready; optional packet end/error |
| **Route** | A bounded set of configured, registered connections at a junction. Some locations may instead have direct tile-to-tile links. No per-packet programmable routing or central scheduler is required. | adjacent Boolean/event and word links, subject to lane counts |
| **Host endpoint** | Adapts the host transport to selected configured memory/queue endpoints and reports errors. Configuration loading is a distinct mode. | host link; explicit connected storage/stream ports |

The logic/control tile is not a commitment to a large fully populated
8-state × 16-input-combination transition table. Table, factored conditions,
and smaller state-machine alternatives must be synthesized and compared.
Likewise, a tile may contain useful fixed protocol operations: CRC, stuffing,
escaping or framing are candidates for specialization where general tiles
cannot deliver adequate throughput or area. They are not yet part of the
minimum tile set and their removal from existing RTL would regress workloads.

This machine is not obliged to use a regular grid. Tile types, direct links
and routing junctions can be heterogeneous. The architecture file must list
the actual instances and their actual connections, not manufacture an
imaginary mesh around them. Pin locations and SRAM macro geometry are physical
constraints when a layout is eventually chosen.

## Connections and timing

The first routing experiment has separate **Boolean lanes** and **word
lanes**. A Boolean lane carries one registered level or one-cycle event. A
word lane carries a 16-bit container plus `valid`, `ready`, `end`, and `err`.
The number of lanes per link and each junction's legal source/destination
pairs are explicit parameters of a candidate, not assumed unlimited. A
16-bit link is a candidate, not a requirement for every neighbor connection;
serializing or narrowing long links may save area at a throughput cost.

At edge `n`, a tile samples selected registered inputs and updates its outputs
after the edge. A consumer directly connected to that output samples it at
edge `n+1`. Each intermediate registered route adds one cycle before the
next consumer can sample it. A registered I/O output/OE adds its own cycle;
the input synchronizer has two registers, and asynchronous arrival adds phase
uncertainty. A path's latency is computed from its actual registers, not from
the geometric distance in the picture. The compiler must account for every
stage in protocol timing and reject a route whose delay or event rate fails
the workload.

An event is a pulse; it is not automatically remembered. A compiler must
allocate a latch/queue when a consumer can miss it, or prove it is ready.
Fanout is allowed only where the actual link and switch permit it. There is no
unbounded global event broadcast, and a switch does not silently replicate a
word stream. Two protocols contending for the same configured lane cannot
both claim it unless the lane defines arbitration and the mapping budgets it.

For word channels, `valid && ready` transfers one item at an edge; a stalled
producer holds payload and tags stable. A registered ready path needs enough
buffering or credits to absorb in-flight items. No deadlock-freedom guarantee
follows merely from using ready/valid: cyclic dependencies need an explicit
buffering/progress argument or must be rejected. Local queue capacity and
storage-port arbitration are part of that analysis.

## Width and storage

The compiler represents values by their actual bit width. In the initial
candidate a 5-, 9-, or 12-bit field occupies the low bits of a 16-bit word
container and a shift tile is configured to transmit or receive exactly that
many bits. Upper bits and host packing have a defined encoding; padding is not
clocked onto the protocol wire. Bit order is separately configured. The host
transport may remain byte-oriented, but that is an endpoint representation,
not a rule that internal operations or wire frames must be eight bits.

Sixteen is a physical candidate width, **not** a claim of unlimited arbitrary
width. Wider fields need an explicitly defined continuation/cascade operation
and enough route and storage bandwidth to maintain their bit timing, or the
compiler rejects them. For example, two 16-bit tiles are not automatically a
32-bit shifter. Compare this against narrower tiles and longer local serial
paths before choosing a fixed width.

Data RAM should be near the consumers it serves where physical implementation
allows. Separate independently usable memory tiles can support concurrent
streams, but each has finite capacity and ports. A single-port tile cannot
serve a host write and two independent reads in the same cycle; the mapper
must account for arbitration and buffering. Shared host bandwidth can still
become a bottleneck. A receiver unable to pause must report overflow if its
buffer is exhausted; a transmitter needs a protocol-specific pause or abort
policy.

Distributed storage is a hypothesis to measure, not a requirement to split
the present 1 KiB macro into tiny pieces. Tiny SRAM macros may not exist, and
register-based RAM can be costly. Compare at least (1) local queues plus the
existing-size shared memory, (2) banked shared memory and (3) larger local
stores. Include a stored Ethernet frame that exceeds any individual local
queue. Without a capacity and service argument this candidate cannot claim to
replace the baseline's stored-frame behavior.

## Programming contract

The intended interface is **configuration/bitstream mapping**, not normal
transaction execution by centrally fetched instructions:

1. The compiler lowers protocol behavior into operations and dependencies,
   places them on specific tile instances, assigns storage and legal routes,
   and emits a versioned configuration image for one specified hardware graph.
2. The host loads and checks that image while the fabric is disarmed. Its
   fields configure tile functions, select routes, allocate storage and bind
   host endpoints. The on-wire encoding and configuration storage are open
   implementation details; configuration is separate from payload RAM.
3. An atomic arm starts the configured hardware. State machines and tiles
   react locally and concurrently; an instruction fetch is not needed to
   advance each protocol phase. The host supplies or receives payload via
   explicit endpoints and can stop/disarm the fabric.
4. On reset, invalid/incomplete image, or disarm, pins are released. Runtime
   reconfiguration and contexts are not promised by the first prototype.

The mapper must report resource exhaustion, unroutable connections, memory
conflicts and unmet timing rather than treating an extracted graph or a tile
count as a successful map. A loader/supervisor can exist without being the
normal transaction sequencer. IR implementation (Rust, MLIR/CIRCT, or a
combination) is a compiler decision and does not define the chip interface.

## Worked example: 12-bit command, 5-bit reply

This is a hypothetical three-wire sensor, not a claim of a tested device. It
needs CS, CLK and bidirectional DATA; the chip emits 12 command bits, releases
DATA, and captures five reply bits. A proposed allocation is:

| Task | Allocated tile or link |
| --- | --- |
| CS, CLK, DATA and input synchronization | Three distinct I/O tiles |
| Bit cadence | One timer tile |
| Command and reply | One time-shared shift/capture tile, width reconfigured by its static phase-control inputs or two statically configured operations if the tile supports them |
| CS and DATA direction/phase decisions | One or more logic/control tiles; count and done signals supplied by explicitly allocated resources |
| Command and result | One or more storage/queue tiles, plus a host endpoint |
| Signals and words between them | Specific Boolean and word routes in a declared hardware graph |

The phrase “width reconfigured by its static phase-control inputs” needs real
hardware: the tile must have two preloaded phase profiles or an explicit
runtime width input. If it does not, use two tiles or reject this mapping;
the compiler cannot change a static configuration for free. Likewise, the
control tile must support every required state, output and event. The DATA OE
must go low early enough for the external device's turnaround requirement,
and the synchronized input must be sampled within its valid window. The
timer-to-pin and timer-to-shifter routes can have different pipeline depths;
any compensation consumes real state or delay. A layout is not proven to
fit until its concrete route allocation and cycle schedule are checked.

## First RTL slice

Build a **small connected fabric**, not a single all-purpose cluster and not a
full chip:

1. Define a candidate instance graph that exposes three I/O tiles, timer,
   shift/capture, logic/control and storage/host endpoints. List each directed
   connection, lane count, multiplexing rule, register boundary and fanout.
   Include two preloaded shift-width profiles or allocate two shift tiles for
   the example. Specify whether CS, clock and data can use distinct routes at
   the same time. This concrete graph is still to be designed; the conceptual
   picture above is not its connectivity specification.
2. Implement those tiles and routes in RTL with a documented configuration
   encoder. Use a pin-level peer to test the 12+5 transfer, including minimum
   allowed turnaround, input synchronization, reset/disarm and an invalid or
   incomplete configuration. Tests included in shared cocotb modules must use
   top-level pins/host signals and remain gate-level safe.
3. Map existing UART and SPI examples by allocating tiles and drawing actual
   paths. UART needs independent TX/RX timing; SPI needs coordinated clock,
   CS, and full-duplex data. Add tiles or routes only when the mappings and
   measured costs justify them. Compare the resulting pin waveforms against
   the existing independent peers and baseline, including wire-rate margins.
4. Run synthesis and physical comparisons: standard-cell and memory area,
   configuration-bit count, mux fan-in/fanout, routed wire length, setup/hold,
   latency, and throughput. Compare direct protocol-oriented links against a
   more uniform network; do not assume the more flexible one wins.
5. Keep old RTL available while functionality migrates. Before removing byte
   stages, account for packet framing, escaping, filtering, checksums and
   CRC workloads as well as buffering and large stored transfers. A single
   successful sensor demo does not establish full protocol compatibility.

The open question is the smallest heterogeneous tile and routing mix that
maps the intended protocols with acceptable area, timing and programming
effort. The answer should come from actual mappings and hardware comparisons,
not a commitment to FPGA, CGRA, byte-layer, or fixed-channel orthodoxy.

The first executable selector-only comparison is in
[experiments/routing](../experiments/routing/README.md). It does not yet
implement this tile graph or establish a physical-design verdict.

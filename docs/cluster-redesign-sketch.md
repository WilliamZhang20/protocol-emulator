# Structured spatial cluster: first candidate

Status: design proposal, not implemented RTL, a compiler target, a measured
fit, or a promise of protocol coverage. The baseline is hardware `7dd2f41`
with compiler `14ddd5f`. The existing hardware remains the reference until a
replacement passes the same pin-level tests. The numerical capacities below
are concrete starting choices for comparison, not established requirements.

## Thesis

Build a statically configured spatial machine out of repeated, defined
clusters. Each cluster has local bit/word operations, control, storage and
connections. A host loads a configuration image; after an atomic arm, the
configured blocks run concurrently without a central instruction fetch on the
normal protocol path. Independent clusters can make progress concurrently.
The architecture exposes bit-level timing and widths rather than dividing
the machine into a universal bit layer and a fixed byte layer.

This does **not** mean an unbounded number of bits, universal connectivity,
or guaranteed progress when a required data source is empty. Widths, routes,
storage, and timing are finite and checked by the compiler. The image is a
configuration of existing hardware, not generated Verilog.

## Candidate machine

Start the comparison with two identical clusters, C0 and C1. Each cluster has:

| Resource | Candidate capacity and purpose |
| --- | --- |
| Serial lanes | Two independently configured 16-bit shift/capture lanes. Each can shift or sample a configured number of bits, 1–16, in either bit order; it exposes bit output, word output, busy and done. A lane's shift and sample events are separately selectable, so a full-duplex SPI lane can transmit and capture on different edges. |
| Timing | Two independently running timers. Each provides a registered level and rising/falling event, with configurable initial and repeating intervals; each can be started, stopped, or held by an event/level. Precise range and minimum period require RTL and physical evaluation. |
| Local control | One configurable finite-state controller, initially eight states, that reads up to four selected local Boolean conditions per cycle and generates registered actions and state. This is a proposed capacity, not a claim that an 8-state, 4-input full transition table is cheap. Exact encoding is open; there is no instruction fetch. |
| Boolean/state cells | Four registered configurable Boolean cells, each taking up to four selected local inputs. They supply small independent conditions or state that would otherwise inflate the controller. |
| Data storage | One 16-word × 16-bit local data memory per cluster, one request serviced per cycle with one-cycle response as a candidate contract. TX and RX queues are logical allocations in that storage, with valid counts and independently selected producer/consumer. Port arbitration and macro cost must be validated. |
| Pins | Four attached bidirectional pads per cluster, with synchronized input, registered output value and registered output-enable. Each supports input, push-pull and open-drain. A pad is owned by exactly one cluster; this is two groups of four, not an assumption that any cluster reaches any pad. |
| Links | Two directed registered 1-bit lanes in each direction between clusters, plus one directed registered 16-bit data channel in each direction. The data channels include valid/ready and packet end/error sidebands. These are shared finite resources, not a global selector bus. |

```text
                     host/configuration interface
                       |                   |
             +---------v---------+ +-------v-----------+
             | C0                | | C1                |
             | 2 timers          | | 2 timers          |
             | 2 serial lanes    | | 2 serial lanes    |
             | local control     | | local control     |
             | 4 Boolean cells   | | 4 Boolean cells   |
             | 16 x 16 data RAM  | | 16 x 16 data RAM  |
             | local interconnect| | local interconnect|
             +--+--+--+--+---+---+ +---+---+--+--+--+--+
                |  |  |  |   +-- registered --+  |  |  |
              four pads       intercluster      four pads
                              event/data links
```

There is one machine clock. Each resource is independently enabled and runs
on that clock; a timer enable is not a derived clock. Local routing is a
defined set of selectors over **that cluster's** resource outputs and its
incoming link endpoints, not over every output on the chip. The initial
candidate permits any local Boolean output/event to feed any local Boolean
input. Wide data ports connect lanes, local storage, and the data-link endpoint
through an explicit local crossbar. Fan-in and fan-out of both networks must
be counted in area and routed timing; this candidate is not automatically
physically local just because its logical ports are local.

## Interface and clock contract

All externally visible links terminate at registers. At edge `n`, an enabled
block samples its selected input values and updates its own registered outputs
after that edge; another block samples those outputs no earlier than edge
`n+1`. An intercluster link captures its source at an edge and its destination
can sample the link register on the next edge. Thus a producer register to a
consumer register across the link is two edges, rather than the one edge of a
direct local connection. A pad output/OE register adds a further edge from
its selected source. An asynchronous input passes through two synchronizer
registers before use; its observation delay and phase uncertainty must be
included in protocol timing. Reset/disarm releases every pad.

Boolean inputs are levels. Events are one-cycle pulses carried on Boolean
routes; an event consumer must observe that pulse or use an explicitly
allocated latch. There is no implicit global sticky-event bank or unbounded
event queue. The compiler must reject a mapping if a required pulse can be
lost or an event-to-output latency cannot meet the stated timing contract.
An unstalled source can emit an event every cycle, but a particular consumer's
capacity must be specified and checked.

A data transfer occurs at an edge when `valid && ready`; the sender holds
data, width, end and error stable while `valid && !ready`. A channel transfers
at most one 16-bit container per cycle. The configured width `w` is 1–16;
bits `[w-1:0]` carry the value and upper bits are zero. Bit order on a serial
pin is a separate lane setting. `end` marks a packet or transaction boundary,
and `error` accompanies the affected item. They do not mean that a partial
word is byte-padded on the wire. Clock-to-clock contracts for output-enable
and data at a bidirectional turnaround are part of the mapping, not inferred
from a byte boundary.

No combinational route may cycle through programmable blocks. Backpressure
must also be bounded: `ready` is registered at the link boundary, and the
implementation must provide sufficient buffering or credits for its advertised
latency. A compiler mapping with a possible cyclic wait must be rejected or
given an explicit buffering/progress argument; merely connecting ready/valid
does not prove freedom from deadlock.

## Configuration, storage and host access

The host writes a versioned configuration image containing cluster resource
settings, local selectors, intercluster routing, widths, local-control tables,
storage allocations, pad modes and host endpoint bindings. Image version and
length are checked before activation. The format and programming transport
are not yet specified; bitstream here means configuration, not an instruction
set. Configuration bits are held in local configuration registers or memory;
that storage is separate from each cluster's data RAM.

Reset and stop release pins and stop block activity. Loading occurs while
disarmed. A successful arm activates a complete image atomically; incomplete
or invalid images cannot drive pins. Changing a running configuration, context
switching, and partial reconfiguration are explicitly outside this first
contract. These restrictions keep the initial programming semantics clear;
they are not a claim that runtime reconfiguration will never be needed.

Each cluster owns its data RAM; a transaction that only uses C0 never needs a
read of C1's RAM. Host transfers terminate at explicitly bound cluster
endpoints. A host transaction does not pause the fabric clock or the other
cluster. Within a cluster, host, TX and RX requests contend for the stated
single port; arbitration is fair, and the mapper must budget worst-case
service including the host, or provision enough buffering. Simultaneous
requests do **not** imply multiple RAM ports. If a non-stallable wire-side
receiver runs out of storage, it reports overflow rather than silently losing
data; a transmitter that runs out follows a protocol-specific configured
stall or abort policy. No protocol may claim a timing guarantee without a
bounded input/host-service contract. Independent progress is conditional on
not sharing a blocked resource or route.

These tiny local RAMs are a **hypothesis**. They supply only 32 bytes per
cluster and may be expensive or impractical as physical macros. In particular,
the current 1 KiB SRAM supports stored frames much larger than either local
RAM. This candidate has no replacement for such a frame yet: it must stream
from the host with a demonstrated service guarantee, add a larger shared or
banked storage option, or fail that workload. Eliminating instruction memory
does not establish that fully distributing all data capacity is better.

## Widths and operations

Widths are types in the compiler and properties of a mapping. A 5-, 9-, or
12-bit value fits a 16-bit lane without forcing an 8-bit framing boundary.
For a width above 16, the compiler must either split the operation using
explicit links, buffering and scheduling with a proven bit cadence, or reject
the mapping. Two lanes existing in a cluster does not automatically make a
32-bit shift register: a cascading path and its timing have not been defined.
Serial bit manipulation remains an escape hatch, but it is not a substitute
for width-aware word operations.

The minimum general operations for the first prototype are: timed pin drive
and sample, edge detection, shift/capture, fixed-width value comparison,
Boolean combination, state transition, bounded counting, and queue movement.
The 16-bit lanes include a bit-count limit; any other counter must be allocated
and specified by the implementation. CRC, escaping, delimiters, checksum,
address filtering and bit stuffing still need candidate implementations or
explicit rejection. In particular, removing the current byte tiles before
providing those functions would regress HDLC/SLIP and packet workloads. An
8-bit specialization can be added when it wins against general operations;
it is not a mandatory path for all data.

## Worked mappings and what they do not prove

The examples below allocate resources against this candidate. They are
manual hypotheses, not compiler results, RTL simulations, or timing proofs.

### Full-duplex UART, 8N1

The existing `examples/uart.spt` at 50 MHz uses a 64-cycle bit period. On C0,
allocate one output pad, one input pad, one timer and lane for transmit, and
one timer and lane for receive. The RX start edge starts the RX timer; it
samples at the configured middle of each bit. TX and RX use distinct timing
resources and can overlap. Local queues feed the TX lane and store RX words.
Start/stop framing and host queue requests must be expressible with the local
control and available RAM service. The synchronizer, edge detection, timer,
lane and pad pipeline delays must be included when selecting the first tick;
no claim of matching the existing exact 64-cycle waveform is made until
cycle-level simulation. Both timers and both lanes are occupied, so another
independent protocol cannot simply be assumed to fit in C0.

### Full-duplex SPI, mode 0

The existing `examples/spi.spt` uses CS, SCK, MOSI and MISO and an 8-cycle
half-period. Allocate all four C0 pads, one timer for SCK and one serial lane
whose transmit and receive events use the appropriate timer edges. Local
control asserts CS, starts the timer/lane, counts words, and releases CS only
after the final edge and required delay. TX and RX queue service share the
single RAM port; their combined service and host traffic must fit the word
rate. The exact phase at the pads, including the output register and input
synchronizers, remains to be calculated and checked against the independent
SPI peer. This uses all four local pads, so an extra peripheral needs another
cluster or explicit pad sharing, which is not in this candidate.

### A 12-bit command followed by a 5-bit reply

This is a hypothetical three-wire device, not a claim about an existing
protocol or checked-in example. On one cluster, allocate CS, CLK and one
bidirectional DATA pad, one timer, one lane and local control. Transmit 12
bits from a 16-bit container, deassert the DATA output-enable at the defined
turnaround edge, then capture five bits into the low bits of a receive word.
The local controller counts the phases and selects shift/sample events. The
input synchronizer and registered output-enable impose a minimum turnaround;
the mapping is valid only if the device's specified setup/hold and turnaround
times accommodate those cycles. No partial byte is sent on the wire.

### Two independent streams and a large stored frame

Allocate one UART-like TX stream per cluster, each with its own timer, lane,
pad and local queue. Their fabric operation is independent; host bandwidth
and its arbitration are still shared and must be budgeted. A 1 KiB stored
Ethernet frame does not fit either 32-byte local RAM, so this candidate cannot
claim equivalence with the baseline on that workload without an additional
storage design or proven host streaming. Use this failure to compare a shared
large memory, banked memory and larger local buffers—not to hide the limit.

## First implementation and acceptance gates

1. Specify the control-table encoding, exact selector endpoints, pad register
   timing, data-RAM arbitration and queue depths. Count configuration bits;
   compare an 8-state/4-input table against smaller factored alternatives.
2. Implement one actual C0 cluster with timer, one bidirectional pad, one lane,
   local control and a small queue. Implement the hypothetical 12+5 transfer
   with a pin-level test peer and an explicit cycle/turnaround contract.
   Add the second lane and timer for the UART mapping before claiming the
   full two-lane cluster exists. This is a vertical slice, not the complete
   machine; do not delete baseline blocks needed by the existing regressions.
3. Build a configuration image for that slice via a small documented encoder;
   validate bad images, arm/reset and pin behavior. The eventual compiler must
   map typed operations and routes to the same image. Whether Rust IR is
   exchanged with MLIR/CIRCT is an implementation decision, not the hardware
   programming interface.
4. Compare the same waveform and transaction against an equivalent baseline
   mapping where possible. Run the existing gate-level-safe top-level protocol
   tests on the replacement, and compare synthesized and routed area, setup/
   hold, wires, latency and throughput. A block count or a model-only fit is
   not evidence of timing closure or full protocol compatibility.
5. Before adopting or deleting old RTL, cover common UART/SPI/I2C and the
   packet/CRC workloads, host starvation, concurrent streams, and the large
   frame case. Reject or revise the candidate where it cannot satisfy a
   declared protocol and physical budget.

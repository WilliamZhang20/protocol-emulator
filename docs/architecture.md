# Protocol emulator architecture

## Purpose

The chip is a deterministic, SRAM-programmed protocol engine. Protocol behavior
is expressed as programs that manipulate shared timing, serial, FIFO, and GPIO
resources. UART, SPI, and I2C are initial demonstrations of the architecture,
not fixed-function peripherals in the hardware.

The first implementation contains one engine. The structure intentionally keeps
execution resources and external interfaces separable so later versions can add
more engines, event routing, and autonomous data movement without replacing the
programming model.

## System structure

```text
                         Host control and data
                                  |
                         +------------------+
                         |  Host interface  |
                         +------------------+
                           |      |      |
                    program|    TX|      |RX
                           v      v      ^
                    +----------+  +--------+
                    | Program  |  | FIFOs  |
                    |   SRAM   |  +--------+
                    +----------+      |
                         |             |
                         v             v
                    +---------------------+
                    |   Protocol engine   |
                    | sequencing + state  |
                    +---------------------+
                       |       |       |
                  +--------+ +-----+ +--------+
                  | timers | |shift| | GPIO   |
                  |counts  | |unit | | fabric |
                  +--------+ +-----+ +--------+
                                          |
                                   Physical protocol pins
```

The architecture has two conceptual planes:

- The host plane loads programs, starts and observes execution, and exchanges
  payload bytes through queues.
- The protocol plane runs deterministically from the chip clock and controls
  external pins without depending on host response time.

## Major components

### Host interface

The host interface is the control boundary of the chip. It provides access to
program loading, execution control, status, and queued payload data. Host
transactions are deliberately kept out of the exact-cycle execution path.

The initial pin-level host protocol will be selected alongside the programming
model. Its internal responsibilities remain the same if a future version uses a
different external transport.

### Program memory

A foundry SRAM macro stores protocol programs. SRAM contents define pin timing,
framing, branches, waits, and data movement, allowing behavior to change after
fabrication.

The memory is wrapped behind a technology-independent program-memory interface.
This isolates the engine from foundry-specific controls and permits a logical
model in simulation and formal verification.

### Protocol engine

The protocol engine owns instruction sequencing and the small amount of local
state needed while a program runs. It coordinates shared execution resources
and advances only when the current operation's timing and flow-control
conditions are satisfied.

The instruction set will remain intentionally small. It needs to express
precise delays, conditional control flow, pin operations, serial shifts, and
FIFO transfers without embedding protocol-specific states in the decoder.

### Register and state storage

A compact register file holds working values, flags, loop state, addresses, and
temporary protocol data. Dedicated counters and shift storage handle operations
that would otherwise require long software sequences while remaining reusable
across protocols.

### Timers and counters

Timers provide exact-cycle delays and bounded counting. They allow programs to
describe baud periods, clock high and low times, setup and hold intervals,
timeouts, and repeated transfers using the same resource.

### Serial shift unit

The shift unit moves data between parallel working values and serial pins. It
supports both input and output directions and is intended to cover UART bits,
SPI words, I2C bytes, and other serial formats without knowing their framing
rules.

### Configurable GPIO fabric

The GPIO fabric is the engine's protocol-facing datapath. It provides sampled
inputs, output values, independent output-enable control, masked comparisons,
edge observations, and logical-to-physical pin mapping.

Independent output-enable control is essential for bidirectional and open-drain
interfaces such as I2C. Pin mapping lets the same SRAM program bind its logical
signals to different physical pins.

### TX and RX FIFOs

Small transmit and receive FIFOs decouple payload traffic from deterministic
execution. A running program can consume or produce bytes at protocol timing
while the host services data at a less predictable rate.

Programs may wait or branch on FIFO state. The engine must define explicit
behavior for empty and full conditions so host latency cannot silently corrupt
a transfer.

## Reprogrammability model

Programming occurs in a configuration phase before execution begins. The host
loads the SRAM image, configures logical pin bindings, supplies initial payload
data, and starts the engine. During execution, the host exchanges data through
the FIFOs and reads status without modifying timing-critical engine state.

Protocol programs define:

- pin levels and output-enable changes;
- timing intervals and repeated cycles;
- input sampling, edge handling, and masked conditions;
- serial bit order and transfer length;
- framing decisions and conditional branches; and
- movement of payload bytes to and from the host queues.

UART, SPI, and I2C therefore differ primarily in SRAM contents and configuration.
No module is designated as a UART controller, SPI controller, or I2C controller.

## Initial demonstrations

- UART transmit and receive establish accurate asynchronous bit timing and
  framing.
- SPI master transfer establishes programmable clock phase, polarity, and
  simultaneous shifting.
- I2C master transactions establish bidirectional open-drain control,
  acknowledgements, and conditional waits.

Loopback or paired endpoints will verify that each demonstration uses the same
engine and execution resources.

## Growth path

The component boundaries allow later versions to add capabilities incrementally:

- multiple engines sharing program or data memories;
- an event router for pin edges, timers, and inter-engine signals;
- DMA-style movement between host queues, memories, and engines;
- richer wait and wake-up behavior;
- specialized but protocol-neutral datapath operations; and
- debug visibility, tracing, and execution breakpoints.

New hardware operations should accelerate patterns useful to several protocols.
Protocol-specific state machines remain outside the architectural direction.

# Configurable serial fabric v2 experiment

This is the earlier shared-selector baseline, retained for comparison. The
Tiny Tapeout experiment now uses the structured [3 × 3 grid](../grid_fabric/README.md).
`fabric_v2_unified` combines finite SPI and independent UART streaming over
one tile fabric and one two-bank SRAM subsystem. Results for this baseline do
not validate the new grid top.

```text
                   configurable Boolean selectors
                       ┌─────────────┐
  synchronized pins ──>│             │──> timer 0 / timer 1
  trigger events ─────>│  17 muxes   │──> shifter 0 / shifter 1
  timer/shift outputs ─>│             │──> 3 output pins + OE mask
                       └─────────────┘
                             │
              SPI finite / UART stream adapters
                   │                    │
             [1 KiB SRAM]          [1 KiB SRAM]
                       host request port
```

The two timer tiles have independently configured 16-bit first and repeating
periods, start/stop/hold, and tick/level/rise/fall outputs. The shifters have
independent start/shift/sample events, 1–16-bit widths, and MSB/LSB-first
right-aligned data. They each hold one word; no queue or arbitrary-width
cascade is implemented. Seventeen independently configured selectors choose
from fixed Boolean sources. The first 16 configure two timers, two shifters,
and two pins; the 17th configures the third pin. Each selector has its own
mux; this prototype does not implement a constrained shared-route network or
prove selector conflicts for a future topology. All muxes are combinational
between registered tile outputs. There is no router pipeline, physical delay
model, generalized logic tile or instruction fetch.

The unified wrapper reuses `experiment_memory_fabric` with two single-port
1024x8 SRAM banks and host/actor bank selections. Its hand-written SPI adapter reads one
or two bytes from SRAM, applies a configured left shift and OR mask to form a
TX word, starts lane 0, then waits for lane 0 and the selected RX lane before
writing one or two bytes back, optionally shifted right. This is not a generic
byte stream, DMA engine, or source function lowering. RX completion before the
finite adapter enters its transfer phase can be lost. The separate UART stream
adapter receives autonomously, as described below. The
host preloads payloads and reads results by explicit memory requests.

## Experimental configuration words

All words must be written while disarmed; changes while armed are ignored.
There are no version or checksum fields. Invalid width, zero timer values,
invalid selector indices or reserved format bits keep outputs disabled.
Addresses 0–25 encode tile and adapter configuration. The unified image adds
address 26 for the static mode (0 SPI, 1 UART):

| Address | Meaning |
| --- | --- |
| 0–3 | Timer 0 first/period, then timer 1 first/period (any write order) |
| 4–5 | Shifter 0/1: width bits `[4:0]`, MSB-first bit 5 |
| 6–21 | Selector indices 0–15, in the order listed below |
| 22 | Adapter: TX byte count `[1:0]`, RX byte count `[3:2]`, RX lane bit 4, TX left shift `[8:5]`, RX right shift `[12:9]`; counts must be 1 or 2 |
| 23 | Adapter TX OR mask |
| 24 | Selector 16, third output pin |
| 25 | Output-enable mask `[2:0]`; open-drain mask `[5:3]` |
| 26 | Unified mode, bit 0; all other bits must be zero |

Selector sinks 0–5 are timer 0 and 1 start/stop/hold; 6–9 and 10–13 are
shifter 0 and 1 start/shift/sample/serial input; 14–16 are output pins 0–2.
Their source indices are 0 zero, 1 one, 2/3 external triggers, 4/5
synchronized inputs, 6–9 timer 0 tick/rise/fall/level, 10–13 timer 1
 tick/rise/fall/level, 14/15/16/17 shift 0 busy/done/serial/serial-or-idle,
18/19/20/21 the same for shift 1, 22/23 input 0/1 falling edge, and 24
`!shift0.busy`. Indices 25–31 are invalid. The two input synchronizers and
falling-edge detectors are fixed resources. Output enable is gated off while
disarmed or incomplete.

For each open-drain output, logical zero drives low and logical one releases
the pad. At the chip interface, output 0 is `uio[6]`, output 1 is `uio[5]`,
and both inputs default to `uio[0]`. Host configuration word 29 bit 0 selects
whether input 1 senses `uio[6]`, and bit 1 selects whether input 0 senses
`uio[5]`; a clear bit selects `uio[0]` (the reset default). Thus
the fabric can sense a shared data line even while another device holds it
low. Word 29 persists across disarm, so hosts loading existing SPI/UART images
must explicitly restore it to zero. The external system must provide the
pull-up. Output 2 is exposed on a
dedicated output and has no physical output-enable; its open-drain mask does
not make that pad bidirectional. This is a pad primitive, not an I2C controller
or proof of I2C source compilation, arbitration, or timing.

## Independent UART streaming wrapper

`fabric_v2_uart_stream` is a second wrapper around the same tile fabric and
two-bank memory; it does not replace the finite SPI wrapper. UART RX starts
from the configured input edge independently of TX, queues received bytes,
and writes them sequentially to a configured SRAM region. TX fetches a
host-specified finite source region through a separate queue and runs without
waiting for RX. Each queue holds four bytes. One registered actor request is
held stable until accepted, and local arbitration alternates between eligible
TX reads and RX writes. Host and actor still contend through the existing
two-bank round-robin arbiter. The host must keep `rx_base` and `rx_capacity`
stable at arm and avoid modifying in-flight TX data; no coherence is provided.

On arm, RX accepts at most `rx_capacity` bytes into the non-wrapping region
`[rx_base, rx_base + rx_capacity)`. `rx_received` counts bytes accepted into
the queue, and `rx_written` counts writes accepted by SRAM. If the region is
invalid/full or the queue cannot accept a completed byte, that byte is dropped
and `rx_overflow` remains set until disarm/reset. Zero capacity is invalid.
TX accepts one nonzero, non-wrapping region on `tx_start` while idle; a request
while busy is ignored. Invalid ranges set `tx_error` and pulse `tx_done`;
valid `tx_done` pulses after the final transmitted frame. Disarm cancels
pending activity and clears status; accepted SRAM writes remain. Framing
errors, stop-bit validation, RX backpressure, runtime ring reclamation and
continuous host streaming are not implemented.

The standalone stream test runs five receive-only bytes and two successive
transmit-only requests, then overlapping traffic while a host continuously accesses the same
bank. It checks FIFO occupancy, host stalls, receive-region overflow and its
sentinel, oversized TX and invalid RX ranges, sticky overflow and disarm.
Interface-level SV assertions check queue bounds, write/receive counts,
sticky overflow, stable stalled host requests and disarmed pin OE. RTL-only
checks also verify that the actor request remains stable while stalled, and
hierarchical coverage confirms that both host and actor actually stalled.
This standalone bench is not part of the gate-level cocotb modules. It uses
the functional SRAM model, not real-time physical timing or silicon.

## Verification and compiler boundary

`make tile-fabric-v2-experiment` runs four standalone RTL tests and Yosys
synthesis/black-box count check. The tests cover timer first/repeat/hold and
all 1–16-bit widths in both orders; one fabric configured first for 12-bit SPI,
then a changed output route, then overlapping UART TX/RX; and the same SPI
and UART operations with actual IHP functional SRAM models, host accesses to
the other bank during UART activity, invalid selector and memory-boundary
rejection, ignored live configuration writes, output enables and disarm. The
SPI test checks CS, clock and all 12 TX bits; UART checks a start, eight TX
bits and stop plus one RX byte. These are standalone RTL-only testbenches,
not shared cocotb tests and not gate-level tests. The SRAM model is functional,
not physical silicon.

The sibling compiler can emit restricted 26-word source-derived images using
`--compile-v2-spi` for `circt_lab/examples/memory_spi.spt` and
`--compile-v2-uart` and `--compile-v2-uart-stream` for `examples/uart.spt`. The compiler validates the
supported source patterns and uses source width/timing, but placement, routes,
packing and the finite adapter are fixed. Control is implemented by the
adapter and direct busy/done wiring, not generally lowered. The original finite
wrapper's UART handling is only the tested one-byte case; the stream wrapper
uses host-supplied regions and lengths. Reports explicitly set
`general_mapping` and `full_source_program_compiled` false. The source-driven
CIRCT regression can run the SRAM RTL test with `V2_MEMORY_IMAGE_TB` set to
its built executable, and the stream test with `V2_UART_STREAM_IMAGE_TB`.
For this baseline, `--compile-v2-unified-spi` and
`--compile-v2-unified-uart` emit 27 words including mode. These images remain
in the standalone baseline tests; the chip top now uses the distinct grid
image contract. General stream/function lowering and a physical timing proof
remain absent. Physical design must separately account for prior SRAM slew,
capacitance and clock-fanout violations.

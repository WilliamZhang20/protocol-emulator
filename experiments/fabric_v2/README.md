# Configurable serial fabric v2 experiment

This standalone experiment is not the Tiny Tapeout top. The top-level physical
CI and gate-level cocotb tests still target `memory_spi_fabric`. This module
has not been placed, run through gate-level simulation, or physically compared.

```text
                   configurable Boolean selectors
                       ┌─────────────┐
  synchronized pins ──>│             │──> timer 0 / timer 1
  trigger events ─────>│  17 muxes   │──> shifter 0 / shifter 1
  timer/shift outputs ─>│             │──> 3 output pins + OE mask
                       └─────────────┘
                             │
                finite 1/2-byte SRAM adapter
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

The wrapper reuses `experiment_memory_fabric` with two single-port 1024x8 SRAM
banks and host/actor bank selections. A hand-written finite adapter reads one
or two bytes from SRAM, applies a configured left shift and OR mask to form a
TX word, starts lane 0, then waits for lane 0 and the selected RX lane before
writing one or two bytes back, optionally shifted right. This is not a generic
byte stream, DMA engine, source function lowering, or autonomous UART receiver:
RX completion before the adapter enters its transfer phase can be lost. The
host preloads payloads and reads results by explicit memory requests.

## Experimental configuration words

All words must be written while disarmed; changes while armed are ignored.
There are no version or checksum fields. Invalid width, zero timer values,
invalid selector indices or reserved format bits keep outputs disabled.
Addresses 0–25 form the image consumed by the testbench:

| Address | Meaning |
| --- | --- |
| 0–3 | Timer 0 first/period, then timer 1 first/period (any write order) |
| 4–5 | Shifter 0/1: width bits `[4:0]`, MSB-first bit 5 |
| 6–21 | Selector indices 0–15, in the order listed below |
| 22 | Adapter: TX byte count `[1:0]`, RX byte count `[3:2]`, RX lane bit 4, TX left shift `[8:5]`, RX right shift `[12:9]`; counts must be 1 or 2 |
| 23 | Adapter TX OR mask |
| 24 | Selector 16, third output pin |
| 25 | Output-enable mask `[2:0]` |

Selector sinks 0–5 are timer 0 and 1 start/stop/hold; 6–9 and 10–13 are
shifter 0 and 1 start/shift/sample/serial input; 14–16 are output pins 0–2.
Their source indices are 0 zero, 1 one, 2/3 external triggers, 4/5
synchronized inputs, 6–9 timer 0 tick/rise/fall/level, 10–13 timer 1
 tick/rise/fall/level, 14/15/16/17 shift 0 busy/done/serial/serial-or-idle,
18/19/20/21 the same for shift 1, 22/23 input 0/1 falling edge, and 24
`!shift0.busy`. Indices 25–31 are invalid. The two input synchronizers and
falling-edge detectors are fixed resources. Output enable is gated off while
disarmed or incomplete.

## Verification and compiler boundary

`make tile-fabric-v2-experiment` runs three standalone RTL tests and a Yosys
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
`--compile-v2-uart` for `examples/uart.spt`. The compiler validates the
supported source patterns and uses source width/timing, but placement, routes,
packing and the finite adapter are fixed. Control is implemented by the
adapter and direct busy/done wiring, not generally lowered. UART frame and
host-stream handling are only the tested one-byte case. Reports explicitly set
`general_mapping` and `full_source_program_compiled` false. The source-driven
CIRCT regression can run the SRAM RTL test with `V2_MEMORY_IMAGE_TB` set to
its built executable. There is no complete source-language fit, configuration
loader on Tiny Tapeout pins, gate-level test, physical PPA result, or claim that
this topology is the final fabric. Physical design must separately account for
prior SRAM slew, capacitance and clock-fanout violations.

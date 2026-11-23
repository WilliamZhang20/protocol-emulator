# Fabric investigation: protocol requirements and physical evidence

This note is a snapshot of investigation, not a final fabric specification.
The current top is the two-SRAM SPI test vehicle. The heterogeneous tile-fabric
sketch remains the architecture direction; tile counts, block boundaries,
connections and memory organization remain experimental.

## Last physical run

The [GDS workflow for hardware `8af6a81`](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/45206782802)
passed GDS, precheck and the pin-level gate-level test. The companion test and
[tile experiment](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/45206783104)
workflows passed. KLayout reported zero geometric DRC violations. Post-route
STA reported worst slow-corner setup slack +8.9115 ns at a 20 ns clock and
worst hold slack +0.2345 ns across the three reported corners.

Post-route electrical checks were not clean: slow-corner STA reports three
maximum-slew violations at SRAM bank 1 input pins, one maximum-capacitance
violation at its `A_DOUT[3]` output, and 18 maximum-fanout violations on
clock leaf buffers. For example, bank 1 `A_ADDR[6]` slew is 1.091317 ns
against a 0.5952 ns limit. The workflow success does not establish electrical
signoff. Investigate the actual constraints, buffers and parasitic paths before
choosing a remedy. These are not KLayout geometric DRC errors. The local
hardware branch is one commit ahead of that CI result, containing only test
and documentation changes, not changed design RTL.

The reported `A_ADDR[6]` path reaches the last `a21oi_1` gate with a
0.818335 ns output transition before reaching the macro input at 1.091317 ns.
The over-capacitance `A_DOUT[3]` net is reported with fanout 2 and load
0.074186 against a 0.064 limit. These observations identify paths to inspect;
they do not establish whether resizing, buffering, placement or constraints
are the right fix. All 18 listed fanout violations are clock leaf buffers.

The final power-aware netlist identifies `_1751_` (`sg13cmos5l_a21oi_1`) as
the only driver of `bank1.address[6]`, with the SRAM address pin as its load.
The extracted nominal SPEF reports 0.0502407 pF total for that net. The
slow-corner SRAM Liberty assigns its `A_ADDR[6]` input 0.0119653 pF, and
their sum is 0.0622060 pF, matching the reported load at `_1751_`'s output.
The SRAM `A_DOUT[3]` output drives `_1839_` (a mux) and `_2424_` (a logic gate);
the SPEF reports 0.0680671 pF total for the net. STA's reported 0.074186 pF
load also reflects its analysis and library assumptions, so these numbers are
not interchangeable. This shows which final-netlist drivers and loads to probe;
no counterfactual resizing or physical reroute has yet been run. The maximum
fanout violations are 18 CTS leaf buffers with reported fanout 13–17 against
the limit 8; why that constraint is not repaired or enforced needs checking.
The checked-in slow-corner SRAM Liberty sets `A_ADDR` maximum transition to
0.5952 ns and `A_DOUT` maximum capacitance to 0.064 pF, matching the STA
limits. The SRAM address timing lookup tables shown in that Liberty stop at
0.5952 ns input slew; the violating path is outside that characterized slew
range. The post-route SDC sets a 20 ns clock and a design-wide maximum fanout
of 10, while the reported leaf-buffer limit is 8; the source of the stricter
limit needs confirmation from the standard-cell library. OpenROAD and the
standard-cell libraries used by CI are not installed in this workspace, so
no counterfactual resize/re-extraction has been run locally.

Each of the two SRAM macros measures approximately 146.88 × 336.46 µm before
spacing and routing. This is a single two-macro test vehicle, not a measured
comparison with a one-macro, smaller-bank or alternative-fabric design. The
pin-level gate test covers the selected two-bank 12-bit transfer, not the
full protocol corpus.

## Workloads inspected

The table counts declarations in the checked-in Rust-frontend examples. It is
not a lower bound on physical tiles: operations may share a tile, contexts may
be exclusive, and some source constructs still lack new-fabric lowering.
Pins exclude host-transport consumption. No result here establishes full
protocol compliance.

| Example | Declared timers | Declared shifters | Other visible requirements |
| --- | ---: | ---: | --- |
| `spi.spt` | 3 | 1 | 4 protocol pins, counter, transaction/byte stream control |
| `uart.spt` | 2 | 2 | 2 pins, independent full-duplex paths, first-tick offsets, byte streams |
| `i2c.spt` | 2 | 2 | 2 open-drain pins, clock stretching, sampled ACK, control flow |
| `jtag.spt` | 1 | 2 | 4 pins, two coordinated driven bit streams and a sampled input |
| `ethernet_tx_coded.spt` | 4 | 1 | 2 digital outputs, Manchester coding, CRC32, frame storage, two-cycle half-bit tick at 40 MHz |
| `usb.spt` | 1 | 1 | 2 outputs, NRZI, bit stuffing, CRC16; example is a low-speed transmitter |

The UART source graph needs two independent timing and shift states in its
current conservative decomposition. The existing integrated slice has one of
each; a hypothetical two-path target passes only abstract placement. It is
not proven that exactly two physical instances are necessary: a combined tile
or different decomposition could supply independent state. The typed graph
and both assessments are documented in the sibling compiler's
`circt_lab/UART_ARCHITECTURE_ASSESSMENT.md`.

The current integrated slice accepts configured half-periods only at least
8 cycles and its shifter is MSB-first. Its current input/output configuration
and timer do not supply the I2C open-drain/clock-hold contract. The 10BASE-T
example's two-cycle half-bit tick is a separate fast-path constraint; simply
adding another copy of the current slice is not a demonstrated solution.
External PHY/line-driving requirements remain outside the digital graph.

## What to investigate before fixing tile counts

1. Trace post-route STA violations to the actual SRAM routes, drivers and
   clock-tree constraints. Establish whether buffering, placement, constraints
   or a combination is responsible; do not infer a fix from the report alone.
2. Expand typed source analysis to I2C and JTAG, recording simultaneous state,
   pad behavior and dependencies independently of a proposed tile layout.
   Compare at least separate versus combined timing/shift blocks; the UART
   graph's two-instance decomposition is only one candidate.
3. Model port-level selector conflicts, event/bit path latency and pulse
   lifetime. Test the two-cycle Ethernet feedback/encoding path and the I2C
   clock-stretch path against candidate local routes, then use RTL simulation
   to validate any promised timing. The current tile-level graph checks only
   reachability, not these properties.
4. Compare shared SRAM plus local queues against the existing two-bank macro
   arrangement using explicit stream contention, frame capacity and host/pad
   constraints. Obtain matched synthesis/physical results before choosing bank
   counts or interpreting generic cell counts as area.

Initial follow-up probes are in the sibling compiler's
`circt_lab/investigations/README.md`. Source connectivity shows JTAG's two
shifters share the declared start and shift events; I2C's two shifters do not
share a direct shift source, though function and context semantics remain to
be lowered. A hypothetical single shared selector cannot simultaneously route
the two JTAG data sources; two selectors can. A micro-test of existing RTL
route primitives preserves two-cycle pulse spacing through three pipeline
stages, but that does not prove an Ethernet feedback path or pin timing.

An explicit synthetic contention trace found two chosen actor deadline misses
with one 1 KiB bank, none with two 1 KiB banks, and none with
one bank plus four-byte prefetch. Over 26 host arrival phases, the unbuffered
one-bank case misses at least one actor deadline in 13 phases; the other cases
have no misses in this finite model. Arbitration, phase, object
placement and host behavior are assumptions; these figures do not decide the
physical SRAM organization. They are useful cases for a future matched RTL
experiment. No physical resize or reroute has been run.

Prefer one controlled comparison where candidate alternatives implement the
same workloads and report functional coverage, wiring/timing limits and
physical cost. A successful GDS run for the present SPI test vehicle does not
predict whether a larger proposed topology will fit.

## Matched shifter block probe

`make tile-shift-pair-experiment` compares separate lanes, a two-data-lane
shared sequencer, and an independent-sequencer wrapper using the same external
interface. Source-inspired JTAG scan and manually step-gated I2C-like byte
stimuli passed; the shared sequencer rejects independently controlled lanes.
A separate unequal-width/rate test exercises both independent lanes. This is a
component-level probe, not full source lowering or a real stretched I2C bus.
Generic flattened synthesis measured 238, 218 and 238 cells respectively,
with 78, 71 and 78 flip-flops; these are not physical area or timing, and the
shared design supports a narrower contract. Details and limits are in
[the experiment README](../experiments/shift_pair/README.md).

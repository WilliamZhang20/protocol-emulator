# Connected-tile SPI vertical slice

Run `make tile-spi-experiment` from the hardware repository root. This is an
experimental standalone module, **not** a replacement for the chip and not a
fair physical comparison with the baseline yet.

The sibling compiler's `circt_lab` experiment can emit an image for this RTL.
`make tile-circt-image-test IMAGE=/path/to/image.mem` loads the 18 configuration
words and TX payload through the prototype ports and runs a pin-level transfer.
For an actual `.spt` protocol declaration, the compiler can also emit only a
control-tile table; `make tile-control-image-test IMAGE=/path/to/control.mem`
checks that table with the corresponding external input sequence. This tests a
component, not placement or binding of the full source program.
The RTL and CIRCT work must be checked out together at matching revisions; this
experimental image is not compatible with the current chip's ABI.

`control_fabric.v` is a second, smaller target for a complete restricted source
program: two synchronized inputs, one four-state controller, and three
registered output paths. Its 17-word image is 16 control rows and an output
enable mask. `make control-fabric-image-test IMAGE=/path/to/control-full.mem`
tests a compiler-generated image at the pins. It is a standalone experiment,
not a replacement for the SPI slice or a proposed final topology. See the
sibling compiler's `circt_lab/README.md` for source restrictions and commands.

## Distributed memory experiment

`make tile-memory-experiment` tests `memory_tiles.v` and `memory_shift.v`.
This is a separate integration prototype using the same timer and shifter
primitives; it has not replaced the register file in `spi_fabric`, and its
transfer sequencer is hand-written. There is no instruction fetch or compiler
mapping in this experiment.

```text
 host request ──── route select ──┬── [bank 0: 1024 x 8, 1 port]
                                  │       round-robin arbitration
 shifter adapter ─ route select ──┴── [bank 1: 1024 x 8, 1 port]
        │
        └── fetch two bytes → [shifter + timer] → store two bytes
```

Each requester is assigned either bank through a two-bit route setting written
while disarmed. Different banks accept requests concurrently; same-bank
requests arbitrate round-robin. A requester holds request and payload until
`ready`. A read returns `rvalid` and data for one cycle after its accepting
edge; writes complete at acceptance and have no response. There is no response
backpressure, queueing, address translation, coherency, or initialized-memory
tracking. Data remains undefined until written. Changing routes while armed is
ignored. This contract is an experiment, not a final memory ISA or topology.
The precise handshake and reset behavior is in [MEMORY_CONTRACT.md](MEMORY_CONTRACT.md).

The test runs the same accesses against a synchronous behavioral bank and the
functional model of the actual IHP `RM_IHPSG13_1P_1024x8_c2_bm_bist` macro.
It checks concurrent access, same-bank arbitration, route changes, a stalled
request, and a 12-bit `0xA5C` transmit crossing two bytes; it then stores and
reads back the received `0xFFF`. The hand-written adapter currently supports
9–16 bits, packs the low bits into two big-endian bytes, and serializes each
16-bit memory word into two 8-bit single-port accesses. Other widths and
streaming need more work. The test is a digital functional simulation, not a
timing or physical silicon test.

`make tile-memory-synth` preserves two SRAM macro black boxes and synthesizes
the surrounding experimental adapter. A local run yielded 623 generic cells
including those two macro cells; this is not standard-cell area or a comparison
with the existing chip. The checked-in macro LEF specifies **146.88 × 336.46
µm per macro**, roughly 49,418 µm² each before spacing and routing. Two such
macros are therefore a substantial physical commitment. No placement, routing,
or timing run has established that this two-macro arrangement fits. We should
compare it with fewer macros and smaller register-based banks before choosing
the final number and location of banks.

```text
                   timer --> [route] --> SCK pin
                     | rise/fall
trigger -> control -> [routes] -> shifter -> [route] -> MOSI pin
               |                    ^
               v                    |
            [route] -> CS pin    [route] <- MISO synchronizer
                                    |
                           local 4 x 16 register file
```

The prototype has a timer, shift/capture tile, configured control, three
registered output pins, a synchronized input, and eight configurable four-input
registered routes. Each route has a finite hardwired set of sources; this is
not an all-to-all network. Eighteen 16-bit configuration writes set the timer,
width, route selections and 16 control-table rows while disarmed. All must be
written before arming; writes while armed are ignored. Configuration storage
is included in synthesis. A local four-word register file holds TX in slot 0
and captures RX in slot 1; slots 2–3 have no assigned fabric function. Its
validity flags are reset; the data bits need not be. The host can write only
while disarmed, and a new start invalidates the old RX value. It has
asynchronous host/TX reads, not the single-port synchronous behavior of a
foundry SRAM. It is **not an SRAM macro** or streaming FIFO, and the host
cannot refill it while running. A valid TX word is required to arm. There is
no host bitstream loader, queue, or general routing network.

The control tile has four states and two fixed inputs (`trigger` and shifter
`done`). Its 16 rows each encode next state and registered `selected`,
`shift_start`, and `done` outputs. The test loads SPI behavior, then rewrites
two rows to make a trigger complete without an SPI transfer. This is a real
reconfiguration but not yet a general control tile: its input and output
ports remain specialized and its full table is expensive. The shifter supports
1–16 bits (MSB first); TX values are left-aligned and RX values right-aligned.
It is a first executable slice of a possible fabric, not
evidence that the proposed architecture maps general protocols.

The standalone Verilog peer exchanges `0xA5` for `0x5A` in SPI mode 0 with an
8-cycle half-period. It checks 8 sampling edges, all 16 clock edges, half-period
spacing, MOSI stability at rising edges, receive data, idle state, disarm pin
release and that incomplete or invalid configuration does not drive pins. It
then reconfigures the same fabric for 5-, 12- and 16-bit transfers, tests a
different MOSI route and control table, and checks that configuration and
payload writes while armed are ignored. It reads received words back from the
local store. A separate junction test exercises all four selector choices with
every possible set of inputs. The 8-bit, 5-bit and 12-bit transactions took
135, 87 and 199 cycles, respectively; the 16-bit transfer took 263 cycles, from
trigger release until `done` in this test. This measures a
different interval than the compiler's wall-clock test report and is not a
baseline speedup claim. The peer is independent of the prototype's internal
hierarchy; it is not the same peer used in the compiler's baseline test.

## Local synthesis comparison

`make tile-spi-experiment` also synthesizes the same tile slice with fixed
routes and with programmable routes. The fixed version ties the selectors to
the tested mapping at elaboration; both retain the same registered route
boundaries. An RTL test checks their pin and status outputs agree cycle by
cycle for one zero-route transaction. With Yosys 0.67+111 (`4821ed17b-dirty`):

| Candidate | Generic cells | Flops |
| --- | ---: | ---: |
| Fixed route selectors | 747 | 248 |
| Programmable route selectors | 781 | 264 |

These are generic mapped cell counts, **not** standard-cell area or timing.
They include the configuration and register-file flops, but omit a host
transport, SRAM macros and the rest of a real chip. The fixed-route control preserves the same pipeline
latency; a fixed design without routing pipeline stages could differ. Both
now include the configurable control table, 16-bit shifter and local register
file, so they are not directly comparable with the previous 8-bit,
fixed-controller results.
Synthesis can restructure logic differently, and generic cell counts do not
use a uniform area weight. This
measures a narrow local cost of eight selectors; it is not a comparison to the
current chip's full 64-line network or evidence for an architecture verdict.

The baseline is compiler `14ddd5f` targeting hardware `7dd2f41`. Its checked-in
`examples/spi.spt` sends `[0xA5, 0x3C, 0x81]` and expects `[0x5A, 0xC3,
0x7E]` from a separate pin-level SPI peripheral. Both that test and the
back-to-back transaction test passed. The first byte and half-period match the
prototype. A separate [one-byte baseline program](baseline_spi.spt) uses the
same `0xA5` command, `0x5A` reply and half-period as the tile test; it also
passed on the pinned baseline. Its peer code, configuration interface and
capabilities still differ from the tile prototype, so this is not yet a
controlled side-by-side timing or area comparison.

On this machine the compiler's cached simulator needed
`LD_LIBRARY_PATH=$HOME/.cache/spatial/python/lib/python3.12/site-packages/cocotb/libs`
because its cached binary could not locate the cocotb VPI shared library.
After setting it, `cargo run --quiet -- run --test examples/spi.spt` passed.
That path is environment-specific and not a project requirement.
To reproduce the single-byte baseline without creating generated files inside
this repository, copy `baseline_spi.spt` into a temporary directory and run
the pinned compiler's `spatial run --test` on the copied file.

Native Yosys can synthesize the slice with:

```sh
.tools/oss-cad-suite/bin/yosys -p 'read_verilog src/spi_tiles.v; hierarchy -top spi_fabric; flatten; synth -top spi_fabric; stat'
```

The generic result is not comparable to the full baseline: the slice omits
the main SRAM, host configuration loading, additional protocols and other fabric
resources. No OpenROAD or LibreLane executable was found on `PATH`, and no
standard-cell PDK was located in the checked locations, so a placed/routed
comparison has **not** been run.

To answer the architecture question, the next work is to provide the same
configuration and host contract, independently run the same multi-transaction
peer against both, generalize and compare the cost of the configured control
tile, expand the graph to useful routing choices, then route comparable
full designs using the same library, floorplan and clock constraints. Also
measure a 12+5-bit bidirectional transfer and a concurrent workload. Until then
there is no evidence for claiming a system-level area or timing improvement.

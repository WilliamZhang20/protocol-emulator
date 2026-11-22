# Connected-tile SPI vertical slice

Run `make tile-spi-experiment` from the hardware repository root. This is an
experimental standalone module, **not** a replacement for the chip and not a
fair physical comparison with the baseline yet.

```text
                   timer --> [route] --> SCK pin
                     | rise/fall
trigger -> control -> [routes] -> shifter -> [route] -> MOSI pin
               |                    ^
               v                    |
            [route] -> CS pin    [route] <- MISO synchronizer
```

The prototype has a timer, shift/capture tile, fixed SPI control, three
registered output pins, a synchronized input, and eight configurable four-input
registered routes. Each route has a finite hardwired set of sources; this is
not an all-to-all network. Two 16-bit configuration words set the timer,
width and route selections while disarmed. Both words must be written before
arming; writes while armed are ignored. Configuration registers are included
in synthesis. There is no host bitstream loader, queue, payload memory, general
routing network, or independently configurable controller.
The shifter supports 1–8 bits (MSB first), not the proposed 16-bit or arbitrary
width design. It is a first executable slice of a possible fabric, not
evidence that the proposed architecture maps general protocols.

The standalone Verilog peer exchanges `0xA5` for `0x5A` in SPI mode 0 with an
8-cycle half-period. It checks 8 sampling edges, all 16 clock edges, half-period
spacing, MOSI stability at rising edges, receive data, idle state, disarm pin
release and that incomplete or invalid configuration does not drive pins. It
then reconfigures the same fabric for a five-bit transfer, tests a different
MOSI route, and checks that writes while armed are ignored. A separate junction
test exercises all four selector choices with every possible set of inputs.
The 8-bit and 5-bit transactions took 135 and 87 cycles, respectively, from
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
| Fixed route selectors | 180 | 68 |
| Programmable route selectors | 225 | 84 |

These are generic mapped cell counts, **not** standard-cell area or timing.
They include the configuration flops, but omit host loading, memory and the
rest of a real chip. The fixed-route control preserves the same pipeline
latency; a fixed design without routing pipeline stages could differ. This
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
.tools/oss-cad-suite/bin/yosys -p 'read_verilog experiments/tile_fabric/spi_tiles.v; hierarchy -top spi_fabric; flatten; synth -top spi_fabric; stat'
```

The generic result is not comparable to the full baseline: the slice omits
memory, configuration loading, additional protocols, host and other fabric
resources. No OpenROAD or LibreLane executable was found on `PATH`, and no
standard-cell PDK was located in the checked locations, so a placed/routed
comparison has **not** been run.

To answer the architecture question, the next work is to provide the same
configuration and host contract, independently run the same multi-transaction
peer against both, replace the hardwired SPI controller with a configurable
control tile, expand the graph to useful routing choices, then route comparable
full designs using the same library, floorplan and clock constraints. Also
measure a 12+5-bit bidirectional transfer and a concurrent workload. Until then
there is no evidence for claiming a system-level area or timing improvement.

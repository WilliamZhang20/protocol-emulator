# Two-SRAM placement experiment

This branch's Tiny Tapeout top is a physical test vehicle for the structured
5 × 3 grid in [grid_fabric/README.md](experiments/grid_fabric/README.md).
Four timers, two shifters, a combinational LUT, four registered LUT4 cells, I/O,
a temporal sequencer and two separately instantiated IHP SRAM tiles connect
through configurable finite-track neighbor routes. All protocols use shared
credit-based SRAM stream tiles, configured frame packing, and source-derived
images. There is no instruction fetch or general source-program lowering.

The coordinates are initial candidate locations in micrometers, not a claim
of legal placement, correct power connectivity, or timing closure. The GDS CI
job uses `src/config.json`, which lists both macro instances, individual power
hooks, and a Metal3 keepout for each SRAM. It retains the existing multi-macro
power-stripe plugin. Physical verification is supplied by CI, not the local
static checks. The two SRAMs are each 146.88 ×
336.46 µm. More or smaller distributed banks are a separate experiment.
The first two-bank run passed LVS but reported 284 M1.b spacing violations at
the second macro's left and right edges. With placement keepouts at those
edges, the [integrated-fabric run for `8af6a81`](https://github.com/WilliamZhang20/protocol-emulator/actions/runs/45206782802)
passed GDS, Tiny Tapeout precheck, and the pin-level gate test. Its KLayout DRC
report contained zero violations. The worst setup slack reported for the slow
corner was about 8.91 ns against the 20 ns clock; this is one test vehicle,
not an area/timing comparison against the old chip. That run was for the older
SPI-only top. The current 5 × 3 top uses the spread placement from `10f2416`
(SRAM 1 at x = 480 µm, placement density 40); its GDS, precheck and gate-level
results must be read from the CI run for the commit under test.

The post-route STA reports still contain **electrical-limit violations**, even
though the CI jobs and setup/hold checks passed. At the slow corner, three
bank-1 SRAM input pins exceed the slew limit, one bank-1 SRAM output exceeds
its capacitance limit, and 18 clock leaf buffers exceed their fanout limits.
These are reported electrical checks, not KLayout geometric DRC violations;
their causes and significance need investigation. The worst reported hold
slack across corners was approximately +0.234 ns. Do not treat the passing
workflow as complete electrical signoff or as proof that a larger fabric fits.

`ui_in[7:0]` carries a command byte. `uio_in[4:2]` selects an opcode;
`uio_in[1]` is the strobe and `uio_in[0]` is serial input. Hold the opcode and
data stable with strobe low for four clocks, high for five, then low for four.
`uo_out` holds the last completed SRAM read, except while the strobe is low
with opcode 7 (bit 0 shows the third output pin, e.g. SPI CS or JTAG TMS),
opcode 5 (the low byte of the received-byte count) or opcode 4 (status
`{rx_overflow,tx_error,tx_active,spi_error,spi_active,3'b000}`). Once
configured and armed, `uio[6]` and `uio[5]` are output pins 0 and 1 (routed by
the image), `uio[0]` is the default input, and `uio[7]` is the finish pulse. Output enables for
the first two follow the image; the done pin is enabled while configured.
Other `uio` pins are inputs. Commands are only a minimal test interface and
must not be sent while a previous memory request is pending.

| Opcode | Action |
| --- | --- |
| 0 / 1 | Set host SRAM byte address bits 7:0 / 9:8. |
| 2 / 3 | Write command byte / request a read at the host address. |
| 4 | Set arm in bit 2 (arm with `0x0C` to stay in configuration mode so per-call host words remain writable). While disarmed, a command with arm=0 writes the default host/stream bank routes in bits 1:0 and configuration mode in bit 3. Leaving configuration mode preserves independently written word-88 routes; issue a separate arm=1 command. |
| 5 | Start the configured TX stream or temporal program while armed and idle. If enabled, RX starts independently. |
| 6 / 7 | While disarmed in normal mode, set source / destination byte address bits 7:0 (upper bits zero). In configuration mode, set the low byte / write the high byte of the 16-bit configuration word addressed by host address bits 7:0 (bits 9:8 must be zero). |

The 66-word component images configure SPI or UART; extended compiler images
write all 185 words. Host words 66 and 67 (TX length, RX capacity) and 89 and
90 (TX and RX base) may also be written while armed and idle; word 68 sets pad
feedback. The [grid contract](experiments/grid_fabric/README.md)
describes routing and the remaining fixed word path.

Local checks: `make lint synth-check gds-config-check sim`, plus
`make tile-memory-lint tile-memory-experiment tile-memory-assertion-mutation
tile-memory-spi-image-test tile-memory-synth tile-fabric-v2-experiment grid-fabric-experiment`. The chip-level cocotb test uses only Tiny Tapeout pins,
and is used in both RTL and gate-level CI. `synth-check` verifies both flattened
macro instance names, while `gds-config-check` checks both placements, M3
keepouts and supply hooks. The GDS workflow performs the real physical run;
its result, not the static checks, determines whether the layout works.

# Two-SRAM placement experiment

This branch's Tiny Tapeout top is a physical test vehicle, not the original
protocol emulator or a complete redesign. It instantiates two IHP 1024 × 8
SRAM macros, a routed/arbitrated memory interface, configurable signal routes,
a configurable control table, a timer and a 9–16-bit shifter. It has no
instruction fetch or program-memory controller. The memory-transfer adapter is
hand-written; control-table rows and datapath parameters can be compiled from
the sibling compiler's `circt_lab/examples/memory_spi.spt`.

```text
 host pins ──> configuration ──> control ── routes ── timer / shifter / pins
      │                                             │
      └──── memory routing ──┬── bank 0             memory adapter
                             └── bank 1 ◄───────────┘
```

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
not an area/timing comparison against the old chip.

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
`uo_out` holds the last completed SRAM read, except while opcode 7 is held with
strobe low, when bit 0 shows CS. Once configured and armed, `uio[5]`, `uio[6]`,
and `uio[7]` output serial clock, serial data, and a one-cycle done pulse.
Other `uio` pins are inputs. Commands are only a minimal test interface and
must not be sent while a previous memory request is pending.

| Opcode | Action |
| --- | --- |
| 0 / 1 | Set host SRAM byte address bits 7:0 / 9:8. |
| 2 / 3 | Write command byte / request a read at the host address. |
| 4 | Set arm in bit 2. While disarmed, a command with arm=0 writes the two requester-to-bank routes in bits 1:0 and configuration mode in bit 3; then issue a separate arm=1 command. |
| 5 | Start one configured transfer while armed and idle. |
| 6 / 7 | In normal mode, set source / destination byte address bits 7:0 (upper bits zero). In configuration mode, set the low byte / write the high byte of the 16-bit configuration word addressed by host address bits 4:0. |

The test image configures a 12-bit transfer. It fetches two bytes from the
actor-selected bank, sends the low 12 bits MSB-first, then stores the received
12 bits as two bytes. The image also configures all eight signal selectors and
the 16 control-table rows. Memory
contract and cancellation behavior are in
[MEMORY_CONTRACT.md](experiments/tile_fabric/MEMORY_CONTRACT.md).

Local checks: `make lint synth-check gds-config-check sim`, plus
`make tile-memory-lint tile-memory-experiment tile-memory-assertion-mutation
tile-memory-spi-image-test tile-memory-synth`. The chip-level cocotb test uses only Tiny Tapeout pins,
and is used in both RTL and gate-level CI. `synth-check` verifies both flattened
macro instance names, while `gds-config-check` checks both placements, M3
keepouts and supply hooks. The GDS workflow performs the real physical run;
its result, not the static checks, determines whether the layout works.

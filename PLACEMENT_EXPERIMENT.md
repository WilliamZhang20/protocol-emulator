# Two-SRAM placement experiment

This branch's Tiny Tapeout top is a physical test vehicle, not the original
protocol emulator or a complete redesign. It instantiates two IHP 1024 × 8
SRAM macros, the experimental routed/arbitrated memory interface, a timer and
a 12-bit shifter. It has no instruction fetch or program-memory controller.
The transfer sequencing is hand-written; the compiler does not yet target
this top-level command interface.

```text
 host pins ──> command interface ──┬── bank 0 at (42, 81)
                                   ├── bank 1 at (480, 81)
                 timer + shifter ──┘
```

The coordinates are initial candidate locations in micrometers, not a claim
of legal placement, correct power connectivity, or timing closure. The GDS CI
job uses `src/config.json`, which lists both macro instances, individual power
hooks, and a Metal3 keepout for each SRAM. It retains the existing multi-macro
power-stripe plugin. CI must still establish actual placement, DRC, LVS and
timing; these have not been checked locally. The two SRAMs are each 146.88 ×
336.46 µm. More or smaller distributed banks are a separate experiment.

`ui_in[7:0]` carries a command byte. `uio_in[4:2]` selects an opcode;
`uio_in[1]` is the strobe and `uio_in[0]` is serial input. Hold the opcode and
data stable with strobe low for four clocks, high for five, then low for four.
`uo_out` holds the last completed SRAM read. When armed, `uio[5]`, `uio[6]`,
and `uio[7]` output serial clock, serial data, and a one-cycle done pulse.
Other `uio` pins are inputs. Commands are only a minimal test interface and
must not be sent while a previous memory request is pending.

| Opcode | Action |
| --- | --- |
| 0 / 1 | Set host SRAM byte address bits 7:0 / 9:8. |
| 2 / 3 | Write command byte / request a read at the host address. |
| 4 | Set arm in bit 2. While disarmed, a command with arm=0 writes the two requester-to-bank routes in bits 1:0; then issue a separate arm=1 command. |
| 5 | Start the fixed 12-bit transfer while armed and idle. |
| 6 / 7 | Set transfer source / destination byte address bits 7:0 (upper bits zero). |

The transfer fetches two bytes from the actor-selected bank, sends the low
12 bits MSB-first, then stores the received 12 bits as two bytes. Memory
contract and cancellation behavior are in
[MEMORY_CONTRACT.md](experiments/tile_fabric/MEMORY_CONTRACT.md).

Local checks: `make lint synth-check gds-config-check sim`, plus
`make tile-memory-lint tile-memory-experiment tile-memory-assertion-mutation
tile-memory-synth`. The chip-level cocotb test uses only Tiny Tapeout pins,
and is used in both RTL and gate-level CI. `synth-check` verifies both flattened
macro instance names, while `gds-config-check` checks both placements, M3
keepouts and supply hooks. The GDS workflow performs the real physical run;
its result, not the static checks, determines whether the layout works.

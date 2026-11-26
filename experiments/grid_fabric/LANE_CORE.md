# Lane core (step 2.4): design

A lane core is the replicated unit of the lane architecture: one lane
controller with the tiles it times bits with, wired to each other by
construction, plus a narrow interface to the pads and the mesh. Step 2.4
builds one and runs every existing lane design on it; step 2.6 places two.

## Why a core, not lane control over shared tiles

Today the lane controller (step 1) drives grid tiles shared with the row
sequencer: timer0/1 and shifter0/1 are plain tiles in the mesh, the coded
shifter and CRC sit in cell 8 and run only in packet mode with their
receive path unconnected (CODER_INVENTORY.md). Every lane design spends
mesh routes on wiring that never changes between protocols (timer tick
to shifter shift, shifter done to timer stop, frame start to both), and
the coded shifter's parity, destuffing, Manchester and CRC link are out of
reach. Five self-sufficient lanes (the plan's concurrency objective) need
each lane to own its timing tiles.

## Composition

| Part | Module | Notes |
|---|---|---|
| Controller | `grid_lane_controller` | unchanged ISA; events, levels and readback come from the core |
| Timer pair | 2 x `grid_timer` | modes from step 2.1 |
| Coded shifter | `fabric_shifter` | parity, stuffing, NRZI, Manchester both ways, receive decode, CRC link |
| CRC | `fabric_crc` | polynomial or additive (step 2.3), linked to the coded shifter |
| Stream port | the lane's reader and writer | the controller's PULL/PUSH, and the coded shifter's auto pull/push |
| Local signal set | 64 lines (32 pulses, 32 levels) | every tile input selects any line, like `fabric_shifter`'s and `fabric_crc`'s existing `lines` |

The local signal set is the arch/spatial idea kept where it is cheap: one
lane's worth of lines (step 1.6 measured a single lane's signal space at
0.74x the mesh), while lanes reach each other and the pads through the
mesh. `fabric_shifter` and `fabric_crc` already select from 64 lines with
6-bit indices (pulses 0-31, levels 32-63), so they drop in unchanged; the
timers get three 6-bit selectors each.

### Lines (draft; the contract will own the table)

Pulses 0-31: 0 never, controller FIRE, controller SHIFT (tx word loaded),
timer0 tick/rise/fall, timer1 tick/rise/fall, shifter word/stop pulses,
pad-input edges (rise and fall per input), mesh-input edges.

Levels 32-63: 32 low, 33 high, controller actions 0-3, timer0/1
level and running, shifter serial out and active, CRC out and ok, pad-input
levels, mesh-input levels.

### Interface

- **Inputs:** N pad inputs (synchronized levels; edges made inside the
  core) and M mesh inputs (soft tiles: LUT4 cells, other lanes).
- **Outputs:** K output lines, each `{value line, enable line}` selected
  from the local set, so open drain, push-pull and tristate are all a
  selection (I2C: value low, enable = action; UART: value = shifter out,
  enable high). In today's grid these replace the cell-6 action sources.
- **Controller events/levels/readback** come from the local set by fixed
  assignment (the contract names them), plus readback of the timer
  captures, shifter rx word and status, CRC value.

## Configuration

Lane words do not fit the 8-bit configuration space (0-215 used). The host
already has address bits 9:8 (`command(1, x)`), today required to be 0 for
configuration writes. Page 1 (addresses 256-511) holds lane cores, 64
words each (lane k at 256 + 64k), delivered by its own leaf of the
configuration tree with the same validity-before-arming rule. Legacy pages
and images are untouched.

## Sub-steps (each sturdy before the next)

1. **2.4a `src/grid_lane_core.v`, standalone.** The core with its local
   signal set and its configuration words on a lane leaf interface; a
   standalone testbench (memory model for program load and streams) that
   runs a UART transmit, a UART receive with parity and resync, and a
   capture, all through local lines only; a formal check of the line table
   (each selector value reaches exactly its line; reserved values are
   invalid configuration); contract `lane_core` section and checker.
2. **2.4b in the chip.** Configuration page 1 (10-bit addresses through
   the host link; page-0 writes and images unchanged; host words 66/67/89/90
   only on page 0) feeding a lane leaf; lane mode uses the core (its output
   lines become cell 6's local sources, mesh inputs from sinks 41-42, pads
   direct). Compiler: lane design schema v2 naming core tiles and lines
   (`timer0.aux <- in0.fall`), encoded from the contract. The five lane pin
   tests (I2C target, SPI target, SLIP TX, pulse period, UART resync) move
   to core designs and must pass unchanged at the pins.
3. **2.4c what only the core can do,** at the pins: UART 8E1 receive with
   the parity check tagging bad bytes; Manchester receive; the coder link
   carrying data bits only, so a LIN checksum (additive CRC) checks a
   received frame.

## 2.4a status: done

- `src/grid_lane_core.v`: 38 configuration words, 64 lines (pulses 0-18,
  levels 32-50 defined; the rest reserved), three outputs, ten readback
  slots. Every line is a register output, so no selection closes a loop.
- `make lane-core-test` (CI, test workflow): `-Wall` lint, the
  pure-function and part-select rules, and four cocotb tests:
  - UART 8E1 transmit, the coded shifter pulling bytes itself (six bytes
    including 0x00, 0xFF; no controller work per byte).
  - UART 8E1 receive at 0, +5 and -5 % drift with timer0 resync on in0
    falls; the controller checks status bit 6 (word bad) and pushes good
    bytes; a wrong parity bit fails the lane after the earlier bytes.
  - Timer1 capture of in1 rising-edge periods (100, 333, 1000 clocks).
  - Invalid configurations refused (reserved lines, reserved bits, N=1
    stuffing, Manchester with NRZI, CRC shape, half-set timer).
- `formal/grid_lane_core` (CI): k-induction that a configured core has no
  selector on an undefined line and no reserved bit set, over every word
  state; 10 mutations of the validity logic all give counterexamples.
- Contract `lane_core`: line table (index, name, RTL source), selector
  fields with kinds, reserved bits, word layout, readback. The checker
  matches the RTL `lines` vector bit by bit, the `line_ok`/`level_ok`
  bounds, the selector wiring, the readback order, and the proof's mask
  and field lists; 8 contract mutations are rejected.

Two findings worth keeping:

- **Impure functions lie in simulation.** `fabric_shifter`'s
  `frame_bit_at` read frame registers directly while called from
  continuous assignments. Icarus re-evaluates those only when the
  arguments change, so with `index` and `tx_word` at their reset values the
  transmit bit stayed X after configuration. Synthesis and verilator were
  fine; the chip tests passed by ordering luck. The function now takes a
  packed shape argument, and `tools/check_pure_functions.py` (in
  `make lint`) refuses any function that reads a module signal.
- **Sample latency.** A tick and the coder's sample are each one register,
  so a receiver's sample lands 2 clocks after the timer count ends. The
  first-tick count and the resync phase both subtract it (the compiler's
  UART receive templates must do the same when they move to the core).

# Formal verification

Formal checks complement the cocotb regression; they do not replace it. Each
RTL block has its own directory with a property harness and an `.sby` task
file. Every harness checks the block against an independently written
reference (a model, a scoreboard, or a pin-level contract), never against a
copy of its own logic.

## Running the suite

Install the YosysHQ OSS CAD Suite, then run from the repository root:

```sh
make formal                 # every target, then the mutation check
make -C formal list         # target names
make -C formal px8_controller
```

Results and counterexample traces are written beneath `build/formal/`.
Harnesses are single-clock: one solver step is one clock cycle, so a depth
of N checks every input sequence of N cycles from reset.

## Targets

| Target | Tasks | Checked behavior |
| --- | --- | --- |
| `program_memory` | BMC, proof, cover | Masked writes and synchronous reads of the SRAM wrapper against a tracked-address abstraction of the macro. |
| `byte_fifo` | BMC, proof, cover | Count, full/empty, ordering, simultaneous push/pop, and refusal of a push into a full FIFO, against an age-ordered reference queue. |
| `host_interface` | BMC, proof, cover | The host-link pin contract under an unconstrained, glitching host: every strobe and state change traces back to one byte that was on the pins at two consecutive clock edges; a second strobe needs a stable 8'h00 in between; a stable 8'h00 followed by a stable command always acts; payload nibbles, address post-increment, SRAM readback capture, FIFO channel select, and stop on halt. |
| `fabric_timer` | BMC (24 cycles), cover | Every tick against an independent cycle-count model (first tick `phase + 1` cycles after a start or resync, then every `reload + 1`); hold freezes time; stop wins; the output moves only on a toggle tick or to idle. |
| `fabric_shifter` | BMC (24 cycles), cover | `out` equals an independently built frame (pre/data in both bit orders/parity/post, lead mode), including gapless restarts and burst mode (words chained with no inner framing, end latch, FIFO underrun); with the input looped back, a fully sampled frame reproduces the word in `rx_data` and in every RX push; FIFO requests hold until granted; overrun is flagged. |
| `fabric_counter` | BMC, proof, cover | Count, threshold level and hit pulse against a per-mode reference (event count, run of ones/zeros/equal bits) with clear priority, including saturation at 255. |
| `fabric_crc` | BMC, proof, cover | The 32-bit configuration against the mirror-image reflected LFSR used by software on every absorb, emit, init, output bit and (registered) residue match. |
| `fabric_lut` | BMC, proof, cover | The glue cell's combinational output is the addressed truth-table entry; the registered output loads it exactly on enable-line cycles and clears while disabled. |
| `px8_controller` | BMC (16 cycles), cover | An independent ISA reference model runs a symbolic 16-byte program (every opcode, prefix chain, branch and stall). Each cycle it predicts the fetch and data-read addresses, every side-effect output (config writes, including each word of a block config load, readback, events, FIRE, pins, FIFO requests and channel) and when the instruction retires under arbitrary handshakes, including level waits that never retire in their first cycle. |
| `fabric_core` | BMC (24 cycles), cover | The whole spatial core running any program from a symbolic SRAM against arbitrary pins and FIFO states: no pin is ever driven before the SRAM has returned a byte every arm write needs (`WCF` n=1, 8'h81, or a block entry's address byte 8'h31); a stopped engine releases the pins; no pop from an empty FIFO channel, no push into a full one; the controller feeds one channel at a time. |

The proofs are unbounded (`abc pdr`). PDR did not converge on the timer or
the shifter within 30 minutes, nor did k-induction (their reference models
count differently from the RTL, and without hierarchical references a
harness cannot state the linking invariant), so those two are bounded, as are
the controller and the core, whose state is too large for PDR.

Each target also has cover statements so over-constrained harnesses are
visible: a pulled three-word burst framed by start and stop bits, a
prefixed constant reaching `A` and a prefixed config write, an LDM data
load at `P`, a two-word block config load, a level wait, a DJNZ loop, a
pin driven after arming, SRAM readback, and so on.

## Mutation check

`make formal` runs `mutation_check.py` last. It builds temporary RTL
variants with one representative defect each and requires the focused BMC
target to reject every one (the repository RTL is never modified):

| Target | Mutations |
| --- | --- |
| `host_interface` | accept without the two-cycle stability check; no address post-increment |
| `px8_controller` | prefix bits dropped; DJNZ testing `C` before the decrement; level wait retiring in its first cycle; block data bytes swapped; block pointer stuck |
| `fabric_lut` | registered cell ignoring its enable line |
| `fabric_core` | arm bit bypassed (pins live as soon as the engine runs) |
| `byte_fifo` | count direction reversed |
| `fabric_timer` | reload off by one; clock-stretch hold ignored |
| `fabric_shifter` | RX and TX bit order; parity polarity; overrun lost; burst end latch forgotten; pre bits repeated between burst words |
| `fabric_counter` | wrong run-of-equal restart value |
| `fabric_crc` | feedback ignoring data |

## Adding a block

1. Create `formal/<block>/<block>.sby` and a property harness with a
   `clk` input.
2. Write the reference independently of the RTL, and keep environment
   assumptions separate from design assertions.
3. Add cover statements so over-constrained proofs are visible.
4. Add the directory name and its tasks to `formal/Makefile`, and at least
   one mutation to `mutation_check.py`.
5. Run bounded checks before adding an unbounded proof task.

The foundry SRAM is replaced only during formal runs by the sound
tracked-address abstraction. Physical views and timing are validated by
the ASIC flow, while cocotb and the standalone Verilator test compile and
exercise the delivered behavioral model.

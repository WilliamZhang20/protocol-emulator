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
| `host_interface` | BMC, proof, cover | The host-link pin contract under an unconstrained, glitching host: every strobe and state change traces back to one byte that was on the pins at two consecutive clock edges; a second strobe needs a stable 8'h00 in between; a stable 8'h00 followed by a stable command always acts; payload nibbles, address post-increment, SRAM readback capture, FIFO channel select, eop tagging by command F, the RX byte's tags in status, and stop on halt. |
| `fabric_timer` | BMC (24 cycles), cover | Every tick against an independent cycle-count model (first tick `phase + 1` cycles after a start or resync, then every `reload + 1`); hold freezes time; stop wins; the output moves only on a toggle tick or to idle. |
| `fabric_shifter` | BMC (24 cycles), cover | `out` equals an independently built frame (pre/data in both bit orders/parity/post, lead mode), including gapless restarts and burst mode (words chained with no inner framing, end latch, FIFO underrun, eop-tagged end) and injected parity errors, and the abort line (the frame in progress is dropped with no word pulse or push); with the input looped back, a fully sampled frame reproduces the word in `rx_data` and in every RX push; FIFO requests hold until granted; overrun is flagged; RX pushes are tagged eop exactly at the end of a burst frame and, with the frame fully sampled in loopback, err exactly when its parity was injected. |
| `fabric_counter` | BMC, proof, cover | Count, threshold level (registered, yet equal to the live compare on every cycle) and hit pulse against a per-mode reference (event count, run of ones/zeros/equal bits) with clear priority, including saturation at 255. |
| `fabric_crc` | BMC, proof, cover | The 32-bit configuration against the mirror-image reflected LFSR used by software on every absorb and emit (each with or without its gate level), init, output bit and (registered) residue match. |
| `byte_tile` | round trip (BMC, 32 cycles), checksum (BMC, 20 cycles), covers | Byte tiles end to end. ESCAPE → UNESCAPE: for any valid escape map (symbolic codes) and any packet stream, every byte and eop tag arrives exactly as sent, never tagged err, nothing invented. CHECK generate → verify (add or xor, any initial value): a packet arrives tagged err exactly when one of its bytes was corrupted on the link (any nonzero flip, symbolic place) or, in the other mode, when its sender asked for an injected error. Every tile output: a byte waiting to be taken never changes. |
| `fabric_logic` | BMC, proof, cover | The logic cell's register loads the addressed truth-table entry exactly on enable-line cycles, holds otherwise, and holds its configured start value while disabled. Both configuration contexts are modelled: writes reach any set of contexts and the active one changes arbitrarily every cycle, and the cell always follows the active context. |
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


## Protocol proofs

`protocols/` proves whole protocols as the chip runs them: the complete core
with its program memory holding exactly the bytes a cocotb test loads
(`gen_rom.py` assembles them from `test/cocotb_tests/protocols.py` on every
run), a symbolic TX FIFO (any bytes, arriving at any time) and symbolic
input pins.

| Target | Program | Depth | Checked behavior |
| --- | --- | --- | --- |
| `uart_tx` | `uart_transmit(4)` | 110 after arm | The pin carries the popped bytes' 8N1 frames in order, every bit exactly 4 cycles; no frame without a byte; a waiting byte starts within 8 cycles; idle high; once armed, always driven. |
| `ws2812` | `ws2812_transmit(6, 1, 2)` | 120 after arm | Every high pulse is exactly 1 cycle for a 0 and 2 for a 1, MSB first, in byte order; the bits of a byte start exactly 6 cycles apart, a later byte never sooner; no pulse without a byte. |
| `spi_master` | `spi_master(0, 3, 2)` | 130 after arm | A two-byte transaction whose bytes arrive at any times: SCK rests low and still while CS is high; CS leads SCK's first edge by at least a half period; exact 3-cycle half periods within a byte, pauses only between bytes; CS rises only between bytes; MOSI stable while SCK is high; MOSI at each rising edge is the next bit of the popped bytes. |

The configuration phase before the program arms the fabric is one
deterministic run: the harness supplies no FIFO bytes and holds the input
pins constant until a pin is driven. `prearm.py` simulates that prefix in
yosys and writes it as the initial state (`sim -w`), so the bound is spent
on the protocol. Flip-flops the prefix leaves undefined stay
unconstrained.

`protocol-negative` reruns each proof with a program that is wrong only in
its timing and requires a counterexample, so a proof cannot pass by
checking too little.

## Mutation check

`make formal` runs `mutation_check.py` last. It builds temporary RTL
variants with one representative defect each and requires the focused BMC
target to reject every one (the repository RTL is never modified):

| Target | Mutations |
| --- | --- |
| `host_interface` | accept without the two-cycle stability check; no address post-increment |
| `px8_controller` | prefix bits dropped; DJNZ testing `C` before the decrement; level wait retiring in its first cycle; block data bytes swapped; block pointer stuck |
| `fabric_logic` | cell ignoring its enable line; start value ignored; a context write ignoring its context mask; the context select inverted |
| `fabric_core` | arm bit bypassed (pins live as soon as the engine runs) |
| `byte_fifo` | count direction reversed |
| `fabric_timer` | reload off by one; clock-stretch hold ignored |
| `fabric_shifter` | RX and TX bit order; parity polarity; overrun lost; burst end latch forgotten; pre bits repeated between burst words; injected parity error ignored; RX eop tag lost; abort line ignored |
| `byte_tile` | escape map swapped; unescape restoring the wrong byte; checksum not negated; error injection ignored; output dropped before it is taken |
| `fabric_counter` | wrong run-of-equal restart value; threshold level one cycle late |
| `fabric_crc` | feedback ignoring data; absorb gate ignored |

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

# Formal verification

Formal checks complement the cocotb regression; they do not replace it. Each
implemented RTL block gets an independent directory containing its harness,
properties, and `.sby` task definition.

## Running the suite

Install the YosysHQ OSS CAD Suite, then run from the repository root:

```sh
make formal
```

Run an individual target with:

```sh
make -C formal program_memory
make -C formal byte_fifo
make -C formal fabric_timer
make -C formal fabric_shifter
```

Results and counterexample traces are written beneath `build/formal/`.

The SRAM target runs bounded checks, an unbounded induction proof, and a cover
trace. Its formal macro is a tracked arbitrary-address abstraction, which proves
masked write and synchronous read behavior without expanding all 8192 storage
bits into the solver.

| Target | Checked behavior |
| --- | --- |
| `byte_fifo` | Unbounded FIFO count, full/empty, ordering, and simultaneous push/pop against an age-ordered reference queue. |
| `fabric_timer` | Bounded: running state and every tick match an independent cycle-count model (first tick after `phase + 1`, then every `reload + 1`), hold freezes time, stop wins, and the output moves only on a toggle tick or to idle. |
| `fabric_shifter` | Bounded: `out` equals an independently built frame (pre/data in both bit orders/parity/post, lead mode), done timing, and with the input looped back a fully sampled frame reproduces the word in `rx_data` and the RX push; FIFO requests hold until granted and overrun is flagged. |

The tile targets are BMC + cover. Unbounded PDR did not converge on their
16-bit counters within 15 minutes, so no proof is claimed for them.

Each target also has a cover task so its important scenario is demonstrably
reachable. `make formal` runs `mutation-check` last. That script makes six
temporary RTL variants and requires the focused BMC targets to reject a FIFO
count reversal, a timer reload off-by-one, an ignored clock-stretch hold, a
shifter bit-order bug, a parity polarity flip, and a lost overrun flag. The
repository RTL is never modified by the mutation run.

## Adding a block

1. Create `formal/<block>/<block>.sby` and a property harness.
2. Keep environmental constraints separate from design assertions.
3. Add cover statements so over-constrained proofs are visible.
4. Add the directory name to `TARGETS` in `formal/Makefile`.
5. Run bounded checks before adding an unbounded proof task.

Use simple clocked `assume`, `assert`, `$past`, and `cover` constructs supported
by the open-source Yosys frontend. Prefer properties at module interfaces over
assertions coupled to private implementation state.

The foundry SRAM is replaced only during formal runs by the sound tracked-address
abstraction. Physical views and timing are validated by the ASIC flow, while
cocotb and the standalone Verilator test compile and exercise the delivered
behavioral model.

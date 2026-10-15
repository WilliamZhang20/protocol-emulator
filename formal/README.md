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
make -C formal fabric_counter
make -C formal fabric_crc
```

Results and counterexample traces are written beneath `build/formal/`.

The SRAM target runs bounded checks, an unbounded induction proof, and a cover
trace. Its formal macro is a tracked arbitrary-address abstraction, which proves
masked write and synchronous read behavior without expanding all 8192 storage
bits into the solver.

| Target | Checked behavior |
| --- | --- |
| `byte_fifo` | Unbounded FIFO count, full/empty, ordering, and simultaneous push/pop against an age-ordered reference queue. |
| `fabric_timer` | Bounded: every tick matches an independent cycle-count model (first tick `phase + 1` cycles after a start or resync, then every `reload + 1`), hold freezes time, stop wins, and the output moves only on a toggle tick or to idle. |
| `fabric_shifter` | Bounded: `out` equals an independently built frame (pre/data in both bit orders/parity/post, lead mode), including gapless restarts; with the input looped back a fully sampled frame reproduces the word in `rx_data` and the RX push; FIFO requests hold until granted and overrun is flagged. |
| `fabric_counter` | Bounded: count, threshold level and hit pulse match a per-mode reference (event count, run of ones/zeros/equal bits) with clear priority. |
| `fabric_crc` | Bounded: the 32-bit configuration matches the mirror-image reflected LFSR used by software on every absorb, emit, init, output bit and residue comparison. |

The tile targets are BMC + cover. Unbounded PDR did not converge on the
16-bit counters within 15 minutes, so no proof is claimed for them, and
counter saturation at 255 lies beyond the BMC depth.

Each target also has a cover task so its important scenario is demonstrably
reachable. `make formal` runs `mutation-check` last. That script makes nine
temporary RTL variants and requires the focused BMC targets to reject a FIFO
count reversal, a timer reload off-by-one, an ignored clock-stretch hold,
shifter bit-order bugs on transmit and receive, a parity polarity flip, a
lost overrun flag, a wrong run-of-equal restart value, and a CRC feedback
that ignores data. The
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

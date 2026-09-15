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
```

Results and counterexample traces are written beneath `build/formal/`.

## Adding a block

1. Create `formal/<block>/<block>.sby` and a property harness.
2. Keep environmental constraints separate from design assertions.
3. Add cover statements so over-constrained proofs are visible.
4. Add the directory name to `TARGETS` in `formal/Makefile`.
5. Run bounded checks before adding an unbounded proof task.

Use simple clocked `assume`, `assert`, `$past`, and `cover` constructs supported
by the open-source Yosys frontend. Prefer properties at module interfaces over
assertions coupled to private implementation state.

The foundry SRAM is replaced during formal runs by a cycle-accurate logical
model. Physical views and timing are validated by the ASIC flow, while cocotb
and the standalone Verilator test exercise the delivered behavioral model.

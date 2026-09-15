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
make -C formal uart_tx
make -C formal uart_rx
```

Results and counterexample traces are written beneath `build/formal/`.

The SRAM target runs bounded checks, an unbounded induction proof, and a cover
trace. Its formal macro is a tracked arbitrary-address abstraction, which proves
masked write and synchronous read behavior without expanding all 8192 storage
bits into the solver.

Each UART target exhaustively checks 300 formal steps for every possible
8-bit payload and produces a reachable complete-frame cover trace. TX assertions
check FIFO consumption, output enable, start/data/stop levels, and idle recovery;
RX assertions check one correctly reconstructed FIFO byte.

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

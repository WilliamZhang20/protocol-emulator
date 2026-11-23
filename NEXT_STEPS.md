# Next steps and experiment status

**Current direction:** The numbered notes below are historical planning notes;
in particular, the later statement dropping CIRCT has been superseded by the
decision to reuse the Rust frontend and experiment with CIRCT lowering.

- Current hardware branch: `experiment/two-sram-placement`, described in
  `PLACEMENT_EXPERIMENT.md`. `work/tile-routing-experiment` retains the prior
  chip top and the standalone tile experiments.
- Compiler experiment: sibling `protocol-emulator-compiler` branch
  `work/tile-fabric-codesign`, described in `circt_lab/README.md`.
- Next: lower actual source transaction functions and byte streams onto the
  integrated timer, shifter, control, routing, and SRAM fabric. The current
  source-derived control/datapath image still uses a hand-written SRAM adapter
  and host preload. Rerun the protocol corpus as semantic coverage grows.
  The first two-bank physical run passed LVS but failed M1 spacing; a revised
  placement needs a fresh physical run before any fit claim.
- The control-only end-to-end example is deliberately small. Corpus export or
  a component table is not evidence that an entire protocol fits.

## Earlier planning notes

0. Clean up the loose ends (one session).

- Decide the uncommitted two-input actor RTL change: commit it or drop it.

- Land or close compiler PR #6.

- Move Codex's uncommitted compiler pile onto its own branch.



Why first: right now nobody can tell what's real. Every later step is cheaper on a clean base.



1. Objectives (half a page, from you).

Why: they decide what the laboratory measures and how agents judge. Without them, step 4 is opinion.



2. Arch file: turn today's hardware constants into data.

The existing backend reads counts, sizes, memory banks/ports, FIFO depth and latencies from current.arch instead of hardware.rs.

Why early: it's small, mechanical, and unblocks everything else.

Caveat: the signal-space line numbering is derived from tile counts, so the encoding has to be computed from the file rather than hard-coded. That's the real work in this step.



3. Laboratory v0, on the existing backend.

Compile the example corpus against any arch file and report fit, resource use, memory requests and contention, and wire-rate margins.

Why before the IR: many of your open hardware questions only change parameters (more shifters, SRAM banks, buffer sizes, FIFO depth). The current backend can answer those once it's parameterized. You get evidence in weeks, not after a rewrite.



4. Run the agent loop on the memory question.

Why memory first: you raised it first, it's the most concrete question, and there's already trace data to start from. It also tests the loop end to end on a real decision.



5. IR and mapper rewrite.

Why this late: it's only needed for structural changes: new tile types, a coherent fabric, width as a mapping choice. Doing it after steps 3–4 means the primitive set is designed against architectures that are actually on the table, not guessed. Designing the IR first is how we'd build the wrong one.



6. Structural hardware changes through the loop: fabric coherence, then width.



Throughout: the chip stays programmable. Every step keeps the existing RTL tests passing.



One thing would reorder this: a tapeout deadline. If there is one, step 4 and any parameter-only RTL changes move ahead of everything else, and step 5 slips past the deadline. Is there one?



What changes



- Mapping means compiling a program into a configuration of a given chip (image, tile configs, selectors, controller code), like VTR placing a netlist onto a fixed FPGA. It never produces Verilog.

- The architecture laboratory never touches RTL. It answers "if the chip had X, would the corpus compile, fit and meet timing?" Agents read that evidence, judge it against objectives and rules, and propose hardware changes. Those changes get written by hand in RTL.

- CIRCT/MLIR drops out for now. Its main payoffs were RTL generation and simulating unbuilt hardware, and you've ruled out both. The IR can be plain Rust data structures with MLIR-like discipline: typed values, a checker at each level, explicit lowering steps. Less to build and maintain.



The specs



1. Compiler (one system).

.spt → program IR → mapping (primitives → tile types → tile instances → signal routes → memory layout) → chip configuration.

- The IR's operations are fabric-independent primitives; widths are type parameters; no operation copies a current tile.

- Mapping reads an arch file and nothing else about the hardware.

- Done when every example compiles through it to the same configuration as today's backend, and its RTL tests pass. Then the current backend is deleted.



2. Arch file (the only interface between hardware and software).

- Start by turning hardware.rs into data: tile types (which primitives each implements, width, latency), counts, signal-space/interconnect rules, memories (size, banks, ports), FIFOs, pads.

- The current chip is current.arch. A candidate is a copy with edits.

- Done when the compiler reads all hardware facts from it, with zero hardware constants left in code.



3. Laboratory (evidence, no judgment).

(arch file, workload corpus) → report:

- per program: fits or not, and why;

- resource use;

- memory requests and bank contention (Codex's memory_model slots in here);

- latency and throughput bounds versus the protocol's wire rate.



Done when the current.arch report agrees with measured RTL runs.



4. Agent arch loop (judgment, no software).

Objectives + rules → agent proposes an arch-file edit → laboratory report → accept or reject with written reasoning. An accepted edit becomes a hand-written RTL change, then synthesis/GDS calibration, then current.arch is updated. The "hillclimb" is this written procedure, not code.



Hardware threads Codex raised but never followed up



1. Memory. Try small local stream/row buffers first. Banking the main SRAM only pays off once traces show competing independent requests. Two stored UART streams already run within 0.86% of their two-wire timing floor.

2. Fabric coherence. Define a common tile interface and group tiles around protocol work. Renaming groups alone gains nothing while the global 64-line signal space remains.

3. Width. Make the byte-level/bit-level split a mapping choice, not an architectural layer.

4. Loose ends: the uncommitted two-input actor RTL change, and compiler draft PR #6.



These become the first arch-file experiments in step 4, once 1–3 exist.



What I need from you



The fundamental objectives the agents judge against. My draft:

1. Protocol coverage: which protocols must fit.

2. Wire-rate and latency guarantees.

3. Area/timing budget for the Tiny Tapeout tile.

4. Simplicity of programming.



What's missing, and what's the priority order?



Once you confirm, I'll write spec 1 (IR op set) and spec 2 (arch file schema), each about a page.

## Cleanup status — 2026-11-22

- Compiler PR #6 was merged as `14ddd5f`; its CI passed the example RTL suite.
- Compiler architecture experiments are preserved on local branch
  `work/architecture-laboratory-wip` in commits `8338e15` and `d2c8de2`.
  The implementation checkpoint is large and remains experimental.
- The expanded actor ABI is a separate hardware experiment, not the baseline.
  Full RTL regression passed 134/134; generic actor synthesis grew from 298 to
  632 cells, so routed measurements and workload justification remain open.
- Compiler baseline `main` targets hardware revision `7dd2f41` (actor ABI 1).
  The compiler WIP's actor images target ABI 2 and need matching experimental
  RTL. See `docs/architecture-triage.md` for details.

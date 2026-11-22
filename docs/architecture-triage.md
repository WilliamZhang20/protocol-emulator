# Architecture and repository triage

Snapshot: 2026-11-22. This is a working assessment, not a new hardware
specification. Preserve the existing uncommitted work until it has been
reviewed and split into coherent changes.

## What the current chip can do

The fabric can implement bit-level protocols: synchronized inputs and edge
cells feed timers, registered logic, shifters, control actors and pin cells.
Pins support input, push-pull and open-drain modes. The controller can read
pin levels and write configuration/flags, so it can also influence outputs
indirectly. It has no dedicated GPIO instruction or fixed-cycle delay
instruction; instruction-driven transitions are limited by controller and
memory timing. Configured fabric generates precisely timed bit edges. This is
not an unrestricted CPU-style bit-banging interface, nor does pin-level
capability prove that an arbitrary protocol can be mapped or meet its timing.

The byte pipeline provides fixed byte-oriented stream operations such as
escaping and packet handling. It does not prevent bit-level pin operation,
but it is a hardwired choice for stream processing, rather than a general
width-parametric compute fabric. Keep it as a baseline candidate, not a
requirement for the next design. The larger coherence issue is that fixed
heterogeneous resources communicate through a global 64-line selector space;
one registered logical hop does not imply short physical wires. Width,
interconnect, resource grouping and controller dependence should be compared
together on real workloads, including narrow and non-byte-aligned protocols.

## What is real

* Hardware branch `arch/spatial8x4` at `7dd2f41` is the RTL baseline.
  The ABI-changing actor experiment is preserved as `c053034` on local branch
  `work/actor-abi2-experiment`. ABI 2 packs transition rows differently and
  adds a second input or additional state; it is not compatible with
  configurations for the baseline actor ABI.
* Compiler [PR #6](https://github.com/WilliamZhang20/protocol-emulator-compiler/pull/6)
  was merged into `main` as `14ddd5f`. It targets the committed hardware ABI;
  CI run 44974603716 passed the full example RTL regression and installed-binary
  smoke test. Its changes are distinct from the following local work.
* The compiler experiments are saved on local branch
  `work/architecture-laboratory-wip`, based on `1ba38ba`: checkpoint
  `8338e15` contains the coupled implementation and tests, and `d2c8de2`
  contains the audit and laboratory notes. The checkpoint is large and needs
  further review and splitting before integration. Generated `build/` and
  the separate nested RTL checkout remain untracked and were not committed.
  Do not merge this experiment into PR #6 implicitly.
* `cargo test` passes on that local compiler work. Hardware `make actor-test
  one-hop-check` passes with the local RTL. Those checks do not establish
  cross-revision compatibility, full protocol correctness, or routed timing.
  Compiler-generated two-input, five-state UART, and consecutive-pulse
  actor examples also pass against the local ABI 2 RTL. Generic Yosys `synth`
  reports 298 cells for one ABI 1 actor and 632 for ABI 2 (same tool and
  flow); this is an unmapped comparison, not physical area or timing.

## Decisions and next actions

1. Keep actor ABI 2 as an experiment: its extra capabilities work in the
   tested configurations, but the generic cell increase and lack of routed
   comparison do not justify adopting it as the baseline. Compare a real
   protocol and routed area/timing before committing to this block shape.
   Treat the two ABIs as separate hardware targets meanwhile.
2. PR #6 is merged; use compiler `main` at `14ddd5f` with hardware `7dd2f41`
   as the reproducible baseline. Do not use ABI 2 images with that hardware.
3. Review and split the large compiler checkpoint into integration-ready
   changes. Preserve the hardware experiment and unrelated working-tree edits
   until they can be separated. Do not rewrite or delete unrelated user changes.
4. Establish a current-hardware architecture file and verify the compiler's
   encoding against RTL before sweeping alternative architectures. Existing
   `model-ir`, partial graph and memory reports are useful prototypes, not a
   complete legality-preserving mapper or calibrated architecture oracle.
   Do not report a candidate as fitting merely because a resource count fits.

For the comparison objective, treat correctness and pin-level timing as hard
constraints, along with actual area and timing closure. Then compare protocol
coverage, independent progress, communication locality, latency/throughput,
and programming effort; do not combine them into a single unexplained score.
The required protocol set, wire rates, physical budget and their priorities
still need an explicit owner decision. Include irregular widths, concurrent
channels and backpressure in that workload set. A candidate is only ready to
justify RTL work when the assumptions, unknowns and baseline measurements are
visible alongside its modeled results.

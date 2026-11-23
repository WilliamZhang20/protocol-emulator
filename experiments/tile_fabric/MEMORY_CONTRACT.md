# Experimental memory contract

This describes `experiment_memory_fabric`, not a finalized architecture or a
host programming ABI. There are two 1024 × 8, single-port banks, and two
requesters. Each requester has a configured route to exactly one bank.

| Event | Contract |
| --- | --- |
| Configure | At a rising edge with `rst_n=1`, `arm=0`, and `cfg_we=1`, latch both routes. Writes while armed are ignored. Reset selects bank 0 for both requesters. |
| Request | At an armed rising edge, `req && ready` accepts a request. `ready` is combinational and only asserted with `req`. The requester holds `req`, address, write flag and data stable until acceptance. A global disarm or reset may cancel an unaccepted request. |
| Banks | Each bank accepts at most one request per edge. Requests to different banks proceed together. When both request one bank continuously, round robin grants them alternately; an unopposed request is granted immediately. |
| Write | Data is committed at the accepting edge. There is no write response and no rollback. |
| Read | Data and `rvalid` are available after the accepting edge and remain valid until the next edge. Back-to-back reads can produce a response every cycle; the recipient must consume them without backpressure. An accepted read response remains visible after disarm. |
| Reset | Reset is synchronous for configuration and response tokens; `ready` is gated low as soon as reset is asserted. At the reset edge pending response tokens are cleared. SRAM contents are not reset. |
| Data | Addresses are byte addresses 0–1023 per bank. Reads of unwritten locations are undefined. No coherence, atomic multi-byte access, masks, queues, or address translation are provided. |

The macro's synchronous read data and the registered response token change
after the same edge. In edge-sampled SVA, `rvalid` sampled at edge N therefore
corresponds to a read accepted at edge N−1. The receiving logic samples that
response at edge N. Disarming does not erase already accepted writes or reads.

The separate `memory_shift_fabric` adapter is an experiment: `transfer_active`
indicates a transaction, `start` is used only when armed and idle, and starts
while busy are ignored. Disarm resets and cancels the adapter at the next edge;
it never resumes after reconfiguration. Already accepted writes remain in
memory, so disarm can leave a partial multi-byte result. The adapter cannot
abort or roll back an accepted write. Its 9–16-bit two-byte format is described
in the adjacent README. No instruction memory is involved.

## Verification

`make tile-memory-lint` checks both the behavioral and macro-backed RTL with
warnings treated as errors. It waives grouped-module filename warnings and
the vendor functional model's unused analog-delay selector only.

`make tile-memory-experiment` runs directed macro/model comparisons, a 12-bit
transfer and abort test, and three seeded 12,000-cycle randomized tests. The
random test uses an independent bank-content scoreboard, checks reads and
writes against both implementations, exercises reset/reconfiguration and
checks that nonaccepted requests remain stable. `memory_contract_assertions.sv`
adds sampled SystemVerilog assertions for response latency, no phantom grants,
disarmed behavior, independent-bank progress, exclusive grants, bounded
fairness, and the requester's stable-until-ready obligation.

`make tile-memory-assertion-mutation` checks the correct arbiter, then builds a
temporary mutants that starve requester 1 or drop bank 0 read responses. The
corresponding fairness and response SVAs must reject them; the mutation bench
contains no separate scoreboard.
These are simulation checks, not an exhaustive formal proof. The macro is its
functional model, not post-layout timing simulation.
The `tile experiment` CI workflow runs these memory checks and synthesis. The
separate GDS workflow still targets the existing chip, not this prototype.

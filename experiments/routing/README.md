# Initial routing experiment

Run from the hardware repository root:

```sh
make routing-experiment
```

This is a **selector microbenchmark**, not a protocol fabric or an area/timing
verdict. It compares one registered Boolean consumer in three configurations:

| Candidate | Reachable sources | Consumer latency | Generic cells | Flops |
| --- | ---: | --- | ---: | ---: |
| `global_selector` | 64 | 1 edge | 132 | 1 |
| `flat15_selector` | same 15 as local | 1 edge | 20 | 1 |
| `local_selector` | 7 direct + 8 via a registered relay | 1 edge direct; 2 edges relayed | 16 | 2 |

The `global_selector` models the shape of one 64-way input selector used by
the current fabric, not the full `fabric_logic` tile or its mixed-width
selectors. The 15-source flat control separates the benefit of reducing
reachability from the effect of the relay. In this particular mapped example,
the relay saves four generic cells versus flat15 while adding a flop and a
cycle on eight of the 15 paths. Generic cells are not equally sized, so that
difference cannot be interpreted as a percentage of physical area.

The testbench checks both rising and falling transitions for all 15 shared
sources, including exact latency. Select inputs are held stable; as on an
armed static fabric, the benchmark does not test runtime reconfiguration.
There is no reset in these proxies: the test flushes the relay before checking
remote paths. Real hardware needs defined reset/arm and event semantics.

Numbers above were produced with Yosys 0.67+111 (`4821ed17b-dirty`) and
Verilator 5.051 devel. They depend on the tool and synthesis flow. The script
reports the running tool version and JSON cell breakdown to make reruns
auditable. The native Yosys in `.tools/oss-cad-suite/bin` is used by the make
target, matching the repository's structural checks.

Important omissions:

- These candidates differ in reachability; `local_selector` is not a
  replacement for an arbitrary 64-way input. The benchmark includes a flat
  15-source control, but no placement/routing or protocol-fit analysis.
- Configuration registers, reset, fanout, replicated junctions, buffering,
  bidirectional or multi-consumer links, control logic, pins and word-wide
  ready/valid routes are excluded. Selects are top-level ports; their storage
  and distribution costs are not counted.
- Yosys generic cell counts do not include physical wires, standard-cell area,
  setup/hold, routing congestion, clock tree or power. They do not establish
  that a local fabric is smaller or faster on the actual chip.
- No protocol waveform or independent peer is exercised. A delay that is
  acceptable in this test may violate a real device's response timing.

Next, specify a small real tile graph with concrete finite links, map the
same pin-level protocol to it and the baseline, then synthesize and route
both with the same physical constraints. Record fit, source-to-pin latency,
throughput, configuration cost and physical area/wire/timing. Add independent
concurrent workloads and the large stored-frame case before drawing a general
architecture conclusion.

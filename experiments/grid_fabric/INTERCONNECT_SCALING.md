# Interconnect scaling: switch-box mesh against the signal space

Step 1.6. `tools/interconnect_scaling.py` synthesizes both interconnects
for the same tiles at 1, 3, 5 and 8 lanes and reports standard-cell area
from the IHP liberty (typical corner; `make interconnect-scaling
LIBERTY=<lib>`). Tile logic is excluded: it is the same in both.

A lane is one grid row: 4 cells, 16 tile outputs, 14 tile-input
selectors (today's average per row).

- **Mesh (this fabric):** 4 `grid_switch` cells per lane (4 tracks per
  direction, unregistered hops, 48 selector bits each) and 14 sink
  selectors of 22 ways (local outputs and the four incoming tracks, 5
  bits each).
- **Signal space (arch/spatial):** one shared set of registered lines,
  16 per lane plus 18 shared (constants, controller pulses and flags, pin
  levels and edges); every tile input selects any line.

| Lanes | Mesh (um2) | Mesh cfg bits | Signal space lines | Signal space (um2) | Signal space cfg bits | Space / mesh |
|---|---|---|---|---|---|---|
| 1 | 17,218 | 262 | 34 | 12,659 | 84 | 0.74 |
| 3 | 61,365 | 786 | 66 | 57,012 | 294 | 0.93 |
| 5 | 106,019 | 1310 | 98 | 122,515 | 490 | 1.16 |
| 8 | 173,197 | 2096 | 146 | 267,490 | 896 | 1.54 |

Cost per added lane: mesh 22.1k, 22.3k, 22.4k um2 (constant); signal
space 22.2k, 32.8k, 48.3k um2 (growing with the lane count, because every
selector widens as lines are added: inputs x lines).

## Reading

- The mesh is linear: a lane costs the same wherever it is added. The
  signal space is cheaper for one lane, breaks even near four, and costs
  1.16x the mesh at the planned five lanes and 1.54x at eight.
- The mesh's cost is mostly configuration storage: 262 bits per lane
  against the signal space's 84 per lane at one lane. That is the lever
  for the mesh (cheaper configuration cells, or fewer selector bits per
  switch), not the multiplexers.

## What this does not measure

- **Connectivity.** The signal space connects any output to any input in
  one registered hop. The mesh has 4 tracks per direction and a fixed turn
  class per track, so some placements will not route; routability at five
  lanes (and the track count it needs, VTR's minimum channel width) is
  measured when the 5 x 4 grid exists (step 2), with the corpus.
- **Timing.** Signal-space hops are registered by construction. Mesh hops
  are not, so a long route is a long combinational path; the 3-row grid
  closes with +2.27 ns slow-corner slack (18fd40a), and five rows must be
  re-checked (step 2).
- **The earlier per-controller signal space** was richer than this model
  (64 lines and about 100 selectors for one controller's tiles); the
  model holds tiles equal so only the interconnect differs.

# RM_IHPSG13_1P_1024x8_c2_bm_bist

IHP SG13G2 foundry-provided 1024x8 single-port SRAM macro with BIST.

## Source

- **Repository**: https://github.com/IHP-GmbH/IHP-Open-PDK
- **Commit**: `7c124b7324778fbc2261aa8529ba04388eb3339e`
  ("SRAM cells layout: fixed PG pins Metal1.txt and Metal4.txt layers (#239)")
- **Path**: `ihp-sg13g2/libs.ref/sg13g2_sram/`

The checked-in GDS omits the non-mask `DigiBnd.drawing` (16/0) and
`SRAM.drawing` (25/0) marker elements. Tiny Tapeout's SG13CMOS5L user-block
precheck forbids these metadata layers. All fabrication geometry is unchanged.
The filtering is reproducible with `tools/filter_gds_layers.py`.

## Metal3 perimeter keepout

SRAM contains wide Metal3 geometry subject to `M3.f` = 0.6 µm spacing. The LEF
macro obstruction covers the macro body but not the external wide-metal
spacing, so `src/config.json` keeps a permanent M3-only routing obstruction
just south of the placed instance (`location` `[42, 81]`):

```json
"ROUTING_OBSTRUCTIONS": [
  ["Metal3", 41.5, 80.2, 189.4, 81.0]
]
```

That forces `A_DIN` (and similar) M3 routes off the violating track near
y=80.640 instead of relying on the router to pick a lower track by chance.
PDN, macro LEF, and placement stay unchanged.

## License

These files are part of IHP-Open-PDK and are licensed under the Apache License 2.0.
See the [IHP-Open-PDK repository](https://github.com/IHP-GmbH/IHP-Open-PDK) for details.

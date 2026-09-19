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
  ["Metal3", 174.0, 80.4, 189.4, 81.0]
]
```

Keepout is limited to the known `M3.f` hotspot (≈174–189 µm at y≈80.6)
so south-edge `A_DIN` M2→M3 escapes stay routable. A full-width strip
starved detailed routing. PDN, macro LEF, and placement stay unchanged.

## Metal4 power straps

PDNGen gaps vertical Metal4 stripes through the macro body. The custom
`src/pdn_cfg.tcl` then derives boundary feeders at run time from:

- the placed SRAM instance bbox and Metal4 pin geometry in the ODB
- the nearest same-net Metal4 stripe stubs already created by PDNGen
- Metal4 spacing keepouts against opposite-net stripes

`VDD!` / `VSS!` attach at south and north edges; `VDDARRAY!` only at north.
Short horizontal jogs stay outside the macro. No absolute strap coordinates
are hardcoded, so pitch/offset/placement changes can reshuffle geometry
without editing `pdn_cfg.tcl`.

## License

These files are part of IHP-Open-PDK and are licensed under the Apache License 2.0.
See the [IHP-Open-PDK repository](https://github.com/IHP-GmbH/IHP-Open-PDK) for details.

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

PDNGen builds the normal Metal4 stdcell stripe lattice (no per-macro grid in
`src/pdn_cfg.tcl`). Immediately after `OpenROAD.GeneratePDN`, LibreLane runs
`Project.ExtendPowerStripes` (`odb_sram_stripes.py`), which ports PRISM's
`allocate_sram()` strategy:

1. Discovers legal Metal4 supply corridors from the SRAM LEF OBS gaps (plus
   the declared `VDD!` / `VDDARRAY!` / `VSS!` PIN boxes), assigns polarity
   from those pins and the ~5.62 µm alternation, and clusters them into
   array L / band / array R.  `src/config.json` reads the LEF straight from
   the PDK (`pdk_dir::libs.ref/sg13cmos5l_sram/lef/...`), which declares all
   32 supply columns: 12 `VDD!`, 12 `VSS!` and 8 `VDDARRAY!`.  A trimmed LEF
   that declares one column per net leaves the rest invisible to the tools,
   and the whole array then draws through a single 2.81 µm column per
   supply.
2. Maps every tile stripe crossing the footprint onto the nearest free
   corridor of the same polarity, then completes VPWR/VGND pairs inside
   each region and tops each region up to `SRAM_PDN_MIN_PAIRS` pairs
   (default 2), keeping the named PIN columns for LVS.
3. Removes the crossing tile stripes and draws full-height replacements on
   the chosen columns, with M1↔M4 rail vias outside the macro.

`ERROR_ON_PDN_VIOLATIONS` is 0 because pdngen's connectivity check runs before
the rewrite; LVS is the connectivity signoff. Magic illegal-overlap / Magic
DRC are waived for the LEF-abstract Metal4 OBS bar on the `VDDARRAY!` column
break (same class as ihp-um-janestreet-prism); `RUN_KLAYOUT_DRC` stays on as
the physical DRC signoff.

## License

These files are part of IHP-Open-PDK and are licensed under the Apache License 2.0.
See the [IHP-Open-PDK repository](https://github.com/IHP-GmbH/IHP-Open-PDK) for details.

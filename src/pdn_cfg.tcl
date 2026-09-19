# Tiny Tapeout SG13CMOS5L power grid.
#
# User blocks may expose power only on Metal4. The 50 um stripe pitch and the
# SRAM's R0 placement roughly align VPWR/VGND stripes with the SRAM Metal4
# rails. PDNGen still gaps those stripes through the macro, so pdngen{} below
# adds SRAM-aligned boundary feeders and short outside-macro jogs onto the
# nearest stripe stubs — never through OBS.
#
# Coordinates are explicit (placement [42,81] + LEF pins + PDN pitch/offset).
# A fully ODB-derived variant was tried and tripped OpenROAD Tcl NULLs during
# GeneratePDN; keep geometry declarative until that path is proven in CI.

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET) } {
        lappend secondary $vdd
        set db_net [[ord::get_db_block] findNet $vdd]
        if { $db_net == "NULL" } {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }
    if { $gnd != $::env(GND_NET) } {
        lappend secondary $gnd
        set db_net [[ord::get_db_block] findNet $gnd]
        if { $db_net == "NULL" } {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domain CORE \
    -pins Metal4

set stripe_args [list]
append_if_equals stripe_args PDN_EXTEND_TO "core_ring" -extend_to_core_ring
append_if_equals stripe_args PDN_EXTEND_TO "boundary" -extend_to_boundary

add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal4 \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) \
    -spacing $::env(PDN_VSPACING) \
    -starts_with POWER \
    {*}$stripe_args

if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins
    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) Metal4"
}

proc replace_power_pin {block metal4 net_name sig_type x1 y1 x2 y2} {
    set net [$block findNet $net_name]
    set bterm [$block findBTerm $net_name]

    if {$bterm == "NULL"} {
        set bterm [odb::dbBTerm_create $net $net_name]
    }

    $bterm setSigType $sig_type

    foreach bpin [$bterm getBPins] {
        odb::dbBPin_destroy $bpin
    }

    set bpin [odb::dbBPin_create $bterm]
    odb::dbBox_create $bpin $metal4 $x1 $y1 $x2 $y2
    $bpin setPlacementStatus FIRM
}


# Wrap pdngen so we can:
#   1. attach SRAM-aligned Metal4 feeders at macro boundaries
#   2. clean up exported VPWR/VGND pins
rename pdngen pdngen_without_sram_bridges

proc pdngen {args} {
    pdngen_without_sram_bridges {*}$args

    set block [ord::get_db_block]
    set metal4 [[ord::get_db_tech] findLayer Metal4]

    # ------------------------------------------------------------
    # SRAM power topology (reference-style feeders)
    #
    # Placement: program_memory.sram at (42, 81), R0, SIZE 146.88 x 336.46
    # Macro bbox die: x=42.00..188.88  y=81.00..417.46
    #
    # LEF Metal4 pin geometry → die frame:
    #   VSS!      x=63.12..65.93   center 64.525   y=81.00..417.46
    #   VDD!      x=111.46..114.27  center 112.865  y=81.00..417.46
    #   VDDARRAY! x=159.33..162.14  center 160.735  y=126.465..417.46
    #
    # Stripe columns after PDNGen (pitch 50, width 2.1, offset 10):
    #   VGND near VSS:      x=65.93..68.03
    #   VPWR near VDD:      x=111.83..113.93
    #   VPWR near VDDARRAY: x=161.83..163.93
    #   VPWR west of VSS:   x=61.83..63.93  (same-layer keepout)
    # Stub tips ~y=80.52 (south) and ~y=417.94 (north).
    #
    # Hard rule: no top-level Metal4 through the macro interior / OBS.
    # VSS feeder cannot use the full pin width outside the macro: the
    # adjacent VPWR stub (x<=63.93) forces x1 >= 64.35 (0.42 um M4 space).
    # ------------------------------------------------------------

    set vpwr_swire [odb::dbSWire_create [$block findNet VPWR] ROUTED]

    # VDD! — full pin-width boundary feeders (already stripe-aligned).
    odb::dbSBox_create $vpwr_swire $metal4 \
        111460 80000 114270 81000 STRIPE
    odb::dbSBox_create $vpwr_swire $metal4 \
        111460 417460 114270 418440 STRIPE

    # VDDARRAY! — full pin-width north feeder + jog to VPWR stripe.
    odb::dbSBox_create $vpwr_swire $metal4 \
        159330 417460 162140 418440 STRIPE
    odb::dbSBox_create $vpwr_swire $metal4 \
        162140 417940 163930 418440 STRIPE

    set vgnd_swire [odb::dbSWire_create [$block findNet VGND] ROUTED]

    # VSS! — max-legal pin-aligned feeders + jogs to VGND stripe.
    odb::dbSBox_create $vgnd_swire $metal4 \
        64350 79520 65930 81000 STRIPE
    odb::dbSBox_create $vgnd_swire $metal4 \
        65930 79520 68030 80520 STRIPE
    odb::dbSBox_create $vgnd_swire $metal4 \
        64350 417460 65930 418500 STRIPE
    odb::dbSBox_create $vgnd_swire $metal4 \
        65930 417940 68030 418500 STRIPE

    # Export Tiny Tapeout pins on uninterrupted stripes east of the SRAM.
    replace_power_pin \
        $block $metal4 VPWR POWER \
        211830 3560 213930 707080

    replace_power_pin \
        $block $metal4 VGND GROUND \
        215930 3560 218030 707080
}

# Tiny Tapeout SG13CMOS5L power grid.
#
# User blocks may expose power only on Metal4. The 50 um stripe pitch and the
# SRAM's R0 placement align VPWR with a full-height VDD rail and VGND with a
# full-height VSS rail. With zero macro halo, these same-layer shapes abut.

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

# PDNGen leaves a 0.48 um placement-row clearance around the SRAM. The SRAM
# exposes vertical Metal4 supplies, so bridge the three deliberately retained
# LEF access points across that clearance to the aligned top-level stripes.
# Wrap pdngen so these shapes are added after grid generation but before
# LibreLane's check_power_grid calls.
rename pdngen pdngen_without_sram_bridges
proc pdngen {args} {
    pdngen_without_sram_bridges {*}$args

    set block [ord::get_db_block]
    set metal4 [[ord::get_db_tech] findLayer Metal4]

    set vpwr_swire [odb::dbSWire_create [$block findNet VPWR] ROUTED]
    odb::dbSBox_create $vpwr_swire $metal4 111830 79520 113930 81000 STRIPE
    odb::dbSBox_create $vpwr_swire $metal4 159330 417460 163930 419580 STRIPE

    set vgnd_swire [odb::dbSWire_create [$block findNet VGND] ROUTED]
    odb::dbSBox_create $vgnd_swire $metal4 64400 79520 68030 81000 STRIPE
}

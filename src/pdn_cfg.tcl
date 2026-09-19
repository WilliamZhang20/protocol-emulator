# Tiny Tapeout SG13CMOS5L power grid.
#
# User blocks may expose power only on Metal4. PDNGen builds the stripe grid
# from PDN_* env knobs, then the pdngen wrapper below derives SRAM feeders
# from the placed macro's Metal4 pin geometry and the stripes already in the
# ODB — no baked-in die coordinates. Lateral jogs stay outside the macro;
# nothing is drawn through OBS.

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

# ------------------------------------------------------------
# Helpers: query ODB instead of hardcoding die coordinates
# ------------------------------------------------------------

proc tt_dbu_per_um {} {
    return [[ord::get_db_tech] getDbUnitsPerMicron]
}

proc tt_m4_spacing {metal4} {
    # Prefer the layer spacing rule; fall back to 0.42 um (SG13 M4).
    set sp 0
    if {![catch {set sp [$metal4 getSpacing]}]} {
        if {$sp > 0} {
            return $sp
        }
    }
    return [expr {int(0.42 * [tt_dbu_per_um])}]
}

proc tt_find_sram_inst {block} {
    set cell_name "RM_IHPSG13_1P_1024x8_c2_bm_bist"
    foreach inst [$block getInsts] {
        if {[[$inst getMaster] getName] eq $cell_name} {
            return $inst
        }
    }
    return "NULL"
}

proc tt_inst_bbox {inst} {
    set b [$inst getBBox]
    return [list [$b xMin] [$b yMin] [$b xMax] [$b yMax]]
}

# Absolute die-frame bbox of a macro pin (prefer iterm bbox from ODB).
proc tt_pin_bbox_on_layer {inst pin_name layer} {
    set iterm [$inst findITerm $pin_name]
    if {$iterm == "NULL"} {
        error "SRAM instance missing pin $pin_name"
    }
    # dbITerm::getBBox is already in die coordinates.
    if {![catch {set ib [$iterm getBBox]}]} {
        return [list [$ib xMin] [$ib yMin] [$ib xMax] [$ib yMax]]
    }
    # Fallback: transform master pin geometry for R0 placements.
    set mterm [$iterm getMTerm]
    set ox [[$inst getBBox] xMin]
    set oy [[$inst getBBox] yMin]
    set x0 0
    set y0 0
    set x1 0
    set y1 0
    set have 0
    foreach mpin [$mterm getMPins] {
        foreach g [$mpin getGeometry] {
            if {[[$g getTechLayer] getName] != [$layer getName]} {
                continue
            }
            set ax [expr {$ox + [$g xMin]}]
            set ay [expr {$oy + [$g yMin]}]
            set bx [expr {$ox + [$g xMax]}]
            set by [expr {$oy + [$g yMax]}]
            if {!$have} {
                set x0 $ax; set y0 $ay; set x1 $bx; set y1 $by
                set have 1
            } else {
                set x0 [expr {min($x0,$ax)}]
                set y0 [expr {min($y0,$ay)}]
                set x1 [expr {max($x1,$bx)}]
                set y1 [expr {max($y1,$by)}]
            }
        }
    }
    if {!$have} {
        error "no Metal4 geometry on pin $pin_name"
    }
    return [list $x0 $y0 $x1 $y1]
}

# Collect Metal4 special-wire rectangles on a net: list of {x0 y0 x1 y1}.
proc tt_net_m4_rects {block net_name layer} {
    set net [$block findNet $net_name]
    set out {}
    if {$net == "NULL"} {
        return $out
    }
    foreach swire [$net getSWires] {
        foreach sbox [$swire getWires] {
            if {[[$sbox getTechLayer] getName] != [$layer getName]} {
                continue
            }
            lappend out [list [$sbox xMin] [$sbox yMin] [$sbox xMax] [$sbox yMax]]
        }
    }
    return $out
}

proc tt_rect_cx {r} {
    return [expr {([lindex $r 0] + [lindex $r 2]) / 2.0}]
}

proc tt_x_overlap {a b} {
    set lo [expr {max([lindex $a 0], [lindex $b 0])}]
    set hi [expr {min([lindex $a 2], [lindex $b 2])}]
    return [expr {$hi - $lo}]
}

proc tt_y_overlap {a b} {
    set lo [expr {max([lindex $a 1], [lindex $b 1])}]
    set hi [expr {min([lindex $a 3], [lindex $b 3])}]
    return [expr {$hi - $lo}]
}

# Vertical-ish rects (taller than wide) near pin_cx, entirely south of y_cut.
proc tt_nearest_south_stub {rects pin_cx y_cut} {
    set best {}
    set best_dist 1e99
    foreach r $rects {
        lassign $r x0 y0 x1 y1
        set w [expr {$x1 - $x0}]
        set h [expr {$y1 - $y0}]
        if {$h < $w} {
            continue
        }
        if {$y1 > $y_cut} {
            continue
        }
        set dist [expr {abs(($x0+$x1)/2.0 - $pin_cx)}]
        if {$dist < $best_dist} {
            set best_dist $dist
            set best $r
        }
    }
    return $best
}

proc tt_nearest_north_stub {rects pin_cx y_cut} {
    set best {}
    set best_dist 1e99
    foreach r $rects {
        lassign $r x0 y0 x1 y1
        set w [expr {$x1 - $x0}]
        set h [expr {$y1 - $y0}]
        if {$h < $w} {
            continue
        }
        if {$y0 < $y_cut} {
            continue
        }
        set dist [expr {abs(($x0+$x1)/2.0 - $pin_cx)}]
        if {$dist < $best_dist} {
            set best_dist $dist
            set best $r
        }
    }
    return $best
}

# Clip [x0,x1] so the feeder keeps >= spacing from opposite-net M4 outside
# the macro on the side being attached.
proc tt_clip_feeder_x {pin_x0 pin_x1 opp_rects side macro_y0 macro_y1 spacing} {
    set x0 $pin_x0
    set x1 $pin_x1
    foreach r $opp_rects {
        lassign $r ox0 oy0 ox1 oy1
        if {$side eq "south"} {
            if {$oy1 > $macro_y0} {
                continue
            }
        } else {
            if {$oy0 < $macro_y1} {
                continue
            }
        }
        # Opposite metal to the west of the pin: push feeder left edge right.
        if {$ox1 <= $pin_x1 && $ox1 > $pin_x0} {
            set x0 [expr {max($x0, $ox1 + $spacing)}]
        }
        # Opposite metal to the east of the pin: push feeder right edge left.
        if {$ox0 >= $pin_x0 && $ox0 < $pin_x1} {
            set x1 [expr {min($x1, $ox0 - $spacing)}]
        }
        # Fully covering / overlapping opposite strip in X: keep clear of it.
        if {$ox0 < $pin_x1 && $ox1 > $pin_x0} {
            if {$ox1 <= ($pin_x0+$pin_x1)/2.0} {
                set x0 [expr {max($x0, $ox1 + $spacing)}]
            } elseif {$ox0 >= ($pin_x0+$pin_x1)/2.0} {
                set x1 [expr {min($x1, $ox0 - $spacing)}]
            } else {
                # Opposite overlaps pin center: prefer clearing the nearer edge.
                set clear_r [expr {$ox1 + $spacing}]
                set clear_l [expr {$ox0 - $spacing}]
                if {[expr {$pin_x1 - $clear_r}] >= [expr {$clear_l - $pin_x0}]} {
                    set x0 [expr {max($x0, $clear_r)}]
                } else {
                    set x1 [expr {min($x1, $clear_l)}]
                }
            }
        }
    }
    if {$x1 - $x0 < [expr {int(0.5 * [tt_dbu_per_um])}]} {
        error "feeder X collapsed after opposite-net keepout \
            (pin $pin_x0..$pin_x1 -> $x0..$x1)"
    }
    return [list $x0 $x1]
}

proc tt_add_box {swire layer x0 y0 x1 y1} {
    if {$x1 <= $x0 || $y1 <= $y0} {
        return
    }
    odb::dbSBox_create $swire $layer $x0 $y0 $x1 $y1 STRIPE
}

# Attach one SRAM power pin: vertical feeder(s) at the reachable boundary
# plus a short outside-macro jog to the nearest same-net stripe stub.
proc tt_attach_sram_pin {block metal4 swire pin_box sides same_rects opp_rects spacing} {
    lassign $pin_box px0 py0 px1 py1
    set pin_cx [expr {($px0 + $px1) / 2.0}]
    set inst [tt_find_sram_inst $block]
    lassign [tt_inst_bbox $inst] mx0 my0 mx1 my1

    foreach side $sides {
        if {$side eq "south"} {
            # Pin must reach the south macro edge.
            if {[expr {abs($py0 - $my0)}] > [tt_dbu_per_um]} {
                puts "PDN: skip south attach — pin does not reach south edge"
                continue
            }
            set stub [tt_nearest_south_stub $same_rects $pin_cx $my0]
            if {$stub eq {}} {
                error "no south Metal4 stub near pin cx=$pin_cx on target net"
            }
            lassign $stub sx0 sy0 sx1 sy1
            lassign [tt_clip_feeder_x $px0 $px1 $opp_rects south $my0 $my1 $spacing] fx0 fx1
            # Feeder: from stub tip up to macro south edge, pin-aligned X.
            set fy0 $sy1
            set fy1 $my0
            if {$fy1 < $fy0} {
                # Stub already past the edge; sit a short apron below the edge.
                set fy0 [expr {$my0 - int(1.5 * [tt_dbu_per_um])}]
                set fy1 $my0
            }
            tt_add_box $swire $metal4 $fx0 $fy0 $fx1 $fy1
            # Jog only if feeder does not already share X with the stub.
            if {[tt_x_overlap [list $fx0 $fy0 $fx1 $fy1] $stub] < 1} {
                set jy0 [expr {max($sy1 - int(0.5 * [tt_dbu_per_um]), $fy0)}]
                set jy1 $sy1
                if {$jy1 <= $jy0} {
                    set jy0 $fy0
                    set jy1 [expr {min($fy1, $sy1)}]
                }
                set jx0 [expr {min($fx0, $sx0)}]
                set jx1 [expr {max($fx1, $sx1)}]
                # Keep jog outside / on the south edge.
                if {$jy1 > $my0} {
                    set jy1 $my0
                }
                tt_add_box $swire $metal4 $jx0 $jy0 $jx1 $jy1
            } elseif {[expr {abs((($fx0+$fx1)/2.0) - (($sx0+$sx1)/2.0))}] > 1} {
                # Partial X overlap: still bridge the gap with a short jog.
                set jy0 [expr {min($fy0, $sy1 - 1)}]
                set jy1 [expr {min($fy1, $sy1)}]
                if {$jy1 > $jy0} {
                    set jx0 [expr {min($fx0, $sx0)}]
                    set jx1 [expr {max($fx1, $sx1)}]
                    tt_add_box $swire $metal4 $jx0 $jy0 $jx1 $jy1
                }
            }
        } elseif {$side eq "north"} {
            if {[expr {abs($py1 - $my1)}] > [tt_dbu_per_um]} {
                puts "PDN: skip north attach — pin does not reach north edge"
                continue
            }
            set stub [tt_nearest_north_stub $same_rects $pin_cx $my1]
            if {$stub eq {}} {
                error "no north Metal4 stub near pin cx=$pin_cx on target net"
            }
            lassign $stub sx0 sy0 sx1 sy1
            lassign [tt_clip_feeder_x $px0 $px1 $opp_rects north $my0 $my1 $spacing] fx0 fx1
            set fy0 $my1
            set fy1 $sy0
            if {$fy1 < $fy0} {
                set fy0 $my1
                set fy1 [expr {$my1 + int(1.5 * [tt_dbu_per_um])}]
            }
            tt_add_box $swire $metal4 $fx0 $fy0 $fx1 $fy1
            if {[tt_x_overlap [list $fx0 $fy0 $fx1 $fy1] $stub] < 1} {
                set jy0 $sy0
                set jy1 [expr {min($sy0 + int(0.5 * [tt_dbu_per_um]), $fy1)}]
                if {$jy1 <= $jy0} {
                    set jy0 $fy0
                    set jy1 $fy1
                }
                if {$jy0 < $my1} {
                    set jy0 $my1
                }
                set jx0 [expr {min($fx0, $sx0)}]
                set jx1 [expr {max($fx1, $sx1)}]
                tt_add_box $swire $metal4 $jx0 $jy0 $jx1 $jy1
            } elseif {[expr {abs((($fx0+$fx1)/2.0) - (($sx0+$sx1)/2.0))}] > 1} {
                set jy0 [expr {max($fy0, $sy0)}]
                set jy1 [expr {max($fy1, $sy0 + 1)}]
                if {$jy1 > $jy0} {
                    set jx0 [expr {min($fx0, $sx0)}]
                    set jx1 [expr {max($fx1, $sx1)}]
                    tt_add_box $swire $metal4 $jx0 $jy0 $jx1 $jy1
                }
            }
        }
    }
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

# Pick a full-height Metal4 stripe east of the SRAM as the exported TT pin.
proc tt_export_pin_from_stripe {block metal4 net_name sig_type west_limit} {
    set rects [tt_net_m4_rects $block $net_name $metal4]
    set best {}
    set best_h 0
    foreach r $rects {
        lassign $r x0 y0 x1 y1
        if {$x0 < $west_limit} {
            continue
        }
        set h [expr {$y1 - $y0}]
        set w [expr {$x1 - $x0}]
        if {$h > $w && $h > $best_h} {
            set best_h $h
            set best $r
        }
    }
    if {$best eq {}} {
        error "no full-height $net_name Metal4 stripe east of $west_limit"
    }
    lassign $best x0 y0 x1 y1
    replace_power_pin $block $metal4 $net_name $sig_type $x0 $y0 $x1 $y1
}


# Wrap pdngen so we can:
#   1. derive SRAM-aligned Metal4 feeders from pin + stripe geometry
#   2. clean up exported VPWR/VGND pins from real stripes
rename pdngen pdngen_without_sram_bridges

proc pdngen {args} {
    pdngen_without_sram_bridges {*}$args

    set block [ord::get_db_block]
    set metal4 [[ord::get_db_tech] findLayer Metal4]
    set spacing [tt_m4_spacing $metal4]

    set sram [tt_find_sram_inst $block]
    if {$sram == "NULL"} {
        puts "PDN: no SRAM instance — skipping feeder attach"
        return
    }
    lassign [tt_inst_bbox $sram] mx0 my0 mx1 my1

    set vpwr_rects [tt_net_m4_rects $block VPWR $metal4]
    set vgnd_rects [tt_net_m4_rects $block VGND $metal4]

    set vss_pin  [tt_pin_bbox_on_layer $sram "VSS!" $metal4]
    set vdd_pin  [tt_pin_bbox_on_layer $sram "VDD!" $metal4]
    set vdda_pin [tt_pin_bbox_on_layer $sram "VDDARRAY!" $metal4]

    set vpwr_swire [odb::dbSWire_create [$block findNet VPWR] ROUTED]
    set vgnd_swire [odb::dbSWire_create [$block findNet VGND] ROUTED]

    # VDD!: both boundaries. Same-net VPWR stripe is already near-aligned;
    # opposite-net keepout is VGND.
    tt_attach_sram_pin $block $metal4 $vpwr_swire $vdd_pin \
        {south north} $vpwr_rects $vgnd_rects $spacing

    # VDDARRAY!: north only (pin does not reach the south edge).
    tt_attach_sram_pin $block $metal4 $vpwr_swire $vdda_pin \
        {north} $vpwr_rects $vgnd_rects $spacing

    # VSS!: both boundaries; clip against nearby VPWR stubs.
    tt_attach_sram_pin $block $metal4 $vgnd_swire $vss_pin \
        {south north} $vgnd_rects $vpwr_rects $spacing

    # Export Tiny Tapeout pins on uninterrupted stripes east of the SRAM.
    tt_export_pin_from_stripe $block $metal4 VPWR POWER $mx1
    tt_export_pin_from_stripe $block $metal4 VGND GROUND $mx1
}

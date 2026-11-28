# Mesh chip timing constraints: LibreLane's base constraints as written for
# this design (final/sdc of run 45938462096), plus the configuration store.
#
# The store's latches (mesh_cfg LATCH=1) open on `strobe` AND a byte decode.
# `strobe` is a flop clocked by clk, so it is declared a generated clock at
# that flop's output: OpenSTA then times every latch's data (d_q, from clk)
# against its enable, instead of leaving 4,156 latch pins unclocked (run
# 45938462096). Paths from the latches into the mesh are static while the
# mesh runs (the host writes the store only while the mesh is held, and the
# hold is released clocks later), so they are false paths.
# Timing Constraints
create_clock -name clk -period 20.0000 [get_ports {clk}]
set_clock_transition 0.1500 [get_clocks {clk}]
set_clock_uncertainty 0.2500 clk
set_propagated_clock [get_clocks {clk}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ena}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {rst_n}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[0]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[1]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[2]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[3]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[4]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[5]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[6]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {ui_in[7]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[0]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[1]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[2]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[3]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[4]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[5]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[6]}]
set_input_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_in[7]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[0]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[1]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[2]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[3]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[4]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[5]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[6]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_oe[7]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[0]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[1]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[2]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[3]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[4]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[5]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[6]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uio_out[7]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[0]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[1]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[2]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[3]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[4]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[5]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[6]}]
set_output_delay 4.0000 -clock [get_clocks {clk}] -add_delay [get_ports {uo_out[7]}]
# Environment
set_load -pin_load 0.0060 [get_ports {uio_oe[7]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[6]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[5]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[4]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[3]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[2]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[1]}]
set_load -pin_load 0.0060 [get_ports {uio_oe[0]}]
set_load -pin_load 0.0060 [get_ports {uio_out[7]}]
set_load -pin_load 0.0060 [get_ports {uio_out[6]}]
set_load -pin_load 0.0060 [get_ports {uio_out[5]}]
set_load -pin_load 0.0060 [get_ports {uio_out[4]}]
set_load -pin_load 0.0060 [get_ports {uio_out[3]}]
set_load -pin_load 0.0060 [get_ports {uio_out[2]}]
set_load -pin_load 0.0060 [get_ports {uio_out[1]}]
set_load -pin_load 0.0060 [get_ports {uio_out[0]}]
set_load -pin_load 0.0060 [get_ports {uo_out[7]}]
set_load -pin_load 0.0060 [get_ports {uo_out[6]}]
set_load -pin_load 0.0060 [get_ports {uo_out[5]}]
set_load -pin_load 0.0060 [get_ports {uo_out[4]}]
set_load -pin_load 0.0060 [get_ports {uo_out[3]}]
set_load -pin_load 0.0060 [get_ports {uo_out[2]}]
set_load -pin_load 0.0060 [get_ports {uo_out[1]}]
set_load -pin_load 0.0060 [get_ports {uo_out[0]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {clk}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ena}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {rst_n}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[7]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[6]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[5]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[4]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[3]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[2]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[1]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {ui_in[0]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[7]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[6]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[5]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[4]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[3]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[2]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[1]}]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin {X} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {uio_in[0]}]
set_timing_derate -early 0.9500
set_timing_derate -late 1.0500
# Design Rules
set_max_fanout 10.0000 [current_design]
# The control actors' timing cuts (src/mesh.v actor_cut): an actor's output
# is a combinational selection of its inputs, so without a cut static
# timing chains paths through several actors and long track runs that no
# configuration forms (0c5527c: post-CTS setup repair began at -49.7 ns WNS
# on 654 endpoints and ran over 80 min) and breaks the structural loops at
# arbitrary points. Paths through an actor's selection are not timed.
set_disable_timing -from A -to X [get_cells -hierarchical *actor_cut_buf]
# `strobe` is high for exactly one clk period per write (edges 1 3 5: rise
# on a clk edge, fall on the next), not a 50% clock: run 45962489266 timed
# it as one and reported a -10.9 ns gating hold at its assumed fall.
create_generated_clock -name cfg_strobe -source [get_ports {clk}] -edges {1 3 5} \
    [get_pins -of_objects [get_nets {store.strobe}] -filter "direction == output"]
set_propagated_clock [get_clocks {cfg_strobe}]
set_false_path -from [get_clocks {cfg_strobe}] -to [get_clocks {clk}]
# The latches close on cfg_strobe's fall, the clk edge after it rose, so
# OpenSTA checks their data (d_q) for hold at that same clk edge, against a
# closing edge late by the strobe flop, the byte decode and the enable tree:
# -4.6 ns on ~9,600 latch pins (runs 46027348989, 46028259749), which hold
# repair cannot buffer away (it spent over an hour and 1,445 buffers trying).
# By construction d_q and a_q load only when !busy, and busy spans staged,
# strobe and settle: d_q is stable for at least one more clk period after
# the latch closes, so the hold check belongs one clk edge earlier.
# Setup: d_q is registered at clock 0, strobe rises at clock 1 and the
# latches close at clock 2. cfg_strobe is aligned with the strobe flop's
# own clk edge (clock 1), so by default OpenSTA assumes d_q launched at
# clock 1, one period late: post-route setup repair then worked on ~4,230
# latch D pins at +0.79 ns real slack (run 46054082523). Setup multicycle 2
# is the real launch.
set_multicycle_path -setup 2 -from [get_clocks {clk}] -to [get_clocks {cfg_strobe}]
# Hold: no clk-launched signal into the store's latches or enable gates
# can change near a strobe edge, by construction (src/mesh_cfg.v):
#   - a_q (the enable decode, gating checks) and d_q (latch D) load only
#     when !busy, and busy = staged | strobe | settle, so after a write
#     staged at clock 0 (strobe falls, latches close, at clock 2) they
#     change at clock 4 at the earliest;
#   - clr_q (latch RESET_B, removal) is a control write, a different host
#     command from a configuration write (mesh_host issues one per `go`),
#     so its release never shares the clk edge a strobe falls on.
# The hold multicycle above this one (b06ffd1 and before) paired each of
# them with the closing edge itself: signoff reported 4,169 hold
# violations, -23 ns on the enable gates (the gating check off by a
# strobe period), -2.8 ns on latch D, -1.8 ns on RESET_B, every one a
# clk -> cfg_strobe path from a_q, d_q or clr_q (run of job 140980597047;
# placement, routing, setup, DRC and LVS passed).
set_false_path -hold -from [get_clocks {clk}] -to [get_clocks {cfg_strobe}]

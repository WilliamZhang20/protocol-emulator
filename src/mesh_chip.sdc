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
set_multicycle_path -hold 1 -from [get_clocks {clk}] -to [get_clocks {cfg_strobe}]

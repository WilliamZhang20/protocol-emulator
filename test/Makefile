# Cocotb RTL and gate-level regression

# Tiny Tapeout's gate-level action installs Icarus. The repository-level
# Makefile still selects Verilator explicitly for the local regression.
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(CURDIR)/../src
COCOTB_CONFIG := $(if $(wildcard $(CURDIR)/../.venv/bin/cocotb-config),$(CURDIR)/../.venv/bin/cocotb-config,cocotb-config)
export PYTHONPATH := $(CURDIR):$(PYTHONPATH)

ifeq ($(SIM),verilator)
COMPILE_ARGS += --timing --assert -DGRID_STREAM_ASSERT -Wno-fatal
endif
PROJECT_SOURCES = project.v fabric_v2_tiles.v fabric_v2.v fabric_v2_unified.v grid_switch.v grid_core.v grid_sequencer.v grid_memory.v grid_unified.v grid_stream_tiles.v grid_stream_memory.v grid_stream_fabric.v fabric_crc.v fabric_shifter.v config_bank.v spi_tiles.v memory_tiles.v memory_shift.v memory_spi_fabric.v program_memory.v

ifneq ($(GATES),yes)
SIM_BUILD = sim_build/rtl
COMPILE_ARGS += -DFUNCTIONAL
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
SIM_BUILD = sim_build/gl
# Lets long real-time cases skip themselves under gate-level simulation.
export GATES
COMPILE_ARGS += -DGL_TEST -DFUNCTIONAL -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif

VERILOG_SOURCES += models/RM_IHPSG13_1P_core_behavioral_bm_bist.v models/RM_IHPSG13_1P_1024x8_c2_bm_bist.v
COMPILE_ARGS += -I$(SRC_DIR)
VERILOG_SOURCES += $(CURDIR)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = cocotb_tests.test_memory_placement,cocotb_tests.test_temporal_i2c,cocotb_tests.test_jtag_tap,cocotb_tests.test_coded_stream,cocotb_tests.test_ethernet_session

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim

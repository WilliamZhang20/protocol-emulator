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
COMPILE_ARGS += --timing -Wno-fatal
endif
PROJECT_SOURCES = project.v protocol_emulator_core.v px8_controller.v fabric_timer.v fabric_shifter.v fabric_counter.v fabric_crc.v fabric_lut.v program_memory.v byte_fifo.v host_interface.v

ifneq ($(GATES),yes)
SIM_BUILD = sim_build/rtl
COMPILE_ARGS += -DFUNCTIONAL
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
SIM_BUILD = sim_build/gl
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
COCOTB_TEST_MODULES = cocotb_tests.test_top,cocotb_tests.test_uart,cocotb_tests.test_spi,cocotb_tests.test_i2c,cocotb_tests.test_ps2,cocotb_tests.test_usb,cocotb_tests.test_ethernet

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim

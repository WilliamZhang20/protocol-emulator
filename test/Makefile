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
PROJECT_SOURCES = project.v protocol_emulator_core.v instruction_decoder.v program_memory.v register_file.v timer_counter.v action_engine.v event_engine.v vm_sequencer.v gpio_arbiter.v gpio_datapath.v crc_engine.v byte_fifo.v host_interface.v

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
COCOTB_TEST_MODULES = cocotb_tests.test_top,cocotb_tests.test_uart,cocotb_tests.test_clocked_regions,cocotb_tests.test_orchestrate,cocotb_tests.test_fuzz,cocotb_tests.test_usb_ls,cocotb_tests.test_alu_branch,cocotb_tests.test_time_event,cocotb_tests.test_sideset,cocotb_tests.test_crc,cocotb_tests.test_jtag,cocotb_tests.test_onewire,cocotb_tests.test_manchester,cocotb_tests.test_host_stream,cocotb_tests.test_action

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim

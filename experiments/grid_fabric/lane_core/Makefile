# Standalone lane core test (step 2.4a): grid_lane_core with Python models of
# the program memory and the stream reader/writer; pads driven directly.
SIM ?= verilator
TOPLEVEL_LANG = verilog
TOPLEVEL = grid_lane_core
COCOTB_TEST_MODULES = test_lane_core
ROOT := $(abspath ../../..)
export PYTHONPATH := $(ROOT)/test:$(CURDIR):$(PYTHONPATH)
VERILOG_SOURCES = $(ROOT)/src/grid_lane_core.v $(ROOT)/src/grid_lane_controller.v $(ROOT)/src/lane_prog_store.v $(ROOT)/src/grid_timer.v \
	$(ROOT)/src/fabric_shifter.v $(ROOT)/src/fabric_crc.v $(ROOT)/src/config_bank.v
ifeq ($(SIM),verilator)
COMPILE_ARGS += --timing -Wno-fatal
endif
include $(shell cocotb-config --makefiles)/Makefile.sim

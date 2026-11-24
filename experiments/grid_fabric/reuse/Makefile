SIM ?= verilator
TOPLEVEL_LANG = verilog
TOPLEVEL = coder_reuse_tb
COCOTB_TEST_MODULES = test_coder_reuse
ROOT := $(abspath ../../..)
export PYTHONPATH := $(ROOT)/test:$(CURDIR):$(PYTHONPATH)
VERILOG_SOURCES = $(CURDIR)/coder_reuse_tb.v $(ROOT)/src/config_bank.v $(ROOT)/src/fabric_shifter.v $(ROOT)/src/fabric_crc.v
COMPILE_ARGS += --timing -Wno-fatal
include $(shell cocotb-config --makefiles)/Makefile.sim

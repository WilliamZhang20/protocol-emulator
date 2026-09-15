BUILD_DIR ?= build
VENV_BIN := $(CURDIR)/.venv/bin
EDA_BIN := $(CURDIR)/.tools/oss-cad-suite/bin
export PATH := $(VENV_BIN):$(EDA_BIN):$(PATH)
VERILATOR ?= verilator
unexport VERILATOR_ROOT
SIM ?= verilator

RTL_SOURCES := \
	src/project.v \
	src/protocol_emulator_core.v \
	src/instruction_decoder.v \
	src/program_memory.v \
	src/register_file.v \
	src/timer_counter.v \
	src/serial_shifter.v \
	src/gpio_datapath.v \
	src/byte_fifo.v \
	src/host_interface.v

SRAM_MODELS := \
	test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
	test/models/RM_IHPSG13_1P_1024x8_c2_bm_bist.v

.PHONY: help verify lint sim memory-test formal clean

help:
	@echo "make lint         Lint the complete RTL hierarchy"
	@echo "make sim          Run the cocotb regression"
	@echo "make memory-test  Exercise the foundry SRAM model"
	@echo "make formal       Run every SymbiYosys target"
	@echo "make verify       Run all verification layers"

verify: lint memory-test sim formal

lint:
	$(VERILATOR) --lint-only --timing -Wno-fatal -DFUNCTIONAL \
		--top-module tb test/tb.v $(RTL_SOURCES) $(SRAM_MODELS)

sim:
	$(MAKE) -C test clean
	$(MAKE) -C test SIM=$(SIM)

memory-test:
	mkdir -p $(BUILD_DIR)/verilator/program_memory
	$(VERILATOR) --binary --timing -Wno-fatal -DFUNCTIONAL \
		--top-module program_memory_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/program_memory) \
		test/program_memory_tb.sv src/program_memory.v $(SRAM_MODELS) \
		-MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/program_memory/Vprogram_memory_tb

formal:
	$(MAKE) -C formal BUILD_DIR=$(abspath $(BUILD_DIR)/formal)

clean:
	$(MAKE) -C test clean
	$(MAKE) -C formal BUILD_DIR=$(abspath $(BUILD_DIR)/formal) clean

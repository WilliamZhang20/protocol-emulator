BUILD_DIR ?= build
VENV_BIN := $(CURDIR)/.venv/bin
EDA_BIN := $(CURDIR)/.tools/oss-cad-suite/bin
export PATH := $(VENV_BIN):$(EDA_BIN):$(PATH)
VERILATOR ?= verilator
PYTHON ?= python3
YOSYS ?= yosys
ROUTING_YOSYS ?= $(EDA_BIN)/yosys
unexport VERILATOR_ROOT
SIM ?= verilator

RTL_SOURCES := \
	src/project.v \
	src/spi_tiles.v \
	src/memory_tiles.v \
	src/memory_shift.v \
	src/memory_spi_fabric.v \
	src/program_memory.v

SRAM_MODELS := \
	test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
	test/models/RM_IHPSG13_1P_1024x8_c2_bm_bist.v

SRAM_BLACKBOX := src/RM_IHPSG13_1P_1024x8_c2_bm_bist.v

.PHONY: help verify precommit install-hooks lint dead-check synth-check gds-config-check pdn-def-check pdn-extract-check sim memory-test routing-experiment tile-spi-experiment tile-route-latency-probe tile-shift-pair-experiment tile-circt-image-test tile-control-image-test control-fabric-image-test tile-memory-experiment tile-memory-spi-image-test tile-memory-lint tile-memory-assertion-mutation tile-memory-synth formal clean

help:
	@echo "make synth-check  Check flattened SRAM hierarchy for LibreLane"
	@echo "make gds-config-check  Check SRAM macro and PDN configuration"
	@echo "make pdn-def-check DEF=...  Check SRAM power nets in a final DEF"
	@echo "make pdn-extract-check SPICE=...  Check Magics SRAM power binding"
	@echo "make lint         Lint the complete RTL hierarchy"
	@echo "make dead-check   Fail on unused signals or constant/never-active flops"
	@echo "make one-hop-check Fail if any signal-space line depends combinationally on a line"
	@echo "make sim          Run the cocotb regression"
	@echo "make memory-test  Exercise the foundry SRAM model"
	@echo "make routing-experiment  Compare selector and registered local-route proxies"
	@echo "make tile-spi-experiment  Simulate the experimental connected SPI tiles"
	@echo "make tile-route-latency-probe  Test route pipeline and synchronized input latency"
	@echo "make tile-shift-pair-experiment  Compare separate and combined shift controls"
	@echo "make tile-circt-image-test IMAGE=...  Exercise a compiler-produced image"
	@echo "make tile-control-image-test IMAGE=...  Exercise a compiled protocol control table"
	@echo "make control-fabric-image-test IMAGE=...  Exercise a complete restricted-program image"
	@echo "make tile-memory-experiment  Test distributed memory and a 12-bit transfer"
	@echo "make tile-memory-spi-image-test  Test the routed memory/SPI fabric"
	@echo "make tile-memory-lint        Lint both memory-bank implementations"
	@echo "make tile-memory-assertion-mutation  Check fairness assertion catches a broken arbiter"
	@echo "make tile-memory-synth       Synthesize with two SRAM macro black boxes"
	@echo "make formal       Run every SymbiYosys target"
	@echo "make verify       Run all verification layers"
	@echo "make precommit    Run lint and the functional regression"
	@echo "make install-hooks Install the local pre-commit hook"

precommit: lint sim

install-hooks:
	git config core.hooksPath .githooks

verify: lint synth-check gds-config-check memory-test sim tile-memory-lint tile-memory-experiment tile-memory-spi-image-test tile-memory-assertion-mutation tile-memory-synth

lint:
	$(VERILATOR) --lint-only --timing -DFUNCTIONAL \
		--top-module tb test/tb.v $(RTL_SOURCES) $(SRAM_MODELS)

dead-check:
	$(PYTHON) tools/dead_rtl_check.py $(VERILATOR) $(EDA_BIN)/yosys tt_um_protocol_emulator \
		$(RTL_SOURCES) $(SRAM_BLACKBOX)

one-hop-check:
	$(PYTHON) tools/one_hop_check.py $(EDA_BIN)/yosys $(filter-out src/project.v src/program_memory.v src/byte_fifo.v src/host_interface.v,$(RTL_SOURCES))

synth-check:
	$(YOSYS) -Q -p 'read_verilog $(RTL_SOURCES) $(SRAM_BLACKBOX); hierarchy -check -top tt_um_protocol_emulator; synth -top tt_um_protocol_emulator -flatten; check -assert; select -assert-count 2 t:RM_IHPSG13_1P_1024x8_c2_bm_bist; select -assert-count 1 tt_um_protocol_emulator/fabric.memory.bank0.macro_bank.memory.sram; select -assert-count 1 tt_um_protocol_emulator/fabric.memory.bank1.macro_bank.memory.sram'

gds-config-check:
	$(PYTHON) test/check_gds_config.py

pdn-def-check:
	@test -n "$(DEF)" || (echo "usage: make pdn-def-check DEF=path/to/design.def" >&2; exit 1)
	$(PYTHON) test/check_pdn_def.py $(DEF)

pdn-extract-check:
	@test -n "$(SPICE)" || (echo "usage: make pdn-extract-check SPICE=path/to/design.spice" >&2; exit 1)
	$(PYTHON) test/check_pdn_extract.py $(SPICE)

sim:
	$(MAKE) -C test clean
	$(MAKE) -C test SIM=$(SIM)

routing-experiment:
	mkdir -p $(BUILD_DIR)/verilator/routing_experiment
	$(VERILATOR) --binary --timing --top-module selector_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/routing_experiment) \
		experiments/routing/selector_tb.v experiments/routing/selector_candidates.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/routing_experiment/Vselector_tb
	YOSYS=$(ROUTING_YOSYS) $(PYTHON) experiments/routing/compare.py

tile-route-latency-probe:
	mkdir -p $(BUILD_DIR)/verilator/tile_route_latency
	$(VERILATOR) --binary --timing -Wno-TIMESCALEMOD --top-module route_latency_probe_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_route_latency) \
		experiments/tile_fabric/route_latency_probe_tb.sv src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_route_latency/Vroute_latency_probe_tb

tile-shift-pair-experiment:
	mkdir -p $(BUILD_DIR)/verilator/tile_shift_pair
	$(VERILATOR) --binary --timing -Wno-TIMESCALEMOD --top-module compare_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_shift_pair) \
		experiments/shift_pair/compare_tb.sv experiments/shift_pair/candidates.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_shift_pair/Vcompare_tb
	YOSYS=$(ROUTING_YOSYS) $(PYTHON) experiments/shift_pair/compare.py

tile-spi-experiment:
	mkdir -p $(BUILD_DIR)/verilator/tile_spi_experiment
	$(VERILATOR) --binary --timing --top-module spi_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_spi_experiment) \
		experiments/tile_fabric/spi_tb.v src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_spi_experiment/Vspi_tb
	mkdir -p $(BUILD_DIR)/verilator/tile_spi_equivalence
	$(VERILATOR) --binary --timing --top-module equiv_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_spi_equivalence) \
		experiments/tile_fabric/equiv_tb.v src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_spi_equivalence/Vequiv_tb
	YOSYS=$(ROUTING_YOSYS) $(PYTHON) experiments/tile_fabric/compare.py

tile-circt-image-test:
	@test -n "$(IMAGE)" || (echo 'usage: make tile-circt-image-test IMAGE=path/to/image.mem' >&2; exit 1)
	mkdir -p $(BUILD_DIR)/verilator/tile_circt_image
	$(VERILATOR) --binary --timing --top-module circt_image_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_circt_image) \
		experiments/tile_fabric/circt_image_tb.v src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_circt_image/Vcirct_image_tb +IMAGE=$(abspath $(IMAGE))

tile-control-image-test:
	@test -n "$(IMAGE)" || (echo 'usage: make tile-control-image-test IMAGE=path/to/control.mem' >&2; exit 1)
	mkdir -p $(BUILD_DIR)/verilator/tile_control_image
	$(VERILATOR) --binary --timing --top-module control_image_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_control_image) \
		experiments/tile_fabric/control_image_tb.v src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_control_image/Vcontrol_image_tb +IMAGE=$(abspath $(IMAGE))

control-fabric-image-test:
	@test -n "$(IMAGE)" || (echo 'usage: make control-fabric-image-test IMAGE=path/to/image.mem' >&2; exit 1)
	mkdir -p $(BUILD_DIR)/verilator/control_fabric_image
	$(VERILATOR) --binary --timing --top-module control_fabric_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/control_fabric_image) \
		experiments/tile_fabric/control_fabric_tb.v experiments/tile_fabric/control_fabric.v \
		src/spi_tiles.v -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/control_fabric_image/Vcontrol_fabric_tb +IMAGE=$(abspath $(IMAGE))

memory-test:
	mkdir -p $(BUILD_DIR)/verilator/program_memory
	$(VERILATOR) --binary --timing -Wno-fatal -DFUNCTIONAL \
		--top-module program_memory_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/program_memory) \
		test/program_memory_tb.sv src/program_memory.v $(SRAM_MODELS) \
		-MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/program_memory/Vprogram_memory_tb

tile-memory-lint:
	$(VERILATOR) --lint-only --timing -Wall -Wno-DECLFILENAME -DFUNCTIONAL \
		--top-module memory_shift_fabric -GUSE_MACRO=0 experiments/tile_fabric/sram_lint.vlt \
		src/memory_shift.v src/memory_tiles.v \
		src/spi_tiles.v src/program_memory.v $(SRAM_MODELS)
	$(VERILATOR) --lint-only --timing -Wall -Wno-DECLFILENAME -DFUNCTIONAL \
		--top-module memory_shift_fabric -GUSE_MACRO=1 experiments/tile_fabric/sram_lint.vlt \
		src/memory_shift.v src/memory_tiles.v \
		src/spi_tiles.v src/program_memory.v $(SRAM_MODELS)
	$(VERILATOR) --lint-only --timing -Wall -Wno-DECLFILENAME -DFUNCTIONAL \
		--top-module memory_spi_fabric -GUSE_MACRO=1 experiments/tile_fabric/sram_lint.vlt \
		src/memory_spi_fabric.v src/memory_tiles.v src/spi_tiles.v src/program_memory.v $(SRAM_MODELS)

tile-memory-experiment:
	mkdir -p $(BUILD_DIR)/verilator/tile_memory $(BUILD_DIR)/verilator/tile_memory_shift $(BUILD_DIR)/verilator/tile_memory_random
	$(VERILATOR) --binary --timing -Wno-fatal -DFUNCTIONAL --top-module memory_tiles_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_memory) \
		experiments/tile_fabric/memory_tiles_tb.sv src/memory_tiles.v \
		src/program_memory.v $(SRAM_MODELS) -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_memory/Vmemory_tiles_tb
	$(VERILATOR) --binary --timing -Wno-fatal -DFUNCTIONAL --top-module memory_shift_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_memory_shift) \
		experiments/tile_fabric/memory_shift_tb.sv src/memory_shift.v \
		src/memory_tiles.v src/spi_tiles.v \
		src/program_memory.v $(SRAM_MODELS) -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_memory_shift/Vmemory_shift_tb
	$(VERILATOR) --binary --timing --assert -Wno-fatal -DFUNCTIONAL --top-module memory_random_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/tile_memory_random) \
		experiments/tile_fabric/memory_random_tb.sv experiments/tile_fabric/memory_contract_assertions.sv src/memory_tiles.v \
		src/program_memory.v $(SRAM_MODELS) -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/tile_memory_random/Vmemory_random_tb +SEED=1
	$(BUILD_DIR)/verilator/tile_memory_random/Vmemory_random_tb +SEED=37
	$(BUILD_DIR)/verilator/tile_memory_random/Vmemory_random_tb +SEED=2026

tile-memory-synth:
	$(ROUTING_YOSYS) -Q -T -p 'read_verilog -lib src/RM_IHPSG13_1P_1024x8_c2_bm_bist.v; read_verilog src/program_memory.v src/memory_tiles.v src/memory_shift.v src/spi_tiles.v; hierarchy -top memory_shift_fabric -chparam USE_MACRO 1; flatten; synth -top memory_shift_fabric; stat'

tile-memory-spi-image-test:
	mkdir -p $(BUILD_DIR)/verilator/memory_spi
	$(VERILATOR) --binary --timing -Wno-fatal -DFUNCTIONAL --top-module memory_spi_tb \
		--Mdir $(abspath $(BUILD_DIR)/verilator/memory_spi) \
		experiments/tile_fabric/memory_spi_tb.sv src/memory_spi_fabric.v src/memory_tiles.v \
		src/spi_tiles.v src/program_memory.v $(SRAM_MODELS) -MAKEFLAGS -j1
	$(BUILD_DIR)/verilator/memory_spi/Vmemory_spi_tb +IMAGE=$(abspath $(if $(IMAGE),$(IMAGE),test/data/spi12.mem))

tile-memory-assertion-mutation:
	VERILATOR=$(VERILATOR) experiments/tile_fabric/check_memory_assertions.sh

formal:
	$(MAKE) -C formal BUILD_DIR=$(abspath $(BUILD_DIR)/formal)

clean:
	$(MAKE) -C test clean
	$(MAKE) -C formal BUILD_DIR=$(abspath $(BUILD_DIR)/formal) clean

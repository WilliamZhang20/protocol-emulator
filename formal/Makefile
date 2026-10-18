PROJECT_ROOT := $(abspath ..)
EDA_BIN := $(PROJECT_ROOT)/.tools/oss-cad-suite/bin
export PATH := $(EDA_BIN):$(PROJECT_ROOT)/.venv/bin:$(PATH)
PYTHON ?= $(PROJECT_ROOT)/.venv/bin/python
SBY ?= $(if $(wildcard $(EDA_BIN)/sby),$(EDA_BIN)/sby,sby)
BUILD_DIR ?= $(PROJECT_ROOT)/build/formal
TARGETS := program_memory byte_fifo host_interface fabric_timer fabric_shifter \
	fabric_counter fabric_crc fabric_logic byte_tile px8_controller fabric_core
# Protocol proofs: the whole core running a real protocol program (the
# bytes the cocotb tests load, assembled into protocols/<name>_rom.vh).
PROTOCOLS := uart_tx ws2812 spi_master
uart_tx_PROGRAM := uart_transmit(4)
ws2812_PROGRAM := ws2812_transmit(8, 2, 4)
spi_master_PROGRAM := spi_master(0, 3)
program_memory_TASKS := bmc prove cover
byte_fifo_TASKS := bmc prove cover
host_interface_TASKS := bmc prove cover
fabric_timer_TASKS := bmc cover
fabric_shifter_TASKS := bmc cover
fabric_counter_TASKS := bmc prove cover
fabric_crc_TASKS := bmc prove cover
fabric_logic_TASKS := bmc prove cover
byte_tile_TASKS := roundtrip checksum cover_roundtrip cover_checksum
px8_controller_TASKS := bmc cover
fabric_core_TASKS := bmc cover

.PHONY: all $(TARGETS) $(PROTOCOLS) protocol-negative mutation-check clean list

all: $(TARGETS) $(PROTOCOLS) protocol-negative mutation-check

list:
	@printf '%s\n' $(TARGETS) $(PROTOCOLS)

$(TARGETS):
	mkdir -p $(BUILD_DIR)/$@
	cd $@ && for task in $($@_TASKS); do \
		$(SBY) -f -d $(BUILD_DIR)/$@/$$task $@.sby $$task || exit $$?; \
	done

$(PROTOCOLS):
	mkdir -p $(BUILD_DIR)/protocols/$@
	cd protocols && $(PYTHON) gen_rom.py $@_rom.vh "$($@_PROGRAM)" && \
	for task in bmc cover; do \
		$(SBY) -f -d $(BUILD_DIR)/protocols/$@/$$task $@.sby $$task || exit $$?; \
	done

protocol-negative:
	cd protocols && $(PYTHON) negative_check.py $(SBY) $(PYTHON) $(BUILD_DIR)/protocols

mutation-check:
	python3 mutation_check.py

clean:
	if [ -d "$(BUILD_DIR)" ]; then find "$(BUILD_DIR)" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi

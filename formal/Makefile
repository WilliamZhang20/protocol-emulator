PROJECT_ROOT := $(abspath ..)
EDA_BIN := $(PROJECT_ROOT)/.tools/oss-cad-suite/bin
export PATH := $(EDA_BIN):$(PROJECT_ROOT)/.venv/bin:$(PATH)
PYTHON ?= $(if $(wildcard $(PROJECT_ROOT)/.venv/bin/python),$(PROJECT_ROOT)/.venv/bin/python,python3)
SBY ?= $(if $(wildcard $(EDA_BIN)/sby),$(EDA_BIN)/sby,sby)
YOSYS ?= $(if $(wildcard $(EDA_BIN)/yosys),$(EDA_BIN)/yosys,yosys)
BUILD_DIR ?= $(PROJECT_ROOT)/build/formal
TARGETS := program_memory byte_fifo host_interface fabric_timer fabric_shifter \
	fabric_counter fabric_crc fabric_logic byte_tile px8_controller fabric_core
# Protocol proofs: the whole core running a real protocol program (the
# bytes the cocotb tests load, assembled into protocols/<name>_rom.vh).
PROTOCOLS := uart_tx ws2812 spi_master gpio_expander quadrature_decoder vga \
	hdlc_receive
# Proofs that take hours (HDLC transmit: 300 cycles, about 12 hours):
# run on a Slurm cluster by formal/slurm/deep.sh, not by CI or `all`.
SLOW_PROTOCOLS := hdlc_transmit vga_framebuffer
uart_tx_PROGRAM := uart_transmit(4)
ws2812_PROGRAM := ws2812_transmit(6, 1, 2)
spi_master_PROGRAM := spi_master(0, 2, 2)
gpio_expander_PROGRAM := gpio_expander(4, 1)
quadrature_decoder_PROGRAM := quadrature_decoder()
vga_PROGRAM := vga(3, 8, 1, 1, 1, 1, 1, 1, 1)
vga_framebuffer_PROGRAM := vga_framebuffer(3, 8, 16, 12, 12, [0, 0], 2, 1, 1, 1)
hdlc_receive_PROGRAM := hdlc_receive()
hdlc_transmit_PROGRAM := hdlc_transmit(10)
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

.PHONY: all modules $(TARGETS) $(PROTOCOLS) $(SLOW_PROTOCOLS) protocol-negative \
	protocol-negative-slow mutation-check clean list list-protocols

all: $(TARGETS) $(PROTOCOLS) protocol-negative mutation-check

# The tile proofs and the mutation check (CI runs each protocol proof as its own job).
modules: $(TARGETS) mutation-check

list:
	@printf '%s\n' $(TARGETS) $(PROTOCOLS)

list-protocols:
	@printf '%s\n' $(PROTOCOLS) $(SLOW_PROTOCOLS)

$(TARGETS):
	mkdir -p $(BUILD_DIR)/$@
	cd $@ && for task in $($@_TASKS); do \
		$(SBY) -f -d $(BUILD_DIR)/$@/$$task $@.sby $$task || exit $$?; \
	done

$(PROTOCOLS) $(SLOW_PROTOCOLS):
	mkdir -p $(BUILD_DIR)/protocols/$@
	cd protocols && $(PYTHON) gen_rom.py $@_rom.vh "$($@_PROGRAM)" && \
	$(PYTHON) prearm.py $(YOSYS) $@ && \
	{ $(SBY) -f -d $(BUILD_DIR)/protocols/$@/bmc $@.sby bmc & bmc=$$!; \
	  $(SBY) -f -d $(BUILD_DIR)/protocols/$@/cover $@.sby cover; cover=$$?; \
	  wait $$bmc && exit $$cover; }

protocol-negative:
	cd protocols && $(PYTHON) negative_check.py $(SBY) $(PYTHON) $(YOSYS) $(BUILD_DIR)/protocols $(PROTOCOLS)

protocol-negative-slow:
	cd protocols && $(PYTHON) negative_check.py $(SBY) $(PYTHON) $(YOSYS) $(BUILD_DIR)/protocols $(SLOW_PROTOCOLS)

mutation-check:
	python3 mutation_check.py

clean:
	if [ -d "$(BUILD_DIR)" ]; then find "$(BUILD_DIR)" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi

PROJECT_ROOT := $(abspath ..)
EDA_BIN := $(PROJECT_ROOT)/.tools/oss-cad-suite/bin
export PATH := $(EDA_BIN):$(PROJECT_ROOT)/.venv/bin:$(PATH)
PYTHON ?= $(PROJECT_ROOT)/.venv/bin/python
SBY ?= $(if $(wildcard $(EDA_BIN)/sby),$(EDA_BIN)/sby,sby)
BUILD_DIR ?= $(PROJECT_ROOT)/build/formal
TARGETS := program_memory uart_tx uart_rx byte_fifo event_engine gpio_ownership action_dispatcher action_engine action_stream shared_resources
program_memory_TASKS := bmc prove cover
uart_tx_TASKS := bmc cover
uart_rx_TASKS := bmc cover
byte_fifo_TASKS := bmc prove cover
event_engine_TASKS := bmc prove cover
gpio_ownership_TASKS := bmc prove cover
action_dispatcher_TASKS := bmc prove cover
action_engine_TASKS := bmc prove cover
action_stream_TASKS := bmc cover
shared_resources_TASKS := bmc prove cover

.PHONY: all $(TARGETS) mutation-check clean list

all: $(TARGETS) mutation-check

list:
	@printf '%s\n' $(TARGETS)

$(TARGETS):
	mkdir -p $(BUILD_DIR)/$@
	cd $@ && for task in $($@_TASKS); do \
		$(SBY) -f -d $(BUILD_DIR)/$@/$$task $@.sby $$task || exit $$?; \
	done

mutation-check:
	python3 mutation_check.py

clean:
	if [ -d "$(BUILD_DIR)" ]; then find "$(BUILD_DIR)" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi

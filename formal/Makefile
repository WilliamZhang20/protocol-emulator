PROJECT_ROOT := $(abspath ..)
EDA_BIN := $(PROJECT_ROOT)/.tools/oss-cad-suite/bin
export PATH := $(EDA_BIN):$(PROJECT_ROOT)/.venv/bin:$(PATH)
PYTHON ?= $(PROJECT_ROOT)/.venv/bin/python
SBY ?= $(if $(wildcard $(EDA_BIN)/sby),$(EDA_BIN)/sby,sby)
BUILD_DIR ?= $(PROJECT_ROOT)/build/formal
TARGETS := program_memory uart_tx uart_rx
program_memory_TASKS := bmc prove cover
uart_tx_TASKS := bmc cover
uart_rx_TASKS := bmc cover

.PHONY: all $(TARGETS) clean list

all: $(TARGETS)

list:
	@printf '%s\n' $(TARGETS)

$(TARGETS):
	mkdir -p $(BUILD_DIR)/$@
	cd $@ && for task in $($@_TASKS); do \
		$(SBY) -f -d $(BUILD_DIR)/$@/$$task $@.sby $$task || exit $$?; \
	done

clean:
	if [ -d "$(BUILD_DIR)" ]; then find "$(BUILD_DIR)" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi

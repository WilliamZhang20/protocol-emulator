SBY ?= sby
BUILD_DIR ?= $(abspath ../build/formal)
TARGETS := program_memory

.PHONY: all $(TARGETS) clean list

all: $(TARGETS)

list:
	@printf '%s\n' $(TARGETS)

$(TARGETS):
	mkdir -p $(BUILD_DIR)
	cd $@ && $(SBY) -f -d $(BUILD_DIR)/$@ $@.sby

clean:
	if [ -d "$(BUILD_DIR)" ]; then find "$(BUILD_DIR)" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi

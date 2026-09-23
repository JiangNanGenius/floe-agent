# FloeTinyEMUTests — TinyEMU SMP (dual-hart) host tests.
#
# Builds the RISC-V test payloads (gen_smp_payload.py, no toolchain
# needed), links smp_host_test.c against libfloevm.a (built from the
# pristine pinned TinyEMU + patches/ series through the adapter Makefile)
# and runs the suite. Everything generated lands under $(BUILD) inside
# the git-ignored Local/Scratch tree.
#
# Usage (from this directory):
#   make test              # build + run everything
#   make MACOS= test       # on a Linux host (default MACOS=1 for Darwin)
#
# The pristine TinyEMU tree is fetched by FloeAgent/ThirdParty/TinyEMU/
# fetch_source.sh into Local/Private/tinyemu-vendor/src when missing.

TINYEMU_DIR := ../../ThirdParty/TinyEMU
TINYEMU_SRC ?= $(TINYEMU_DIR)/../../../Local/Private/tinyemu-vendor/src/tinyemu-2019-12-21
BUILD ?= ../../../Local/Scratch/floetinyemu-smp-tests/build
MACOS ?= 1

PAYLOADS := $(BUILD)/smp_test.bin $(BUILD)/perf_dual.bin $(BUILD)/perf_single.bin \
            $(BUILD)/mmio_solo.bin

.PHONY: all test clean payloads lib
all: $(BUILD)/smp_host_test payloads

payloads: $(PAYLOADS)

$(BUILD):
	mkdir -p $(BUILD)

$(PAYLOADS): gen_smp_payload.py | $(BUILD)
	python3 gen_smp_payload.py $(BUILD)

lib: | $(BUILD)
	cd $(TINYEMU_DIR) && $(MAKE) -f adapter/Makefile \
	    TINYEMU_SRC=../../../Local/Private/tinyemu-vendor/src/tinyemu-2019-12-21 \
	    BUILD=../../../Local/Scratch/floetinyemu-smp-tests/build MACOS=$(MACOS)

# The library must be rebuilt when the patch series, the adapter, or the
# adapter Makefile changes. Without these prerequisites the archive is
# only built once and `make test` silently links a stale engine (the
# vendored engine is not a prerequisite either: the qualification build
# compiles the pristine tarball + patches, never Sources/FloeTinyEMU).
ENGINE_INPUTS := $(TINYEMU_DIR)/adapter/Makefile \
                 $(TINYEMU_DIR)/adapter/floe_vm.c \
                 $(TINYEMU_DIR)/adapter/floe_vm.h \
                 $(wildcard $(TINYEMU_DIR)/patches/*.patch)

$(BUILD)/libfloevm.a: $(ENGINE_INPUTS) | $(BUILD)
	$(MAKE) lib

$(BUILD)/smp_host_test: smp_host_test.c $(BUILD)/libfloevm.a
	cc -O2 -Wall -I$(TINYEMU_DIR)/adapter -o $@ smp_host_test.c \
	    $(BUILD)/libfloevm.a -lpthread -lm

$(BUILD)/stop_test_disk.img: | $(BUILD)
	dd if=/dev/zero of=$@ bs=1m count=8 2>/dev/null

test: all $(BUILD)/stop_test_disk.img
	cd $(BUILD) && ./smp_host_test

clean:
	rm -rf $(BUILD)

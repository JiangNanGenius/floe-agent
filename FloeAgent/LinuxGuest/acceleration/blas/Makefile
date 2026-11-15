# SPDX-License-Identifier: Apache-2.0
#
# Cross-build the Floe guest BLAS interposer and its probe.
#
# The generated SPIR-V headers are real build inputs.  They are produced by
# build/build_spirv.py from the GLSL sources; this Makefile intentionally
# fails with a clear message when they have not been produced.  It never
# substitutes an empty shader.
#
# GNU cross compiler example:
#   make CC=aarch64-linux-gnu-gcc TARGET_FLAGS=--sysroot=/path/to/sysroot
#
# Apple clang + lld example (same toolchain family as gpu-mesa/BUILD-RECIPE):
#   make CC=/Applications/Xcode.app/Contents/Developer/Toolchains/\
#   XcodeDefault.xctoolchain/usr/bin/clang \
#   TARGET_FLAGS="--target=aarch64-unknown-linux-gnu \
#     --sysroot=/path/to/debian-trixie-arm64 -fuse-ld=lld"

CC ?= aarch64-linux-gnu-gcc
TARGET_FLAGS ?=
CFLAGS ?= -O2 -g0 -fPIC -fvisibility=hidden -std=c11 -Wall -Wextra -Werror \
          -D_GNU_SOURCE -DVK_NO_PROTOTYPES=1
CPPFLAGS += -Iinclude -Igenerated -Isrc
LDLIBS += -ldl -lpthread -lm

BUILD := build
LIB := $(BUILD)/libfloe_blas.so
PROBE := $(BUILD)/floe-blas-probe
TESTS := $(BUILD)/floe-blas-tests

CORE_SOURCES := src/floe_blas.c src/floe_blas_policy.c \
                src/floe_blas_activate.c
VK_SOURCES := src/floe_blas_vk.c
SPV_HEADERS := generated/floe_blas_matmul_spv.h \
               generated/floe_blas_gemv_spv.h
HEADERS := include/floe_blas.h include/floe_blas_cblas.h \
           src/floe_blas_internal.h src/floe_blas_policy.h \
           src/floe_blas_activate.h

.PHONY: all clean check check-spirv install

all: $(LIB) $(PROBE)

$(SPV_HEADERS): $(wildcard shaders/*.comp) build/build_spirv.py
	@echo "error: generated SPIR-V asset is missing: $@" >&2
	@echo "       run: python3 build/build_spirv.py" >&2
	@echo "       (requires a trusted glslangValidator or glslc)" >&2
	@exit 2

$(LIB): $(CORE_SOURCES) $(VK_SOURCES) $(HEADERS) $(SPV_HEADERS)
	@mkdir -p $(BUILD)
	$(CC) $(TARGET_FLAGS) $(CFLAGS) $(CPPFLAGS) -shared \
	    -Wl,-soname,libfloe_blas.so -Wl,-z,defs -Wl,-z,relro -Wl,-z,now \
	    -o $@ $(CORE_SOURCES) $(VK_SOURCES) $(LDLIBS)

$(PROBE): tools/floe_blas_probe.c $(LIB) include/floe_blas.h \
          include/floe_blas_cblas.h src/floe_blas_activate.h
	@mkdir -p $(BUILD)
	$(CC) $(TARGET_FLAGS) $(CFLAGS) $(CPPFLAGS) -o $@ \
	    tools/floe_blas_probe.c -L$(BUILD) -lfloe_blas \
	    -Wl,-rpath,'$$ORIGIN' -Wl,-rpath,/usr/local/lib/floe-acceleration \
	    $(LDLIBS)

$(TESTS): tests/test_provider_abi.c $(LIB)
	@mkdir -p $(BUILD)
	$(CC) $(TARGET_FLAGS) $(CFLAGS) $(CPPFLAGS) -o $@ \
	    tests/test_provider_abi.c -L$(BUILD) -lfloe_blas \
	    -Wl,-rpath,'$$ORIGIN' -Wl,-rpath,/usr/local/lib/floe-acceleration \
	    $(LDLIBS)

tests: $(TESTS)

check:
	python3 tests/run_source_checks.py
	python3 tests/hostile_path_fixture.py
	python3 build/build_spirv.py --source-check

check-spirv:
	python3 build/build_spirv.py --check

install:
	@echo "Use scripts/install-floe-blas.sh --root <guest-root> --build $(BUILD)" >&2
	@exit 2

clean:
	rm -rf $(BUILD)

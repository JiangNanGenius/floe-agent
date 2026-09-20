# Floe embeddable TinyEMU qualification build.
#
# Builds libfloevm.a from the pristine, pinned TinyEMU 2019-12-21 sources
# plus one documented patch (patches/0001-htif-poweroff-callback.patch) and
# the Floe MPL adapter (adapter/floe_vm.c). Optionally builds the
# qualification host (floe_vm_host) when HOST_DIR is set.
#
# Trimmed configuration: RV64 only, virtio console/block/9p + slirp user
# networking. Excluded on purpose: SDL, x86 emulator, RV128, the
# curl/OpenSSL HTTP filesystem (CONFIG_FS_NET), aes.c/sha256.c (only used
# by the HTTP filesystem). No KVM exists on this path upstream (x86 only).
#
# Paths are relative (workspace may contain spaces). Typical use:
#   make -f adapter/Makefile TINYEMU_SRC=../../src/tinyemu-2019-12-21 \
#        BUILD=./out MACOS=1
# (see Qualification/TinyEMULinux/run_local_smoke.sh for a full driver)

TINYEMU_SRC ?= tinyemu-2019-12-21
# PATCH_DIR default assumes make runs from FloeAgent/ThirdParty/TinyEMU;
# callers invoking from elsewhere pass it explicitly (make's wildcard
# cannot resolve ".." inside patterns, and paths must stay relative
# because the workspace may contain spaces).
PATCH_DIR ?= patches
PATCHES := $(sort $(wildcard $(PATCH_DIR)/*.patch))
# PATCHES apply in sorted order; 0002 must follow 0001 because both touch
# riscv_machine.c, and 0005 only touches riscv_cpu_template.h.
ADAPTER ?= $(dir $(lastword $(MAKEFILE_LIST)))
HOST_DIR ?=
BUILD ?= out

CC ?= cc
CFLAGS := -O2 -Wall -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
          -D_GNU_SOURCE -DCONFIG_VERSION=\"2019-12-21\" \
          -DCONFIG_SLIRP -DCONFIG_RISCV_MAX_XLEN=64 \
          -I$(TINYEMU_SRC)
LIBS := -lm -lpthread

ifeq ($(MACOS),1)
CFLAGS += -I$(ADAPTER)macos -include $(ADAPTER)macos/force.h
else
LIBS += -lrt
endif

SLIRP_OBJS := bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc \
              socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer
# pristine-compiled core objects
CORE_OBJS := virtio pci fs cutils simplefb json machine fs_disk softfp
# sources replaced by patched build copies (see PATCHES). riscv_cpu.c is
# copied too so its quoted include of riscv_cpu_template.h resolves to the
# patched copy in $(BUILD) (the pristine tree keeps the unpatched header).
PATCHED_SRCS := riscv_machine.c iomem.c riscv_cpu.c riscv_cpu_template.h

OBJS := $(addprefix $(BUILD)/,$(addsuffix .o,$(CORE_OBJS))) \
        $(addprefix $(BUILD)/slirp/,$(addsuffix .o,$(SLIRP_OBJS))) \
        $(BUILD)/riscv_cpu32.o $(BUILD)/riscv_cpu64.o \
        $(BUILD)/riscv_machine.o $(BUILD)/iomem.o

TARGETS := $(BUILD)/libfloevm.a
ifneq ($(HOST_DIR),)
TARGETS += $(BUILD)/floe_vm_host $(BUILD)/lifecycle_test
endif

all: $(TARGETS)

$(BUILD)/.dir:
	mkdir -p $(BUILD)/slirp
	touch $@

# Patched sources: copy into $(BUILD), apply every patch in order, verify
# the expected markers landed.
$(BUILD)/.prepared: $(PATCHES) | $(BUILD)/.dir
	for f in $(PATCHED_SRCS); do cp $(TINYEMU_SRC)/$$f $(BUILD)/$$f; done
	for p in $(PATCHES); do patch -p1 -N -d $(BUILD) < $$p; done
	grep -q "poweroff_requested" $(BUILD)/riscv_machine.c
	grep -q "floe_ram_oom" $(BUILD)/iomem.c
	grep -q "static int copy_bios" $(BUILD)/riscv_machine.c
	grep -q "FLOE-EMBED: accept FENCE, FENCE.TSO" $(BUILD)/riscv_cpu_template.h
	touch $@

$(BUILD)/riscv_machine.o: $(BUILD)/.prepared
	$(CC) $(CFLAGS) -c -o $@ $(BUILD)/riscv_machine.c

$(BUILD)/iomem.o: $(BUILD)/.prepared
	$(CC) $(CFLAGS) -c -o $@ $(BUILD)/iomem.c

$(BUILD)/%.o: $(TINYEMU_SRC)/%.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/slirp/%.o: $(TINYEMU_SRC)/slirp/%.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/riscv_cpu64.o: $(BUILD)/.prepared
	$(CC) $(CFLAGS) -DMAX_XLEN=64 -c -o $@ $(BUILD)/riscv_cpu.c

$(BUILD)/riscv_cpu32.o: $(BUILD)/.prepared
	$(CC) $(CFLAGS) -DMAX_XLEN=32 -c -o $@ $(BUILD)/riscv_cpu.c

$(BUILD)/floe_vm.o: $(ADAPTER)floe_vm.c $(ADAPTER)floe_vm.h | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/libfloevm.a: $(OBJS) $(BUILD)/floe_vm.o
	ar rcs $@ $^

$(BUILD)/floe_vm_host.o: $(HOST_DIR)/floe_vm_host.c $(ADAPTER)floe_vm.h | $(BUILD)/.dir
	$(CC) $(CFLAGS) -I$(ADAPTER) -c -o $@ $<

$(BUILD)/floe_vm_host: $(BUILD)/floe_vm_host.o $(BUILD)/libfloevm.a
	$(CC) -o $@ $^ $(LIBS)

$(BUILD)/lifecycle_test.o: $(HOST_DIR)/lifecycle_test.c $(ADAPTER)floe_vm.h | $(BUILD)/.dir
	$(CC) $(CFLAGS) -I$(ADAPTER) -c -o $@ $<

$(BUILD)/lifecycle_test: $(BUILD)/lifecycle_test.o $(BUILD)/libfloevm.a
	$(CC) -o $@ $^ $(LIBS)

clean:
	rm -rf $(BUILD)

.PHONY: all clean

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
PATCH ?= $(dir $(lastword $(MAKEFILE_LIST)))../patches/0001-htif-poweroff-callback.patch
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
CORE_OBJS := virtio pci fs cutils iomem simplefb json machine fs_disk softfp

OBJS := $(addprefix $(BUILD)/,$(addsuffix .o,$(CORE_OBJS))) \
        $(addprefix $(BUILD)/slirp/,$(addsuffix .o,$(SLIRP_OBJS))) \
        $(BUILD)/riscv_cpu32.o $(BUILD)/riscv_cpu64.o \
        $(BUILD)/riscv_machine.o

TARGETS := $(BUILD)/libfloevm.a
ifneq ($(HOST_DIR),)
TARGETS += $(BUILD)/floe_vm_host
endif

all: $(TARGETS)

$(BUILD)/.dir:
	mkdir -p $(BUILD)/slirp
	touch $@

# pristine sources compile directly (no copying); only riscv_machine.c is
# patched, into $(BUILD), verified after patching.
$(BUILD)/riscv_machine.c: $(TINYEMU_SRC)/riscv_machine.c $(PATCH) | $(BUILD)/.dir
	cp $< $@
	patch -p1 -N -d $(BUILD) < $(PATCH)
	grep -q "poweroff_requested" $@

$(BUILD)/riscv_machine.o: $(BUILD)/riscv_machine.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%.o: $(TINYEMU_SRC)/%.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/slirp/%.o: $(TINYEMU_SRC)/slirp/%.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/riscv_cpu64.o: $(TINYEMU_SRC)/riscv_cpu.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -DMAX_XLEN=64 -c -o $@ $<

$(BUILD)/riscv_cpu32.o: $(TINYEMU_SRC)/riscv_cpu.c | $(BUILD)/.dir
	$(CC) $(CFLAGS) -DMAX_XLEN=32 -c -o $@ $<

$(BUILD)/floe_vm.o: $(ADAPTER)floe_vm.c $(ADAPTER)floe_vm.h | $(BUILD)/.dir
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/libfloevm.a: $(OBJS) $(BUILD)/floe_vm.o
	ar rcs $@ $^

$(BUILD)/floe_vm_host.o: $(HOST_DIR)/floe_vm_host.c $(ADAPTER)floe_vm.h | $(BUILD)/.dir
	$(CC) $(CFLAGS) -I$(ADAPTER) -c -o $@ $<

$(BUILD)/floe_vm_host: $(BUILD)/floe_vm_host.o $(BUILD)/libfloevm.a
	$(CC) -o $@ $^ $(LIBS)

clean:
	rm -rf $(BUILD)

.PHONY: all clean

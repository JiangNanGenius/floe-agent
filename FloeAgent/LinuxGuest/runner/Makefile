# Floe Linux guest runner build.
#
# Host build (protocol checks on the developer machine / CI):
#   make -C FloeAgent/LinuxGuest/runner host
# Guest build (static riscv64 for the TinyEMU image; needs
# gcc-riscv64-linux-gnu on the build host):
#   make -C FloeAgent/LinuxGuest/runner riscv64
#
# Variables:
#   CC        host compiler        (default: cc)
#   CROSS_CC  guest cross compiler (default: riscv64-linux-gnu-gcc)
#   CFLAGS    warning/optimization flags
#
# The guest binary is linked statically on purpose: the pinned 2018 demo
# kernel cannot load Debian's versioned modules, and a static binary removes
# any dependency on the guest's dynamic loader for the init process.

CC ?= cc
CROSS_CC ?= riscv64-linux-gnu-gcc
CFLAGS ?= -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE

HOST_BIN := floe-exec
RISCV_BIN := floe-exec-riscv64
CLOCK_CHECK_BIN := clock-arg-check

.PHONY: all host riscv64 check check-clock clean

all: host

host: $(HOST_BIN)

$(HOST_BIN): floe_exec.c floe_clock.h
	$(CC) $(CFLAGS) -o $@ $<

riscv64: $(RISCV_BIN)

$(RISCV_BIN): floe_exec.c floe_clock.h
	$(CROSS_CC) $(CFLAGS) -static -o $@ $<

# Real stdio protocol check (host framing + runner child processes). This is
# the full suite; the boot-clock change must not rerun it.
check: host
	bash ../tests/host_protocol_check.sh

# Pure-function/native check for the floe.epoch= parser and the bounded
# /proc/cmdline reader. No protocol run, no command execution and no clock
# change (the apply step is compiled out of the native build).
check-clock: $(CLOCK_CHECK_BIN)
	./$(CLOCK_CHECK_BIN)

$(CLOCK_CHECK_BIN): floe_clock.h ../tests/clock_arg_check.c
	$(CC) $(CFLAGS) -I. -o $@ ../tests/clock_arg_check.c

clean:
	rm -f $(HOST_BIN) $(RISCV_BIN) $(CLOCK_CHECK_BIN)

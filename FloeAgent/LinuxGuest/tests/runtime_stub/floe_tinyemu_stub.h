/*
 * floe_tinyemu_stub.h — host-only stand-in for the pinned FloeTinyEMU C
 * target, used by RuntimeLifecycleCheck to compile and exercise the real
 * TinyEMUGuestRuntime.swift lifecycle without booting a guest.
 *
 * This is not the engine: it implements the exact subset of the floe_vm_*
 * ABI the Swift runtime calls, with controllable slice duration and
 * observability for destroy-during-slice and post-destroy use.
 */
#ifndef FLOE_TINYEMU_STUB_H
#define FLOE_TINYEMU_STUB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeVM FloeVM;

#define FLOE_VM_MAX_SHARES 4
#define FLOE_VM_MAX_HOSTFWD 16

typedef struct {
    const char *tag;
    const char *host_dir;
} FloeVMShare;

typedef struct {
    uint64_t ram_mb;
    const char *bios_path;
    const char *kernel_path;
    const char *initrd_path;
    const char *cmdline;
    const char *disk_path;
    int disk_rw;
    FloeVMShare shares[FLOE_VM_MAX_SHARES];
    int share_count;
    int net_enable;
    int vcpu_count;
} FloeVMConfig;

typedef void (*FloeVMConsoleOutFn)(void *opaque, const uint8_t *data, int len);

FloeVM *floe_vm_create(const FloeVMConfig *cfg,
                       FloeVMConsoleOutFn out_fn, void *out_opaque);
int floe_vm_console_input(FloeVM *vm, const uint8_t *data, int len);
int floe_vm_run_slice(FloeVM *vm, int timeout_ms);
int floe_vm_poweroff_requested(const FloeVM *vm);
int floe_vm_hostfwd_add(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                        int host_port, uint32_t guest_ipv4, int guest_port);
int floe_vm_hostfwd_remove(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                           int host_port);
void floe_vm_destroy(FloeVM *vm);
const char *floe_vm_engine_version(void);

/* ---- test controls ---------------------------------------------------- */

/* Milliseconds each run_slice call sleeps (default 2). */
void floe_stub_set_slice_ms(int ms);
/* run_slice returns 1 (poweroff) after this many calls; 0 = never. */
void floe_stub_set_slices_before_poweroff(int slices);
/* 1 when floe_vm_destroy was called while a run_slice was executing. */
int floe_stub_destroy_while_slicing(void);
/* 1 when any floe_vm_* call happened after that VM was destroyed. */
int floe_stub_use_after_destroy(void);
int floe_stub_slice_calls(void);
/* Resets the console input counters (bytes, checksum, calls). */
void floe_stub_reset_console_counters(void);
/* Console input acceptance per floe_vm_console_input call: -1 = all
 * (default), 0 = none (permanent ring pressure), n>0 = at most n bytes. */
void floe_stub_set_partial_accept(int max_bytes);
/* Total console bytes accepted, and a 31-multiplier checksum of their order. */
long floe_stub_console_bytes_received(void);
unsigned long long floe_stub_console_checksum(void);
/* Number of successful console_input calls (validated bytes). */
int floe_stub_console_input_calls(void);
int floe_stub_hostfwd_add_calls(void);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_TINYEMU_STUB_H */

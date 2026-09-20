/*
 * floe_vm.h — Floe embeddable VM API over the TinyEMU 2019-12-21 (MIT) core.
 *
 * Copyright (c) 2026 Floe contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * This is Floe's own adapter layer. It links against the pristine, pinned
 * TinyEMU 2019-12-21 sources (MIT, Fabrice Bellard) plus one documented
 * minimal patch (patches/0001-htif-poweroff-callback.patch) that converts
 * the guest-poweroff exit(0) into an observable VM flag. No GPL code is
 * used: no QEMU, no iSH derived implementation.
 *
 * Threading model: the embedder runs floe_vm_run_slice() from a single VM
 * thread. floe_vm_console_input() may be called from any thread (queued).
 * Console output is delivered through the callback from within run_slice.
 */
#ifndef FLOE_VM_H
#define FLOE_VM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeVM FloeVM;

#define FLOE_VM_MAX_SHARES 4

typedef struct {
    const char *tag;       /* 9p mount tag visible to the guest */
    const char *host_dir;  /* host directory to export (must exist) */
} FloeVMShare;

typedef struct {
    uint64_t ram_mb;            /* guest RAM in MB (e.g. 128..1024) */
    const char *bios_path;      /* required: bbl64.bin (RISC-V BIOS/BBL) */
    const char *kernel_path;    /* optional: Linux kernel ELF/Image; NULL = payload in BIOS */
    const char *initrd_path;    /* optional initrd */
    const char *cmdline;        /* kernel cmdline, e.g. "console=hvc0 root=/dev/vda rw" */
    const char *disk_path;      /* optional raw block image (virtio-blk => /dev/vda) */
    int disk_rw;                /* 0 = snapshot (writes discarded), 1 = write-through */
    FloeVMShare shares[FLOE_VM_MAX_SHARES]; /* virtio-9p shares */
    int share_count;
    int net_enable;             /* 1 = slirp user-mode networking (10.0.2.0/24) */
} FloeVMConfig;

/* guest console output callback, invoked synchronously inside run_slice */
typedef void (*FloeVMConsoleOutFn)(void *opaque, const uint8_t *data, int len);

/* Create a VM. Returns NULL on error (diagnostic goes to stderr via vm_error). */
FloeVM *floe_vm_create(const FloeVMConfig *cfg,
                       FloeVMConsoleOutFn out_fn, void *out_opaque);

/* Queue bytes for the guest console (guest stdin). Callable from any thread.
 * Returns number of bytes queued, or <0 on error. Bytes are delivered to the
 * virtio console during subsequent run_slice calls. */
int floe_vm_console_input(FloeVM *vm, const uint8_t *data, int len);

/* Run one slice: poll network fds with select() up to timeout_ms, deliver
 * queued console input, then interpret up to a fixed cycle budget.
 * Returns: 0 = ran normally; 1 = guest requested poweroff; <0 = error. */
int floe_vm_run_slice(FloeVM *vm, int timeout_ms);

/* Non-blocking: 1 if the guest requested poweroff (HTIF tohost shutdown). */
int floe_vm_poweroff_requested(const FloeVM *vm);

/* Stop and free the VM. Safe to call after poweroff request. */
void floe_vm_destroy(FloeVM *vm);

const char *floe_vm_engine_version(void); /* TinyEMU core version string */

#ifdef __cplusplus
}
#endif

#endif /* FLOE_VM_H */

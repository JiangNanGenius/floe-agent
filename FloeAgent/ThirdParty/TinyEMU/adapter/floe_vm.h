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
 *
 * Lifecycle contract (verified by Qualification/TinyEMULinux):
 *  - create/destroy are repeatable: destroy releases the guest RAM, disk
 *    FILE handles + snapshot tables, 9p FS devices + tags, slirp state and
 *    file buffers; a failed create frees its partial allocations.
 *  - Networking uses one process-wide slirp instance: at most ONE VM with
 *    net_enable=1 may exist at a time; after that VM is destroyed a new
 *    networked VM can be created. Multiple simultaneous non-networked VMs
 *    are allowed by the adapter (upstream TinyEMU is not reentrant-safe
 *    across threads; run all slices from the same VM thread pool and do
 *    not drive two VMs concurrently from two threads).
 *  - Upstream engine fatal paths: guest RAM allocation failure exit(1)
 *    (iomem.c), internal device-invariant abort()s (virtio.c/riscv_cpu.c)
 *    remain from upstream and would terminate the host process; they are
 *    not reachable via valid guest behavior but are engine defects the
 *    embedder should know about. The guest-poweroff exit(0) IS fixed by
 *    patches/0001. */
#ifndef FLOE_VM_H
#define FLOE_VM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeVM FloeVM;

#define FLOE_VM_MAX_SHARES 4
#define FLOE_VM_MAX_HOSTFWD 16

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

/* host->guest TCP/UDP port forwarding through slirp (for localService:
   a guest Node/Python service becomes reachable on the host loopback).
   IPv4 addresses are in HOST byte order; host_ipv4 should normally be
   0x7F000001 (127.0.0.1); guest_ipv4 = 0 selects the guest's DHCP address
   (10.0.2.15). Callable from the run_slice thread while the VM runs, or
   any thread while it is paused. Forwards added here are removed
   automatically by floe_vm_destroy (listening fds are closed).
   Returns 0 on success, -1 on error (no network, table full, bad args). */
int floe_vm_hostfwd_add(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                        int host_port, uint32_t guest_ipv4, int guest_port);
int floe_vm_hostfwd_remove(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                           int host_port);

/* Stop and free the VM. Safe to call after poweroff request. */
void floe_vm_destroy(FloeVM *vm);

const char *floe_vm_engine_version(void); /* TinyEMU core version string */

#ifdef __cplusplus
}
#endif

#endif /* FLOE_VM_H */

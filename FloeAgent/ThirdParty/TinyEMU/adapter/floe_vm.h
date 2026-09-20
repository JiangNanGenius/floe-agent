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
 * TinyEMU 2019-12-21 sources (MIT, Fabrice Bellard) plus the documented
 * Floe patches in patches/ (guest poweroff, recoverable create/OOM paths,
 * Apple stat names, BOOTP typo, FENCE hints, per-instance slirp state,
 * 9p export-root containment, recoverable guest-fault paths). No GPL code
 * is used: no QEMU, no iSH derived implementation.
 *
 * Threading model: create may run on any thread; run_slice may then run on
 * a different (worker) thread -- nothing adapter- or engine-owned is
 * thread-local, and create does not capture a thread id. Console input may
 * be queued from any thread. Per VM, run_slice/destroy/hostfwd calls are
 * serialized by the adapter; different VMs (including networked ones) can
 * run concurrently on different threads because every VM owns its slirp
 * instance, its CPU state and its devices. Console output is delivered
 * through the callback from within run_slice (do not call floe_vm_destroy
 * from that callback; stop the worker first).
 *
 * Lifecycle contract (verified by Qualification/TinyEMULinux):
 *  - create/destroy are repeatable: destroy releases the guest RAM, disk
 *    FILE handles + snapshot tables, 9p FS devices + tags, slirp state
 *    (including adapter-registered port forwards) and file buffers; a
 *    failed create frees its partial allocations.
 *  - Networking is per-VM: each net_enable=1 VM gets its own slirp
 *    instance (separate 10.0.2.0/24 network, timers, DNS cache and select
 *    scratch), so TWO independent networked VMs can run on separate host
 *    threads at the same time. Destroying one closes only its own listening
 *    sockets. Host TCP/UDP ports remain a host-wide namespace: two VMs
 *    cannot both bind the same 127.0.0.1:port.
 *  - run_slice returns <0 only for a host-side fault it can recover from
 *    (e.g. select() failure); destroy such a VM and create a new one.
 *  - Upstream engine fatal paths: guest-RAM OOM (iomem.c), oversized
 *    BIOs/kernel/initrd (copy_bios), unknown virtio-blk request types and
 *    guest-sized descriptor/allocation failures in the virtio devices are
 *    recoverable (patches/0001, 0002, 0008). The remaining upstream
 *    abort()s are internal invariant checks on size_log2 / reply format
 *    strings that this adapter cannot reach with a valid guest, plus the
 *    unused config-file loader in machine.c; they are recorded in
 *    PHASE2_adapter.md rather than silently assumed away. */
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
 * Serialized per VM against destroy/hostfwd calls on other threads.
 * Returns: 0 = ran normally; 1 = guest requested poweroff; <0 = host-side
 * fault (destroy and recreate the VM). */
int floe_vm_run_slice(FloeVM *vm, int timeout_ms);

/* Non-blocking: 1 if the guest requested poweroff (HTIF tohost shutdown).
 * Safe to call from any thread; the value is cached atomically by the
 * adapter (updated by create/run_slice). */
int floe_vm_poweroff_requested(const FloeVM *vm);

/* host->guest TCP/UDP port forwarding through this VM's own slirp instance
   (for localService: a guest Node/Python service becomes reachable on the
   host loopback). IPv4 addresses are in HOST byte order; host_ipv4 should
   normally be 0x7F000001 (127.0.0.1); guest_ipv4 = 0 selects the guest's
   DHCP address (10.0.2.15). Callable from any thread; the adapter serializes
   it with run_slice/destroy on this VM (bounded by one slice). Forwards
   added here are removed automatically by floe_vm_destroy (listening fds are
   closed) and never touch another VM's slirp instance.
   Returns 0 on success, -1 on error (no network, table full, bad args,
   host port already bound). */
int floe_vm_hostfwd_add(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                        int host_port, uint32_t guest_ipv4, int guest_port);
int floe_vm_hostfwd_remove(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                           int host_port);

/* Stop and free the VM; waits for an in-flight run_slice on this VM to
   return. Do not call it from the console output callback. */
void floe_vm_destroy(FloeVM *vm);

const char *floe_vm_engine_version(void); /* TinyEMU core version string */

#ifdef __cplusplus
}
#endif

#endif /* FLOE_VM_H */

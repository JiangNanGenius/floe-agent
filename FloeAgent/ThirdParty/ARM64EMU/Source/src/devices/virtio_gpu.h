/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* virtio-gpu device interface (Floe ARM64EMU transport candidate). */
#ifndef A64_VIRTIO_GPU_H
#define A64_VIRTIO_GPU_H

#include "../types.h"
#include "../../../Bridge/virtio_gpu_backend.h"

struct Machine;
struct GIC;
struct VirtIOGPU;

/* Default live-allocation budget: 1 GiB, allocated on demand. This is NOT the
 * aperture capacity (FLOE_GPU_SHM_CAP) and NOT eagerly reserved. */
#define FLOE_GPU_DEFAULT_BUDGET (1024ULL << 20)

typedef struct VirtIOGPUOptions {
    uint64_t budget_bytes;    /* 0 = FLOE_GPU_DEFAULT_BUDGET */
    uint32_t scanout_width;   /* 0 = 1280 */
    uint32_t scanout_height;  /* 0 = 800  */
    int      wake_fd;         /* -1 = none; written on async fence completion */
    uint32_t max_transfer;    /* 0 = default staging cap for 3D transfers */
} VirtIOGPUOptions;

/* Create the device on virtio-mmio `slot` (fixed slot 31 by platform policy).
 * The backend is borrowed: the device never destroys it, the owner does after
 * virtio_gpu_destroy() has drained/cancelled fences. Returns NULL on failure. */
struct VirtIOGPU *virtio_gpu_create(struct Machine *m, struct GIC *gic,
                                    FloeVirtioGPUBackend *backend, int slot,
                                    const VirtIOGPUOptions *opts);

/* Coordinator-thread service: pops available descriptors, dispatches commands
 * to the backend, drains async fence completions and publishes used-ring
 * entries + IRQ. Never called from a backend worker thread. */
bool virtio_gpu_has_work(struct VirtIOGPU *v);
void virtio_gpu_service(struct VirtIOGPU *v);
/* Drain only async fence completions and publish what became retireable. */
void virtio_gpu_service_fence_drain(struct VirtIOGPU *v);

/* Warm reboot: quiesce queues, cancel outstanding fences, release resources,
 * contexts and aperture mappings. The backend and its contexts' host state
 * survive; the device tells the backend to drop fence tracking. */
void virtio_gpu_reset(struct VirtIOGPU *v);
/* Full teardown after the machine is quiet. Cancels fences, unmaps every
 * aperture range, then frees the device. Does NOT destroy the backend. */
void virtio_gpu_destroy(struct VirtIOGPU *v);

/* ---- quiesce protocol ----------------------------------------------------
 * A guest RESOURCE_UNMAP_BLOB / RESOURCE_UNREF of a mapped blob removes
 * guest-visible memory backing. The D-TLB caches VA->HOST POINTER on every
 * hart (mmu.c fills it by calling ram_ptr directly), and a whole-machine TLB
 * flush is illegal while native workers run (tlb_flush_machine fails the
 * machine when parallel_ops is installed). So the device:
 *   1. records the release, keeps the segment fully mapped and holds the
 *      command's response, and requests a quiesce (machine_owner_yield);
 *   2. the coordinator stops granting tickets, waits for the in-flight ones to
 *      retire, removes parallel_ops at that quiet point, calls
 *      virtio_gpu_quiesce_drain() to invalidate TLB/JIT/monitor state and
 *      release the backend pages, restores parallel_ops and resumes the SAME
 *      slice;
 *   3. the held responses are then published by the normal service path with
 *      parallel_ops installed, because gic_set_irq routes through
 *      parallel_ops->irq and an IRQ raised inside the window would be lost when
 *      the epoch re-seeds the harts.
 * Mapping never defers: adding backing to a hole needs no flush and is
 * published with a release store, so real SMP MAP_BLOB completes inline. */
bool virtio_gpu_quiesce_requested(struct VirtIOGPU *v);
int  virtio_gpu_quiesce_drain(struct VirtIOGPU *v);

/* Callback disable barrier. Call BEFORE the Bridge closes its wake pipe and
 * before destroying the device: after it returns, no backend completion
 * callback is inside the device and none can enter, so the fd can never be
 * written after close/reuse. A stale generation token alone does not give this
 * guarantee. */
void virtio_gpu_disable_callbacks(struct VirtIOGPU *v);
bool virtio_gpu_callbacks_enabled(struct VirtIOGPU *v);

/* Close only the display session: disable the scanout and release scanout-only
 * state. Compute (contexts, submissions, outstanding fences, mapped blobs)
 * keeps running. Returns true when a scanout was active. */
bool virtio_gpu_close_display(struct VirtIOGPU *v);

/* Live budget adjustment. Raising applies to subsequent allocations within the
 * aperture capacity and host headroom. Lowering never reclaims active
 * resources: *actual_out reports the budget now in force and
 * *pending_target_out the requested lower target that will apply once
 * occupancy drops. Returns 0 or negative errno. */
int virtio_gpu_set_budget(struct VirtIOGPU *v, uint64_t bytes,
                          uint64_t *actual_out, uint64_t *pending_target_out);

/* Introspection for diagnostics/tests (all outputs optional). */
typedef struct VirtIOGPUInfo {
    uint64_t budget_bytes;        /* budget in force */
    uint64_t requested_budget;    /* configured preference, before host clamp */
    uint64_t host_blob_bytes,host_internal_bytes; /* physical ledger, never add logical live */
    uint64_t pending_target;      /* lower target awaiting occupancy drop, 0 = none */
    uint64_t live_bytes;          /* bytes charged against the budget */
    uint32_t num_capsets;         /* enumerated from the backend */
    uint32_t num_scanouts;
    uint32_t resources;           /* live resource table entries */
    uint32_t contexts;            /* live contexts */
    uint32_t inflight;            /* commands accepted but not yet published */
    uint32_t fences_outstanding;  /* fenced commands awaiting exact completion */
    uint32_t aperture_mapped;     /* aperture ranges currently registered */
    uint64_t aperture_bytes;      /* aperture bytes currently registered */
    uint64_t features;            /* features actually advertised */
    uint32_t status, isr;
    bool     needs_reset;
} VirtIOGPUInfo;
void virtio_gpu_get_info(struct VirtIOGPU *v, VirtIOGPUInfo *out);

#endif /* A64_VIRTIO_GPU_H */

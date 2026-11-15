/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* virtio_gpu_pending.h — deferred aperture-release bookkeeping.
 *
 * A guest-visible aperture unmap needs every hart parked. When the unmap is
 * requested while workers are live, the transport records a pending release:
 * the renderer's pages must stay alive until the real all-hart drain performs
 * the TLB/JIT/monitor invalidation and only then unmaps and frees them.
 *
 * A RESOURCE_UNREF may arrive after that deferred UNMAP_BLOB and before the
 * drain (Linux virtio_gpu_vram_free sends exactly this sequence for a mappable
 * blob). The unref must escalate the pending unmap-only record into a full
 * release. Acking the unref without recording the release would strand the
 * resource table slot, the renderer resource and the backend fd/pages until a
 * device reset or session teardown — the per-client accumulation seen with
 * multiple real GPU clients.
 *
 * This header is the single implementation of that small state machine and is
 * compiled both into the transport device and into the deterministic fixture
 * (tests/lifetime_fixture.c). It performs no I/O and has no dependency beyond
 * the C standard library headers; callers keep ownership of the storage.
 */
#ifndef VIRTIO_GPU_PENDING_H
#define VIRTIO_GPU_PENDING_H

#include <stdbool.h>
#include <stdint.h>

typedef struct VGPendingRelease {
    bool     in_use;
    uint32_t res_id;
    bool     backend_mapped;   /* call resource_unmap_blob first */
    bool     release_resource; /* then free the resource table slot */
    uint64_t off, len;         /* aperture range still registered */
    uint64_t charged;          /* logical bytes to return on release */
} VGPendingRelease;

/* Find one resource's pending record; NULL when none is recorded. */
static inline VGPendingRelease *
vg_pending_find(VGPendingRelease *table, unsigned capacity, uint32_t res_id)
{
    if (!table || !res_id)
        return 0;
    for (unsigned i = 0; i < capacity; i++)
        if (table[i].in_use && table[i].res_id == res_id)
            return &table[i];
    return 0;
}

/* Overflow-safe [off, off+len) check for a record that will be used to unmap a
 * real region. Zero length is not a valid deferred mapping. */
static inline int
length_check(uint64_t off, uint64_t len)
{
    return len && off <= UINT64_MAX - len;
}

/* Record a new pending release. Fails only when the table is full (never
 * overwrites another resource's record, never reuses a live wait slot). */
static inline bool
vg_pending_add(VGPendingRelease *table, unsigned capacity, uint32_t res_id,
               bool backend_mapped, bool release_resource,
               uint64_t off, uint64_t len, uint64_t charged)
{
    if (!table || !res_id || length_check(off, len) == 0)
        return false;
    /* Never create a second wait record for one resource: two records would
     * double-release the same slot and logical charge at drain time. */
    if (vg_pending_find(table, capacity, res_id))
        return false;
    for (unsigned i = 0; i < capacity; i++) {
        if (table[i].in_use)
            continue;
        table[i].in_use = true;
        table[i].res_id = res_id;
        table[i].backend_mapped = backend_mapped;
        table[i].release_resource = release_resource;
        table[i].off = off;
        table[i].len = len;
        table[i].charged = charged;
        return true;
    }
    return false;
}

/* Escalate a pending unmap-only record into a full release.
 *
 * Called when RESOURCE_UNREF proves the guest has dropped its last ownership
 * of the resource while the aperture unmap is still deferred. Idempotent: a
 * second unref for the same resource must not charge the logical bytes twice.
 * Returns false when no matching pending record exists — the caller must fail
 * closed and keep the resource alive rather than invent a release. */
static inline bool
vg_pending_escalate(VGPendingRelease *table, unsigned capacity, uint32_t res_id,
                    uint64_t charged)
{
    VGPendingRelease *p = vg_pending_find(table, capacity, res_id);
    if (!p)
        return false;
    if (!p->release_resource) {
        p->release_resource = true;
        p->charged = charged;
    }
    return true;
}

#endif /* VIRTIO_GPU_PENDING_H */

/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* Device-mappable guest-physical region registry.
 *
 * Why this exists: memory.c maps exactly ONE RAM region (m->ram), so no device
 * could ever expose guest-visible shared memory. Two independent features need
 * such ranges and must not fight over a single hardwired slot:
 *
 *   - virtio-mem physical hotplug region (RAM package, job-cdfa5547be7547aa):
 *     one large contiguous engine-owned region.
 *   - virtio-gpu host-visible aperture (this transport candidate): a STABLE but
 *     SPARSE 4 GiB range at FLOE_GPU_SHM_BASE. Storage is allocated per blob by
 *     the host renderer (Venus/vkr -> VkDeviceMemory backed by its own shm
 *     pages), so each mapped blob registers its REAL host pointer+length at a
 *     device-assigned aperture offset. Nothing preallocates 4 GiB and nothing
 *     copies: the guest pages ARE the renderer's pages.
 *
 * Registry shape: a small array of coarse regions (<= FLOE_MAX_MAPPED_REGIONS);
 * a region is either contiguous (one host pointer for the whole range) or
 * sparse (a heap segment table; unmapped offsets are HOLES that fault like any
 * other unmapped PA). Lookup cost on the bus fast path is one range compare per
 * region, same shape as the existing RAM/flash checks.
 *
 * SAFETY / lifetime contract:
 *  - add/remove/seg_map/seg_unmap are COORDINATOR-ONLY calls.
 *  - Removing backing invalidates CPU-visible translations. The D-TLB caches
 *    VA page -> HOST POINTER (mmu.h: "RAM pages only"), so a stale entry after
 *    unmap would let a worker touch released pages. Real unmap therefore
 *    requires all-worker quiescence (m->parallel_ops == NULL, the same rule
 *    parallel_iface.h states for installing/removing ops) and then performs
 *    tlb_flush_machine() (all harts, incl. block/large-page entries),
 *    jit_invalidate_phys_range() and machine_store_notify() BEFORE the backing
 *    is released.
 *  - If workers are live, seg_unmap does NOT flush (tlb_flush_machine() would
 *    fail the machine) and does NOT release. It marks the segment pending and
 *    returns FLOE_REGION_DEFERRED; the owner must retry at a quiescent point.
 *    A pending segment stays fully mapped and accessible until then, so no
 *    guest access can ever reach released storage.
 *  - Adding backing to a former hole needs no flush: negative bus accesses
 *    never install a D-TLB entry (only RAM-backed host pointers are inserted).
 *  - Engine-owned backing (host == NULL at map time) is mmap'd here and
 *    munmap'd on release. Caller-supplied backing is ALIASED and never freed
 *    or munmap'd by the registry; its owner releases it after unmap returns. */
#ifndef A64_MEMORY_REGIONS_H
#define A64_MEMORY_REGIONS_H

#include "types.h"
#include <stdatomic.h>

struct Machine;

#define FLOE_MAX_MAPPED_REGIONS   8u
#define FLOE_MAX_REGION_SEGMENTS  256u
#define FLOE_REGION_PAGE          0x1000ULL

enum {
    FLOE_REGION_OK        =  0,
    FLOE_REGION_DEFERRED  =  1,   /* workers live: marked pending, retry when quiet */
    FLOE_REGION_EINVAL    = -22,
    FLOE_REGION_ENOMEM    = -12,
    FLOE_REGION_EEXIST    = -17,
    FLOE_REGION_ENOENT    = -2,
    FLOE_REGION_E2BIG     = -7,
};

/* One coarse guest-physical region. `sparse` regions keep a heap segment
 * table; contiguous regions use `host` for the whole [base, base+size). */
typedef struct MappedRegion {
    bool        in_use;
    bool        sparse;
    bool        owned;        /* contiguous: registry mmap'd `host` */
    u64         base, size;
    u8         *host;         /* contiguous backing, or NULL when sparse */
    const char *name;
    struct RegionSegment *segs;   /* sparse only; heap, FLOE_MAX_REGION_SEGMENTS */
    unsigned    nseg_active;
    unsigned    nseg_pending;     /* segments awaiting a quiescent unmap */
} MappedRegion;

/* Segment publication is CROSS-THREAD: mmu.c fills the D-TLB by calling
 * ram_ptr() directly on a native worker, so a worker reads this table while the
 * coordinator mutates it. `in_use` is therefore the publication flag: the
 * coordinator writes off/len/host/owned FIRST and release-stores in_use last;
 * readers acquire-load in_use before touching any other field. Adding backing
 * to a hole is then safe with workers live and needs no TLB flush (negative bus
 * accesses never install a D-TLB entry). REMOVING backing is not: it needs the
 * quiescence + whole-machine flush described above. */
typedef struct RegionSegment {
    _Atomic bool in_use;
    _Atomic bool pending_unmap;   /* unmap requested while workers were live */
    bool owned;           /* registry mmap'd this backing */
    u64  off, len;        /* offset within the region */
    u8  *host;            /* real backing bytes (aliased when !owned) */
} RegionSegment;

#ifdef __cplusplus
extern "C" {
#endif

int  machine_regions_init(struct Machine *m);
void machine_regions_destroy(struct Machine *m);

/* True when no native worker can be executing: m->parallel_ops is installed
 * and removed only at all-worker quiescence (parallel_iface.h). */
bool machine_workers_quiescent(struct Machine *m);

/* Add a region. sparse==true creates an empty hole-filled aperture.
 * Returns the region index (>=0) or a negative FLOE_REGION_E*. */
int  machine_region_add(struct Machine *m, u64 base, u64 size, bool sparse,
                        const char *name);
void machine_region_remove(struct Machine *m, int index);

/* Sparse-region backing. off/len must be FLOE_REGION_PAGE aligned and inside
 * the region. host == NULL asks the registry to mmap anonymous pages (owned).
 * seg_unmap returns FLOE_REGION_OK when the backing is really gone,
 * FLOE_REGION_DEFERRED when workers were live (segment still fully mapped and
 * marked pending; call machine_region_flush_pending when quiet). */
int  machine_region_seg_map(struct Machine *m, int index, u64 off, u64 len,
                            void *host);
int  machine_region_seg_unmap(struct Machine *m, int index, u64 off, u64 len);
/* Complete every pending unmap. Coordinator-only; no-op when workers are live
 * (returns FLOE_REGION_DEFERRED) so it is always safe to call between slices. */
int  machine_region_flush_pending(struct Machine *m, int index);

/* Bus integration used by memory.c. */
/* Host pointer aliasing [pa, pa+len), or NULL when unmapped / a sparse hole /
 * crossing a region or segment boundary. Never returns a pointer for a
 * pending-unmap segment's released bytes: pending segments stay mapped. */
void *machine_region_host_ptr(struct Machine *m, u64 pa, u64 len);
/* Reverse a live alias for the same memory guards/monitors as ordinary RAM. */
bool machine_region_guest_pa(struct Machine *m,const void *host,u64 len,u64 *pa);
/* Contiguous backed byte count starting at pa (0 when unmapped). */
u64   machine_region_contig(struct Machine *m, u64 pa);
/* True when [pa, pa+len) lies inside a region's address range, whether or not
 * sparse backing currently exists there. */
bool  machine_region_span(struct Machine *m, u64 pa, u64 len);

/* Direct region table access for device bookkeeping (read-only use). */
const MappedRegion *machine_region_at(struct Machine *m, int index);
int machine_region_find_by_name(struct Machine *m, const char *name);

#ifdef __cplusplus
}
#endif
#endif /* A64_MEMORY_REGIONS_H */

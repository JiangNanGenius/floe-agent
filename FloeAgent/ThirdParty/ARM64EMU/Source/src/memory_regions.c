/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* Device-mappable guest-physical region registry. See memory_regions.h for the
 * full lifetime/safety contract. Coordinator-only mutation; read side is the
 * memory.c bus fast path. */
#include "machine.h"
#include "memory_regions.h"
#include "mmu.h"          /* tlb_flush_machine, jit_invalidate_phys_range */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/mman.h>

/* parallel_ops is installed/removed only at all-worker quiescence, so its
 * absence is exactly "no native worker can be executing right now". */
bool machine_workers_quiescent(Machine *m) {
    return m && m->parallel_ops == NULL;
}

static bool page_aligned(u64 v) { return (v & (FLOE_REGION_PAGE - 1)) == 0; }
static bool range_ok(u64 base, u64 size, u64 off, u64 len) {
    return len <= size && off <= size - len && base + off >= base &&
           (size - off) >= len;
}
static bool spans_overlap(u64 a_base, u64 a_size, u64 b_base, u64 b_size) {
    return a_base < b_base + b_size && b_base < a_base + a_size;
}

int machine_regions_init(Machine *m) {
    if (!m) return FLOE_REGION_EINVAL;
    if (m->regions) return FLOE_REGION_OK;      /* idempotent */
    m->regions = calloc(FLOE_MAX_MAPPED_REGIONS, sizeof(MappedRegion));
    return m->regions ? FLOE_REGION_OK : FLOE_REGION_ENOMEM;
}

/* Release one segment's backing. Caller guarantees quiescence + invalidation. */
/* Coordinator-only. Unpublish FIRST (release), then drop the backing, so a
 * concurrent worker reader can never observe in_use with stale fields. */
static void segment_release(RegionSegment *s) {
    if (!atomic_load_explicit(&s->in_use, memory_order_acquire)) return;
    bool owned = s->owned; u64 len = s->len; u8 *host = s->host;
    atomic_store_explicit(&s->pending_unmap, false, memory_order_release);
    atomic_store_explicit(&s->in_use, false, memory_order_release);
    s->owned = false; s->host = NULL; s->off = 0; s->len = 0;
    if (owned && host) munmap(host, (size_t)len);
}

static void region_clear(Machine *m, MappedRegion *r) {
    if (!r->in_use) return;
    if (r->sparse) {
        if (r->segs) {
            for (unsigned i = 0; i < FLOE_MAX_REGION_SEGMENTS; i++)
                segment_release(&r->segs[i]);
            free(r->segs);
            r->segs = NULL;
        }
    } else if (r->owned && r->host) {
        munmap(r->host, (size_t)r->size);
    }
    (void)m;
    memset(r, 0, sizeof(*r));
}

void machine_regions_destroy(Machine *m) {
    if (!m || !m->regions) return;
    for (unsigned i = 0; i < FLOE_MAX_MAPPED_REGIONS; i++)
        region_clear(m, &m->regions[i]);
    free(m->regions);
    m->regions = NULL;
}

/* Invalidate every CPU-visible translation and reservation for [pa, pa+len).
 * Must be called only when workers are quiescent: tlb_flush_machine() fails
 * the machine when parallel_ops is installed. */
static void region_invalidate(Machine *m, u64 pa, u64 len) {
    if (!len) return;
    tlb_flush_machine(m);                 /* all harts: D-TLB host ptrs + TLB,
                                           * incl. block/large-page entries */
    jit_invalidate_phys_range(pa, len);   /* no-op in this library, kept for
                                           * parity with phys_write_blk */
    machine_store_notify(m, pa, len);     /* monitors + code-page epochs */
}

int machine_region_add(Machine *m, u64 base, u64 size, bool sparse,
                       const char *name) {
    if (!m || !m->regions || !size || !page_aligned(base) || !page_aligned(size))
        return FLOE_REGION_EINVAL;
    if (base + size < base) return FLOE_REGION_EINVAL;      /* wrap */
    /* Never alias RAM or flash: those are separately owned and separately
     * guarded, and a second mapping of the same PA would break accounting. */
    if (m->ram   && spans_overlap(base, size, m->ram_base,   m->ram_size))
        return FLOE_REGION_EEXIST;
    if (m->flash && spans_overlap(base, size, m->flash_base, m->flash_size))
        return FLOE_REGION_EEXIST;
    int free_idx = -1;
    for (unsigned i = 0; i < FLOE_MAX_MAPPED_REGIONS; i++) {
        MappedRegion *r = &m->regions[i];
        if (r->in_use) {
            if (spans_overlap(base, size, r->base, r->size))
                return FLOE_REGION_EEXIST;
        } else if (free_idx < 0) free_idx = (int)i;
    }
    if (free_idx < 0) return FLOE_REGION_E2BIG;
    MappedRegion *r = &m->regions[free_idx];
    memset(r, 0, sizeof(*r));
    r->base = base; r->size = size; r->sparse = sparse; r->name = name;
    if (sparse) {
        r->segs = calloc(FLOE_MAX_REGION_SEGMENTS, sizeof(RegionSegment));
        if (!r->segs) return FLOE_REGION_ENOMEM;
    } else {
        void *p = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return FLOE_REGION_ENOMEM;
        r->host = p; r->owned = true;
    }
    r->in_use = true;
    return free_idx;
}

void machine_region_remove(Machine *m, int index) {
    if (!m || !m->regions) return;
    if (index < 0 || index >= (int)FLOE_MAX_MAPPED_REGIONS) return;
    MappedRegion *r = &m->regions[index];
    if (!r->in_use) return;
    /* Removing a whole region also invalidates translations. Only legal when
     * quiet; when workers are live we still must not leave dangling D-TLB host
     * pointers, so refuse and leave the region installed. */
    if (!machine_workers_quiescent(m)) return;
    region_invalidate(m, r->base, r->size);
    region_clear(m, r);
}

static RegionSegment *find_segment(const MappedRegion *r, u64 off, u64 len,
                                   bool exact) {
    if (!r->sparse || !r->segs) return NULL;
    for (unsigned i = 0; i < FLOE_MAX_REGION_SEGMENTS; i++) {
        RegionSegment *s = &r->segs[i];
        /* acquire pairs with the coordinator's release store in seg_map */
        if (!atomic_load_explicit(&s->in_use, memory_order_acquire)) continue;
        if (exact) { if (s->off == off && s->len == len) return s; }
        else if (off < s->off + s->len && s->off < off + len) return s;
    }
    return NULL;
}

int machine_region_seg_map(Machine *m, int index, u64 off, u64 len, void *host) {
    if (!m || !m->regions) return FLOE_REGION_EINVAL;
    if (index < 0 || index >= (int)FLOE_MAX_MAPPED_REGIONS) return FLOE_REGION_EINVAL;
    MappedRegion *r = &m->regions[index];
    if (!r->in_use || !r->sparse) return FLOE_REGION_EINVAL;
    if (!len || !page_aligned(off) || !page_aligned(len)) return FLOE_REGION_EINVAL;
    if (!range_ok(r->base, r->size, off, len)) return FLOE_REGION_EINVAL;
    if (find_segment(r, off, len, false)) return FLOE_REGION_EEXIST;
    /* Reusing a hole that still has a pending unmap would resurrect bytes a
     * worker may still have translated; require the flush first. */
    for (unsigned i = 0; i < FLOE_MAX_REGION_SEGMENTS; i++) {
        RegionSegment *s = &r->segs[i];
        if (atomic_load_explicit(&s->in_use, memory_order_acquire) &&
            atomic_load_explicit(&s->pending_unmap, memory_order_acquire) &&
            off < s->off + s->len && s->off < off + len) return FLOE_REGION_EEXIST;
    }
    int slot = -1;
    for (unsigned i = 0; i < FLOE_MAX_REGION_SEGMENTS; i++)
        if (!atomic_load_explicit(&r->segs[i].in_use, memory_order_acquire)) { slot = (int)i; break; }
    if (slot < 0) return FLOE_REGION_E2BIG;
    RegionSegment *s = &r->segs[slot];
    s->off = off; s->len = len;
    if (host) { s->host = host; s->owned = false; }
    else {
        void *p = mmap(NULL, (size_t)len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return FLOE_REGION_ENOMEM;
        s->host = p; s->owned = true;
    }
    atomic_store_explicit(&s->pending_unmap, false, memory_order_relaxed);
    /* Payload first, publication last: a worker filling its D-TLB either sees
     * no segment or a fully initialized one. */
    atomic_store_explicit(&s->in_use, true, memory_order_release);
    r->nseg_active++;
    /* Adding backing to a hole needs no TLB flush: negative bus accesses never
     * install a D-TLB entry (only RAM-backed host pointers are inserted). */
    return FLOE_REGION_OK;
}

int machine_region_seg_unmap(Machine *m, int index, u64 off, u64 len) {
    if (!m || !m->regions) return FLOE_REGION_EINVAL;
    if (index < 0 || index >= (int)FLOE_MAX_MAPPED_REGIONS) return FLOE_REGION_EINVAL;
    MappedRegion *r = &m->regions[index];
    if (!r->in_use || !r->sparse) return FLOE_REGION_EINVAL;
    RegionSegment *s = find_segment(r, off, len, true);
    if (!s) return FLOE_REGION_ENOENT;
    if (atomic_load_explicit(&s->pending_unmap, memory_order_acquire))
        return FLOE_REGION_DEFERRED;
    if (!machine_workers_quiescent(m)) {
        /* Workers may hold D-TLB host pointers into these bytes and a whole
         * machine TLB flush is illegal while parallel_ops is installed. Keep
         * the segment fully mapped and accessible; the owner retries when
         * quiet. Nothing is released here, so no access can dangle. */
        atomic_store_explicit(&s->pending_unmap, true, memory_order_release);
        r->nseg_pending++;
        return FLOE_REGION_DEFERRED;
    }
    region_invalidate(m, r->base + s->off, s->len);
    segment_release(s);
    if (r->nseg_active) r->nseg_active--;
    return FLOE_REGION_OK;
}

int machine_region_flush_pending(Machine *m, int index) {
    if (!m || !m->regions) return FLOE_REGION_EINVAL;
    if (index < 0 || index >= (int)FLOE_MAX_MAPPED_REGIONS) return FLOE_REGION_EINVAL;
    MappedRegion *r = &m->regions[index];
    if (!r->in_use || !r->sparse || !r->segs) return FLOE_REGION_EINVAL;
    if (!r->nseg_pending) return FLOE_REGION_OK;
    if (!machine_workers_quiescent(m)) return FLOE_REGION_DEFERRED;
    for (unsigned i = 0; i < FLOE_MAX_REGION_SEGMENTS; i++) {
        RegionSegment *s = &r->segs[i];
        if (!atomic_load_explicit(&s->in_use, memory_order_acquire)) continue;
        if (!atomic_load_explicit(&s->pending_unmap, memory_order_acquire)) continue;
        region_invalidate(m, r->base + s->off, s->len);
        segment_release(s);
        if (r->nseg_active) r->nseg_active--;
        if (r->nseg_pending) r->nseg_pending--;
    }
    return FLOE_REGION_OK;
}

static MappedRegion *region_for(Machine *m, u64 pa, u64 len) {
    if (!m || !m->regions || !len) return NULL;
    for (unsigned i = 0; i < FLOE_MAX_MAPPED_REGIONS; i++) {
        MappedRegion *r = &m->regions[i];
        if (r->in_use && range_ok(r->base, r->size, pa - r->base, len) &&
            pa >= r->base) return r;
    }
    return NULL;
}

void *machine_region_host_ptr(Machine *m, u64 pa, u64 len) {
    MappedRegion *r = region_for(m, pa, len);
    if (!r) return NULL;
    u64 off = pa - r->base;
    if (!r->sparse) return r->host + off;
    RegionSegment *s = find_segment(r, off, len, false);
    if (!s) return NULL;                       /* sparse hole: faults like any
                                                * other unmapped PA */
    if (off < s->off || len > s->len || off - s->off > s->len - len) return NULL;
    return s->host + (off - s->off);
}

u64 machine_region_contig(Machine *m, u64 pa) {
    MappedRegion *r = region_for(m, pa, 1);
    if (!r) return 0;
    u64 off = pa - r->base;
    if (!r->sparse) return r->size - off;
    RegionSegment *s = find_segment(r, off, 1, false);
    if (!s) return 0;
    return s->off + s->len - off;
}

bool machine_region_span(Machine *m, u64 pa, u64 len) {
    return region_for(m, pa, len) != NULL;
}

const MappedRegion *machine_region_at(Machine *m, int index) {
    if (!m || !m->regions) return NULL;
    if (index < 0 || index >= (int)FLOE_MAX_MAPPED_REGIONS) return NULL;
    const MappedRegion *r = &m->regions[index];
    return r->in_use ? r : NULL;
}

int machine_region_find_by_name(Machine *m, const char *name) {
    if (!m || !m->regions || !name) return -1;
    for (unsigned i = 0; i < FLOE_MAX_MAPPED_REGIONS; i++)
        if (m->regions[i].in_use && m->regions[i].name &&
            strcmp(m->regions[i].name, name) == 0) return (int)i;
    return -1;
}

/* Maps/regions are published before use and removed only after every worker
 * parks. A pending unmap retains these exact bytes until the global TLB flush. */
bool machine_region_guest_pa(Machine *m,const void *host,u64 len,u64 *pa) {
    if(!m || !m->regions || !host || !len || !pa) return false;
    uintptr_t ptr=(uintptr_t)host;
    for(unsigned i=0;i<FLOE_MAX_MAPPED_REGIONS;i++) {
        const MappedRegion *r=&m->regions[i];
        if(!r->in_use) continue;
        if(!r->sparse) {
            uintptr_t base=(uintptr_t)r->host;
            if(r->host && ptr>=base && len<=r->size && ptr-base<=r->size-len) {
                *pa=r->base+(u64)(ptr-base);return true;
            }
        } else if(r->segs) {
            for(unsigned j=0;j<FLOE_MAX_REGION_SEGMENTS;j++) {
                const RegionSegment *seg=&r->segs[j];
                if(!atomic_load_explicit(&seg->in_use,memory_order_acquire)) continue;
                uintptr_t base=(uintptr_t)seg->host;
                if(seg->host && ptr>=base && len<=seg->len && ptr-base<=seg->len-len) {
                    *pa=r->base+seg->off+(u64)(ptr-base);return true;
                }
            }
        }
    }
    return false;
}

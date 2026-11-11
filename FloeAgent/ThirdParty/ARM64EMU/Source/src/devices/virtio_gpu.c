/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* virtio-gpu over a modern (version 2) virtio-mmio transport.
 *
 * Standard device for Linux DRM/Mesa Venus: control + cursor split queues,
 * capsets/context init, 3D submission, 2D and blob resources, host-visible
 * blob map/unmap through a sparse shared aperture, per-timeline ordered fences
 * and 2D scanout.
 *
 * Protocol: OASIS Virtio 1.3 section 5.7 (wire structures and their
 * provenance in virtio_gpu_protocol.h). Consulted for lifecycle/queue shape
 * only: libkrun (Apache-2.0) virtio/gpu, rutabaga_gfx (BSD-3-Clause),
 * virglrenderer (MIT). No GPL device source was used or copied.
 *
 * Design constraints honoured here:
 *  - ALL guest-visible state (guest memory, used ring, IRQ) is published on the
 *    machine coordinator thread. Backend worker threads may only call
 *    floe_gpu_backend_fence_complete(), which appends to a bounded ring and
 *    writes one wake byte.
 *  - Fences are exact (ctx_id, ring_idx, fence_id) identities. There is no
 *    global sequence and no cumulative retirement: completing one fence never
 *    retires another. Publication is ordered PER RING TIMELINE only, because
 *    Linux signals every seqno <= fence_id on that timeline.
 *  - A pending fence never blocks dispatch of later queue commands, so a ring
 *    can never deadlock waiting on work a later command would unblock.
 *  - The aperture (address capacity) is distinct from the budget (live bytes).
 *    This file's byte accounting is LOGICAL guest-requested bytes; the host
 *    backend owns physical usage and the two are never summed.
 *  - Closing the display releases only scanout state; contexts, submissions,
 *    fences and mapped blobs keep running. */
#include "../devices.h"
#include "virtio_gpu.h"
#include "virtio_gpu_protocol.h"
#include "virtio_gpu_shm.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <stdatomic.h>
#include <time.h>

#define GPU_DEVICE_ID        16u   /* virtio-gpu */
#define GPU_NUM_QUEUES       2u
#define GPU_QUEUE_CTRL       0u
#define GPU_QUEUE_CURSOR     1u
#define GPU_QUEUE_NUM_MAX    256u
#define GPU_MAX_DESC         64u   /* bounded descriptor-chain length */
#define GPU_MAX_RESOURCES    256u
#define GPU_MAX_CONTEXTS     64u
#define GPU_MAX_INFLIGHT     64u
#define GPU_MAX_IOV          64u   /* bounded backing entries per resource */
#define GPU_MAX_CAPSETS      8u
#define GPU_RESP_MAX         4096u /* staged response payload cap */
#define GPU_SUBMIT_MAX       (256u * 1024u)
#define GPU_FENCE_RING       256u  /* bounded async completion ring */
#define GPU_MAX_2D_DIM       16384u
#define GPU_MAX_ORPHANS      256u
#define GPU_CTRL_HDR_LEN     24u
#define GPU_EDID_LEN         128u
#define GPU_CAPSET_MAX_BYTES (GPU_RESP_MAX - GPU_CTRL_HDR_LEN)

/* split-virtqueue descriptor flags */
#define VIRTQ_DESC_F_NEXT     1u
#define VIRTQ_DESC_F_WRITE    2u
#define VIRTQ_DESC_F_INDIRECT 4u

/* Status register bits (virtio 1.3 section 2.1.2) */
#define VIRTIO_S_ACKNOWLEDGE 1u
#define VIRTIO_S_DRIVER      2u
#define VIRTIO_S_DRIVER_OK   4u
#define VIRTIO_S_FEATURES_OK 8u
#define VIRTIO_S_NEEDS_RESET 0x40u
#define VIRTIO_S_FAILED      0x80u

/* Response code used when a backend entry point is absent. */
#define FLOE_GPU_RESP_UNSPEC VIRTIO_GPU_RESP_ERR_UNSPEC

/* Little-endian wire accessors: never cast a struct onto guest bytes. */
static inline u32 rd16(const u8 *p){ return (u32)p[0] | ((u32)p[1] << 8); }
static inline u32 rd32(const u8 *p){
    return (u32)p[0] | ((u32)p[1]<<8) | ((u32)p[2]<<16) | ((u32)p[3]<<24);
}
static inline u64 rd64(const u8 *p){ return (u64)rd32(p) | ((u64)rd32(p+4)<<32); }
static inline void wr32(u8 *p,u32 v){
    p[0]=(u8)v; p[1]=(u8)(v>>8); p[2]=(u8)(v>>16); p[3]=(u8)(v>>24);
}
static inline void wr64(u8 *p,u64 v){ wr32(p,(u32)v); wr32(p+4,(u32)(v>>32)); }

typedef struct VGQueue {
    u32  num, ready;
    u64  desc, avail, used;
    u16  last_avail;
    bool notify_pending;
} VGQueue;

enum { VG_RES_NONE = 0, VG_RES_2D, VG_RES_3D, VG_RES_BLOB };

typedef struct VGResource {
    bool in_use;
    u32  id;
    u32  kind;                 /* VG_RES_* */
    u32  format, width, height;
    u32  ctx_id;
    /* blob */
    u32  blob_mem, blob_flags;
    u64  blob_id, size;
    bool mapped, backend_mapped, unmap_pending;
    u64  map_off, map_len;     /* aperture offset/length actually registered */
    u64  charged;              /* LOGICAL bytes charged against the budget */
    /* guest backing (attach_backing) */
    struct iovec iov[GPU_MAX_IOV];
    u32  niov;
    u64  backing_len;
    bool backing_attached;
} VGResource;

typedef struct VGContext {
    bool in_use;
    u32  id;
    u32  capset_id;
    u32  num_rings;
} VGContext;

/* One accepted-but-unpublished command. The response is staged here so an async
 * fence completion can publish it later without re-parsing the chain. */
typedef struct VGCmd {
    bool active;
    u32  queue;
    u16  head;
    u64  submit_seq;
    /* request header echo */
    u32  req_type, req_flags, req_ctx_id;
    u64  req_fence_id;
    u8   req_ring_idx;
    bool ring_valid;
    /* writable descriptors, kept for late publication */
    u64  w_gpa[GPU_MAX_DESC];
    u32  w_len[GPU_MAX_DESC];
    u32  nwrite;
    u64  w_total;
    /* staged response */
    u8   resp[GPU_RESP_MAX];
    u32  resp_len;
    bool resp_ready;
    /* fence state */
    bool fenced, fence_done, fence_registered;
    bool deferred;            /* response held until a quiescent aperture drain */
    /* Fence timeline key. Publication is ordered per timeline, and a timeline is
     * (ctx_id, ring_idx): Linux allocates ring_idx globally per device, so a
     * ring never spans two contexts and keying on both is equivalent to keying
     * on the ring while removing any cross-context head-of-line blocking.
     * ring == 0xFF means the wire header carried no INFO_RING_IDX flag. */
    u32  timeline_ctx;
    u8   timeline_ring;
} VGCmd;

/* Bounded MPSC completion ring: backend threads reserve a slot with a CAS and
 * publish the payload with a release store; the coordinator drains in order and
 * stops at the first not-yet-published slot (a slow producer can only delay,
 * never corrupt, later completions). */
typedef struct VGFCE {
    _Atomic u32 state;      /* 0 = free, 1 = payload ready */
    u32 ctx_id;
    u8  ring_idx, ring_valid;
    u64 fence_id;
} VGFCE;
typedef struct VGFenceRing {
    _Atomic u32 head;       /* producer reservation counter */
    _Atomic u32 tail;       /* consumer counter */
    VGFCE e[GPU_FENCE_RING];
} VGFenceRing;

typedef struct VirtIOGPU {
    Machine *m; GIC *gic; int irq; int slot;
    FloeVirtioGPUBackend *be;
    int  region_index;             /* sparse aperture in the region registry */
    VirtIOGPUOptions opts;

    u64  features;                 /* actually advertised */
    u32  status, isr;
    u32  dev_feat_sel, drv_feat_sel; u64 drv_feat;
    u32  queue_sel, shm_sel;

    VGQueue q[GPU_NUM_QUEUES];

    /* config space */
    u32  events_read, num_scanouts;
    u32  scanout_w, scanout_h;
    bool scanout_active;
    u32  scanout_res;

    /* capsets enumerated from the backend (never hardcoded) */
    struct { u32 id, max_version, max_size; } capsets[GPU_MAX_CAPSETS];
    u32  num_capsets;

    VGResource res[GPU_MAX_RESOURCES];
    VGContext  ctx[GPU_MAX_CONTEXTS];

    VGCmd inflight[GPU_MAX_INFLIGHT];
    u64   next_seq, oldest_seq;
    u32   inflight_count;

    VGFenceRing ring;
    u8  *submit_buf, *transfer_buf;
    u32  submit_cap, transfer_cap;
    FloeGPUGuestMem guest_mem;

    /* LOGICAL budget accounting (guest-requested bytes). The host backend owns
     * physical usage; never add the two together. */
    u64 budget_bytes, requested_budget, pending_target, live_bytes;

    u8  edid[GPU_EDID_LEN];
    bool work_pending;

    /* Quiesce protocol: a guest MAP_BLOB/UNMAP_BLOB mutates guest-visible
     * memory mappings, which needs every hart parked and parallel_ops removed
     * (parallel_iface.h). The device records the request and the coordinator
     * performs it at the next quiet point inside the SAME slice, so a real SMP
     * run never answers EBUSY. See virtio_gpu_quiesce_requested/_drain. */
    bool needs_quiesce;
    u32  quiesce_pending_ops;      /* map/unmap operations awaiting quiescence */
    /* Deferred backend releases. When an aperture unmap has to be deferred
     * (workers live), the renderer's pages MUST stay alive because the segment
     * is still mapped and a worker may still hold a D-TLB host pointer into it.
     * So unmap_blob / resource_unref / ctx_destroy AND the completion-ring
     * reset all wait for the real all-worker drain instead of running inline. */
    struct {
        bool in_use;
        u32  res_id;
        bool backend_mapped;      /* call resource_unmap_blob first */
        bool release_resource;    /* then free the resource table slot */
        u64  off, len;            /* aperture range still registered */
        u64  charged;             /* logical bytes to return on release */
    } pend_res[GPU_MAX_ORPHANS];
    struct { bool in_use; u32 ctx_id; } pend_ctx[GPU_MAX_CONTEXTS];
    bool pend_ring_reset;         /* completion ring reset awaits the drain */
    bool teardown;                /* a device-wide teardown is in progress */

    /* Callback disable barrier. The Bridge closes its wake pipe during dispose;
     * a late renderer retire callback holding that fd would race with close and
     * fd reuse. Teardown sets cb_disabled, then waits for cb_inflight to reach
     * zero, after which no callback can ever touch the fd again. The increment
     * is re-checked against the flag so a caller that raced the store is either
     * counted by the drain loop or refuses to enter. */
    _Atomic bool backend_signalled;
    _Atomic bool cb_disabled;
    _Atomic u32  cb_inflight;
    /* diagnostics */
    u64 stat_cmds, stat_fences, stat_deferred_unmaps, stat_bad_chain;
} VirtIOGPU;

static void gpu_settle_budget(VirtIOGPU *v) {
    if(v->be&&v->be->get_budget) {
        u64 requested=0,actual=0,target=0;
        if(!v->be->get_budget(v->be->opaque,&requested,&actual,&target)) {
            v->requested_budget=requested;
            v->budget_bytes=actual>v->live_bytes?actual:v->live_bytes;
            v->pending_target=v->budget_bytes>target?target:0;
        }
    } else if(v->pending_target&&v->live_bytes<=v->pending_target) {
        v->budget_bytes=v->pending_target;v->pending_target=0;
    }
}

/* ------------------------------------------------------- aperture wrapper */
/* Thin wrappers over the generic region registry, scoping every call to the
 * GPU aperture so the RAM package's virtio-mem hotplug region can share the
 * same registry without either device knowing about the other. */
int floe_gpu_shm_region_create(Machine *m) {
    int idx = machine_region_find_by_name(m, FLOE_GPU_SHM_NAME);
    if (idx >= 0) return idx;                    /* idempotent across reset */
    return machine_region_add(m, FLOE_GPU_SHM_BASE, FLOE_GPU_SHM_CAP, true,
                              FLOE_GPU_SHM_NAME);
}
bool floe_gpu_shm_span_ok(u64 gpa, u64 len) {
    return len && gpa >= FLOE_GPU_SHM_BASE && len <= FLOE_GPU_SHM_CAP &&
           gpa - FLOE_GPU_SHM_BASE <= FLOE_GPU_SHM_CAP - len;
}
int floe_gpu_shm_map(Machine *m, u64 gpa, u64 len, void *host) {
    if (!floe_gpu_shm_span_ok(gpa, len)) return FLOE_REGION_EINVAL;
    int idx = machine_region_find_by_name(m, FLOE_GPU_SHM_NAME);
    if (idx < 0) return FLOE_REGION_ENOENT;
    return machine_region_seg_map(m, idx, gpa - FLOE_GPU_SHM_BASE, len, host);
}
int floe_gpu_shm_unmap(Machine *m, u64 gpa, u64 len) {
    if (!floe_gpu_shm_span_ok(gpa, len)) return FLOE_REGION_EINVAL;
    int idx = machine_region_find_by_name(m, FLOE_GPU_SHM_NAME);
    if (idx < 0) return FLOE_REGION_ENOENT;
    return machine_region_seg_unmap(m, idx, gpa - FLOE_GPU_SHM_BASE, len);
}
int floe_gpu_shm_flush_pending(Machine *m) {
    int idx = machine_region_find_by_name(m, FLOE_GPU_SHM_NAME);
    if (idx < 0) return FLOE_REGION_ENOENT;
    return machine_region_flush_pending(m, idx);
}
void *floe_gpu_shm_host_ptr(Machine *m, u64 gpa, u64 len) {
    if (!floe_gpu_shm_span_ok(gpa, len)) return NULL;
    return machine_region_host_ptr(m, gpa, len);
}
u64 floe_gpu_shm_contig(Machine *m, u64 gpa) {
    if (gpa < FLOE_GPU_SHM_BASE ||
        gpa >= FLOE_GPU_SHM_BASE + FLOE_GPU_SHM_CAP) return 0;
    return machine_region_contig(m, gpa);
}

/* ----------------------------------------------------------- guest memory */
static int gm_resolve(FloeGPUGuestMem *self, u64 gpa, u64 len, void **out) {
    VirtIOGPU *v = (VirtIOGPU *)self->opaque;
    if (!v || !out || !len) return -EINVAL;
    void *p = ram_ptr(v->m, gpa, len);                    /* guest RAM first */
    if (!p) p = floe_gpu_shm_host_ptr(v->m, gpa, len);    /* sparse aperture */
    if (!p) return -EFAULT;
    *out = p;
    return 0;
}
static u64 gm_contig(FloeGPUGuestMem *self, u64 gpa) {
    VirtIOGPU *v = (VirtIOGPU *)self->opaque;
    if (!v) return 0;
    if (v->m->ram && gpa >= v->m->ram_base &&
        gpa < v->m->ram_base + v->m->ram_size)
        return v->m->ram_base + v->m->ram_size - gpa;
    return floe_gpu_shm_contig(v->m, gpa);
}
static int gm_is_shm(FloeGPUGuestMem *self, u64 gpa, u64 len) {
    VirtIOGPU *v = (VirtIOGPU *)self->opaque;
    return v && floe_gpu_shm_host_ptr(v->m, gpa, len) != NULL;
}

/* ----------------------------------------------------- async fence ring */
int floe_gpu_backend_fence_complete(struct VirtIOGPU *dev, u32 ctx_id,
                                    u8 ring_idx, u8 ring_valid, u64 fence_id) {
    VirtIOGPU *v = (VirtIOGPU *)dev;
    if (!v) return -EINVAL;
    /* Enter the barrier: refuse once teardown began, and make an in-flight
     * caller visible to virtio_gpu_disable_callbacks() before touching the
     * wake fd. The re-check after the increment is what closes the race. */
    if (atomic_load_explicit(&v->cb_disabled, memory_order_acquire))
        return -ESHUTDOWN;
    atomic_fetch_add_explicit(&v->cb_inflight, 1u, memory_order_acq_rel);
    if (atomic_load_explicit(&v->cb_disabled, memory_order_acquire)) {
        atomic_fetch_sub_explicit(&v->cb_inflight, 1u, memory_order_acq_rel);
        return -ESHUTDOWN;
    }
    int rc = 0;
    VGFenceRing *r = &v->ring;
    u32 h = atomic_load_explicit(&r->head, memory_order_relaxed);
    bool reserved = false;
    for (unsigned spin = 0; spin < 64u; spin++) {
        u32 t = atomic_load_explicit(&r->tail, memory_order_acquire);
        if ((u32)(h - t) >= GPU_FENCE_RING) { rc = -EAGAIN; break; }  /* bounded */
        if (atomic_compare_exchange_weak_explicit(&r->head, &h, h + 1,
                memory_order_acq_rel, memory_order_relaxed)) { reserved = true; break; }
    }
    if (!reserved && rc == 0) rc = -EAGAIN;    /* CAS contention: caller retries */
    if (reserved) {
        VGFCE *e = &r->e[h % GPU_FENCE_RING];
        e->ctx_id = ctx_id; e->ring_idx = ring_idx;
        e->ring_valid = ring_valid ? 1u : 0u; e->fence_id = fence_id;
        atomic_store_explicit(&e->state, 1u, memory_order_release);
        if (v->opts.wake_fd >= 0) {
            unsigned char byte = 0;
            ssize_t n = write(v->opts.wake_fd, &byte, 1);
            (void)n;   /* EAGAIN means a wake is already pending */
        }
    }
    atomic_fetch_sub_explicit(&v->cb_inflight, 1u, memory_order_acq_rel);
    return rc;
}

/* Teardown barrier: after this returns, no completion callback is inside the
 * device and none can enter, so the Bridge may safely close the wake fd. The
 * backend's own threads must still be joined by the backend (host CHECKPOINT
 * §7); this barrier is what makes the fd lifetime safe regardless of ordering,
 * and it is the reason a stale generation token alone is not enough. */
void virtio_gpu_disable_callbacks(struct VirtIOGPU *v) {
    if (!v) return;
    atomic_store_explicit(&v->cb_disabled, true, memory_order_release);
    for (unsigned spin = 0; spin < 1000000u; spin++) {
        if (atomic_load_explicit(&v->cb_inflight, memory_order_acquire) == 0u)
            return;
        struct timespec ts = { 0, 1000 };      /* 1us: bounded, no busy burn */
        nanosleep(&ts, NULL);
    }
    /* A caller stuck for a full second means a backend violated the contract;
     * leave the flag set so no further callback can enter. */
}

bool virtio_gpu_callbacks_enabled(struct VirtIOGPU *v) {
    return v && !atomic_load_explicit(&v->cb_disabled, memory_order_acquire);
}

static void gpu_drain_completions(VirtIOGPU *v) {
    VGFenceRing *r = &v->ring;
    for (;;) {
        u32 t = atomic_load_explicit(&r->tail, memory_order_relaxed);
        VGFCE *e = &r->e[t % GPU_FENCE_RING];
        if (atomic_load_explicit(&e->state, memory_order_acquire) != 1u) break;
        u32 ctx = e->ctx_id; u8 ri = e->ring_idx, rv = e->ring_valid;
        u64 fid = e->fence_id;
        atomic_store_explicit(&e->state, 0u, memory_order_relaxed);
        atomic_store_explicit(&r->tail, t + 1, memory_order_release);
        /* Exact-identity match only. A completion for an unknown or cancelled
         * identity (post-reset, unref'd resource, destroyed context) is ignored
         * and never applied to a different fence. */
        for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
            VGCmd *c = &v->inflight[i];
            if (!c->active || !c->fenced || c->fence_done) continue;
            if (c->req_ctx_id != ctx) continue;
            if (c->ring_valid != (rv != 0)) continue;
            if (c->ring_valid && c->req_ring_idx != ri) continue;
            if (c->req_fence_id != fid) continue;
            c->fence_done = true;
            break;
        }
    }
}

/* --------------------------------------------------------------- tables */
static VGResource *res_find(VirtIOGPU *v, u32 id) {
    if (!id) return NULL;
    for (u32 i = 0; i < GPU_MAX_RESOURCES; i++)
        if (v->res[i].in_use && v->res[i].id == id) return &v->res[i];
    return NULL;
}
static VGResource *res_alloc(VirtIOGPU *v, u32 id) {
    if (!id || res_find(v, id)) return NULL;
    for (u32 i = 0; i < GPU_MAX_RESOURCES; i++)
        if (!v->res[i].in_use) {
            memset(&v->res[i], 0, sizeof(v->res[i]));
            v->res[i].in_use = true; v->res[i].id = id;
            return &v->res[i];
        }
    return NULL;
}
static VGContext *ctx_find(VirtIOGPU *v, u32 id) {
    if (!id) return NULL;
    for (u32 i = 0; i < GPU_MAX_CONTEXTS; i++)
        if (v->ctx[i].in_use && v->ctx[i].id == id) return &v->ctx[i];
    return NULL;
}
static VGContext *ctx_alloc(VirtIOGPU *v, u32 id) {
    if (!id || ctx_find(v, id)) return NULL;
    for (u32 i = 0; i < GPU_MAX_CONTEXTS; i++)
        if (!v->ctx[i].in_use) {
            memset(&v->ctx[i], 0, sizeof(v->ctx[i]));
            v->ctx[i].in_use = true; v->ctx[i].id = id;
            return &v->ctx[i];
        }
    return NULL;
}
static bool capset_known(VirtIOGPU *v, u32 id) {
    for (u32 i = 0; i < v->num_capsets; i++) if (v->capsets[i].id == id) return true;
    return false;
}
static u32 res_count(VirtIOGPU *v) {
    u32 n = 0;
    for (u32 i = 0; i < GPU_MAX_RESOURCES; i++) if (v->res[i].in_use) n++;
    return n;
}
static u32 ctx_count(VirtIOGPU *v) {
    u32 n = 0;
    for (u32 i = 0; i < GPU_MAX_CONTEXTS; i++) if (v->ctx[i].in_use) n++;
    return n;
}

/* ----------------------------------------------------------------- EDID */
/* Build a valid 128-byte EDID 1.4 block for the configured mode: correct
 * header, a detailed timing descriptor so drm_edid_valid() accepts it, no
 * extensions, and a checksum that makes all 128 bytes sum to 0 mod 256. */
static void dtd_pack(u8 *d, u32 hactive, u32 vactive) {
    u32 hblank = hactive / 5, vblank = vactive / 25;
    if (hblank < 80) hblank = 80;
    if (vblank < 20) vblank = 20;
    u32 hsync_off = hblank / 2, hsync_w = hblank / 3;
    u32 vsync_off = 3, vsync_w = 6;
    u64 htotal = (u64)hactive + hblank, vtotal = (u64)vactive + vblank;
    u32 clock10k = (u32)((htotal * vtotal * 60ULL) / 10000ULL);
    memset(d, 0, 18);
    d[0] = (u8)(clock10k & 0xff); d[1] = (u8)(clock10k >> 8);
    d[2] = (u8)(hactive & 0xff);
    d[3] = (u8)(hblank & 0xff);
    d[4] = (u8)((((hactive >> 8) & 0x0f) << 4) | ((hblank >> 8) & 0x0f));
    d[5] = (u8)(vactive & 0xff);
    d[6] = (u8)(vblank & 0xff);
    d[7] = (u8)((((vactive >> 8) & 0x0f) << 4) | ((vblank >> 8) & 0x0f));
    d[8] = (u8)(hsync_off & 0xff);
    d[9] = (u8)(hsync_w & 0xff);
    d[10] = (u8)((((vsync_off & 0x3) << 6) | ((vsync_w & 0x3) << 4) |
                  (((hsync_w >> 8) & 0x3) << 2) | ((hsync_off >> 8) & 0x3)));
    d[11] = (u8)((((vsync_w >> 2) & 0x3) << 6) | (((vsync_off >> 2) & 0x3) << 4));
    d[12] = 0x90; d[13] = 0x7e; d[14] = 0x00;   /* ~370 x 330 mm */
    d[17] = 0x1e;   /* non-interlaced, digital separate sync, +H +V */
}
static void gpu_build_edid(VirtIOGPU *v) {
    u8 *e = v->edid;
    memset(e, 0, sizeof(v->edid));
    e[0]=0x00; e[1]=0xff; e[2]=0xff; e[3]=0xff;
    e[4]=0xff; e[5]=0xff; e[6]=0xff; e[7]=0x00;
    u32 m = ((u32)('F'-'A'+1) << 10) | ((u32)('L'-'A'+1) << 5) | (u32)('O'-'A'+1);
    e[8] = (u8)(m >> 8); e[9] = (u8)(m & 0xff);
    e[10] = 0x01; e[11] = 0x00;                 /* product code */
    e[12] = 1; e[13] = 0; e[14] = 0; e[15] = 0;  /* serial */
    e[16] = 1;                                   /* week */
    e[17] = 34;                                  /* 1990 + 34 = 2024 */
    e[18] = 1; e[19] = 4;                        /* EDID 1.4 */
    e[20] = 0x80;                                /* digital input */
    e[21] = 37; e[22] = 23;                      /* ~370 x 230 mm */
    e[23] = 120;                                 /* gamma 2.20 */
    e[24] = 0x0a;                                /* RGB 4:4:4, preferred timing */
    e[25]=0xee; e[26]=0x91; e[27]=0xa3; e[28]=0x54; e[29]=0x4c;
    e[30]=0x99; e[31]=0x26; e[32]=0x0f; e[33]=0x50; e[34]=0x54;
    dtd_pack(e + 54, v->scanout_w, v->scanout_h);
    u8 *rl = e + 72;                             /* monitor range limits */
    rl[3]=0xfd; rl[5]=48; rl[6]=75; rl[7]=30; rl[8]=83; rl[9]=10; rl[10]=0x0a;
    memset(rl + 11, 0x20, 7);
    u8 *mn = e + 90;                             /* monitor name */
    mn[3]=0xfc;
    const char *name = "Floe Virtual GPU";
    for (int i = 0; i < 13; i++) mn[5+i] = (u8)(name[i] ? name[i] : 0x0a);
    u8 *d4 = e + 108;                            /* dummy descriptor */
    d4[3]=0x10;
    memset(d4 + 5, 0x20, 13);
    e[126] = 0;                                  /* no extensions */
    u8 sum = 0;
    for (int i = 0; i < 127; i++) sum = (u8)(sum + e[i]);
    e[127] = (u8)(0x100u - sum);
}

/* -------------------------------------------------------------- capsets */
/* Enumerated from the backend at create and at every reset. A Venus-only host
 * backend exports only Venus (id 4); the transport never invents a GL capset. */
static void gpu_enumerate_capsets(VirtIOGPU *v) {
    v->num_capsets = 0;
    if (!v->be || !v->be->num_capsets || !v->be->get_capset_info) return;
    u32 n = v->be->num_capsets(v->be->opaque);
    if (n > GPU_MAX_CAPSETS) n = GPU_MAX_CAPSETS;
    for (u32 i = 0; i < n; i++) {
        u32 id = 0, mv = 0, ms = 0;
        if (v->be->get_capset_info(v->be->opaque, i, &id, &mv, &ms) != 0) continue;
        if (!id) continue;
        if (ms > GPU_CAPSET_MAX_BYTES) ms = GPU_CAPSET_MAX_BYTES;   /* bounded */
        v->capsets[v->num_capsets].id = id;
        v->capsets[v->num_capsets].max_version = mv;
        v->capsets[v->num_capsets].max_size = ms;
        v->num_capsets++;
    }
}

/* ------------------------------------------------------------- features */
/* Advertise only the intersection of what the backend actually serves and what
 * this transport implements. */
static void gpu_compute_features(VirtIOGPU *v) {
    u64 f = VIRTIO_F_VERSION_1;
    u32 caps = (v->be && v->be->caps_flags) ? v->be->caps_flags(v->be->opaque) : 0;
    if (caps & FLOE_GPU_CAP_VIRGL)         f |= (1ULL << VIRTIO_GPU_F_VIRGL);
    if (caps & FLOE_GPU_CAP_EDID)          f |= (1ULL << VIRTIO_GPU_F_EDID);
    if (caps & FLOE_GPU_CAP_RESOURCE_BLOB) f |= (1ULL << VIRTIO_GPU_F_RESOURCE_BLOB);
    if (caps & FLOE_GPU_CAP_CONTEXT_INIT)  f |= (1ULL << VIRTIO_GPU_F_CONTEXT_INIT);
    v->features = f;
}
static bool feat_acked(VirtIOGPU *v, unsigned bit) {
    return (v->drv_feat & (1ULL << bit)) != 0;
}

/* ------------------------------------------------------- queue plumbing */
static bool queue_spans(VirtIOGPU *v, VGQueue *q) {
    return q->ready && q->num && q->num <= GPU_QUEUE_NUM_MAX &&
        ram_ptr(v->m, q->desc,  (u64)q->num * 16) &&
        ram_ptr(v->m, q->avail, 6 + (u64)q->num * 2) &&
        ram_ptr(v->m, q->used,  6 + (u64)q->num * 8);
}

typedef struct VGChain {
    u16 head;
    u32 n;
    struct { u64 gpa; u32 len; u16 flags; } d[GPU_MAX_DESC];
    u32 ridx[GPU_MAX_DESC], widx[GPU_MAX_DESC];
    u32 nread, nwrite;
    u64 rtotal, wtotal;
} VGChain;

/* Walk one descriptor chain with cycle, length and flag bounds. Rejects
 * indirect descriptors (the feature is not advertised), unknown flag bits and
 * zero-length descriptors, and requires both a request and a response buffer. */
static bool gpu_chain_walk(VirtIOGPU *v, VGQueue *q, u16 head, VGChain *c) {
    memset(c, 0, sizeof(*c));
    c->head = head;
    bool seen[GPU_QUEUE_NUM_MAX];
    memset(seen, 0, sizeof(seen));
    u32 idx = head;
    for (;;) {
        if (idx >= q->num) return false;                  /* index out of range */
        if (seen[idx]) return false;                      /* descriptor cycle */
        if (c->n >= GPU_MAX_DESC) return false;           /* chain too long */
        seen[idx] = true;
        u8 md[16];
        phys_read_blk(v->m, q->desc + (u64)idx * 16, md, 16);
        if (machine_bus_status(v->m) != BUS_OK) return false;
        u64 addr = rd64(md); u32 len = rd32(md + 8);
        u16 flags = rd16(md + 12), next = rd16(md + 14);
        if (flags & ~(VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_INDIRECT))
            return false;
        if (flags & VIRTQ_DESC_F_INDIRECT) return false;  /* not advertised */
        if (!len) return false;
        c->d[c->n].gpa = addr; c->d[c->n].len = len; c->d[c->n].flags = flags;
        if (flags & VIRTQ_DESC_F_WRITE) c->widx[c->nwrite++] = c->n;
        else                            c->ridx[c->nread++]  = c->n;
        c->n++;
        if (!(flags & VIRTQ_DESC_F_NEXT)) break;
        idx = next;
    }
    for (u32 i = 0; i < c->nread; i++)  c->rtotal += c->d[c->ridx[i]].len;
    for (u32 i = 0; i < c->nwrite; i++) c->wtotal += c->d[c->widx[i]].len;
    return c->nread >= 1 && c->nwrite >= 1;
}

/* Read `len` bytes at logical offset `off` of the concatenated readable
 * descriptors. False when the request is shorter than asked (never reads
 * past what the guest actually offered). */
static bool chain_read(VirtIOGPU *v, const VGChain *c, u64 off, void *dst, u64 len) {
    u8 *out = dst;
    for (u32 i = 0; i < c->nread && len; i++) {
        const u64 gpa = c->d[c->ridx[i]].gpa;
        const u32 dlen = c->d[c->ridx[i]].len;
        if (off >= dlen) { off -= dlen; continue; }
        u64 take = dlen - off;
        if (take > len) take = len;
        phys_read_blk(v->m, gpa + off, out, take);
        if (machine_bus_status(v->m) != BUS_OK) return false;
        out += take; len -= take; off = 0;
    }
    return len == 0;
}

/* ---------------------------------------------------------- responses */
static void resp_hdr(VGCmd *c, u32 type) {
    wr32(c->resp + 0, type);
    wr32(c->resp + 4, c->req_flags);
    wr64(c->resp + 8, c->req_fence_id);
    wr32(c->resp + 16, c->req_ctx_id);
    c->resp[20] = c->req_ring_idx;
    c->resp[21] = c->resp[22] = c->resp[23] = 0;
    c->resp_len = GPU_CTRL_HDR_LEN;
}
static void resp_ok(VGCmd *c)  { resp_hdr(c, VIRTIO_GPU_RESP_OK_NODATA); c->resp_ready = true; }
static void resp_err(VGCmd *c, u32 err) { resp_hdr(c, err); c->resp_ready = true; }
/* Backend entries return 0 or a VIRTIO_GPU_RESP_ERR_* code verbatim. */
static void resp_rc(VGCmd *c, int rc) {
    if (!rc) { resp_ok(c); return; }
    resp_hdr(c, (rc >= (int)VIRTIO_GPU_RESP_ERR_UNSPEC &&
                 rc <= (int)VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER)
                    ? (u32)rc : (u32)VIRTIO_GPU_RESP_ERR_UNSPEC);
    c->resp_ready = true;
}

static void gpu_needs_reset(VirtIOGPU *v) {
    v->status |= VIRTIO_S_NEEDS_RESET;
    v->work_pending = false;
}

static bool gpu_push_used(VirtIOGPU *v, VGQueue *q, u16 id, u32 len) {
    u16 index = (u16)phys_read(v->m, q->used + 2, 2);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    u64 entry = q->used + 4 + (u64)(index % q->num) * 8;
    phys_write(v->m, entry, 4, id);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    phys_write(v->m, entry + 4, 4, len);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    phys_write(v->m, q->used + 2, 2, (u16)(index + 1));
    return machine_bus_status(v->m) == BUS_OK;
}

/* Publish one command: write the staged response into the writable descriptors
 * and retire it on the used ring. Never writes past the guest-provided
 * capacity; a response buffer smaller than the 24-byte header is a protocol
 * violation and puts the device into NEEDS_RESET instead of overflowing guest
 * memory. A capacity between 24 and the full payload yields an honestly
 * truncated response (used length = bytes actually written). */
static void gpu_publish(VirtIOGPU *v, VGCmd *c) {
    VGQueue *q = &v->q[c->queue];
    c->active = false;
    if (v->inflight_count) v->inflight_count--;
    if (!queue_spans(v, q)) { gpu_needs_reset(v); return; }
    if (c->resp_len < GPU_CTRL_HDR_LEN) c->resp_len = GPU_CTRL_HDR_LEN;
    if (c->w_total < GPU_CTRL_HDR_LEN || c->nwrite == 0) { gpu_needs_reset(v); return; }
    u64 remain = c->resp_len;
    if (remain > c->w_total) remain = c->w_total;          /* clamp: no overflow */
    u64 off = 0, written = 0;
    for (u32 i = 0; i < c->nwrite && remain; i++) {
        u64 take = c->w_len[i] < remain ? c->w_len[i] : remain;
        phys_write_blk(v->m, c->w_gpa[i], c->resp + off, take);
        if (machine_bus_status(v->m) != BUS_OK) { gpu_needs_reset(v); return; }
        off += take; written += take; remain -= take;
    }
    if (!gpu_push_used(v, q, c->head, (u32)written)) { gpu_needs_reset(v); return; }
    v->isr |= 1u;
    gic_set_irq(v->gic, v->irq, 1);
}

/* Ordered retirement. A fenced command publishes only once its EXACT identity
 * completed AND no earlier command on the same ring timeline is still
 * outstanding (Linux signals every seqno <= fence_id on that timeline, so
 * publishing early would be a false completion). Everything else publishes as
 * soon as it is staged, which is what keeps a pending fence from
 * head-of-line-blocking the ring. */
/* True when an EARLIER fenced command on the SAME timeline (ctx_id + ring) is
 * still outstanding. This is what makes publication ordered per timeline, which
 * the guest driver requires: Linux signals every seqno <= fence_id on a
 * timeline, so publishing a later fence first would falsely complete the
 * earlier one. Comparing ctx_id as well as the ring keeps two independent
 * contexts from blocking each other. */
static bool timeline_blocked(VirtIOGPU *v, const VGCmd *c) {
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
        const VGCmd *o = &v->inflight[i];
        if (!o->active || o == c || !o->fenced || o->fence_done) continue;
        if (o->submit_seq >= c->submit_seq) continue;
        if (o->timeline_ctx != c->timeline_ctx) continue;
        if (o->timeline_ring != c->timeline_ring) continue;
        return true;
    }
    return false;
}

static void gpu_retire(VirtIOGPU *v) {
    for (u64 s = v->oldest_seq; s < v->next_seq; s++) {
        VGCmd *c = &v->inflight[s % GPU_MAX_INFLIGHT];
        if (!c->active || c->submit_seq != s) continue;
        if (!c->resp_ready) continue;
        if (c->fenced && !c->fence_done) continue;
        if (c->fenced && timeline_blocked(v, c)) continue;
        gpu_publish(v, c);
        if (v->status & VIRTIO_S_NEEDS_RESET) return;
    }
    while (v->oldest_seq < v->next_seq) {
        VGCmd *o = &v->inflight[v->oldest_seq % GPU_MAX_INFLIGHT];
        if (o->active && o->submit_seq == v->oldest_seq) break;
        v->oldest_seq++;
    }
}

/* ------------------------------------------------------- backing iovecs */
/* Turn a validated virtio_gpu_mem_entry list into real host iovecs. Every entry
 * must be fully backed by guest RAM or the shared aperture; anything else is a
 * protocol error, never a silent truncation or an invented mapping. */
static bool gpu_build_iov(VirtIOGPU *v, const u8 *entries, u32 nr,
                          struct iovec *iov, u32 *niov_out, u64 *total_out) {
    u32 n = 0; u64 total = 0;
    for (u32 i = 0; i < nr; i++) {
        const u8 *e = entries + (u64)i * 16;
        u64 addr = rd64(e); u32 len = rd32(e + 8);
        if (!len) return false;
        if (total + len < total) return false;                 /* u64 overflow */
        void *host = ram_ptr(v->m, addr, len);
        if (!host) host = floe_gpu_shm_host_ptr(v->m, addr, len);
        if (!host) return false;                               /* unmapped GPA */
        if (n >= GPU_MAX_IOV) return false;                    /* over bound */
        iov[n].iov_base = host; iov[n].iov_len = (size_t)len; n++;
        total += len;
    }
    *niov_out = n; *total_out = total;
    return true;
}

/* --------------------------------------------------- quiesce bookkeeping */
/* Record an aperture range that must be released once every hart is parked.
 * The registry keeps the segment fully mapped (and the backend keeps its pages)
 * until then, so no access can dangle in the meantime. */
static bool pend_add(VirtIOGPU *v, u32 res_id, bool backend_mapped,
                     bool release_resource, u64 off, u64 len, u64 charged) {
    for (u32 i = 0; i < GPU_MAX_ORPHANS; i++) {
        if (v->pend_res[i].in_use) continue;
        v->pend_res[i].in_use = true;
        v->pend_res[i].res_id = res_id;
        v->pend_res[i].backend_mapped = backend_mapped;
        v->pend_res[i].release_resource = release_resource;
        v->pend_res[i].off = off; v->pend_res[i].len = len;
        v->pend_res[i].charged = charged;
        return true;
    }
    return false;   /* table full: caller must NOT release the backing */
}

static void request_quiesce(VirtIOGPU *v) {
    v->needs_quiesce = true;
    /* Make the requesting worker yield promptly so the coordinator reaches the
     * quiet point inside this slice (same mechanism virtio-blk DMA uses). */
    machine_owner_yield(v->m);
}

bool virtio_gpu_quiesce_requested(struct VirtIOGPU *v) {
    return v && v->needs_quiesce;
}

/* Perform the deferred aperture releases. MUST be called with every hart parked
 * and parallel_ops removed (the coordinator's device-quiesce window). It does
 * memory work only: the used ring and the IRQ are published afterwards by the
 * normal service path with parallel_ops restored, because gic_set_irq routes
 * through parallel_ops->irq and a direct write inside the window would be lost
 * when the epoch re-seeds the harts. */
int virtio_gpu_quiesce_drain(struct VirtIOGPU *v) {
    if (!v || !v->needs_quiesce) return FLOE_REGION_OK;
    /* Step 1: really remove the guest-visible mappings. This is what performs
     * the whole-machine TLB/JIT/monitor invalidation, and it refuses to run
     * unless every worker is parked. Until it succeeds, no backing is freed. */
    int rc = floe_gpu_shm_flush_pending(v->m);
    if (rc != FLOE_REGION_OK) return rc;         /* still not quiet: keep state */

    /* Step 2: only now may the renderer release its pages, and only after the
     * mapping is gone. Order per entry: unmap_blob, then unref, then free. */
    for (u32 i = 0; i < GPU_MAX_ORPHANS; i++) {
        if (!v->pend_res[i].in_use) continue;
        u32 id = v->pend_res[i].res_id;
        if (v->pend_res[i].backend_mapped && v->be && v->be->resource_unmap_blob)
            v->be->resource_unmap_blob(v->be->opaque, id);
        VGResource *r = res_find(v, id);
        if (r) { r->mapped = false; r->backend_mapped = false; r->unmap_pending = false; }
        if (v->pend_res[i].release_resource) {
            if (r) {
                if (r->backing_attached && v->be && v->be->resource_detach_backing)
                    v->be->resource_detach_backing(v->be->opaque, id);
                if (v->be && v->be->resource_unref) v->be->resource_unref(v->be->opaque, id);
                memset(r, 0, sizeof(*r));
            }
            v->live_bytes -= v->pend_res[i].charged;
        }
        memset(&v->pend_res[i], 0, sizeof(v->pend_res[i]));
    }

    /* Step 3: contexts are destroyed only after every blob that could belong to
     * them is unmapped and unreffed, so no renderer teardown can free pages a
     * hart could still have translated. */
    for (u32 i = 0; i < GPU_MAX_CONTEXTS; i++) {
        if (!v->pend_ctx[i].in_use) continue;
        VGContext *cx = ctx_find(v, v->pend_ctx[i].ctx_id);
        if (cx) {
            if (v->be && v->be->ctx_destroy) v->be->ctx_destroy(v->be->opaque, cx->id);
            memset(cx, 0, sizeof(*cx));
        }
        memset(&v->pend_ctx[i], 0, sizeof(v->pend_ctx[i]));
    }

    /* Step 4: reset the completion ring LAST. Any completion the old generation
     * managed to enqueue is discarded here, and cancel_fence was already issued
     * for every outstanding identity, so a stale renderer callback cannot be
     * matched against a new command that reused the same (ctx, ring, fence_id).
     * The backend contract requires cancel_fence to guarantee no later
     * completion for that identity. */
    if (v->pend_ring_reset) {
        atomic_store(&v->ring.head, 0u);
        atomic_store(&v->ring.tail, 0u);
        for (u32 i = 0; i < GPU_FENCE_RING; i++)
            atomic_store(&v->ring.e[i].state, 0u);
        v->pend_ring_reset = false;
    }

    /* Step 5: complete the commands that were held for the quiescent drain. */
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
        VGCmd *c = &v->inflight[i];
        if (!c->active || !c->deferred) continue;
        c->deferred = false;
        resp_ok(c);
    }
    v->teardown = false;
    v->needs_quiesce = false;
    v->quiesce_pending_ops = 0;
    return FLOE_REGION_OK;
}

/* ------------------------------------------------------------- handlers */
/* One wire pmode is rect(16) + enabled(4) + flags(4) = 24 bytes, so the whole
 * response is 24 + VIRTIO_GPU_MAX_SCANOUTS * 24 = 408 bytes. */
#define GPU_PMODE_LEN 24u
#define GPU_DISPLAY_INFO_LEN (GPU_CTRL_HDR_LEN + VIRTIO_GPU_MAX_SCANOUTS * GPU_PMODE_LEN)
_Static_assert(GPU_DISPLAY_INFO_LEN == 408u, "virtio_gpu_resp_display_info wire size");

static void h_get_display_info(VirtIOGPU *v, VGCmd *c) {
    resp_hdr(c, VIRTIO_GPU_RESP_OK_DISPLAY_INFO);
    u8 *p = c->resp + c->resp_len;
    for (u32 i = 0; i < VIRTIO_GPU_MAX_SCANOUTS; i++) {
        if (p + GPU_PMODE_LEN > c->resp + GPU_RESP_MAX) return;
        bool on = (i == 0 && v->scanout_active);
        wr32(p + 0,  0);                      /* rect.x      */
        wr32(p + 4,  0);                      /* rect.y      */
        wr32(p + 8,  on ? v->scanout_w : 0);  /* rect.width  */
        wr32(p + 12, on ? v->scanout_h : 0);  /* rect.height */
        wr32(p + 16, on ? 1u : 0u);           /* enabled     */
        wr32(p + 20, 0);                      /* flags       */
        p += GPU_PMODE_LEN;
    }
    c->resp_len = (u32)(p - c->resp);
    c->resp_ready = true;
}

static bool valid_2d_format(u32 f) {
    switch (f) {
        case VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: case VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM:
        case VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM: case VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM:
        case VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM: case VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM:
        case VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM: case VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM:
            return true;
        default: return false;
    }
}

static void h_resource_create_2d(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[16];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b), fmt = rd32(b + 4), w = rd32(b + 8), h = rd32(b + 12);
    if (!w || !h || w > GPU_MAX_2D_DIM || h > GPU_MAX_2D_DIM || !valid_2d_format(fmt)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    VGResource *r = res_alloc(v, id);
    if (!r) { resp_err(c, res_find(v, id) ? VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER
                                          : VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return; }
    r->kind = VG_RES_2D; r->format = fmt; r->width = w; r->height = h;
    int rc = (v->be && v->be->resource_create_2d)
        ? v->be->resource_create_2d(v->be->opaque, id, fmt, w, h) : 0;
    if (rc) { r->in_use = false; resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_resource_unref(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    VGResource *r = res_find(v, id);
    if (!r) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (r->unmap_pending) { resp_ok(c); return; }   /* release already in flight */
    if (v->scanout_active && v->scanout_res == id) { v->scanout_active = false; v->scanout_res = 0; }
    if (r->mapped) {
        int rc = floe_gpu_shm_unmap(v->m, FLOE_GPU_SHM_BASE + r->map_off, r->map_len);
        if (rc == FLOE_REGION_DEFERRED) {
            /* Workers are live, so the aperture range is still mapped and a hart
             * may still hold a D-TLB host pointer into the renderer's pages.
             * Nothing may be freed yet: not unmap_blob, not detach, not unref.
             * The slot stays reserved (its id cannot be reused) and the response
             * is held until the real all-worker drain releases everything in the
             * correct order. */
            if (!pend_add(v, id, r->backend_mapped, true, r->map_off, r->map_len,
                          r->charged)) {
                /* No room to record the deferral: refuse rather than free pages
                 * a worker could still reach. The guest may retry. */
                resp_err(c, VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY);
                return;
            }
            r->unmap_pending = true;
            request_quiesce(v);
            v->quiesce_pending_ops++;
            c->deferred = true;                 /* resp_ready stays false */
            return;
        }
        if (r->backend_mapped && v->be && v->be->resource_unmap_blob)
            v->be->resource_unmap_blob(v->be->opaque, id);
        r->mapped = false; r->backend_mapped = false;
    }
    if (r->backing_attached && v->be && v->be->resource_detach_backing)
        v->be->resource_detach_backing(v->be->opaque, id);
    if (r->charged) { v->live_bytes -= r->charged; r->charged = 0; }
    if (v->be && v->be->resource_unref) v->be->resource_unref(v->be->opaque, id);
    memset(r, 0, sizeof(*r));
    resp_ok(c);
}

static void h_set_scanout(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[24];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_rect r = { rd32(b), rd32(b+4), rd32(b+8), rd32(b+12) };
    u32 scanout = rd32(b + 16), res = rd32(b + 20);
    if (scanout >= v->num_scanouts) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID); return; }
    if (res && !res_find(v, res)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    int rc = (v->be && v->be->set_scanout)
        ? v->be->set_scanout(v->be->opaque, scanout, res, &r) : 0;
    if (rc) { resp_rc(c, rc); return; }
    bool was = v->scanout_active;
    v->scanout_active = (res != 0);
    v->scanout_res = res;
    if (v->scanout_active && !was) {
        v->events_read |= VIRTIO_GPU_EVENT_DISPLAY;
        v->isr |= 2u;                            /* config-change */
        gic_set_irq(v->gic, v->irq, 1);
    }
    resp_ok(c);
}

static void h_resource_flush(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[24];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_rect r = { rd32(b), rd32(b+4), rd32(b+8), rd32(b+12) };
    u32 id = rd32(b + 16);
    if (!res_find(v, id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    int rc = (v->be && v->be->flush) ? v->be->flush(v->be->opaque, id, &r) : 0;
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_transfer_to_host_2d(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[32];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_rect r = { rd32(b), rd32(b+4), rd32(b+8), rd32(b+12) };
    u64 off = rd64(b + 16);
    u32 id = rd32(b + 24);
    VGResource *res = res_find(v, id);
    if (!res) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (!r.width || !r.height ||
        r.x + r.width < r.x || r.y + r.height < r.y ||
        r.x + r.width > res->width || r.y + r.height > res->height) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    u64 need = (u64)r.width * r.height * 4u + off;
    if (need < off) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (res->backing_attached && need > res->backing_len) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    int rc = (v->be && v->be->transfer_to_host_2d)
        ? v->be->transfer_to_host_2d(v->be->opaque, id, &r, off) : 0;
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_attach_backing(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b), nr = rd32(b + 4);
    VGResource *r = res_find(v, id);
    if (!r) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (!nr || nr > GPU_MAX_IOV) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    u64 need = (u64)nr * 16u;
    if (GPU_CTRL_HDR_LEN + 8u + need > ch->rtotal) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;   /* short request */
    }
    u8 entries[GPU_MAX_IOV * 16];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN + 8u, entries, need)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return;
    }
    struct iovec iov[GPU_MAX_IOV];
    u32 niov = 0; u64 total = 0;
    if (!gpu_build_iov(v, entries, nr, iov, &niov, &total)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;   /* bad range */
    }
    int rc = (v->be && v->be->resource_attach_backing)
        ? v->be->resource_attach_backing(v->be->opaque, id, iov, niov, total,
                                         &v->guest_mem) : 0;
    if (rc) { resp_rc(c, rc); return; }
    memcpy(r->iov, iov, sizeof(struct iovec) * niov);
    r->niov = niov; r->backing_len = total; r->backing_attached = true;
    resp_ok(c);
}

static void h_detach_backing(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    VGResource *r = res_find(v, id);
    if (!r) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    int rc = (v->be && v->be->resource_detach_backing)
        ? v->be->resource_detach_backing(v->be->opaque, id) : 0;
    if (rc) { resp_rc(c, rc); return; }
    r->niov = 0; r->backing_len = 0; r->backing_attached = false;
    resp_ok(c);
}

static void h_get_capset_info(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 idx = rd32(b);
    if (idx >= v->num_capsets) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    resp_hdr(c, VIRTIO_GPU_RESP_OK_CAPSET_INFO);
    u8 *p = c->resp + c->resp_len;
    wr32(p, v->capsets[idx].id);
    wr32(p + 4, v->capsets[idx].max_version);
    wr32(p + 8, v->capsets[idx].max_size);
    wr32(p + 12, 0);
    c->resp_len += 16;
    c->resp_ready = true;
}

static void h_get_capset(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b), ver = rd32(b + 4);
    u32 idx = 0; bool found = false;
    for (u32 i = 0; i < v->num_capsets; i++)
        if (v->capsets[i].id == id) { idx = i; found = true; break; }
    if (!found) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (ver > v->capsets[idx].max_version) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    u32 room = GPU_CAPSET_MAX_BYTES;
    if (c->w_total > GPU_CTRL_HDR_LEN && (u64)(c->w_total - GPU_CTRL_HDR_LEN) < room)
        room = (u32)(c->w_total - GPU_CTRL_HDR_LEN);      /* never overflow the guest buffer */
    if (room > v->capsets[idx].max_size) room = v->capsets[idx].max_size;
    resp_hdr(c, VIRTIO_GPU_RESP_OK_CAPSET);
    u32 size = room;
    int rc = (v->be && v->be->get_capset)
        ? v->be->get_capset(v->be->opaque, id, ver, c->resp + c->resp_len, &size) : -1;
    if (rc) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    if (size > room) size = room;
    c->resp_len += size;
    c->resp_ready = true;
}

static void h_get_edid(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 scanout = rd32(b);
    if (!feat_acked(v, VIRTIO_GPU_F_EDID)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    if (scanout >= v->num_scanouts) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID); return; }
    resp_hdr(c, VIRTIO_GPU_RESP_OK_EDID);
    wr32(c->resp + c->resp_len, GPU_EDID_LEN);
    wr32(c->resp + c->resp_len + 4, 0);
    c->resp_len += 8;
    u32 room = GPU_RESP_MAX - c->resp_len;
    if (c->w_total > c->resp_len && (u64)(c->w_total - c->resp_len) < room)
        room = (u32)(c->w_total - c->resp_len);
    u32 n = room < GPU_EDID_LEN ? room : GPU_EDID_LEN;
    memcpy(c->resp + c->resp_len, v->edid, n);
    c->resp_len += n;
    c->resp_ready = true;
}

static void h_ctx_create(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[72];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 nlen = rd32(b), ctx_init = rd32(b + 4);
    if (nlen > 64) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (c->req_ctx_id == 0) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID); return; }
    if (ctx_find(v, c->req_ctx_id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    u32 capset = 0;
    if (ctx_init) {
        if (!feat_acked(v, VIRTIO_GPU_F_CONTEXT_INIT)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
        }
        capset = ctx_init & VIRTIO_GPU_CONTEXT_INIT_CAPSET_ID_MASK;
        if (!capset_known(v, capset)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    } else if (!feat_acked(v, VIRTIO_GPU_F_VIRGL)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return;
    }
    char name[65];
    memcpy(name, b + 8, 64);
    name[nlen < 64u ? nlen : 64u] = '\0';
    int rc = (v->be && v->be->ctx_create)
        ? v->be->ctx_create(v->be->opaque, c->req_ctx_id, ctx_init, name, nlen) : 0;
    if (rc) { resp_rc(c, rc); return; }
    VGContext *cx = ctx_alloc(v, c->req_ctx_id);
    if (!cx) { resp_err(c, VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return; }
    cx->capset_id = capset;
    cx->num_rings = 1;
    resp_ok(c);
}

/* Cancel every outstanding fence on a context being destroyed: those identities
 * can never complete, and the backend must not signal a freed identity later. */
static void ctx_cancel_fences(VirtIOGPU *v, u32 ctx_id) {
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
        VGCmd *o = &v->inflight[i];
        if (!o->active || !o->fenced || o->fence_done) continue;
        if (o->req_ctx_id != ctx_id) continue;
        if (o->fence_registered && v->be && v->be->cancel_fence) {
            FloeGPUFenceID fid;
            memset(&fid, 0, sizeof(fid));
            fid.ctx_id = o->req_ctx_id;
            fid.ring_idx = o->req_ring_idx;
            fid.ring_valid = o->ring_valid ? 1u : 0u;
            fid.fence_id = o->req_fence_id;
            v->be->cancel_fence(v->be->opaque, &fid);
        }
        o->fence_registered = false;
        o->fence_done = true;   /* retire: the context it belonged to is gone */
    }
}

static void h_ctx_destroy(VirtIOGPU *v, VGCmd *c) {
    VGContext *cx = ctx_find(v, c->req_ctx_id);
    if (!cx) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID); return; }
    int rc = (v->be && v->be->ctx_destroy)
        ? v->be->ctx_destroy(v->be->opaque, c->req_ctx_id) : 0;
    ctx_cancel_fences(v, c->req_ctx_id);
    if (rc) { resp_rc(c, rc); return; }
    memset(cx, 0, sizeof(*cx));
    resp_ok(c);
}

static void h_ctx_resource(VirtIOGPU *v, VGCmd *c, const VGChain *ch, bool attach) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    if (!ctx_find(v, c->req_ctx_id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID); return; }
    if (!res_find(v, id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    int rc = 0;
    if (attach && v->be && v->be->ctx_attach_resource)
        rc = v->be->ctx_attach_resource(v->be->opaque, c->req_ctx_id, id);
    if (!attach && v->be && v->be->ctx_detach_resource)
        rc = v->be->ctx_detach_resource(v->be->opaque, c->req_ctx_id, id);
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_resource_create_3d(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    if (!feat_acked(v, VIRTIO_GPU_F_VIRGL)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u8 b[44];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    if (!id) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    struct virtio_gpu_resource_create_3d a;
    memset(&a, 0, sizeof(a));
    a.resource_id = id;
    a.target = rd32(b + 4); a.format = rd32(b + 8); a.bind = rd32(b + 12);
    a.width = rd32(b + 16); a.height = rd32(b + 20); a.depth = rd32(b + 24);
    a.array_size = rd32(b + 28); a.last_level = rd32(b + 32);
    a.nr_samples = rd32(b + 36); a.flags = rd32(b + 40);
    VGResource *r = res_alloc(v, id);
    if (!r) { resp_err(c, res_find(v, id) ? VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER
                                          : VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return; }
    r->kind = VG_RES_3D; r->width = a.width; r->height = a.height;
    r->format = a.format; r->ctx_id = c->req_ctx_id;
    int rc = (v->be && v->be->resource_create_3d)
        ? v->be->resource_create_3d(v->be->opaque, c->req_ctx_id, id, &a) : 0;
    if (rc) { r->in_use = false; resp_rc(c, rc); return; }
    resp_ok(c);
}

/* Stage `len` request bytes; the backend contract says the buffer is valid only
 * for the duration of the call, so one shared staging buffer per direction is
 * enough and bounds memory regardless of guest request size. */
static bool stage_payload(VirtIOGPU *v, const VGChain *ch, u64 off, u32 len,
                          u8 *buf, u32 cap) {
    (void)v;
    if (!len || len > cap) return false;
    return chain_read(v, ch, off, buf, len);
}

static void h_transfer_host_3d(VirtIOGPU *v, VGCmd *c, const VGChain *ch, bool to_host) {
    if (!feat_acked(v, VIRTIO_GPU_F_VIRGL)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u8 b[44];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_transfer_host_3d a;
    memset(&a, 0, sizeof(a));
    a.box.x = rd32(b); a.box.y = rd32(b+4); a.box.z = rd32(b+8);
    a.box.w = rd32(b+12); a.box.h = rd32(b+16); a.box.d = rd32(b+20);
    a.offset = rd64(b + 24);
    a.resource_id = rd32(b + 32); a.level = rd32(b + 36); a.stride = rd32(b + 40);
    if (!res_find(v, a.resource_id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (!a.box.w || !a.box.h) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    u64 bytes = (u64)a.box.w * a.box.h * (a.box.d ? a.box.d : 1u) * 4u;
    /* Bounded staging: over-cap transfers are refused, never truncated. */
    if (bytes > v->transfer_cap) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    int rc;
    if (to_host) {
        if (!stage_payload(v, ch, GPU_CTRL_HDR_LEN + 44u, (u32)bytes,
                           v->transfer_buf, v->transfer_cap)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
        }
        rc = (v->be && v->be->transfer_to_host_3d)
            ? v->be->transfer_to_host_3d(v->be->opaque, c->req_ctx_id, a.resource_id,
                                         &a, v->transfer_buf, (u32)bytes) : 0;
    } else {
        rc = (v->be && v->be->transfer_from_host_3d)
            ? v->be->transfer_from_host_3d(v->be->opaque, c->req_ctx_id, a.resource_id,
                                           &a, v->transfer_buf, (u32)bytes) : 0;
    }
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_submit_3d(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    if (!feat_acked(v, VIRTIO_GPU_F_VIRGL)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 size = rd32(b);
    if (!ctx_find(v, c->req_ctx_id)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID); return; }
    if (!size || size > v->submit_cap) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (GPU_CTRL_HDR_LEN + 8u + size > ch->rtotal) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;   /* short request */
    }
    if (!stage_payload(v, ch, GPU_CTRL_HDR_LEN + 8u, size, v->submit_buf, v->submit_cap)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return;
    }
    int rc = (v->be && v->be->submit_3d)
        ? v->be->submit_3d(v->be->opaque, c->req_ctx_id, v->submit_buf, size) : 0;
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void h_resource_create_blob(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    gpu_settle_budget(v);
    if (!feat_acked(v, VIRTIO_GPU_F_RESOURCE_BLOB)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u8 b[32];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b), blob_mem = rd32(b + 4), blob_flags = rd32(b + 8), nr = rd32(b + 12);
    u64 blob_id = rd64(b + 16), size = rd64(b + 24);
    if (!id || !size) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (blob_mem != VIRTIO_GPU_BLOB_MEM_GUEST &&
        blob_mem != VIRTIO_GPU_BLOB_MEM_HOST3D &&
        blob_mem != VIRTIO_GPU_BLOB_MEM_HOST3D_GUEST) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    if (blob_flags & ~(VIRTIO_GPU_BLOB_FLAG_USE_MAPPABLE |
                       VIRTIO_GPU_BLOB_FLAG_USE_SHAREABLE |
                       VIRTIO_GPU_BLOB_FLAG_USE_CROSS_DEVICE)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    if (blob_mem != VIRTIO_GPU_BLOB_MEM_GUEST) {
        /* HOST3D blob ids are created inside a Venus context. */
        if (!c->req_ctx_id || !ctx_find(v, c->req_ctx_id)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID); return;
        }
    }
    /* LOGICAL budget check on guest-requested bytes, page rounded. The host
     * backend owns the physical ledger; these numbers are never summed. */
    u64 charged = (size + FLOE_GPU_SHM_PAGE - 1) & ~(FLOE_GPU_SHM_PAGE - 1);
    if (charged < size || v->live_bytes + charged < v->live_bytes ||
        v->live_bytes + charged > v->budget_bytes) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return;
    }
    if (charged > FLOE_GPU_SHM_CAP) { resp_err(c, VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return; }
    struct iovec iov[GPU_MAX_IOV];
    u32 niov = 0; u64 total = 0;
    if (blob_mem == VIRTIO_GPU_BLOB_MEM_GUEST ||
        blob_mem == VIRTIO_GPU_BLOB_MEM_HOST3D_GUEST) {
        if (!nr || nr > GPU_MAX_IOV) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
        if (GPU_CTRL_HDR_LEN + 32u + (u64)nr * 16u > ch->rtotal) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
        }
        u8 entries[GPU_MAX_IOV * 16];
        if (!chain_read(v, ch, GPU_CTRL_HDR_LEN + 32u, entries, (u64)nr * 16u)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return;
        }
        if (!gpu_build_iov(v, entries, nr, iov, &niov, &total)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
        }
    } else if (nr) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;  /* HOST3D takes no entries */
    }
    VGResource *r = res_alloc(v, id);
    if (!r) { resp_err(c, res_find(v, id) ? VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER
                                          : VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY); return; }
    r->kind = VG_RES_BLOB; r->blob_mem = blob_mem; r->blob_flags = blob_flags;
    r->blob_id = blob_id; r->size = size; r->ctx_id = c->req_ctx_id;
    memcpy(r->iov, iov, sizeof(struct iovec) * niov);
    r->niov = niov; r->backing_len = total; r->backing_attached = (niov != 0);
    int rc = (v->be && v->be->resource_create_blob)
        ? v->be->resource_create_blob(v->be->opaque, c->req_ctx_id, id, blob_mem,
                                      blob_flags, blob_id, size,
                                      niov ? iov : NULL, niov, NULL, 0) : 0;
    if (rc) { r->in_use = false; resp_rc(c, rc); return; }
    r->charged = charged;
    v->live_bytes += charged;
    resp_ok(c);
}

static void h_set_scanout_blob(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[56];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_rect r = { rd32(b), rd32(b+4), rd32(b+8), rd32(b+12) };
    u32 scanout = rd32(b + 16), id = rd32(b + 20);
    u32 w = rd32(b + 24), h = rd32(b + 28), fmt = rd32(b + 32);
    u32 strides[4], offsets[4];
    for (int i = 0; i < 4; i++) strides[i] = rd32(b + 40u + (u32)i * 4u);
    for (int i = 0; i < 4; i++) offsets[i] = 0;   /* wire has 4 offsets after strides */
    u8 ob[16];
    if (chain_read(v, ch, GPU_CTRL_HDR_LEN + 56u, ob, sizeof(ob)))
        for (int i = 0; i < 4; i++) offsets[i] = rd32(ob + (u32)i * 4u);
    if (scanout >= v->num_scanouts) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID); return; }
    VGResource *res = res_find(v, id);
    if (!res || res->kind != VG_RES_BLOB) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (!w || !h || w > GPU_MAX_2D_DIM || h > GPU_MAX_2D_DIM || !valid_2d_format(fmt)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    if (!(res->blob_flags & VIRTIO_GPU_BLOB_FLAG_USE_MAPPABLE)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    int rc = (v->be && v->be->set_scanout_blob)
        ? v->be->set_scanout_blob(v->be->opaque, scanout, id, &r, w, h, fmt,
                                  strides, offsets) : 0;
    if (rc) { resp_rc(c, rc); return; }
    bool was = v->scanout_active;
    v->scanout_active = true; v->scanout_res = id;
    if (w != v->scanout_w || h != v->scanout_h) { v->scanout_w = w; v->scanout_h = h; gpu_build_edid(v); }
    if (!was) {
        v->events_read |= VIRTIO_GPU_EVENT_DISPLAY;
        v->isr |= 2u;
        gic_set_irq(v->gic, v->irq, 1);
    }
    resp_ok(c);
}

/* The driver owns the aperture allocator (a drm_mm over the shared region), so
 * the wire `offset` is the PLACEMENT of the whole blob inside the region, not
 * an offset into the resource. That distinction matters: the device maps the
 * ENTIRE resource at SHM_BASE + offset, validates offset against the aperture
 * CAPACITY (never the resource size), and asks the backend to map the resource
 * from ITS offset 0. Mapping adds backing to a former hole, which needs no TLB
 * flush and is published with a release store, so it is safe with workers live
 * and never has to be deferred. */
static void h_resource_map_blob(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    if (!feat_acked(v, VIRTIO_GPU_F_RESOURCE_BLOB)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u8 b[16];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    u64 off = rd64(b + 8);
    VGResource *r = res_find(v, id);
    if (!r || r->kind != VG_RES_BLOB) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (!(r->blob_flags & VIRTIO_GPU_BLOB_FLAG_USE_MAPPABLE)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    if (r->mapped || r->unmap_pending) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    if (off & (FLOE_GPU_SHM_PAGE - 1)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return; }
    /* The FULL resource maps at the placement offset: validate against the
     * aperture capacity (off + len <= CAP), not the resource size. */
    if (r->size > UINT64_MAX - (FLOE_GPU_SHM_PAGE - 1)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    u64 len = (r->size + FLOE_GPU_SHM_PAGE - 1) & ~(FLOE_GPU_SHM_PAGE - 1);
    if (!len || len > FLOE_GPU_SHM_CAP || off > FLOE_GPU_SHM_CAP - len) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
    }
    void *host = NULL; u64 host_len = 0;
    int rc = (v->be && v->be->resource_map_blob)
        ? v->be->resource_map_blob(v->be->opaque, r->ctx_id, id, /*blob_offset*/0, &host, &host_len)
        : FLOE_GPU_RESP_UNSPEC;
    if (rc) { resp_rc(c, rc); return; }
    if (host) {
        /* The backend exported real renderer pages. They must cover the WHOLE
         * mapping: a short backing is refused, never silently truncated into a
         * shifted alias where the guest and the renderer would see different
         * bytes for the same GPA. */
        u64 hl = host_len & ~(FLOE_GPU_SHM_PAGE - 1);
        if (!hl || hl < len) {
            if (v->be && v->be->resource_unmap_blob)
                v->be->resource_unmap_blob(v->be->opaque, id);
            resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER); return;
        }
        /* Linux reserves the guest-page-rounded blob length, independent of
         * the host's larger page size. Export enough real backing but map
         * exactly that guest span; host padding must not overlap the NEXT
         * blob's drm_mm placement (4 KiB guest vs 16 KiB Apple host pages). */
    }
    int mrc = floe_gpu_shm_map(v->m, FLOE_GPU_SHM_BASE + off, len, host);
    if (mrc != FLOE_REGION_OK) {
        if (host && v->be && v->be->resource_unmap_blob)
            v->be->resource_unmap_blob(v->be->opaque, id);
        resp_err(c, mrc == FLOE_REGION_EEXIST ? VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER
                                             : VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY);
        return;
    }
    r->mapped = true; r->backend_mapped = (host != NULL);
    r->map_off = off; r->map_len = len;
    resp_hdr(c, VIRTIO_GPU_RESP_OK_MAP_INFO);
    /* Write-combining: host-visible GPU memory is not cache-coherent with this
     * guest CPU model, and WC is what the Linux driver expects for virtio-gpu
     * host-visible blobs. */
    wr32(c->resp + c->resp_len, VIRTIO_GPU_MAP_CACHE_WC);
    wr32(c->resp + c->resp_len + 4, 0);
    c->resp_len += 8;
    c->resp_ready = true;
}

static void h_resource_unmap_blob(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[8];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, 8)) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    u32 id = rd32(b);
    VGResource *r = res_find(v, id);
    if (!r) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    if (r->unmap_pending) { resp_ok(c); return; }   /* already in flight */
    if (!r->mapped) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    int rc = floe_gpu_shm_unmap(v->m, FLOE_GPU_SHM_BASE + r->map_off, r->map_len);
    if (rc == FLOE_REGION_DEFERRED) {
        /* Hold BOTH the response and the renderer's pages: the segment is still
         * mapped, so freeing now would leave live CPU translations dangling. */
        if (!pend_add(v, id, r->backend_mapped, false, r->map_off, r->map_len, 0)) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY);
            return;
        }
        r->unmap_pending = true;
        request_quiesce(v);
        v->quiesce_pending_ops++;
        c->deferred = true;                     /* resp_ready stays false */
        return;
    }
    r->mapped = false; r->backend_mapped = false;
    if (rc == FLOE_REGION_OK && v->be && v->be->resource_unmap_blob)
        v->be->resource_unmap_blob(v->be->opaque, id);
    resp_ok(c);
}

/* Cursor queue: UPDATE_CURSOR carries a resource, MOVE_CURSOR only a position. */
static void h_cursor(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    u8 b[16];
    if (!chain_read(v, ch, GPU_CTRL_HDR_LEN, b, sizeof(b))) { resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return; }
    struct virtio_gpu_cursor_pos pos;
    pos.scanout_id = rd32(b); pos.x = rd32(b + 4); pos.y = rd32(b + 8); pos.padding = 0;
    u32 res = 0, hot_x = 0, hot_y = 0;
    if (c->req_type == VIRTIO_GPU_CMD_UPDATE_CURSOR) {
        u8 t[12];
        if (!chain_read(v, ch, GPU_CTRL_HDR_LEN + 16u, t, sizeof(t))) {
            resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); return;
        }
        res = rd32(t); hot_x = rd32(t + 4); hot_y = rd32(t + 8);
        if (res && !res_find(v, res)) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID); return; }
    }
    if (pos.scanout_id >= v->num_scanouts) { resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID); return; }
    int rc = 0;
    if (c->req_type == VIRTIO_GPU_CMD_UPDATE_CURSOR && v->be && v->be->update_cursor)
        rc = v->be->update_cursor(v->be->opaque, pos.scanout_id, res,
                                  (int32_t)hot_x, (int32_t)hot_y, &pos);
    else if (c->req_type == VIRTIO_GPU_CMD_MOVE_CURSOR && v->be && v->be->move_cursor)
        rc = v->be->move_cursor(v->be->opaque, pos.scanout_id, &pos);
    if (rc) { resp_rc(c, rc); return; }
    resp_ok(c);
}

static void gpu_dispatch(VirtIOGPU *v, VGCmd *c, const VGChain *ch) {
    v->stat_cmds++;
    switch (c->req_type) {
        case VIRTIO_GPU_CMD_GET_DISPLAY_INFO:        h_get_display_info(v, c); break;
        case VIRTIO_GPU_CMD_RESOURCE_CREATE_2D:      h_resource_create_2d(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_UNREF:          h_resource_unref(v, c, ch); break;
        case VIRTIO_GPU_CMD_SET_SCANOUT:             h_set_scanout(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_FLUSH:          h_resource_flush(v, c, ch); break;
        case VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D:     h_transfer_to_host_2d(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: h_attach_backing(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: h_detach_backing(v, c, ch); break;
        case VIRTIO_GPU_CMD_GET_CAPSET_INFO:         h_get_capset_info(v, c, ch); break;
        case VIRTIO_GPU_CMD_GET_CAPSET:              h_get_capset(v, c, ch); break;
        case VIRTIO_GPU_CMD_GET_EDID:                h_get_edid(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB:    h_resource_create_blob(v, c, ch); break;
        case VIRTIO_GPU_CMD_SET_SCANOUT_BLOB:        h_set_scanout_blob(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_MAP_BLOB:       h_resource_map_blob(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_UNMAP_BLOB:     h_resource_unmap_blob(v, c, ch); break;
        case VIRTIO_GPU_CMD_CTX_CREATE:              h_ctx_create(v, c, ch); break;
        case VIRTIO_GPU_CMD_CTX_DESTROY:             h_ctx_destroy(v, c); break;
        case VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE:     h_ctx_resource(v, c, ch, true); break;
        case VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE:     h_ctx_resource(v, c, ch, false); break;
        case VIRTIO_GPU_CMD_RESOURCE_CREATE_3D:      h_resource_create_3d(v, c, ch); break;
        case VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D:     h_transfer_host_3d(v, c, ch, true); break;
        case VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D:   h_transfer_host_3d(v, c, ch, false); break;
        case VIRTIO_GPU_CMD_SUBMIT_3D:               h_submit_3d(v, c, ch); break;
        case VIRTIO_GPU_CMD_UPDATE_CURSOR:
        case VIRTIO_GPU_CMD_MOVE_CURSOR:             h_cursor(v, c, ch); break;
        case VIRTIO_GPU_CMD_RESOURCE_ASSIGN_UUID:    /* feature not advertised */
        default:                                     resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC); break;
    }
    if (!c->resp_ready && !c->deferred) {
        /* A handler must always either stage a response or explicitly defer it
         * to the quiescent drain; never leave a command silently unanswered. */
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC);
    }
}

/* 3D-path commands whose fences the backend must track so an async renderer
 * signals the exact identity. Everything else completes inline. */
static bool cmd_needs_backend_fence(u32 type) {
    return type == VIRTIO_GPU_CMD_SUBMIT_3D ||
           type == VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D ||
           type == VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D;
}

/* --------------------------------------------------------------- pop */
/* Allocate STRICTLY at next_seq % GPU_MAX_INFLIGHT, inside a bounded window.
 *
 * The invariant gpu_retire() depends on is: the command holding submit_seq S
 * lives at inflight[S % GPU_MAX_INFLIGHT]. Reusing an inactive hole inside the
 * window would place a command at an index that does not match its sequence,
 * and gpu_retire() (which indexes by sequence) would then never find it: the
 * command becomes unretireable and has_work() spins forever. Because the window
 * is at most GPU_MAX_INFLIGHT sequences wide, index next_seq % MAX is always
 * free by construction; the active check is a defensive assertion of that. */
static VGCmd *gpu_cmd_alloc(VirtIOGPU *v) {
    if (v->next_seq - v->oldest_seq >= GPU_MAX_INFLIGHT) return NULL;  /* window full */
    VGCmd *c = &v->inflight[v->next_seq % GPU_MAX_INFLIGHT];
    if (c->active) return NULL;              /* bookkeeping invariant violated */
    return c;
}

static bool gpu_pop_one(VirtIOGPU *v, u32 qi) {
    VGQueue *q = &v->q[qi];
    if (!queue_spans(v, q)) return false;
    u16 avail = (u16)phys_read(v->m, q->avail + 2, 2);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    if (avail == q->last_avail) { q->notify_pending=false;return false; }
    if ((u16)(avail - q->last_avail) > q->num) { gpu_needs_reset(v); return false; }
    VGCmd *c = gpu_cmd_alloc(v);
    if (!c) return false;                        /* backpressure: stop popping */
    u16 head = (u16)phys_read(v->m, q->avail + 4 + (u64)(q->last_avail % q->num) * 2, 2);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    /* CONSUME the available-ring slot here, at successful accept, before the
     * command is dispatched and long before any async fence completes. If this
     * were done at publish time instead, a command held for a fence would be
     * re-read from the same avail slot on the next service pass and dispatched
     * again, duplicating work and pinning the coordinator at 100%. */
    q->last_avail++;
    VGChain ch;
    if (!gpu_chain_walk(v, q, head, &ch)) { v->stat_bad_chain++; gpu_needs_reset(v); return false; }
    u8 hdr[GPU_CTRL_HDR_LEN];
    if (!chain_read(v, &ch, 0, hdr, sizeof(hdr))) { v->stat_bad_chain++; gpu_needs_reset(v); return false; }
    memset(c, 0, sizeof(*c));
    c->active = true;
    c->queue = qi;
    c->head = head;
    c->submit_seq = v->next_seq++;
    c->req_type = rd32(hdr);
    c->req_flags = rd32(hdr + 4);
    c->req_fence_id = rd64(hdr + 8);
    c->req_ctx_id = rd32(hdr + 16);
    c->req_ring_idx = hdr[20];
    c->ring_valid = (c->req_flags & VIRTIO_GPU_FLAG_INFO_RING_IDX) != 0;
    c->timeline_ctx = c->req_ctx_id;
    c->timeline_ring = c->ring_valid ? (u8)c->req_ring_idx : 0xFFu;
    c->fenced = (c->req_flags & VIRTIO_GPU_FLAG_FENCE) != 0;
    c->nwrite = ch.nwrite;
    c->w_total = ch.wtotal;
    for (u32 i = 0; i < ch.nwrite; i++) {
        c->w_gpa[i] = ch.d[ch.widx[i]].gpa;
        c->w_len[i] = ch.d[ch.widx[i]].len;
    }
    v->inflight_count++;
    if (c->req_flags & ~(VIRTIO_GPU_FLAG_FENCE | VIRTIO_GPU_FLAG_INFO_RING_IDX)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER);
    } else if (ch.rtotal < GPU_CTRL_HDR_LEN) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER);
    } else if (qi == GPU_QUEUE_CURSOR &&
               c->req_type != VIRTIO_GPU_CMD_UPDATE_CURSOR &&
               c->req_type != VIRTIO_GPU_CMD_MOVE_CURSOR) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC);      /* wrong queue */
    } else if (qi == GPU_QUEUE_CTRL &&
               (c->req_type == VIRTIO_GPU_CMD_UPDATE_CURSOR ||
                c->req_type == VIRTIO_GPU_CMD_MOVE_CURSOR)) {
        resp_err(c, VIRTIO_GPU_RESP_ERR_UNSPEC);      /* wrong queue */
    } else {
        gpu_dispatch(v, c, &ch);
        if (c->fenced && c->resp_ready) {
            v->stat_fences++;
            if (cmd_needs_backend_fence(c->req_type) && v->be && v->be->create_fence) {
                FloeGPUFenceID fid;
                memset(&fid, 0, sizeof(fid));
                fid.ctx_id = c->req_ctx_id;
                fid.ring_idx = c->req_ring_idx;
                fid.ring_valid = c->ring_valid ? 1u : 0u;
                fid.fence_id = c->req_fence_id;
                int rc = v->be->create_fence(v->be->opaque, &fid);
                if (rc == 0) c->fence_registered = true;
                else c->fence_done = true;   /* backend declines: complete inline */
            } else {
                c->fence_done = true;        /* synchronous path */
            }
        } else if (c->fenced) {
            /* Deferred command: the fence is registered when the drain stages
             * the response, so identity order still matches submission order. */
            v->stat_fences++;
            c->fence_done = false;
        }
    }
    return true;
}

/* Can the coordinator make REAL progress right now?
 *
 * This must never be a self-referential latch: it is what the AE coordinator
 * loop turns into io_work, and a permanently-true answer would starve guest
 * execution. So it reads only genuine pending state, and an inflight command
 * counts only when it is actually publishable (staged, fence satisfied, and not
 * held behind an earlier command on its own ring timeline). A command waiting
 * on an outstanding fence therefore does NOT keep the loop spinning. */
bool virtio_gpu_has_work(struct VirtIOGPU *v) {
    if (!v) return false;
    if (v->needs_quiesce) return true;
    /* Let the guest observe/reset a failed device instead of starving its
     * CPUs on a doorbell that the failed transport can no longer consume. */
    if (v->status & VIRTIO_S_NEEDS_RESET) return false;
    if (atomic_load_explicit(&v->backend_signalled,memory_order_acquire)) return true;
    for (u32 i = 0; i < GPU_NUM_QUEUES; i++)
        if (v->q[i].notify_pending && gpu_cmd_alloc(v)) return true;
    if (atomic_load_explicit(&v->ring.head, memory_order_acquire) !=
        atomic_load_explicit(&v->ring.tail, memory_order_acquire)) return true;
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
        const VGCmd *c = &v->inflight[i];
        if (!c->active || !c->resp_ready) continue;
        if (c->fenced && !c->fence_done) continue;
        if (c->fenced && timeline_blocked(v, c)) continue;
        return true;
    }
    return false;
}

void virtio_gpu_service_fence_drain(struct VirtIOGPU *v) {
    if (!v) return;
    atomic_store_explicit(&v->backend_signalled,false,memory_order_release);
    if (v->be && v->be->poll) v->be->poll(v->be->opaque);
    gpu_drain_completions(v);
    gpu_retire(v);
}

void virtio_gpu_service(struct VirtIOGPU *v) {
    if (!v) return;
    /* Clear the notify latch FIRST, so the readiness recomputed at the end
     * reflects actual queue/completion state and can never re-latch itself. */
    v->work_pending = false;
    virtio_gpu_service_fence_drain(v);
    if (v->status & VIRTIO_S_NEEDS_RESET) { v->work_pending = false; return; }
    for (u32 qi = 0; qi < GPU_NUM_QUEUES; qi++) {
        VGQueue *q = &v->q[qi];
        if (!q->notify_pending) continue;
        /* Bounded per pass. A full inflight table stops popping (backpressure)
         * rather than dropping commands, and dispatch continues while earlier
         * fences are outstanding, so a pending fence can never stall the ring. */
        for (unsigned n = 0; n < GPU_MAX_INFLIGHT; n++) {
            if (!queue_spans(v, q)) { gpu_needs_reset(v); break; }
            if (!gpu_pop_one(v, qi)) break;
            gpu_retire(v);
            if (v->status & VIRTIO_S_NEEDS_RESET) break;
        }
        /* Clear only after observing an empty avail ring in gpu_pop_one.
         * A bounded pass or full window must retain the original doorbell;
         * completion retirement will make space without a new guest kick. */
    }
    gpu_retire(v);
    v->work_pending = virtio_gpu_has_work(v);
}

static void gpu_notify(VirtIOGPU *v, u32 qi) {
    if (qi < GPU_NUM_QUEUES) v->q[qi].notify_pending = true;
    v->work_pending = true;
    machine_owner_yield(v->m);   /* let the coordinator service promptly */
}

/* ---------------------------------------------------------------- MMIO */
static u64 gpu_config_read(VirtIOGPU *v, u64 off, unsigned size) {
    u8 cfg[16];
    wr32(cfg + 0, v->events_read);
    wr32(cfg + 4, 0);                 /* events_clear is write-only */
    wr32(cfg + 8, v->num_scanouts);
    wr32(cfg + 12, v->num_capsets);
    u64 r = 0;
    for (unsigned i = 0; i < size && off + i < sizeof(cfg); i++)
        r |= (u64)cfg[off + i] << (i * 8);
    return r;
}

static u64 gpu_read(void *opaque, u64 off, unsigned size) {
    VirtIOGPU *v = opaque;
    if (off >= 0x100) return gpu_config_read(v, off - 0x100, size);
    switch (off) {
        case 0x000: return 0x74726976;                  /* MagicValue "virt" */
        case 0x004: return 2;                           /* Version (modern)  */
        case 0x008: return GPU_DEVICE_ID;               /* DeviceID = gpu    */
        case 0x00c: return 0x554d4551;                  /* VendorID "QEMU"   */
        case 0x010:                                     /* DeviceFeatures */
            return v->dev_feat_sel == 1 ? (u32)(v->features >> 32)
                                        : (u32)(v->features & 0xffffffffu);
        case 0x034:                                     /* QueueNumMax */
            return v->queue_sel < GPU_NUM_QUEUES ? GPU_QUEUE_NUM_MAX : 0;
        case 0x044:                                     /* QueueReady */
            return v->queue_sel < GPU_NUM_QUEUES ? v->q[v->queue_sel].ready : 0;
        case 0x060: return v->isr;                      /* InterruptStatus */
        case 0x070: return v->status;                   /* Status */
        /* Shared memory region registers at the canonical Linux offsets. A
         * ShmId we do not implement reports an all-ones LENGTH (both halves),
         * which is how Linux vm_get_shm_region() detects "no such region";
         * reporting 0 would make the driver try to reserve a zero-length
         * host-visible region and fail the probe. */
        case VIRTIO_MMIO_SHM_LEN_LOW:                   /* 0x0b0 */
            return v->shm_sel == VIRTIO_GPU_SHM_ID_HOST_VISIBLE
                 ? (u32)(FLOE_GPU_SHM_CAP & 0xffffffffu) : 0xffffffffu;
        case VIRTIO_MMIO_SHM_LEN_HIGH:                  /* 0x0b4 */
            return v->shm_sel == VIRTIO_GPU_SHM_ID_HOST_VISIBLE
                 ? (u32)(FLOE_GPU_SHM_CAP >> 32) : 0xffffffffu;
        case VIRTIO_MMIO_SHM_BASE_LOW:                  /* 0x0b8 */
            return v->shm_sel == VIRTIO_GPU_SHM_ID_HOST_VISIBLE
                 ? (u32)(FLOE_GPU_SHM_BASE & 0xffffffffu) : 0;
        case VIRTIO_MMIO_SHM_BASE_HIGH:                 /* 0x0bc */
            return v->shm_sel == VIRTIO_GPU_SHM_ID_HOST_VISIBLE
                 ? (u32)(FLOE_GPU_SHM_BASE >> 32) : 0;
        case 0x0fc: return 0;                           /* ConfigGeneration */
        default:    return 0;
    }
}

static void gpu_queue_write(VirtIOGPU *v, u64 off, u32 v32) {
    if (v->queue_sel >= GPU_NUM_QUEUES) return;
    VGQueue *q = &v->q[v->queue_sel];
    switch (off) {
        case 0x038: q->num = v32 > GPU_QUEUE_NUM_MAX ? GPU_QUEUE_NUM_MAX : v32; break;
        case 0x044: q->ready = v32 ? true : false; break;
        case 0x080: q->desc  = (q->desc  & ~0xffffffffULL) | v32; break;
        case 0x084: q->desc  = (q->desc  &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x090: q->avail = (q->avail & ~0xffffffffULL) | v32; break;
        case 0x094: q->avail = (q->avail &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x0a0: q->used  = (q->used  & ~0xffffffffULL) | v32; break;
        case 0x0a4: q->used  = (q->used  &  0xffffffffULL) | ((u64)v32 << 32); break;
        default: break;
    }
}

static void gpu_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIOGPU *v = opaque;
    u32 v32 = (u32)val;
    (void)size;
    if (off == 0x104) {                        /* config: events_clear (WO) */
        v->events_read &= ~(u32)val;
        return;
    }
    if (off >= 0x100) return;                  /* rest of config is read-only */
    switch (off) {
        case 0x014: v->dev_feat_sel = v32; break;             /* DeviceFeaturesSel */
        case 0x020:                                             /* DriverFeatures */
            if (v->drv_feat_sel == 1)
                v->drv_feat = (v->drv_feat & 0xffffffffULL) | ((u64)v32 << 32);
            else
                v->drv_feat = (v->drv_feat & ~0xffffffffULL) | v32;
            break;
        case 0x024: v->drv_feat_sel = v32; break;             /* DriverFeaturesSel */
        case 0x030: v->queue_sel = v32; break;                /* QueueSel */
        case 0x050: gpu_notify(v, v32); break;                /* QueueNotify */
        case 0x064:                                             /* InterruptACK */
            v->isr &= ~(u32)val;
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:                                             /* Status */
            if (v32 == 0) { virtio_gpu_reset(v); }
            else {
                /* FEATURES_OK: refuse an unacceptable feature set by not
                 * latching the bit, exactly as virtio 1.3 section 2.1.2
                 * requires. VERSION_1 is mandatory for a modern device. */
                if ((v32 & VIRTIO_S_FEATURES_OK) &&
                    !(v->drv_feat & VIRTIO_F_VERSION_1)) {
                    v->status = v32 & ~VIRTIO_S_FEATURES_OK;
                } else if ((v32 & VIRTIO_S_FEATURES_OK) &&
                           (v->drv_feat & ~v->features)) {
                    v->status = v32 & ~VIRTIO_S_FEATURES_OK;   /* unsupported bit */
                } else {
                    v->status = v32;
                }
            }
            break;
        case VIRTIO_MMIO_SHM_SEL: v->shm_sel = v32; break;    /* ShmSel (WO) */
        case 0x038: case 0x044: case 0x080: case 0x084:
        case 0x090: case 0x094: case 0x0a0: case 0x0a4:
            gpu_queue_write(v, off, v32);
            break;
        default: break;
    }
}

/* ------------------------------------------------------------ lifecycle */
/* Begin a device-wide teardown (warm reboot reset, or destroy). Split into
 * two phases so that NOTHING the guest can still reach is ever freed early:
 *
 *   Phase A (here): cancel outstanding fences with the backend, request every
 *     aperture unmap, and RECORD what still needs releasing in the pending
 *     tables. When teardown runs with workers live (a reset reached through an
 *     MMIO write), an unmap defers, so the resource slot, its renderer pages
 *     and its context all survive until the real all-worker drain. Only
 *     resources with NO guest-visible mapping release immediately.
 *
 *   Phase B (virtio_gpu_quiesce_drain, at the documented all-worker quiescence
 *     point): perform the registry flush (TLB/JIT/monitor invalidation), then
 *     unmap_blob, then unref, then ctx_destroy, then reset the completion ring
 *     LAST, so no old-generation callback can be matched against a new command
 *     that reused the same (ctx, ring, fence_id) identity. */
static void gpu_release_all(VirtIOGPU *v, bool quiescent_ok) {
    v->teardown = true;
    /* Phase A.1: cancel outstanding fences so no late completion references a
     * released identity. The backend contract requires cancel_fence to
     * guarantee no later completion for that identity. */
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++) {
        VGCmd *c = &v->inflight[i];
        if (!c->active) continue;
        if (c->fenced && c->fence_registered && v->be && v->be->cancel_fence) {
            FloeGPUFenceID fid;
            memset(&fid, 0, sizeof(fid));
            fid.ctx_id = c->req_ctx_id; fid.ring_idx = c->req_ring_idx;
            fid.ring_valid = c->ring_valid ? 1u : 0u; fid.fence_id = c->req_fence_id;
            v->be->cancel_fence(v->be->opaque, &fid);
        }
        c->active = false;
    }
    v->inflight_count = 0;

    /* Phase A.2: aperture mappings + resources. */
    for (u32 i = 0; i < GPU_MAX_RESOURCES; i++) {
        VGResource *r = &v->res[i];
        if (!r->in_use) continue;
        if (r->mapped) {
            int rc = floe_gpu_shm_unmap(v->m, FLOE_GPU_SHM_BASE + r->map_off, r->map_len);
            if (rc == FLOE_REGION_DEFERRED) {
                /* Workers live: retain the WHOLE release (unmap_blob, detach,
                 * unref) until the drain. The slot stays reserved so its id
                 * cannot be reused while its pages are still reachable. */
                if (pend_add(v, r->id, r->backend_mapped, true, r->map_off,
                             r->map_len, r->charged)) {
                    r->unmap_pending = true;
                    v->needs_quiesce = true;
                    continue;
                }
                /* No room: keep everything alive rather than free early. */
                v->needs_quiesce = true;
                continue;
            }
            r->mapped = false; r->backend_mapped = false;
        }
        if (r->unmap_pending) { v->needs_quiesce = true; continue; }
        if (r->backing_attached && v->be && v->be->resource_detach_backing)
            v->be->resource_detach_backing(v->be->opaque, r->id);
        if (v->be && v->be->resource_unref) v->be->resource_unref(v->be->opaque, r->id);
        memset(r, 0, sizeof(*r));
    }

    /* Phase A.3: contexts. Defer ctx_destroy while anything is still mapped or
     * pending, because destroying a context can free its blobs' pages. */
    bool defer_ctx = v->needs_quiesce;
    for (u32 i = 0; i < GPU_MAX_CONTEXTS; i++) {
        if (!v->ctx[i].in_use) continue;
        if (defer_ctx) {
            for (u32 j = 0; j < GPU_MAX_CONTEXTS; j++) {
                if (v->pend_ctx[j].in_use) continue;
                v->pend_ctx[j].in_use = true; v->pend_ctx[j].ctx_id = v->ctx[i].id;
                break;
            }
            memset(&v->ctx[i], 0, sizeof(v->ctx[i]));
            continue;
        }
        if (v->be && v->be->ctx_destroy) v->be->ctx_destroy(v->be->opaque, v->ctx[i].id);
        memset(&v->ctx[i], 0, sizeof(v->ctx[i]));
    }

    /* Phase A.4: the completion-ring reset is part of the drain, not of the
     * immediate teardown, so a callback already in flight on a renderer thread
     * is drained (or discarded) rather than racing a reset buffer. */
    if (v->needs_quiesce) v->pend_ring_reset = true;
    if (quiescent_ok) virtio_gpu_quiesce_drain(v);
}

void virtio_gpu_reset(struct VirtIOGPU *v) {
    if (!v) return;
    /* No callback may arrive after this point for the old device generation. */
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0; v->shm_sel = 0;
    for (u32 i = 0; i < GPU_NUM_QUEUES; i++) {
        v->q[i].num = 0; v->q[i].ready = false;
        v->q[i].desc = v->q[i].avail = v->q[i].used = 0;
        v->q[i].last_avail = 0; v->q[i].notify_pending = false;
    }
    atomic_store(&v->ring.head, 0u);
    atomic_store(&v->ring.tail, 0u);
    for (u32 i = 0; i < GPU_FENCE_RING; i++)
        atomic_store(&v->ring.e[i].state, 0u);
    v->next_seq = v->oldest_seq = 0;
    v->events_read = 0;
    v->scanout_active = false; v->scanout_res = 0;
    v->work_pending = false;
    /* Reset happens through an MMIO write, i.e. possibly with workers live: the
     * aperture release may defer, and the drain finishes it when quiet. */
    gpu_release_all(v, machine_workers_quiescent(v->m));
    gpu_enumerate_capsets(v);
    if (v->gic) gic_set_irq(v->gic, v->irq, 0);
}

bool virtio_gpu_close_display(struct VirtIOGPU *v) {
    if (!v) return false;
    bool was = v->scanout_active;
    if (!was) return false;
    /* Release ONLY the scanout session. Contexts, submissions, outstanding
     * fences and mapped blobs are untouched, so closing the display never stops
     * GPU compute. */
    if (v->be && v->be->set_scanout) {
        struct virtio_gpu_rect none = { 0, 0, 0, 0 };
        v->be->set_scanout(v->be->opaque, 0, 0, &none);
    }
    v->scanout_active = false;
    v->scanout_res = 0;
    v->events_read |= VIRTIO_GPU_EVENT_DISPLAY;
    return true;
}

struct VirtIOGPU *virtio_gpu_create(Machine *m, GIC *gic,
                                    FloeVirtioGPUBackend *backend, int slot,
                                    const VirtIOGPUOptions *opts) {
    if (!m || slot < 0 || slot > 31) return NULL;
    VirtIOGPU *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0 + slot; v->slot = slot;
    v->be = backend;
    if (opts) v->opts = *opts; else memset(&v->opts, 0, sizeof(v->opts));
    if (!v->opts.budget_bytes) v->opts.budget_bytes = FLOE_GPU_DEFAULT_BUDGET;
    if (!v->opts.scanout_width) v->opts.scanout_width = 1280;
    if (!v->opts.scanout_height) v->opts.scanout_height = 800;
    if (!v->opts.max_transfer) v->opts.max_transfer = GPU_SUBMIT_MAX;
    if (v->opts.wake_fd == 0) v->opts.wake_fd = -1;
    v->budget_bytes = v->opts.budget_bytes;
    v->requested_budget = v->opts.budget_bytes;
    v->scanout_w = v->opts.scanout_width;
    v->scanout_h = v->opts.scanout_height;
    v->num_scanouts = 1;
    v->region_index = floe_gpu_shm_region_create(m);
    if (v->region_index < 0) { free(v); return NULL; }
    v->submit_cap = GPU_SUBMIT_MAX;
    v->submit_buf = malloc(v->submit_cap);
    v->transfer_cap = v->opts.max_transfer;
    v->transfer_buf = malloc(v->transfer_cap);
    if (!v->submit_buf || !v->transfer_buf) {
        free(v->submit_buf); free(v->transfer_buf); free(v);
        return NULL;
    }
    atomic_init(&v->backend_signalled, false);
    atomic_store(&v->cb_disabled, false);
    atomic_store(&v->cb_inflight, 0u);
    atomic_store(&v->ring.head, 0u);
    atomic_store(&v->ring.tail, 0u);
    v->guest_mem.opaque = v;
    v->guest_mem.resolve = gm_resolve;
    v->guest_mem.contig_len = gm_contig;
    v->guest_mem.is_shm_backed = gm_is_shm;
    gpu_build_edid(v);
    gpu_enumerate_capsets(v);
    gpu_compute_features(v);
    if (backend && backend->bind_transport) backend->bind_transport(backend->opaque, v);
    if (backend && backend->set_budget) {
        u64 actual=0,pending=0;
        if (backend->set_budget(backend->opaque,v->opts.budget_bytes,&actual,&pending)||!actual) {
            virtio_gpu_destroy(v);return NULL;
        }
        v->budget_bytes=actual;
    }
    u64 base = 0x0a000000ULL + (u64)slot * 0x200ULL;
    machine_add_device(m, base, 0x200, gpu_read, gpu_write, v, "virtio-gpu");
    return v;
}

void virtio_gpu_destroy(struct VirtIOGPU *v) {
    if (!v) return;
    /* Barrier first: after this returns no completion callback can be inside the
     * device or touch the wake fd, so the Bridge may close its pipe safely. */
    virtio_gpu_disable_callbacks(v);
    if (v->be && v->be->poll) v->be->poll(v->be->opaque);
    gpu_drain_completions(v);
    /* Teardown runs with the machine quiet, so aperture release is immediate. */
    gpu_release_all(v, true);
    if (v->gic) gic_set_irq(v->gic, v->irq, 0);
    if(v->be&&v->be->bind_transport) v->be->bind_transport(v->be->opaque,NULL);
    free(v->submit_buf); free(v->transfer_buf);
    free(v);
}

int virtio_gpu_set_budget(struct VirtIOGPU *v, u64 bytes,
                          u64 *actual_out, u64 *pending_target_out) {
    if (!v || !bytes) return -EINVAL;
    u64 actual = bytes, pending = 0;
    /* The host backend owns the physical ledger; ask it first so the effective
     * budget reflects real host headroom, then mirror the logical cap. */
    if (v->be && v->be->set_budget) {
        u64 ba = 0, bp = 0;
        if (v->be->set_budget(v->be->opaque, bytes, &ba, &bp) != 0) return -EIO;
        actual = ba ? ba : bytes;
        pending = bp;
    }
    if (bytes < v->live_bytes) {
        /* Lowering never reclaims active resources: the target applies once
        * occupancy drops, and we report both numbers honestly. */
        actual = v->live_bytes;
        pending = bytes;
    }
    v->budget_bytes = actual > v->live_bytes ? actual : v->live_bytes;
    v->requested_budget=bytes;
    u64 target=pending?pending:bytes;
    v->pending_target=v->budget_bytes>target?target:0;
    gpu_settle_budget(v);
    if (actual_out) *actual_out = v->budget_bytes;
    if (pending_target_out) *pending_target_out = v->pending_target;
    return 0;
}

void virtio_gpu_get_info(struct VirtIOGPU *v, VirtIOGPUInfo *out) {
    if (!v || !out) return;
    gpu_settle_budget(v);
    memset(out, 0, sizeof(*out));
    out->requested_budget=v->requested_budget;
    if(v->be&&v->be->get_usage) v->be->get_usage(v->be->opaque,&out->host_blob_bytes,&out->host_internal_bytes);
    out->budget_bytes = v->budget_bytes;
    out->pending_target = v->pending_target;
    out->live_bytes = v->live_bytes;
    out->num_capsets = v->num_capsets;
    out->num_scanouts = v->num_scanouts;
    out->resources = res_count(v);
    out->contexts = ctx_count(v);
    out->inflight = v->inflight_count;
    for (u32 i = 0; i < GPU_MAX_INFLIGHT; i++)
        if (v->inflight[i].active && v->inflight[i].fenced && !v->inflight[i].fence_done)
            out->fences_outstanding++;
    const MappedRegion *r = machine_region_at(v->m, v->region_index);
    if (r) {
        out->aperture_mapped = r->nseg_active;
        for (u32 i = 0; i < GPU_MAX_RESOURCES; i++)
            if (v->res[i].in_use && v->res[i].mapped) out->aperture_bytes += v->res[i].map_len;
    }
    out->features = v->features;
    out->status = v->status;
    out->isr = v->isr;
    out->needs_reset = (v->status & VIRTIO_S_NEEDS_RESET) != 0;
}

void floe_gpu_backend_set_failed(struct VirtIOGPU *v) {if(v) gpu_needs_reset(v);}

void floe_gpu_backend_notify(struct VirtIOGPU *v) {
    if(!v||atomic_load_explicit(&v->cb_disabled,memory_order_acquire)) return;
    atomic_fetch_add_explicit(&v->cb_inflight,1,memory_order_acq_rel);
    if(!atomic_load_explicit(&v->cb_disabled,memory_order_acquire)) {
        atomic_store_explicit(&v->backend_signalled,true,memory_order_release);
        if(v->opts.wake_fd>=0) {unsigned char byte=0;ssize_t wrote=write(v->opts.wake_fd,&byte,1);(void)wrote;}
    }
    atomic_fetch_sub_explicit(&v->cb_inflight,1,memory_order_acq_rel);
}

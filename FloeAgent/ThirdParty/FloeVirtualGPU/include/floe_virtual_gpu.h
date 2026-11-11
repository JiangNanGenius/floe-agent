/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* floe_virtual_gpu.h — FloeVirtualGPU host-side session ABI.
 *
 * This is the host package's own surface (owned by job-3b20af3971fb4693).
 * The transport-facing vtable is FloeVirtioGPUBackend, owned by the transport
 * package (ARM64EMU Bridge/virtio_gpu_backend.h); this session API is what a
 * Swift/native host or the qualification binary drives, and what the
 * FloeVirtioGPUBackend implementation is built on.
 *
 * Threading: every entry must be called on ONE thread (the machine
 * coordinator in App integration; the main thread in the qualification
 * binary). The only off-thread activity is internal renderer work whose
 * completions are queued and drained via floe_gpu_session_poll().
 */
#ifndef FLOE_VIRTUAL_GPU_H
#define FLOE_VIRTUAL_GPU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeGPUSession FloeGPUSession;

/* host-internal result codes (the transport adapter maps them onto
 * VIRTIO_GPU_RESP_ERR_* wire codes) */
#define FLOE_GPU_RESP_OK 0
#define FLOE_GPU_RESP_ERR_UNSPEC 1
#define FLOE_GPU_RESP_OUT_OF_MEMORY 2
#define FLOE_GPU_RESP_INVALID 3

struct floe_gpu_rect { uint32_t x, y, width, height; };

#define FLOE_GPU_DEFAULT_BUDGET_BYTES (1ull << 30) /* 1 GiB, user decision */

/* Completion token published by the renderer for one fenced submission.
 * Keyed by exact (ctx_id, ring_idx, fence_id) — never a global "later
 * retires earlier" sequence across timelines. */
typedef struct FloeGPUFenceCompletion {
    uint32_t ctx_id;
    uint32_t ring_idx;
    uint64_t fence_id;
} FloeGPUFenceCompletion;

/* Device/identity/capability report filled at create. */
typedef struct FloeGPUDeviceInfo {
    char device_name[256];
    char device_type[32];     /* integrated/discrete/virtual/cpu/other */
    char driver_info[256];    /* e.g. MoltenVK version, when available */
    uint32_t api_version;     /* Vulkan apiVersion of the physical device */
    uint32_t vendor_id, device_id;
    uint64_t host_heap_budget_bytes;   /* VK_EXT_memory_budget, 0 if absent */
    uint64_t host_heap_size_bytes;     /* VkMemoryHeap::size */
    uint32_t venus_capset_version;     /* actual version served, honest */
    uint32_t venus_capset_size;        /* sizeof(struct virgl_renderer_capset_venus) */
    uint32_t num_capsets;
    bool venus_enabled;
} FloeGPUDeviceInfo;

/* Budget state + set_budget result semantics (contract §2):
 *  - raise: applies to NEW allocations, clamped by real headroom.
 *    returns {requested, actual(=new limit), live, reason} — never lies.
 *  - lower: never reclaims active resources; if target < live the limit
 *    is still recorded but enforcement keeps live resources alive; result
 *    reports live + pending target. */
typedef struct FloeGPUBudgetResult {
    uint64_t requested_bytes;
    uint64_t actual_limit_bytes;  /* the limit now in force */
    uint64_t live_bytes;          /* current live host-device-memory bytes */
    uint64_t pending_target_bytes;/* if lower-than-live was requested: that target, else == actual */
    char reason[128];             /* "", "host-headroom", "clamped-by-capacity" */
} FloeGPUBudgetResult;

/* Split ledger (no double counting), all bytes page-aligned:
 *  - blob_bytes: renderer-owned HOST3D shm blob backing pages.
 *  - device_memory_bytes: VkDeviceMemory allocated by the renderer on this
 *    session, excluding aliased imports and excluding blob backing pages
 *    (those live in blob_bytes). A guest VkDeviceMemory imported over a
 *    renderer shm blob lands in aliased_guest_bytes, never here — the blob
 *    pages were already counted once in blob_bytes.
 *  - aliased_guest_bytes: device memory imported over guest-owned pages.
 *    Guest RAM; reported but NOT charged to the host GPU budget.
 *  - internal_other_bytes: host allocations we do not instrument (shader
 *    translation scratch, pipeline caches outside VkDeviceMemory, protocol
 *    buffers). Reported as an honest lower-bound, never claimed exact. */
typedef struct FloeGPUMemoryLedger {
    uint64_t blob_bytes;
    uint64_t device_memory_bytes;
    uint64_t aliased_guest_bytes;
    uint64_t internal_other_bytes;
} FloeGPUMemoryLedger;

/* Scanout pixmap: fields, not guesses (see host/CHECKPOINT §6). */
typedef struct FloeGPUScanout {
    uint32_t width, height;
    uint32_t stride_bytes;
    uint32_t format_fourcc;       /* ASCII e.g. 'XRGB' */
    bool top_down;
    const uint8_t *pixels;        /* backend-owned; valid until next call */
} FloeGPUScanout;

/* ---- lifecycle ------------------------------------------------------- */
/* Creates the session: inits the Venus renderer (pinned virglrenderer)
 * on top of the platform Vulkan (MoltenVK on Apple), with the default
 * 1 GiB budget. Returns NULL with *err filled on failure. */
FloeGPUSession *floe_gpu_session_create(const FloeGPUDeviceInfo **info,
                                        char *err, size_t err_size);
/* Sandboxed Apple App uses its ALREADY-entitled group namespace for SHM.
 * The identifier is supplied by trusted host configuration, never guest code. */
FloeGPUSession *floe_gpu_session_create_in_app_group(const FloeGPUDeviceInfo **info,
    const char *app_group,char *err,size_t err_size);
void floe_gpu_session_destroy(FloeGPUSession *s);

/* ---- caps ------------------------------------------------------------ */
int floe_gpu_num_capsets(FloeGPUSession *s);
int floe_gpu_get_capset_info(FloeGPUSession *s, uint32_t index,
                             uint32_t *capset_id, uint32_t *max_version,
                             uint32_t *max_size);
int floe_gpu_get_capset(FloeGPUSession *s, uint32_t capset_id,
                        uint32_t version, void *data, uint32_t *size);

/* ---- contexts (Venus) ------------------------------------------------ */
int floe_gpu_ctx_create(FloeGPUSession *s, uint32_t ctx_id,
                        uint32_t context_init, const char *debug_name);
int floe_gpu_ctx_destroy(FloeGPUSession *s, uint32_t ctx_id);
int floe_gpu_ctx_attach_resource(FloeGPUSession *s, uint32_t ctx_id,
                                 uint32_t res_id);
int floe_gpu_ctx_detach_resource(FloeGPUSession *s, uint32_t ctx_id,
                                 uint32_t res_id);

/* ---- resources ---------------------------------------------------------
 * create_blob: ctx-bound. HOST3D storage is allocated by the renderer and
 * returned as an fd + real host pointer and length (out_ptr/out_size).
 * The pointer is owned by the session; the transport maps its GPA region to
 * it (sparse aperture), no second copy. GUEST blobs consume host iovecs
 * (real host pointers+lengths of pinned guest RAM). */
int floe_gpu_resource_create_blob(FloeGPUSession *s, uint32_t ctx_id,
                                  uint32_t res_id, uint32_t blob_mem,
                                  uint32_t blob_flags, uint64_t blob_id,
                                  uint64_t size,
                                  const struct iovec *iov, uint32_t iov_count,
                                  void **out_ptr, uint64_t *out_size,
                                  int *out_fd);
int floe_gpu_resource_attach_iov(FloeGPUSession *s, uint32_t res_id,
                                 const struct iovec *iov, uint32_t iov_count);
int floe_gpu_resource_unref(FloeGPUSession *s, uint32_t res_id);

/* Transport-facing map export: returns the REAL host pointer+length of a
 * mappable blob (backend-owned; valid until resource_unmap_transport or
 * unref). This is what the device GPA aperture region aliases — no second
 * copy. */
int floe_gpu_resource_map_transport(FloeGPUSession *s, uint32_t res_id,
                                    uint64_t offset, void **host_ptr,
                                    uint64_t *host_len);
int floe_gpu_resource_unmap_transport(FloeGPUSession *s, uint32_t res_id);

/* ---- submission + fences ----------------------------------------------
 * submit hands an opaque Venus command stream to ctx. An exact
 * (ctx_id, ring_idx, fence_id) token retires this submission; completions
 * are queued and drained by poll. create_fence allows a fence without a
 * new command stream; the queue keeps accepting subsequent commands. */
int floe_gpu_submit(FloeGPUSession *s, uint32_t ctx_id,
                    const void *cmds, uint32_t size);
int floe_gpu_create_fence(FloeGPUSession *s, uint32_t ctx_id,
                          uint32_t ring_idx, uint64_t fence_id);
/* Drains queued completions into out (capacity n, returns count). */
uint32_t floe_gpu_poll(FloeGPUSession *s, FloeGPUFenceCompletion *out,
                       uint32_t n);
/* Non-zero once the bounded completion queue overflowed (fences can no
 * longer be delivered reliably). Never silent: adapters must surface this
 * as a device/context error, not drop the condition. */
int floe_gpu_completions_overflow(FloeGPUSession *s);
/* Bounded async wake notification; callback must not re-enter this session. */
void floe_gpu_set_completion_wake(FloeGPUSession *s,void (*notify)(void *),void *user);

/* ---- budget ------------------------------------------------------------ */
FloeGPUBudgetResult floe_gpu_set_budget(FloeGPUSession *s,
                                        uint64_t requested_bytes);
FloeGPUBudgetResult floe_gpu_get_budget(FloeGPUSession *s);
FloeGPUMemoryLedger floe_gpu_get_ledger(FloeGPUSession *s);

/* ---- scanout -------------------------------------------------------------
 * v1 serves an XRGB8888 top-down pixmap converted from the actual resource
 * layout into a backend-owned scratch buffer; closing a scanout releases
 * only scanout state, never compute contexts/resources. */
int floe_gpu_scanout_set(FloeGPUSession *s, uint32_t scanout_id,
                         uint32_t res_id, const struct floe_gpu_rect *r);
int floe_gpu_scanout_close(FloeGPUSession *s, uint32_t scanout_id);
int floe_gpu_scanout_snapshot(FloeGPUSession *s, uint32_t scanout_id,
                              FloeGPUScanout *out);

#ifdef __cplusplus
}
#endif
#endif /* FLOE_VIRTUAL_GPU_H */

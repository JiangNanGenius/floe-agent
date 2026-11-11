/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* FloeVirtioGPUBackend — narrow C ABI between the ARM64EMU virtio-gpu
 * transport device (Source/src/devices/virtio_gpu.c) and the host GPU
 * backend package (FloeVirtualGPU: virglrenderer Venus -> MoltenVK -> Metal).
 *
 * Implemented and owned by the host package (job-3b20af3971fb4693).
 * The transport (job-4fadfdf819f64fba) calls this vtable only.
 *
 * ============================================================================
 * THREADING CONTRACT (hard requirement)
 * ============================================================================
 *  - ->create/->destroy run on the machine coordinator thread, at machine
 *    construction / teardown (teardown only after the machine is quiet and
 *    all fences have been drained or cancelled).
 *  - Every other entry is ALSO called only on the coordinator thread, from
 *    virtio_gpu_service(). The backend may run its own worker threads.
 *  - The backend's ONLY cross-thread publication back to the transport is
 *    floe_gpu_backend_fence_complete(transport, ...) — an exact-identity
 *    completion that
 *    appends to a bounded lock-free queue and optionally writes one byte to
 *    the registered wake fd. It never touches guest memory, used rings or
 *    the GIC; all guest-visible publication happens on the coordinator
 *    inside virtio_gpu_service_fence_drain().
 *
 * ============================================================================
 * ZERO-COPY / WINDOW CONTRACT
 * ============================================================================
 *  The transport does NOT preallocate a contiguous Metal-visible buffer and
 *  does NOT assume the backend can wrap one. Venus HOST3D memory is allocated
 *  by vkr/Metal on the host side. The real pages are handed to the transport
 *  through ->resource_map_blob() (host_ptr + host_len), and the transport
 *  registers exactly that range at a guest-visible GPA inside the aperture
 *  (floe_gpu_shm_map with a caller-supplied host pointer = aliasing, not a
 *  copy). The transport never frees a backend-supplied pointer.
 *  If a backend instead wants the transport to own the pages (engine-anonymous
 *  backing), it returns host_ptr == NULL and ->resource_create_blob receives
 *  the transport-allocated window pointer via `shm`/`shm_offset`.
 *  Claiming noCopy equivalence between engine window pages and Metal pages is
 *  a HOST acceptance duty requiring same-physical-page proof; it is not
 *  asserted by this header.
 *
 * ============================================================================
 * FENCE CONTRACT
 * ============================================================================
 *  Fence identity is the exact triple (ctx_id, ring_idx, fence_id) taken from
 *  the wire ctrl_hdr. There is NO global monotonic sequence and NO cumulative
 *  retirement: completing a fence never implies completion of any other
 *  fence, on any timeline. A fence-tagged command's response is held until
 *  its exact identity is reported complete.
 *  The transport keeps dispatching later queue commands while earlier fences
 *  are outstanding, so a pending fence can never head-of-line-block the ring
 *  (Venus may need a later command to make progress). Ordered publication is
 *  maintained PER TIMELINE only: on one (ctx_id, ring_idx), a fence response
 *  is not published before every earlier fence_id on that same timeline has
 *  completed, because Linux signals all seqno <= fence_id on that timeline.
 *
 * Errors: entries return 0 on success or a VIRTIO_GPU_RESP_ERR_* code; the
 * transport maps them onto the wire. Entries never leave partial guest state
 * published. */
#ifndef FLOE_VIRTIO_GPU_BACKEND_H
#define FLOE_VIRTIO_GPU_BACKEND_H

#include <stdint.h>
#include <stddef.h>
#include <sys/uio.h>   /* struct iovec: what virglrenderer's resource layer
                        * consumes (src/virgl_resource.h), so no translation
                        * layer is needed host-side. */
#include "../Source/src/devices/virtio_gpu_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeVirtioGPUBackend FloeVirtioGPUBackend;
typedef struct FloeGPUGuestMem FloeGPUGuestMem;
struct VirtIOGPU;   /* opaque transport handle, passed back on completion */

/* Exact fence identity as it appears on the wire. Two fences are the same
 * fence only when all three fields match. */
typedef struct FloeGPUFenceID {
    uint32_t ctx_id;      /* 0 for non-3D / 2D-only timelines */
    uint8_t  ring_idx;    /* valid iff VIRTIO_GPU_FLAG_INFO_RING_IDX was set */
    uint8_t  ring_valid;  /* transport sets: ring_idx is meaningful */
    uint8_t  reserved[2];
    uint64_t fence_id;    /* guest-supplied per-timeline sequence */
} FloeGPUFenceID;

/* Guest scatter lists are passed as real `struct iovec` arrays: one entry per
 * bounds-validated contiguous host mapping of a guest range. The backend can
 * hand them straight to the renderer resource layer.
 *
 * LIFETIME: every iov_base is valid only while the machine is quiet and until
 * the owning resource is detached / unref'd / blob-unmapped, or the queue,
 * device or machine is reset. The transport keeps the entries pinned for that
 * window; backends that need them longer must copy or re-resolve through
 * FloeGPUGuestMem.
 *
 * POINTER VALIDITY for command/data buffers (submit_3d, transfer_*_3d): the
 * buffer is valid only for the duration of that single call. The backend must
 * copy or consume synchronously what it needs (vkr_renderer_submit_cmd decodes
 * into its own ring, so this matches the pinned renderer).
 */

/* Guest memory service provided BY the transport TO the backend.
 * Pointers obtained here are valid only while the machine is quiet and until
 * the owning resource is detached / unref'd / blob-unmapped, or the queue,
 * device or machine is reset. Backends must not cache them across those
 * events; re-resolve instead. */
struct FloeGPUGuestMem {
    void *opaque;         /* transport-owned; pass back unchanged */
    /* Resolve [gpa, gpa+len) to one contiguous host pointer.
     * 0 on success; negative errno (-EINVAL/-EFAULT) when unmapped or
     * crossing a region boundary. */
    int (*resolve)(FloeGPUGuestMem *self, uint64_t gpa, uint64_t len,
                   void **host_ptr);
    /* Contiguous mapped byte count starting at gpa (0 = unmapped). Lets a
     * backend walk a scatter list without repeated failing resolves. */
    uint64_t (*contig_len)(FloeGPUGuestMem *self, uint64_t gpa);
    /* True when [gpa, gpa+len) is inside the GPU shared aperture and backed. */
    int (*is_shm_backed)(FloeGPUGuestMem *self, uint64_t gpa, uint64_t len);
};

/* Scanout pixmap snapshot for the host display entrypoint. Field-carrying, not
 * a fixed guess (host CHECKPOINT §6): the backend fills the ACTUAL layout of
 * the flushed resource and, when that layout differs from the wire order,
 * converts into its own scratch buffer and says so via pixel_format/flags.
 * pixels is backend-owned and valid until the next backend call. */
enum FloeGPUPixelFormat {
    FLOE_GPU_PIX_XRGB8888 = 0,   /* wire B8G8R8A8_UNORM, 4 bytes/px */
    FLOE_GPU_PIX_XBGR8888 = 1,   /* wire R8G8B8A8_UNORM, 4 bytes/px */
    FLOE_GPU_PIX_RGBA8888 = 2,   /* host-native RGBA byte order     */
};
enum {
    FLOE_GPU_PIX_F_TOP_DOWN = 1u << 0,  /* row 0 is the top scanline */
    FLOE_GPU_PIX_F_CONVERTED = 1u << 1, /* backend converted into scratch */
};
typedef struct FloeGPUScanoutPixmap {
    uint32_t width, height;
    uint32_t stride_bytes;    /* >= width * bytes_per_pixel */
    uint32_t pixel_format;    /* enum FloeGPUPixelFormat */
    uint32_t flags;           /* FLOE_GPU_PIX_F_* */
    const uint8_t *pixels;
} FloeGPUScanoutPixmap;

/* Declared capability flags a backend may report (mirrors the wire feature
 * bits the transport may then advertise). The transport advertises only the
 * intersection of these with what it actually implements. */
#define FLOE_GPU_CAP_VIRGL          (1u << 0)  /* 3D ctx + submit path      */
#define FLOE_GPU_CAP_EDID           (1u << 1)
#define FLOE_GPU_CAP_RESOURCE_BLOB  (1u << 2)  /* blobs + host-visible shm   */
#define FLOE_GPU_CAP_CONTEXT_INIT   (1u << 3)  /* ctx create with capset id  */
#define FLOE_GPU_CAP_SCANOUT_BLOB   (1u << 4)

struct FloeVirtioGPUBackend {
    void *opaque;

    /* Called once by the transport right after the backend is attached. Store
     * `transport` and pass it back verbatim to
     * floe_gpu_backend_fence_complete(); it is opaque to the backend. */
    void (*bind_transport)(void *opaque, struct VirtIOGPU *transport);

    /* ---- capability / caps ------------------------------------------------
     * The transport never hardcodes a capset list: it enumerates exactly what
     * the backend reports (a Venus-only backend exports only Venus id 4).
     * caps_flags returns the FLOE_GPU_CAP_* set actually served. */
    uint32_t (*caps_flags)(void *opaque);
    uint32_t (*num_capsets)(void *opaque);
    int (*get_capset_info)(void *opaque, uint32_t capset_index,
                           uint32_t *capset_id, uint32_t *max_version,
                           uint32_t *max_size);
    /* Copies up to *size bytes of capset (id, version) into data; *size is
     * updated to the actual length. Report the true max_version. */
    int (*get_capset)(void *opaque, uint32_t capset_id, uint32_t version,
                      void *data, uint32_t *size);

    /* ---- budget ledger (host CHECKPOINT §5) ---------------------------------
     * The HOST backend owns the authoritative physical budget: a session quota
     * with a blob ledger plus an internal (non-glob) Vulkan ledger. The
     * transport keeps only a LOGICAL record of guest-requested bytes and must
     * never add its number to the backend's physical usage.
     * set_budget: raise applies to new allocations clamped by real host heap
     * headroom; lower NEVER reclaims active resources and reports actual plus
     * the pending target that applies once occupancy drops.
     * get_usage fills the backend's own split ledger (either pointer optional).
     * Returns 0 or negative errno. */
    int (*set_budget)(void *opaque, uint64_t bytes,
                      uint64_t *actual_out, uint64_t *pending_target_out);
    int (*get_usage)(void *opaque, uint64_t *blob_bytes_out,
                     uint64_t *internal_bytes_out);

    /* ---- contexts (3D / Venus) --------------------------------------------
     * context_init carries VIRTIO_GPU_CONTEXT_INIT_CAPSET_ID_MASK; ctx_id is
     * the wire ctx_id and scopes every later blob_id / fence on that context. */
    int (*ctx_create)(void *opaque, uint32_t ctx_id, uint32_t context_init,
                      const char *debug_name, uint32_t nlen);
    int (*ctx_destroy)(void *opaque, uint32_t ctx_id);
    int (*ctx_attach_resource)(void *opaque, uint32_t ctx_id, uint32_t resource_id);
    int (*ctx_detach_resource)(void *opaque, uint32_t ctx_id, uint32_t resource_id);

    /* ---- resources --------------------------------------------------------- */
    int (*resource_create_2d)(void *opaque, uint32_t resource_id,
                              uint32_t format, uint32_t width, uint32_t height);
    int (*resource_create_3d)(void *opaque, uint32_t ctx_id, uint32_t resource_id,
                              const struct virtio_gpu_resource_create_3d *args);
    int (*resource_unref)(void *opaque, uint32_t resource_id);

    /* Validated scatter list: iov/niov were bounds-checked by the transport
     * against guest RAM and the GPU aperture, total_len is their sum.
     * guest_mem lets the backend re-resolve or extend mappings later under
     * the lifetime rules above. The transport keeps the entries pinned until
     * detach/unref/reset. */
    int (*resource_attach_backing)(void *opaque, uint32_t resource_id,
                                   const struct iovec *iov, uint32_t niov,
                                   uint64_t total_len,
                                   FloeGPUGuestMem *guest_mem);
    int (*resource_detach_backing)(void *opaque, uint32_t resource_id);
    int (*transfer_to_host_2d)(void *opaque, uint32_t resource_id,
                               const struct virtio_gpu_rect *r, uint64_t offset);

    /* ---- blobs ---------------------------------------------------------------
     * ctx_id scopes blob_id exactly as Venus/vkr expects (HOST3D blob ids are
     * created inside a context). For BLOB_MEM_GUEST, iov/niov describe the
     * already-validated guest ranges. For BLOB_MEM_HOST3D, shm/shm_offset are
     * non-NULL only when the transport owns the pages; a backend that
     * allocates its own memory ignores them and exports pages later through
     * ->resource_map_blob. */
    int (*resource_create_blob)(void *opaque, uint32_t ctx_id, uint32_t resource_id,
                                uint32_t blob_mem, uint32_t blob_flags,
                                uint64_t blob_id, uint64_t size,
                                const struct iovec *iov, uint32_t niov,
                                void *shm, uint64_t shm_offset);

    /* Export the real host pages of a mappable blob so the transport can
     * register them at a guest-visible GPA. *host_ptr/*host_len are filled by
     * the backend; *host_ptr == NULL asks the transport to back the range with
     * engine-anonymous pages instead. blob_offset is the guest-requested
     * offset inside the resource. The transport page-aligns the registration
     * and reports the chosen aperture offset in the wire response. */
    int (*resource_map_blob)(void *opaque, uint32_t ctx_id, uint32_t resource_id,
                             uint64_t blob_offset,
                             void **host_ptr, uint64_t *host_len);
    /* Release the backend-side mapping. Called AFTER the transport has
     * unregistered and TLB/JIT-invalidated the GPA range, so no guest access
     * can still be in flight to those pages. */
    int (*resource_unmap_blob)(void *opaque, uint32_t resource_id);

    /* ---- 3D transfer / submission ---------------------------------------------
     * data/data_size describe the transport-staged bytes for the box; the
     * transport stages guest RAM into a bounded buffer and never exposes raw
     * guest pointers across an await. */
    int (*transfer_to_host_3d)(void *opaque, uint32_t ctx_id, uint32_t resource_id,
                               const struct virtio_gpu_transfer_host_3d *args,
                               const void *data, uint32_t data_size);
    int (*transfer_from_host_3d)(void *opaque, uint32_t ctx_id, uint32_t resource_id,
                                 const struct virtio_gpu_transfer_host_3d *args,
                                 void *data, uint32_t data_size);
    int (*submit_3d)(void *opaque, uint32_t ctx_id, const void *cmds, uint32_t size);

    /* ---- fences ---------------------------------------------------------------
     * Register an outstanding fence for the exact identity. The backend must
     * eventually report that identity complete (or the transport cancels it on
     * reset/destroy, after which a late completion is ignored). Fence-tagged
     * commands that need no async work may skip registration and complete
     * inline; the transport decides. */
    int (*create_fence)(void *opaque, const FloeGPUFenceID *id);
    /* Called by the transport on reset/destroy/unref so the backend can drop
     * tracking for an identity it will never complete. */
    void (*cancel_fence)(void *opaque, const FloeGPUFenceID *id);
    /* Drain completions and any other backend state the transport must observe
     * before it waits. Coordinator thread only. */
    void (*poll)(void *opaque);

    /* ---- scanout / cursor ------------------------------------------------------- */
    int (*set_scanout)(void *opaque, uint32_t scanout_id, uint32_t resource_id,
                       const struct virtio_gpu_rect *r);
    int (*set_scanout_blob)(void *opaque, uint32_t scanout_id, uint32_t resource_id,
                            const struct virtio_gpu_rect *r, uint32_t width,
                            uint32_t height, uint32_t format,
                            const uint32_t strides[4], const uint32_t offsets[4]);
    int (*flush)(void *opaque, uint32_t resource_id, const struct virtio_gpu_rect *r);
    int (*update_cursor)(void *opaque, uint32_t scanout_id, uint32_t resource_id,
                         int32_t hot_x, int32_t hot_y,
                         const struct virtio_gpu_cursor_pos *pos);
    int (*move_cursor)(void *opaque, uint32_t scanout_id,
                       const struct virtio_gpu_cursor_pos *pos);
    int (*get_scanout_pixmap)(void *opaque, uint32_t scanout_id,
                              FloeGPUScanoutPixmap *out);

    void (*destroy)(void *opaque);
    /* Optional authoritative snapshot. Target may be below actual while live
     * allocations await release; requested preserves the user's preference. */
    int (*get_budget)(void *opaque,uint64_t *requested,uint64_t *actual,uint64_t *target);
};

/* Native host construction only. The app passes its existing entitled group
 * before renderer workers start; the emulator never grants a new entitlement. */
/* Crosses two Clang targets. Keep these symbols external when SwiftPM's
 * relocatable-link step localizes the other hidden implementation symbols. */
#if defined(__GNUC__)
#define FLOE_GPU_BACKEND_API __attribute__((visibility("default")))
#else
#define FLOE_GPU_BACKEND_API
#endif
FLOE_GPU_BACKEND_API FloeVirtioGPUBackend *floe_virtual_gpu_backend_create(char *err, size_t err_size);
FLOE_GPU_BACKEND_API FloeVirtioGPUBackend *floe_virtual_gpu_backend_create_in_app_group(
    const char *app_group, char *err, size_t err_size);

/* Backend -> transport completion for ONE exact fence identity. Safe from any
 * backend thread at any time: appends to a bounded completion queue and writes
 * one byte to the wake fd when one is registered. Returns 0, or -EAGAIN when
 * the bounded queue is full (the transport drains on its next service pass and
 * the backend should retry; a dropped completion would stall that timeline). */
/* Coordinator-only fatal backend condition; guest sees NEEDS_RESET. */
FLOE_GPU_BACKEND_API void floe_gpu_backend_set_failed(struct VirtIOGPU *transport);
/* Thread-safe work notification through the same callback/fd lifetime barrier. */
FLOE_GPU_BACKEND_API void floe_gpu_backend_notify(struct VirtIOGPU *transport);

FLOE_GPU_BACKEND_API int floe_gpu_backend_fence_complete(struct VirtIOGPU *transport,
                                    uint32_t ctx_id, uint8_t ring_idx,
                                    uint8_t ring_valid, uint64_t fence_id);

#ifdef __cplusplus
}
#endif
#endif /* FLOE_VIRTIO_GPU_BACKEND_H */

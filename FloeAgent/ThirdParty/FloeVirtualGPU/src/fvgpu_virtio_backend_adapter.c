/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_virtio_backend_adapter.c — implements the transport-owned
 * FloeVirtioGPUBackend vtable (virtio_gpu_backend.h, v2) on top of the
 * FloeVirtualGPU session API.
 *
 * The transport header is owned by the transport package; this file is
 * compiled with -I pointing at its Bridge directory (see Makefile).
 *
 * Lifecycle contract (hard, from the transport header):
 *  - every vtable call runs on the machine coordinator thread;
 *  - ->destroy disables completion enqueue and joins renderer threads
 *    (floe_gpu_session_destroy -> vkr_renderer_fini) BEFORE returning; after
 *    that this adapter holds no wake fd and no session pointer;
 *  - fences are exact (ctx_id, ring_idx, fence_id) identities; there is no
 *    global monotonic sequence: completing one fence never retires another;
 *  - completions: renderer retire callbacks enqueue into the bounded session
 *    queue (4096; overflow -> floe_gpu_completions_overflow()); poll() drains
 *    and forwards each exact identity via the transport-provided
 *    floe_gpu_backend_fence_complete(). -EAGAIN means the transport queue is
 *    full: the identity is kept and retried on the next poll (never dropped);
 *  - monotonically unique private tokens make cancellation/reset delivery
 *    safe even if a later guest command reuses the same fence identity. */
#include "floe_virtual_gpu.h"

/* transport-owned header (do not copy into this package) */
#include "virtio_gpu_backend.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    FloeVirtioGPUBackend base;   /* must be first: returned as the vtable */
    FloeGPUSession *session;
    struct VirtIOGPU *transport;
    uint64_t next_fence_token;
    struct { bool used;uint64_t token;FloeGPUFenceID id; } fences[4096];
    bool holding_completion;
    FloeGPUFenceCompletion completion;
} FVGpuBackendAdapter;

/* ---- capability / caps -------------------------------------------------- */
static uint32_t
fvgpu_ad_caps_flags(void *opaque)
{
    (void)opaque;
    return FLOE_GPU_CAP_VIRGL | FLOE_GPU_CAP_RESOURCE_BLOB |
           FLOE_GPU_CAP_CONTEXT_INIT;
}

static uint32_t
fvgpu_ad_num_capsets(void *opaque)
{
    FVGpuBackendAdapter *a = opaque;
    return (uint32_t)floe_gpu_num_capsets(a->session);
}

static int
fvgpu_ad_get_capset_info(void *opaque, uint32_t index, uint32_t *capset_id,
                         uint32_t *max_version, uint32_t *max_size)
{
    FVGpuBackendAdapter *a = opaque;
    return floe_gpu_get_capset_info(a->session, index, capset_id, max_version, max_size);
}

static int
fvgpu_ad_get_capset(void *opaque, uint32_t capset_id, uint32_t version,
                    void *data, uint32_t *size)
{
    FVGpuBackendAdapter *a = opaque;
    return floe_gpu_get_capset(a->session, capset_id, version, data, size);
}

/* ---- budget ledger -------------------------------------------------------
 * Host backend owns the authoritative physical budget (host CHECKPOINT §5);
 * the transport keeps only a logical record. */
static int
fvgpu_ad_set_budget(void *opaque, uint64_t bytes,
                    uint64_t *actual_out, uint64_t *pending_target_out)
{
    FVGpuBackendAdapter *a = opaque;
    FloeGPUBudgetResult r = floe_gpu_set_budget(a->session, bytes);
    if (actual_out)
        *actual_out = r.actual_limit_bytes;
    if (pending_target_out)
        *pending_target_out = r.pending_target_bytes;
    return 0;
}

static int
fvgpu_ad_get_usage(void *opaque, uint64_t *blob_bytes_out,
                   uint64_t *internal_bytes_out)
{
    FVGpuBackendAdapter *a = opaque;
    FloeGPUMemoryLedger l = floe_gpu_get_ledger(a->session);
    if (blob_bytes_out)
        *blob_bytes_out = l.blob_bytes;
    if (internal_bytes_out)
        *internal_bytes_out = l.device_memory_bytes;
    return 0;
}

static int fvgpu_ad_get_budget(void *opaque,uint64_t *requested,uint64_t *actual,uint64_t *target) {
    FVGpuBackendAdapter *a=opaque;FloeGPUBudgetResult r=floe_gpu_get_budget(a->session);
    if(requested) *requested=r.requested_bytes;
    if(actual) *actual=r.actual_limit_bytes;
    if(target) *target=r.pending_target_bytes;
    return 0;
}

/* ---- contexts ------------------------------------------------------------ */
static int
fvgpu_ad_ctx_create(void *opaque, uint32_t ctx_id, uint32_t context_init,
                    const char *debug_name, uint32_t nlen)
{
    FVGpuBackendAdapter *a = opaque;
    char name[64] = {0};
    if (debug_name && nlen)
        snprintf(name, sizeof(name), "%.*s", (int)(nlen < 63 ? nlen : 63), debug_name);
    return floe_gpu_ctx_create(a->session, ctx_id, context_init, name);
}

static int
fvgpu_ad_ctx_destroy(void *opaque, uint32_t ctx_id)
{
    FVGpuBackendAdapter *a = opaque;
    for(unsigned i=0;i<4096;i++) if(a->fences[i].used&&a->fences[i].id.ctx_id==ctx_id) a->fences[i].used=false;
    return floe_gpu_ctx_destroy(a->session, ctx_id);
}

static int
fvgpu_ad_ctx_attach(void *opaque, uint32_t ctx_id, uint32_t res_id)
{
    FVGpuBackendAdapter *a = opaque;
    return floe_gpu_ctx_attach_resource(a->session, ctx_id, res_id);
}

static int
fvgpu_ad_ctx_detach(void *opaque, uint32_t ctx_id, uint32_t res_id)
{
    FVGpuBackendAdapter *a = opaque;
    return floe_gpu_ctx_detach_resource(a->session, ctx_id, res_id);
}

/* ---- resources ------------------------------------------------------------ */
static int
fvgpu_ad_res_create_2d(void *opaque, uint32_t res_id, uint32_t format,
                       uint32_t width, uint32_t height)
{
    (void)opaque; (void)res_id; (void)format; (void)width; (void)height;
    return VIRTIO_GPU_RESP_ERR_UNSPEC; /* no 2D/GL path in venus-only renderer */
}

static int
fvgpu_ad_res_create_3d(void *opaque, uint32_t ctx_id, uint32_t res_id,
                       const struct virtio_gpu_resource_create_3d *args)
{
    (void)opaque; (void)ctx_id; (void)res_id; (void)args;
    return VIRTIO_GPU_RESP_ERR_UNSPEC;
}

static int
fvgpu_ad_res_unref(void *opaque, uint32_t res_id)
{
    FVGpuBackendAdapter *a = opaque;
    return floe_gpu_resource_unref(a->session, res_id);
}

static int
fvgpu_ad_res_attach_backing(void *opaque, uint32_t res_id,
                            const struct iovec *iov, uint32_t niov,
                            uint64_t total_len, FloeGPUGuestMem *guest_mem)
{
    FVGpuBackendAdapter *a = opaque;
    (void)total_len; (void)guest_mem;
    if (!iov || !niov)
        return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    return floe_gpu_resource_attach_iov(a->session, res_id, iov, niov);
}

static int
fvgpu_ad_res_detach_backing(void *opaque, uint32_t res_id)
{
    (void)opaque; (void)res_id;
    return 0;
}

static int
fvgpu_ad_transfer_to_host_2d(void *opaque, uint32_t res_id,
                             const struct virtio_gpu_rect *r, uint64_t offset)
{
    (void)opaque; (void)res_id; (void)r; (void)offset;
    return VIRTIO_GPU_RESP_ERR_UNSPEC;
}

/* ---- blobs ----------------------------------------------------------------
 * HOST3D storage is allocated by the renderer; the transport only learns the
 * real pages through resource_map_blob. GUEST blobs pass validated iovecs.
 */
static int
fvgpu_ad_res_create_blob(void *opaque, uint32_t ctx_id, uint32_t res_id,
                         uint32_t blob_mem, uint32_t blob_flags,
                         uint64_t blob_id, uint64_t size,
                         const struct iovec *iov, uint32_t niov,
                         void *shm, uint64_t shm_offset)
{
    FVGpuBackendAdapter *a = opaque;
    (void)shm; (void)shm_offset; /* v1: renderer owns HOST3D pages */
    void *ptr = NULL;
    uint64_t psz = 0;
    int pfd = -1;
    int rc = floe_gpu_resource_create_blob(a->session, ctx_id, res_id,
                                           blob_mem, blob_flags, blob_id, size,
                                           iov, niov, &ptr, &psz, &pfd);
    if (rc == FLOE_GPU_RESP_OUT_OF_MEMORY)
        return VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
    if (rc == FLOE_GPU_RESP_INVALID)
        return VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID;
    if (rc != FLOE_GPU_RESP_OK)
        return VIRTIO_GPU_RESP_ERR_UNSPEC;
    return 0;
}

static int
fvgpu_ad_res_map_blob(void *opaque, uint32_t ctx_id, uint32_t res_id,
                      uint64_t blob_offset, void **host_ptr, uint64_t *host_len)
{
    FVGpuBackendAdapter *a = opaque;
    (void)ctx_id;
    int rc = floe_gpu_resource_map_transport(a->session, res_id, blob_offset,
                                             host_ptr, host_len);
    if (rc == FLOE_GPU_RESP_INVALID)
        return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    if (rc != FLOE_GPU_RESP_OK)
        return VIRTIO_GPU_RESP_ERR_UNSPEC;
    return 0;
}

static int
fvgpu_ad_res_unmap_blob(void *opaque, uint32_t res_id)
{
    FVGpuBackendAdapter *a = opaque;
    int rc = floe_gpu_resource_unmap_transport(a->session, res_id);
    return rc == FLOE_GPU_RESP_OK ? 0 : VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
}

/* ---- 3D transfer / submission ---------------------------------------------- */
static int
fvgpu_ad_transfer_to_host_3d(void *opaque, uint32_t ctx_id, uint32_t res_id,
                             const struct virtio_gpu_transfer_host_3d *args,
                             const void *data, uint32_t data_size)
{
    (void)opaque; (void)ctx_id; (void)res_id; (void)args; (void)data; (void)data_size;
    return VIRTIO_GPU_RESP_ERR_UNSPEC; /* transfers ride the Venus stream */
}

static int
fvgpu_ad_transfer_from_host_3d(void *opaque, uint32_t ctx_id, uint32_t res_id,
                               const struct virtio_gpu_transfer_host_3d *args,
                               void *data, uint32_t data_size)
{
    (void)opaque; (void)ctx_id; (void)res_id; (void)args; (void)data; (void)data_size;
    return VIRTIO_GPU_RESP_ERR_UNSPEC;
}

static int
fvgpu_ad_submit_3d(void *opaque, uint32_t ctx_id, const void *cmds, uint32_t size)
{
    FVGpuBackendAdapter *a = opaque;
    int rc = floe_gpu_submit(a->session, ctx_id, cmds, size);
    if (rc == FLOE_GPU_RESP_INVALID)
        return VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID;
    if (rc != FLOE_GPU_RESP_OK)
        return VIRTIO_GPU_RESP_ERR_UNSPEC;
    return 0;
}

/* ---- fences ----------------------------------------------------------------- */
static bool same_fence(const FloeGPUFenceID *a,const FloeGPUFenceID *b) {
    return a->ctx_id==b->ctx_id&&a->ring_valid==b->ring_valid&&
        (!a->ring_valid||a->ring_idx==b->ring_idx)&&a->fence_id==b->fence_id;
}
static int fvgpu_ad_create_fence(void *opaque,const FloeGPUFenceID *id) {
    FVGpuBackendAdapter *a=opaque;unsigned slot=4096;
    for(unsigned i=0;i<4096;i++) {
        if(a->fences[i].used&&same_fence(&a->fences[i].id,id)) return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        if(!a->fences[i].used&&slot==4096) slot=i;
    }
    if(slot==4096||a->next_fence_token==UINT64_MAX) return VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
    uint64_t token=++a->next_fence_token;
    a->fences[slot].id=*id;a->fences[slot].token=token;a->fences[slot].used=true;
    int rc=floe_gpu_create_fence(a->session,id->ctx_id,id->ring_valid?id->ring_idx:0,token);
    if(rc!=FLOE_GPU_RESP_OK) a->fences[slot].used=false;
    return rc==FLOE_GPU_RESP_OK?0:VIRTIO_GPU_RESP_ERR_UNSPEC;
}
static void fvgpu_ad_cancel_fence(void *opaque,const FloeGPUFenceID *id) {
    FVGpuBackendAdapter *a=opaque;
    for(unsigned i=0;i<4096;i++) if(a->fences[i].used&&same_fence(&a->fences[i].id,id)) a->fences[i].used=false;
    /* Underlying tokens never reuse a guest ID after reset. Renderer callbacks
     * only reach this coordinator poll, so cancel is a hard delivery barrier. */
}
static void fvgpu_ad_poll(void *opaque) {
    FVGpuBackendAdapter *a=opaque;
    if(!a->transport) return;
    if(floe_gpu_completions_overflow(a->session)) {floe_gpu_backend_set_failed(a->transport);return;}
    for(unsigned work=0;work<256;work++) {
        if(!a->holding_completion) {
            if(!floe_gpu_poll(a->session,&a->completion,1)) return;
            a->holding_completion=true;
        }
        unsigned slot=4096;
        for(unsigned i=0;i<4096;i++) if(a->fences[i].used&&
            a->fences[i].token==a->completion.fence_id&&
            a->fences[i].id.ctx_id==a->completion.ctx_id&&
            (a->fences[i].id.ring_valid?a->fences[i].id.ring_idx:0)==a->completion.ring_idx) {slot=i;break;}
        if(slot==4096) {a->holding_completion=false;continue;} /* cancelled old token */
        const FloeGPUFenceID *id=&a->fences[slot].id;
        int rc=floe_gpu_backend_fence_complete(a->transport,id->ctx_id,id->ring_idx,id->ring_valid,id->fence_id);
        if(rc==-EAGAIN) return; /* keep it; transport drains after poll returns */
        if(rc) {floe_gpu_backend_set_failed(a->transport);return;}
        a->fences[slot].used=false;a->holding_completion=false;
    }
}

/* ---- scanout / cursor --------------------------------------------------------- */
static int
fvgpu_ad_set_scanout(void *opaque, uint32_t scanout_id, uint32_t res_id,
                     const struct virtio_gpu_rect *r)
{
    FVGpuBackendAdapter *a = opaque;
    struct floe_gpu_rect fr = { r->x, r->y, r->width, r->height };
    int rc = floe_gpu_scanout_set(a->session, scanout_id, res_id, &fr);
    if (rc == FLOE_GPU_RESP_INVALID)
        return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    return rc == FLOE_GPU_RESP_OK ? 0 : VIRTIO_GPU_RESP_ERR_UNSPEC;
}

static int
fvgpu_ad_set_scanout_blob(void *opaque, uint32_t scanout_id, uint32_t res_id,
                          const struct virtio_gpu_rect *r, uint32_t width,
                          uint32_t height, uint32_t format,
                          const uint32_t strides[4], const uint32_t offsets[4])
{
    (void)opaque; (void)scanout_id; (void)res_id; (void)r; (void)width;
    (void)height; (void)format; (void)strides; (void)offsets;
    return VIRTIO_GPU_RESP_ERR_UNSPEC; /* display path lands with zink */
}

static int
fvgpu_ad_flush(void *opaque, uint32_t res_id, const struct virtio_gpu_rect *r)
{
    (void)opaque; (void)res_id; (void)r;
    return 0;
}

static int
fvgpu_ad_update_cursor(void *opaque, uint32_t scanout_id, uint32_t res_id,
                       int32_t hot_x, int32_t hot_y,
                       const struct virtio_gpu_cursor_pos *pos)
{
    (void)opaque; (void)scanout_id; (void)res_id; (void)hot_x; (void)hot_y; (void)pos;
    return 0;
}

static int
fvgpu_ad_move_cursor(void *opaque, uint32_t scanout_id,
                     const struct virtio_gpu_cursor_pos *pos)
{
    (void)opaque; (void)scanout_id; (void)pos;
    return 0;
}

static int
fvgpu_ad_get_scanout_pixmap(void *opaque, uint32_t scanout_id,
                            FloeGPUScanoutPixmap *out)
{
    FVGpuBackendAdapter *a = opaque;
    FloeGPUScanout sc = {0};
    int rc = floe_gpu_scanout_snapshot(a->session, scanout_id, &sc);
    if (rc != FLOE_GPU_RESP_OK)
        return VIRTIO_GPU_RESP_ERR_UNSPEC;
    out->width = sc.width;
    out->height = sc.height;
    out->stride_bytes = sc.stride_bytes;
    out->pixel_format = FLOE_GPU_PIX_XRGB8888;
    out->flags = FLOE_GPU_PIX_F_TOP_DOWN;
    out->pixels = sc.pixels;
    return 0;
}

static void
fvgpu_ad_destroy(void *opaque)
{
    FVGpuBackendAdapter *a = opaque;
    /* hard contract: session destroy unbinds callbacks, drains completions,
     * destroys resources/contexts and joins renderer threads
     * (vkr_renderer_fini) before returning; afterwards we hold nothing the
     * transport could close or reuse (no wake fd, no session pointer). */
    floe_gpu_session_destroy(a->session);
    a->session = NULL;
    a->transport = NULL;
    free(a);
}

static void fvgpu_ad_notify(void *opaque) {
    FVGpuBackendAdapter *a=opaque;if(a->transport) floe_gpu_backend_notify(a->transport);
}

static void
fvgpu_ad_bind_transport(void *opaque, struct VirtIOGPU *transport)
{
    FVGpuBackendAdapter *a = opaque;
    /* Detach under the callback mutex before changing its borrowed target. */
    floe_gpu_set_completion_wake(a->session,NULL,NULL);
    a->transport = transport;
    if(transport) floe_gpu_set_completion_wake(a->session,fvgpu_ad_notify,a);
}

/* Backend factory: the transport calls this on the coordinator thread at
 * machine start, then ->bind_transport(). */
static FloeVirtioGPUBackend *
create_backend(const char *app_group, char *err, size_t err_size)
{
    FVGpuBackendAdapter *a = calloc(1, sizeof(*a));
    if (!a) {
        snprintf(err, err_size, "oom");
        return NULL;
    }
    const FloeGPUDeviceInfo *info = NULL;
    a->session = floe_gpu_session_create_in_app_group(&info, app_group, err, err_size);
    if (!a->session) {
        free(a);
        return NULL;
    }
    a->base = (FloeVirtioGPUBackend){
        .opaque = a,
        .bind_transport = fvgpu_ad_bind_transport,
        .caps_flags = fvgpu_ad_caps_flags,
        .num_capsets = fvgpu_ad_num_capsets,
        .get_capset_info = fvgpu_ad_get_capset_info,
        .get_capset = fvgpu_ad_get_capset,
        .set_budget = fvgpu_ad_set_budget,
        .get_usage = fvgpu_ad_get_usage,
        .ctx_create = fvgpu_ad_ctx_create,
        .ctx_destroy = fvgpu_ad_ctx_destroy,
        .ctx_attach_resource = fvgpu_ad_ctx_attach,
        .ctx_detach_resource = fvgpu_ad_ctx_detach,
        .resource_create_2d = fvgpu_ad_res_create_2d,
        .resource_create_3d = fvgpu_ad_res_create_3d,
        .resource_unref = fvgpu_ad_res_unref,
        .resource_attach_backing = fvgpu_ad_res_attach_backing,
        .resource_detach_backing = fvgpu_ad_res_detach_backing,
        .transfer_to_host_2d = fvgpu_ad_transfer_to_host_2d,
        .resource_create_blob = fvgpu_ad_res_create_blob,
        .resource_map_blob = fvgpu_ad_res_map_blob,
        .resource_unmap_blob = fvgpu_ad_res_unmap_blob,
        .transfer_to_host_3d = fvgpu_ad_transfer_to_host_3d,
        .transfer_from_host_3d = fvgpu_ad_transfer_from_host_3d,
        .submit_3d = fvgpu_ad_submit_3d,
        .create_fence = fvgpu_ad_create_fence,
        .cancel_fence = fvgpu_ad_cancel_fence,
        .poll = fvgpu_ad_poll,
        .set_scanout = fvgpu_ad_set_scanout,
        .set_scanout_blob = fvgpu_ad_set_scanout_blob,
        .flush = fvgpu_ad_flush,
        .update_cursor = fvgpu_ad_update_cursor,
        .move_cursor = fvgpu_ad_move_cursor,
        .get_scanout_pixmap = fvgpu_ad_get_scanout_pixmap,
        .destroy = fvgpu_ad_destroy,
        .get_budget = fvgpu_ad_get_budget,
    };
    return &a->base;
}

FloeVirtioGPUBackend *
floe_virtual_gpu_backend_create(char *err, size_t err_size)
{
    return create_backend(NULL, err, err_size);
}

FloeVirtioGPUBackend *
floe_virtual_gpu_backend_create_in_app_group(const char *app_group,
                                           char *err, size_t err_size)
{
    return create_backend(app_group, err, err_size);
}

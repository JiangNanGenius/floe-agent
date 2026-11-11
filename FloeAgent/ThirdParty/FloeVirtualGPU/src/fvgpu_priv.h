/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_priv.h — private session state shared by the component sources. */
#ifndef FVGPU_PRIV_H
#define FVGPU_PRIV_H

#include "floe_virtual_gpu.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>

#include <vulkan/vulkan.h>
#include <virgl/virglrenderer.h>
#include <virgl/vkr_renderer.h>
#include <virgl/venus_hw.h>
#include <virgl/vkr_accounting.h>

#define FVGPU_MAX_CONTEXTS 64

/* host-internal result codes (public names in floe_virtual_gpu.h) */
#define FVGPU_RESP_OK FLOE_GPU_RESP_OK
#define FVGPU_RESP_ERR_UNSPEC FLOE_GPU_RESP_ERR_UNSPEC
#define FVGPU_RESP_OUT_OF_MEMORY FLOE_GPU_RESP_OUT_OF_MEMORY
#define FVGPU_RESP_INVALID FLOE_GPU_RESP_INVALID

struct fvgpu_resource_entry {
    uint32_t res_id;
    uint32_t ctx_id;   /* creating context (exact ownership; joint fix H6 —
                        * unref/destroy must target THIS ctx, never the first
                        * live one) */
    bool used;
    bool is_blob;
    bool creator_alive;
    /* Renderer-owned backing. The fd + blob_size lifetime belongs to the
     * resource (released only at unref/destroy) and is SEPARATE from the
     * transport alias mapping below (joint fix H7: transport unmap must not
     * drop the fd, so the same live resource can be mapped again). */
    int fd;             /* shm fd for HOST3D, -1 else */
    uint64_t blob_size; /* renderer blob size as created */
    uint64_t accounting_key; /* retained until every host fd/alias is gone */
    uint64_t context_mask;   /* exact live context slots, cleared at destroy */
    enum virgl_resource_fd_type fd_type;
    /* Transport alias mapping of `fd` (lazy mmap). NULL while unmapped. */
    void *ptr;
    uint64_t size;   /* mapping length (page-aligned) */
};

struct fvgpu_context_entry {
    uint32_t ctx_id;
    bool used;
};

struct fvgpu_completion_node {
    FloeGPUFenceCompletion c;
    struct fvgpu_completion_node *next;
};

struct FloeGPUSession {
    FloeGPUDeviceInfo info;
    /* Budget state. Mutated by set_budget (coordinator thread) AND by the
     * renderer-thread free/settle path (pending-lower convergence, joint fix
     * H3), so every read/write is under ledger_lock. */
    struct {
        uint64_t limit_bytes;        /* limit in force */
        uint64_t requested_bytes;    /* last requested */
        uint64_t target_bytes;       /* admission ceiling, including pending lower */
        uint64_t pending_lower_bytes;/* a below-live target awaiting release, 0 if none */
        bool pending;
        bool clamped;
    } budget;

    /* split ledger (see public header): written by the renderer accounting
     * hook callback (any renderer thread) and by this session; guarded. */
    pthread_mutex_t ledger_lock;
    FloeGPUMemoryLedger ledger;
    uint64_t capacity_max_bytes; /* configured ceiling for raises */

    /* Atomic quota admission (joint fix H2). reserved_bytes is the sum of
     * in-flight admissions that have not settled into the ledger yet:
     *  - renderer vkAllocateMemory admissions (any renderer thread), and
     *  - the coordinator-thread HOST3D blob create reservation.
     * Admission checks live + reserved + request against the effective limit
     * under ledger_lock, so concurrent allocations can never over-commit the
     * budget between the check and the real allocation. Both are guarded by
     * ledger_lock. */
    uint64_t reserved_bytes;
    uint64_t blob_resv_bytes;  /* in-flight blob create reservation (coordinator thread only) */

    /* host device memory attributed to our session by the vkr hook */
    pthread_mutex_t devmem_lock;
    struct fvgpu_devmem_node *devmem; /* list of live VkDeviceMemory wrappers */

    struct fvgpu_context_entry contexts[FVGPU_MAX_CONTEXTS];
    struct fvgpu_resource_entry resources[512];
    pthread_mutex_t res_lock;

    /* completion queue: renderer thread enqueues, coordinator drains */
    pthread_mutex_t comp_lock;
    pthread_cond_t comp_cond;
    struct fvgpu_completion_node *comp_head, *comp_tail;
    uint32_t comp_depth;
    bool comp_stopping;
    bool comp_overflow;
    void (*completion_wake)(void *);
    void *completion_wake_user;

    struct {
        bool active;
        uint32_t res_id;
        struct floe_gpu_rect rect;
        uint8_t *scratch;      /* XRGB8888 converted pixmap */
        uint32_t scratch_size;
        uint32_t width, height;
    } scanout;
};

/* fvgpu_ledger.c */
void fvgpu_ledger_init(FloeGPUSession *s);
void fvgpu_ledger_fini(FloeGPUSession *s);
uint64_t fvgpu_ledger_live(FloeGPUSession *s);
/* Renderer hooks use explicit session ownership; no unguarded globals. */
bool fvgpu_ledger_reserve(FloeGPUSession *s, uint64_t size, bool aliased);
void fvgpu_ledger_cancel(FloeGPUSession *s, uint64_t size, bool aliased);
void fvgpu_ledger_event(FloeGPUSession *s, uint64_t size, bool aliased, bool blob, bool alloc);
uint64_t fvgpu_live_locked(FloeGPUSession *s);
void fvgpu_budget_settle_locked(FloeGPUSession *s);
bool fvgpu_host_headroom(uint64_t *available);

/* fvgpu_contexts.c */
bool fvgpu_context_exists(FloeGPUSession *s, uint32_t ctx_id);
int fvgpu_context_add(FloeGPUSession *s, uint32_t ctx_id);
void fvgpu_context_remove(FloeGPUSession *s, uint32_t ctx_id);
void fvgpu_contexts_destroy_all(FloeGPUSession *s);

/* fvgpu_completion.c — called from renderer threads; must stay async-safe
 * (queue + optional wake only; never touches guest memory). */
void fvgpu_enqueue_completion(uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id);
void fvgpu_completion_queue_destroy(FloeGPUSession *s);
int floe_gpu_completions_overflow(FloeGPUSession *s);

/* fvgpu_resources.c */
void fvgpu_resources_destroy_all(FloeGPUSession *s);
struct fvgpu_resource_entry *fvgpu_resource_find(FloeGPUSession *s, uint32_t res_id);
void fvgpu_resource_remove(FloeGPUSession *s, uint32_t res_id);

/* fvgpu_completion.c */
void fvgpu_bind_current_session(FloeGPUSession *s);

/* fvgpu_budget.c */
FloeGPUBudgetResult fvgpu_budget_set(FloeGPUSession *s, uint64_t requested);

#endif /* FVGPU_PRIV_H */

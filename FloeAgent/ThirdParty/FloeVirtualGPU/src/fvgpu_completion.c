/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_completion.c — exact (ctx_id, ring_idx, fence_id) completion queue.
 *
 * Lifecycle (per coordinator integration contract):
 *  - bounded capacity: a fence is never silently dropped (a guest would wait
 *    forever). On overflow the session enters an explicit error state visible
 *    via floe_gpu_completions_overflow(); the adapter maps that to a device
 *    context reset, not to silent loss.
 *  - destroy: enqueue is disabled BEFORE vkr_renderer_fini() joins renderer
 *    threads, so no callback can touch session state after destroy returns.
 *  - this session never holds the transport wake fd; wake-up wiring lives in
 *    the FloeVirtioGPUBackend adapter (transport-owned). */
#include "fvgpu_priv.h"

#include <stdlib.h>

/* transport pending-fence bound; coordinator-aligned */
#define FVGPU_COMPLETION_CAPACITY 4096

/* The current session for the enqueue path. The pinned renderer is a
 * process-wide singleton (render-server-mode=thread), so the callback uses
 * the current session. NULL before create/after destroy -> late callbacks
 * are dropped only after the queue is stopped (post-destroy contract). */
static FloeGPUSession *fvgpu_current;
static pthread_mutex_t current_lock=PTHREAD_MUTEX_INITIALIZER;

void
fvgpu_bind_current_session(FloeGPUSession *s)
{
    pthread_mutex_lock(&current_lock);fvgpu_current=s;pthread_mutex_unlock(&current_lock);
}

void floe_gpu_set_completion_wake(FloeGPUSession *s,void (*notify)(void *),void *user) {
    pthread_mutex_lock(&s->comp_lock);s->completion_wake=notify;s->completion_wake_user=user;pthread_mutex_unlock(&s->comp_lock);
}
void fvgpu_enqueue_completion(uint32_t ctx,uint32_t ring,uint64_t fence) {
    pthread_mutex_lock(&current_lock);
    FloeGPUSession *s=fvgpu_current;
    if(!s) {pthread_mutex_unlock(&current_lock);return;}
    pthread_mutex_lock(&s->comp_lock);
    if(!s->comp_stopping) {
        struct fvgpu_completion_node *n=s->comp_depth<FVGPU_COMPLETION_CAPACITY?malloc(sizeof(*n)):NULL;
        if(n) {
            n->c=(FloeGPUFenceCompletion){.ctx_id=ctx,.ring_idx=ring,.fence_id=fence};n->next=NULL;
            if(s->comp_tail) s->comp_tail->next=n;else s->comp_head=n;
            s->comp_tail=n;s->comp_depth++;
        } else s->comp_overflow=true;
        pthread_cond_signal(&s->comp_cond);
        /* Without this, all-WFI Linux can sleep forever: its coordinator has
         * no reason to poll our private completion queue after GPU retirement. */
        if(s->completion_wake) s->completion_wake(s->completion_wake_user);
    }
    pthread_mutex_unlock(&s->comp_lock);pthread_mutex_unlock(&current_lock);
}

uint32_t
floe_gpu_poll(FloeGPUSession *s, FloeGPUFenceCompletion *out, uint32_t n)
{
    uint32_t count = 0;
    pthread_mutex_lock(&s->comp_lock);
    while (s->comp_head && count < n) {
        struct fvgpu_completion_node *head = s->comp_head;
        s->comp_head = head->next;
        if (!s->comp_head)
            s->comp_tail = NULL;
        s->comp_depth--;
        if (out) out[count]=head->c;
        count++;
        free(head);
    }
    pthread_mutex_unlock(&s->comp_lock);
    return count;
}

int
floe_gpu_completions_overflow(FloeGPUSession *s)
{
    int v;
    pthread_mutex_lock(&s->comp_lock);
    v = s->comp_overflow ? 1 : 0;
    pthread_mutex_unlock(&s->comp_lock);
    return v;
}

void
fvgpu_completion_queue_destroy(FloeGPUSession *s)
{
    /* disable enqueue first: after this point renderer callbacks (incl. late
     * reset tokens) are dropped, and vkr_renderer_fini() joins renderer
     * threads before session free. */
    pthread_mutex_lock(&s->comp_lock);
    s->comp_stopping = true;
    struct fvgpu_completion_node *n = s->comp_head;
    while (n) {
        struct fvgpu_completion_node *next = n->next;
        free(n);
        n = next;
    }
    s->comp_head = s->comp_tail = NULL;
    s->comp_depth = 0;
    pthread_cond_broadcast(&s->comp_cond);
    pthread_mutex_unlock(&s->comp_lock);
}

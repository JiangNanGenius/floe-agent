/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_contexts.c + ledger — small record keepers. */
#include "fvgpu_priv.h"

#include <stdlib.h>
#include <assert.h>
#include <string.h>

bool
fvgpu_context_exists(FloeGPUSession *s, uint32_t ctx_id)
{
    for (uint32_t i = 0; i < FVGPU_MAX_CONTEXTS; i++)
        if (s->contexts[i].used && s->contexts[i].ctx_id == ctx_id)
            return true;
    return false;
}

int
fvgpu_context_add(FloeGPUSession *s, uint32_t ctx_id)
{
    for (uint32_t i = 0; i < FVGPU_MAX_CONTEXTS; i++) {
        if (!s->contexts[i].used) {
            s->contexts[i].used = true;
            s->contexts[i].ctx_id = ctx_id;
            return 0;
        }
    }
    return -1;
}

void
fvgpu_context_remove(FloeGPUSession *s, uint32_t ctx_id)
{
    for (uint32_t i = 0; i < FVGPU_MAX_CONTEXTS; i++)
        if (s->contexts[i].used && s->contexts[i].ctx_id == ctx_id)
            s->contexts[i].used = false;
}

void
fvgpu_contexts_destroy_all(FloeGPUSession *s)
{
    for (uint32_t i = 0; i < FVGPU_MAX_CONTEXTS; i++) {
        if (s->contexts[i].used) {
            floe_gpu_ctx_destroy(s,s->contexts[i].ctx_id);
        }
    }
}

/* Quota reservations and settlement. All callbacks retain the session until
 * vkr_renderer_fini has joined its workers and hooks are detached. */
uint64_t fvgpu_live_locked(FloeGPUSession *s) {
    return s->ledger.blob_bytes+s->ledger.device_memory_bytes;
}
void fvgpu_ledger_init(FloeGPUSession *s) {
    pthread_mutex_init(&s->ledger_lock,NULL);
    pthread_mutex_init(&s->devmem_lock,NULL);
}
void fvgpu_ledger_fini(FloeGPUSession *s) {
    pthread_mutex_destroy(&s->devmem_lock);
    pthread_mutex_destroy(&s->ledger_lock);
}
uint64_t fvgpu_ledger_live(FloeGPUSession *s) {
    pthread_mutex_lock(&s->ledger_lock);
    uint64_t n=fvgpu_live_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);return n;
}
bool fvgpu_ledger_reserve(FloeGPUSession *s,uint64_t size,bool aliased) {
    pthread_mutex_lock(&s->ledger_lock);
    uint64_t live=fvgpu_live_locked(s),target=s->budget.target_bytes;
    bool allowed=aliased||(size<=target&&live<=target-size&&s->reserved_bytes<=target-size-live);
    if(allowed&&!aliased) {
        uint64_t available;
        /* Per-process headroom on iOS, not optimistic system-wide free RAM.
         * Include concurrent not-yet-settled reservations conservatively. */
        if(fvgpu_host_headroom(&available)&&
           (size>available||s->reserved_bytes>available-size)) allowed=false;
    }
    if(allowed&&!aliased) s->reserved_bytes+=size;
    pthread_mutex_unlock(&s->ledger_lock);return allowed;
}
void fvgpu_ledger_cancel(FloeGPUSession *s,uint64_t size,bool aliased) {
    pthread_mutex_lock(&s->ledger_lock);
    if(!aliased) {assert(s->reserved_bytes>=size);s->reserved_bytes-=size;}
    fvgpu_budget_settle_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);
}
void fvgpu_ledger_event(FloeGPUSession *s,uint64_t size,bool aliased,bool blob,bool alloc) {
    pthread_mutex_lock(&s->ledger_lock);
    uint64_t *counter=blob?&s->ledger.blob_bytes:aliased?&s->ledger.aliased_guest_bytes:&s->ledger.device_memory_bytes;
    if(alloc) {
        if(!aliased) {assert(s->reserved_bytes>=size);s->reserved_bytes-=size;}
        assert(*counter<=UINT64_MAX-size);*counter+=size;
    } else {assert(*counter>=size);*counter-=size;}
    fvgpu_budget_settle_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);
}

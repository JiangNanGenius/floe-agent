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
void fvgpu_ledger_fault(FloeGPUSession *s,const char *what,uint64_t a,uint64_t b) {
    s->ledger_faults++;
    fvgpu_trace("ev=ledger-fault what=%s a=%llu b=%llu faults=%llu",
        what,(unsigned long long)a,(unsigned long long)b,
        (unsigned long long)s->ledger_faults);
}
int floe_gpu_ledger_faulted(FloeGPUSession *s) {
    if(!s) return 1;
    pthread_mutex_lock(&s->ledger_lock);
    int faulted=s->ledger_faults!=0;
    pthread_mutex_unlock(&s->ledger_lock);
    return faulted;
}
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
    if(s->ledger_faults) {
        fvgpu_trace("ev=admit-deny reason=ledger-fault bytes=%llu aliased=%u faults=%llu",
            (unsigned long long)size,aliased?1u:0u,(unsigned long long)s->ledger_faults);
        pthread_mutex_unlock(&s->ledger_lock);return false;
    }
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
    if(!allowed) fvgpu_trace("ev=admit-deny bytes=%llu aliased=%u live=%llu reserved=%llu target=%llu",
        (unsigned long long)size,aliased?1u:0u,(unsigned long long)live,
        (unsigned long long)s->reserved_bytes,(unsigned long long)target);
    pthread_mutex_unlock(&s->ledger_lock);return allowed;
}
void fvgpu_ledger_cancel(FloeGPUSession *s,uint64_t size,bool aliased) {
    pthread_mutex_lock(&s->ledger_lock);
    if(!aliased) {
        if(s->reserved_bytes<size) {
            fvgpu_ledger_fault(s,"cancel-reserved",size,s->reserved_bytes);
            assert(s->reserved_bytes>=size);   /* preserved original assertion */
            s->reserved_bytes=0;               /* faulted: never wrap a counter */
        } else s->reserved_bytes-=size;
    }
    fvgpu_budget_settle_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);
}
/* Callbacks are serialized by the accounting registry. A release must only
 * decrement bytes that were actually charged; an unmatched release is recorded
 * and refused instead of underflowing or inventing a free. */
void fvgpu_ledger_event(FloeGPUSession *s,uint64_t size,bool aliased,bool blob,bool alloc,uint64_t key) {
    pthread_mutex_lock(&s->ledger_lock);
    uint64_t *counter=blob?&s->ledger.blob_bytes:aliased?&s->ledger.aliased_guest_bytes:&s->ledger.device_memory_bytes;
    if(alloc) {
        if(!aliased) {
            if(s->reserved_bytes<size) {
                fvgpu_ledger_fault(s,"settle-reserved",size,s->reserved_bytes);
                assert(s->reserved_bytes>=size);   /* preserved original assertion */
                s->reserved_bytes=0;               /* faulted: never wrap a counter */
            } else s->reserved_bytes-=size;
        }
        if(*counter>UINT64_MAX-size) {
            /* The allocation is real but cannot be represented. Keep the
             * counter unchanged (do not wrap or silently undercount), fault
             * the session so no further admission succeeds. */
            fvgpu_ledger_fault(s,"counter-overflow",*counter,size);
            assert(*counter<=UINT64_MAX-size);     /* preserved original assertion */
        } else *counter+=size;
    } else {
        if(*counter<size) {
            fvgpu_ledger_fault(s,"counter-underflow",*counter,size);
            assert(*counter>=size);                /* preserved original assertion */
            /* Do not invent a release: the counter stays as charged. */
        } else *counter-=size;
    }
    fvgpu_trace("ev=ledger op=%s kind=%s bytes=%llu key=%llu live=%llu blob=%llu device=%llu aliased=%llu reserved=%llu faults=%llu",
        alloc?"alloc":"free",blob?"blob":aliased?"alias":"device",
        (unsigned long long)size,(unsigned long long)key,(unsigned long long)fvgpu_live_locked(s),
        (unsigned long long)s->ledger.blob_bytes,
        (unsigned long long)s->ledger.device_memory_bytes,
        (unsigned long long)s->ledger.aliased_guest_bytes,
        (unsigned long long)s->reserved_bytes,
        (unsigned long long)s->ledger_faults);
    fvgpu_budget_settle_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);
}

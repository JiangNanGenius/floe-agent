/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
#include "memory_sync.h"
#include "machine.h"
#include "parallel_iface.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <os/lock.h> /* public system API only; no lock implementation copied */
typedef os_unfair_lock MemoryNativeLock;
#else
typedef pthread_rwlock_t MemoryNativeLock;
#endif

/* The backing is independently posix_memalign'ed; calloc alignment is not
 * sufficient for this type. Addresses remain stable until workers have joined.
 * On Apple each 4-byte opaque lock occupies its own 128-byte cache line. */
typedef struct MemoryStripe {
    _Alignas(MEMORY_STRIPE_ALIGNMENT) MemoryNativeLock lock;
} MemoryStripe;
_Static_assert(_Alignof(MemoryStripe)==MEMORY_STRIPE_ALIGNMENT&&
               sizeof(MemoryStripe)%MEMORY_STRIPE_ALIGNMENT==0,
               "stripe storage must isolate 128-byte cache lines");
#if defined(__APPLE__)
_Static_assert(sizeof(MemoryStripe)==128,"one public unfair lock per line");
#endif

typedef struct Reservation { u64 pa;unsigned size;bool valid; } Reservation;
_Static_assert(A64_MAX_CPUS<=sizeof(unsigned)*8&&
               A64_EXCLUSIVE_GRANULE<=0x1000&&0x1000%A64_EXCLUSIVE_GRANULE==0,
               "active mask and reservation granule must fit the stripe protocol");
struct MemorySync {
    MemoryStripe *stripe;
    pthread_mutex_t monitor;
    unsigned initialized;
    bool monitor_ready;
    atomic_int error;
    /* A3 canonical mask: publish a bit before valid, clear after invalidation.
     * All canonical mutations remain under the original monitor mutex. */
    atomic_uint active_reservations;
    Reservation reservation[A64_MAX_CPUS];
    MemoryCodeEpoch *ram_epoch,*flash_epoch;
    u64 ram_pages,flash_pages;
};
_Thread_local MemoryGuard *memory_guard_held;
__attribute__((weak,noinline,visibility("hidden")))
void *ae_code_epoch_alloc(size_t bytes) { return calloc(1,bytes); }
__attribute__((weak,noinline,visibility("hidden")))
void ae_code_epoch_free(void *p) { free(p); }
static MemoryCodeEpoch *epoch_table(u64 bytes,u64 *pages) {
    *pages=bytes>>12; /* partial final pages cannot be snapshot sources */
    if(!*pages||*pages>SIZE_MAX/sizeof(MemoryCodeEpoch))return NULL;
    MemoryCodeEpoch *p=ae_code_epoch_alloc((size_t)*pages*sizeof(*p));
    if(p)for(u64 i=0;i<*pages;i++)atomic_init(&p[i].version,0);
    return p;
}
MemoryCodeEpoch *memory_code_page_epoch(Machine *m,u64 pa_page) {
    struct MemorySync *s=m->memory_sync;if(!s||(pa_page&0xfff))return NULL;
    if(s->ram_epoch&&!(m->ram_base&0xfff)&&pa_page>=m->ram_base) {
        u64 page=(pa_page-m->ram_base)>>12;
        if(page<s->ram_pages)return &s->ram_epoch[page];
    }
    if(s->flash_epoch&&!(m->flash_base&0xfff)&&pa_page>=m->flash_base) {
        u64 page=(pa_page-m->flash_base)>>12;
        if(page<s->flash_pages)return &s->flash_epoch[page];
    }
    return NULL;
}
static unsigned stripe_index(u64 pa) {
    return (unsigned)(((pa>>12)^(pa>>28))&(MEMORY_LOCK_STRIPES-1));
}
static void set_bit(u64 *bits,unsigned n) { bits[n>>6]|=1ULL<<(n&63); }
static bool bit(const u64 *bits,unsigned n) { return (bits[n>>6]>>(n&63))&1; }
static int stripe_lock(struct MemorySync *s,unsigned stripe,bool write) {
#if defined(__APPLE__)
    (void)write;os_unfair_lock_lock(&s->stripe[stripe].lock);return 0;
#else
    return write?pthread_rwlock_wrlock(&s->stripe[stripe].lock):
                 pthread_rwlock_rdlock(&s->stripe[stripe].lock);
#endif
}
static void stripe_unlock(struct MemorySync *s,unsigned stripe) {
#if defined(__APPLE__)
    os_unfair_lock_unlock(&s->stripe[stripe].lock);
#else
    pthread_rwlock_unlock(&s->stripe[stripe].lock);
#endif
}
static bool guard_has(const MemoryGuard *g,unsigned stripe,bool write) {
    if(g->single)return g->single_stripe==stripe&&(!write||g->single_write);
    return bit(g->write,stripe)||(!write&&bit(g->read,stripe));
}
static MemoryGuard *guard_root(void) {
    MemoryGuard *g=memory_guard_held;while(g&&g->parent)g=g->parent;return g;
}
static bool held_write_guard_covers(Machine *m,u64 pa,u64 length) {
    if(!length||length-1>UINT64_MAX-pa)return false;
    MemoryGuard *g=guard_root();if(!g||g->machine!=m||!g->owns)return false;
    u64 page=pa&~0xfffULL,last=(pa+length-1)&~0xfffULL;
    for(;;) {
        if(!guard_has(g,stripe_index(page),true))return false;
        if(page==last)return true;page+=0x1000;
    }
}
void memory_sync_fail(Machine *m,int error) {
    if(!m->memory_sync){m->host_error=error;return;}
    int expected=0;atomic_compare_exchange_strong(&m->memory_sync->error,&expected,error);
}
int memory_sync_error(Machine *m) {
    return m->memory_sync?atomic_load(&m->memory_sync->error):m->host_error;
}
const atomic_int *memory_sync_error_address(const Machine *m) {
    return !m?NULL:m->memory_sync?&m->memory_sync->error:&m->host_error;
}
int memory_sync_init(Machine *m) {
    struct MemorySync *s=calloc(1,sizeof(*s));if(!s)return -6;
    atomic_init(&s->error,0);atomic_init(&s->active_reservations,0);m->memory_sync=s;
    if(pthread_mutex_init(&s->monitor,NULL))goto failed;
    s->monitor_ready=true;
    void *storage=NULL;
    if(posix_memalign(&storage,MEMORY_STRIPE_ALIGNMENT,
                     MEMORY_LOCK_STRIPES*sizeof(MemoryStripe)))goto failed;
    s->stripe=storage;
    for(;s->initialized<MEMORY_LOCK_STRIPES;s->initialized++) {
#if defined(__APPLE__)
        s->stripe[s->initialized].lock=OS_UNFAIR_LOCK_INIT;
#else
        if(pthread_rwlock_init(&s->stripe[s->initialized].lock,NULL))goto failed;
#endif
    }
    /* Immutable table pointers after init. Either allocation may fail: pages
     * without a version keep the original live read/lock path. No CPU cache or
     * worker exists yet, including during the initial firmware memcpy. */
    s->ram_epoch=epoch_table(m->ram_size,&s->ram_pages);
    s->flash_epoch=epoch_table(m->flash_size,&s->flash_pages);
    return 0;
failed:
    memory_sync_destroy(m);return -6;
}
void memory_sync_destroy(Machine *m) {
    struct MemorySync *s=m->memory_sync;if(!s)return;
#if !defined(__APPLE__)
    for(unsigned n=0;n<s->initialized;n++)pthread_rwlock_destroy(&s->stripe[n].lock);
#endif
    free(s->stripe); /* unfair locks have no destroy API; all owners are quiet */
    if(s->monitor_ready)pthread_mutex_destroy(&s->monitor);
    ae_code_epoch_free(s->ram_epoch);ae_code_epoch_free(s->flash_epoch);
    free(s);m->memory_sync=NULL;
}
bool memory_host_span(Machine *m,const void *host,u64 length,u64 *pa) {
    uintptr_t p=(uintptr_t)host,b=(uintptr_t)m->ram;
    if(m->ram&&p>=b&&length<=m->ram_size&&p-b<=m->ram_size-length) {
        *pa=m->ram_base+(u64)(p-b);return true;
    }
    b=(uintptr_t)m->flash;
    if(m->flash&&p>=b&&length<=m->flash_size&&p-b<=m->flash_size-length) {
        *pa=m->flash_base+(u64)(p-b);return true;
    }
    return false;
}
/* Keep bitset setup/rollback out of the common one-page stack frame. */
__attribute__((noinline))
static bool guard_begin_slow(MemoryGuard *g,Machine *m,const MemoryRange *ranges,unsigned count) {
    memset(g->read,0,sizeof(g->read));memset(g->write,0,sizeof(g->write));
    for(unsigned r=0;r<count;r++) {
        u64 pa=ranges[r].pa,n=ranges[r].length;if(!n)continue;
        if(n-1>UINT64_MAX-pa){memory_sync_fail(m,-3);return false;}
        u64 page=pa&~0xfffULL,last=(pa+n-1)&~0xfffULL;
        for(;;) {
            set_bit(ranges[r].write?g->write:g->read,stripe_index(page));
            if(page==last)break;page+=0x1000;
        }
    }
    if(g->parent) {
        /* Nested requests reuse only an owning root's existing logical modes.
         * In particular Apple's exclusive implementation of RD is NOT WR. */
        MemoryGuard *owner=guard_root();bool subset=owner&&owner->machine==m;
        for(unsigned w=0;w<MEMORY_LOCK_WORDS&&subset;w++) {
            u64 bits=g->read[w]|g->write[w];
            while(bits) {
                unsigned b=(unsigned)__builtin_ctzll(bits),n=w*64+b;
                if(!guard_has(owner,n,bit(g->write,n))){subset=false;break;}
                bits&=bits-1;
            }
        }
        if(!subset){memory_sync_fail(m,-3);return false;}
        memory_guard_held=g;return true;
    }
    u64 acquired[MEMORY_LOCK_WORDS]={0};bool failed=false;
    for(unsigned w=0;w<MEMORY_LOCK_WORDS&&!failed;w++) {
        u64 bits=g->read[w]|g->write[w];
        while(bits) {
            unsigned b=(unsigned)__builtin_ctzll(bits),n=w*64+b;
            if(stripe_lock(m->memory_sync,n,bit(g->write,n))){failed=true;break;}
            acquired[w]|=1ULL<<b;bits&=bits-1;
        }
    }
    if(failed) {
        for(unsigned w=MEMORY_LOCK_WORDS;w--;) {
            u64 bits=acquired[w];
            while(bits){unsigned b=63u-(unsigned)__builtin_clzll(bits);stripe_unlock(m->memory_sync,w*64+b);bits&=~(1ULL<<b);}
        }
        memory_sync_fail(m,-3);return false;
    }
    g->owns=true;memory_guard_held=g;return true;
}
bool memory_guard_begin(MemoryGuard *g,Machine *m,const MemoryRange *ranges,unsigned count) {
    /* Do not touch bitsets on the single-page root path. */
    g->machine=m;g->parent=memory_guard_held;g->wake_mask=0;g->owns=false;
    g->single=false;g->single_write=false;g->single_stripe=0;
    if(!m->memory_sync)return false;
    if(!g->parent&&count==1&&ranges[0].length) {
        u64 pa=ranges[0].pa,n=ranges[0].length;
        if(n-1<=UINT64_MAX-pa&&(pa>>12)==((pa+n-1)>>12)) {
            unsigned stripe=stripe_index(pa);
            if(stripe_lock(m->memory_sync,stripe,ranges[0].write)){memory_sync_fail(m,-3);return false;}
            g->single=true;g->single_write=ranges[0].write;g->single_stripe=(u16)stripe;
            g->owns=true;memory_guard_held=g;return true;
        }
    }
    return guard_begin_slow(g,m,ranges,count);
}
bool memory_guard_host(MemoryGuard *g,Machine *m,const void *host,u64 length,bool write) {
    u64 pa;if(!memory_host_span(m,host,length,&pa)){memory_sync_fail(m,-3);return false;}
    MemoryRange range={pa,length,write};return memory_guard_begin(g,m,&range,1);
}
void memory_guard_end(MemoryGuard *g) {
    Machine *m=g->machine;memory_guard_held=g->parent;
    if(g->parent) { g->parent->wake_mask|=g->wake_mask;return; }
    if(g->owns) {
        if(g->single)stripe_unlock(m->memory_sync,g->single_stripe);
        else for(unsigned w=MEMORY_LOCK_WORDS;w--;) {
            u64 bits=g->read[w]|g->write[w];
            while(bits){unsigned b=63u-(unsigned)__builtin_clzll(bits);stripe_unlock(m->memory_sync,w*64+b);bits&=~(1ULL<<b);}
        }
    }
    /* No control/RPC/condition operation while any RAM stripe is held. */
    if(g->wake_mask)machine_dispatch_wakes(m,g->wake_mask);
}
static inline u64 small_read_value(const void *host,unsigned size) {
    u64 value=0;
    switch(size) {
        case 1:__builtin_memcpy(&value,host,1);break;
        case 2:__builtin_memcpy(&value,host,2);break;
        case 4:__builtin_memcpy(&value,host,4);break;
        case 8:__builtin_memcpy(&value,host,8);break;
        default:break; /* callers select only these four widths */
    }
    return value;
}
__attribute__((noinline))
static bool read_small_guarded(Machine *m,const void *host,unsigned size,u64 *out) {
    MemoryGuard guard;if(!memory_guard_host(&guard,m,host,size,false))return false;
    if(size>sizeof(u64)){memory_guard_end(&guard);memory_sync_fail(m,-3);return false;}
    u64 value=0;
    if(size==1||size==2||size==4||size==8)value=small_read_value(host,size);
    else __builtin_memcpy(&value,host,size); /* original guarded non-PD fallback */
    memory_guard_end(&guard);*out=value;return true;
}
bool memory_read_small(Machine *m,const void *host,unsigned size,u64 *out) {
    u64 pa;
    if((size==1||size==2||size==4||size==8)&&!memory_guard_held&&m->memory_sync&&
       memory_host_span(m,host,size,&pa)&&(pa&0xfffULL)+size<=0x1000) {
        unsigned stripe=stripe_index(pa);
        if(stripe_lock(m->memory_sync,stripe,false)){memory_sync_fail(m,-3);return false;}
        u64 value=small_read_value(host,size);
        stripe_unlock(m->memory_sync,stripe);*out=value;return true;
    }
    return read_small_guarded(m,host,size,out);
}
void memory_code_store_publish(Machine *m,u64 pa,u64 length) {
    if(!length)return;
    if(length-1>UINT64_MAX-pa){memory_sync_fail(m,-3);return;}
    MemoryGuard *owner=memory_guard_held;
    while(owner&&owner->parent)owner=owner->parent;
    u64 page=pa&~0xfffULL,last=(pa+length-1)&~0xfffULL;
    for(;;) {
        MemoryCodeEpoch *epoch=memory_code_page_epoch(m,page);
        if(epoch) {
            /* This is a mutation notification, not guard acquisition: every
             * actual ordinary/atomic/bulk write publishes before its bytes. */
            bool held=owner&&owner->machine==m&&owner->owns&&guard_has(owner,stripe_index(page),true);
            if(!held) {
                /* A legacy quiet/initialization notification may follow bytes.
                 * Do not infer quiescence from parallel_ops: retire this page
                 * from snapshots permanently. It remains a valid live source.
                 * This invalidator does not authorize unguarded concurrent RAM
                 * byte access; the existing DRF ownership contract is intact. */
                atomic_store_explicit(&epoch->version,UINT64_MAX,memory_order_release);
            }else {
                /* Zero has never backed a snapshot, so data-only writes need
                 * no RMW. Activation holds the same RD stripe: it cannot race
                 * these bytes, and RD unlock -> WR acquire orders a prior 1.
                 * CAS, despite WR serialization, prevents an unguarded MAX
                 * invalidator from being lowered. No path deactivates to 0. */
                u64 old=atomic_load_explicit(&epoch->version,memory_order_relaxed);
                while(old&&old!=UINT64_MAX&&!atomic_compare_exchange_weak_explicit(
                    &epoch->version,&old,old+1,memory_order_release,memory_order_relaxed)){}
            }
        }
        if(page==last)break;page+=0x1000;
    }
}
void memory_monitor_lock(Machine *m) { pthread_mutex_lock(&m->memory_sync->monitor); }
void memory_monitor_unlock(Machine *m) { pthread_mutex_unlock(&m->memory_sync->monitor); }
void memory_monitor_reserve_locked(CPU *c,u64 pa,unsigned size) {
    Reservation *r=&c->m->memory_sync->reservation[c->hart_id];
    atomic_fetch_or_explicit(&c->m->memory_sync->active_reservations,1u<<c->hart_id,memory_order_seq_cst);
    *r=(Reservation){pa,size,true};c->excl_addr=pa;c->excl_size=size;c->excl_valid=true;
}
bool memory_monitor_test_clear_locked(CPU *c,u64 pa,unsigned size) {
    Reservation *r=&c->m->memory_sync->reservation[c->hart_id];
    bool ok=r->valid&&r->pa==pa&&r->size==size;r->valid=false;
    atomic_fetch_and_explicit(&c->m->memory_sync->active_reservations,~(1u<<c->hart_id),memory_order_seq_cst);
    c->excl_valid=false;return ok;
}
void memory_monitor_clear(CPU *c) {
    if(c->m&&c->m->memory_sync) {
        memory_monitor_lock(c->m);c->m->memory_sync->reservation[c->hart_id].valid=false;
        atomic_fetch_and_explicit(&c->m->memory_sync->active_reservations,~(1u<<c->hart_id),memory_order_seq_cst);
        c->excl_valid=false;memory_monitor_unlock(c->m);
    }else c->excl_valid=false;
}
void memory_monitor_sync_cpu(CPU *c) {
    memory_monitor_lock(c->m);Reservation *r=&c->m->memory_sync->reservation[c->hart_id];
    c->excl_valid=r->valid;if(r->valid){c->excl_addr=r->pa;c->excl_size=r->size;}
    memory_monitor_unlock(c->m);
}
unsigned memory_monitor_store_locked(Machine *m,u64 pa,u64 length) {
    if(!length)return 0;unsigned wake=0;
    for(unsigned h=0;h<m->ncpus;h++) {
        Reservation *r=&m->memory_sync->reservation[h];if(!r->valid)continue;
        u64 granule=r->pa&~(u64)(A64_EXCLUSIVE_GRANULE-1);
        bool overlap=pa<=granule?length>granule-pa:pa-granule<A64_EXCLUSIVE_GRANULE;
        if(overlap) {
            r->valid=false;
            atomic_fetch_and_explicit(&m->memory_sync->active_reservations,~(1u<<h),memory_order_seq_cst);
            wake|=1u<<h;
            /* Between public slices every worker is parked. Preserve the
             * original serial component view without writing a live CPU. */
            if(!m->parallel_ops)machine_cpu(m,h)->excl_valid=false;
        }
    }
    return wake;
}
void memory_monitor_store(Machine *m,u64 pa,u64 length) {
    /* Reserve publishes before RD unlock. A matching WR acquire orders the
     * mask load and excludes a new overlapping reserve until the store ends.
     * The independent code-epoch publish has already happened in the caller. */
    if(held_write_guard_covers(m,pa,length)&&
       atomic_load_explicit(&m->memory_sync->active_reservations,memory_order_acquire)==0)return;
    memory_monitor_lock(m);unsigned wake=memory_monitor_store_locked(m,pa,length);memory_monitor_unlock(m);
    if(memory_guard_held&&memory_guard_held->machine==m)memory_guard_held->wake_mask|=wake;
    else if(wake)machine_dispatch_wakes(m,wake);
}

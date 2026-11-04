/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
#ifndef A64_MEMORY_SYNC_H
#define A64_MEMORY_SYNC_H
#include "types.h"
#include <stdatomic.h>
struct Machine;
struct CPU;
struct MemorySync;
#define MEMORY_LOCK_STRIPES 256u
#define MEMORY_LOCK_WORDS (MEMORY_LOCK_STRIPES/64u)
#define MEMORY_STRIPE_ALIGNMENT 128u
typedef struct MemoryRange { u64 pa,length;bool write; } MemoryRange;
typedef struct MemoryGuard {
    struct Machine *machine;
    struct MemoryGuard *parent;
    unsigned wake_mask;
    bool owns;
    /* A root one-page guard never initializes read/write bitsets. Every
     * containment/unlock consumer must branch on single before using them. */
    bool single,single_write;
    u16 single_stripe;
    u64 read[MEMORY_LOCK_WORDS],write[MEMORY_LOCK_WORDS];
} MemoryGuard;
/* Per-physical-page byte versions, independent of stripes and the monitor.
 * Zero means no hart has EVER installed a snapshot: first nonnested refill
 * activates 0->1 under RD before copying bytes. Writers preserve zero, advance
 * every nonzero version before bytes, and never lower sticky UINT64_MAX.
 * Reset/OFF do not deactivate pages; only a new Machine starts at zero. */
typedef struct MemoryCodeEpoch { _Atomic(u64) version; } MemoryCodeEpoch;
extern _Thread_local MemoryGuard *memory_guard_held;
MemoryCodeEpoch *memory_code_page_epoch(struct Machine *m,u64 pa_page);
void memory_code_store_publish(struct Machine *m,u64 pa,u64 length);
/* Separate hidden allocation seam: metadata OOM disables only this optimization,
 * never substitutes shared cache state or changes the guest allocation result. */
void *ae_code_epoch_alloc(size_t bytes);
void ae_code_epoch_free(void *p);
int memory_sync_init(struct Machine *m);
void memory_sync_destroy(struct Machine *m);
int memory_sync_error(struct Machine *m);
/* Canonical address only; valid until Machine destruction after worker join.
 * No error-value mirror: fast polling must see every first-fault publication. */
const atomic_int *memory_sync_error_address(const struct Machine *m);
void memory_sync_fail(struct Machine *m,int error);
bool memory_host_span(struct Machine *m,const void *host,u64 length,u64 *pa);
bool memory_guard_begin(MemoryGuard *g,struct Machine *m,const MemoryRange *ranges,unsigned count);
bool memory_guard_host(MemoryGuard *g,struct Machine *m,const void *host,u64 length,bool write);
void memory_guard_end(MemoryGuard *g);
/* Proven PD RAM hit only. Other PD widths/permissions stay in mem_read before
 * calling this helper; nested/cross-page accesses keep the original guard. */
bool memory_read_small(struct Machine *m,const void *host,unsigned size,u64 *out);
void memory_monitor_lock(struct Machine *m);
void memory_monitor_unlock(struct Machine *m);
void memory_monitor_reserve_locked(struct CPU *c,u64 pa,unsigned size);
bool memory_monitor_test_clear_locked(struct CPU *c,u64 pa,unsigned size);
void memory_monitor_clear(struct CPU *c);
void memory_monitor_sync_cpu(struct CPU *c);
unsigned memory_monitor_store_locked(struct Machine *m,u64 pa,u64 length);
void memory_monitor_store(struct Machine *m,u64 pa,u64 length);
#endif

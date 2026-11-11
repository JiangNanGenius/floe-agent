/* Copyright 2026 Floe contributors; SPDX-License-Identifier: Apache-2.0 */
#include "fvgpu_priv.h"
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <os/proc.h>
#endif
#include <string.h>

/* Extra process headroom beyond each allocation. This is a last native guard;
 * App-level shape admission still uses the existing runtime resource pool. */
#define HEADROOM_RESERVE (64ull<<20)
bool fvgpu_host_headroom(uint64_t *available) {
    uint64_t raw;
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    raw=(uint64_t)os_proc_available_memory(); /* zero means actually exhausted */
#else
    mach_port_t host=mach_host_self();vm_size_t page=0;
    vm_statistics64_data_t st;mach_msg_type_number_t count=HOST_VM_INFO64_COUNT;
    bool ok=host_page_size(host,&page)==KERN_SUCCESS&&
        host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&st,&count)==KERN_SUCCESS;
    mach_port_deallocate(mach_task_self(),host);
    if(!ok) return false;
    raw=((uint64_t)st.free_count+(uint64_t)st.inactive_count)*page;
#endif
    *available=raw>HEADROOM_RESERVE?raw-HEADROOM_RESERVE:0;return true;
}
void fvgpu_budget_settle_locked(FloeGPUSession *s) {
    uint64_t occupied=fvgpu_live_locked(s)+s->reserved_bytes;
    uint64_t target=s->budget.target_bytes;
    s->budget.limit_bytes=occupied>target?occupied:target;
    s->budget.pending=occupied>target;
    s->budget.pending_lower_bytes=s->budget.pending?target:0;
}
static FloeGPUBudgetResult fill_locked(FloeGPUSession *s) {
    FloeGPUBudgetResult r={0};
    r.requested_bytes=s->budget.requested_bytes;
    r.actual_limit_bytes=s->budget.limit_bytes;
    r.live_bytes=fvgpu_live_locked(s);
    r.pending_target_bytes=s->budget.target_bytes;
    if(s->budget.pending) strcpy(r.reason,"below-live-pending-release");
    else if(s->budget.clamped) strcpy(r.reason,"capacity-or-process-headroom");
    return r;
}
FloeGPUBudgetResult fvgpu_budget_set(FloeGPUSession *s,uint64_t requested) {
    pthread_mutex_lock(&s->ledger_lock);
    uint64_t target=requested>s->capacity_max_bytes?s->capacity_max_bytes:requested;
    if(target>s->budget.target_bytes) {
        uint64_t available;
        if(fvgpu_host_headroom(&available)) {
            uint64_t live=fvgpu_live_locked(s)+s->reserved_bytes;
            uint64_t headroom_ceiling=available>UINT64_MAX-live?UINT64_MAX:live+available;
            if(headroom_ceiling<s->budget.target_bytes) headroom_ceiling=s->budget.target_bytes;
            if(target>headroom_ceiling) target=headroom_ceiling;
        } else target=s->budget.target_bytes; /* unknown headroom: refuse a raise */
    }
    s->budget.requested_bytes=requested;s->budget.target_bytes=target;
    s->budget.clamped=target!=requested;
    fvgpu_budget_settle_locked(s);
    FloeGPUBudgetResult r=fill_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);return r;
}
FloeGPUBudgetResult floe_gpu_set_budget(FloeGPUSession *s,uint64_t requested) {
    return fvgpu_budget_set(s,requested);
}
FloeGPUBudgetResult floe_gpu_get_budget(FloeGPUSession *s) {
    pthread_mutex_lock(&s->ledger_lock);fvgpu_budget_settle_locked(s);
    FloeGPUBudgetResult r=fill_locked(s);
    pthread_mutex_unlock(&s->ledger_lock);return r;
}
FloeGPUMemoryLedger floe_gpu_get_ledger(FloeGPUSession *s) {
    pthread_mutex_lock(&s->ledger_lock);FloeGPUMemoryLedger l=s->ledger;
    pthread_mutex_unlock(&s->ledger_lock);return l;
}

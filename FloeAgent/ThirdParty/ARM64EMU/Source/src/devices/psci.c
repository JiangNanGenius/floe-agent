/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre. Cooperative SMP extensions, 2026 Floe contributors. */
/* Emulated PSCI v1.0; no firmware source is incorporated. */
#include "../devices.h"
#include "../parallel_iface.h"
#define PSCI_VERSION 0x84000000u
#define PSCI_SUSPEND32 0x84000001u
#define PSCI_SUSPEND64 0xc4000001u
#define PSCI_CPU_OFF 0x84000002u
#define PSCI_CPU_ON32 0x84000003u
#define PSCI_CPU_ON64 0xc4000003u
#define PSCI_AFFINITY32 0x84000004u
#define PSCI_AFFINITY64 0xc4000004u
#define PSCI_MIGRATE_INFO_TYPE 0x84000006u
#define PSCI_SYSTEM_OFF 0x84000008u
#define PSCI_SYSTEM_RESET 0x84000009u
#define PSCI_FEATURES 0x8400000au
#define NOT_SUPPORTED ((u64)-1)
#define INVALID_PARAMS ((u64)-2)
#define ALREADY_ON ((u64)-4)
#define ON_PENDING ((u64)-5)
#define INVALID_ADDRESS ((u64)-9)
#define AFF_MASK 0xff00ffffffULL

static CPU *target_cpu(Machine *m,u64 affinity) {
    if(affinity&~AFF_MASK)return NULL;
    for(unsigned h=0;h<m->ncpus;h++){CPU *c=machine_cpu(m,h);if((c->mpidr&AFF_MASK)==affinity)return c;}
    return NULL;
}
static bool supported(u32 f) {
    return f==PSCI_VERSION||f==PSCI_SUSPEND32||f==PSCI_SUSPEND64||
           f==PSCI_CPU_OFF||f==PSCI_CPU_ON32||f==PSCI_CPU_ON64||
           f==PSCI_AFFINITY32||f==PSCI_AFFINITY64||f==PSCI_MIGRATE_INFO_TYPE||
           f==PSCI_SYSTEM_OFF||f==PSCI_SYSTEM_RESET||f==PSCI_FEATURES;
}
static bool valid_entry(Machine *m,u64 entry) {
    if(entry&3)return false;
    return ram_ptr(m,entry,4)!=NULL||
           (entry>=m->flash_base&&m->flash_size>=4&&entry-m->flash_base<=m->flash_size-4);
}
static u64 affinity_info(Machine *m,u64 target,u64 level) {
    if(level>3||(target&~AFF_MASK))return INVALID_PARAMS;
    u64 lower=level==0?0:level==1?0xff:level==2?0xffff:0xffffff;
    u64 mask=AFF_MASK&~lower;bool found=false,pending=false;
    for(unsigned h=0;h<m->ncpus;h++){
        CPU *c=machine_cpu(m,h);if((c->mpidr&mask)!=(target&mask))continue;
        found=true;if(c->power==CPU_POWER_ON)return 0;
        if(c->power==CPU_POWER_ON_PENDING)pending=true;
    }
    return !found?INVALID_PARAMS:pending?2:1;
}
bool smccc_conduit(CPU *c,bool is_hvc) {
    if(c->m&&c->m->parallel_ops&&c->m->parallel_ops->psci&&c->m->parallel_ops->psci(c,is_hvc))return true;
    Machine *m=c->m;u32 fn=(u32)c->x[0];bool wide=(fn&(1u<<30))!=0;
    u64 a=wide?c->x[1]:(u32)c->x[1],b=wide?c->x[2]:(u32)c->x[2],context=wide?c->x[3]:(u32)c->x[3],ret;
    switch(fn){
    case PSCI_VERSION:ret=0x00010000;break;
    case PSCI_FEATURES:ret=supported((u32)c->x[1])?0:NOT_SUPPORTED;break;
    case PSCI_MIGRATE_INFO_TYPE:ret=2;break;
    case PSCI_AFFINITY32:case PSCI_AFFINITY64:ret=affinity_info(m,a,b);break;
    case PSCI_CPU_ON32:case PSCI_CPU_ON64:{
        CPU *target=target_cpu(m,a);
        if(!target)ret=INVALID_PARAMS;
        else if(!valid_entry(m,b))ret=INVALID_ADDRESS;
        else if(target->power==CPU_POWER_ON)ret=ALREADY_ON;
        else if(target->power==CPU_POWER_ON_PENDING)ret=ON_PENDING;
        else {
            /* No reset/fenv/global-cache work inside another PE's instruction.
             * The sole owner activates this context at its next safe quantum. */
            target->boot_entry=b;target->boot_context=context;
            target->power=CPU_POWER_ON_PENDING;c->owner_yield=true;ret=0;
        }break;
    }
    case PSCI_CPU_OFF:
        memory_monitor_clear(c);c->power=CPU_POWER_OFF;c->sleep=CPU_SLEEP_NONE;
        c->halted=true;c->owner_yield=true;gic_cpu_reset(m->gic,c->hart_id);
        return true; /* successful CPU_OFF never returns to the old instruction */
    case PSCI_SUSPEND32:case PSCI_SUSPEND64:
        /* Original-format state0: retention/standby only. Power-down entry/context
         * and nonzero affinity/state IDs are not advertised as implemented. */
        if(a!=0)ret=INVALID_PARAMS;
        else {cpu_sleep(c,CPU_SLEEP_WFI);ret=0;}break;
    case PSCI_SYSTEM_OFF:m->system_off=true;c->owner_yield=true;return true;
    case PSCI_SYSTEM_RESET:m->system_reset=true;c->owner_yield=true;return true;
    default:ret=NOT_SUPPORTED;break;
    }
    c->x[0]=ret;(void)is_hvc;return true;
}

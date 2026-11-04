/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre. Cooperative SMP extensions, 2026 Floe contributors. */
/* Shared physical counter epoch; private compare/control and PPIs per PE. */
#include "../devices.h"
#include "../parallel_iface.h"
#include <stdlib.h>
#include <time.h>

static u64 host_ns(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return (u64)t.tv_sec*1000000000ULL+(u64)t.tv_nsec;
}
u64 gt_count(CPU *c,bool virt) {
    Machine *m=c->m;u64 ticks;
    if(!m)ticks=c->icount;
    else if(g_rtclock){
        unsigned __int128 elapsed=(unsigned __int128)(host_ns()-m->clock_epoch_ns)*m->counter_hz;
        ticks=(u64)(elapsed/1000000000ULL);
    } else {
        if(m->parallel_ops&&m->parallel_ops->counter_ticks)ticks=m->parallel_ops->counter_ticks(c);
        else {ticks=m->virtual_ticks;if(m->executing_cpu)ticks+=m->executing_cpu->icount-m->quantum_icount;}
    }
    return virt?ticks-(u64)c->cntvoff:ticks;
}
static u64 *cached(Machine *m,unsigned h) {
    return h?&m->timer->secondary_deadline[h-1]:&m->timer->deadline;
}
static bool fires(u64 control,u64 now,u64 value) {
    return (control&1)&&!(control&2)&&now>=value;
}
static u64 deadline_count(CPU *c) {
    u64 best=UINT64_MAX;
    if((c->cntp_ctl&1)&&!(c->cntp_ctl&2))best=c->cntp_cval;
    if((c->cntv_ctl&1)&&!(c->cntv_ctl&2)){
        u64 d=c->cntv_cval+(u64)c->cntvoff;if(d<best)best=d;
    }return best;
}
/* Timer register ownership follows the worker; the board evaluates only
 * coordinator-owned value snapshots, never reads a live CPU structure. */
static CPU *timer_cpu(Machine *m,unsigned h,CPU *view){
    MachineTimerView t;
    if(m->parallel_ops&&m->parallel_ops->timer_view&&m->parallel_ops->timer_view(m,h,&t)){
        *view=(CPU){.m=m,.hart_id=h,.power=t.power,.cntp_ctl=t.cntp_ctl,.cntp_cval=t.cntp_cval,
                    .cntv_ctl=t.cntv_ctl,.cntv_cval=t.cntv_cval,.cntvoff=t.cntvoff};return view;
    }
    return machine_cpu(m,h);
}
void timer_update_cpu(CPU *c) {
    Machine *m=c->m;if(!m)return;
    if(m->parallel_ops&&m->parallel_ops->timer_publish&&m->parallel_ops->timer_publish(c))return;
    bool on=c->power==CPU_POWER_ON;
    bool p=on&&fires(c->cntp_ctl,gt_count(c,false),c->cntp_cval);
    bool v=on&&fires(c->cntv_ctl,gt_count(c,true),c->cntv_cval);
    gic_set_ppi(m->gic,c->hart_id,INTID_TIMER_PHYS,p);
    gic_set_ppi(m->gic,c->hart_id,INTID_TIMER_VIRT,v);
    if(m->timer)*cached(m,c->hart_id)=on?deadline_count(c):UINT64_MAX;
}
void timer_update(Machine *m) {
    for(unsigned h=0;h<m->ncpus;h++){CPU view;timer_update_cpu(timer_cpu(m,h,&view));}
}
void timer_check(Machine *m) {
    if(!m->timer)return;
    for(unsigned h=0;h<m->ncpus;h++){
        CPU view,*c=timer_cpu(m,h,&view);
        if(c->power==CPU_POWER_ON&&gt_count(c,false)>=*cached(m,h))timer_update_cpu(c);
    }
}
static u64 ticks_until(CPU *c) {
    if(c->power!=CPU_POWER_ON)return UINT64_MAX;
    u64 best=UINT64_MAX,p=gt_count(c,false),v=gt_count(c,true);
    if((c->cntp_ctl&1)&&!(c->cntp_ctl&2)){
        if(c->cntp_cval<=p)return 0;best=c->cntp_cval-p;
    }
    if((c->cntv_ctl&1)&&!(c->cntv_ctl&2)){
        if(c->cntv_cval<=v)return 0;u64 d=c->cntv_cval-v;if(d<best)best=d;
    }return best;
}
u64 timer_next_deadline_ticks(Machine *m) {
    u64 best=UINT64_MAX;
    for(unsigned h=0;h<m->ncpus;h++){CPU view;u64 d=ticks_until(timer_cpu(m,h,&view));if(d<best)best=d;}
    return best;
}
u64 timer_next_deadline_ns(Machine *m) {
    u64 ticks=timer_next_deadline_ticks(m);if(ticks==UINT64_MAX)return ticks;
    if(!m->counter_hz)return 0;
    /* Round upward: a sub-nanosecond positive deadline must not become timer0. */
    unsigned __int128 ns=((unsigned __int128)ticks*1000000000ULL+m->counter_hz-1)/m->counter_hz;
    return ns>UINT64_MAX?UINT64_MAX:(u64)ns;
}
u64 timer_next_event_ns(Machine *m) {
    u64 ticks=UINT64_MAX;
    for(unsigned h=0;h<m->ncpus;h++) {
        CPU view,*c=timer_cpu(m,h,&view);if(c->power!=CPU_POWER_ON)continue;
        u64 counts[2]={gt_count(c,false),gt_count(c,true)};
        u64 controls[2]={c->cntp_ctl,c->cntv_ctl},values[2]={c->cntp_cval,c->cntv_cval};
        unsigned ids[2]={INTID_TIMER_PHYS,INTID_TIMER_VIRT};
        for(unsigned which=0;which<2;which++)if((controls[which]&1)&&!(controls[which]&2)) {
            u64 d;
            if(values[which]>counts[which])d=values[which]-counts[which];
            else {
                /* A due, already asserted PPI is stable. A parked PE whose
                 * GIC masks it cannot service it merely because host wait
                 * times out again. Only an unserviced transition needs tick0. */
                if(m->gic&&m->gic->bank[h].line[ids[which]])continue;
                d=0;
            }
            if(d<ticks)ticks=d;
        }
    }
    if(ticks==UINT64_MAX)return ticks;
    if(!m->counter_hz)return 0;
    unsigned __int128 ns=((unsigned __int128)ticks*1000000000ULL+m->counter_hz-1)/m->counter_hz;
    return ns>UINT64_MAX?UINT64_MAX:(u64)ns;
}
ARMTimer *gtimer_create(Machine *m) {
    ARMTimer *t=calloc(1,sizeof(*t));if(!t)return NULL;
    t->m=m;t->cpu=&m->cpu;t->gic=m->gic;t->deadline=UINT64_MAX;
    for(unsigned h=1;h<A64_MAX_CPUS;h++)t->secondary_deadline[h-1]=UINT64_MAX;
    m->timer=t;return t;
}
void gtimer_destroy(ARMTimer *t){free(t);}

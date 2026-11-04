/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
#ifndef A64_PARALLEL_IFACE_H
#define A64_PARALLEL_IFACE_H
#include "machine.h"
/* A6: immutable value addresses leased to one validated PD invocation. The
 * Source tier neither sees Bridge layouts nor owns these atomic objects. */
typedef struct MachineParallelPollView {
    const CPU *cpu;
    const Machine *machine;
    const atomic_uint *pending;
    const atomic_bool *abort_run,*stop;
    const atomic_int *memory_error;
} MachineParallelPollView;
/* Only a predicate: every interesting condition returns to the unchanged
 * Bridge slow poll, preserving its epoch/IRQ/event/wake/fatal ordering. */
static inline bool machine_parallel_poll_due(CPU *c,const MachineParallelPollView *v) {
    /* Immutable identity/address validation ran once at PD entry. */
    if(!v||c->halted)return true;
    return atomic_load_explicit(v->pending,memory_order_acquire)!=0||
           atomic_load_explicit(v->abort_run,memory_order_acquire)||
           atomic_load_explicit(v->stop,memory_order_acquire)||
           atomic_load_explicit(&c->m->system_off,memory_order_acquire)||
           atomic_load_explicit(&c->m->system_reset,memory_order_acquire)||
           atomic_load(&c->m->host_error)||atomic_load(v->memory_error);
}
typedef struct MachineBusReply { u64 value;BusStatus status;bool yield; } MachineBusReply;
typedef struct MachineTimerView {
    CPUPower power;u64 cntp_ctl,cntp_cval,cntv_ctl,cntv_cval;s64 cntvoff;
} MachineTimerView;
/* Install/remove only at all-worker quiescence. The coordinator owns devices;
 * workers exchange value payloads and retain exclusive register/cache/fenv
 * ownership. No callback waits for control while a RAM/monitor lock is held. */
typedef struct MachineParallelOps {
    void (*wake_harts)(Machine *,unsigned mask);
    bool (*poll_cpu)(CPU *);
    bool (*bus_access)(CPU *,u64,unsigned,bool,u64,MachineBusReply *);
    CPUPower (*power)(Machine *,unsigned);
    void (*irq)(Machine *,unsigned,bool);
    bool (*timer_publish)(CPU *);
    bool (*timer_view)(Machine *,unsigned,MachineTimerView *);
    bool (*psci)(CPU *,bool);
    void (*tlbi)(CPU *,u64,bool);
    void (*barrier)(CPU *,unsigned);
    u64 (*counter_ticks)(CPU *);
    /* Optional, side-effect-free; validates native worker + CPU + Machine.
     * The returned immutable view is valid only until this PD call returns. */
    const MachineParallelPollView *(*poll_view)(CPU *);
} MachineParallelOps;
MachineBusReply machine_bus_service(Machine *,unsigned,u64,unsigned,bool,u64,u64,u64);
void machine_dispatch_wakes(Machine *m,unsigned mask);
#endif

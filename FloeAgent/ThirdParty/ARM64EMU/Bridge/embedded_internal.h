/* SPDX-License-Identifier: MPL-2.0 */
#ifndef FLOE_AE_INTERNAL_H
#define FLOE_AE_INTERNAL_H
#include "floe_arm64emu.h"
#include "devices.h"
#include "jit/predecode.h"
#include <pthread.h>
#include <stdatomic.h>
#include <fenv.h>
#include <stdio.h>
_Static_assert(A64_MAX_CPUS==FLOE_AE_MAX_VCPUS,"public and internal CPU ceilings must match");
typedef struct AERing { unsigned char *bytes; size_t cap,head,count; } AERing;
typedef struct AESession AESession;
struct AEParallel;
struct ConsoleEP { AESession *owner; };
struct AESession {
    Machine machine;
    struct AEParallel *parallel;
    uint64_t handle,sequence,instructions,slice_calls,park_waits,resets;
    uint64_t snapshot_pc,deadline_at,diagnostic_dropped;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int mutex_ready,condition_ready,active,waiters,state,error,last_reason;
    atomic_bool stop;
    AERing input,output,diagnostic;
    ConsoleEP endpoint;
    char *disk_path;
    fenv_t guest_environment[A64_MAX_CPUS];
};
extern _Thread_local AESession *ae_current;
uint64_t ae_now_ns(void);
size_t ae_ring_write(AERing *,const void *,size_t);
size_t ae_ring_read(AERing *,void *,size_t);
void ae_signal_locked(AESession *);
void ae_machine_destroy(Machine *);
void ae_reset_caches(Machine *);
int platform_build(Machine *);
void machine_tick(Machine *);
void machine_reset(Machine *,u64,unsigned);

void fpsr_sync(CPU *);
int ae_vendor_fprintf(FILE *,const char *,...);
int ae_vendor_printf(const char *,...);
int ae_vendor_fputc(int,FILE *);
#endif

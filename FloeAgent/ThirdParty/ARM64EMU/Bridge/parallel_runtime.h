/* SPDX-License-Identifier: MPL-2.0 */
#ifndef FLOE_AE_PARALLEL_RUNTIME_H
#define FLOE_AE_PARALLEL_RUNTIME_H
#include "embedded_internal.h"
typedef struct AEParallelCallbacks {
    StepResult (*step)(CPU *,u64,u64);
    void (*tick)(Machine *);
    void (*fw_service)(FwCfg *,u32);
    void (*blk_service)(struct VirtIOBlk *);
    void (*fp_sync)(CPU *);
} AEParallelCallbacks;
typedef struct AEParallelResult { u64 instructions,resets,observed_sequence;unsigned reason;int error; } AEParallelResult;
/* Internal diagnostic, not a public ABI or model tool. Read only at public
 * all-worker quiescence. in_pd counts actual interpreter entry/leave regions;
 * it is not a speedup metric and can include brief RAM-lock waits. */
typedef struct AEParallelSnapshot {
    unsigned started_workers,max_in_pd;
    u64 native_id[A64_MAX_CPUS],retired[A64_MAX_CPUS],cpu_ns[A64_MAX_CPUS];
} AEParallelSnapshot;
int ae_parallel_init(AESession *);
void ae_parallel_destroy(AESession *);
void ae_parallel_notify(AESession *);
AEParallelResult ae_parallel_run(AESession *,u64,u64,const AEParallelCallbacks *);
void ae_parallel_snapshot(AESession *,AEParallelSnapshot *);
/* Hidden weak hook: empty in release. Components can block a precise real
 * worker boundary without exporting a production control/test API. */
void ae_parallel_test_boundary(CPU *,unsigned);
#endif

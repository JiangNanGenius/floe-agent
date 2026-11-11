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
_Static_assert(MAX_CONSOLES==FLOE_AE_MAX_CONSOLES,"public and internal console ceilings must match");
_Static_assert(MAX_SHARES==FLOE_AE_MAX_SHARES,"public and internal share ceilings must match");
typedef struct AERing { unsigned char *bytes; size_t cap,head,count; } AERing;
typedef struct AESession AESession;
struct AEParallel;
/* One host-visible byte channel. Channel 0 is the PL011 UART (the legacy
 * floe_ae_console_* target); channels 1..N are the virtio-consoles in
 * creation order (hvc<i> -> channel i+1). Input is host->guest, output is
 * guest->host; both are bounded rings drained by the ABI and the devices. */
typedef struct AEChannel {
    AERing input, output;
    uint16_t cols, rows;     /* last pushed geometry; 0x0 = unknown */
    bool winch;              /* geometry changed since the guest last looked */
    bool present;
} AEChannel;
#define AE_MAX_CHANNELS (MAX_CONSOLES + 1)
struct ConsoleEP { AESession *owner; uint32_t channel; };
struct AESession {
    Machine machine;
    struct AEParallel *parallel;
    uint64_t handle,sequence,instructions,slice_calls,park_waits,resets;
    uint64_t snapshot_pc,deadline_at,diagnostic_dropped;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int mutex_ready,condition_ready,active,waiters,state,error,last_reason;
    atomic_bool stop;
    /* Owned readiness pipe: ae_signal_locked writes one byte; the public
     * wait_event and the fully-parked in-slice wait poll its read end
     * together with dup'd usernet descriptors. Both ends are CLOEXEC and
     * nonblocking; filled at create, closed at dispose after workers join. */
    int wake_pipe[2];
    int wake_pipe_ready;
    AERing diagnostic;
    AEChannel channels[AE_MAX_CHANNELS];
    ConsoleEP endpoint;                     /* channel 0 */
    ConsoleEP vcon_endpoints[MAX_CONSOLES]; /* channels 1.. */
    char *disk_path;
    /* Deep copies of the device configuration (owned, freed at destroy). */
    char *dns_text;                          /* NULL when probing */
    uint32_t dns_server;                     /* parsed host-order IPv4, 0 = probe */
    uint32_t requested_consoles;
    struct {
        char *path;
        char *tag;
        bool ro;
        uint32_t guest_uid;
        uint32_t guest_gid;
    } share[FLOE_AE_MAX_SHARES];
    uint32_t share_count;
    NetFwd fwd[FLOE_AE_MAX_NET_FORWARDS];
    uint32_t fwd_count;
    /* ABI version 3 online memory (validated deep state; device built at
     * platform_build when enabled). */
    uint32_t mem_enabled;
    uint32_t mem_boot_mib;
    uint32_t gpu_requested;
    uint64_t gpu_budget_bytes;
    char *gpu_app_group;
    fenv_t guest_environment[A64_MAX_CPUS];
};
extern _Thread_local AESession *ae_current;
uint64_t ae_now_ns(void);
size_t ae_ring_write(AERing *,const void *,size_t);
size_t ae_ring_read(AERing *,void *,size_t);
size_t ae_ring_space(const AERing *);
void ae_signal_locked(AESession *);
void ae_wake_drain(AESession *);
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

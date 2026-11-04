/* SPDX-License-Identifier: MPL-2.0 */
#include "embedded_internal.h"
#include "parallel_runtime.h"
#include "sysreg.h"
#include "mmu.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <limits.h>

#ifndef AE_COMPLETE_OBSERVER
#define AE_COMPLETE_OBSERVER(s) ((void)0)
#endif
static pthread_mutex_t registry=PTHREAD_MUTEX_INITIALIZER;
static AESession *live;
static uint64_t generation;
static int transition;
uint64_t ae_now_ns(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec; }
static void dispose(AESession *s) {
    if(!s)return;
    ae_parallel_destroy(s);
    ae_machine_destroy(&s->machine);
    free(s->input.bytes);free(s->output.bytes);free(s->diagnostic.bytes);free(s->disk_path);
    if(s->condition_ready)pthread_cond_destroy(&s->condition);
    if(s->mutex_ready)pthread_mutex_destroy(&s->mutex);
    free(s);
}
static int load(const char *path,unsigned char **out,u32 *length,uint64_t limit) {
    *out=NULL;*length=0;if(!path)return 0;
    int fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return FLOE_AE_IO;
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||(uint64_t)st.st_size>limit) { close(fd);return FLOE_AE_IO; }
    unsigned char *data=malloc((size_t)st.st_size);if(!data){close(fd);return FLOE_AE_NOMEM;}
    size_t offset=0;
    while(offset<(size_t)st.st_size) {
        ssize_t n=read(fd,data+offset,(size_t)st.st_size-offset);
        if(n<0&&errno==EINTR)continue;
        if(n<=0){free(data);close(fd);return FLOE_AE_IO;}offset+=(size_t)n;
    }
    close(fd);*out=data;*length=(u32)offset;return 0;
}
static uint64_t next_deadline(Machine *m) {
    if(fwcfg_has_work(m->fwcfg))return 0;
    for(int i=0;i<m->n_blk;i++)if(virtio_blk_has_work(m->blk[i]))return 0;
    uint64_t earliest=timer_next_event_ns(m);
    PL031 *p=m->rtc;
    if(p&&p->armed) {
        struct timespec now;clock_gettime(CLOCK_REALTIME,&now);
        u32 count=(u32)((u32)now.tv_sec+p->tick_offset);
        uint64_t rtc=count>=p->mr?0:(uint64_t)(p->mr-count)*1000000000-(uint64_t)now.tv_nsec;
        if(rtc<earliest)earliest=rtc;
    }
    return earliest;
}
static int valid_config(const floe_ae_config *c) {
    if(!c||c->abi_version!=FLOE_AE_ABI_VERSION||c->struct_size<sizeof(*c))return FLOE_AE_VERSION;
    if(c->requested_vcpus<1||c->requested_vcpus>A64_MAX_CPUS)return FLOE_AE_UNSUPPORTED;
    if(!c->firmware_path||c->ram_mib<16||c->ram_mib>1024)return FLOE_AE_INVALID;
    if(c->initrd_path&&!c->kernel_path)return FLOE_AE_INVALID;
    if(c->command_line&&strnlen(c->command_line,4097)>4096)return FLOE_AE_INVALID;
    for(unsigned i=0;i<4;i++)if(c->reserved[i])return FLOE_AE_UNSUPPORTED;
    uint32_t in=c->input_capacity?c->input_capacity:65536,out=c->output_capacity?c->output_capacity:1048576;
    if(in<256||in>1048576||out<4096||out>16777216)return FLOE_AE_INVALID;
    return 0;
}
int floe_ae_create(const floe_ae_config *c,floe_ae_handle *handle) {
    if(!handle)return FLOE_AE_INVALID;*handle=0;
    int error=valid_config(c);if(error)return error;
    pthread_mutex_lock(&registry);
    if(live||transition||generation==UINT64_MAX) { pthread_mutex_unlock(&registry);return FLOE_AE_BUSY; }
    transition=1;uint64_t id=++generation;pthread_mutex_unlock(&registry);
    AESession *s=calloc(1,sizeof(*s));unsigned char *firmware=NULL,*kernel=NULL,*initrd=NULL;u32 fn=0,kn=0,in=0;
    fenv_t caller;int saved=fegetenv(&caller)==0;
    if(!saved||fesetenv(FE_DFL_ENV)) { error=FLOE_AE_FAULT;goto finished; }
    if(!s){error=FLOE_AE_NOMEM;goto finished;}
    s->handle=id;s->state=FLOE_AE_CREATED;s->deadline_at=UINT64_MAX;s->sequence=1;atomic_init(&s->stop,false);
    if(pthread_mutex_init(&s->mutex,NULL)) { error=FLOE_AE_FAULT;goto finished; }s->mutex_ready=1;
    if(pthread_cond_init(&s->condition,NULL)) { error=FLOE_AE_FAULT;goto finished; }s->condition_ready=1;
    s->input.cap=c->input_capacity?c->input_capacity:65536;s->output.cap=c->output_capacity?c->output_capacity:1048576;s->diagnostic.cap=65536;
    s->input.bytes=malloc(s->input.cap);s->output.bytes=malloc(s->output.cap);s->diagnostic.bytes=malloc(s->diagnostic.cap);
    if(!s->input.bytes||!s->output.bytes||!s->diagnostic.bytes){error=FLOE_AE_NOMEM;goto finished;}
    ae_current=s;
    error=load(c->firmware_path,&firmware,&fn,FLASH_SIZE);if(error)goto finished;
    error=load(c->kernel_path,&kernel,&kn,268435456);if(error)goto finished;
    error=load(c->initrd_path,&initrd,&in,268435456);if(error)goto finished;
    if(c->private_writable_disk_path) {
        size_t n=strnlen(c->private_writable_disk_path,PATH_MAX);if(!n||n==PATH_MAX){error=FLOE_AE_INVALID;goto finished;}
        s->disk_path=malloc(n+1);if(!s->disk_path){error=FLOE_AE_NOMEM;goto finished;}memcpy(s->disk_path,c->private_writable_disk_path,n+1);
    }
    machine_init(&s->machine,(u64)c->ram_mib<<20);if(s->machine.host_error){error=s->machine.host_error;goto finished;}
    if(machine_configure_cpus(&s->machine,c->requested_vcpus)){error=FLOE_AE_UNSUPPORTED;goto finished;}
    s->endpoint.owner=s;s->machine.uart_ep=&s->endpoint;
    if(s->disk_path){s->machine.drives[0]=(Drive){s->disk_path,false};s->machine.n_drives=1;}
    memcpy(s->machine.flash,firmware,fn);
    error=platform_build(&s->machine);if(error)goto finished;
    fwcfg_set_legacy_kernel(s->machine.fwcfg,kernel,kn,initrd,in,c->command_line?c->command_line:"");
    if(!fwcfg_valid(s->machine.fwcfg)){error=FLOE_AE_NOMEM;goto finished;}
    cpu_reset(&s->machine.cpu,FLASH_BASE,1);fpsr_sync(&s->machine.cpu);
    for(unsigned h=0;h<s->machine.ncpus;h++)if(fegetenv(&s->guest_environment[h])){error=FLOE_AE_FAULT;goto finished;}
    error=ae_parallel_init(s);
finished:
    free(firmware);free(kernel);free(initrd);
    if(error){dispose(s);s=NULL;}
    ae_fp_unbind();ae_current=NULL;if(saved)fesetenv(&caller);
    pthread_mutex_lock(&registry);live=s;transition=0;if(s)*handle=id;pthread_mutex_unlock(&registry);
    return error;
}
static AESession *locked(floe_ae_handle h) {
    pthread_mutex_lock(&registry);AESession *s=live;
    if(!s||!h||s->handle!=h){pthread_mutex_unlock(&registry);return NULL;}
    pthread_mutex_lock(&s->mutex);return s;
}
static void unlock(AESession *s) { pthread_mutex_unlock(&s->mutex);pthread_mutex_unlock(&registry); }

int floe_ae_run_slice(floe_ae_handle h,uint64_t max_ns,uint64_t max_insn,floe_ae_slice *out) {
    if(!out||out->struct_size<sizeof(*out)||!max_ns||max_ns>100000000||!max_insn||max_insn>100000000)return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    if(s->state==FLOE_AE_POWEROFF||s->state==FLOE_AE_FAILED||atomic_load(&s->stop)) {
        *out=(floe_ae_slice){.struct_size=sizeof(*out),.reason=s->state==FLOE_AE_POWEROFF?FLOE_AE_GUEST_OFF:s->state==FLOE_AE_FAILED?FLOE_AE_GUEST_FAULT:FLOE_AE_CANCELLED,.state=(uint32_t)s->state,.wake_sequence=s->sequence,.next_deadline_ns=UINT64_MAX};
        int e=s->state==FLOE_AE_FAILED?FLOE_AE_FAULT:0;unlock(s);return e;
    }
    s->active=1;s->state=FLOE_AE_RUNNING;unlock(s);
    uint64_t began=ae_now_ns(),executed=0,reset_delta=0,observed_sequence=0;uint32_t reason=FLOE_AE_BUDGET;int error=0;
    fenv_t caller;int saved=fegetenv(&caller)==0;ae_current=s;
    if(!saved||fesetenv(FE_DFL_ENV)){error=FLOE_AE_FAULT;goto complete;}
    const AEParallelCallbacks callbacks={pd_step,machine_tick,fwcfg_service,virtio_blk_service,fpsr_sync};
    AEParallelResult result=ae_parallel_run(s,max_ns,max_insn,&callbacks);
    executed=result.instructions;reset_delta=result.resets;observed_sequence=result.observed_sequence;
    reason=result.reason;error=result.error;
    /* Worker host flags were folded on that worker. Only software pending
     * may be committed here; coordinator/caller host flags never enter CPU0. */
    s->machine.cpu.fpsr|=s->machine.cpu.exec.fp_pending;s->machine.cpu.exec.fp_pending=0;
    AE_COMPLETE_OBSERVER(s);
complete:
    s->machine.executing_cpu=NULL;
    if(saved)fesetenv(&caller);ae_fp_unbind();ae_current=NULL;
    uint64_t deadline=reason==FLOE_AE_OUTPUT_FULL?UINT64_MAX:next_deadline(&s->machine),now=ae_now_ns();
    pthread_mutex_lock(&registry);pthread_mutex_lock(&s->mutex);
    s->active=0;s->slice_calls++;s->resets+=reset_delta;s->instructions+=executed;s->snapshot_pc=s->machine.cpu.pc;
    if(error){s->error=error;s->state=FLOE_AE_FAILED;reason=FLOE_AE_GUEST_FAULT;}
    else if(reason==FLOE_AE_GUEST_OFF)s->state=FLOE_AE_POWEROFF;
    else if(reason==FLOE_AE_CANCELLED||atomic_load(&s->stop)){s->state=FLOE_AE_STOPPED;reason=FLOE_AE_CANCELLED;}
    else s->state=FLOE_AE_CREATED;
    s->deadline_at=(deadline==UINT64_MAX||deadline>UINT64_MAX-now)?UINT64_MAX:now+deadline;s->last_reason=reason;
    *out=(floe_ae_slice){.struct_size=sizeof(*out),.reason=reason,.instructions=executed,.host_elapsed_ns=now-began,.wake_sequence=(reason==FLOE_AE_PARKED||reason==FLOE_AE_OUTPUT_FULL)?observed_sequence:s->sequence,.next_deadline_ns=deadline,.state=(uint32_t)s->state};
    unlock(s);return error?FLOE_AE_FAULT:0;
}
int floe_ae_request_stop(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;atomic_store_explicit(&s->stop,true,memory_order_release);ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_resume(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    int e=0;if(s->active||s->waiters)e=FLOE_AE_BUSY;else if(s->state==FLOE_AE_FAILED||s->state==FLOE_AE_POWEROFF)e=FLOE_AE_INVALID;
    else {atomic_store(&s->stop,false);s->state=FLOE_AE_CREATED;s->deadline_at=0;s->last_reason=FLOE_AE_BUDGET;ae_signal_locked(s);}unlock(s);return e;
}
static int read_ring(floe_ae_handle h,void *p,size_t n,size_t *got,int diagnostic) {
    if(!got||(!p&&n))return FLOE_AE_INVALID;*got=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    *got=ae_ring_read(diagnostic?&s->diagnostic:&s->output,p,n);if(*got&&!diagnostic)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_console_read(floe_ae_handle h,void *p,size_t n,size_t *got){return read_ring(h,p,n,got,0);}
int floe_ae_diagnostic_read(floe_ae_handle h,void *p,size_t n,size_t *got){return read_ring(h,p,n,got,1);}
int floe_ae_console_write(floe_ae_handle h,const void *p,size_t n,size_t *accepted) {
    if(!accepted||(!p&&n))return FLOE_AE_INVALID;*accepted=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->state==FLOE_AE_POWEROFF||s->state==FLOE_AE_FAILED){unlock(s);return FLOE_AE_INVALID;}
    *accepted=ae_ring_write(&s->input,p,n);if(*accepted)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_get_stats(floe_ae_handle h,floe_ae_stats *out) {
    if(!out||out->struct_size<sizeof(*out))return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    *out=(floe_ae_stats){.struct_size=sizeof(*out),.state=s->state,.instructions=s->instructions,.pc=s->snapshot_pc,.slice_calls=s->slice_calls,.park_waits=s->park_waits,.wake_sequence=s->sequence,.input_queued=s->input.count,.output_queued=s->output.count,.diagnostic_dropped=s->diagnostic_dropped,.ram_bytes=s->machine.ram_size,.flash_bytes=s->machine.flash_size,.owned_disk_fds=s->machine.n_blk,.reset_count=s->resets,.supported_vcpus=s->machine.ncpus,.active_slice=s->active,.last_error=s->error};unlock(s);return 0;
}
int floe_ae_wait_event(floe_ae_handle h,uint64_t expected,uint64_t max_ns,uint64_t *new_sequence) {
    if(!new_sequence||max_ns>60000000000ULL)return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}s->waiters++;s->park_waits++;
    pthread_mutex_unlock(&registry);
    uint64_t now=ae_now_ns(),wait=max_ns;
    if(s->last_reason!=FLOE_AE_OUTPUT_FULL&&s->deadline_at!=UINT64_MAX){uint64_t remain=s->deadline_at>now?s->deadline_at-now:0;if(remain<wait)wait=remain;}
    if(s->last_reason!=FLOE_AE_PARKED&&s->last_reason!=FLOE_AE_OUTPUT_FULL)wait=0;
    if(s->last_reason==FLOE_AE_OUTPUT_FULL&&s->output.cap-s->output.count>=1024)wait=0;
    if(wait&&s->sequence==expected&&!atomic_load(&s->stop)) {
        struct timespec relative={(time_t)(wait/1000000000),(long)(wait%1000000000)};
        pthread_cond_timedwait_relative_np(&s->condition,&s->mutex,&relative);
    }
    *new_sequence=s->sequence;s->waiters--;pthread_mutex_unlock(&s->mutex);return 0;
}
int floe_ae_destroy(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    live=NULL;transition=1;unlock(s);
    fenv_t caller;int saved=fegetenv(&caller)==0;fesetenv(FE_DFL_ENV);ae_current=s;
    dispose(s);ae_fp_unbind();ae_current=NULL;if(saved)fesetenv(&caller);
    pthread_mutex_lock(&registry);transition=0;pthread_mutex_unlock(&registry);return saved?0:FLOE_AE_FAULT;
}

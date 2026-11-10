/* SPDX-License-Identifier: MPL-2.0 */
/* Embedded runtime: session registry, slice coordination, the version-1
 * console ABI on channel 0, and the version-2 device/channel operations.
 *
 * Version-1 callers keep the exact original contract. Version 2 adds device
 * configuration at create (network/NAT, loopback port forwards, contained 9P
 * shares, extra virtio-consoles) plus per-channel byte and geometry
 * operations. All configuration strings are deep-copied into the session and
 * released with it; machine devices are built during create and destroyed
 * with it after every worker is quiet. */
#include "embedded_internal.h"
#include "parallel_runtime.h"
#include "sysreg.h"
#include "mmu.h"
#include "../Source/src/net/usernet.h"
#include "net_wait.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/stat.h>
#include <errno.h>
#include <limits.h>

#ifndef AE_COMPLETE_OBSERVER
#define AE_COMPLETE_OBSERVER(s) ((void)0)
#endif
/* The readiness park now sizes its descriptor set from what the backend
 * actually reports (see net_wait.h), bounded there by AE_NET_WAIT_FD_CEILING,
 * so no fixed local cap is needed here. */
static pthread_mutex_t registry=PTHREAD_MUTEX_INITIALIZER;
static AESession *live;
static uint64_t generation;
static int transition;
uint64_t ae_now_ns(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec; }
static char *ae_strdup_bounded(const char *text,size_t limit) {
    if(!text)return NULL;size_t n=strnlen(text,limit);if(!n||n==limit)return NULL;
    char *copy=malloc(n+1);if(copy)memcpy(copy,text,n+1);return copy;
}
static int parse_ipv4(const char *text,uint32_t *out) {
    unsigned a,b,c,d;char tail;
    if(!text||sscanf(text,"%u.%u.%u.%u%c",&a,&b,&c,&d,&tail)!=4)return -1;
    if(a>255||b>255||c>255||d>255)return -1;
    *out=((uint32_t)a<<24)|((uint32_t)b<<16)|((uint32_t)c<<8)|(uint32_t)d;return 0;
}
static void free_device_config(AESession *s) {
    free(s->dns_text);s->dns_text=NULL;s->dns_server=0;
    for(uint32_t i=0;i<s->share_count;i++){free(s->share[i].path);free(s->share[i].tag);s->share[i].path=NULL;s->share[i].tag=NULL;}
    s->share_count=0;s->fwd_count=0;s->requested_consoles=0;
}
static void dispose(AESession *s) {
    if(!s)return;
    if(s->wake_pipe_ready){close(s->wake_pipe[0]);close(s->wake_pipe[1]);s->wake_pipe[0]=s->wake_pipe[1]=-1;s->wake_pipe_ready=0;}
    ae_parallel_destroy(s);
    ae_machine_destroy(&s->machine);
    for(uint32_t i=0;i<AE_MAX_CHANNELS;i++){free(s->channels[i].input.bytes);free(s->channels[i].output.bytes);}
    free(s->diagnostic.bytes);free(s->disk_path);
    free_device_config(s);
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
/* ---- version-2 device configuration --------------------------------------
 * Validates and deep-copies the device section. Everything the Machine needs
 * (share descriptors, forward rules, dns target, console count) is stored in
 * session-owned memory so the caller's buffers only need to outlive create.
 */
static int valid_devices(const floe_ae_devices_config *d,AESession *s) {
    if(!d||d->struct_size<sizeof(*d))return FLOE_AE_VERSION;
    for(unsigned i=0;i<4;i++)if(d->reserved[i])return FLOE_AE_UNSUPPORTED;
    if(d->virtio_consoles>FLOE_AE_MAX_CONSOLES)return FLOE_AE_UNSUPPORTED;
    if(d->share_count>FLOE_AE_MAX_SHARES||d->forward_count>FLOE_AE_MAX_NET_FORWARDS)return FLOE_AE_UNSUPPORTED;
    if((d->share_count&&!d->shares)||(d->forward_count&&!d->forwards))return FLOE_AE_INVALID;
    s->requested_consoles=d->virtio_consoles;
    if(d->dns_server) {
        uint32_t ip;if(parse_ipv4(d->dns_server,&ip))return FLOE_AE_INVALID;
        s->dns_text=ae_strdup_bounded(d->dns_server,64);if(!s->dns_text)return FLOE_AE_NOMEM;
        s->dns_server=ip;
    }
    for(uint32_t i=0;i<d->share_count;i++) {
        const floe_ae_share_config *sh=&d->shares[i];
        if(!sh||sh->struct_size<sizeof(*sh)||sh->reserved)return FLOE_AE_VERSION;
        if(!sh->host_path||!sh->mount_tag)return FLOE_AE_INVALID;
        size_t taglen=strnlen(sh->mount_tag,128);if(!taglen||taglen>127)return FLOE_AE_INVALID;
        s->share[i].path=ae_strdup_bounded(sh->host_path,PATH_MAX);
        s->share[i].tag=ae_strdup_bounded(sh->mount_tag,128);
        s->share[i].ro=sh->read_only!=0;
        s->share[i].guest_uid=sh->guest_uid;
        s->share[i].guest_gid=sh->guest_gid;
        if(!s->share[i].path||!s->share[i].tag)return FLOE_AE_NOMEM;
        s->share_count=i+1;   /* copies owned from here on (dispose frees) */
        for(uint32_t j=0;j<i;j++)
            if(!strcmp(s->share[j].tag,s->share[i].tag))return FLOE_AE_INVALID; /* duplicate mount tag */
    }
    for(uint32_t i=0;i<d->forward_count;i++) {
        const floe_ae_net_forward *f=&d->forwards[i];
        if(!f||f->struct_size<sizeof(*f))return FLOE_AE_VERSION;
        if(!f->host_port||f->host_port>65535||!f->guest_port||f->guest_port>65535)return FLOE_AE_INVALID;
        s->fwd[i]=(NetFwd){.is_udp=f->is_udp!=0,.host_port=(int)f->host_port,.guest_port=(int)f->guest_port};
        s->fwd_count=i+1;
        for(uint32_t j=0;j<i;j++)
            if(s->fwd[j].is_udp==s->fwd[i].is_udp&&s->fwd[j].host_port==s->fwd[i].host_port)return FLOE_AE_INVALID;
    }
    return 0;
}
static int valid_config(const floe_ae_config *c,AESession *s) {
    if(!c||c->struct_size<sizeof(*c))return FLOE_AE_VERSION;
    if(c->abi_version!=FLOE_AE_ABI_VERSION&&c->abi_version!=1)return FLOE_AE_VERSION;
    if(c->requested_vcpus<1||c->requested_vcpus>A64_MAX_CPUS)return FLOE_AE_UNSUPPORTED;
    if(!c->firmware_path||c->ram_mib<16||c->ram_mib>1024)return FLOE_AE_INVALID;
    if(c->initrd_path&&!c->kernel_path)return FLOE_AE_INVALID;
    if(c->command_line&&strnlen(c->command_line,4097)>4096)return FLOE_AE_INVALID;
    for(unsigned i=0;i<4;i++)if(c->reserved[i])return FLOE_AE_UNSUPPORTED;
    uint32_t in=c->input_capacity?c->input_capacity:65536,out=c->output_capacity?c->output_capacity:1048576;
    if(in<256||in>1048576||out<4096||out>16777216)return FLOE_AE_INVALID;
    if(c->abi_version==1)return 0;   /* version 1: devices stay disabled */
    const floe_ae_config_v2 *c2=(const floe_ae_config_v2 *)c;
    if(c->struct_size<sizeof(*c2))return FLOE_AE_VERSION;
    return valid_devices(&c2->devices,s);
}
int floe_ae_create(const floe_ae_config *c,floe_ae_handle *handle) {
    if(!handle)return FLOE_AE_INVALID;*handle=0;
    pthread_mutex_lock(&registry);
    if(live||transition||generation==UINT64_MAX) { pthread_mutex_unlock(&registry);return FLOE_AE_BUSY; }
    transition=1;uint64_t id=++generation;pthread_mutex_unlock(&registry);
    AESession *s=calloc(1,sizeof(*s));unsigned char *firmware=NULL,*kernel=NULL,*initrd=NULL;u32 fn=0,kn=0,in=0;
    fenv_t caller;int saved=fegetenv(&caller)==0;
    int error=0;
    if(!saved||fesetenv(FE_DFL_ENV)) { error=FLOE_AE_FAULT;goto finished; }
    if(!s){error=FLOE_AE_NOMEM;goto finished;}
    s->handle=id;s->state=FLOE_AE_CREATED;s->deadline_at=UINT64_MAX;s->sequence=1;atomic_init(&s->stop,false);
    if(pthread_mutex_init(&s->mutex,NULL)) { error=FLOE_AE_FAULT;goto finished; }s->mutex_ready=1;
    if(pthread_cond_init(&s->condition,NULL)) { error=FLOE_AE_FAULT;goto finished; }s->condition_ready=1;
    s->wake_pipe[0]=s->wake_pipe[1]=-1;
    if(pipe(s->wake_pipe)==0) {
        int ok=1;
        for(int e=0;e<2;e++){
            int fl=fcntl(s->wake_pipe[e],F_GETFL),fd=fcntl(s->wake_pipe[e],F_GETFD);
            if(fl<0||fd<0||fcntl(s->wake_pipe[e],F_SETFL,fl|O_NONBLOCK)<0||
               fcntl(s->wake_pipe[e],F_SETFD,fd|FD_CLOEXEC)<0) ok=0;
        }
        if(ok)s->wake_pipe_ready=1;
        else{close(s->wake_pipe[0]);close(s->wake_pipe[1]);s->wake_pipe[0]=s->wake_pipe[1]=-1;}
    } /* a missing wake pipe degrades readiness waits to deadline waits only */
    s->diagnostic.cap=65536;
    s->diagnostic.bytes=malloc(s->diagnostic.cap);
    if(!s->diagnostic.bytes){error=FLOE_AE_NOMEM;goto finished;}
    error=valid_config(c,s);if(error)goto finished;
    uint32_t in_cap=c->input_capacity?c->input_capacity:65536,out_cap=c->output_capacity?c->output_capacity:1048576;
    /* Channel 0 (PL011) plus one channel per requested virtio-console; every
     * ring is bounded exactly like the legacy single-console rings. */
    uint32_t channel_count=1+s->requested_consoles;
    for(uint32_t i=0;i<channel_count;i++) {
        s->channels[i].input.cap=in_cap;s->channels[i].output.cap=out_cap;
        s->channels[i].input.bytes=malloc(in_cap);s->channels[i].output.bytes=malloc(out_cap);
        if(!s->channels[i].input.bytes||!s->channels[i].output.bytes){error=FLOE_AE_NOMEM;goto finished;}
        s->channels[i].present=true;
    }
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
    s->endpoint.owner=s;s->endpoint.channel=0;
    s->machine.uart_ep=&s->endpoint;
    for(uint32_t i=0;i<s->requested_consoles;i++) {
        s->vcon_endpoints[i].owner=s;s->vcon_endpoints[i].channel=1+i;
        s->machine.vcon_ep[i]=&s->vcon_endpoints[i];
    }
    s->machine.n_consoles_req=(int)s->requested_consoles;
    s->machine.dns_server=s->dns_server;
    if(s->disk_path){s->machine.drives[0]=(Drive){s->disk_path,false};s->machine.n_drives=1;}
    for(uint32_t i=0;i<s->share_count;i++) {
        s->machine.shares[i]=(VirtFS){s->share[i].path,s->share[i].tag,s->share[i].ro,
                                      s->share[i].guest_uid,s->share[i].guest_gid};
        s->machine.n_shares++;
    }
    for(uint32_t i=0;i<s->fwd_count;i++) {
        s->machine.net_fwds[i]=s->fwd[i];
        s->machine.n_net_fwds++;
    }
    int net_on=0;
    if(c->abi_version==2)net_on=((const floe_ae_config_v2 *)c)->devices.network_enabled!=0;
    if((s->fwd_count||s->dns_server)&&!net_on){error=FLOE_AE_INVALID;goto finished;} /* rules without a device */
    s->machine.net_enabled=net_on;
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
int floe_ae_notify(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    ae_signal_locked(s);unlock(s);return FLOE_AE_OK;
}
int floe_ae_request_stop(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;atomic_store_explicit(&s->stop,true,memory_order_release);ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_resume(floe_ae_handle h) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    int e=0;if(s->active||s->waiters)e=FLOE_AE_BUSY;else if(s->state==FLOE_AE_FAILED||s->state==FLOE_AE_POWEROFF)e=FLOE_AE_INVALID;
    else {atomic_store(&s->stop,false);s->state=FLOE_AE_CREATED;s->deadline_at=0;s->last_reason=FLOE_AE_BUDGET;ae_signal_locked(s);}unlock(s);return e;
}
/* Channel 0 read/write (the legacy console ABI). */
static int read_ring(floe_ae_handle h,void *p,size_t n,size_t *got,int diagnostic) {
    if(!got||(!p&&n))return FLOE_AE_INVALID;*got=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    *got=ae_ring_read(diagnostic?&s->diagnostic:&s->channels[0].output,p,n);if(*got&&!diagnostic)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_console_read(floe_ae_handle h,void *p,size_t n,size_t *got){return read_ring(h,p,n,got,0);}
int floe_ae_diagnostic_read(floe_ae_handle h,void *p,size_t n,size_t *got){return read_ring(h,p,n,got,1);}
int floe_ae_console_write(floe_ae_handle h,const void *p,size_t n,size_t *accepted) {
    if(!accepted||(!p&&n))return FLOE_AE_INVALID;*accepted=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->state==FLOE_AE_POWEROFF||s->state==FLOE_AE_FAILED){unlock(s);return FLOE_AE_INVALID;}
    *accepted=ae_ring_write(&s->channels[0].input,p,n);if(*accepted)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_get_stats(floe_ae_handle h,floe_ae_stats *out) {
    if(!out||out->struct_size<sizeof(*out))return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    *out=(floe_ae_stats){.struct_size=sizeof(*out),.state=s->state,.instructions=s->instructions,.pc=s->snapshot_pc,.slice_calls=s->slice_calls,.park_waits=s->park_waits,.wake_sequence=s->sequence,.input_queued=s->channels[0].input.count,.output_queued=s->channels[0].output.count,.diagnostic_dropped=s->diagnostic_dropped,.ram_bytes=s->machine.ram_size,.flash_bytes=s->machine.flash_size,.owned_disk_fds=s->machine.n_blk,.reset_count=s->resets,.supported_vcpus=s->machine.ncpus,.active_slice=s->active,.last_error=s->error};unlock(s);return 0;
}
int floe_ae_wait_event(floe_ae_handle h,uint64_t expected,uint64_t max_ns,uint64_t *new_sequence) {
    if(!new_sequence||max_ns>60000000000ULL)return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}s->waiters++;s->park_waits++;
    pthread_mutex_unlock(&registry);
    uint64_t now=ae_now_ns(),wait=max_ns;
    if(s->last_reason!=FLOE_AE_OUTPUT_FULL&&s->deadline_at!=UINT64_MAX){uint64_t remain=s->deadline_at>now?s->deadline_at-now:0;if(remain<wait)wait=remain;}
    if(s->last_reason!=FLOE_AE_PARKED&&s->last_reason!=FLOE_AE_OUTPUT_FULL)wait=0;
    if(s->last_reason==FLOE_AE_OUTPUT_FULL&&s->channels[0].output.cap-s->channels[0].output.count>=1024)wait=0;
    if(wait&&s->sequence==expected&&!atomic_load(&s->stop)) {
        /* Readiness-driven park: the owned wake pipe together with the
         * backend's own descriptor set, each with the exact interest mask the
         * backend computed (read, write-ready, exception) and bounded by the
         * earliest real deadline — the caller cap, the cpu/rtc/budget deadline
         * and the backend's next network timer. Never a fixed poll interval,
         * and no longer POLLIN-only: a descriptor that libslirp wants to write
         * to now wakes the park instead of stalling the guest until an
         * unrelated deadline. The snapshot is taken while holding the session
         * mutex and with s->waiters already incremented, so attach/detach,
         * hostfwd add/remove and destroy all return BUSY and the descriptors
         * cannot change underneath us; net_wait.h additionally dup()s every
         * descriptor so the poll set owns independent references. */
        UserNet *un=s->machine.net?virtio_net_usernet(s->machine.net):NULL;
        pthread_mutex_unlock(&s->mutex);
        bool pipe_ready=ae_net_wait_park(s,un,wait);
        pthread_mutex_lock(&s->mutex);
        if(pipe_ready)ae_wake_drain(s);
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
/* ---- version-2 channel operations --------------------------------------- */
int floe_ae_channel_count(floe_ae_handle h,uint32_t *count) {
    if(!count)return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    uint32_t n=0;for(uint32_t i=0;i<AE_MAX_CHANNELS;i++)if(s->channels[i].present)n++;
    *count=n;unlock(s);return 0;
}
int floe_ae_channel_reset(floe_ae_handle h,uint32_t channel) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    if(channel>=AE_MAX_CHANNELS||!s->channels[channel].present){unlock(s);return FLOE_AE_INVALID;}
    AEChannel *ch=&s->channels[channel];
    ch->input.head=ch->input.count=0;ch->output.head=ch->output.count=0;
    ae_signal_locked(s);unlock(s);return FLOE_AE_OK;
}
int floe_ae_channel_read(floe_ae_handle h,uint32_t channel,void *p,size_t n,size_t *got) {
    if(!got||(!p&&n))return FLOE_AE_INVALID;*got=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(channel>=AE_MAX_CHANNELS||!s->channels[channel].present){unlock(s);return FLOE_AE_INVALID;}
    *got=ae_ring_read(&s->channels[channel].output,p,n);if(*got)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_channel_write(floe_ae_handle h,uint32_t channel,const void *p,size_t n,size_t *accepted) {
    if(!accepted||(!p&&n))return FLOE_AE_INVALID;*accepted=0;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(channel>=AE_MAX_CHANNELS||!s->channels[channel].present){unlock(s);return FLOE_AE_INVALID;}
    if(s->state==FLOE_AE_POWEROFF||s->state==FLOE_AE_FAILED){unlock(s);return FLOE_AE_INVALID;}
    *accepted=ae_ring_write(&s->channels[channel].input,p,n);if(*accepted)ae_signal_locked(s);unlock(s);return 0;
}
int floe_ae_channel_get_winsize(floe_ae_handle h,uint32_t channel,uint16_t *cols,uint16_t *rows) {
    if(!cols||!rows)return FLOE_AE_INVALID;AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(channel>=AE_MAX_CHANNELS||!s->channels[channel].present){unlock(s);return FLOE_AE_INVALID;}
    *cols=s->channels[channel].cols;*rows=s->channels[channel].rows;unlock(s);return 0;
}
int floe_ae_channel_set_winsize(floe_ae_handle h,uint32_t channel,uint16_t cols,uint16_t rows) {
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(channel>=AE_MAX_CHANNELS||!s->channels[channel].present){unlock(s);return FLOE_AE_INVALID;}
    AEChannel *ch=&s->channels[channel];
    if(ch->cols!=cols||ch->rows!=rows){ch->cols=cols;ch->rows=rows;ch->winch=true;}
    ae_signal_locked(s);unlock(s);return 0;
}
/* ---- version-2 network operations --------------------------------------- */
/* Live port-forward management. Add/remove run on the live usernet backend;
 * bind failures (EADDRINUSE and friends) surface as FLOE_AE_IO with the host
 * error preserved in the session diagnostic via the backend's own note.
 * Device mutation requires the same quiescence as share attach/detach: while
 * a slice or a readiness wait is active the coordinator owns the backend and
 * these return FLOE_AE_BUSY for the caller to retry between slices. */
int floe_ae_net_forward_add(floe_ae_handle h,const floe_ae_net_forward *rule) {
    if(!rule||rule->struct_size<sizeof(*rule))return FLOE_AE_VERSION;
    if(rule->is_udp>1||!rule->host_port||rule->host_port>65535||!rule->guest_port||rule->guest_port>65535)return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    int error=0;
    UserNet *un=virtio_net_usernet(s->machine.net);
    if(!un)error=FLOE_AE_UNSUPPORTED;
    else {
        int r=usernet_add_hostfwd(un,rule->is_udp!=0,(uint16_t)rule->host_port,(uint16_t)rule->guest_port);
        if(r==-ENOBUFS)error=FLOE_AE_UNSUPPORTED;          /* rule table full */
        else if(r!=0)error=FLOE_AE_IO;                     /* bind/listen: see diagnostic */
    }
    unlock(s);return error;
}
int floe_ae_net_forward_remove(floe_ae_handle h,uint32_t is_udp,uint32_t host_port) {
    if(is_udp>1||!host_port||host_port>65535)return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    int error=0;
    UserNet *un=virtio_net_usernet(s->machine.net);
    if(!un)error=FLOE_AE_UNSUPPORTED;
    else if(usernet_remove_hostfwd(un,is_udp!=0,(uint16_t)host_port)!=0)error=FLOE_AE_INVALID; /* no such rule */
    unlock(s);return error;
}
int floe_ae_net_get_info(floe_ae_handle h,floe_ae_net_info *out) {
    if(!out||out->struct_size<sizeof(*out))return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    UserNet *un=virtio_net_usernet(s->machine.net);
    memset(out,0,sizeof(*out));
    out->struct_size=sizeof(*out);
    for(int i=0;i<s->machine.n_fs;i++) {
        int state=0;virtio_9p_get_info(s->machine.fs[i],&state,NULL,NULL,NULL,NULL,NULL);
        if(state==FLOE_AE_SHARE_ATTACHED)out->share_count++;
    }
    out->console_count=(uint32_t)s->machine.n_vcon;
    if(s->machine.net&&un) {
        unsigned tcp=0,udp=0;uint64_t in=0,ok=0,ref=0;
        usernet_get_stats(un,&in,&ok,&ref,&tcp,&udp);
        out->network_enabled=1;
        /* dns_server keeps its exact documented meaning: the host-order IPv4
         * resolver guest DNS actually relays to, or 0 when there is none. On
         * an IPv6-only host that field is legitimately 0 while DNS still
         * works over IPv6, so dns_available is no longer derived from it —
         * it reports the versioned resolver snapshot, which knows both
         * families. Never substitute the guest-visible virtual nameserver
         * (10.0.2.3) for a host resolver: that would claim a host DNS that
         * does not exist. */
        UserNetDnsInfo dns;memset(&dns,0,sizeof(dns));
        out->dns_server=usernet_get_dns_info(un,&dns)==0
            ? dns.v4_addr : usernet_dns_server(un);
        out->dns_available=(dns.v4_valid||dns.v6_valid)?1u:0u;
        out->forward_count=(uint32_t)s->machine.n_net_fwds;
        out->active_tcp=tcp;out->active_udp=udp;
        out->rx_frames=in;out->tx_frames=ok;out->rx_refused=ref;
    }
    unlock(s);return 0;
}
/* ---- live project-share operations ---------------------------------------
 * See the header contract: attach/detach mutate device state and therefore
 * require machine quiescence (FLOE_AE_BUSY while a slice or readiness wait
 * owns the machine; the registry retries between slices). info is read-only.
 */
int floe_ae_share_attach(floe_ae_handle h,uint32_t slot,const floe_ae_share_config *cfg) {
    if(!cfg||cfg->struct_size<sizeof(*cfg)||cfg->reserved)return FLOE_AE_VERSION;
    if(slot>=FLOE_AE_MAX_SHARES)return FLOE_AE_UNSUPPORTED;      /* capacity is explicit */
    if(!cfg->host_path||!cfg->mount_tag)return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    int error=0;
    if(slot>=(uint32_t)s->machine.n_fs)error=FLOE_AE_UNSUPPORTED;
    else {
        struct VirtIO9P *v=s->machine.fs[slot];
        uint16_t tag_len=0;
        const char *tag=virtio_9p_slot_tag(v,&tag_len);
        char want[128];size_t wl=strnlen(cfg->mount_tag,sizeof(want));
        if(!wl||wl>=sizeof(want)){unlock(s);return FLOE_AE_INVALID;}
        memcpy(want,cfg->mount_tag,wl);want[wl]='\0';
        if(!tag||(size_t)tag_len!=wl||memcmp(tag,want,wl))error=FLOE_AE_INVALID; /* tag is fixed per slot */
        else {
            int r=virtio_9p_attach_root(v,cfg->host_path,cfg->guest_uid,cfg->guest_gid,cfg->read_only!=0);
            if(r==-EBUSY)error=FLOE_AE_BUSY;
            else if(r!=0)error=FLOE_AE_IO;
        }
    }
    unlock(s);return error;
}
int floe_ae_share_detach(floe_ae_handle h,uint32_t slot,uint32_t flags) {
    if(slot>=FLOE_AE_MAX_SHARES)return FLOE_AE_UNSUPPORTED;
    if(flags&~FLOE_AE_SHARE_FORCE)return FLOE_AE_INVALID;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    if(s->active||s->waiters){unlock(s);return FLOE_AE_BUSY;}
    int error=0;
    if(slot>=(uint32_t)s->machine.n_fs)error=FLOE_AE_INVALID;
    else if(virtio_9p_detach_root(s->machine.fs[slot],(flags&FLOE_AE_SHARE_FORCE)!=0)!=0)error=FLOE_AE_BUSY;
    unlock(s);return error;
}
int floe_ae_share_get_info(floe_ae_handle h,uint32_t slot,floe_ae_share_info *out) {
    if(!out||out->struct_size<sizeof(*out))return FLOE_AE_INVALID;
    if(slot>=FLOE_AE_MAX_SHARES)return FLOE_AE_UNSUPPORTED;
    AESession *s=locked(h);if(!s)return FLOE_AE_STALE;
    int error=0;
    if(slot>=(uint32_t)s->machine.n_fs)error=FLOE_AE_INVALID;
    else {
        struct VirtIO9P *v=s->machine.fs[slot];
        const char *tag=NULL;uint16_t tag_len=0;
        memset(out,0,sizeof(*out));out->struct_size=sizeof(*out);out->slot=slot;
        tag=virtio_9p_slot_tag(v,&tag_len);
        if(tag){size_t n=tag_len<sizeof(out->mount_tag)-1?tag_len:sizeof(out->mount_tag)-1;memcpy(out->mount_tag,tag,n);}
        uint64_t generation=0;int state=0,ro=0;
        virtio_9p_get_info(v,&state,&generation,&out->open_fids,&out->guest_uid,&out->guest_gid,&ro);
        out->state=(uint32_t)state;
        out->generation=(uint32_t)generation;
        out->read_only=(uint32_t)ro;
    }
    unlock(s);return error;
}

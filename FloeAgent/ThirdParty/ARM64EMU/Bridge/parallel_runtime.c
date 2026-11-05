/* SPDX-License-Identifier: MPL-2.0 */
/* True host workers. Device state belongs to this call's coordinator, while
 * each CPU/cache/fenv belongs to its worker until an all-worker quiet point.
 * Lock order: session mutex -> parallel mutex. Never acquire session, RAM or
 * monitor locks while holding parallel mutex. Mailboxes carry value payloads. */
#include "parallel_runtime.h"
#include "parallel_iface.h"
#include "mmu.h"
#include "sysreg.h"
#include "../Source/src/net/usernet.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <poll.h>
#include <unistd.h>
/* Qualification-only observation; defaults erase at preprocessing, with no
 * production callback/extra per-boundary function call or synchronization. */
#ifndef AE_FASTPOLL_OBSERVE
#define AE_FASTPOLL_OBSERVE(c,phase) ((void)0)
#endif

typedef enum { RPC_NONE,RPC_BUS,RPC_TIMER,RPC_PSCI } RPCType;
typedef enum { MAIL_EMPTY,MAIL_PENDING,MAIL_SERVICING,MAIL_DONE } MailState;
typedef struct AERPC {
    RPCType type;MailState state;
    u64 address,value,args[4],pc,icount;unsigned size;bool write,is_hvc;
    MachineTimerView timer;
    MachineBusReply bus;
    u64 result;unsigned action; /* bit0 CPU_OFF, bit1 retention WFI */
} AERPC;
typedef struct AEHart AEHart;
typedef struct AEParallel {
    AESession *session;
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    bool mutex_ready,condition_ready,active,closing,shutdown;
    atomic_bool abort_run;
    _Atomic u64 tlbi_epoch;
    u64 deadline,remaining,executed,progress;
    unsigned next_hart;
    AEParallelCallbacks callbacks;
    AEHart *hart;
    atomic_uint in_pd,max_in_pd;
} AEParallel;
struct AEHart {
    AEParallel *parallel;unsigned index;
    pthread_t thread;pthread_cond_t condition;
    bool condition_ready,started,busy,reset_pending,quiet_fp,await_yield;
    u64 ticket,boot_entry,boot_context,applied_epoch,quantum_start;
    u32 fp_generation;
    _Atomic u64 ack_epoch;
    atomic_int power;
    atomic_bool irq,event;
    atomic_uint poll_pending;
    MachineParallelPollView poll_view;
    bool halted,failed,fiq;CPUSleep sleep; /* publication protected by parallel mutex */
    MachineTimerView timer;          /* coordinator-owned; updated by RPC */
    AERPC request;
    u64 native_id,total_retired,cpu_ns;
};
static _Thread_local AEHart *worker;
#ifndef AE_PARALLEL_TEST_BOUNDARY_DEFINED
__attribute__((weak,noinline,visibility("hidden")))
void ae_parallel_test_boundary(CPU *c,unsigned point){(void)c;(void)point;}
#endif
static AEParallel *parallel(Machine *m){return m->parallel_owner;}
static AEHart *current(CPU *c){return worker&&worker->parallel->session->handle&&c==machine_cpu(c->m,worker->index)?worker:NULL;}
static u64 thread_cpu_ns(void){
    struct timespec t;if(clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t))return 0;
    return (u64)t.tv_sec*1000000000ULL+(u64)t.tv_nsec;
}
static void changed(AEParallel *p){
    p->progress++;pthread_cond_broadcast(&p->changed);
    /* The coordinator now parks in poll(2), not only p->changed. Publish
     * every worker/RPC transition to that same wait set. The pipe lifetime
     * covers all workers, writes are nonblocking and need no session lock
     * (taking it under p->mutex would invert the control-side lock order).
     * EAGAIN already means an unread wake is pending. */
    AESession *s=p->session;
    if(s->wake_pipe_ready){unsigned char byte=0;(void)write(s->wake_pipe[1],&byte,1);}
}
static void enter_pd(AEHart *h){
    AEParallel *p=h->parallel;unsigned n=atomic_fetch_add_explicit(&p->in_pd,1,memory_order_relaxed)+1;
    unsigned old=atomic_load_explicit(&p->max_in_pd,memory_order_relaxed);
    while(n>old&&!atomic_compare_exchange_weak_explicit(&p->max_in_pd,&old,n,memory_order_relaxed,memory_order_relaxed)){}
}
static void leave_pd(AEHart *h){atomic_fetch_sub_explicit(&h->parallel->in_pd,1,memory_order_relaxed);}
/* Must be called outside parallel mutex and at an instruction boundary. No
 * other thread mutates this MMU/PD bank. An idle ACK never edits a cache: the
 * applied epoch remains old, so re-entry must flush before fetching. */
static void apply_epoch(AEHart *h){
    AEParallel *p=h->parallel;u64 epoch=atomic_load_explicit(&p->tlbi_epoch,memory_order_acquire);
    if(epoch==h->applied_epoch)return;
    tlb_flush_all(machine_cpu(&p->session->machine,h->index));h->applied_epoch=epoch;
    atomic_store_explicit(&h->ack_epoch,epoch,memory_order_release);
    pthread_mutex_lock(&p->mutex);changed(p);pthread_mutex_unlock(&p->mutex);
}
static void apply_epoch_locked(AEHart *h){
    pthread_mutex_unlock(&h->parallel->mutex);apply_epoch(h);pthread_mutex_lock(&h->parallel->mutex);
}
static bool all_acked(AEParallel *p,u64 epoch){
    for(unsigned i=0;i<p->session->machine.ncpus;i++)
        if(atomic_load_explicit(&p->hart[i].ack_epoch,memory_order_acquire)<epoch)return false;
    return true;
}
static void wait_epoch(AEHart *h,u64 epoch){
    AEParallel *p=h->parallel;
    pthread_mutex_lock(&p->mutex);
    while(!all_acked(p,epoch)){
        /* Simultaneous TLBI callers service each other's incoming epoch before
         * waiting. A waiting CPU never retains a RAM/monitor/device lock. */
        apply_epoch_locked(h);
        if(!all_acked(p,epoch))pthread_cond_wait(&p->changed,&p->mutex);
    }
    pthread_mutex_unlock(&p->mutex);
}
static void parallel_tlbi(CPU *c,u64 va,bool page){
    (void)va;(void)page;AEHart *h=current(c);AEParallel *p=parallel(c->m);
    if(!h){/* coordinator/fixture call is legal only at all-worker quiescence */
        for(unsigned i=0;i<c->m->ncpus;i++)tlb_flush_all(machine_cpu(c->m,i));return;
    }
    pthread_mutex_lock(&p->mutex);
    u64 epoch=atomic_fetch_add_explicit(&p->tlbi_epoch,1,memory_order_acq_rel)+1;
    if(!epoch){c->m->host_error=FLOE_AE_FAULT;atomic_store(&p->abort_run,true);}
    for(unsigned i=0;i<c->m->ncpus;i++){
        AEHart *other=&p->hart[i];
        atomic_store_explicit(&other->poll_pending,1,memory_order_release);
        if(!other->busy)atomic_store_explicit(&other->ack_epoch,epoch,memory_order_release);
        else pthread_cond_signal(&other->condition);
    }
    pthread_cond_broadcast(&p->changed);pthread_mutex_unlock(&p->mutex);
    AE_FASTPOLL_OBSERVE(c,2); /* epoch/value and pending already published */
    apply_epoch(h);leave_pd(h);wait_epoch(h,epoch);enter_pd(h);
}
static void parallel_barrier(CPU *c,unsigned kind){
    AEHart *h=current(c);if(!h)return;
    /* Host memory transactions and synchronous device RPC have completed on
     * return. DSB additionally waits broadcast TLB completion; stronger full
     * host fences are used for all shareability options in this prototype. */
    if(kind==4){leave_pd(h);apply_epoch(h);wait_epoch(h,atomic_load(&h->parallel->tlbi_epoch));enter_pd(h);}
    if(kind==6){apply_epoch(h);tlb_flush_all(c);} /* ISB refetches current code */
    atomic_thread_fence(memory_order_seq_cst);
}
static const MachineParallelPollView *poll_view(CPU *c){
    AEHart *h=current(c);
    if(!h||c->m!=&h->parallel->session->machine)return NULL;
    return &h->poll_view;
}
static bool parallel_poll(CPU *c){
    AEHart *h=current(c);if(!h)return false;AEParallel *p=h->parallel;
    /* Clear BEFORE rescan. A later producer either enters this rescan or
     * leaves 1 for the next boundary; never clear after consuming values. */
    atomic_exchange_explicit(&h->poll_pending,0,memory_order_acq_rel);
    AE_FASTPOLL_OBSERVE(c,0);
    apply_epoch(h);
    c->irq_line=atomic_load_explicit(&h->irq,memory_order_acquire); /* private FIQ is preserved */
    if(atomic_exchange_explicit(&h->event,false,memory_order_acq_rel))c->event=true;
    if(c->halted&&(c->irq_line||c->fiq_line||(c->sleep==CPU_SLEEP_WFE&&c->event))){
        if(c->sleep==CPU_SLEEP_WFE)c->event=false;cpu_wake(c);
    }
    AE_FASTPOLL_OBSERVE(c,1);
    if(atomic_load_explicit(&p->abort_run,memory_order_acquire)||
       atomic_load_explicit(&p->session->stop,memory_order_acquire)||
       atomic_load_explicit(&c->m->system_off,memory_order_acquire)||
       atomic_load_explicit(&c->m->system_reset,memory_order_acquire)||
       atomic_load(&c->m->host_error)||memory_sync_error(c->m)){
        c->owner_yield=true;return true;
    }
    return false;
}
static void wake_harts(Machine *m,unsigned mask){
    AEParallel *p=parallel(m);pthread_mutex_lock(&p->mutex);
    for(unsigned i=0;i<m->ncpus;i++)if(mask&(1u<<i)){
        AEHart *h=&p->hart[i];if(atomic_load(&h->power)!=CPU_POWER_ON)continue;
        atomic_store_explicit(&h->event,true,memory_order_release);
        atomic_store_explicit(&h->poll_pending,1,memory_order_release);
        /* An event wakes WFE; it does not manufacture an IRQ for WFI. */
        if(h->sleep==CPU_SLEEP_WFE)h->halted=false;
        if(h->started)pthread_cond_signal(&h->condition);
    }
    changed(p);pthread_mutex_unlock(&p->mutex);
}
static CPUPower hart_power(Machine *m,unsigned i){return (CPUPower)atomic_load_explicit(&parallel(m)->hart[i].power,memory_order_acquire);}
static void publish_irq(Machine *m,unsigned i,bool level){
    AEParallel *p=parallel(m);AEHart *h=&p->hart[i];
    /* GIC rescans publish every hart's level. An already deasserted line has
     * no new value: avoid its mutex, full-poll request and readiness-pipe wake.
     * Never clear pending here: a falling edge/event/TLBI may be unconsumed.
     * Asserted levels still take the original path to wake a sleeping hart.
     * The acquire load is the no-op's linearization point; a later assertion
     * remains a later publication, with its own pending bit and wake. */
    if(!level&&!atomic_load_explicit(&h->irq,memory_order_acquire))return;
    pthread_mutex_lock(&p->mutex);atomic_store_explicit(&h->irq,level,memory_order_release);
    /* Deassertion is a publication too; leaving a stale true IRQ is invalid. */
    atomic_store_explicit(&h->poll_pending,1,memory_order_release);
    if(level){h->halted=false;if(h->started)pthread_cond_signal(&h->condition);}
    changed(p);pthread_mutex_unlock(&p->mutex);
}
static AERPC rpc(CPU *c,AERPC request){
    AEHart *h=current(c);AEParallel *p=h->parallel;
    leave_pd(h);pthread_mutex_lock(&p->mutex);
    request.state=MAIL_PENDING;h->request=request;changed(p);
    while(h->request.state!=MAIL_DONE){
        apply_epoch_locked(h);
        if(h->request.state!=MAIL_DONE)pthread_cond_wait(&h->condition,&p->mutex);
    }
    AERPC reply=h->request;h->request.state=MAIL_EMPTY;pthread_mutex_unlock(&p->mutex);enter_pd(h);return reply;
}
static bool bus_access(CPU *c,u64 address,unsigned size,bool write,u64 value,MachineBusReply *out){
    if(!current(c))return false;
    *out=rpc(c,(AERPC){.type=RPC_BUS,.address=address,.size=size,.write=write,.value=value,.pc=c->cur_insn_pc,.icount=c->icount}).bus;return true;
}
static bool timer_publish(CPU *c){
    if(!current(c))return false;
    MachineTimerView view={c->power,c->cntp_ctl,c->cntp_cval,c->cntv_ctl,c->cntv_cval,c->cntvoff};
    (void)rpc(c,(AERPC){.type=RPC_TIMER,.timer=view});return true;
}
static bool timer_view(Machine *m,unsigned i,MachineTimerView *out){
    AEParallel *p=parallel(m);*out=p->hart[i].timer;out->power=hart_power(m,i);return true;
}
static bool parallel_psci(CPU *c,bool is_hvc){
    if(!current(c))return false;
    AERPC request={.type=RPC_PSCI,.is_hvc=is_hvc};for(unsigned i=0;i<4;i++)request.args[i]=c->x[i];
    AERPC reply=rpc(c,request);
    if(reply.action&1){ae_parallel_test_boundary(c,2);memory_monitor_clear(c);c->power=CPU_POWER_OFF;c->sleep=CPU_SLEEP_NONE;c->halted=true;c->owner_yield=true;}
    else {c->x[0]=reply.result;if(reply.action&2)cpu_sleep(c,CPU_SLEEP_WFI);}
    if(!(reply.action&1))ae_parallel_test_boundary(c,3);
    if(atomic_load(&c->m->system_off)||atomic_load(&c->m->system_reset))c->owner_yield=true;
    return true;
}
static u64 counter_ticks(CPU *c){
    AEHart *h=current(c);u64 value=atomic_load_explicit(&c->m->virtual_ticks,memory_order_relaxed);
    return h?value+c->icount-h->quantum_start:value;
}
static const MachineParallelOps operations={
    .wake_harts=wake_harts,.poll_cpu=parallel_poll,.bus_access=bus_access,.power=hart_power,.irq=publish_irq,
    .poll_view=poll_view,
    .timer_publish=timer_publish,.timer_view=timer_view,.psci=parallel_psci,.tlbi=parallel_tlbi,.barrier=parallel_barrier,.counter_ticks=counter_ticks
};
/* PSCI values are interface constants; no firmware/Linux implementation is
 * embedded. The serial implementation's validation/return semantics are kept. */
static bool psci_supported(u32 f){
    switch(f){case 0x84000000:case 0x84000001:case 0xc4000001:case 0x84000002:
    case 0x84000003:case 0xc4000003:case 0x84000004:case 0xc4000004:case 0x84000006:
    case 0x84000008:case 0x84000009:case 0x8400000a:return true;default:return false;}
}
static void psci_service(AEParallel *p,unsigned source,AERPC *r){
    Machine *m=&p->session->machine;u32 fn=(u32)r->args[0];bool wide=(fn&(1u<<30))!=0;
    u64 a=wide?r->args[1]:(u32)r->args[1],b=wide?r->args[2]:(u32)r->args[2],context=wide?r->args[3]:(u32)r->args[3];
    r->result=(u64)-1;
    switch(fn){
    case 0x84000000:r->result=0x10000;break;
    case 0x8400000a:r->result=psci_supported((u32)r->args[1])?0:(u64)-1;break;
    case 0x84000006:r->result=2;break;
    case 0x84000004:case 0xc4000004:{
        if(b>3||(a&~0xff00ffffffULL)){r->result=(u64)-2;break;}
        u64 low=b==0?0:b==1?0xff:b==2?0xffff:0xffffff,mask=0xff00ffffffULL&~low;
        bool found=false,pending=false;u64 result=1;
        for(unsigned i=0;i<m->ncpus;i++)if(((u64)i&mask)==(a&mask)){
            found=true;CPUPower state=hart_power(m,i);if(state==CPU_POWER_ON){result=0;break;}
            if(state==CPU_POWER_ON_PENDING)pending=true;
        }
        r->result=!found?(u64)-2:result==0?0:pending?2:1;break;
    }
    case 0x84000003:case 0xc4000003:{
        if((a&~0xff00ffffffULL)||a>=m->ncpus){r->result=(u64)-2;break;}
        if((b&3)||(!ram_ptr(m,b,4)&&!(b>=m->flash_base&&m->flash_size>=4&&b-m->flash_base<=m->flash_size-4))){r->result=(u64)-9;break;}
        pthread_mutex_lock(&p->mutex);AEHart *h=&p->hart[a];CPUPower state=(CPUPower)atomic_load(&h->power);
        if(state==CPU_POWER_ON)r->result=(u64)-4;
        else if(state==CPU_POWER_ON_PENDING)r->result=(u64)-5;
        else {h->boot_entry=b;h->boot_context=context;h->reset_pending=true;h->halted=false;h->failed=false;
            atomic_store_explicit(&h->power,CPU_POWER_ON_PENDING,memory_order_release);r->result=0;}
        pthread_mutex_unlock(&p->mutex);
        if(!r->result)gic_cpu_reset(m->gic,(unsigned)a);
        break;
    }
    case 0x84000002:
        atomic_store_explicit(&p->hart[source].power,CPU_POWER_OFF,memory_order_release);
        p->hart[source].timer=(MachineTimerView){.power=CPU_POWER_OFF};
        gic_cpu_reset(m->gic,source);r->action=1;break;
    case 0x84000001:case 0xc4000001:
        r->result=a?(u64)-2:0;if(!a)r->action=2;break;
    case 0x84000008:atomic_store(&m->system_off,true);break;
    case 0x84000009:atomic_store(&m->system_reset,true);break;
    default:break;
    }
}
static void service(AEParallel *p,unsigned i,AERPC *r){
    Machine *m=&p->session->machine;
    if(r->type==RPC_BUS)r->bus=machine_bus_service(m,i,r->address,r->size,r->write,r->value,r->pc,r->icount);
    else if(r->type==RPC_TIMER){
        p->hart[i].timer=r->timer;
        CPU view={.m=m,.hart_id=i,.power=r->timer.power,.cntp_ctl=r->timer.cntp_ctl,.cntp_cval=r->timer.cntp_cval,
                  .cntv_ctl=r->timer.cntv_ctl,.cntv_cval=r->timer.cntv_cval,.cntvoff=r->timer.cntvoff};
        timer_update_cpu(&view);gic_update(m->gic);
    } else if(r->type==RPC_PSCI)psci_service(p,i,r);
}
static void *hart_main(void *argument){
    AEHart *h=argument;AEParallel *p=h->parallel;AESession *s=p->session;CPU *c=machine_cpu(&s->machine,h->index);
    worker=h;ae_current=s;if(pthread_threadid_np(NULL,&h->native_id))s->machine.host_error=FLOE_AE_FAULT;
    if(fesetenv(FE_DFL_ENV)){s->machine.host_error=FLOE_AE_FAULT;}
    pthread_mutex_lock(&p->mutex);
    for(;;){
        while(!p->shutdown&&!h->ticket)pthread_cond_wait(&h->condition,&p->mutex);
        if(p->shutdown)break;
        u64 ticket=h->ticket;h->ticket=0;bool reset=h->reset_pending;h->reset_pending=false;
        u64 entry=h->boot_entry,context=h->boot_context;AEParallelCallbacks fn=p->callbacks;
        pthread_mutex_unlock(&p->mutex);
        u64 cpu_start=thread_cpu_ns();
        if(reset){
            if(fesetenv(FE_DFL_ENV))s->machine.host_error=FLOE_AE_FAULT;
            ae_fp_reset_pending(c);cpu_reset(c,entry,1);c->x[0]=context;
            atomic_store_explicit(&h->power,CPU_POWER_ON,memory_order_release);
        }
        if(h->fp_generation!=c->exec.reset_generation){
            /* CPU reset already cleared software FPSR pending. Clear only this
             * worker's old host environment; preserve a legitimate software
             * pending flag injected/executed while all workers were quiet. */
            if(fesetenv(FE_DFL_ENV))s->machine.host_error=FLOE_AE_FAULT;
            ae_fp_unbind();h->fp_generation=c->exec.reset_generation;
        }
        apply_epoch(h);c->owner_yield=false;h->quantum_start=c->icount;
        u64 before=c->icount;enter_pd(h);if(reset)(void)timer_publish(c);ae_parallel_test_boundary(c,0);
        if(!parallel_poll(c)&&mmu_bind_cpu(c))fn.step(c,ticket,0);
        ae_parallel_test_boundary(c,1);leave_pd(h);
        u64 retired=c->icount-before;
        /* Fold on a worker quiet boundary, never in the coordinator's fenv.
         * The host environment itself stays attached to this native worker. */
        fn.fp_sync(c);h->quiet_fp=true;
        u64 cpu_end=thread_cpu_ns();
        pthread_mutex_lock(&p->mutex);
        if(retired>ticket){s->machine.host_error=FLOE_AE_FAULT;p->remaining=0;}
        else p->remaining+=ticket-retired;
        p->executed+=retired;
        atomic_fetch_add_explicit(&s->machine.virtual_ticks,retired,memory_order_relaxed);
        h->total_retired+=retired;h->cpu_ns+=cpu_end>=cpu_start?cpu_end-cpu_start:0;
        h->halted=h->reset_pending?false:c->halted;h->sleep=c->sleep;h->failed=c->stop;h->fiq=c->fiq_line;
        /* CPU_ON may be accepted after OFF's mailbox reply but before the old
         * instruction returns. Preserve the new pending boot across that end. */
        if(!h->reset_pending)atomic_store_explicit(&h->power,c->power,memory_order_release);
        h->busy=false;h->await_yield=false;atomic_store_explicit(&h->ack_epoch,atomic_load(&p->tlbi_epoch),memory_order_release);
        changed(p);pthread_mutex_unlock(&p->mutex);ae_parallel_test_boundary(c,5);pthread_mutex_lock(&p->mutex);
    }
    pthread_mutex_unlock(&p->mutex);ae_parallel_test_boundary(c,6);cpu_debug_release();ae_fp_unbind();ae_current=NULL;worker=NULL;return NULL;
}
static int ensure_worker(AEParallel *p,unsigned i){
    AEHart *h=&p->hart[i];if(h->started)return 0;
    pthread_attr_t attr;if(pthread_attr_init(&attr))return FLOE_AE_FAULT;
    int error=pthread_attr_setstacksize(&attr,512*1024);
    if(!error)error=pthread_create(&h->thread,&attr,hart_main,h);
    pthread_attr_destroy(&attr);if(error)return FLOE_AE_FAULT;h->started=true;return 0;
}
int ae_parallel_init(AESession *s){
    AEParallel *p=calloc(1,sizeof(*p));if(!p)return FLOE_AE_NOMEM;
    s->parallel=p;p->session=s;p->hart=calloc(s->machine.ncpus,sizeof(*p->hart));
    if(!p->hart)return FLOE_AE_NOMEM;
    atomic_init(&p->abort_run,false);atomic_init(&p->tlbi_epoch,1);atomic_init(&p->in_pd,0);atomic_init(&p->max_in_pd,0);
    if(pthread_mutex_init(&p->mutex,NULL))return FLOE_AE_FAULT;p->mutex_ready=true;
    if(pthread_cond_init(&p->changed,NULL))return FLOE_AE_FAULT;p->condition_ready=true;
    for(unsigned i=0;i<s->machine.ncpus;i++){
        AEHart *h=&p->hart[i];h->parallel=p;h->index=i;h->applied_epoch=1;atomic_init(&h->power,CPU_POWER_OFF);
        atomic_init(&h->irq,false);atomic_init(&h->event,false);atomic_init(&h->ack_epoch,1);
        atomic_init(&h->poll_pending,1);
        h->poll_view=(MachineParallelPollView){.cpu=machine_cpu(&s->machine,i),.machine=&s->machine,
            .pending=&h->poll_pending,.abort_run=&p->abort_run,.stop=&s->stop,
            .memory_error=memory_sync_error_address(&s->machine)};
        if(pthread_cond_init(&h->condition,NULL))return FLOE_AE_FAULT;h->condition_ready=true;
    }
    return 0;
}
void ae_parallel_notify(AESession *s){
    AEParallel *p=s->parallel;if(!p||!p->mutex_ready)return;
    /* Callers may hold the session mutex. No inverse parallel->session edge. */
    pthread_mutex_lock(&p->mutex);changed(p);pthread_mutex_unlock(&p->mutex);
}
void ae_parallel_destroy(AESession *s){
    AEParallel *p=s->parallel;if(!p)return;
    if(p->mutex_ready){
        pthread_mutex_lock(&p->mutex);p->shutdown=true;atomic_store(&p->abort_run,true);
        if(p->hart)for(unsigned i=0;i<s->machine.ncpus;i++)if(p->hart[i].condition_ready)pthread_cond_signal(&p->hart[i].condition);
        pthread_mutex_unlock(&p->mutex);
    }
    if(p->hart)for(unsigned i=0;i<s->machine.ncpus;i++)if(p->hart[i].started)pthread_join(p->hart[i].thread,NULL);
    if(p->hart)for(unsigned i=0;i<s->machine.ncpus;i++)if(p->hart[i].condition_ready)pthread_cond_destroy(&p->hart[i].condition);
    if(p->condition_ready)pthread_cond_destroy(&p->changed);
    if(p->mutex_ready)pthread_mutex_destroy(&p->mutex);
    free(p->hart);free(p);s->parallel=NULL;
}
static void seed(AEParallel *p){
    Machine *m=&p->session->machine;
    for(unsigned i=0;i<m->ncpus;i++){
        AEHart *h=&p->hart[i];CPU *c=machine_cpu(m,i);
        h->halted=c->halted;h->sleep=c->sleep;h->failed=c->stop;h->fiq=c->fiq_line;
        h->reset_pending=c->power==CPU_POWER_ON_PENDING;h->boot_entry=c->boot_entry;h->boot_context=c->boot_context;
        atomic_store(&h->power,c->power);atomic_store(&h->irq,c->irq_line);atomic_store(&h->event,c->event);
        atomic_store_explicit(&h->poll_pending,1,memory_order_release);
        h->timer=(MachineTimerView){c->power,c->cntp_ctl,c->cntp_cval,c->cntv_ctl,c->cntv_cval,c->cntvoff};
        h->request.state=MAIL_EMPTY;h->await_yield=false;
    }
}
static bool busy(AEParallel *p){for(unsigned i=0;i<p->session->machine.ncpus;i++)if(p->hart[i].busy)return true;return false;}
static bool runnable(AEHart *h){
    CPUPower power=(CPUPower)atomic_load(&h->power);
    if(power==CPU_POWER_ON_PENDING)return true;
    if(power!=CPU_POWER_ON||h->failed)return false;
    return !h->halted||h->fiq||atomic_load(&h->irq)||(h->sleep==CPU_SLEEP_WFE&&atomic_load(&h->event));
}
static int grant(AEParallel *p){
    Machine *m=&p->session->machine;unsigned ready=0;bool pressure=p->remaining<=128;
    for(unsigned i=0;i<m->ncpus;i++)if(!p->hart[i].busy&&runnable(&p->hart[i]))ready++;
    for(unsigned n=0;n<m->ncpus&&p->remaining;n++){
        unsigned i=(p->next_hart+n)%m->ncpus;AEHart *h=&p->hart[i];
        if(h->busy||!runnable(h))continue;
        int error=ensure_worker(p,i);if(error)return error;
        /* A small total budget must reach every ready hart, rather than
         * disappear into the first capped ticket. Keep <=128 RR pressure.
         * Amortize coordinator/worker handoffs for compute-heavy runs with a
         * bounded 16K ticket on every topology. Stop/IRQ/TLBI remain checked
         * at instruction boundaries; device RPCs still yield immediately. */
        u64 ticket=p->remaining;
        if(!pressure&&ready>1)ticket=(ticket+ready-1)/ready;
        if(ticket>16384)ticket=16384;
        ready--;p->remaining-=ticket;
        h->ticket=ticket;h->busy=true;h->quiet_fp=false;pthread_cond_signal(&h->condition);
        m->next_hart=(i+1)%m->ncpus;
    }
    p->next_hart=m->next_hart;return 0;
}
static int pending(AEParallel *p){
    for(unsigned i=0;i<p->session->machine.ncpus;i++)if(p->hart[i].request.state==MAIL_PENDING)return (int)i;
    return -1;
}
static void close_run(AEParallel *p){
    p->closing=true;atomic_store_explicit(&p->abort_run,true,memory_order_release);
    /* Only busy workers need a stop wake. OFF/quiescent threads remain asleep. */
    for(unsigned i=0;i<p->session->machine.ncpus;i++)if(p->hart[i].busy)pthread_cond_signal(&p->hart[i].condition);
    pthread_cond_broadcast(&p->changed);
}
/* Parallel mutex held. Use the same exit priorities both before and after
 * unlocked board work: workers/control can complete while the owner is away. */
static void close_if_requested(AEParallel *p,AEParallelResult *result,u64 max_insn){
    AESession *s=p->session;Machine *m=&s->machine;
    if(!p->closing){
        if(atomic_load(&s->stop)){result->reason=FLOE_AE_CANCELLED;close_run(p);}
        else if(m->host_error||memory_sync_error(m)){result->error=m->host_error?m->host_error:memory_sync_error(m);close_run(p);}
        else if(m->system_off){result->reason=FLOE_AE_GUEST_OFF;close_run(p);}
        else if(m->system_reset){close_run(p);}
        else if(p->executed>=max_insn||ae_now_ns()>=p->deadline)close_run(p);
        for(unsigned i=0;i<m->ncpus;i++)if(p->hart[i].failed){result->error=FLOE_AE_FAULT;close_run(p);break;}
    }
}
static AEParallelResult parallel_epoch(AESession *s,u64 max_ns,u64 max_insn,const AEParallelCallbacks *fn){
    AEParallel *p=s->parallel;Machine *m=&s->machine;AEParallelResult result={.reason=FLOE_AE_BUDGET};
    u64 began=ae_now_ns();pthread_mutex_lock(&p->mutex);
    seed(p);p->callbacks=*fn;p->remaining=max_insn;p->executed=0;p->next_hart=m->next_hart;
    p->active=true;p->closing=false;p->deadline=began+max_ns;atomic_store(&p->abort_run,false);
    /* All workers are idle under this mutex: install immutable routing before
     * any grant, and remove it only after every granted call has returned. */
    m->parallel_owner=p;m->parallel_ops=&operations;
    for(;;){
        int index=pending(p);
        if(index>=0){
            AEHart *h=&p->hart[index];AERPC r=h->request;h->request.state=MAIL_SERVICING;
            pthread_mutex_unlock(&p->mutex);service(p,(unsigned)index,&r);pthread_mutex_lock(&p->mutex);
            r.state=MAIL_DONE;h->request=r;if(r.type==RPC_BUS&&r.bus.yield)h->await_yield=true;pthread_cond_signal(&h->condition);continue;
        }
        close_if_requested(p,&result,max_insn);
        if(p->closing){
            if(!busy(p))break;
            pthread_cond_wait(&p->changed,&p->mutex);continue;
        }
        bool defer_dma=false;for(unsigned i=0;i<m->ncpus;i++)defer_dma|=p->hart[i].busy&&p->hart[i].await_yield;
        pthread_mutex_unlock(&p->mutex);
        /* Sequence denotes the actual conditions observation, never a later
         * unserviced input/drain event. It is preserved on PARKED/FULL. */
        pthread_mutex_lock(&s->mutex);result.observed_sequence=s->sequence;
        size_t room=s->channels[0].output.cap-s->channels[0].output.count;pthread_mutex_unlock(&s->mutex);
        m->io_poll_due=0;fn->tick(m);
        bool io_work=false;
        if(!defer_dma&&!atomic_load_explicit(&s->stop,memory_order_acquire)&&!m->host_error&&!m->system_off&&!m->system_reset){
        if(fwcfg_has_work(m->fwcfg)){fn->fw_service(m->fwcfg,4096);io_work=true;}
        else for(int i=0;i<m->n_blk;i++)if(virtio_blk_has_work(m->blk[i])){fn->blk_service(m->blk[i]);io_work=true;break;}
        }
        pthread_mutex_lock(&p->mutex);
        /* A completed budget/deadline or a new control/fault is not PARKED.
         * Recheck before granting new work or interpreting an empty busy set. */
        close_if_requested(p,&result,max_insn);
        if(p->closing)continue;
        if(room<1024){result.reason=FLOE_AE_OUTPUT_FULL;close_run(p);continue;}
        if(io_work)continue;
        int error=grant(p);if(error){result.error=error;close_run(p);continue;}
        if(!busy(p)){
            /* All private state is now quiet. No periodic per-hart timeout:
             * external wait uses earliest actual timer/RTC/control/IO event. */
            if(!g_rtclock){pthread_mutex_unlock(&p->mutex);u64 ticks=timer_next_deadline_ticks(m);pthread_mutex_lock(&p->mutex);
                if(ticks&&ticks!=UINT64_MAX){atomic_fetch_add(&m->virtual_ticks,ticks);continue;}}
            result.reason=FLOE_AE_PARKED;close_run(p);continue;
        }
        u64 observed_progress=p->progress,deadline_snapshot=p->deadline;
        pthread_mutex_unlock(&p->mutex);u64 timer=timer_next_event_ns(m),now=ae_now_ns();
        ae_parallel_test_boundary(NULL,4);
        /* Hart-busy readiness wait: at least one hart executes, so sleep
         * until it makes progress, the budget/timer fires, a control signal
         * arrives on the session wake pipe (input/stop/winsize/ABI), or a
         * usernet descriptor becomes ready (socket readiness wakes the loop
         * immediately, so a guest blocked on RX/TX resumes within this slice
         * instead of after the remaining budget). Lock order respected: the
         * usernet snapshot is taken with the parallel mutex released, and
         * every mutation path (hostfwd add/remove, share attach/detach,
         * destroy) requires this same quiescence, so the snapshotted fds
         * cannot be closed or reused underneath poll(2). */
        AESession *ps=p->session;
        struct pollfd pf[132];
        int nfds=0,held[128],nheld=0,pipe_idx=-1;
        if(ps->wake_pipe_ready){pipe_idx=nfds;pf[nfds].fd=ps->wake_pipe[0];pf[nfds].events=POLLIN|POLLERR|POLLHUP;nfds++;}
        UserNet *un=m->net?virtio_net_usernet(m->net):NULL;
        int raw[128];int nraw=un?usernet_wait_fds(un,raw,128):0;
        for(int i=0;i<nraw;i++){int d=dup(raw[i]);if(d>=0){pf[nfds].fd=d;pf[nfds].events=POLLIN|POLLERR|POLLHUP;held[nheld++]=d;nfds++;}}
        u64 wait_ns=deadline_snapshot>now?deadline_snapshot-now:0;if(timer<wait_ns)wait_ns=timer;
        int ready=0;
        if(wait_ns)ready=poll(pf,(nfds_t)nfds,(int)((wait_ns+999999)/1000000));
        pthread_mutex_lock(&p->mutex);
        for(int i=0;i<nheld;i++)close(held[i]);
        if(ready>0&&pipe_idx>=0&&(pf[pipe_idx].revents&(POLLIN|POLLERR|POLLHUP)))ae_wake_drain(ps);
        /* A worker/RPC/control change between observation and wait cannot be
         * consumed by the old condition signal. Re-enter the full predicates. */
        if(p->progress!=observed_progress||pending(p)>=0)continue;
    }
    result.instructions=p->executed;p->active=false;
    m->parallel_ops=NULL;m->parallel_owner=NULL;
    /* Last publication + mutex acquisition gives a quiet architectural view.
     * Monitor mirrors are refreshed only here, with every worker stopped. */
    pthread_mutex_unlock(&p->mutex);
    for(unsigned i=0;i<m->ncpus;i++){
        AEHart *h=&p->hart[i];CPU *c=machine_cpu(m,i);
        memory_monitor_sync_cpu(c);
        /* Transfer unconsumed publications back to the quiet architectural
         * view; the next public seed must not overwrite a late IRQ/SEV/ON. */
        c->irq_line=atomic_load(&h->irq);c->event|=atomic_exchange(&h->event,false);
        if(h->reset_pending){c->power=CPU_POWER_ON_PENDING;c->boot_entry=h->boot_entry;c->boot_context=h->boot_context;}
        if(c->power==CPU_POWER_ON&&c->halted&&(c->irq_line||c->fiq_line||(c->sleep==CPU_SLEEP_WFE&&c->event))){
            if(c->sleep==CPU_SLEEP_WFE)c->event=false;cpu_wake(c);
        }
    }
    if(m->host_error||memory_sync_error(m))result.error=m->host_error?m->host_error:memory_sync_error(m);
    for(unsigned i=0;i<m->ncpus;i++)if(machine_cpu(m,i)->stop)result.error=FLOE_AE_FAULT;
    if(atomic_load(&s->stop))result.reason=FLOE_AE_CANCELLED;
    else if(m->system_off)result.reason=FLOE_AE_GUEST_OFF;
    if(m->system_reset&&!m->system_off&&!result.error&&!atomic_load(&s->stop)){
        /* Public caller owns reset only after all workers acknowledge quiescence.
         * The next run seeds fresh boot state without replaying CPU_ON entropy. */
        ae_fp_unbind();machine_reset(m,FLASH_BASE,1);result.resets++;
        if(m->host_error)result.error=m->host_error;
    }
    return result;
}
AEParallelResult ae_parallel_run(AESession *s,u64 max_ns,u64 max_insn,const AEParallelCallbacks *fn){
    u64 began=ae_now_ns();AEParallelResult total={.reason=FLOE_AE_BUDGET};
    do {
        u64 elapsed=ae_now_ns()-began;if(elapsed>=max_ns)break;
        AEParallelResult result=parallel_epoch(s,max_ns-elapsed,max_insn-total.instructions,fn);
        total.instructions+=result.instructions;total.resets+=result.resets;
        total.observed_sequence=result.observed_sequence;total.reason=result.reason;total.error=result.error;
        /* Preserve ABI reset-in-slice behavior: reset is a quiet ownership
         * transition, then the remaining aggregate budget can execute boot0. */
        if(!result.resets||result.error||result.reason==FLOE_AE_CANCELLED||result.reason==FLOE_AE_GUEST_OFF)break;
    } while(total.instructions<max_insn);
    return total;
}
void ae_parallel_snapshot(AESession *s,AEParallelSnapshot *out){
    AEParallel *p=s->parallel;memset(out,0,sizeof(*out));pthread_mutex_lock(&p->mutex);
    out->max_in_pd=atomic_load(&p->max_in_pd);
    for(unsigned i=0;i<s->machine.ncpus;i++){
        AEHart *h=&p->hart[i];out->started_workers+=h->started;out->native_id[i]=h->native_id;
        out->retired[i]=h->total_retired;out->cpu_ns[i]=h->cpu_ns;
    }
    pthread_mutex_unlock(&p->mutex);
}

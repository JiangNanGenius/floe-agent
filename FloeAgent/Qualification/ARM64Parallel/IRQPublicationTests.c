/* SPDX-License-Identifier: MPL-2.0 */
/* Exercise the actual session, IRQ publication and event paths. Ordinary
 * archive lookup omits the two runtime objects included below. */
#include "../../ThirdParty/ARM64EMU/Bridge/runtime.c"
#include "../../ThirdParty/ARM64EMU/Bridge/parallel_runtime.c"
#include <assert.h>

#ifdef NDEBUG
#error "IRQ publication qualification requires assertions"
#endif

static bool pipe_ready(AESession *s) {
    struct pollfd fd={.fd=s->wake_pipe[0],.events=POLLIN};
    int n=poll(&fd,1,0);assert(n>=0);return n!=0;
}
static void consume(AESession *s,AEHart *h) {
    ae_wake_drain(s);atomic_store(&h->poll_pending,0);
}
int main(int argc,char **argv) {
    assert(argc==2);
    char firmware[PATH_MAX];
    assert(snprintf(firmware,sizeof(firmware),"%s/irq-fw.bin",argv[1])<(int)sizeof(firmware));
    int fd=open(firmware,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);
    u32 branch=0x14000000;assert(write(fd,&branch,4)==4&&!close(fd));
    floe_ae_config cfg={.abi_version=1,.struct_size=sizeof(cfg),.ram_mib=16,
        .requested_vcpus=4,.firmware_path=firmware,.input_capacity=256,.output_capacity=4096};
    floe_ae_handle handle=0;assert(!floe_ae_create(&cfg,&handle)&&live);
    AESession *s=live;Machine *m=&s->machine;AEParallel *p=s->parallel;
    assert(p&&s->wake_pipe_ready);m->parallel_owner=p;m->parallel_ops=&operations;
    AEHart *h=&p->hart[0];consume(s,h);

    /* An already-low line has no new state to publish. It must not make the
     * coordinator's readiness pipe readable or demand another full poll. */
    u64 progress=p->progress;
    for(unsigned i=0;i<10000;i++)publish_irq(m,0,false);
    assert(p->progress==progress&&!atomic_load(&h->poll_pending)&&!pipe_ready(s));

    publish_irq(m,0,true);
    assert(atomic_load(&h->irq)&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    assert(p->progress==progress+1);consume(s,h);
    /* Repeated asserted levels still wake a sleeping worker. */
    h->halted=true;publish_irq(m,0,true);
    assert(!h->halted&&atomic_load(&h->irq)&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    assert(p->progress==progress+2);consume(s,h);

    publish_irq(m,0,false);
    assert(!atomic_load(&h->irq)&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    assert(p->progress==progress+3);
    /* Coalescing must retain an unconsumed falling edge. */
    publish_irq(m,0,false);
    assert(p->progress==progress+3&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    consume(s,h);

    atomic_store(&h->power,CPU_POWER_ON);h->sleep=CPU_SLEEP_WFE;h->halted=true;
    wake_harts(m,1);
    assert(!h->halted&&atomic_load(&h->event)&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    publish_irq(m,0,false);
    assert(atomic_load(&h->event)&&atomic_load(&h->poll_pending)&&pipe_ready(s));
    consume(s,h);
    /* A low IRQ cannot clear a pending TLB/control publication either. */
    atomic_store(&h->poll_pending,1);publish_irq(m,0,false);
    assert(atomic_load(&h->poll_pending));
    consume(s,h);

    for(unsigned i=0;i<4;i++){
        AEHart *other=&p->hart[i];atomic_store(&other->irq,false);
        atomic_store(&other->poll_pending,0);
    }
    progress=p->progress;gic_update(m->gic);
    assert(p->progress==progress&&!pipe_ready(s));
    for(unsigned i=0;i<4;i++)assert(!atomic_load(&p->hart[i].poll_pending));
    m->parallel_ops=NULL;m->parallel_owner=NULL;
    assert(!floe_ae_destroy(handle)&&!unlink(firmware));
    puts("ARM64_IRQ_PUBLICATION_OK duplicate_low=10000 rising=1 repeated_high=1 falling=1 pending_preserved=1 event_preserved=1 gic_four_harts=1");
    return 0;
}

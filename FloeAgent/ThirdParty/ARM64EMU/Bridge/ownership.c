/* SPDX-License-Identifier: MPL-2.0 */
/* Machine ownership for the embedded profile.
 *
 * Every device with host-owned state (descriptors, flows, listeners,
 * directories) has a real create/reset/destroy lifecycle here; teardown runs
 * only after the parallel runtime has joined every worker. The disabled
 * backends of the A6 checkpoint are gone: net and 9P are the restored
 * upstream devices, not absent stubs. */
#include "embedded_internal.h"
#include <stdlib.h>
void ae_machine_destroy(Machine *m) {
    for(int i=0;i<m->n_vcon;i++) { virtio_console_destroy(m->vcon[i]);m->vcon[i]=NULL; } m->n_vcon=0;
    for(int i=0;i<m->n_fs;i++)  { virtio_9p_destroy(m->fs[i]);m->fs[i]=NULL; } m->n_fs=0;
    if(m->net) { virtio_net_destroy(m->net);m->net=NULL; }
    for(int i=0;i<m->n_blk;i++) { virtio_blk_destroy(m->blk[i]);m->blk[i]=NULL; } m->n_blk=0;
    fwcfg_destroy(m->fwcfg);m->fwcfg=NULL;
    pl011_destroy(m->uart);m->uart=NULL;
    pl031_destroy(m->rtc);m->rtc=NULL;
    gtimer_destroy(m->timer);m->timer=NULL;
    gic_destroy(m->gic);m->gic=NULL;
    machine_free(m);
}
void ae_reset_caches(Machine *m) {
    for(unsigned h=0;h<m->ncpus;h++)cpu_exec_reset(machine_cpu(m,h));
    ae_fp_unbind();
}

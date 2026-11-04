/* SPDX-License-Identifier: MPL-2.0 */
#include "embedded_internal.h"
#include <stdlib.h>
void ae_machine_destroy(Machine *m) {
    for(int i=0;i<m->n_vcon;i++) { virtio_console_destroy(m->vcon[i]);m->vcon[i]=NULL; } m->n_vcon=0;
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
/* Disabled devices are explicit absent backends, never advertised as usable. */
struct VirtIONet *virtio_net_create(Machine *m,GIC *g) { (void)m;(void)g;return NULL; }
void virtio_net_poll(struct VirtIONet *v) { (void)v; }
void virtio_net_reset(struct VirtIONet *v) { (void)v; }
struct VirtIO9P *virtio_9p_create(Machine *m,GIC *g,const char *p,const char *t,bool ro,int slot) {
    (void)m;(void)g;(void)p;(void)t;(void)ro;(void)slot;return NULL;
}

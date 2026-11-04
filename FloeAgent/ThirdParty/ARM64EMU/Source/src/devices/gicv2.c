/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre. Cooperative SMP extensions, 2026 Floe contributors. */
/* GICv2 without Security Extensions: one banked CPU interface/private interrupt
 * set per possible PE; shared SPIs have exactly one active owner. */
#include "../devices.h"
#include <stdlib.h>
#include <string.h>
#define SPURIOUS 1023u
#define EOIMODE (1u<<9) /* no-Security-Extensions view of GICC_CTLR */

static CPU *access_cpu(GIC *g) {
    CPU *c=machine_bus_cpu(g->m);
    if(!c||c->m!=g->m||c->hart_id>=g->m->ncpus){machine_bus_set_status(g->m,BUS_FAULT);return NULL;}
    return c;
}
static unsigned priority(GIC *g,unsigned h,unsigned id) {
    return id<32?g->bank[h].priority[id]:g->priority[id];
}
static unsigned running(GIC *g,unsigned h) {
    unsigned p=256;
    for(unsigned id=0;id<GIC_NUM_IRQS;id++) {
        bool active=id<32?g->bank[h].active[id]&&!g->bank[h].dropped[id]
                         :g->active[id]&&g->active_owner[id]==(int)h&&!g->dropped[id];
        if(active&&priority(g,h,id)<p)p=priority(g,h,id);
    }
    return p;
}
static bool eligible(GIC *g,unsigned h,unsigned id) {
    struct GICBank *b=&g->bank[h];
    if(!(g->d_ctlr&1)||!(b->ctlr&1)||machine_hart_power(g->m,h)!=CPU_POWER_ON)return false;
    unsigned p=priority(g,h,id),r=running(g,h),shift=(unsigned)b->bpr+1;
    return p<b->pmr&&(r==256||(p>>shift)<(r>>shift));
}
static int spi_destination(GIC *g,unsigned id) {
    for(unsigned n=1;n<=g->m->ncpus;n++) {
        unsigned h=(unsigned)((int)g->route_after[id]+(int)n)%g->m->ncpus;
        if((g->target[id]&(1u<<h))&&eligible(g,h,id))return (int)h;
    }
    return -1;
}
static unsigned best(GIC *g,unsigned h) {
    unsigned winner=SPURIOUS,p=256;
    for(unsigned id=0;id<GIC_NUM_IRQS;id++) {
        bool ready=id<32?g->bank[h].enabled[id]&&g->bank[h].pending[id]&&!g->bank[h].active[id]
                        :g->enabled[id]&&g->pending[id]&&!g->active[id]&&spi_destination(g,id)==(int)h;
        if(!ready||!eligible(g,h,id))continue;
        unsigned q=priority(g,h,id);if(q<p){p=q;winner=id;}
    }
    return winner;
}
void gic_update(GIC *g) {
    if(!g)return;
    for(unsigned h=0;h<g->m->ncpus;h++)machine_set_irq(g->m,h,best(g,h)!=SPURIOUS);
}
void gic_set_irq(GIC *g,int id,int level) {
    /* Private interrupts require the explicit gic_set_ppi API. */
    if(!g||id<32||id>=GIC_NUM_IRQS)return;
    bool lv=level!=0,old=g->pending[id];
    if(g->cfg_edge[id])g->pending[id]|=lv&&!g->line[id];
    else g->pending[id]=lv||g->software[id];
    g->line[id]=lv;if(old!=g->pending[id])gic_update(g);
}
void gic_set_ppi(GIC *g,unsigned h,int id,int level) {
    if(!g||h>=g->m->ncpus||id<16||id>=32)return;
    struct GICBank *b=&g->bank[h];bool lv=level!=0,old=b->pending[id];
    if(b->edge[id])b->pending[id]|=lv&&!b->line[id];
    else b->pending[id]=lv||b->software[id];
    b->line[id]=lv;if(old!=b->pending[id])gic_update(g);
}
static unsigned sgi_value(GIC *g,unsigned h,unsigned id) {
    if(id>=16)return id;
    unsigned sources=g->bank[h].sgi_pending[id];
    for(unsigned source=0;source<g->m->ncpus;source++)if(sources&(1u<<source))return id|(source<<10);
    return SPURIOUS;
}
static unsigned acknowledge(GIC *g,unsigned h) {
    unsigned id=best(g,h);if(id==SPURIOUS)return id;
    unsigned value=sgi_value(g,h,id);struct GICBank *b=&g->bank[h];
    if(id<32) {
        b->active[id]=true;b->dropped[id]=false;b->software[id]=false;
        if(id<16){b->sgi_source[id]=(u8)(value>>10);b->sgi_pending[id]&=(u8)~(1u<<(value>>10));b->pending[id]=b->sgi_pending[id]!=0;b->sgi_acknowledged++;}
        else b->pending[id]=!b->edge[id]&&b->line[id];
    } else {
        g->active[id]=true;g->dropped[id]=false;g->active_owner[id]=(s8)h;g->route_after[id]=(s8)h;
        g->software[id]=false;g->pending[id]=!g->cfg_edge[id]&&g->line[id];
    }
    b->acknowledged++;gic_update(g);return value;
}
static void deactivate(GIC *g,unsigned h,unsigned value,bool priority_only) {
    unsigned id=value&0x3ff;if(id>=GIC_NUM_IRQS)return;
    struct GICBank *b=&g->bank[h];
    if(id<32) {
        if(!b->active[id]||(id<16&&((value>>10)&7)!=b->sgi_source[id]))return;
        b->dropped[id]=true;if(!priority_only)b->active[id]=false;
    } else {
        if(!g->active[id]||g->active_owner[id]!=(int)h)return;
        g->dropped[id]=true;
        if(!priority_only){g->active[id]=false;g->active_owner[id]=-1;}
    }
    gic_update(g);
}
static bool word_access(GIC *g,u64 off,unsigned size) {
    if(size==4&&!(off&3))return true;
    machine_bus_set_status(g->m,BUS_FAULT);return false;
}
static bool reg_bit(GIC *g,unsigned h,unsigned id,unsigned kind) {
    if(id>=GIC_NUM_IRQS)return false;
    struct GICBank *b=&g->bank[h];
    if(kind==0)return id<32?b->enabled[id]:g->enabled[id];
    if(kind==1)return id<32?b->pending[id]:g->pending[id];
    return id<32?b->active[id]:g->active[id];
}
static void set_reg_bit(GIC *g,unsigned h,unsigned id,unsigned kind,bool set) {
    if(id>=GIC_NUM_IRQS)return;
    struct GICBank *b=&g->bank[h];
    if(kind==0){if(id<16)return;if(id<32)b->enabled[id]=set;else g->enabled[id]=set;}
    else if(kind==1) {
        if(id<16){if(set)b->sgi_pending[id]|=(u8)(1u<<h);else b->sgi_pending[id]=0;b->pending[id]=b->sgi_pending[id]!=0;}
        else if(id<32){b->software[id]=set;b->pending[id]=set||(!b->edge[id]&&b->line[id]);}
        else {g->software[id]=set;g->pending[id]=set||(!g->cfg_edge[id]&&g->line[id]);}
    } else if(id<32){b->active[id]=set;b->dropped[id]=false;if(id<16)b->sgi_source[id]=(u8)h;}
    else if(!set||!g->active[id]){g->active[id]=set;g->active_owner[id]=set?(s8)h:-1;g->dropped[id]=false;}
}
static u64 gicd_read(void *opaque,u64 off,unsigned size) {
    GIC *g=opaque;CPU *c=access_cpu(g);if(!c)return 0;unsigned h=c->hart_id;
    if((off>=0x400&&off<0xc00)||(off>=0xf10&&off<0xf30)) {
        u64 v=0;
        for(unsigned i=0;i<size;i++) {
            unsigned pos=(unsigned)off+i,byte=0;
            if(pos>=0x400&&pos<0x800){unsigned id=pos-0x400;if(id<GIC_NUM_IRQS)byte=priority(g,h,id);}
            else if(pos>=0x800&&pos<0xc00){unsigned id=pos-0x800;if(id<GIC_NUM_IRQS)byte=id<32?1u<<h:g->target[id];}
            else if(pos>=0xf10&&pos<0xf20)byte=g->bank[h].sgi_pending[pos-0xf10];
            else if(pos>=0xf20&&pos<0xf30)byte=g->bank[h].sgi_pending[pos-0xf20];
            v|=(u64)byte<<(8*i);
        }return v;
    }
    if(!word_access(g,off,size))return 0;
    if(off==0)return g->d_ctlr;
    if(off==4)return (GIC_NUM_IRQS/32-1)|((g->m->ncpus-1)<<5);
    if(off==8)return 0x0200043b;
    if(off>=0x100&&off<0x400){unsigned kind=(unsigned)((off-0x100)/0x100),base=(unsigned)((off&0x7f)*8);u32 v=0;
        for(unsigned i=0;i<32;i++)if(reg_bit(g,h,base+i,kind))v|=1u<<i;return v;}
    if(off>=0xc00&&off<0xd00){unsigned base=(unsigned)((off-0xc00)*4);u32 v=0;
        for(unsigned i=0;i<16&&base+i<GIC_NUM_IRQS;i++){unsigned id=base+i;bool edge=id<16||(id<32?g->bank[h].edge[id]:g->cfg_edge[id]);if(edge)v|=2u<<(i*2);}return v;}
    return 0;
}
static void gicd_write(void *opaque,u64 off,unsigned size,u64 value) {
    GIC *g=opaque;CPU *c=access_cpu(g);if(!c)return;unsigned h=c->hart_id,mask=(1u<<g->m->ncpus)-1;
    if((off>=0x400&&off<0xc00)||(off>=0xf10&&off<0xf30)) {
        for(unsigned i=0;i<size;i++) {
            unsigned pos=(unsigned)off+i;u8 byte=(u8)(value>>(8*i));
            if(pos>=0x400&&pos<0x800){unsigned id=pos-0x400;if(id<32)g->bank[h].priority[id]=byte;else if(id<GIC_NUM_IRQS)g->priority[id]=byte;}
            else if(pos>=0x800&&pos<0xc00){unsigned id=pos-0x800;if(id>=32&&id<GIC_NUM_IRQS)g->target[id]=byte&(u8)mask;}
            else if(pos>=0xf10&&pos<0xf30){unsigned id=pos&15;if(pos<0xf20)g->bank[h].sgi_pending[id]&=(u8)~byte;else g->bank[h].sgi_pending[id]|=byte&(u8)mask;g->bank[h].pending[id]=g->bank[h].sgi_pending[id]!=0;}
        }gic_update(g);return;
    }
    if(!word_access(g,off,size))return;
    if(off==0){g->d_ctlr=(u32)value&1;gic_update(g);return;}
    if(off>=0x100&&off<0x400){unsigned kind=(unsigned)((off-0x100)/0x100),base=(unsigned)((off&0x7f)*8);bool set=(off&0x80)==0;
        for(unsigned i=0;i<32;i++)if(value&(1u<<i))set_reg_bit(g,h,base+i,kind,set);gic_update(g);return;}
    if(off>=0xc00&&off<0xd00){unsigned base=(unsigned)((off-0xc00)*4);
        for(unsigned i=0;i<16&&base+i<GIC_NUM_IRQS;i++){unsigned id=base+i;if(id<16)continue;bool edge=(value>>(i*2))&2;if(id<32)g->bank[h].edge[id]=edge;else g->cfg_edge[id]=edge;}gic_update(g);return;}
    if(off==0xf00){unsigned id=(unsigned)value&15,filter=(unsigned)(value>>24)&3,targets=(unsigned)(value>>16)&255;
        if(filter==1)targets=mask&~(1u<<h);else if(filter==2)targets=1u<<h;else if(filter==3)return;
        for(unsigned target=0;target<g->m->ncpus;target++)if(targets&(1u<<target)){g->bank[target].sgi_pending[id]|=(u8)(1u<<h);g->bank[target].pending[id]=true;}gic_update(g);
    }
}
static u64 gicc_read(void *opaque,u64 off,unsigned size) {
    GIC *g=opaque;CPU *c=access_cpu(g);if(!c||!word_access(g,off,size))return 0;
    unsigned h=c->hart_id;struct GICBank *b=&g->bank[h];
    switch(off){case 0:return b->ctlr;case 4:return b->pmr;case 8:return b->bpr;case 0xc:return acknowledge(g,h);
    case 0x14:{unsigned r=running(g,h);return r==256?255:r;}
    case 0x18:return sgi_value(g,h,best(g,h));case 0xfc:return 0x0202143b;default:return 0;}
}
static void gicc_write(void *opaque,u64 off,unsigned size,u64 value) {
    GIC *g=opaque;CPU *c=access_cpu(g);if(!c||!word_access(g,off,size))return;
    struct GICBank *b=&g->bank[c->hart_id];
    switch(off){case 0:b->ctlr=(u32)value&(1|EOIMODE);break;case 4:b->pmr=(u8)value;break;case 8:b->bpr=(u8)value&7;break;
    case 0x10:deactivate(g,c->hart_id,(unsigned)value,(b->ctlr&EOIMODE)!=0);return;
    case 0x1000:deactivate(g,c->hart_id,(unsigned)value,false);return;default:return;}gic_update(g);
}
void gic_cpu_reset(GIC *g,unsigned h) {
    if(!g||h>=g->m->ncpus)return;
    memset(&g->bank[h],0,sizeof(g->bank[h]));
    for(unsigned id=0;id<16;id++){g->bank[h].enabled[id]=true;g->bank[h].edge[id]=true;}
    for(unsigned id=32;id<GIC_NUM_IRQS;id++)if(g->active_owner[id]==(int)h){g->active[id]=false;g->dropped[id]=false;g->active_owner[id]=-1;}
    machine_set_irq(g->m,h,false);gic_update(g);
}
void gic_reset(GIC *g) {
    Machine *m=g->m;memset(g,0,sizeof(*g));g->m=m;
    memset(g->active_owner,-1,sizeof(g->active_owner));memset(g->route_after,-1,sizeof(g->route_after));
    for(unsigned h=0;h<m->ncpus;h++)gic_cpu_reset(g,h);
}
GIC *gic_create(Machine *m) {
    GIC *g=calloc(1,sizeof(*g));if(!g)return NULL;g->m=m;gic_reset(g);
    machine_add_device(m,GICD_BASE,0x10000,gicd_read,gicd_write,g,"gicd");
    machine_add_device(m,GICC_BASE,0x10000,gicc_read,gicc_write,g,"gicc");m->gic=g;return g;
}
void gic_destroy(GIC *g){free(g);}

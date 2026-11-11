/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* Physical memory bus: RAM, flash, and MMIO device dispatch. */
#include "machine.h"
#include "mmu.h"     /* jit_invalidate_phys_range (SMC coherence hooks) */
#include "parallel_iface.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/mman.h>
#include <time.h>
#include <stdatomic.h>

typedef struct BusScope { Machine *machine;CPU *cpu;BusStatus status;bool yield; } BusScope;
static _Thread_local BusScope bus_scope;
CPU *machine_bus_cpu(Machine *m){return bus_scope.machine==m?bus_scope.cpu:NULL;}
BusStatus machine_bus_status(Machine *m){return bus_scope.machine==m?bus_scope.status:m->last_bus_status;}
void machine_bus_set_status(Machine *m,BusStatus status){
    bus_scope.machine=m;bus_scope.status=status;
    if(!m->parallel_ops)m->last_bus_status=status;
}
void machine_owner_yield(Machine *m){
    if(bus_scope.machine==m){bus_scope.yield=true;if(bus_scope.cpu)bus_scope.cpu->owner_yield=true;}
}
CPUPower machine_hart_power(Machine *m,unsigned h){
    return m->parallel_ops&&m->parallel_ops->power?m->parallel_ops->power(m,h):machine_cpu(m,h)->power;
}
void machine_set_irq(Machine *m,unsigned h,bool level){
    if(m->parallel_ops&&m->parallel_ops->irq)m->parallel_ops->irq(m,h,level);
    else machine_cpu(m,h)->irq_line=level;
}
bool machine_parallel_poll(CPU *c){
    return c->m&&c->m->parallel_ops&&c->m->parallel_ops->poll_cpu?c->m->parallel_ops->poll_cpu(c):false;
}
const MachineParallelPollView *machine_parallel_poll_view(CPU *c){
    if(!c||!c->m||!c->m->parallel_ops||!c->m->parallel_ops->poll_view)return NULL;
    const MachineParallelPollView *v=c->m->parallel_ops->poll_view(c);
    if(!v||v->cpu!=c||v->machine!=c->m||!v->pending||!v->abort_run||
       !v->stop||!v->memory_error)return NULL;
    return v;
}
void machine_tlbi(CPU *c,u64 va,bool page){
    if(c->m&&c->m->parallel_ops&&c->m->parallel_ops->tlbi){c->m->parallel_ops->tlbi(c,va,page);return;}
    if(c->m){if(page)tlb_flush_machine_page(c->m,va);else tlb_flush_machine(c->m);}
    else if(page)tlb_flush_page(c,va);else tlb_flush_all(c);
}
void machine_barrier(CPU *c,unsigned kind){
    atomic_thread_fence(memory_order_seq_cst);
    if(c->m&&c->m->parallel_ops&&c->m->parallel_ops->barrier)c->m->parallel_ops->barrier(c,kind);
    else if(kind==6)tlb_flush_all(c); /* ISB: refetch/retranslate locally */
    atomic_thread_fence(memory_order_seq_cst);
}
void machine_clock_reset(Machine *m) {
    struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
    m->clock_epoch_ns=(u64)now.tv_sec*1000000000ULL+(u64)now.tv_nsec;
    m->virtual_ticks=0;m->executing_cpu=NULL;m->quantum_icount=0;
    m->counter_hz=24000000ULL;
}
int machine_configure_cpus(Machine *m,unsigned count) {
    if(count<1||count>A64_MAX_CPUS||m->gic||m->fwcfg)return -1;
    m->ncpus=count;m->next_hart=0;
    for(unsigned i=0;i<A64_MAX_CPUS;i++) {
        CPU *c=i?&m->secondary[i-1]:&m->cpu;
        c->m=m;c->hart_id=i;cpu_reset(c,FLASH_BASE,1);
        if(i)c->power=CPU_POWER_OFF;
    }
    return 0;
}
void machine_send_event(Machine *m,CPU *local) {
    if(m->parallel_ops&&m->parallel_ops->wake_harts){
        m->parallel_ops->wake_harts(m,local?1u<<local->hart_id:(1u<<m->ncpus)-1);return;
    }
    for(unsigned i=0;i<m->ncpus;i++) {
        CPU *c=machine_cpu(m,i);if(local&&c!=local)continue;
        if(c->power!=CPU_POWER_ON)continue;
        c->event=true;
        if(c->halted&&c->sleep==CPU_SLEEP_WFE){c->event=false;cpu_wake(c);}
    }
}
void machine_store_notify(Machine *m,u64 pa,u64 length) {
    /* Separate from reservations: even a same-value store with no active
     * exclusive monitor invalidates the physical code-page snapshot. */
    memory_code_store_publish(m,pa,length);
    memory_monitor_store(m,pa,length);
}
void machine_dispatch_wakes(Machine *m,unsigned mask) {
    if(m->parallel_ops&&m->parallel_ops->wake_harts){m->parallel_ops->wake_harts(m,mask);return;}
    for(unsigned h=0;h<m->ncpus;h++)if(mask&(1u<<h))machine_send_event(m,machine_cpu(m,h));
}

void machine_init(Machine *m, u64 ram_size) {
    memset(m, 0, sizeof(*m));
    atomic_init(&m->host_error,0);atomic_init(&m->system_off,false);atomic_init(&m->system_reset,false);atomic_init(&m->virtual_ticks,0);
    m->ram_base = RAM_BASE;
    m->ram_size = ram_size ? ram_size : RAM_SIZE_DEF;
    /* mmap, not calloc: host page pointers to RAM must be 4 KB-aligned because
     * the D-TLB packs permission bits into their low bits (see mmu.h), and the
     * anonymous mapping gives lazily-zeroed pages for large guest RAM. */
    m->ram = mmap(NULL, m->ram_size, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m->ram == MAP_FAILED) m->ram = NULL;
    m->flash_base = FLASH_BASE;
    m->flash_size = FLASH_SIZE;
    m->flash = calloc(1, m->flash_size);
    m->flash_writable = true;
    m->flash_cfi[0].status = m->flash_cfi[1].status = 0x80;  /* CFI status: WSM ready */
    if (!m->ram || !m->flash) {
        fprintf(stderr, "fatal: out of memory allocating guest RAM/flash\n");
        m->host_error = -6; return;
    }
    if(memory_sync_init(m)){m->host_error=-6;return;}
    if(machine_regions_init(m)){m->host_error=-6;return;}
    m->ndev = 0;
    m->ncpus=1;
    for(unsigned i=0;i<A64_MAX_CPUS;i++) {
        CPU *c=i?&m->secondary[i-1]:&m->cpu;c->m=m;c->hart_id=i;
        c->power=i?CPU_POWER_OFF:CPU_POWER_ON;
    }
    machine_clock_reset(m);
}

/* ABI version 3 (online memory) initialization: the mapped RAM span is the
 * full 1 GiB envelope (boot RAM low 256 MiB + virtio-mem managed region
 * above it). Anonymous pages are lazily backed, so mapping the envelope
 * commits host memory only for pages the guest actually touches — a virtual
 * reservation, not eager allocation. The guest-visible boot RAM is reported
 * separately via m->boot_ram_size (DTB memory node); v1/v2 machine_init
 * keeps the exact historical single-size mapping. */
void machine_init_vmem(Machine *m, u64 ram_size) {
    machine_init(m, 0);            /* maps the default 1 GiB envelope */
    if (m->host_error) return;
    m->boot_ram_size = (!ram_size || ram_size > FLOE_BOOT_RAM_MAX) ? FLOE_BOOT_RAM_MAX : ram_size;
}

void machine_free(Machine *m) {
    /* Only called after the sole run_slice owner is quiescent. OFF does not
     * free caches while a current PD handler can still hold an entry. */
    for(unsigned h=0;h<A64_MAX_CPUS;h++)
        cpu_exec_destroy(h?&m->secondary[h-1]:&m->cpu);
    memory_sync_destroy(m);
    machine_regions_destroy(m);
    if (m->ram) munmap(m->ram, m->ram_size);
    free(m->flash);
    m->ram = m->flash = NULL; m->ndev = 0;
}

void machine_add_device(Machine *m, u64 base, u64 size, mmio_read_fn r,
                        mmio_write_fn w, void *opaque, const char *name) {
    if (!size || size>UINT64_MAX-base || m->ndev >= MAX_DEVS) {
        fprintf(stderr, "fatal: too many MMIO devices\n");
        m->host_error = -3; return;
    }
    MMIODev *d = &m->dev[m->ndev++];
    d->base = base; d->size = size; d->read = r; d->write = w;
    d->opaque = opaque; d->name = name;
}

/* ---------- NOR flash: Intel CFI (pflash_cfi01) command set ----------
 * EDK2 ArmVirtQemu stores UEFI variables in flash and drives it with the Intel
 * command set. We complete every program/erase instantly (status always ready).
 * Instruction fetch reads the array directly (mem_ifetch fast path) and is
 * unaffected by the command mode, matching real hardware (code runs from a bank
 * left in read-array mode). Block size matches EDK2's NorFlashQemuLib: 256 KB. */
enum { FL_ARRAY = 0, FL_STATUS, FL_ID, FL_CFI };
enum { PG_NONE = 0, PG_WORD, PG_ERASE, PG_BUFCNT, PG_BUFDATA, PG_BUFCONF };
#define FL_BLOCK   0x40000ULL          /* 256 KB erase block (SIZE_256KB) */
#define FL_STAT_RDY 0x80               /* SR.7: write state machine ready */

/* Program (clear bits) `size` bytes at flash offset `off` with `val`. */
static void flash_program(Machine *m, u64 off, unsigned size, u64 val) {
    /* Firmware code can live in flash: drop JIT translations on the
     * programmed bytes (no-op when -jit is off). */
    MemoryRange range={m->flash_base+off,size,true};MemoryGuard guard;
    if(!memory_guard_begin(&guard,m,&range,1))return;
    jit_invalidate_phys_range(m->flash_base + off, size);
    machine_store_notify(m,m->flash_base+off,size);
    for (unsigned i = 0; i < size; i++)
        m->flash[off + i] &= (u8)(val >> (i * 8));
    memory_guard_end(&guard);
}

/* CFI command write to the flash bank containing `off`. */
static void flash_cfi_write(Machine *m, u64 off, unsigned size, u64 val) {
    struct FlashCFI *s = &m->flash_cfi[off >= FLASH_BANK ? 1 : 0];
    unsigned cmd = val & 0xff;

    switch (s->prog) {                 /* data phases consume the write as data */
    case PG_WORD:
        flash_program(m, off, size, val); s->prog = PG_NONE; s->mode = FL_STATUS; return;
    case PG_BUFCNT:
        s->buf_cnt = (u32)((val & 0xffff) + 1); s->buf_seen = 0;
        s->buf_base = (u32)off; s->prog = PG_BUFDATA; return;
    case PG_BUFDATA:
        flash_program(m, off, size, val);
        if (++s->buf_seen >= s->buf_cnt) s->prog = PG_BUFCONF;
        return;
    case PG_BUFCONF:
        if (cmd == 0xd0) { s->prog = PG_NONE; s->mode = FL_STATUS; }
        return;
    case PG_ERASE:
        if (cmd == 0xd0) {             /* erase confirm: wipe the 256 KB block */
            u64 base = off & ~(FL_BLOCK - 1);
            MemoryRange range={m->flash_base+base,FL_BLOCK,true};MemoryGuard guard;
            if(!memory_guard_begin(&guard,m,&range,1))return;
            machine_store_notify(m,m->flash_base+base,FL_BLOCK);
            memset(m->flash + base, 0xff, FL_BLOCK);memory_guard_end(&guard);
            s->status = FL_STAT_RDY; s->prog = PG_NONE; s->mode = FL_STATUS;
        }
        return;
    }

    switch (cmd) {                     /* command phase */
    case 0xff: case 0xf0: s->mode = FL_ARRAY;  break;   /* read array */
    case 0x70:            s->mode = FL_STATUS; break;   /* read status */
    case 0x50:            s->status = FL_STAT_RDY; break; /* clear status */
    case 0x90:            s->mode = FL_ID;     break;   /* read identifier */
    case 0x98:            s->mode = FL_CFI;    break;   /* CFI query */
    case 0x10: case 0x40: s->prog = PG_WORD;   s->mode = FL_STATUS; break; /* word program */
    case 0x20:            s->prog = PG_ERASE;  s->mode = FL_STATUS; break; /* block erase */
    case 0xe8:            s->prog = PG_BUFCNT; s->mode = FL_STATUS; break; /* buffer program */
    default: break;
    }
}

/* Minimal Intel CFI query table (byte at CFI word offset). */
static u8 cfi_query_byte(u64 word_off) {
    switch (word_off) {
    case 0x10: return 'Q';  case 0x11: return 'R';  case 0x12: return 'Y';
    case 0x13: return 0x01; case 0x14: return 0x00;       /* primary cmd set: Intel */
    case 0x27: return 0x1a;                                /* device size: 2^26 = 64 MB */
    case 0x28: return 0x02; case 0x29: return 0x00;       /* x16 async interface */
    case 0x2a: return 0x05; case 0x2b: return 0x00;       /* max write buffer 2^5 = 32 B */
    case 0x2c: return 0x01;                                /* one erase region */
    case 0x2d: return 0xff; case 0x2e: return 0x00;       /* (256-1) blocks */
    case 0x2f: return 0x00; case 0x30: return 0x04;       /* 0x0400*256 = 256 KB block */
    default:   return 0x00;
    }
}

/* CFI read from the flash bank containing `off`. Returns true if handled (mode
 * other than read-array); *out holds the value. */
static bool flash_cfi_read(Machine *m, u64 off, unsigned size, u64 *out) {
    struct FlashCFI *s = &m->flash_cfi[off >= FLASH_BANK ? 1 : 0];
    if (s->mode == FL_ARRAY) return false;          /* normal array read */
    u64 bank_off = off & (FLASH_BANK - 1);
    u64 v = 0;
    for (unsigned i = 0; i < size; i++) {
        u8 b = 0;
        if (s->mode == FL_STATUS) b = (i & 1) ? 0 : s->status;     /* SR in each x16 lane */
        else if (s->mode == FL_ID) {
            u64 wo = (bank_off + i) >> 1;            /* x16 word offset */
            b = ((bank_off + i) & 1) ? 0 : (wo == 0 ? 0x89 : wo == 1 ? 0x18 : 0x00);
        } else /* FL_CFI */ {
            u64 wo = (bank_off + i) >> 1;
            b = ((bank_off + i) & 1) ? 0 : cfi_query_byte(wo);
        }
        v |= (u64)b << (i * 8);
    }
    *out = v;
    return true;
}

/* Return the NOR flash command state machine to read-array/ready on system
 * reset. The array contents (UEFI variable store) are non-volatile and left
 * intact; this only clears a program/erase left in flight when the reset hit. */
void flash_cfi_reset(Machine *m) {
    for (int b = 0; b < 2; b++) {
        m->flash_cfi[b].mode   = FL_ARRAY;
        m->flash_cfi[b].prog   = PG_NONE;
        m->flash_cfi[b].status = FL_STAT_RDY;
        m->flash_cfi[b].buf_base = m->flash_cfi[b].buf_cnt = m->flash_cfi[b].buf_seen = 0;
    }
}

/* Complete spans without pa+length or base+size overflow. */
static bool bus_span(u64 base,u64 size,u64 pa,u64 length) {
    return pa>=base && length<=size && pa-base<=size-length;
}
static MMIODev *find_dev(Machine *m, u64 pa, u64 length) {
    for (int i = 0; i < m->ndev; i++) {
        MMIODev *d = &m->dev[i];
        if (bus_span(d->base,d->size,pa,length)) return d;
    }
    return NULL;
}

void *ram_ptr(Machine *m, u64 pa, u64 len) {
    if (m->ram && bus_span(m->ram_base,m->ram_size,pa,len))
        return m->ram + (pa - m->ram_base);
    /* Device-mappable regions (virtio-gpu host-visible aperture, virtio-mem
     * hotplug region). A sparse hole returns NULL and faults like any other
     * unmapped PA. Segment publication is release-ordered, so a worker filling
     * its D-TLB here sees either no segment or a fully initialized one. */
    return machine_region_host_ptr(m, pa, len);
}

/* Host is little-endian; guest is little-endian. Direct memcpy preserves order.
 * Fixed-size copies for the power-of-two sizes (#3): the compiler turns each
 * into a single load/store; odd sizes (page-split fragments) keep the runtime
 * memcpy. */
static inline u64 ld_le(const u8 *p, unsigned size) {
    switch (size) {
        case 1: return *p;
        case 2: { u16 v; memcpy(&v, p, 2); return v; }
        case 4: { u32 v; memcpy(&v, p, 4); return v; }
        case 8: { u64 v; memcpy(&v, p, 8); return v; }
        default: { u64 v = 0; memcpy(&v, p, size); return v; }
    }
}
static inline void st_le(u8 *p, unsigned size, u64 v) {
    switch (size) {
        case 1: *p = (u8)v; break;
        case 2: { u16 x = (u16)v; memcpy(p, &x, 2); break; }
        case 4: { u32 x = (u32)v; memcpy(p, &x, 4); break; }
        case 8: memcpy(p, &v, 8); break;
        default: memcpy(p, &v, size); break;
    }
}
static u64 bus_read(Machine *m, u64 pa, unsigned size) {
    machine_bus_set_status(m,BUS_OK);
    if(!size||size>8||size>UINT64_MAX-pa){machine_bus_set_status(m,BUS_FAULT);return 0;}
    if (g_dbg >= 2 && pa >= RAM_BASE && pa < RAM_BASE + 0x40) {
        static _Thread_local int n = 0;
        if (n++ < 40) fprintf(stderr, "[dtbrd] pa=0x%llx size=%u pc=0x%llx\n",
                              (unsigned long long)pa, size, (unsigned long long)(machine_bus_cpu(m)?machine_bus_cpu(m)->cur_insn_pc:0));
    }
    if (m->ram && bus_span(m->ram_base,m->ram_size,pa,size)) {
        MemoryRange range={pa,size,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return 0;}
        u64 value=ld_le(m->ram+(pa-m->ram_base),size);memory_guard_end(&guard);return value;
    }
    if (m->flash && bus_span(m->flash_base,m->flash_size,pa,size)) {
        u64 off = pa - m->flash_base, v = 0;
        if (flash_cfi_read(m, off, size, &v)) return v;   /* status/id/cfi mode */
        MemoryRange range={pa,size,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return 0;}
        u64 value=ld_le(m->flash+off,size);memory_guard_end(&guard);return value;
    }
    u8 *region = machine_region_host_ptr(m, pa, size);
    if (region) {
        MemoryRange range={pa,size,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return 0;}
        u64 value=ld_le(region,size);memory_guard_end(&guard);return value;
    }
    MMIODev *d = find_dev(m, pa, size);
    if (d && d->read) return d->read(d->opaque, pa - d->base, size);

    machine_bus_set_status(m,BUS_FAULT);
    if (g_trace)
        fprintf(stderr, "[bus] unmapped read  pa=0x%llx size=%u\n",
                (unsigned long long)pa, size);
    return 0;
}

static void bus_write(Machine *m, u64 pa, unsigned size, u64 value) {
    machine_bus_set_status(m,BUS_OK);
    if(!size||size>8||size>UINT64_MAX-pa){machine_bus_set_status(m,BUS_FAULT);return;}
    if (g_dbg >= 3 && pa >= 0x40000000 && pa < 0x40000020)
        fprintf(stderr, "[wwatch] pa=0x%llx size=%u val=0x%llx pc=0x%llx\n",
                (unsigned long long)pa, size, (unsigned long long)value,
                (unsigned long long)(machine_bus_cpu(m)?machine_bus_cpu(m)->cur_insn_pc:0));
    if (g_watch && pa < g_watch + 8 && pa + size > g_watch)
        fprintf(stderr, "[watch] pa=0x%llx size=%u val=0x%llx pc=0x%llx icount=%llu\n",
                (unsigned long long)pa, size, (unsigned long long)value,
                (unsigned long long)(machine_bus_cpu(m)?machine_bus_cpu(m)->cur_insn_pc:0),
                (unsigned long long)(machine_bus_cpu(m)?machine_bus_cpu(m)->icount:0));
    if (m->ram && bus_span(m->ram_base,m->ram_size,pa,size)) {
        MemoryRange range={pa,size,true};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        machine_store_notify(m,pa,size);
        st_le(m->ram + (pa - m->ram_base), size, value);memory_guard_end(&guard);
        return;
    }
    if (m->flash && bus_span(m->flash_base,m->flash_size,pa,size)) {
        flash_cfi_write(m, pa - m->flash_base, size, value);   /* Intel CFI commands */
        return;
    }
    u8 *region = machine_region_host_ptr(m, pa, size);
    if (region) {
        MemoryRange range={pa,size,true};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        machine_store_notify(m,pa,size);
        st_le(region,size,value);memory_guard_end(&guard);
        return;
    }
    MMIODev *d = find_dev(m, pa, size);
    if (d && d->write) { d->write(d->opaque, pa - d->base, size, value); return; }

    machine_bus_set_status(m,BUS_FAULT);
    if (g_trace)
        fprintf(stderr, "[bus] unmapped write pa=0x%llx size=%u val=0x%llx\n",
                (unsigned long long)pa, size, (unsigned long long)value);
}

/* No shared mutable bus_cpu/last-status slot in active parallel execution.
 * Requests carry only hart identity; callbacks run on the coordinator. */
static u64 scoped_access(Machine *m,CPU *c,u64 pa,unsigned size,bool write,u64 value){
    BusScope prior=bus_scope;bus_scope=(BusScope){m,c,BUS_OK,false};
    MachineBusReply reply={0,BUS_OK,false};
    bool ram=(m->ram&&bus_span(m->ram_base,m->ram_size,pa,size)) ||
             machine_region_host_ptr(m,pa,size)!=NULL;
    if(c&&!ram&&m->parallel_ops&&m->parallel_ops->bus_access&&
       m->parallel_ops->bus_access(c,pa,size,write,value,&reply)){
        bus_scope.status=reply.status;bus_scope.yield=reply.yield;value=reply.value;
    } else if(write)bus_write(m,pa,size,value);else value=bus_read(m,pa,size);
    BusStatus status=bus_scope.status;bool yield=bus_scope.yield;
    bus_scope=prior;bus_scope.machine=m;bus_scope.status=status;
    if(!m->parallel_ops)m->last_bus_status=status;
    if(c&&yield)c->owner_yield=true;
    return value;
}
u64 phys_read(Machine *m,u64 pa,unsigned size){return scoped_access(m,NULL,pa,size,false,0);}
void phys_write(Machine *m,u64 pa,unsigned size,u64 value){(void)scoped_access(m,NULL,pa,size,true,value);}
u64 phys_read_cpu(CPU *c,u64 pa,unsigned size){return scoped_access(c->m,c,pa,size,false,0);}
void phys_write_cpu(CPU *c,u64 pa,unsigned size,u64 value){(void)scoped_access(c->m,c,pa,size,true,value);}
/* Only the coordinator calls this while a worker is blocked on its mailbox.
 * The proxy is an identity/scope token, never another worker's CPU storage. */
MachineBusReply machine_bus_service(Machine *m,unsigned hart,u64 pa,unsigned size,bool write,u64 value,u64 pc,u64 icount){
    CPU proxy={.m=m,.hart_id=hart,.cur_insn_pc=pc,.icount=icount};BusScope prior=bus_scope;
    bus_scope=(BusScope){m,&proxy,BUS_OK,false};
    if(write)bus_write(m,pa,size,value);else value=bus_read(m,pa,size);
    MachineBusReply reply={value,bus_scope.status,bus_scope.yield};bus_scope=prior;return reply;
}

void phys_write_blk(Machine *m, u64 pa, const void *src, u64 len) {
    machine_bus_set_status(m,BUS_OK);
    if(len>UINT64_MAX-pa){machine_bus_set_status(m,BUS_FAULT);return;}
    if(!len)return;
    const u8 *s = src;
    /* Device DMA / loader writes bypass mem_write's store hook: drop any
     * JIT translations in the written range (virtio-blk module loads,
     * fwcfg blobs, warm-reboot DTB restore). Cheap no-op when -jit is off. */
    jit_invalidate_phys_range(pa, len);
    /* RAM fast path */
    if (m->ram && bus_span(m->ram_base,m->ram_size,pa,len)) {
        MemoryRange range={pa,len,true};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        machine_store_notify(m,pa,len);
        memcpy(m->ram + (pa - m->ram_base), s, len);memory_guard_end(&guard);
        return;
    }
    if (m->flash && bus_span(m->flash_base,m->flash_size,pa,len)) {
        MemoryRange range={pa,len,true};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        machine_store_notify(m,pa,len);
        memcpy(m->flash + (pa - m->flash_base), s, len);memory_guard_end(&guard);
        return;
    }
    u8 *region = machine_region_host_ptr(m, pa, len);
    if (region) {
        MemoryRange range={pa,len,true};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        jit_invalidate_phys_range(pa, len);
        machine_store_notify(m,pa,len);
        memcpy(region, s, len);memory_guard_end(&guard);
        return;
    }
    bool fault=false;
    for(u64 i=0;i<len;i++){phys_write(m,pa+i,1,s[i]);fault|=machine_bus_status(m)!=BUS_OK;}
    if(fault)machine_bus_set_status(m,BUS_FAULT);
}

void phys_read_blk(Machine *m, u64 pa, void *dst, u64 len) {
    machine_bus_set_status(m,BUS_OK);
    if(len>UINT64_MAX-pa){machine_bus_set_status(m,BUS_FAULT);return;}
    if(!len)return;
    u8 *d = dst;
    if (m->ram && bus_span(m->ram_base,m->ram_size,pa,len)) {
        MemoryRange range={pa,len,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        memcpy(d, m->ram + (pa - m->ram_base), len);memory_guard_end(&guard);
        return;
    }
    if (m->flash && bus_span(m->flash_base,m->flash_size,pa,len)) {
        MemoryRange range={pa,len,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        memcpy(d, m->flash + (pa - m->flash_base), len);memory_guard_end(&guard);
        return;
    }
    u8 *region = machine_region_host_ptr(m, pa, len);
    if (region) {
        MemoryRange range={pa,len,false};MemoryGuard guard;
        if(!memory_guard_begin(&guard,m,&range,1)){machine_bus_set_status(m,BUS_FAULT);return;}
        memcpy(d, region, len);memory_guard_end(&guard);
        return;
    }
    bool fault=false;
    for(u64 i=0;i<len;i++){d[i]=(u8)phys_read(m,pa+i,1);fault|=machine_bus_status(m)!=BUS_OK;}
    if(fault)machine_bus_set_status(m,BUS_FAULT);
}

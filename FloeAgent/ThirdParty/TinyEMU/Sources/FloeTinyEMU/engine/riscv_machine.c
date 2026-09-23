/*
 * RISCV machine
 * 
 * Copyright (c) 2016-2017 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <inttypes.h>
#include <assert.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

#include "cutils.h"
#include "iomem.h"
#include "riscv_cpu.h"
#include "virtio.h"
#include "machine.h"

/* RISCV machine */

typedef struct RISCVMachine {
    VirtMachine common;
    PhysMemoryMap *mem_map;
    int max_xlen;
    RISCVCPUState *cpu_state; /* == cpus[0] */
    /* FLOE-SMP: per-hart CPU states sharing mem_map (RAM + devices).
       Hart i owns cpus[i]; the embedder drives each hart from its own
       host thread through the per-hart machine-class hooks. cpu_state
       stays as the hart-0 alias for the legacy single-hart paths. */
    RISCVCPUState *cpus[RISCV_SMP_MAX_HARTS];
    int nb_harts;
    RISCVSMPCpuArray smp;
    int smp_atomic_lock; /* spinlock, 0 = free */
    pthread_mutex_t smp_device_lock;
    uint64_t ram_size;
    /* RTC */
    BOOL rtc_real_time;
    uint64_t rtc_start_time;
    /* FLOE-SMP: per-hart CLINT compare values and software-interrupt
       pending bits (hart i: msip[i] bit 0 <-> MIP_MSIP of cpus[i]). */
    uint64_t timecmp[RISCV_SMP_MAX_HARTS];
    uint32_t msip[RISCV_SMP_MAX_HARTS];
    /* PLIC */
    uint32_t plic_pending_irq, plic_served_irq;
    IRQSignal plic_irq[32]; /* IRQ 0 is not used */
    /* HTIF */
    uint64_t htif_tohost, htif_fromhost;

    /* FLOE-EMBED: set instead of exit(0) on guest poweroff. Atomic:
       written under the device lock, read by the embedder's run thread. */
    BOOL poweroff_requested;

    VIRTIODevice *keyboard_dev;
    VIRTIODevice *mouse_dev;

    int virtio_count;
} RISCVMachine;

#define LOW_RAM_SIZE   0x00010000 /* 64KB */
#define RAM_BASE_ADDR  0x80000000
#define CLINT_BASE_ADDR 0x02000000
#define CLINT_SIZE      0x000c0000
#define HTIF_BASE_ADDR 0x40008000
#define IDE_BASE_ADDR  0x40009000
#define VIRTIO_BASE_ADDR 0x40010000
#define VIRTIO_SIZE      0x1000
#define VIRTIO_IRQ       1
#define PLIC_BASE_ADDR 0x40100000
#define PLIC_SIZE      0x00400000
#define FRAMEBUFFER_BASE_ADDR 0x41000000

#define RTC_FREQ 10000000
#define RTC_FREQ_DIV 16 /* arbitrary, relative to CPU freq to have a
                           10 MHz frequency */

static uint64_t rtc_get_real_time(RISCVMachine *s)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * RTC_FREQ +
        (ts.tv_nsec / (1000000000 / RTC_FREQ));
}

static uint64_t rtc_get_time(RISCVMachine *m)
{
    uint64_t val;
    if (m->rtc_real_time) {
        val = rtc_get_real_time(m) - m->rtc_start_time;
    } else {
        val = riscv_cpu_get_cycles(m->cpu_state) / RTC_FREQ_DIV;
    }
    //    printf("rtc_time=%" PRId64 "\n", val);
    return val;
}

static uint32_t htif_read(void *opaque, uint32_t offset,
                          int size_log2)
{
    RISCVMachine *s = opaque;
    uint32_t val;

    assert(size_log2 == 2);
    switch(offset) {
    case 0:
        val = s->htif_tohost;
        break;
    case 4:
        val = s->htif_tohost >> 32;
        break;
    case 8:
        val = s->htif_fromhost;
        break;
    case 12:
        val = s->htif_fromhost >> 32;
        break;
    default:
        val = 0;
        break;
    }
    return val;
}

static void htif_handle_cmd(RISCVMachine *s)
{
    uint32_t device, cmd;

    device = s->htif_tohost >> 56;
    cmd = (s->htif_tohost >> 48) & 0xff;
    if (s->htif_tohost == 1) {
        /* shuthost -- FLOE-EMBED: a library must not exit(0) the host
           process; record the request, the embedder ends the VM.
           Atomic: written under the device lock, read cross-thread. */
        __atomic_store_n(&s->poweroff_requested, TRUE, __ATOMIC_SEQ_CST);
    } else if (device == 1 && cmd == 1) {
        uint8_t buf[1];
        buf[0] = s->htif_tohost & 0xff;
        s->common.console->write_data(s->common.console->opaque, buf, 1);
        s->htif_tohost = 0;
        s->htif_fromhost = ((uint64_t)device << 56) | ((uint64_t)cmd << 48);
    } else if (device == 1 && cmd == 0) {
        /* request keyboard interrupt */
        s->htif_tohost = 0;
    } else {
        printf("HTIF: unsupported tohost=0x%016" PRIx64 "\n", s->htif_tohost);
    }
}

static void htif_write(void *opaque, uint32_t offset, uint32_t val,
                       int size_log2)
{
    RISCVMachine *s = opaque;

    assert(size_log2 == 2);
    switch(offset) {
    case 0:
        s->htif_tohost = (s->htif_tohost & ~0xffffffff) | val;
        break;
    case 4:
        s->htif_tohost = (s->htif_tohost & 0xffffffff) | ((uint64_t)val << 32);
        htif_handle_cmd(s);
        break;
    case 8:
        s->htif_fromhost = (s->htif_fromhost & ~0xffffffff) | val;
        break;
    case 12:
        s->htif_fromhost = (s->htif_fromhost & 0xffffffff) |
            (uint64_t)val << 32;
        break;
    default:
        break;
    }
}

#if 0
static void htif_poll(RISCVMachine *s)
{
    uint8_t buf[1];
    int ret;

    if (s->htif_fromhost == 0) {
        ret = s->console->read_data(s->console->opaque, buf, 1);
        if (ret == 1) {
            s->htif_fromhost = ((uint64_t)1 << 56) | ((uint64_t)0 << 48) |
                buf[0];
        }
    }
}
#endif

/* FLOE-SMP: the CLINT decodes per-hart msip (0x0 + 4*hart) and
 * timecmp (0x4000 + 8*hart) registers; mtime (0xbff8) is shared. The
 * per-hart decode reduces exactly to the upstream hart-0 behavior when
 * nb_harts == 1. */
static uint32_t clint_read(void *opaque, uint32_t offset, int size_log2)
{
    RISCVMachine *m = opaque;
    uint32_t val;

    assert(size_log2 == 2);
    if (offset < 4 * RISCV_SMP_MAX_HARTS) {
        int hart = offset >> 2;
        val = (hart < m->nb_harts) ? (m->msip[hart] & 1) : 0;
    } else if (offset >= 0x4000 &&
               offset < 0x4000 + 8 * RISCV_SMP_MAX_HARTS) {
        int hart = (offset - 0x4000) >> 3;
        if (hart < m->nb_harts)
            val = (offset & 4) ? (m->timecmp[hart] >> 32) : m->timecmp[hart];
        else
            val = 0;
    } else {
        switch(offset) {
        case 0xbff8:
            val = rtc_get_time(m);
            break;
        case 0xbffc:
            val = rtc_get_time(m) >> 32;
            break;
        default:
            val = 0;
            break;
        }
    }
    return val;
}
 
static void clint_write(void *opaque, uint32_t offset, uint32_t val,
                       int size_log2)
{
    RISCVMachine *m = opaque;

    assert(size_log2 == 2);
    if (offset < 4 * RISCV_SMP_MAX_HARTS) {
        /* per-hart msip: IPI doorbell for hart (offset >> 2) */
        int hart = offset >> 2;
        if (hart < m->nb_harts) {
            m->msip[hart] = val & 1;
            if (val & 1)
                riscv_cpu_set_mip(m->cpus[hart], MIP_MSIP);
            else
                riscv_cpu_reset_mip(m->cpus[hart], MIP_MSIP);
        }
    } else if (offset >= 0x4000 &&
               offset < 0x4000 + 8 * RISCV_SMP_MAX_HARTS) {
        int hart = (offset - 0x4000) >> 3;
        if (hart < m->nb_harts) {
            if (offset & 4)
                m->timecmp[hart] = (m->timecmp[hart] & 0xffffffff) |
                    ((uint64_t)val << 32);
            else
                m->timecmp[hart] = (m->timecmp[hart] & ~0xffffffff) | val;
            riscv_cpu_reset_mip(m->cpus[hart], MIP_MTIP);
        }
    }
}

static void plic_update_mip(RISCVMachine *s)
{
    /* FLOE-SMP: level-triggered external interrupts are broadcast to
       every hart (M + S); the claim register arbitrates which hart
       actually serves each source, under the machine device lock. */
    uint32_t mask;
    int i;
    mask = s->plic_pending_irq & ~s->plic_served_irq;
    for(i = 0; i < s->nb_harts; i++) {
        if (mask) {
            riscv_cpu_set_mip(s->cpus[i], MIP_MEIP | MIP_SEIP);
        } else {
            riscv_cpu_reset_mip(s->cpus[i], MIP_MEIP | MIP_SEIP);
        }
    }
}

#define PLIC_HART_BASE 0x200000
#define PLIC_HART_SIZE 0x1000
/* FLOE-SMP: one S and one M context per hart, in FDT interrupts-extended
 * order (S-ext 9 first, M-ext 11 second): context = 2*hart + (0=S,1=M).
 * Claim/complete accept every context; sources are not enable/priority
 * masked (same simplification as upstream single-hart TinyEMU), which is
 * sufficient because any hart may serve any level-triggered source. */
#define PLIC_CONTEXTS(m) (2 * (m)->nb_harts)

static uint32_t plic_read(void *opaque, uint32_t offset, int size_log2)
{
    RISCVMachine *s = opaque;
    uint32_t val, mask;
    int i;
    assert(size_log2 == 2);
    if (offset >= PLIC_HART_BASE &&
        offset < PLIC_HART_BASE + PLIC_CONTEXTS(s) * PLIC_HART_SIZE) {
        uint32_t ctx_off = offset & (PLIC_HART_SIZE - 1);
        if (ctx_off == 4) {
            /* claim: first claimant serves the lowest pending source */
            mask = s->plic_pending_irq & ~s->plic_served_irq;
            if (mask != 0) {
                i = ctz32(mask);
                s->plic_served_irq |= 1 << i;
                plic_update_mip(s);
                val = i + 1;
            } else {
                val = 0;
            }
        } else {
            val = 0;
        }
        return val;
    }
    return 0;
}

static void plic_write(void *opaque, uint32_t offset, uint32_t val,
                       int size_log2)
{
    RISCVMachine *s = opaque;

    assert(size_log2 == 2);
    if (offset >= PLIC_HART_BASE &&
        offset < PLIC_HART_BASE + PLIC_CONTEXTS(s) * PLIC_HART_SIZE) {
        uint32_t ctx_off = offset & (PLIC_HART_SIZE - 1);
        if (ctx_off == 4) {
            /* complete */
            val--;
            if (val < 32) {
                s->plic_served_irq &= ~(1 << val);
                plic_update_mip(s);
            }
        }
    }
}

static void plic_set_irq(void *opaque, int irq_num, int state)
{
    RISCVMachine *s = opaque;
    uint32_t mask;

    mask = 1 << (irq_num - 1);
    if (state) 
        s->plic_pending_irq |= mask;
    else
        s->plic_pending_irq &= ~mask;
    plic_update_mip(s);
}

static uint8_t *get_ram_ptr(RISCVMachine *s, uint64_t paddr, BOOL is_rw)
{
    return phys_mem_get_ram_ptr(s->mem_map, paddr, is_rw);
}

/* FDT machine description */

#define FDT_MAGIC	0xd00dfeed
#define FDT_VERSION	17

struct fdt_header {
    uint32_t magic;
    uint32_t totalsize;
    uint32_t off_dt_struct;
    uint32_t off_dt_strings;
    uint32_t off_mem_rsvmap;
    uint32_t version;
    uint32_t last_comp_version; /* <= 17 */
    uint32_t boot_cpuid_phys;
    uint32_t size_dt_strings;
    uint32_t size_dt_struct;
};

struct fdt_reserve_entry {
       uint64_t address;
       uint64_t size;
};

#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_NOP		4
#define FDT_END		9

typedef struct {
    uint32_t *tab;
    int tab_len;
    int tab_size;
    int open_node_count;
    
    char *string_table;
    int string_table_len;
    int string_table_size;
} FDTState;

static FDTState *fdt_init(void)
{
    FDTState *s;
    s = mallocz(sizeof(*s));
    return s;
}

static void fdt_alloc_len(FDTState *s, int len)
{
    int new_size;
    if (unlikely(len > s->tab_size)) {
        new_size = max_int(len, s->tab_size * 3 / 2);
        s->tab = realloc(s->tab, new_size * sizeof(uint32_t));
        s->tab_size = new_size;
    }
}

static void fdt_put32(FDTState *s, int v)
{
    fdt_alloc_len(s, s->tab_len + 1);
    s->tab[s->tab_len++] = cpu_to_be32(v);
}

/* the data is zero padded */
static void fdt_put_data(FDTState *s, const uint8_t *data, int len)
{
    int len1;
    
    len1 = (len + 3) / 4;
    fdt_alloc_len(s, s->tab_len + len1);
    memcpy(s->tab + s->tab_len, data, len);
    memset((uint8_t *)(s->tab + s->tab_len) + len, 0, -len & 3);
    s->tab_len += len1;
}

static void fdt_begin_node(FDTState *s, const char *name)
{
    fdt_put32(s, FDT_BEGIN_NODE);
    fdt_put_data(s, (uint8_t *)name, strlen(name) + 1);
    s->open_node_count++;
}

static void fdt_begin_node_num(FDTState *s, const char *name, uint64_t n)
{
    char buf[256];
    snprintf(buf, sizeof(buf), "%s@%" PRIx64, name, n);
    fdt_begin_node(s, buf);
}

static void fdt_end_node(FDTState *s)
{
    fdt_put32(s, FDT_END_NODE);
    s->open_node_count--;
}

static int fdt_get_string_offset(FDTState *s, const char *name)
{
    int pos, new_size, name_size, new_len;

    pos = 0;
    while (pos < s->string_table_len) {
        if (!strcmp(s->string_table + pos, name))
            return pos;
        pos += strlen(s->string_table + pos) + 1;
    }
    /* add a new string */
    name_size = strlen(name) + 1;
    new_len = s->string_table_len + name_size;
    if (new_len > s->string_table_size) {
        new_size = max_int(new_len, s->string_table_size * 3 / 2);
        s->string_table = realloc(s->string_table, new_size);
        s->string_table_size = new_size;
    }
    pos = s->string_table_len;
    memcpy(s->string_table + pos, name, name_size);
    s->string_table_len = new_len;
    return pos;
}

static void fdt_prop(FDTState *s, const char *prop_name,
                     const void *data, int data_len)
{
    fdt_put32(s, FDT_PROP);
    fdt_put32(s, data_len);
    fdt_put32(s, fdt_get_string_offset(s, prop_name));
    fdt_put_data(s, data, data_len);
}

static void fdt_prop_tab_u32(FDTState *s, const char *prop_name,
                             uint32_t *tab, int tab_len)
{
    int i;
    fdt_put32(s, FDT_PROP);
    fdt_put32(s, tab_len * sizeof(uint32_t));
    fdt_put32(s, fdt_get_string_offset(s, prop_name));
    for(i = 0; i < tab_len; i++)
        fdt_put32(s, tab[i]);
}

static void fdt_prop_u32(FDTState *s, const char *prop_name, uint32_t val)
{
    fdt_prop_tab_u32(s, prop_name, &val, 1);
}

static void fdt_prop_tab_u64(FDTState *s, const char *prop_name,
                             uint64_t v0)
{
    uint32_t tab[2];
    tab[0] = v0 >> 32;
    tab[1] = v0;
    fdt_prop_tab_u32(s, prop_name, tab, 2);
}

static void fdt_prop_tab_u64_2(FDTState *s, const char *prop_name,
                               uint64_t v0, uint64_t v1)
{
    uint32_t tab[4];
    tab[0] = v0 >> 32;
    tab[1] = v0;
    tab[2] = v1 >> 32;
    tab[3] = v1;
    fdt_prop_tab_u32(s, prop_name, tab, 4);
}

static void fdt_prop_str(FDTState *s, const char *prop_name,
                         const char *str)
{
    fdt_prop(s, prop_name, str, strlen(str) + 1);
}

/* NULL terminated string list */
static void fdt_prop_tab_str(FDTState *s, const char *prop_name,
                             ...)
{
    va_list ap;
    int size, str_size;
    char *ptr, *tab;

    va_start(ap, prop_name);
    size = 0;
    for(;;) {
        ptr = va_arg(ap, char *);
        if (!ptr)
            break;
        str_size = strlen(ptr) + 1;
        size += str_size;
    }
    va_end(ap);
    
    tab = malloc(size);
    va_start(ap, prop_name);
    size = 0;
    for(;;) {
        ptr = va_arg(ap, char *);
        if (!ptr)
            break;
        str_size = strlen(ptr) + 1;
        memcpy(tab + size, ptr, str_size);
        size += str_size;
    }
    va_end(ap);
    
    fdt_prop(s, prop_name, tab, size);
    free(tab);
}

/* write the FDT to 'dst1'. return the FDT size in bytes */
int fdt_output(FDTState *s, uint8_t *dst)
{
    struct fdt_header *h;
    struct fdt_reserve_entry *re;
    int dt_struct_size;
    int dt_strings_size;
    int pos;

    assert(s->open_node_count == 0);
    
    fdt_put32(s, FDT_END);
    
    dt_struct_size = s->tab_len * sizeof(uint32_t);
    dt_strings_size = s->string_table_len;

    h = (struct fdt_header *)dst;
    h->magic = cpu_to_be32(FDT_MAGIC);
    h->version = cpu_to_be32(FDT_VERSION);
    h->last_comp_version = cpu_to_be32(16);
    h->boot_cpuid_phys = cpu_to_be32(0);
    h->size_dt_strings = cpu_to_be32(dt_strings_size);
    h->size_dt_struct = cpu_to_be32(dt_struct_size);

    pos = sizeof(struct fdt_header);

    h->off_dt_struct = cpu_to_be32(pos);
    memcpy(dst + pos, s->tab, dt_struct_size);
    pos += dt_struct_size;

    /* align to 8 */
    while ((pos & 7) != 0) {
        dst[pos++] = 0;
    }
    h->off_mem_rsvmap = cpu_to_be32(pos);
    re = (struct fdt_reserve_entry *)(dst + pos);
    re->address = 0; /* no reserved entry */
    re->size = 0;
    pos += sizeof(struct fdt_reserve_entry);

    h->off_dt_strings = cpu_to_be32(pos);
    memcpy(dst + pos, s->string_table, dt_strings_size);
    pos += dt_strings_size;

    /* align to 8, just in case */
    while ((pos & 7) != 0) {
        dst[pos++] = 0;
    }

    h->totalsize = cpu_to_be32(pos);
    return pos;
}

void fdt_end(FDTState *s)
{
    free(s->tab);
    free(s->string_table);
    free(s);
}

static int riscv_build_fdt(RISCVMachine *m, uint8_t *dst,
                           uint64_t kernel_start, uint64_t kernel_size,
                           uint64_t initrd_start, uint64_t initrd_size,
                           const char *cmd_line)
{
    FDTState *s;
    int size, max_xlen, i, cur_phandle, plic_phandle;
    int intc_phandle[RISCV_SMP_MAX_HARTS];
    char isa_string[128], *q;
    uint32_t misa;
    uint32_t tab[4 * RISCV_SMP_MAX_HARTS];
    FBDevice *fb_dev;

    s = fdt_init();

    cur_phandle = 1;

    fdt_begin_node(s, "");
    fdt_prop_u32(s, "#address-cells", 2);
    fdt_prop_u32(s, "#size-cells", 2);
    fdt_prop_str(s, "compatible", "ucbbar,riscvemu-bar_dev");
    fdt_prop_str(s, "model", "ucbbar,riscvemu-bare");

    /* CPU list (FLOE-SMP: one node per hart; nb_harts == 1 emits exactly
       the upstream single-cpu tree) */
    fdt_begin_node(s, "cpus");
    fdt_prop_u32(s, "#address-cells", 1);
    fdt_prop_u32(s, "#size-cells", 0);
    fdt_prop_u32(s, "timebase-frequency", RTC_FREQ);

    max_xlen = m->max_xlen;
    misa = riscv_cpu_get_misa(m->cpu_state);
    q = isa_string;
    q += snprintf(isa_string, sizeof(isa_string), "rv%d", max_xlen);
    for(i = 0; i < 26; i++) {
        if (misa & (1 << i))
            *q++ = 'a' + i;
    }
    *q = '\0';

    for(i = 0; i < m->nb_harts; i++) {
        fdt_begin_node_num(s, "cpu", i);
        fdt_prop_str(s, "device_type", "cpu");
        fdt_prop_u32(s, "reg", i);
        fdt_prop_str(s, "status", "okay");
        fdt_prop_str(s, "compatible", "riscv");

        fdt_prop_str(s, "riscv,isa", isa_string);

        fdt_prop_str(s, "mmu-type", max_xlen <= 32 ? "riscv,sv32" : "riscv,sv48");
        fdt_prop_u32(s, "clock-frequency", 2000000000);

        fdt_begin_node(s, "interrupt-controller");
        fdt_prop_u32(s, "#interrupt-cells", 1);
        fdt_prop(s, "interrupt-controller", NULL, 0);
        fdt_prop_str(s, "compatible", "riscv,cpu-intc");
        intc_phandle[i] = cur_phandle++;
        fdt_prop_u32(s, "phandle", intc_phandle[i]);
        fdt_end_node(s); /* interrupt-controller */

        fdt_end_node(s); /* cpu */
    }

    fdt_end_node(s); /* cpus */

    fdt_begin_node_num(s, "memory", RAM_BASE_ADDR);
    fdt_prop_str(s, "device_type", "memory");
    tab[0] = (uint64_t)RAM_BASE_ADDR >> 32;
    tab[1] = RAM_BASE_ADDR;
    tab[2] = m->ram_size >> 32;
    tab[3] = m->ram_size;
    fdt_prop_tab_u32(s, "reg", tab, 4);
    
    fdt_end_node(s); /* memory */

    fdt_begin_node(s, "htif");
    fdt_prop_str(s, "compatible", "ucb,htif0");
    fdt_end_node(s); /* htif */

    fdt_begin_node(s, "soc");
    fdt_prop_u32(s, "#address-cells", 2);
    fdt_prop_u32(s, "#size-cells", 2);
    fdt_prop_tab_str(s, "compatible",
                     "ucbbar,riscvemu-bar-soc", "simple-bus", NULL);
    fdt_prop(s, "ranges", NULL, 0);

    fdt_begin_node_num(s, "clint", CLINT_BASE_ADDR);
    fdt_prop_str(s, "compatible", "riscv,clint0");

    /* FLOE-SMP: per hart: M IPI irq + M timer irq */
    for(i = 0; i < m->nb_harts; i++) {
        tab[4 * i + 0] = intc_phandle[i];
        tab[4 * i + 1] = 3; /* M IPI irq */
        tab[4 * i + 2] = intc_phandle[i];
        tab[4 * i + 3] = 7; /* M timer irq */
    }
    fdt_prop_tab_u32(s, "interrupts-extended", tab, 4 * m->nb_harts);

    fdt_prop_tab_u64_2(s, "reg", CLINT_BASE_ADDR, CLINT_SIZE);

    fdt_end_node(s); /* clint */

    fdt_begin_node_num(s, "plic", PLIC_BASE_ADDR);
    fdt_prop_u32(s, "#interrupt-cells", 1);
    fdt_prop(s, "interrupt-controller", NULL, 0);
    fdt_prop_str(s, "compatible", "riscv,plic0");
    fdt_prop_u32(s, "riscv,ndev", 31);
    fdt_prop_tab_u64_2(s, "reg", PLIC_BASE_ADDR, PLIC_SIZE);

    /* FLOE-SMP: per hart: S ext irq + M ext irq */
    for(i = 0; i < m->nb_harts; i++) {
        tab[4 * i + 0] = intc_phandle[i];
        tab[4 * i + 1] = 9; /* S ext irq */
        tab[4 * i + 2] = intc_phandle[i];
        tab[4 * i + 3] = 11; /* M ext irq */
    }
    fdt_prop_tab_u32(s, "interrupts-extended", tab, 4 * m->nb_harts);

    plic_phandle = cur_phandle++;
    fdt_prop_u32(s, "phandle", plic_phandle);

    fdt_end_node(s); /* plic */
    
    for(i = 0; i < m->virtio_count; i++) {
        fdt_begin_node_num(s, "virtio", VIRTIO_BASE_ADDR + i * VIRTIO_SIZE);
        fdt_prop_str(s, "compatible", "virtio,mmio");
        fdt_prop_tab_u64_2(s, "reg", VIRTIO_BASE_ADDR + i * VIRTIO_SIZE,
                           VIRTIO_SIZE);
        tab[0] = plic_phandle;
        tab[1] = VIRTIO_IRQ + i;
        fdt_prop_tab_u32(s, "interrupts-extended", tab, 2);
        fdt_end_node(s); /* virtio */
    }

    fb_dev = m->common.fb_dev;
    if (fb_dev) {
        fdt_begin_node_num(s, "framebuffer", FRAMEBUFFER_BASE_ADDR);
        fdt_prop_str(s, "compatible", "simple-framebuffer");
        fdt_prop_tab_u64_2(s, "reg", FRAMEBUFFER_BASE_ADDR, fb_dev->fb_size);
        fdt_prop_u32(s, "width", fb_dev->width);
        fdt_prop_u32(s, "height", fb_dev->height);
        fdt_prop_u32(s, "stride", fb_dev->stride);
        fdt_prop_str(s, "format", "a8r8g8b8");
        fdt_end_node(s); /* framebuffer */
    }
    
    fdt_end_node(s); /* soc */

    fdt_begin_node(s, "chosen");
    fdt_prop_str(s, "bootargs", cmd_line ? cmd_line : "");
    if (kernel_size > 0) {
        fdt_prop_tab_u64(s, "riscv,kernel-start", kernel_start);
        fdt_prop_tab_u64(s, "riscv,kernel-end", kernel_start + kernel_size);
    }
    if (initrd_size > 0) {
        fdt_prop_tab_u64(s, "linux,initrd-start", initrd_start);
        fdt_prop_tab_u64(s, "linux,initrd-end", initrd_start + initrd_size);
    }
    

    fdt_end_node(s); /* chosen */
    
    fdt_end_node(s); /* / */

    size = fdt_output(s, dst);
#if 0
    {
        FILE *f;
        f = fopen("/tmp/riscvemu.dtb", "wb");
        fwrite(dst, 1, size, f);
        fclose(f);
    }
#endif
    fdt_end(s);
    return size;
}

/* FLOE-EMBED: returns 0 on success, -1 on image/RAM size errors so the
   embedder gets a recoverable create failure instead of process exit.
   Also fixes upstream check-after-memcpy overflow on kernel/initrd. */
static int copy_bios(RISCVMachine *s, const uint8_t *buf, int buf_len,
                      const uint8_t *kernel_buf, int kernel_buf_len,
                      const uint8_t *initrd_buf, int initrd_buf_len,
                      const char *cmd_line)
{
    uint32_t fdt_addr, align, kernel_base, initrd_base;
    uint8_t *ram_ptr;
    uint32_t *q;

    if (buf_len > s->ram_size) {
        vm_error("BIOS too big\n");
        return -1;
    }

    ram_ptr = get_ram_ptr(s, RAM_BASE_ADDR, TRUE);
    memcpy(ram_ptr, buf, buf_len);

    kernel_base = 0;
    if (kernel_buf_len > 0) {
        /* copy the kernel if present */
        if (s->max_xlen == 32)
            align = 4 << 20; /* 4 MB page align */
        else
            align = 2 << 20; /* 2 MB page align */
        kernel_base = (buf_len + align - 1) & ~(align - 1);
        if (kernel_buf_len + kernel_base > s->ram_size) {
            vm_error("kernel too big");
            return -1;
        }
        memcpy(ram_ptr + kernel_base, kernel_buf, kernel_buf_len);
    }

    initrd_base = 0;
    if (initrd_buf_len > 0) {
        /* same allocation as QEMU */
        initrd_base = s->ram_size / 2;
        if (initrd_base > (128 << 20))
            initrd_base = 128 << 20;
        if (initrd_buf_len + initrd_base > s->ram_size) {
            vm_error("initrd too big");
            return -1;
        }
        memcpy(ram_ptr + initrd_base, initrd_buf, initrd_buf_len);
    }
    
    ram_ptr = get_ram_ptr(s, 0, TRUE);
    
    fdt_addr = 0x1000 + 8 * 8;

    riscv_build_fdt(s, ram_ptr + fdt_addr,
                    RAM_BASE_ADDR + kernel_base, kernel_buf_len,
                    RAM_BASE_ADDR + initrd_base, initrd_buf_len,
                    cmd_line);

    /* jump_addr = 0x80000000 */
    
    q = (uint32_t *)(ram_ptr + 0x1000);
    q[0] = 0x297 + 0x80000000 - 0x1000; /* auipc t0, jump_addr */
    q[1] = 0x597; /* auipc a1, dtb */
    q[2] = 0x58593 + ((fdt_addr - 4) << 20); /* addi a1, a1, dtb */
    q[3] = 0xf1402573; /* csrr a0, mhartid */
    q[4] = 0x00028067; /* jalr zero, t0, jump_addr */
    return 0; /* FLOE-EMBED: success */
}

static void riscv_flush_tlb_write_range(void *opaque, uint8_t *ram_addr,
                                        size_t ram_size)
{
    /* FLOE-SMP: the write TLBs of every hart cache this RAM range. */
    RISCVMachine *s = opaque;
    int i;
    for(i = 0; i < s->nb_harts; i++)
        riscv_cpu_flush_tlb_write_range_ram(s->cpus[i], ram_addr, ram_size);
}

static void riscv_machine_set_defaults(VirtMachineParams *p)
{
}

/* FLOE-SMP: end every created hart and destroy the machine locks.
 * Used by the init failure paths and by riscv_machine_end (the embedder
 * has already joined its hart threads before calling virt_machine_end). */
static void riscv_machine_release_cpus(RISCVMachine *s)
{
    int i;
    for(i = 0; i < s->nb_harts; i++) {
        if (s->cpus[i]) {
            riscv_cpu_end(s->cpus[i]);
            s->cpus[i] = NULL;
        }
    }
    pthread_mutex_destroy(&s->smp_device_lock);
}

static VirtMachine *riscv_machine_init(const VirtMachineParams *p)
{
    RISCVMachine *s;
    VIRTIODevice *blk_dev;
    int irq_num, i, max_xlen, ram_flags;
    VIRTIOBusDef vbus_s, *vbus = &vbus_s;


    if (!strcmp(p->machine_name, "riscv32")) {
        max_xlen = 32;
    } else if (!strcmp(p->machine_name, "riscv64")) {
        max_xlen = 64;
    } else if (!strcmp(p->machine_name, "riscv128")) {
        max_xlen = 128;
    } else {
        vm_error("unsupported machine: %s\n", p->machine_name);
        return NULL;
    }
    
    s = mallocz(sizeof(*s));
    s->common.vmc = p->vmc;
    s->ram_size = p->ram_size;
    s->max_xlen = max_xlen;
    s->mem_map = phys_mem_map_init();
    /* needed to handle the RAM dirty bits */
    s->mem_map->opaque = s;
    s->mem_map->flush_tlb_write_range = riscv_flush_tlb_write_range;

    /* FLOE-SMP: create one CPU state per hart (0/1 vcpu_count = single
       hart, the default and bit-compatible behavior). Every hart shares
       mem_map (RAM + devices) and the machine SMP block; hart i gets
       mhartid == i so the reset ROM's a0 handshake works unchanged. */
    {
        int nb_harts = p->vcpu_count;
        if (nb_harts <= 0)
            nb_harts = 1;
        if (nb_harts > RISCV_SMP_MAX_HARTS)
            nb_harts = RISCV_SMP_MAX_HARTS;
        s->nb_harts = nb_harts;
    }
    s->smp_atomic_lock = 0;
    pthread_mutex_init(&s->smp_device_lock, NULL);
    s->smp.nb_harts = s->nb_harts;
    s->smp.atomic_lock = &s->smp_atomic_lock;
    s->smp.device_lock = &s->smp_device_lock;
    for(i = 0; i < s->nb_harts; i++) {
        s->cpus[i] = riscv_cpu_init(s->mem_map, max_xlen);
        if (!s->cpus[i]) {
            vm_error("unsupported max_xlen=%d\n", max_xlen);
            while (--i >= 0)
                riscv_cpu_end(s->cpus[i]);
            pthread_mutex_destroy(&s->smp_device_lock);
            phys_mem_map_end(s->mem_map);
            free(s);
            return NULL;
        }
        riscv_cpu_set_mhartid(s->cpus[i], i);
        riscv_cpu_smp_attach(s->cpus[i], &s->smp);
        s->smp.cpus[i] = s->cpus[i];
    }
    s->cpu_state = s->cpus[0];
    /* RAM */
    ram_flags = 0;
    /* FLOE-EMBED: cpu_register_ram returns NULL on allocation failure
       (see iomem.c floe_ram_oom); report and release the partial machine
       so the embedder gets a recoverable create error. */
    if (!cpu_register_ram(s->mem_map, RAM_BASE_ADDR, p->ram_size, ram_flags) ||
        !cpu_register_ram(s->mem_map, 0x00000000, LOW_RAM_SIZE, 0)) {
        vm_error("floe: could not allocate guest RAM (%llu MB)\n",
                 (unsigned long long)(p->ram_size >> 20));
        riscv_machine_release_cpus(s);
        phys_mem_map_end(s->mem_map);
        free(s);
        return NULL;
    }
    s->rtc_real_time = p->rtc_real_time;
    if (p->rtc_real_time) {
        s->rtc_start_time = rtc_get_real_time(s);
    }
    
    cpu_register_device(s->mem_map, CLINT_BASE_ADDR, CLINT_SIZE, s,
                        clint_read, clint_write, DEVIO_SIZE32);
    cpu_register_device(s->mem_map, PLIC_BASE_ADDR, PLIC_SIZE, s,
                        plic_read, plic_write, DEVIO_SIZE32);
    for(i = 1; i < 32; i++) {
        irq_init(&s->plic_irq[i], plic_set_irq, s, i);
    }

    cpu_register_device(s->mem_map, HTIF_BASE_ADDR, 16,
                        s, htif_read, htif_write, DEVIO_SIZE32);
    s->common.console = p->console;

    memset(vbus, 0, sizeof(*vbus));
    vbus->mem_map = s->mem_map;
    vbus->addr = VIRTIO_BASE_ADDR;
    irq_num = VIRTIO_IRQ;
    
    /* virtio console */
    if (p->console) {
        vbus->irq = &s->plic_irq[irq_num];
        s->common.console_dev = virtio_console_init(vbus, p->console);
        vbus->addr += VIRTIO_SIZE;
        irq_num++;
        s->virtio_count++;
    }
    
    /* virtio net device */
    for(i = 0; i < p->eth_count; i++) {
        vbus->irq = &s->plic_irq[irq_num];
        virtio_net_init(vbus, p->tab_eth[i].net);
        s->common.net = p->tab_eth[i].net;
        vbus->addr += VIRTIO_SIZE;
        irq_num++;
        s->virtio_count++;
    }

    /* virtio block device */
    for(i = 0; i < p->drive_count; i++) {
        vbus->irq = &s->plic_irq[irq_num];
        blk_dev = virtio_block_init(vbus, p->tab_drive[i].block_dev);
        (void)blk_dev;
        vbus->addr += VIRTIO_SIZE;
        irq_num++;
        s->virtio_count++;
    }

    /* virtio filesystem */
    for(i = 0; i < p->fs_count; i++) {
        VIRTIODevice *fs_dev;
        vbus->irq = &s->plic_irq[irq_num];
        fs_dev = virtio_9p_init(vbus, p->tab_fs[i].fs_dev,
                                p->tab_fs[i].tag);
        (void)fs_dev;
        //        virtio_set_debug(fs_dev, VIRTIO_DEBUG_9P);
        vbus->addr += VIRTIO_SIZE;
        irq_num++;
        s->virtio_count++;
    }

    if (p->display_device) {
        FBDevice *fb_dev;
        fb_dev = mallocz(sizeof(*fb_dev));
        s->common.fb_dev = fb_dev;
        if (!strcmp(p->display_device, "simplefb")) {
            simplefb_init(s->mem_map,
                          FRAMEBUFFER_BASE_ADDR,
                          fb_dev,
                          p->width, p->height);
            
        } else {
            vm_error("unsupported display device: %s\n", p->display_device);
            exit(1);
        }
    }

    if (p->input_device) {
        if (!strcmp(p->input_device, "virtio")) {
            vbus->irq = &s->plic_irq[irq_num];
            s->keyboard_dev = virtio_input_init(vbus,
                                                VIRTIO_INPUT_TYPE_KEYBOARD);
            vbus->addr += VIRTIO_SIZE;
            irq_num++;
            s->virtio_count++;

            vbus->irq = &s->plic_irq[irq_num];
            s->mouse_dev = virtio_input_init(vbus,
                                             VIRTIO_INPUT_TYPE_TABLET);
            vbus->addr += VIRTIO_SIZE;
            irq_num++;
            s->virtio_count++;
        } else {
            vm_error("unsupported input device: %s\n", p->input_device);
            exit(1);
        }
    }
    
    if (!p->files[VM_FILE_BIOS].buf) {
        vm_error("No bios found");
    }

    /* FLOE-EMBED: propagate copy_bios failure; release the partial machine.
       Note: virtio device structs registered above are not individually
       freed (upstream has no virtio_device_end) -- a few hundred bytes. */
    if (copy_bios(s, p->files[VM_FILE_BIOS].buf, p->files[VM_FILE_BIOS].len,
                  p->files[VM_FILE_KERNEL].buf, p->files[VM_FILE_KERNEL].len,
                  p->files[VM_FILE_INITRD].buf, p->files[VM_FILE_INITRD].len,
                  p->cmdline) < 0) {
        riscv_machine_release_cpus(s);
        phys_mem_map_end(s->mem_map);
        free(s);
        return NULL;
    }

    return (VirtMachine *)s;
}

/* FLOE-EMBED: public accessor for the embeddable adapter (floe_vm.c). */
int riscv_machine_poweroff_requested(VirtMachine *s1)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    return __atomic_load_n(&s->poweroff_requested, __ATOMIC_SEQ_CST);
}

static void riscv_machine_end(VirtMachine *s1)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    /* FLOE-SMP: the embedder joined all hart threads before ending the
       machine (adapter destroy order: stop+join harts, then end). */
    riscv_machine_release_cpus(s);
    phys_mem_map_end(s->mem_map);
    free(s);
}

/* in ms */
static int riscv_machine_get_sleep_duration(VirtMachine *s1, int delay)
{
    RISCVMachine *m = (RISCVMachine *)s1;
    int64_t delay1, now;
    int i;

    /* wait for an event: the only asynchronous event is the RTC timer.
       FLOE-SMP: the sleep delay is the minimum over all harts -- a hart
       with a due timer or an active (non-WFI) hart forces delay 0. */
    now = rtc_get_time(m);
    for(i = 0; i < m->nb_harts; i++) {
        RISCVCPUState *s = m->cpus[i];
        if (!(riscv_cpu_get_mip(s) & MIP_MTIP)) {
            delay1 = m->timecmp[i] - now;
            if (delay1 <= 0) {
                riscv_cpu_set_mip(s, MIP_MTIP);
                delay = 0;
            } else {
                /* convert delay to ms */
                delay1 = delay1 / (RTC_FREQ / 1000);
                if (delay1 < delay)
                    delay = delay1;
            }
        }
        if (!riscv_cpu_get_power_down(s))
            delay = 0;
    }
    return delay;
}

static void riscv_machine_interp(VirtMachine *s1, int max_exec_cycle)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    riscv_cpu_interp(s->cpu_state, max_exec_cycle);
}

/* FLOE-SMP: per-hart hooks for the embedder's hart host threads. */
static int riscv_machine_get_cpu_count(VirtMachine *s1)
{
    return ((RISCVMachine *)s1)->nb_harts;
}

static RISCVCPUState *riscv_machine_get_cpu(VirtMachine *s1, int cpu_idx)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    if (cpu_idx < 0 || cpu_idx >= s->nb_harts)
        return NULL;
    return s->cpus[cpu_idx];
}

static void riscv_machine_interp_cpu(VirtMachine *s1, int cpu_idx,
                                     int max_exec_cycle)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    if (cpu_idx >= 0 && cpu_idx < s->nb_harts)
        riscv_cpu_interp(s->cpus[cpu_idx], max_exec_cycle);
}

static void riscv_vm_send_key_event(VirtMachine *s1, BOOL is_down,
                                    uint16_t key_code)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    if (s->keyboard_dev) {
        virtio_input_send_key_event(s->keyboard_dev, is_down, key_code);
    }
}

static BOOL riscv_vm_mouse_is_absolute(VirtMachine *s)
{
    return TRUE;
}

static void riscv_vm_send_mouse_event(VirtMachine *s1, int dx, int dy, int dz,
                                      unsigned int buttons)
{
    RISCVMachine *s = (RISCVMachine *)s1;
    if (s->mouse_dev) {
        virtio_input_send_mouse_event(s->mouse_dev, dx, dy, dz, buttons);
    }
}

/* FLOE-SMP: diagnostic counters read by the host tests through the
 * adapter (written by smp_note_device_lock / riscv_smp_pte_write_bits). */
static void riscv_machine_get_smp_diag(VirtMachine *s,
                                       uint64_t *lock_order_violations,
                                       uint64_t *pte_ad_updates,
                                       uint64_t *pte_ad_merges,
                                       uint64_t *pte_ad_conflicts,
                                       uint64_t *pte_walk_restarts)
{
    RISCVMachine *m = (RISCVMachine *)s;
    *lock_order_violations =
        __atomic_load_n(&m->smp.lock_order_violations, __ATOMIC_RELAXED);
    *pte_ad_updates =
        __atomic_load_n(&m->smp.pte_ad_updates, __ATOMIC_RELAXED);
    *pte_ad_merges =
        __atomic_load_n(&m->smp.pte_ad_merges, __ATOMIC_RELAXED);
    *pte_ad_conflicts =
        __atomic_load_n(&m->smp.pte_ad_conflicts, __ATOMIC_RELAXED);
    *pte_walk_restarts =
        __atomic_load_n(&m->smp.pte_walk_restarts, __ATOMIC_RELAXED);
}

const VirtMachineClass riscv_machine_class = {
    "riscv32,riscv64,riscv128",
    riscv_machine_set_defaults,
    riscv_machine_init,
    riscv_machine_end,
    riscv_machine_get_sleep_duration,
    riscv_machine_interp,
    riscv_vm_mouse_is_absolute,
    riscv_vm_send_mouse_event,
    riscv_vm_send_key_event,
    riscv_machine_get_cpu_count,
    riscv_machine_get_cpu,
    riscv_machine_interp_cpu,
    riscv_machine_get_smp_diag,
};

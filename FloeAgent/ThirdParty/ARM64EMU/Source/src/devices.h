/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Platform device interfaces (QEMU 'virt', GICv2). */
#ifndef A64_DEVICES_H
#define A64_DEVICES_H

#include "types.h"
#include "machine.h"

/* virt memory map */
#define GICD_BASE   0x08000000ULL
#define GICC_BASE   0x08010000ULL
#define UART_BASE   0x09000000ULL
#define RTC_BASE    0x09010000ULL
#define FWCFG_BASE  0x09020000ULL

/* Interrupt IDs (GIC INTIDs). SPIs = 32 + DTB-spi-number. */
#define INTID_TIMER_VIRT 27   /* PPI 11 */
#define INTID_TIMER_PHYS 30   /* PPI 14 (NS EL1 physical timer) */
#define INTID_UART       33   /* SPI 1  */
#define INTID_RTC        34   /* SPI 2  */
#define INTID_VIRTIO0    48   /* SPI 16 (virtio-mmio slot 0) */
#define INTID_VIRTIO1    49   /* SPI 17 (virtio-mmio slot 1) */

/* ---- GICv2 ---- */
#define GIC_NUM_IRQS 256
_Static_assert(A64_MAX_CPUS<=8,"GICv2 SGI sources and IRQ targets have eight PE bits");
typedef struct GIC {
    Machine *m;
    u32 d_ctlr;
    struct GICBank {
        u32 ctlr;u8 pmr,bpr;
        bool enabled[32],pending[32],software[32],active[32],dropped[32],line[32],edge[32];
        u8 priority[32],sgi_pending[16],sgi_source[16];
        u64 acknowledged,sgi_acknowledged;
    } bank[A64_MAX_CPUS];
    bool enabled[GIC_NUM_IRQS];
    bool pending[GIC_NUM_IRQS];
    bool software[GIC_NUM_IRQS];
    bool active[GIC_NUM_IRQS];
    bool dropped[GIC_NUM_IRQS];
    s8 active_owner[GIC_NUM_IRQS],route_after[GIC_NUM_IRQS];
    bool line[GIC_NUM_IRQS];
    bool cfg_edge[GIC_NUM_IRQS];
    u8   priority[GIC_NUM_IRQS];
    u8   target[GIC_NUM_IRQS];
} GIC;

GIC *gic_create(Machine *m);
void gic_reset(GIC *g);           /* system reset: clear all interrupt state */
void gic_set_irq(GIC *g, int intid, int level);
void gic_set_ppi(GIC *g,unsigned hart,int intid,int level);
void gic_cpu_reset(GIC *g,unsigned hart);
void gic_update(GIC *g);

/* ---- generic timer ---- */
typedef struct ARMTimer {
    Machine *m;CPU *cpu; GIC *gic;
    u64 deadline;   /* cached next-fire count (phys domain), ~0 = none armed */
    u64 secondary_deadline[A64_MAX_CPUS-1];
} ARMTimer;
ARMTimer *gtimer_create(Machine *m);
u64 gt_count(CPU *c,bool virt);
void timer_update(Machine *m);
void timer_update_cpu(CPU *c);
void timer_check(Machine *m);   /* per-tick: one compare, full update when due */
u64  timer_next_deadline_ns(Machine *m);     /* host-ns until next fire, or ~0 */
u64  timer_next_event_ns(Machine *m);        /* next transition; no steady-level poll */
u64  timer_next_deadline_ticks(Machine *m);  /* instructions until next fire, or ~0 */

/* ---- PL011 UART ---- */
typedef struct PL011 {
    Machine *m;                    /* for the input-follows-output active flag */
    GIC *gic;
    ConsoleEP *ep;                 /* host endpoint this UART speaks through */
    u32 imsc, ris;
    u8  rx_fifo[64]; int rx_head, rx_tail;
    u32 cr, lcr_h, ibrd, fbrd, ifls;
} PL011;
PL011 *pl011_create(Machine *m, GIC *gic);
void pl011_reset(PL011 *p);       /* system reset: clear FIFO/masks/interrupt */
void pl011_rx_poll(Machine *m);   /* feed host input into RX FIFO, drain output */
bool pl011_is_stdio(PL011 *p);    /* on the shared process terminal? */

/* ---- PL031 RTC ---- */
typedef struct PL031 { GIC *gic; u32 mr, lr, cr, imsc, ris; s64 tick_offset; bool armed; u8 irq_line; } PL031;
PL031 *pl031_create(Machine *m, GIC *gic);
void pl031_reset(PL031 *p);       /* system reset: clear match/control/interrupt */
void pl031_update(Machine *m);    /* per-tick: evaluate RTCMR match, drive INTID_RTC */

/* ---- fw_cfg ---- */
typedef struct FwCfg FwCfg;
FwCfg *fwcfg_create(Machine *m);
void fwcfg_reset(FwCfg *f);       /* system reset: clear the selector/DMA cursor */
void fwcfg_add_file(FwCfg *f, const char *name, const void *data, u32 len);
void fwcfg_set_legacy_kernel(FwCfg *f, const void *kernel, u32 ksize,
                             const void *initrd, u32 isize,
                             const char *cmdline);

/* ---- virtio-blk (virtio-mmio slot N) ---- */
/* slot picks the MMIO window (0x0a000000 + slot*0x200) and IRQ (INTID_VIRTIO0 + slot).
 * ro opens the image O_RDONLY and advertises VIRTIO_BLK_F_RO (guest mounts read-only). */
struct VirtIOBlk;
struct VirtIOBlk *virtio_blk_create(Machine *m, GIC *gic, const char *path, bool ro, int slot);

/* ---- virtio-net (virtio-mmio slot 0) ---- */
struct VirtIONet;
struct VirtIONet *virtio_net_create(Machine *m, GIC *gic);
void              virtio_net_poll(struct VirtIONet *v);
void              virtio_net_reset(struct VirtIONet *v);  /* system reset: quiesce queues */
void              virtio_net_destroy(struct VirtIONet *v); /* full teardown after quiet */
/* Opaque usernet backend handle for the live-management ABI operations. */
struct UserNet;
struct UserNet   *virtio_net_usernet(struct VirtIONet *);

/* ---- virtio-9p host directory share (virtio-mmio slot N) ------------------
 * Exports host directory `root` to the guest as a 9P2000.L filesystem named by
 * `tag`; `ro` makes it read-only. slot picks the MMIO window / IRQ as for blk.
 * Containment is pinned-descriptor based: attach resolves `root` once and all
 * host access stays on that root descriptor. `root` may be NULL to create a
 * DETACHED slot (the device probes but refuses fs ops with ENODEV) that the
 * host later binds with virtio_9p_attach_root() while the machine is quiet.
 * guest_uid/guest_gid are the synthetic ids stat reports to the guest; they
 * are never forwarded to a host chown. */
struct VirtIO9P;
struct VirtIO9P *virtio_9p_create(Machine *m, GIC *gic, const char *root,
                                  const char *tag, bool ro,
                                  uint32_t guest_uid, uint32_t guest_gid,
                                  int slot);
void             virtio_9p_destroy(struct VirtIO9P *);
int              virtio_9p_attach_root(struct VirtIO9P *, const char *root,
                                       uint32_t guest_uid, uint32_t guest_gid,
                                       bool ro);      /* 0, -EBUSY, -errno */
int              virtio_9p_detach_root(struct VirtIO9P *, bool force); /* 0/-EBUSY */
void             virtio_9p_get_info(struct VirtIO9P *, int *state,
                                    uint64_t *generation, uint32_t *open_handles,
                                    uint32_t *guest_uid, uint32_t *guest_gid,
                                    int *ro);
const char      *virtio_9p_slot_tag(struct VirtIO9P *, uint16_t *tag_len);

/* ---- virtio-console (virtio-mmio slot N) ---- */
/* Non-multiport console (DeviceID 3) advertising VIRTIO_CONSOLE_F_SIZE: the
 * guest terminal's geometry tracks its host endpoint (initial size + live
 * resize). slot picks the MMIO window / IRQ as for blk. Each device is one more
 * guest tty, numbered in creation order: the first is hvc0, the next hvc1, and
 * so on, and each takes the endpoint bound for that index (m->vcon_ep). Poll is
 * called from machine_tick to feed host input and re-read the geometry; reset
 * quiesces the background-polled queues on warm reboot. vcon_driver_ok gates the
 * machine_tick input handover (input stays on PL011 until the driver is up). */
struct VirtIOConsole;
struct VirtIOConsole *virtio_console_create(Machine *m, GIC *gic, int slot);
void                  virtio_console_poll(struct VirtIOConsole *v);
void                  virtio_console_reset(struct VirtIOConsole *v);
bool                  vcon_driver_ok(struct VirtIOConsole *v);
bool                  vcon_is_stdio(struct VirtIOConsole *v);  /* shared terminal? */

bool fwcfg_has_work(FwCfg *); void fwcfg_service(FwCfg *,u32);
bool virtio_blk_has_work(struct VirtIOBlk *); void virtio_blk_service(struct VirtIOBlk *);
/* Typed ownership for the embedded profile. */
void gic_destroy(GIC *); void gtimer_destroy(ARMTimer *);
bool smccc_conduit(CPU *c,bool is_hvc);
void pl011_destroy(PL011 *); void pl031_destroy(PL031 *);
void fwcfg_destroy(FwCfg *); bool fwcfg_valid(FwCfg *);
void virtio_blk_destroy(struct VirtIOBlk *);
void virtio_console_destroy(struct VirtIOConsole *);
#endif /* A64_DEVICES_H */

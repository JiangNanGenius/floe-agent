/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* virtio-console over modern (version 2) virtio-mmio transport.
 *
 * DeviceID 3, non-multiport (we do NOT advertise VIRTIO_CONSOLE_F_MULTIPORT),
 * so exactly two virtqueues and no control-queue handshake:
 *   queue 0 (RX): guest posts free buffers; we fill them with host keystrokes.
 *   queue 1 (TX): guest posts console output; we write it to host stdout.
 *
 * We advertise VIRTIO_CONSOLE_F_SIZE: config space carries cols/rows, and a
 * config-change interrupt (ISR bit 1) is raised whenever the host terminal is
 * resized. Linux's virtio_console driver then resizes the hvc0 tty and delivers
 * SIGWINCH to the foreground process, so the guest's idea of terminal size
 * follows the host window with no `resize` needed.
 *
 * Processing mirrors virtio-net: TX is handled synchronously on QueueNotify;
 * host input and winsize changes are injected during virtio_console_poll(),
 * called from machine_tick() once the guest driver owns the console.
 *
 * The RX-delivery path is the bug-fixed version of virtio-net's net_flush_rx:
 * the descriptor-chain walk is bounded, read-only descriptors are skipped, and
 * the used ring reports the bytes actually written (see TODO_BUGS §3.1/§3.2). */
#include "../devices.h"
#include "../console.h"
#include <stdlib.h>
#include <stdio.h>

/* Feature bits. VIRTIO_F_VERSION_1 is mandatory for a modern (version-2
 * transport) device; F_SIZE makes the driver honour the cols/rows in config. */
#define VIRTIO_F_VERSION_1     (1ULL << 32)
#define VIRTIO_CONSOLE_F_SIZE  (1ULL << 0)
#define CON_FEATURES           (VIRTIO_F_VERSION_1 | VIRTIO_CONSOLE_F_SIZE)

/* Split-virtqueue descriptor flags. */
#define VIRTQ_DESC_F_NEXT   1
#define VIRTQ_DESC_F_WRITE  2

#define QUEUE_NUM_MAX 256

#define CON_QUEUE_RX  0
#define CON_QUEUE_TX  1

#define VIRTIO_STATUS_DRIVER_OK 4    /* guest driver fully initialised */

/* Host-input FIFO: keystrokes buffered until the guest posts RX buffers. */
#define RX_FIFO_SIZE 1024

typedef struct VirtIOConsole {
    Machine *m; GIC *gic; int irq;
    ConsoleEP *ep;                   /* host endpoint this console speaks through */
    int index;                       /* which guest tty: 0 = hvc0, 1 = hvc1, ... */

    uint16_t cols, rows;             /* config-space geometry (0 = unknown) */
    uint32_t status, isr;
    uint32_t dev_feat_sel, drv_feat_sel; uint64_t drv_feat;
    uint32_t queue_sel;

    uint32_t q_num[2], q_ready[2];
    uint64_t q_desc[2], q_avail[2], q_used[2];
    uint16_t last_avail[2];

    uint8_t  rx_fifo[RX_FIFO_SIZE];
    int      rx_head, rx_tail;       /* circular; head == tail => empty */
    bool     size_synced;            /* fired the initial config-change IRQ yet? */
} VirtIOConsole;

/* ---- helpers ---- */

/* Refresh cols/rows from the host endpoint; returns true if they changed. */
static bool con_update_winsize(VirtIOConsole *v) {
    u16 c = 0, r = 0;
    console_get_winsize(v->ep, &c, &r);
    if (c == v->cols && r == v->rows) return false;
    v->cols = c; v->rows = r;
    return true;
}

static void con_reset(VirtIOConsole *v) {
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0;
    for (int q = 0; q < 2; q++) {
        v->q_num[q] = v->q_ready[q] = 0;
        v->q_desc[q] = v->q_avail[q] = v->q_used[q] = 0;
        v->last_avail[q] = 0;
    }
    v->rx_head = v->rx_tail = 0;      /* drop type-ahead queued for the old driver */
    v->size_synced = false;
    con_update_winsize(v);           /* a warm reboot starts with the current size */
    gic_set_irq(v->gic, v->irq, 0);
}

/* Apply the initial hvc0 window size. The non-multiport virtio_console driver
 * only picks up cols/rows from config on a config-change interrupt (and on some
 * kernels not at all until one arrives), so once the driver and its console port
 * are up (DRIVER_OK + RX queue ready) we raise exactly one config-change IRQ with
 * a fresh winsize. Idempotent (guarded by size_synced). */
static void con_sync_size(VirtIOConsole *v) {
    if (v->size_synced) return;
    if (!(v->status & VIRTIO_STATUS_DRIVER_OK) || !v->q_ready[CON_QUEUE_RX]) return;
    v->size_synced = true;
    con_update_winsize(v);
    v->isr |= 2;                      /* VIRTIO_MMIO_INT_CONFIG */
    gic_set_irq(v->gic, v->irq, 1);
    if (getenv("AEVCON"))
        fprintf(stderr, "[vcon] hvc%d initial size sync: %ux%u\n",
                v->index, v->cols, v->rows);
}

/* System-reset entry point: identical to a guest-driven STATUS=0 device reset.
 * Called explicitly on reboot because virtio-console is background-polled, so
 * its queues must be quiesced before the rebooting firmware reuses guest RAM. */
void virtio_console_reset(VirtIOConsole *v) { con_reset(v); }

static void push_used(VirtIOConsole *v, int q, uint16_t id, uint32_t len) {
    Machine *m = v->m;
    uint16_t ui = (uint16_t)phys_read(m, v->q_used[q] + 2, 2);
    uint64_t e  = v->q_used[q] + 4 + (uint64_t)(ui % v->q_num[q]) * 8;
    phys_write(m, e + 0, 4, id);
    phys_write(m, e + 4, 4, len);
    phys_write(m, v->q_used[q] + 2, 2, (uint16_t)(ui + 1));
}

/* ---- RX FIFO ---- */

static bool rx_fifo_empty(VirtIOConsole *v) { return v->rx_head == v->rx_tail; }
static bool rx_fifo_full(VirtIOConsole *v)  {
    return ((v->rx_tail + 1) % RX_FIFO_SIZE) == v->rx_head;
}
static void rx_fifo_push(VirtIOConsole *v, uint8_t ch) {
    if (rx_fifo_full(v)) return;     /* full: drop; backpressure handled by caller */
    v->rx_fifo[v->rx_tail] = ch;
    v->rx_tail = (v->rx_tail + 1) % RX_FIFO_SIZE;
}

/* ---- RX: deliver buffered host input into guest RX buffers ---- */

static void con_flush_rx(VirtIOConsole *v) {
    Machine *m = v->m;
    if (!v->q_ready[CON_QUEUE_RX] || v->q_num[CON_QUEUE_RX] == 0) return;
    bool did = false;

    while (!rx_fifo_empty(v)) {
        uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[CON_QUEUE_RX] + 2, 2);
        if (v->last_avail[CON_QUEUE_RX] == avail_idx) break; /* no free guest buffers */

        uint16_t q_num = (uint16_t)v->q_num[CON_QUEUE_RX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[CON_QUEUE_RX] + 4 +
            (uint64_t)(v->last_avail[CON_QUEUE_RX] % q_num) * 2, 2);
        v->last_avail[CON_QUEUE_RX]++;

        /* Copy as many FIFO bytes as fit into this chain's writable buffers.
         * The chain walk is bounded by q_num and skips read-only descriptors —
         * fixing the two virtio-net RX defects (TODO_BUGS §3.1/§3.2). */
        uint32_t written = 0;
        uint32_t n = 0, idx = hd;
        for (;;) {
            if (n >= q_num) break;
            uint64_t d    = v->q_desc[CON_QUEUE_RX] + (uint64_t)idx * 16;
            uint64_t gpa  = phys_read(m, d + 0, 8);
            uint32_t dlen = (uint32_t)phys_read(m, d + 8, 4);
            uint16_t df   = (uint16_t)phys_read(m, d + 12, 2);
            uint16_t next = (uint16_t)phys_read(m, d + 14, 2);
            n++;

            if (df & VIRTQ_DESC_F_WRITE) {
                uint32_t off = 0;
                while (off < dlen && !rx_fifo_empty(v)) {
                    /* One contiguous run out of the ring (up to the wrap point). */
                    uint32_t run = (v->rx_tail >= v->rx_head)
                        ? (uint32_t)(v->rx_tail - v->rx_head)
                        : (uint32_t)(RX_FIFO_SIZE - v->rx_head);
                    uint32_t c = dlen - off;
                    if (c > run) c = run;
                    phys_write_blk(m, gpa + off, &v->rx_fifo[v->rx_head], c);
                    v->rx_head = (v->rx_head + (int)c) % RX_FIFO_SIZE;
                    off += c;
                    written += c;
                }
            }
            if (!(df & VIRTQ_DESC_F_NEXT) || rx_fifo_empty(v)) break;
            idx = next;
        }

        push_used(v, CON_QUEUE_RX, hd, written);   /* report bytes actually written */
        did = true;
    }

    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- TX: drain guest console output to host stdout ---- */

static void con_tx_process(VirtIOConsole *v) {
    Machine *m = v->m;
    if (!v->q_ready[CON_QUEUE_TX] || v->q_num[CON_QUEUE_TX] == 0) return;

    uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[CON_QUEUE_TX] + 2, 2);
    bool did = false;

    while (v->last_avail[CON_QUEUE_TX] != avail_idx) {
        uint16_t q_num = (uint16_t)v->q_num[CON_QUEUE_TX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[CON_QUEUE_TX] + 4 +
            (uint64_t)(v->last_avail[CON_QUEUE_TX] % q_num) * 2, 2);
        v->last_avail[CON_QUEUE_TX]++;

        /* Console TX is a byte stream (no atomic-frame requirement like net),
         * so write each readable descriptor straight to stdout — no payload
         * size cap and nothing dropped. Chain walk bounded by q_num. */
        uint32_t n = 0, idx = hd;
        for (;;) {
            if (n >= q_num) break;
            uint64_t d    = v->q_desc[CON_QUEUE_TX] + (uint64_t)idx * 16;
            uint64_t gpa  = phys_read(m, d + 0, 8);
            uint32_t dlen = (uint32_t)phys_read(m, d + 8, 4);
            uint16_t df   = (uint16_t)phys_read(m, d + 12, 2);
            uint16_t next = (uint16_t)phys_read(m, d + 14, 2);
            uint32_t off = 0;
            while (off < dlen) {
                uint8_t chunk[512];
                uint32_t c = dlen - off;
                if (c > sizeof(chunk)) c = sizeof(chunk);
                phys_read_blk(m, gpa + off, chunk, c);
                console_write(v->ep, chunk, c);
                off += c;
            }
            n++;
            if (!(df & VIRTQ_DESC_F_NEXT)) break;
            idx = next;
        }

        push_used(v, CON_QUEUE_TX, hd, 0);
        did = true;
    }

    if (did) {
        /* The guest is writing its console output here -> host input should
         * follow it (rather than going to ttyAMA0). Only meaningful while this
         * console shares the process terminal with the UART: an endpoint of its
         * own has nothing to arbitrate. See machine_tick. */
        if (console_is_stdio(v->ep)) v->m->console_active_virtio = true;
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- background poll (machine_tick): host input + winsize ---- */

void virtio_console_poll(VirtIOConsole *v) {
    con_sync_size(v);                          /* apply the initial size once */
    console_flush(v->ep);                      /* retry output the peer stalled on */

    /* Host terminal resized? Update config geometry and raise a config-change
     * interrupt (ISR bit 1) so the guest re-reads config, resizes the tty, and
     * delivers SIGWINCH to the foreground process. */
    if (console_take_winch(v->ep) && con_update_winsize(v)) {
        v->isr |= 2;                           /* VIRTIO_MMIO_INT_CONFIG */
        gic_set_irq(v->gic, v->irq, 1);
    }

    /* Pull host keystrokes into the FIFO while there's room. Checking room
     * before reading leaves surplus bytes in the host tty buffer (flow
     * control) rather than reading-then-dropping — same contract as PL011. */
    int ch;
    while (!rx_fifo_full(v) && (ch = console_getchar(v->ep)) >= 0)
        rx_fifo_push(v, (uint8_t)ch);

    con_flush_rx(v);
}

bool vcon_driver_ok(VirtIOConsole *v) {
    return (v->status & VIRTIO_STATUS_DRIVER_OK) && v->q_ready[CON_QUEUE_RX];
}

/* True while this console is on the shared process terminal (see machine_tick). */
bool vcon_is_stdio(VirtIOConsole *v) { return v && console_is_stdio(v->ep); }

/* ---- MMIO ---- */

static u64 con_config_read(VirtIOConsole *v, u64 off, unsigned size) {
    /* struct virtio_console_config: cols@0 (u16), rows@2 (u16),
     * max_nr_ports@4 (u32), emerg_wr@8 (u32). */
    uint8_t cfg[12];
    cfg[0] = (uint8_t)(v->cols & 0xff);
    cfg[1] = (uint8_t)((v->cols >> 8) & 0xff);
    cfg[2] = (uint8_t)(v->rows & 0xff);
    cfg[3] = (uint8_t)((v->rows >> 8) & 0xff);
    cfg[4] = 1; cfg[5] = 0; cfg[6] = 0; cfg[7] = 0;   /* max_nr_ports = 1 */
    cfg[8] = 0; cfg[9] = 0; cfg[10] = 0; cfg[11] = 0; /* emerg_wr = 0 (no F_EMERG_WRITE) */
    u64 r = 0;
    for (unsigned i = 0; i < size && off + i < sizeof(cfg); i++)
        r |= (u64)cfg[off + i] << (i * 8);
    return r;
}

static u64 con_read(void *opaque, u64 off, unsigned size) {
    VirtIOConsole *v = opaque;
    if (off >= 0x100) return con_config_read(v, off - 0x100, size);
    int q = (int)v->queue_sel;
    switch (off) {
        case 0x000: return 0x74726976;       /* MagicValue "virt"  */
        case 0x004: return 2;                /* Version (modern)   */
        case 0x008: return 3;                /* DeviceID = console */
        case 0x00c: return 0x554d4551;       /* VendorID "QEMU"    */
        case 0x010:
            return v->dev_feat_sel == 1 ? (u32)(CON_FEATURES >> 32)
                                        : (u32)(CON_FEATURES & 0xffffffff);
        case 0x034: return (q == 0 || q == 1) ? QUEUE_NUM_MAX : 0; /* QueueNumMax */
        case 0x044: return (q == 0 || q == 1) ? v->q_ready[q] : 0; /* QueueReady  */
        case 0x060: return v->isr;           /* InterruptStatus    */
        case 0x070: return v->status;        /* Status             */
        case 0x0fc: return 0;                /* ConfigGeneration   */
        default:    return 0;
    }
}

static void con_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIOConsole *v = opaque;
    u32 v32 = (u32)val;
    int q = (int)v->queue_sel;
    switch (off) {
        case 0x014: v->dev_feat_sel = v32; break;
        case 0x020:
            if (v->drv_feat_sel == 1) v->drv_feat = (v->drv_feat & 0xffffffffULL) | ((u64)v32 << 32);
            else                      v->drv_feat = (v->drv_feat & ~0xffffffffULL) | v32;
            break;
        case 0x024: v->drv_feat_sel = v32; break;
        case 0x030: v->queue_sel = v32; break;
        case 0x038:
            if (q == 0 || q == 1)
                v->q_num[q] = v32 > QUEUE_NUM_MAX ? QUEUE_NUM_MAX : v32;
            break;
        case 0x044:
            if (q == 0 || q == 1) v->q_ready[q] = v32;
            break;
        case 0x050:                                     /* QueueNotify: val = queue index */
            if (v32 == CON_QUEUE_TX) con_tx_process(v);
            else if (v32 == CON_QUEUE_RX) {
                con_flush_rx(v);      /* guest added free buffers */
                con_sync_size(v);     /* console port is up -> apply initial size */
            }
            break;
        case 0x064:
            v->isr &= ~v32;                             /* clears bit 0 and/or bit 1 */
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:
            /* Note: DRIVER_OK is set before the driver creates the console port,
             * so the initial size sync is deferred to the first RX-queue notify
             * (con_sync_size in case 0x050) / poll, once the port exists. */
            if (v32 == 0) con_reset(v); else v->status = v32;
            break;
        /* Queue descriptor/available/used table addresses (low/high 32-bit pairs). */
        case 0x080:
            if (q == 0 || q == 1) { v->q_desc[q]  = (v->q_desc[q]  & ~0xffffffffULL) | v32; } break;
        case 0x084:
            if (q == 0 || q == 1) { v->q_desc[q]  = (v->q_desc[q]  &  0xffffffffULL) | ((u64)v32 << 32); } break;
        case 0x090:
            if (q == 0 || q == 1) { v->q_avail[q] = (v->q_avail[q] & ~0xffffffffULL) | v32; } break;
        case 0x094:
            if (q == 0 || q == 1) { v->q_avail[q] = (v->q_avail[q] &  0xffffffffULL) | ((u64)v32 << 32); } break;
        case 0x0a0:
            if (q == 0 || q == 1) { v->q_used[q]  = (v->q_used[q]  & ~0xffffffffULL) | v32; } break;
        case 0x0a4:
            if (q == 0 || q == 1) { v->q_used[q]  = (v->q_used[q]  &  0xffffffffULL) | ((u64)v32 << 32); } break;
        default: break;
    }
}

/* ---- creation ---- */

VirtIOConsole *virtio_console_create(Machine *m, GIC *gic, int slot) {
    if (m->n_vcon >= MAX_CONSOLES) return NULL;
    u64 base = 0x0a000000ULL + (u64)slot * 0x200;
    VirtIOConsole *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    /* Consoles are numbered in creation order, which is the order Linux probes
     * the virtio-mmio slots in, so device i is the guest's hvc<i>. */
    v->index = m->n_vcon;
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0 + slot;
    v->ep = m->vcon_ep[v->index] ? m->vcon_ep[v->index] : console_stdio();
    if (!v->ep) { free(v);return NULL; }

    /* Seed the initial geometry. The driver reads config after DRIVER_OK, so it
     * picks up the correct size at first login with no config interrupt. */
    con_update_winsize(v);

    machine_add_device(m, base, 0x200, con_read, con_write, v, "virtio-console");
    m->vcon[m->n_vcon++] = v;
    fprintf(stderr, "[virtio-console] slot %d: guest hvc%d, size %ux%u%s\n",
            slot, v->index, v->cols, v->rows,
            console_is_stdio(v->ep) ? " (host terminal)" : " (bound endpoint)");
    return v;
}

/* Embedded typed ownership; borrowed backpointers are not freed here. */
void virtio_console_destroy(VirtIOConsole *p) { free(p); }

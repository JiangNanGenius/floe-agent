/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* virtio-net over modern (version 2) virtio-mmio transport, slot 0 of QEMU's
 * 'virt' map (0x0a000000, INTID 48 / SPI 16, edge-triggered per the DTB).
 *
 * The backend is usernet (src/net/): a built-in user-mode TCP/IP stack that
 * NATs guest traffic through regular host sockets — no TAP, TUN, privileges,
 * or external libraries required.
 *
 * Two virtqueues:
 *   queue 0 (RX): guest posts free buffers; we fill them with incoming frames.
 *   queue 1 (TX): guest posts outgoing frames; we pass them to usernet_input().
 *
 * Processing is synchronous on the machine coordinator: TX is handled on
 * QueueNotify, RX is injected during virtio_net_poll() from machine_tick().
 * Guest-RAM DMA goes through phys_read/phys_write, which hold the A6 memory
 * guard and publish code-page epochs and exclusive-monitor invalidation
 * before every write, including the used-ring publication.
 *
 * Floe embedded restoration differences from the upstream original:
 *  - allocation failures and host-forward binding failures fail create
 *    cleanly (NULL return) instead of exit(1);
 *  - every owned descriptor (backend, flows, listeners) is released by
 *    virtio_net_destroy() after workers are quiet;
 *  - queue descriptor rings are validated against guest RAM before use.
 */
#include "../devices.h"
#include "../net/usernet.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Feature bits. VIRTIO_NET_F_MAC and F_STATUS; VIRTIO_F_VERSION_1 mandatory
 * for a modern device (version 2 transport). No offload features — simplest
 * possible path through the Linux virtio_net driver. */
#define VIRTIO_F_VERSION_1  (1ULL << 32)
#define VIRTIO_NET_F_MAC    (1ULL << 5)
#define VIRTIO_NET_F_STATUS (1ULL << 16)
#define NET_FEATURES        (VIRTIO_F_VERSION_1 | VIRTIO_NET_F_MAC | VIRTIO_NET_F_STATUS)

#define VIRTIO_NET_S_LINK_UP  1

/* virtio_net header length. The Linux virtio_net driver (and QEMU) use the
 * 12-byte struct virtio_net_hdr_mrg_rxbuf whenever VIRTIO_F_VERSION_1 OR
 * VIRTIO_NET_F_MRG_RXBUF is negotiated — the bare 10-byte struct virtio_net_hdr
 * is used only by a legacy device that negotiates neither. We are a modern
 * (version-2 transport) device that negotiates VERSION_1, so the guest prepends
 * 12 bytes on TX and expects 12 bytes on RX, even though we don't merge buffers.
 * The extra 2 bytes are num_buffers (set to 1 on RX, ignored on TX). */
#define NET_HDR_LEN   12

/* Split-virtqueue descriptor flags. */
#define VIRTQ_DESC_F_NEXT  1
#define VIRTQ_DESC_F_WRITE 2

#define QUEUE_NUM_MAX 256
#define VIRTQ_MAX     256

#define NET_QUEUE_RX  0
#define NET_QUEUE_TX  1

/* Pending RX frame ring — frames queued by the backend before the guest
 * RX queue is ready. Power-of-two so the head/tail modulo is a mask. */
#define RX_RING_SIZE  64          /* must be power of 2 */
#define MAX_ETH_FRAME 1518

typedef struct VirtIONet {
    Machine *m; GIC *gic; int irq;   /* INTID_VIRTIO0 */
    UserNet *un;

    uint8_t  mac[6];
    uint32_t status, isr;
    uint32_t dev_feat_sel, drv_feat_sel; uint64_t drv_feat;
    uint32_t queue_sel;

    uint32_t q_num[2], q_ready[2];
    uint64_t q_desc[2], q_avail[2], q_used[2];
    uint16_t last_avail[2];

    /* Pending RX frames from the backend (queued by net_deliver_frame,
     * drained into guest by net_flush_rx). */
    uint8_t  rx_buf[RX_RING_SIZE][NET_HDR_LEN + MAX_ETH_FRAME];
    uint32_t rx_len[RX_RING_SIZE];
    int      rx_head, rx_tail;
} VirtIONet;

/* ---- helpers ---- */

static void net_reset(VirtIONet *v) {
    usernet_guest_reset(v->un);
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0;
    for (int q = 0; q < 2; q++) {
        v->q_num[q] = v->q_ready[q] = 0;
        v->q_desc[q] = v->q_avail[q] = v->q_used[q] = 0;
        v->last_avail[q] = 0;
    }
    v->rx_head = v->rx_tail = 0;    /* drop frames queued for the old driver */
    gic_set_irq(v->gic, v->irq, 0);
}

/* System-reset entry point: identical to a guest-driven STATUS=0 device reset.
 * Called explicitly on reboot because virtio-net is background-polled, so its
 * queues must be quiesced before the rebooting firmware reuses guest RAM (the
 * network backend and any host port-forwards are preserved). */
void virtio_net_reset(VirtIONet *v) { net_reset(v); }

/* The queue rings must live in guest RAM; a malformed or not-yet-programmed
 * queue is a device error, not a host memory adventure. */
static bool queue_spans(VirtIONet *v, int q) {
    return v->q_num[q] && v->q_num[q] <= VIRTQ_MAX &&
        ram_ptr(v->m, v->q_desc[q], (u64)v->q_num[q] * 16) &&
        ram_ptr(v->m, v->q_avail[q], 6 + (u64)v->q_num[q] * 2) &&
        ram_ptr(v->m, v->q_used[q], 6 + (u64)v->q_num[q] * 8);
}

static void push_used(VirtIONet *v, int q, uint16_t id, uint32_t len) {
    Machine *m = v->m;
    uint16_t ui = (uint16_t)phys_read(m, v->q_used[q] + 2, 2);
    uint64_t e  = v->q_used[q] + 4 + (uint64_t)(ui % v->q_num[q]) * 8;
    phys_write(m, e + 0, 4, id);
    phys_write(m, e + 4, 4, len);
    phys_write(m, v->q_used[q] + 2, 2, (uint16_t)(ui + 1));
}

/* ---- RX: deliver pending frames from the ring into guest buffers ---- */

static void net_flush_rx(VirtIONet *v) {
    Machine *m = v->m;
    if (!v->q_ready[NET_QUEUE_RX] || v->q_num[NET_QUEUE_RX] == 0) return;
    if (!queue_spans(v, NET_QUEUE_RX)) { v->status |= 64; return; }
    bool did = false;

    while (v->rx_head != v->rx_tail) {
        uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[NET_QUEUE_RX] + 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        if (v->last_avail[NET_QUEUE_RX] == avail_idx) break; /* no free guest buffers */

        uint16_t q_num = (uint16_t)v->q_num[NET_QUEUE_RX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[NET_QUEUE_RX] + 4 +
            (uint64_t)(v->last_avail[NET_QUEUE_RX] % q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        v->last_avail[NET_QUEUE_RX]++;

        int slot = v->rx_head;
        v->rx_head = (v->rx_head + 1) & (RX_RING_SIZE - 1);

        uint8_t  *frame = v->rx_buf[slot];
        uint32_t  flen  = v->rx_len[slot];

        /* Write the frame (hdr + packet) into the guest descriptor chain.
         * Bound the walk by q_num (a malformed cyclic chain must not hang us)
         * and only fill device-writable descriptors. */
        uint32_t written = 0;
        uint32_t n = 0, idx = hd;
        while (written < flen && n < q_num) {
            uint64_t d    = v->q_desc[NET_QUEUE_RX] + (uint64_t)idx * 16;
            uint64_t gpa  = phys_read(m, d + 0, 8);
            uint32_t dlen = (uint32_t)phys_read(m, d + 8, 4);
            uint16_t df   = (uint16_t)phys_read(m, d + 12, 2);
            uint16_t next = (uint16_t)phys_read(m, d + 14, 2);
            if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
            n++;
            if (df & VIRTQ_DESC_F_WRITE) {
                uint32_t chunk = flen - written;
                if (chunk > dlen) chunk = dlen;
                phys_write_blk(m, gpa, frame + written, chunk);
                if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
                written += chunk;
            }
            if (!(df & VIRTQ_DESC_F_NEXT)) break;
            idx = next;
        }

        push_used(v, NET_QUEUE_RX, hd, written);
        did = true;
    }

    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- TX: drain guest TX queue into the backend ---- */

static void net_tx_process(VirtIONet *v) {
    Machine *m = v->m;
    if (!v->q_ready[NET_QUEUE_TX] || v->q_num[NET_QUEUE_TX] == 0) return;
    if (!queue_spans(v, NET_QUEUE_TX)) { v->status |= 64; return; }

    uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[NET_QUEUE_TX] + 2, 2);
    if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
    bool did = false;

    while (v->last_avail[NET_QUEUE_TX] != avail_idx) {
        uint16_t q_num = (uint16_t)v->q_num[NET_QUEUE_TX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[NET_QUEUE_TX] + 4 +
            (uint64_t)(v->last_avail[NET_QUEUE_TX] % q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        v->last_avail[NET_QUEUE_TX]++;

        /* Gather descriptor chain into a flat buffer. */
        uint8_t  pkt[NET_HDR_LEN + MAX_ETH_FRAME];
        uint32_t plen = 0;
        uint32_t n = 0, idx = hd;
        for (;;) {
            if (n >= q_num) break;
            uint64_t d    = v->q_desc[NET_QUEUE_TX] + (uint64_t)idx * 16;
            uint64_t gpa  = phys_read(m, d + 0, 8);
            uint32_t dlen = (uint32_t)phys_read(m, d + 8, 4);
            uint16_t df   = (uint16_t)phys_read(m, d + 12, 2);
            uint16_t next = (uint16_t)phys_read(m, d + 14, 2);
            if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
            uint32_t chunk = dlen;
            if (plen + chunk > sizeof(pkt)) chunk = (uint32_t)(sizeof(pkt) - plen);
            phys_read_blk(m, gpa, pkt + plen, chunk);
            if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
            plen += chunk;
            n++;
            if (!(df & VIRTQ_DESC_F_NEXT)) break;
            idx = next;
        }

        /* Skip the virtio_net_hdr; pass the raw Ethernet frame to the backend. */
        if (plen > NET_HDR_LEN)
            usernet_input(v->un, pkt + NET_HDR_LEN, plen - NET_HDR_LEN);

        push_used(v, NET_QUEUE_TX, hd, 0);
        did = true;
    }

    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- backend RX entry: queue a frame for delivery to the guest ---- */

/* Returns false when the software RX ring is full: usernet uses that as
 * backpressure — TCP data is simply not emitted yet, so nothing is lost. */
static bool net_deliver_frame(void *opaque, const uint8_t *buf, size_t len) {
    VirtIONet *v = opaque;
    if (len > MAX_ETH_FRAME) return true;              /* oversized: drop */
    int next_tail = (v->rx_tail + 1) & (RX_RING_SIZE - 1);
    if (next_tail == v->rx_head) return false;         /* ring full */
    int slot = v->rx_tail;
    v->rx_tail = next_tail;

    memset(v->rx_buf[slot], 0, NET_HDR_LEN);          /* zero virtio_net_hdr */
    v->rx_buf[slot][10] = 1;                           /* num_buffers = 1 (LE) */
    memcpy(v->rx_buf[slot] + NET_HDR_LEN, buf, len);
    v->rx_len[slot] = NET_HDR_LEN + (uint32_t)len;
    return true;
}

/* Called from machine_tick() on the host-IO poll cadence. */
void virtio_net_poll(VirtIONet *v) {
    usernet_poll(v->un);
    net_flush_rx(v);
}

/* ---- MMIO ---- */

static u64 net_config_read(VirtIONet *v, u64 off, unsigned size) {
    /* struct virtio_net_config: mac[6] @ 0, status[2] @ 6. */
    uint8_t cfg[8];
    memcpy(cfg, v->mac, 6);
    cfg[6] = VIRTIO_NET_S_LINK_UP & 0xff;
    cfg[7] = (VIRTIO_NET_S_LINK_UP >> 8) & 0xff;
    u64 r = 0;
    for (unsigned i = 0; i < size && off + i < sizeof(cfg); i++)
        r |= (u64)cfg[off + i] << (i * 8);
    return r;
}

static u64 net_read(void *opaque, u64 off, unsigned size) {
    VirtIONet *v = opaque;
    if (off >= 0x100) return net_config_read(v, off - 0x100, size);
    int q = (int)v->queue_sel;
    switch (off) {
        case 0x000: return 0x74726976;       /* MagicValue "virt" */
        case 0x004: return 2;                /* Version (modern)  */
        case 0x008: return 1;                /* DeviceID = net    */
        case 0x00c: return 0x554d4551;       /* VendorID "QEMU"   */
        case 0x010:
            return v->dev_feat_sel == 1 ? (u32)(NET_FEATURES >> 32)
                                        : (u32)(NET_FEATURES & 0xffffffff);
        case 0x034: return (q == 0 || q == 1) ? QUEUE_NUM_MAX : 0; /* QueueNumMax */
        case 0x044: return (q == 0 || q == 1) ? v->q_ready[q] : 0; /* QueueReady */
        case 0x060: return v->isr;           /* InterruptStatus   */
        case 0x070: return v->status;        /* Status            */
        case 0x0fc: return 0;                /* ConfigGeneration  */
        default:    return 0;
    }
}

static void net_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIONet *v = opaque;
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
        case 0x050:                                         /* QueueNotify: val = queue index */
            if (v32 == NET_QUEUE_TX) net_tx_process(v);
            else if (v32 == NET_QUEUE_RX) net_flush_rx(v); /* guest added free buffers */
            break;
        case 0x064:
            v->isr &= ~v32;
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:
            if (v32 == 0) net_reset(v); else v->status = v32;
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

/* Fails cleanly (NULL) on any allocation or host-binding failure; the
 * caller turns that into a create error. Never exits the host process. */
VirtIONet *virtio_net_create(Machine *m, GIC *gic) {
    VirtIONet *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0;   /* slot 0 */

    /* Stable MAC: 52:54:00:12:34:56 (QEMU's default range). */
    static const uint8_t default_mac[6] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    memcpy(v->mac, default_mac, 6);

    v->un = usernet_new(net_deliver_frame, v, v->mac, m->dns_server);
    if (!v->un) { free(v); return NULL; }

    /* Apply port-forwarding rules from the device configuration. A failed
     * bind is a create failure, not a silent "FAILED" note: the caller sees
     * the machine error and reports FLOE_AE_IO to the embedder. */
    for (int i = 0; i < m->n_net_fwds; i++) {
        int r = usernet_add_hostfwd(v->un, m->net_fwds[i].is_udp,
                                    (uint16_t)m->net_fwds[i].host_port,
                                    (uint16_t)m->net_fwds[i].guest_port);
        if (r != 0) {
            fprintf(stderr, "[virtio-net] port forward %s %d -> 10.0.2.15:%d "
                    "FAILED (%s)\n",
                    m->net_fwds[i].is_udp ? "udp" : "tcp",
                    m->net_fwds[i].host_port, m->net_fwds[i].guest_port,
                    strerror(-r));
            usernet_destroy(v->un);
            free(v);
            return NULL;
        }
    }

    machine_add_device(m, 0x0a000000, 0x200, net_read, net_write, v, "virtio-net");
    m->net = v;
    fprintf(stderr, "[virtio-net] MAC %02x:%02x:%02x:%02x:%02x:%02x, "
            "guest 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3\n",
            v->mac[0], v->mac[1], v->mac[2], v->mac[3], v->mac[4], v->mac[5]);
    return v;
}

/* Full teardown after the machine is quiet: backend flows and listeners
 * first, then the device itself. */
void virtio_net_destroy(VirtIONet *v) {
    if (!v) return;
    usernet_destroy(v->un);
    v->un = NULL;
    free(v);
}

/* Accessor for the live-management ABI operations (port-forward add/remove,
 * diagnostics). The backend stays opaque to the bridge. */
UserNet *virtio_net_usernet(VirtIONet *v) { return v ? v->un : NULL; }

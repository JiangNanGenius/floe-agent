/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Modified by Floe contributors, 2026-11-10: mature network backend,
 * bounded event integration and virtual-NIC scheduling/offloads. */
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
 * Processing is synchronous on the machine coordinator: QueueNotify marks the
 * TX queue pending and both directions are serviced during virtio_net_poll()
 * from machine_tick(), so no backend work runs inside a guest trap.
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
 *
 * Floe NIC offloads are negotiated-feature gated; scheduling and completion
 * bounds apply to both legacy and offload-capable drivers:
 *  - TX partial-checksum completion (VIRTIO_NET_F_CSUM) and native TCP
 *    segmentation for TCPV4/TCPV6 (VIRTIO_NET_F_HOST_TSO4/TSO6), so a guest
 *    64 KiB write becomes ordinary, fully checksummed Ethernet frames before
 *    the backend ever sees them. The backend interface is unchanged.
 *  - RX transport-checksum verification reported as
 *    VIRTIO_NET_HDR_F_DATA_VALID (VIRTIO_NET_F_GUEST_CSUM), only when the
 *    checksum was actually confirmed here.
 *  - bounded RX TCP coalescing into one GSO super-frame
 *    (VIRTIO_NET_F_GUEST_TSO4/TSO6, the guest's GRO_HW path), sized to the
 *    buffer the guest actually posted and stopped at every protocol boundary.
 *  - batched used-ring publication and a per-poll delivery cap, so a large
 *    backlog becomes bounded work instead of one long uninterruptible pass.
 *  - poll-cadence TX draining with a held bulk-completion window: QueueNotify
 *    only marks the TX queue pending, the drain runs from virtio_net_poll(),
 *    and used entries for bulk-class frames are published on a bounded
 *    descriptor-count lag (VN_TX_COMPLETION_HOLD) instead of inside the
 *    guest's transmit syscall. Bulk data still flows to the backend at full
 *    speed and in descriptor order, but the guest-visible ring stays occupied,
 *    so the sending socket feels real backpressure and a single bulk stream
 *    cannot hold the guest's event loop for the whole transfer. Interactive
 *    and small frames complete in the same poll drain. A tick with no new
 *    bulk work advances the old tail even during continuous control traffic;
 *    an idle tick publishes every held completion.
 *  - per-flow fair admission to the RX ring, so one bulk flow cannot starve
 *    another (or ARP/ND/ICMP) when the ring is under pressure.
 * See virtio_net_offload.h for the rules this implements and the references.
 */
#include "../devices.h"
#include "../net/usernet.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "virtio_net_offload.h"
/* The offload helper is folded into this translation unit so the engine keeps
 * its existing translation-unit layout without a Package.swift or Sources/
 * change. To build it as its own translation unit instead, add a
 * Sources/NN_virtio_net_offload.c wrapper, define VN_OFFLOAD_SEPARATE_TU for
 * this file, and record the new unit in PROVENANCE.json. */
#ifndef VN_OFFLOAD_SEPARATE_TU
#include "virtio_net_offload.c"
#endif

/* Feature bits. VIRTIO_NET_F_MAC and F_STATUS; VIRTIO_F_VERSION_1 mandatory
 * for a modern device (version 2 transport). The offload set is exactly what
 * virtio_net_offload.c can actually service - a bit we cannot honour would
 * cost the guest correctness, so nothing beyond it is offered. Every offload
 * bit sits below bit 32, i.e. in feature word 0. */
#define VIRTIO_F_VERSION_1  (1ULL << 32)
#define VIRTIO_NET_F_MAC    (1ULL << 5)
#define VIRTIO_NET_F_STATUS (1ULL << 16)

/* ---- RX GSO advertisement: OFF by default, and that is a measured decision --
 *
 * Negotiating VIRTIO_NET_F_GUEST_TSO4/TSO6 makes Linux virtio_net switch its
 * receive ring into big-packet mode (virtnet_set_big_packets ->
 * virtnet_check_guest_gso): every RX buffer becomes a chain of
 * MAX_SKB_FRAGS + 2 descriptors instead of one, and the guest assembles each
 * skb from that many frags. With this device's 256-entry ring that leaves about
 * 14 buffers in flight. It also turns on NETIF_F_GRO_HW and, per
 * virtnet_xdp_set(), blocks guest XDP until rx-gro-hw is switched off.
 *
 * That cost is only repaid if the device actually delivers coalesced
 * super-frames. The current usernet backend marks *every* data segment
 * ACK|PSH (usernet_tcp.c emit_conn), and PSH is a push boundary this device
 * must not merge across, so no aggregate is ever produced: the guest would pay
 * the big-buffer cost and receive nothing in return.
 *
 * Root's NIC-only preview01 run is consistent with exactly that. Full feature
 * negotiation was traced, TX-CSUM / TX-TSO4 / RX DATA_VALID all really
 * executed, no RX-GSO aggregate was observed, and guest bulk work went UP
 * (17,254,291 instr/MiB vs 15,465,373 for the old engine on the same 24 MiB
 * hash fixture, +11.57%) rather than down. Host readiness load differed
 * between the two runs, so the wall-clock ratio is not attributable to code and
 * is not claimed here; the instruction count is the number that matters and it
 * did not improve.
 *
 * GUEST_CSUM alone does NOT trigger big-packet mode (it is not in
 * virtnet_check_guest_gso), so keeping it is a pure win: the guest stops
 * recomputing transport checksums and the device only asserts DATA_VALID after
 * verifying them here.
 *
 * Build with -DVN_ADVERTISE_RX_GSO=1 to turn the RX GSO advertisement on. Do
 * that once the backend delivers TCP segments without a blanket PSH (the
 * libslirp replacement is the natural point to re-measure). The coalescing
 * implementation itself is complete and stays fully covered by tests in both
 * configurations; only the advertisement is gated. */
#ifndef VN_ADVERTISE_RX_GSO
#define VN_ADVERTISE_RX_GSO 0
#endif

#define VN_RX_GSO_FEATURES  (VN_F_GUEST_TSO4 | VN_F_GUEST_TSO6)
#define VN_OFFLOAD_ADVERTISED \
    (VN_OFFLOAD_TX_FEATURES | VN_F_GUEST_CSUM | \
     (VN_ADVERTISE_RX_GSO ? VN_RX_GSO_FEATURES : 0ULL))

#define NET_FEATURES        (VIRTIO_F_VERSION_1 | VIRTIO_NET_F_MAC | \
                             VIRTIO_NET_F_STATUS | VN_OFFLOAD_ADVERTISED)

_Static_assert((VN_OFFLOAD_FEATURES >> 32) == 0,
               "offload features must stay in virtio feature word 0");
_Static_assert((NET_FEATURES & ~VN_F_VERSION_1) < (1ULL << 32),
               "only VERSION_1 may live in virtio feature word 1");

#define VIRTIO_NET_S_LINK_UP  1

/* virtio_net header length. The Linux virtio_net driver (and QEMU) use the
 * 12-byte struct virtio_net_hdr_mrg_rxbuf whenever VIRTIO_F_VERSION_1 OR
 * VIRTIO_NET_F_MRG_RXBUF is negotiated — the bare 10-byte struct virtio_net_hdr
 * is used only by a legacy device that negotiates neither. We are a modern
 * (version 2 transport) device that negotiates VERSION_1, so the guest prepends
 * 12 bytes on TX and expects 12 bytes on RX, even though we don't merge buffers.
 * The extra 2 bytes are num_buffers (set to 1 on RX, ignored on TX). */
#define NET_HDR_LEN   12
_Static_assert(NET_HDR_LEN == VN_HDR_LEN, "virtio_net_hdr_v1 is 12 bytes here");

/* Split-virtqueue descriptor flags. */
#define VIRTQ_DESC_F_NEXT  1
#define VIRTQ_DESC_F_WRITE 2

#define QUEUE_NUM_MAX 256
#define VIRTQ_MAX     256

#define NET_QUEUE_RX  0
#define NET_QUEUE_TX  1

/* Pending RX frame ring — frames queued by the backend before the guest
 * RX queue is ready. Power-of-two so the head/tail modulo is a mask.
 *
 * Slots stay sized for one ordinary Ethernet frame: coalescing happens on the
 * way *out* of the ring into the guest's own buffer, so a bigger ring is not
 * what buys the batching. */
#define RX_RING_SIZE  64          /* must be power of 2 */
#define MAX_ETH_FRAME VN_MAX_ETH_FRAME

/* Usable ring capacity. The ring keeps one slot empty to distinguish full from
 * empty, which is also what the fairness accounting is told about. */
#define RX_RING_USABLE (RX_RING_SIZE - 1)

/* Gather/emit buffer sizes, derived from the 16-bit IP length fields rather
 * than guessed. See VN_MAX_GSO_FRAME. */
#define NET_TX_GATHER_BYTES (NET_HDR_LEN + VN_MAX_GSO_FRAME)
#define NET_RX_AGGREGATE_BYTES (NET_HDR_LEN + VN_MAX_GSO_FRAME)

/* One used-ring entry pending publication. */
typedef struct { uint16_t id; uint32_t len; } NetUsedEntry;

/* One writable RX descriptor, snapshotted so the delivery size can be chosen
 * against the space the guest really posted before anything is written. */
typedef struct { uint64_t gpa; uint32_t len; } NetRxDesc;

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

    /* Per-slot fair-queuing accounting, released when the slot is drained. */
    VNFlowKey rx_flow[RX_RING_SIZE];
    bool      rx_flow_known[RX_RING_SIZE];

    /* Offload working storage, all owned by this device and freed in
     * virtio_net_destroy(). Heap rather than stack: a GSO super-packet is up
     * to 64 KiB and this runs on the machine coordinator's stack. */
    uint8_t      *tx_gather;      /* NET_TX_GATHER_BYTES */
    uint8_t      *tx_segment;     /* MAX_ETH_FRAME: one produced segment */
    uint8_t      *rx_aggregate;   /* NET_RX_AGGREGATE_BYTES */
    NetUsedEntry *used_batch;     /* VIRTQ_MAX entries */
    NetRxDesc    *rx_desc;        /* VIRTQ_MAX entries */

    VNFairness fair;
    VNStats    stats;

    /* Set when a bounded TX drain stopped with descriptors still available,
     * so virtio_net_poll() finishes the job. Without this the guest could wait
     * for a notify it has no reason to send. */
    bool tx_pending;

    /* Held bulk TX completions: descriptor heads already consumed and handed
     * to the backend whose used entries are published on a bounded lag
     * (VN_TX_COMPLETION_HOLD) from the poll cadence. FIFO by descriptor
     * order; out-of-order used entries relative to the avail ring are ordinary
     * virtio behaviour because every entry carries its id. The natural bound
     * is the ring itself: an unpublished descriptor still occupies its ring
     * slot from the guest's point of view, so at most VIRTQ_MAX entries can
     * ever be outstanding. */
    uint16_t tx_deferred_ids[VIRTQ_MAX];
    uint32_t tx_deferred_n;
} VirtIONet;

/* ---- helpers ---- */

/* The feature set the driver actually accepted, restricted to what we offered.
 * Zero until the driver writes DriverFeatures, so every offload decision below
 * naturally falls back to the legacy path during probe and after a reset. */
static inline uint64_t net_negotiated(const VirtIONet *v) {
    return v->drv_feat & NET_FEATURES;
}

/* ---- qualification-only observability ----
 *
 * A real guest run has to be able to prove two things that no host-side unit
 * test can: that Linux actually *negotiated* the new feature bits, and that the
 * negotiated paths actually *ran* rather than every frame quietly falling back.
 * Both are reported through the engine's existing stderr hook, which the Bridge
 * redirects into the bounded diagnostic buffer readable with the existing
 * floe_ae_diagnostic_read(). That needs no public ABI field, no reserved-slot
 * change, no devices.h change and no App UI.
 *
 * Volume is bounded by construction: each event class logs its first
 * occurrence and then only on powers of ten, so a multi-gigabyte transfer
 * produces a handful of lines, not one per frame. Rejections and fallbacks are
 * traced on the same schedule, so "offload silently did nothing" is visible
 * rather than inferred from the absence of a line.
 *
 * Set VN_OFFLOAD_TRACE to 0 at build time to compile every trace statement out.
 * The counters themselves are kept either way. */
#ifndef VN_OFFLOAD_TRACE
#define VN_OFFLOAD_TRACE 1
#endif

#if VN_OFFLOAD_TRACE
/* True on the 1st occurrence and then on every exact power of ten, so each
 * event class contributes a handful of lines no matter how long the run. */
static bool vn_trace_at(uint64_t count) {
    uint64_t t;
    if (count == 0) return false;
    if (count == 1) return true;
    for (t = 10; t <= count; t *= 10)
        if (t == count) return true;
    return false;
}
#define VN_TRACE(...) fprintf(stderr, __VA_ARGS__)
#else
/* Counters are kept either way; only the reporting is compiled out. */
#define vn_trace_at(count) (false)
#define VN_TRACE(...) ((void)0)
#endif

/* virtio STATUS bits this device cares about for tracing negotiation. */
#define VIRTIO_NET_S_DRIVER_OK    4u
#define VIRTIO_NET_S_FEATURES_OK  8u

/* One line describing exactly which offloads the driver accepted. Called when
 * the guest reaches FEATURES_OK/DRIVER_OK, i.e. when negotiation is settled. */
static void net_trace_negotiation(VirtIONet *v, const char *stage) {
    uint64_t n = net_negotiated(v);
    VN_TRACE("[virtio-net] %s: driver features 0x%08x%08x -> negotiated %s%s%s%s%s%s\n",
             stage,
             (unsigned)(v->drv_feat >> 32), (unsigned)(v->drv_feat & 0xffffffffu),
             (n & VN_F_CSUM)       ? "TX-CSUM "       : "",
             (n & VN_F_HOST_TSO4)  ? "TX-TSO4 "       : "",
             (n & VN_F_HOST_TSO6)  ? "TX-TSO6 "       : "",
             (n & VN_F_GUEST_CSUM) ? "RX-CSUM "       : "",
             (n & VN_F_GUEST_TSO4) ? "RX-GSO4 "       : "",
             (n & VN_F_GUEST_TSO6) ? "RX-GSO6"        : "");
    if (!(n & VN_OFFLOAD_FEATURES))
        VN_TRACE("[virtio-net] %s: no offload negotiated, legacy path only\n",
                 stage);
}

/* Full counter dump. Emitted on device reset and teardown, so a real run
 * leaves a record of what the negotiated paths actually did. */
static void net_trace_stats(VirtIONet *v, const char *stage) {
    const VNStats *s = &v->stats;
    VN_TRACE("[virtio-net] %s stats: tx frames=%llu passthrough=%llu "
             "csum=%llu csum_deferred=%llu segmented=%llu segments=%llu "
             "segbytes=%llu\n",
             stage,
             (unsigned long long)s->tx_frames,
             (unsigned long long)s->tx_passthrough,
             (unsigned long long)s->tx_csum_completed,
             (unsigned long long)s->tx_csum_deferred,
             (unsigned long long)s->tx_segmented,
             (unsigned long long)s->tx_segments,
             (unsigned long long)s->tx_seg_bytes);
    VN_TRACE("[virtio-net] %s stats: tx reject malformed=%llu unsupported=%llu "
             "unnegotiated=%llu oversized=%llu budget=%llu\n",
             stage,
             (unsigned long long)s->tx_reject_malformed,
             (unsigned long long)s->tx_reject_unsupported,
             (unsigned long long)s->tx_reject_unnegotiated,
             (unsigned long long)s->tx_reject_oversized,
             (unsigned long long)s->tx_budget_exhausted);
    VN_TRACE("[virtio-net] %s stats: rx frames=%llu delivered=%llu "
             "data_valid=%llu aggregates=%llu members=%llu\n",
             stage,
             (unsigned long long)s->rx_frames,
             (unsigned long long)s->rx_delivered,
             (unsigned long long)s->rx_data_valid,
             (unsigned long long)s->rx_aggregates,
             (unsigned long long)s->rx_aggregate_members);
    VN_TRACE("[virtio-net] %s stats: rx csum valid=%llu invalid=%llu unknown=%llu "
             "ring_full=%llu fair_refused=%llu batch_capped=%llu truncated=%llu "
             "oversized=%llu desc_violations=%llu\n",
             stage,
             (unsigned long long)s->rx_csum_valid,
             (unsigned long long)s->rx_csum_invalid,
             (unsigned long long)s->rx_csum_unknown,
             (unsigned long long)s->rx_ring_full,
             (unsigned long long)s->rx_fair_refused,
             (unsigned long long)s->rx_batch_capped,
             (unsigned long long)s->rx_truncated_buffer,
             (unsigned long long)s->rx_oversized,
             (unsigned long long)s->desc_index_violations);
    VN_TRACE("[virtio-net] %s stats: fairness admits=%llu refusals=%llu "
             "control_bypass=%llu table_full=%llu tracked=%u\n",
             stage,
             (unsigned long long)v->fair.admits,
             (unsigned long long)v->fair.refusals,
             (unsigned long long)v->fair.control_bypass,
             (unsigned long long)v->fair.table_full,
             (unsigned)v->fair.tracked);
}

static void net_reset(VirtIONet *v) {
    /* Record what the outgoing driver instance actually used before its state
     * is discarded, so a warm reboot leaves an honest trace behind. */
    if (v->stats.tx_frames || v->stats.rx_frames)
        net_trace_stats(v, "reset");
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
    for (int i = 0; i < RX_RING_SIZE; i++) v->rx_flow_known[i] = false;
    /* Counters describe the device and survive a guest reset; the accounting
     * that depends on ring occupancy does not. */
    vn_fairness_reset(&v->fair);
    v->tx_pending = false;
    v->tx_deferred_n = 0;   /* the old driver's ring is gone; held ids are meaningless */
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

/* ---- used-ring publication ----
 *
 * Batched on purpose. Entries are written first and the index last, which is
 * the ordering a driver relies on anyway, and it turns four bus transactions
 * per frame into two plus one for the whole batch. A driver only ever sees a
 * frame once the index that covers it has landed. */

static bool used_ring_read_index(VirtIONet *v, int q, uint16_t *idx) {
    u64 raw = phys_read(v->m, v->q_used[q] + 2, 2);
    if (machine_bus_status(v->m) != BUS_OK) return false;
    *idx = (uint16_t)raw;
    return true;
}

static bool used_ring_publish(VirtIONet *v, int q, uint16_t start, uint32_t n) {
    Machine *m = v->m;
    uint16_t q_num = (uint16_t)v->q_num[q];
    for (uint32_t i = 0; i < n; i++) {
        uint16_t slot = (uint16_t)((uint16_t)(start + i) % q_num);
        uint64_t e = v->q_used[q] + 4 + (uint64_t)slot * 8;
        phys_write(m, e + 0, 4, v->used_batch[i].id);
        phys_write(m, e + 4, 4, v->used_batch[i].len);
        if (machine_bus_status(m) != BUS_OK) return false;
    }
    phys_write(m, v->q_used[q] + 2, 2, (uint16_t)(start + n));
    return machine_bus_status(m) == BUS_OK;
}

/* Read one descriptor. A descriptor index outside the ring is a driver
 * violation: following it would read guest memory the queue does not own, so
 * it is refused and counted instead. */
static bool net_read_desc(VirtIONet *v, int q, uint16_t idx,
                          uint64_t *gpa, uint32_t *dlen, uint16_t *flags,
                          uint16_t *next) {
    if (idx >= v->q_num[q]) { v->stats.desc_index_violations++; return false; }
    uint64_t d = v->q_desc[q] + (uint64_t)idx * 16;
    *gpa   = phys_read(v->m, d + 0, 8);
    *dlen  = (uint32_t)phys_read(v->m, d + 8, 4);
    *flags = (uint16_t)phys_read(v->m, d + 12, 2);
    *next  = (uint16_t)phys_read(v->m, d + 14, 2);
    return machine_bus_status(v->m) == BUS_OK;
}

/* ---- RX: deliver pending frames from the ring into guest buffers ---- */

/* Snapshot the writable part of one RX descriptor chain and report how much
 * room the guest actually posted. Bounded by q_num so a cyclic chain cannot
 * hang us, and by the snapshot array so the walk is a single pass. */
static bool net_rx_chain_capacity(VirtIONet *v, uint16_t head,
                                  uint32_t *count, uint32_t *capacity) {
    uint16_t q_num = (uint16_t)v->q_num[NET_QUEUE_RX];
    uint32_t n = 0, cap = 0, idx = head;
    for (;;) {
        uint64_t gpa; uint32_t dlen; uint16_t flags, next;
        if (n >= q_num || n >= VIRTQ_MAX) break;
        if (!net_read_desc(v, NET_QUEUE_RX, (uint16_t)idx, &gpa, &dlen,
                           &flags, &next))
            return false;
        if (flags & VIRTQ_DESC_F_WRITE) {
            v->rx_desc[n].gpa = gpa;
            v->rx_desc[n].len = dlen;
            n++;
            cap += dlen;
        }
        if (!(flags & VIRTQ_DESC_F_NEXT)) break;
        idx = next;
    }
    *count = n;
    *capacity = cap;
    return true;
}

/* Ring occupancy, for the fairness share. */
static inline uint16_t net_rx_occupancy(const VirtIONet *v) {
    return (uint16_t)((v->rx_tail - v->rx_head) & (RX_RING_SIZE - 1));
}

static void net_flush_rx(VirtIONet *v) {
    Machine *m = v->m;
    uint64_t negotiated;
    bool guest_csum, coal4, coal6;
    uint16_t used_start = 0;
    uint32_t used_n = 0;
    uint32_t delivered = 0;
    bool have_used_start = false;

    if (!v->q_ready[NET_QUEUE_RX] || v->q_num[NET_QUEUE_RX] == 0) return;
    if (!queue_spans(v, NET_QUEUE_RX)) { v->status |= 64; return; }

    negotiated = net_negotiated(v);
    guest_csum = (negotiated & VN_F_GUEST_CSUM) != 0;
    coal4 = guest_csum && (negotiated & VN_F_GUEST_TSO4) != 0;
    coal6 = guest_csum && (negotiated & VN_F_GUEST_TSO6) != 0;

    while (v->rx_head != v->rx_tail) {
        uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[NET_QUEUE_RX] + 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        if (v->last_avail[NET_QUEUE_RX] == avail_idx) break; /* no free guest buffers */
        /* Bounded work per invocation. The remainder stays in the ring and is
         * picked up by the next poll, so a multi-megabyte backlog becomes a
         * sequence of short passes instead of one long stall on the owner
         * thread. Nothing is dropped to achieve this. */
        if (delivered >= VN_RX_BATCH_MAX_FRAMES) {
            v->stats.rx_batch_capped++;
            if (vn_trace_at(v->stats.rx_batch_capped))
                VN_TRACE("[virtio-net] RX batch cap %u reached n=%llu, "
                         "%d frame(s) still queued for the next poll\n",
                         (unsigned)VN_RX_BATCH_MAX_FRAMES,
                         (unsigned long long)v->stats.rx_batch_capped,
                         (int)((v->rx_tail - v->rx_head) & (RX_RING_SIZE - 1)));
            break;
        }

        uint16_t q_num = (uint16_t)v->q_num[NET_QUEUE_RX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[NET_QUEUE_RX] + 4 +
            (uint64_t)(v->last_avail[NET_QUEUE_RX] % q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        if (hd >= q_num) {
            /* A descriptor index outside the ring: refuse the queue rather
             * than walk guest memory this queue does not own. */
            v->stats.desc_index_violations++;
            v->status |= 64;
            return;
        }
        v->last_avail[NET_QUEUE_RX]++;

        uint32_t desc_count = 0, capacity = 0;
        if (!net_rx_chain_capacity(v, hd, &desc_count, &capacity)) {
            v->status |= 64; return;
        }

        int slot = v->rx_head;
        uint8_t  *frame = v->rx_buf[slot] + NET_HDR_LEN;
        uint32_t  flen  = v->rx_len[slot] > NET_HDR_LEN
                        ? v->rx_len[slot] - NET_HDR_LEN : 0;

        VNFrameInfo info;
        bool parsed = (vn_frame_parse(frame, flen, &info) == VN_PARSE_OK);
        bool coalesced = false;
        uint32_t out_len = 0;
        const uint8_t *out = NULL;
        int consumed = 1;                 /* ring slots this delivery covers */
        VNNetHdrFields hdr;
        bool root_verified = false;

        memset(&hdr, 0, sizeof(hdr));

        /* ---- RX coalescing ----
         * Only when the guest accepted GUEST_CSUM plus the GUEST_TSO bit for
         * this address family, and only up to the buffer it actually posted.
         * Every protocol boundary is preserved: a member must be a verified,
         * in-order, plain-ACK TCP segment of the same flow with an identical
         * header, so ARP/ND/ICMP/UDP and SYN/FIN/RST/PSH always go through
         * individually. */
        if (parsed && capacity > 0 &&
            ((info.family == VN_FRAME_IPV4 && coal4) ||
             (info.family == VN_FRAME_IPV6 && coal6))) {
            VNCoalesce c;
            VNTcpView view;
            VNCaps caps;
            /* Leave room for the replicated prefix inside the buffer the guest
             * posted, and inside the 16-bit IP length field. */
            uint32_t room = capacity > NET_HDR_LEN + VN_ETH_HLEN + VN_IPV6_HLEN +
                                     VN_MAX_TCP_HLEN
                          ? capacity - (NET_HDR_LEN + VN_ETH_HLEN + VN_IPV6_HLEN +
                                        VN_MAX_TCP_HLEN)
                          : 0;
            if (room > VN_RX_COALESCE_MAX_PAYLOAD) room = VN_RX_COALESCE_MAX_PAYLOAD;
            caps.max_payload = room;
            caps.max_segments = VN_RX_COALESCE_MAX_SEGMENTS;

            if (room >= info.payload_len &&
                vn_coalesce_begin(frame, flen, negotiated, &c, &view) == VN_COAL_OK) {
                VNFrameRef members[VN_RX_COALESCE_MAX_SEGMENTS];
                int peek = v->rx_head;
                uint16_t n = 0;

                root_verified = true;   /* begin() confirmed this checksum */
                members[0].bytes = frame;
                members[0].len = flen;
                members[0].payload_off = c.prefix_len;
                members[0].payload_len = c.gso_size;
                n = 1;

                for (;;) {
                    int nxt = (peek + 1) & (RX_RING_SIZE - 1);
                    uint8_t *nf;
                    uint32_t nlen, added = 0;
                    VNCoalReason r;
                    if (nxt == v->rx_tail) break;
                    if (n >= VN_RX_COALESCE_MAX_SEGMENTS) break;
                    peek = nxt;
                    nf = v->rx_buf[peek] + NET_HDR_LEN;
                    nlen = v->rx_len[peek] > NET_HDR_LEN
                         ? v->rx_len[peek] - NET_HDR_LEN : 0;
                    r = vn_coalesce_append(&c, nf, nlen, &caps, &added);
                    if (r != VN_COAL_OK) { peek = (peek - 1) & (RX_RING_SIZE - 1); break; }
                    members[n].bytes = nf;
                    members[n].len = nlen;
                    members[n].payload_off = c.prefix_len;
                    members[n].payload_len = added;
                    n++;
                }

                /* A single member is not a super-frame: hand it over through
                 * the ordinary path so the guest sees exactly what arrived. */
                if (n >= 2) {
                    uint32_t cap = capacity > NET_RX_AGGREGATE_BYTES
                                 ? NET_RX_AGGREGATE_BYTES : capacity;
                    uint32_t total = vn_coalesce_emit(&c, members, n,
                                                      v->rx_aggregate, cap);
                    if (total) {
                        /* vn_coalesce_emit() produces the complete
                         * [virtio_net_hdr | Ethernet super-frame] blob, header
                         * included, because it is the only party that knows the
                         * negotiated GSO metadata. Normalise it into the same
                         * representation the single-frame path uses - a header
                         * struct plus a pointer at the first Ethernet byte - so
                         * the scatter loop below writes exactly one header and
                         * reports exactly one header's worth of length.
                         * Treating `total` as a frame length here would prepend
                         * a second, zeroed header and push the used length 12
                         * bytes too high. */
                        vn_hdr_read(v->rx_aggregate, &hdr);
                        out = v->rx_aggregate + NET_HDR_LEN;
                        out_len = total - NET_HDR_LEN;
                        consumed = (int)n;
                        coalesced = true;
                        v->stats.rx_aggregates++;
                        v->stats.rx_aggregate_members += n;
                        if (vn_trace_at(v->stats.rx_aggregates))
                            VN_TRACE("[virtio-net] RX-GSO coalesced n=%llu "
                                     "gso_type=%u gso_size=%u members=%u "
                                     "-> %u bytes (guest buffer %u)\n",
                                     (unsigned long long)v->stats.rx_aggregates,
                                     (unsigned)c.gso_type, (unsigned)c.gso_size,
                                     (unsigned)n, (unsigned)total,
                                     (unsigned)capacity);
                    }
                }
            }
        }

        if (!coalesced) {
            /* Single frame. DATA_VALID only when this device actually verified
             * the transport checksum; a bad or unjudgeable checksum is still
             * delivered with flags clear so the guest's stack can count it. */
            VNRxCsumVerdict verdict = root_verified
                ? VN_RX_CSUM_VALID
                : (parsed ? vn_rx_verify(frame, flen, &info)
                          : VN_RX_CSUM_UNKNOWN);
            if (verdict == VN_RX_CSUM_VALID) {
                v->stats.rx_csum_valid++;
                if (guest_csum) {
                    hdr.flags = VN_HDR_F_DATA_VALID;
                    v->stats.rx_data_valid++;
                    if (vn_trace_at(v->stats.rx_data_valid))
                        VN_TRACE("[virtio-net] RX-CSUM DATA_VALID n=%llu "
                                 "proto=%u len=%u\n",
                                 (unsigned long long)v->stats.rx_data_valid,
                                 (unsigned)info.proto, (unsigned)flen);
                }
            } else if (verdict == VN_RX_CSUM_INVALID) {
                v->stats.rx_csum_invalid++;
                if (vn_trace_at(v->stats.rx_csum_invalid))
                    VN_TRACE("[virtio-net] RX-CSUM invalid, delivered with flags "
                             "clear n=%llu proto=%u len=%u\n",
                             (unsigned long long)v->stats.rx_csum_invalid,
                             (unsigned)info.proto, (unsigned)flen);
            } else {
                v->stats.rx_csum_unknown++;
            }
            out = frame;
            out_len = flen;
        }

        /* Write the 12-byte header plus the frame into the guest's buffer. */
        {
            uint8_t hdrbytes[NET_HDR_LEN];
            vn_hdr_write(hdrbytes, &hdr);   /* num_buffers is forced to 1 */
            uint32_t need = NET_HDR_LEN + out_len;
            uint32_t at = 0;
            bool ok = true;
            if (need > capacity) {
                /* The guest posted less room than one frame needs. Truncating
                 * is what the legacy path did; keep the behaviour but make it
                 * visible instead of silent. */
                v->stats.rx_truncated_buffer++;
            }
            for (uint32_t i = 0; i < desc_count && at < need; i++) {
                uint32_t chunk = need - at;
                if (chunk > v->rx_desc[i].len) chunk = v->rx_desc[i].len;
                if (chunk == 0) continue;      /* zero-length descriptor */
                /* `at` walks the logical [header | frame] stream, so a chunk
                 * that straddles the boundary is written as two DMA copies but
                 * still advances the cursor by exactly `chunk`. */
                if (at < NET_HDR_LEN) {
                    uint32_t h = NET_HDR_LEN - at;
                    if (h > chunk) h = chunk;
                    phys_write_blk(m, v->rx_desc[i].gpa, hdrbytes + at, h);
                    if (machine_bus_status(m) != BUS_OK) { ok = false; break; }
                    if (chunk > h) {
                        phys_write_blk(m, v->rx_desc[i].gpa + h, out, chunk - h);
                        if (machine_bus_status(m) != BUS_OK) { ok = false; break; }
                    }
                } else {
                    phys_write_blk(m, v->rx_desc[i].gpa, out + (at - NET_HDR_LEN),
                                   chunk);
                    if (machine_bus_status(m) != BUS_OK) { ok = false; break; }
                }
                at += chunk;
            }
            if (!ok) { v->status |= 64; return; }
            out_len = at > NET_HDR_LEN ? at - NET_HDR_LEN : 0;
        }

        /* Release the fairness accounting for every slot this delivery took,
         * then advance the ring. */
        for (int i = 0; i < consumed; i++) {
            int s = (v->rx_head + i) & (RX_RING_SIZE - 1);
            if (v->rx_flow_known[s]) {
                vn_fairness_release(&v->fair, &v->rx_flow[s]);
                v->rx_flow_known[s] = false;
            }
        }
        v->rx_head = (v->rx_head + consumed) & (RX_RING_SIZE - 1);

        if (!have_used_start) {
            if (!used_ring_read_index(v, NET_QUEUE_RX, &used_start)) {
                v->status |= 64; return;
            }
            have_used_start = true;
        }
        if (used_n < VIRTQ_MAX) {
            v->used_batch[used_n].id = hd;
            v->used_batch[used_n].len = NET_HDR_LEN + out_len;
            used_n++;
        } else {
            /* Cannot happen while the batch is capped below the queue size,
             * but never write past the array: publish what we have. */
            break;
        }
        v->stats.rx_delivered++;
        delivered++;
    }

    if (used_n) {
        if (!used_ring_publish(v, NET_QUEUE_RX, used_start, used_n)) {
            v->status |= 64; return;
        }
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- TX: drain guest TX queue into the backend ---- */

/* True when a guest TX frame carries bulk-class transport payload, so its
 * completion rides the held window instead of publishing immediately.
 * Unparseable frames and everything small or control-class stay immediate. */
static bool net_tx_frame_is_bulk(const uint8_t *frame, uint32_t flen) {
    VNFrameInfo info;
    if (vn_frame_parse(frame, flen, &info) != VN_PARSE_OK) return false;
    if (!vn_frame_is_bulk(&info)) return false;
    return info.payload_len >= VN_TX_DEFER_MIN_PAYLOAD;
}

/* Publish held bulk TX completions: the used entries plus the interrupt, in
 * one batch. With drain_all false, publish the overflow beyond the hold window
 * (oldest first), or one old entry when make_progress is requested. This keeps
 * the guest-visible ring
 * occupancy - and therefore the sending socket's backpressure - bounded away
 * from zero during a bulk transfer. Runs on the machine coordinator like every
 * other ring mutation. */
static void net_flush_tx_completions(VirtIONet *v, bool drain_all,
                                      bool make_progress) {
    if (!v->tx_deferred_n) return;
    uint32_t n = v->tx_deferred_n;
    if (!drain_all) {
        /* Scale the window to the ring the guest actually selected, so a
         * driver that negotiates fewer descriptors still sees the window
         * slide (and can never be locked out by a hold larger than its
         * whole ring). */
        uint32_t hold = VN_TX_COMPLETION_HOLD;
        if (v->q_num[NET_QUEUE_TX] && v->q_num[NET_QUEUE_TX] < VIRTQ_MAX) {
            uint32_t scaled = v->q_num[NET_QUEUE_TX] / 4 * 3;
            if (scaled < hold) hold = scaled;
        }
        if (n <= hold) {
            if (!make_progress) return;
            n = 1;
        } else {
            n -= hold;
        }
    }
    if (!v->q_ready[NET_QUEUE_TX] || v->q_num[NET_QUEUE_TX] == 0 ||
        !queue_spans(v, NET_QUEUE_TX)) {
        /* The queue went away underneath the completions (guest reset): the
         * ids are meaningless now, drop them without touching the ring. */
        v->tx_deferred_n = 0;
        return;
    }
    uint16_t used_start = 0;
    if (!used_ring_read_index(v, NET_QUEUE_TX, &used_start)) { v->status |= 64; return; }
    for (uint32_t i = 0; i < n; i++) {
        v->used_batch[i].id = v->tx_deferred_ids[i];
        v->used_batch[i].len = 0;   /* TX writes nothing back */
    }
    if (!used_ring_publish(v, NET_QUEUE_TX, used_start, n)) { v->status |= 64; return; }
    v->tx_deferred_n -= n;
    if (v->tx_deferred_n)
        memmove(v->tx_deferred_ids, v->tx_deferred_ids + n,
                v->tx_deferred_n * sizeof(v->tx_deferred_ids[0]));
    v->isr |= 1;
    gic_set_irq(v->gic, v->irq, 1);
}

/* One produced segment on its way to the backend. */
typedef struct {
    VirtIONet *v;
    bool       stopped;    /* the backend refused a frame */
    uint64_t   frames;
} NetTxSink;

static bool net_tx_emit(void *opaque, const uint8_t *frame, uint32_t len) {
    NetTxSink *sink = opaque;
    sink->frames++;
    sink->v->stats.tx_segments++;
    sink->v->stats.tx_seg_bytes += len;
    /* usernet_input() has no return value, so a segment is always accepted or
     * rejected by the backend's own length rules. The sink stays truthful
     * about how many frames it handed over. */
    usernet_input(sink->v->un, frame, len);
    return !sink->stopped;
}

/* budget is the number of output frames this drain may still produce. It is
 * never allowed to split a super-packet, so a caller that has produced nothing
 * yet passes UINT32_MAX to guarantee forward progress. */
static void net_tx_process(VirtIONet *v, uint32_t budget) {
    Machine *m = v->m;
    uint64_t negotiated;
    bool host_csum, host_tso4, host_tso6;
    uint16_t used_start = 0;
    uint32_t used_n = 0;
    bool have_used_start = false;
    bool did = false;
    uint32_t emitted = 0;
    bool defer_completion = false;

    if (!v->q_ready[NET_QUEUE_TX] || v->q_num[NET_QUEUE_TX] == 0) return;
    if (!queue_spans(v, NET_QUEUE_TX)) { v->status |= 64; return; }

    uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail[NET_QUEUE_TX] + 2, 2);
    if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }

    negotiated = net_negotiated(v);
    host_csum = (negotiated & VN_F_CSUM) != 0;
    host_tso4 = (negotiated & VN_F_HOST_TSO4) != 0;
    host_tso6 = (negotiated & VN_F_HOST_TSO6) != 0;

    v->tx_pending = false;

    while (v->last_avail[NET_QUEUE_TX] != avail_idx) {
        defer_completion = false;
        uint16_t q_num = (uint16_t)v->q_num[NET_QUEUE_TX];
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail[NET_QUEUE_TX] + 4 +
            (uint64_t)(v->last_avail[NET_QUEUE_TX] % q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        if (hd >= q_num) {
            v->stats.desc_index_violations++;
            v->status |= 64;
            return;
        }

        /* Gather the descriptor chain into the flat buffer. */
        uint8_t  *pkt = v->tx_gather;
        uint32_t  cap = NET_TX_GATHER_BYTES;
        uint32_t plen = 0;
        uint32_t n = 0, idx = hd;
        bool truncated = false;
        bool chain_ok = true;
        for (;;) {
            uint64_t gpa; uint32_t dlen; uint16_t df, next;
            if (n >= q_num) break;
            if (!net_read_desc(v, NET_QUEUE_TX, (uint16_t)idx, &gpa, &dlen,
                               &df, &next)) { chain_ok = false; break; }
            n++;
            uint32_t chunk = dlen;
            if (plen + chunk > cap) {
                chunk = plen + chunk > cap ? cap - plen : 0;
                truncated = true;
            }
            if (chunk) {
                phys_read_blk(m, gpa, pkt + plen, chunk);
                if (machine_bus_status(m) != BUS_OK) { chain_ok = false; break; }
                plen += chunk;
            }
            if (!(df & VIRTQ_DESC_F_NEXT)) break;
            idx = next;
        }
        if (!chain_ok) { v->status |= 64; return; }
        if (truncated) {
            /* A chain longer than a maximum-size super-packet. Forwarding a
             * truncated frame would hand the backend something whose IP length
             * disagrees with its bytes, so it is refused and counted instead.
             * This is a driver violation of the negotiated queue, not a case a
             * conforming guest reaches. */
            v->stats.tx_reject_oversized++;
            goto tx_used;
        }

        v->stats.tx_frames++;

        if (plen > NET_HDR_LEN) {
            uint8_t *frame = pkt + NET_HDR_LEN;
            uint32_t flen = plen - NET_HDR_LEN;
            /* Bulk data frames ride the held completion window; everything
             * else completes inside this drain, exactly as before. */
            defer_completion = net_tx_frame_is_bulk(frame, flen);
            VNNetHdrFields hdr;
            vn_hdr_read(pkt, &hdr);
            bool segmented = false;
            bool csum_deferred = false;

            /* Will this frame be handed to the segmenter? If so, completing its
             * whole-packet checksum first is pure waste: vn_tx_segment()
             * recomputes the transport checksum from each segment's own bytes
             * and never reads the seed. On a 64 KiB super-packet that skipped
             * walk is the single largest per-packet host cost in the TX path, so
             * it is deferred and only performed if segmentation does not happen
             * and the frame is about to be forwarded as-is. */
            bool csum_requested = host_csum &&
                                  (hdr.flags & VN_HDR_F_NEEDS_CSUM) != 0;
            bool csum_done = false;
            {
                uint8_t b = (uint8_t)(hdr.gso_type & (uint8_t)~VN_GSO_ECN);
                bool will_segment = (b == VN_GSO_TCPV4 && host_tso4) ||
                                    (b == VN_GSO_TCPV6 && host_tso6);
                csum_deferred = csum_requested && will_segment;
                if (csum_deferred) {
                    v->stats.tx_csum_deferred++;
                    if (vn_trace_at(v->stats.tx_csum_deferred))
                        VN_TRACE("[virtio-net] TX-CSUM deferred n=%llu: the "
                                 "segmenter recomputes every segment\n",
                                 (unsigned long long)v->stats.tx_csum_deferred);
                }
            }

            /* TX partial checksum. Only when the feature was accepted: an
             * un-negotiated driver sends complete checksums and its header
             * fields must not be read as offload requests. */
            if (csum_requested && !csum_deferred) {
                csum_done = true;
                if (vn_tx_complete_csum(frame, flen, &hdr) == VN_TX_CSUM_COMPLETED) {
                    v->stats.tx_csum_completed++;
                    if (vn_trace_at(v->stats.tx_csum_completed))
                        VN_TRACE("[virtio-net] TX-CSUM completed n=%llu "
                                 "csum_start=%u csum_offset=%u len=%u\n",
                                 (unsigned long long)v->stats.tx_csum_completed,
                                 (unsigned)hdr.csum_start,
                                 (unsigned)hdr.csum_offset, (unsigned)flen);
                } else {
                    v->stats.tx_reject_malformed++;
                    if (vn_trace_at(v->stats.tx_reject_malformed))
                        VN_TRACE("[virtio-net] TX-CSUM malformed n=%llu "
                                 "csum_start=%u csum_offset=%u len=%u\n",
                                 (unsigned long long)v->stats.tx_reject_malformed,
                                 (unsigned)hdr.csum_start,
                                 (unsigned)hdr.csum_offset, (unsigned)flen);
                }
            }

            /* TX segmentation. gso_type is honoured only together with the
             * matching accepted feature; otherwise the frame is passed through
             * untouched, exactly as before this change. */
            if (hdr.gso_type != VN_GSO_NONE) {
                uint8_t base = (uint8_t)(hdr.gso_type & (uint8_t)~VN_GSO_ECN);
                /* Distinguish "this device never implements that gso_type"
                 * (UFO, USO, tunnels) from "it is implemented but the driver
                 * did not accept the feature". Both are counted and traced;
                 * neither is allowed to disappear silently. */
                bool implemented = (base == VN_GSO_TCPV4 || base == VN_GSO_TCPV6);
                bool offered = (base == VN_GSO_TCPV4 && host_tso4) ||
                               (base == VN_GSO_TCPV6 && host_tso6);
                if (!implemented) {
                    v->stats.tx_reject_unsupported++;
                    if (vn_trace_at(v->stats.tx_reject_unsupported))
                        VN_TRACE("[virtio-net] TX gso_type=%u not implemented "
                                 "by this device, passed through n=%llu\n",
                                 (unsigned)hdr.gso_type,
                                 (unsigned long long)v->stats.tx_reject_unsupported);
                } else if (!offered) {
                    /* The driver asked for a segmentation we did not offer.
                     * Passing the frame through untouched is the least
                     * surprising answer - the backend's own length check decides
                     * what happens to it - but it must not be silent. */
                    v->stats.tx_reject_unnegotiated++;
                    if (vn_trace_at(v->stats.tx_reject_unnegotiated))
                        VN_TRACE("[virtio-net] TX gso_type=%u not negotiated, "
                                 "passed through n=%llu\n",
                                 (unsigned)hdr.gso_type,
                                 (unsigned long long)v->stats.tx_reject_unnegotiated);
                } else {
                    NetTxSink sink;
                    VNSegCtx ctx;
                    VNSegReport report;
                    VNSegStatus st;

                    sink.v = v; sink.stopped = false; sink.frames = 0;
                    ctx.max_out_frame = MAX_ETH_FRAME;
                    ctx.scratch = v->tx_segment;
                    ctx.scratch_cap = MAX_ETH_FRAME;
                    /* Never split one super-packet across drains: the guest has
                     * already been told the whole thing was consumed. */
                    ctx.budget = emitted ? (budget > emitted ? budget - emitted : 0)
                                         : UINT32_MAX;
                    st = vn_tx_segment(frame, flen, &hdr, negotiated, &ctx,
                                       net_tx_emit, &sink, &report);
                    emitted += report.frames;
                    switch (st) {
                    case VN_SEG_OK:
                        v->stats.tx_segmented++;
                        segmented = true;
                        if (vn_trace_at(v->stats.tx_segmented))
                            VN_TRACE("[virtio-net] TX-TSO segmented n=%llu "
                                     "gso_type=%u gso_size=%u super=%u bytes "
                                     "-> %u frames (%llu bytes)\n",
                                     (unsigned long long)v->stats.tx_segmented,
                                     (unsigned)hdr.gso_type,
                                     (unsigned)hdr.gso_size, (unsigned)flen,
                                     (unsigned)report.frames,
                                     (unsigned long long)report.bytes);
                        break;
                    case VN_SEG_NOT_GSO:
                        break;
                    case VN_SEG_UNSUPPORTED:
                        v->stats.tx_reject_unsupported++;
                        if (vn_trace_at(v->stats.tx_reject_unsupported))
                            VN_TRACE("[virtio-net] TX gso_type=%u unsupported "
                                     "n=%llu (passed through)\n",
                                     (unsigned)hdr.gso_type,
                                     (unsigned long long)v->stats.tx_reject_unsupported);
                        break;
                    case VN_SEG_MALFORMED:
                        v->stats.tx_reject_malformed++;
                        if (vn_trace_at(v->stats.tx_reject_malformed))
                            VN_TRACE("[virtio-net] TX super-packet malformed "
                                     "gso_type=%u gso_size=%u len=%u n=%llu\n",
                                     (unsigned)hdr.gso_type,
                                     (unsigned)hdr.gso_size, (unsigned)flen,
                                     (unsigned long long)v->stats.tx_reject_malformed);
                        break;
                    case VN_SEG_BUDGET:
                        v->stats.tx_budget_exhausted++;
                        if (vn_trace_at(v->stats.tx_budget_exhausted))
                            VN_TRACE("[virtio-net] TX segment budget reached "
                                     "n=%llu, deferring super-packet to poll\n",
                                     (unsigned long long)v->stats.tx_budget_exhausted);
                        break;
                    case VN_SEG_STOPPED:
                        segmented = true;   /* partial: counted by the sink */
                        break;
                    }
                    if (st == VN_SEG_BUDGET) {
                        /* Leave this descriptor unconsumed so the next drain
                         * produces every segment. The used entry is not
                         * published for it either. */
                        v->tx_pending = true;
                        goto tx_done;
                    }
                }
            }

            if (!segmented) {
                /* Segmentation did not happen, so these bytes go to the backend
                 * as they are. If the checksum completion was deferred on the
                 * expectation of segmenting, it has to happen now - forwarding a
                 * frame that still carries a partial seed would hand the peer a
                 * bad transport checksum. */
                if (csum_requested && !csum_done) {
                    if (vn_tx_complete_csum(frame, flen, &hdr) ==
                        VN_TX_CSUM_COMPLETED)
                        v->stats.tx_csum_completed++;
                    else
                        v->stats.tx_reject_malformed++;
                }
                v->stats.tx_passthrough++;
                usernet_input(v->un, frame, flen);
                emitted++;
            }
        }

tx_used:
        v->last_avail[NET_QUEUE_TX]++;
        if (defer_completion && v->tx_deferred_n < VIRTQ_MAX) {
            /* Consumed and delivered; the used entry is intentionally held so
             * the descriptor keeps occupying its ring slot from the guest's
             * point of view. That occupancy is the backpressure the sending
             * socket needs; see VN_TX_COMPLETION_HOLD. */
            v->tx_deferred_ids[v->tx_deferred_n++] = hd;
            did = true;
            continue;
        }
        if (!have_used_start) {
            if (!used_ring_read_index(v, NET_QUEUE_TX, &used_start)) {
                v->status |= 64; return;
            }
            have_used_start = true;
        }
        if (used_n >= VIRTQ_MAX) {
            if (!used_ring_publish(v, NET_QUEUE_TX, used_start, used_n)) {
                v->status |= 64; return;
            }
            used_n = 0;
            have_used_start = false;
            if (!used_ring_read_index(v, NET_QUEUE_TX, &used_start)) {
                v->status |= 64; return;
            }
            have_used_start = true;
        }
        v->used_batch[used_n].id = hd;
        v->used_batch[used_n].len = 0;   /* TX writes nothing back */
        used_n++;
        did = true;
    }

tx_done:
    if (used_n) {
        if (!used_ring_publish(v, NET_QUEUE_TX, used_start, used_n)) {
            v->status |= 64; return;
        }
    }
    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- backend RX entry: queue a frame for delivery to the guest ---- */

/* Returns false when the software RX ring cannot take the frame: usernet uses
 * that as backpressure — TCP data is simply not emitted yet, so nothing is
 * lost. Fairness is applied here, at admission, because that is the only point
 * where the device still has a choice; once a frame is in the ring it will be
 * delivered. */
static bool net_deliver_frame(void *opaque, const uint8_t *buf, size_t len) {
    VirtIONet *v = opaque;
    VNFrameInfo info;
    VNFlowKey key;
    bool have_key, bulk;
    uint16_t used;

    if (len > MAX_ETH_FRAME) {
        /* Oversized for the ring. Reported honestly rather than counted as a
         * delivery; the current backend never produces one. */
        v->stats.rx_oversized++;
        return true;
    }
    used = net_rx_occupancy(v);
    if (used >= RX_RING_USABLE) {
        v->stats.rx_ring_full++;
        if (vn_trace_at(v->stats.rx_ring_full))
            VN_TRACE("[virtio-net] RX ring full n=%llu (occupancy %u/%u), "
                     "backend holds the data back\n",
                     (unsigned long long)v->stats.rx_ring_full,
                     (unsigned)used, (unsigned)RX_RING_USABLE);
        return false;
    }

    have_key = (vn_frame_parse(buf, (uint32_t)len, &info) == VN_PARSE_OK) &&
               vn_flow_key(buf, (uint32_t)len, &info, &key);
    /* A frame with no IP flow identity (ARP, or anything unparseable) goes
     * through the same admission call with an empty key, so it is admitted on
     * room alone and still counted as control traffic rather than silently
     * skipping the accounting. */
    if (!have_key) memset(&key, 0, sizeof(key));
    bulk = have_key && vn_frame_is_bulk(&info);

    if (!vn_fairness_admit(&v->fair, &key, bulk, RX_RING_USABLE, used)) {
        /* This flow already holds its share of a contended ring. Refusing here
         * is what keeps a second flow (and control traffic, which bypasses the
         * cap) able to make progress. The adapter retries delivery from its
         * bounded deferred queue; TCP recovery handles any overflow loss. */
        v->stats.rx_fair_refused++;
        if (vn_trace_at(v->stats.rx_fair_refused))
            VN_TRACE("[virtio-net] RX fair share reached n=%llu proto=%u "
                     "ports %u->%u occupancy %u/%u\n",
                     (unsigned long long)v->stats.rx_fair_refused,
                     (unsigned)info.proto, (unsigned)info.sport,
                     (unsigned)info.dport,
                     (unsigned)used, (unsigned)RX_RING_USABLE);
        return false;
    }

    int slot = v->rx_tail;
    v->rx_tail = (v->rx_tail + 1) & (RX_RING_SIZE - 1);

    memset(v->rx_buf[slot], 0, NET_HDR_LEN);          /* zero virtio_net_hdr */
    v->rx_buf[slot][10] = 1;                           /* num_buffers = 1 (LE) */
    memcpy(v->rx_buf[slot] + NET_HDR_LEN, buf, len);
    v->rx_len[slot] = NET_HDR_LEN + (uint32_t)len;
    v->rx_flow_known[slot] = have_key;
    if (have_key) v->rx_flow[slot] = key;
    v->stats.rx_frames++;
    return true;
}

/* Called from machine_tick() on the host-IO poll cadence. */
void virtio_net_poll(VirtIONet *v) {
    /* Slide the held-completion window forward first: publishing the overflow
     * frees ring slots for the guest's next burst and is what paces a bulk
     * sender's socket without ever holding its data back. */
    net_flush_tx_completions(v, false, false);
    usernet_poll(v->un);
    net_flush_rx(v);
    /* Finish a TX drain that a segment budget cut short, and drain whatever a
     * QueueNotify marked pending. The guest will not notify again for
     * descriptors it already made available, so the poll is what guarantees
     * they are neither stranded nor, when the ring produced nothing new this
     * tick, left waiting behind the held-completion window. */
    uint64_t consumed_before = v->stats.tx_frames;
    uint32_t held_before = v->tx_deferred_n;
    if (v->tx_pending) net_tx_process(v, VN_TX_SEGMENT_BUDGET);
    /* A control-only stream must not strand a previously consumed bulk tail.
     * Release at least its oldest completion on each such tick. New bulk work
     * keeps the count window; an entirely idle tick still drains the tail. */
    net_flush_tx_completions(v, v->stats.tx_frames == consumed_before,
                             v->tx_deferred_n == held_before);
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
            if (v32 == NET_QUEUE_TX) {
                /* TX is deliberately NOT drained inside the notify. The notify
                 * runs inside the guest's transmit syscall; draining here would
                 * consume, deliver and acknowledge the frames before the
                 * sending application returns from write(), so the guest's
                 * socket buffers never fill and the application never observes
                 * backpressure. A bulk sender could then stream an entire
                 * transfer inside one event-loop turn, starving every other
                 * flow in the guest for its whole duration. Marking pending and
                 * draining from virtio_net_poll() at the coordinator cadence
                 * instead keeps unacknowledged and queued bytes charged to the
                 * sending socket: the kernel paces the application (queue stop,
                 * then EAGAIN once its send buffer fills), its event loop keeps
                 * serving other flows, and throughput is unchanged because the
                 * poll drain stays far ahead of the backend's own rate. The
                 * guest never waits for a notify it has no reason to send:
                 * tx_pending is exactly what virtio_net_poll() finishes. */
                v->tx_pending = true;
            }
            else if (v32 == NET_QUEUE_RX) net_flush_rx(v); /* guest added free buffers */
            break;
        case 0x064:
            v->isr &= ~v32;
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:
            if (v32 == 0) { net_reset(v); }
            else {
                uint32_t before = v->status;
                v->status = v32;
                /* Negotiation is settled when the driver accepts our feature
                 * word; the offload decisions below read drv_feat from here on.
                 * Tracing both edges is what proves a real guest took the
                 * negotiated path instead of the legacy one. */
                if (!(before & VIRTIO_NET_S_FEATURES_OK) &&
                    (v32 & VIRTIO_NET_S_FEATURES_OK))
                    net_trace_negotiation(v, "FEATURES_OK");
                if (!(before & VIRTIO_NET_S_DRIVER_OK) &&
                    (v32 & VIRTIO_NET_S_DRIVER_OK))
                    net_trace_negotiation(v, "DRIVER_OK");
            }
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

    /* Offload working storage. Allocated up front rather than on first GSO
     * use: a failure here must be a create failure, not an allocation attempt
     * on the coordinator's data path. Roughly 131 KiB per machine
     * (2 x 65601 for the super-packet buffers, 1518 for one segment, plus the
     * used-ring and RX descriptor snapshots). */
    v->tx_gather = malloc(NET_TX_GATHER_BYTES);
    v->tx_segment = malloc(MAX_ETH_FRAME);
    v->rx_aggregate = malloc(NET_RX_AGGREGATE_BYTES);
    v->used_batch = calloc(VIRTQ_MAX, sizeof(*v->used_batch));
    v->rx_desc = calloc(VIRTQ_MAX, sizeof(*v->rx_desc));
    if (!v->tx_gather || !v->tx_segment || !v->rx_aggregate ||
        !v->used_batch || !v->rx_desc) {
        free(v->tx_gather); free(v->tx_segment); free(v->rx_aggregate);
        free(v->used_batch); free(v->rx_desc);
        free(v);
        return NULL;
    }
    vn_fairness_init(&v->fair);
    vn_stats_init(&v->stats);

    /* Enable guest dual-stack networking through the internal configuration.
     * Public ABI2 and caller-owned configuration layouts remain unchanged. */
    UserNetConfig un_cfg;
    memset(&un_cfg, 0, sizeof(un_cfg));
    un_cfg.struct_size = sizeof(un_cfg);
    un_cfg.abi = USERNET_CFG_ABI;
    un_cfg.flags = USERNET_CFG_F_IPV6;
    un_cfg.dns_server_v4 = m->dns_server;
    memcpy(un_cfg.guest_mac, v->mac, sizeof(un_cfg.guest_mac));
    v->un = usernet_new_with_config(net_deliver_frame, v, &un_cfg);
    if (!v->un) {
        free(v->tx_gather); free(v->tx_segment); free(v->rx_aggregate);
        free(v->used_batch); free(v->rx_desc);
        free(v);
        return NULL;
    }

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
            free(v->tx_gather); free(v->tx_segment); free(v->rx_aggregate);
            free(v->used_batch); free(v->rx_desc);
            free(v);
            return NULL;
        }
    }

    machine_add_device(m, 0x0a000000, 0x200, net_read, net_write, v, "virtio-net");
    m->net = v;
    fprintf(stderr, "[virtio-net] MAC %02x:%02x:%02x:%02x:%02x:%02x, "
            "guest 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3\n",
            v->mac[0], v->mac[1], v->mac[2], v->mac[3], v->mac[4], v->mac[5]);
    fprintf(stderr, "[virtio-net] offered features 0x%08x%08x "
            "(csum=%d guest_csum=%d host_tso4=%d host_tso6=%d "
            "guest_tso4=%d guest_tso6=%d rx_gso_advertised=%d)\n",
            (unsigned)(NET_FEATURES >> 32), (unsigned)(NET_FEATURES & 0xffffffffu),
            (int)((NET_FEATURES & VN_F_CSUM) != 0),
            (int)((NET_FEATURES & VN_F_GUEST_CSUM) != 0),
            (int)((NET_FEATURES & VN_F_HOST_TSO4) != 0),
            (int)((NET_FEATURES & VN_F_HOST_TSO6) != 0),
            (int)((NET_FEATURES & VN_F_GUEST_TSO4) != 0),
            (int)((NET_FEATURES & VN_F_GUEST_TSO6) != 0),
            (int)VN_ADVERTISE_RX_GSO);
    return v;
}

/* Full teardown after the machine is quiet: backend flows and listeners
 * first, then the device itself. */
void virtio_net_destroy(VirtIONet *v) {
    if (!v) return;
    /* Last chance to leave an honest record of what the negotiated paths did. */
    net_trace_stats(v, "destroy");
    usernet_destroy(v->un);
    v->un = NULL;
    free(v->tx_gather);      v->tx_gather = NULL;
    free(v->tx_segment);     v->tx_segment = NULL;
    free(v->rx_aggregate);   v->rx_aggregate = NULL;
    free(v->used_batch);     v->used_batch = NULL;
    free(v->rx_desc);        v->rx_desc = NULL;
    free(v);
}

/* Accessor for the live-management ABI operations (port-forward add/remove,
 * diagnostics). The backend stays opaque to the bridge. */
UserNet *virtio_net_usernet(VirtIONet *v) { return v ? v->un : NULL; }

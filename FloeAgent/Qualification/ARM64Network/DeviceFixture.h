/* SPDX-License-Identifier: MPL-2.0 */
/* Real guest-RAM and virtio-MMIO fixture for the networking component host.
 * Includes production bridge/device code; omit those3objects at link time.
 * No Linux boot, App, Simulator or physical device is involved. */
#include "../../ThirdParty/ARM64EMU/Bridge/runtime.c"
#include "../../ThirdParty/ARM64EMU/Bridge/parallel_runtime.c"
#include "../../ThirdParty/ARM64EMU/Source/src/devices/virtio_net.c"

#include <assert.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifdef NDEBUG
#error "NIC offload qualification requires assertions"
#endif

static unsigned checks;
static const char *current_case = "";
#define CASE(name) do { current_case = (name); } while (0)
#define CHECK(x) do {                                                     \
    if (!(x)) {                                                           \
        fprintf(stderr, "FAIL [%s] %s:%d %s\n", current_case, __FILE__,   \
                __LINE__, #x);                                            \
        exit(1);                                                          \
    }                                                                     \
    checks++;                                                             \
} while (0)
#define DONE() do { printf("PASS %s\n", current_case); } while (0)

/* The oracle and the Layer A cases need the macros above, so they come last. */
#include "OffloadOracle.h"
#include "OffloadUnitTests.h"

/* =================================================================== *
 * Layer B harness: a guest-side split virtqueue in real guest RAM      *
 * =================================================================== */

#define NET_MMIO       0x0a000000ULL
#define MMIO_DEVFEAT   0x010
#define MMIO_DEVSEL    0x014
#define MMIO_DRVFEAT   0x020
#define MMIO_DRVSEL    0x024
#define MMIO_QSEL      0x030
#define MMIO_QNUMMAX   0x034
#define MMIO_QNUM      0x038
#define MMIO_QREADY    0x044
#define MMIO_QNOTIFY   0x050
#define MMIO_ISR       0x060
#define MMIO_ISRACK    0x064
#define MMIO_STATUS    0x070
#define MMIO_QDESC_LO  0x080
#define MMIO_QDESC_HI  0x084
#define MMIO_QAVAIL_LO 0x090
#define MMIO_QAVAIL_HI 0x094
#define MMIO_QUSED_LO  0x0a0
#define MMIO_QUSED_HI  0x0a4
#define MMIO_CFG_MAC   0x100

#define ST_ACK          1u
#define ST_DRIVER       2u
#define ST_DRIVER_OK    4u
#define ST_FEATURES_OK  8u
#define ST_NEEDS_RESET  0x40u

#define Q_RX 0
#define Q_TX 1

/* Guest RAM layout, all inside the 16 MiB the session asks for. */
#define G_RX_DESC   0x00800000ULL
#define G_RX_AVAIL  0x00801000ULL
#define G_RX_USED   0x00802000ULL
#define G_TX_DESC   0x00803000ULL
#define G_TX_AVAIL  0x00804000ULL
#define G_TX_USED   0x00805000ULL
#define G_RX_POOL   0x00810000ULL
#define G_RX_POOL_END 0x00A00000ULL
#define G_TX_POOL   0x00A00000ULL
#define TX_SLOT     66048ULL

/* Linux big-packet RX buffer shape: one descriptor for the header, then
 * MAX_SKB_FRAGS pages. This is what a real guest posts once GUEST_TSO is
 * negotiated, so the device must size its aggregates against it. */
#define BIG_DESCS      18
#define BIG_PAGE       4096
#define BIG_HDR_PAD    24
#define BIG_BUF_BYTES  (BIG_HDR_PAD + (uint64_t)BIG_DESCS * BIG_PAGE)
#define SMALL_DESCS    1
#define SMALL_SIZE     (NET_HDR_LEN + VN_MAX_ETH_FRAME)

typedef struct {
    Machine *m;
    int      q;
    uint64_t desc, avail, used;
    uint16_t num;
    uint16_t avail_idx;
    uint16_t used_seen;
} GuestVQ;

typedef struct {
    uint16_t head;        /* descriptor chain head published to the device */
    uint64_t buf;         /* guest PA of the first byte of this buffer */
    uint32_t capacity;    /* total writable bytes across the chain */
} RxBuf;

static RxBuf rxbufs[512];
static uint32_t rxbuf_n;

static floe_ae_handle handle;
static Machine *m;
static VirtIONet *v;
static GuestVQ rq, tq;

static uint64_t pa(uint64_t off) { return RAM_BASE + off; }

static void gw(uint64_t p, const void *src, uint32_t len) {
    phys_write_blk(m, p, src, len);
    assert(machine_bus_status(m) == BUS_OK);
}
static void gr(uint64_t p, void *dst, uint32_t len) {
    phys_read_blk(m, p, dst, len);
    assert(machine_bus_status(m) == BUS_OK);
}
static void gw16(uint64_t p, uint16_t val) {
    uint8_t b[2] = { (uint8_t)val, (uint8_t)(val >> 8) };
    gw(p, b, 2);
}
static uint16_t gr16(uint64_t p) {
    uint8_t b[2]; gr(p, b, 2);
    return (uint16_t)(b[0] | (b[1] << 8));
}
static uint32_t gr32(uint64_t p) {
    uint8_t b[4]; gr(p, b, 4);
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static void mmio_w(uint32_t off, uint32_t val) {
    phys_write(m, NET_MMIO + off, 4, val);
    assert(machine_bus_status(m) == BUS_OK);
}
static uint32_t mmio_r(uint32_t off) {
    uint64_t val = phys_read(m, NET_MMIO + off, 4);
    assert(machine_bus_status(m) == BUS_OK);
    return (uint32_t)val;
}

/* Point an Ethernet frame from the guest at the gateway. usernet learns the
 * guest MAC from the frame's source address, so TX frames must carry it. */
static void eth_guest_to_host(uint8_t *f) {
    memcpy(f, MAC_HOST, 6);
    memcpy(f + 6, MAC_GUEST, 6);
}

static void vq_setup(GuestVQ *q, int idx, uint64_t desc, uint64_t avail,
                     uint64_t used, uint16_t num) {
    q->m = m; q->q = idx; q->desc = desc; q->avail = avail; q->used = used;
    q->num = num; q->avail_idx = 0; q->used_seen = 0;
    mmio_w(MMIO_QSEL, (uint32_t)idx);
    CHECK(mmio_r(MMIO_QNUMMAX) == QUEUE_NUM_MAX);
    mmio_w(MMIO_QNUM, num);
    mmio_w(MMIO_QDESC_LO, (uint32_t)pa(desc));
    mmio_w(MMIO_QDESC_HI, (uint32_t)(pa(desc) >> 32));
    mmio_w(MMIO_QAVAIL_LO, (uint32_t)pa(avail));
    mmio_w(MMIO_QAVAIL_HI, (uint32_t)(pa(avail) >> 32));
    mmio_w(MMIO_QUSED_LO, (uint32_t)pa(used));
    mmio_w(MMIO_QUSED_HI, (uint32_t)(pa(used) >> 32));
    gw16(pa(avail), 0);
    gw16(pa(avail) + 2, 0);
    gw16(pa(used), 0);
    gw16(pa(used) + 2, 0);
    mmio_w(MMIO_QREADY, 1);
    CHECK(mmio_r(MMIO_QREADY) == 1);
}

static void vq_set_desc(GuestVQ *q, uint16_t i, uint64_t addr, uint32_t len,
                        uint16_t flags, uint16_t next) {
    uint8_t b[16];
    uint64_t d = pa(q->desc) + (uint64_t)i * 16;
    for (int k = 0; k < 8; k++) b[k] = (uint8_t)(addr >> (8 * k));
    for (int k = 0; k < 4; k++) b[8 + k] = (uint8_t)(len >> (8 * k));
    b[12] = (uint8_t)flags;       b[13] = (uint8_t)(flags >> 8);
    b[14] = (uint8_t)next;        b[15] = (uint8_t)(next >> 8);
    gw(d, b, 16);
}

static void vq_push(GuestVQ *q, uint16_t head) {
    uint16_t slot = (uint16_t)(q->avail_idx % q->num);
    gw16(pa(q->avail) + 4 + (uint64_t)slot * 2, head);
    q->avail_idx++;
    /* The index is published last; a real driver inserts a barrier here. */
    gw16(pa(q->avail) + 2, q->avail_idx);
}

static uint32_t vq_used_pending(GuestVQ *q) {
    return (uint32_t)(uint16_t)(gr16(pa(q->used) + 2) - q->used_seen);
}

static void vq_used_next(GuestVQ *q, uint16_t *id, uint32_t *len) {
    uint16_t idx = gr16(pa(q->used) + 2);
    uint16_t slot;
    assert((uint16_t)(idx - q->used_seen) != 0);
    slot = (uint16_t)(q->used_seen % q->num);
    *id  = (uint16_t)gr32(pa(q->used) + 4 + (uint64_t)slot * 8);
    *len = gr32(pa(q->used) + 4 + (uint64_t)slot * 8 + 4);
    q->used_seen++;
}

/* Consume and discard everything the device has published. */
static uint32_t drain_used(GuestVQ *q) {
    uint32_t n = 0;
    while (vq_used_pending(q)) {
        uint16_t id; uint32_t len;
        vq_used_next(q, &id, &len);
        n++;
    }
    return n;
}

static void rx_pool_reset(void) {
    memset(rxbufs, 0, sizeof(rxbufs));
    rxbuf_n = 0;
}

/* Post `count` RX buffers. big=true reproduces Linux's big-packet chain;
 * big=false is the small single-descriptor buffer a non-GSO guest posts. */
static void post_rx(uint32_t count, bool big) {
    uint16_t descs = big ? BIG_DESCS : SMALL_DESCS;
    uint64_t off = G_RX_POOL;
    uint16_t d = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint16_t head = d;
        uint32_t cap = 0;
        assert(d + descs <= QUEUE_NUM_MAX);
        for (uint16_t k = 0; k < descs; k++) {
            uint32_t size;
            uint16_t flags = VIRTQ_DESC_F_WRITE;
            uint16_t next = (uint16_t)(d + 1);
            uint64_t addr;
            if (big) {
                if (k == 0)      { size = NET_HDR_LEN; addr = off; }
                else if (k == 1) { size = BIG_PAGE - BIG_HDR_PAD;
                                   addr = off + BIG_HDR_PAD; }
                else             { size = BIG_PAGE;
                                   addr = off + BIG_HDR_PAD +
                                          (uint64_t)(k - 1) * BIG_PAGE; }
            } else {
                size = SMALL_SIZE; addr = off;
            }
            if (k + 1 == descs) next = 0; else flags |= VIRTQ_DESC_F_NEXT;
            vq_set_desc(&rq, d, pa(addr), size, flags, next);
            cap += size;
            d++;
        }
        /* post_rx() restarts at descriptor 0 and at the pool base, so a head
         * can legitimately be recorded twice; keep the first mapping, which
         * points at the same buffer either way. */
        {
            bool known = false;
            for (uint32_t i = 0; i < rxbuf_n; i++)
                if (rxbufs[i].head == head) { known = true; break; }
            if (!known) {
                assert(rxbuf_n < sizeof(rxbufs) / sizeof(rxbufs[0]));
                rxbufs[rxbuf_n].head = head;
                rxbufs[rxbuf_n].buf = pa(off);
                rxbufs[rxbuf_n].capacity = cap;
                rxbuf_n++;
            }
        }
        vq_push(&rq, head);
        off += big ? BIG_BUF_BYTES : (uint64_t)SMALL_SIZE;
    }
    assert(off - G_RX_POOL < (G_RX_POOL_END - G_RX_POOL));
    mmio_w(MMIO_QNOTIFY, Q_RX);
}

/* Post one RX buffer as a chain with caller-chosen descriptor sizes, so a test
 * can put a descriptor boundary anywhere it likes - including inside the
 * 12-byte virtio_net_hdr. Returns the chain head. */
static uint16_t post_rx_chain(uint16_t first_desc, uint64_t off,
                              const uint32_t *sizes, uint32_t ndescs) {
    uint64_t at = off;
    uint16_t d = first_desc;
    uint32_t cap = 0;
    for (uint32_t k = 0; k < ndescs; k++) {
        uint16_t flags = VIRTQ_DESC_F_WRITE;
        uint16_t next = (uint16_t)(d + 1);
        if (k + 1 == ndescs) next = 0; else flags |= VIRTQ_DESC_F_NEXT;
        vq_set_desc(&rq, d, pa(at), sizes[k], flags, next);
        cap += sizes[k];
        at += sizes[k];
        d++;
    }
    assert(first_desc + ndescs <= QUEUE_NUM_MAX);
    assert(rxbuf_n < sizeof(rxbufs) / sizeof(rxbufs[0]));
    rxbufs[rxbuf_n].head = first_desc;
    rxbufs[rxbuf_n].buf = pa(off);
    rxbufs[rxbuf_n].capacity = cap;
    rxbuf_n++;
    vq_push(&rq, first_desc);
    mmio_w(MMIO_QNOTIFY, Q_RX);
    return first_desc;
}

/* Raw bytes of one descriptor, read straight out of guest RAM. `want` caps how
 * much is copied out; the descriptor itself may be much larger. Returns the
 * number of bytes actually read. */
static uint32_t read_desc_raw(uint16_t idx, uint8_t *out, uint32_t want) {
    uint8_t d[16];
    uint64_t gpa = 0;
    uint32_t dlen, n;
    gr(pa(rq.desc) + (uint64_t)idx * 16, d, 16);
    for (int k = 0; k < 8; k++) gpa |= (uint64_t)d[k] << (8 * k);
    dlen = (uint32_t)d[8] | ((uint32_t)d[9] << 8) |
           ((uint32_t)d[10] << 16) | ((uint32_t)d[11] << 24);
    n = dlen < want ? dlen : want;
    gr(gpa, out, n);
    return n;
}

static uint64_t rx_buffer_for_head(uint16_t head) {
    for (uint32_t i = 0; i < rxbuf_n; i++)
        if (rxbufs[i].head == head) return rxbufs[i].buf;
    fprintf(stderr, "FAIL delivered descriptor head %u the guest never posted\n",
            (unsigned)head);
    exit(1);
}

/* Read one delivered frame (virtio_net_hdr + Ethernet frame) back out of guest
 * RAM by walking the same descriptor chain the device wrote into.
 *
 * A flat read of the buffer base would be wrong for big-packet buffers: Linux
 * gives the header its own descriptor and starts the data descriptor after
 * sizeof(struct padded_vnet_hdr), so bytes [12,24) of the first page are padding
 * the device never touches. Walking the chain reproduces exactly what the guest
 * driver would assemble. */
static uint32_t read_delivered(uint16_t head, uint32_t used_len, uint8_t *out,
                               uint32_t cap) {
    uint32_t at = 0;
    uint16_t idx = head;

    (void)rx_buffer_for_head(head);      /* the head must be one we posted */
    assert(used_len <= cap);
    for (uint32_t n = 0; n < rq.num && at < used_len; n++) {
        uint8_t d[16];
        uint64_t gpa = 0;
        uint32_t dlen, chunk;
        uint16_t flags, next;
        gr(pa(rq.desc) + (uint64_t)idx * 16, d, 16);
        for (int k = 0; k < 8; k++) gpa |= (uint64_t)d[k] << (8 * k);
        dlen  = (uint32_t)d[8] | ((uint32_t)d[9] << 8) |
                ((uint32_t)d[10] << 16) | ((uint32_t)d[11] << 24);
        flags = (uint16_t)(d[12] | (d[13] << 8));
        next  = (uint16_t)(d[14] | (d[15] << 8));
        if (flags & VIRTQ_DESC_F_WRITE) {
            chunk = used_len - at;
            if (chunk > dlen) chunk = dlen;
            gr(gpa, out + at, chunk);
            at += chunk;
        }
        if (!(flags & VIRTQ_DESC_F_NEXT)) break;
        idx = next;
    }
    /* The device must have filled every byte it claimed in the used ring. */
    assert(at == used_len);
    return at;
}

/* Program the device through the real virtio-mmio registers up to DRIVER_OK.
 * Returns the feature word the device offered. */
static uint64_t device_negotiate(uint64_t want) {
    uint32_t lo, hi;
    uint64_t offered;

    mmio_w(MMIO_STATUS, 0);                     /* device reset */
    CHECK(mmio_r(MMIO_STATUS) == 0);
    mmio_w(MMIO_STATUS, ST_ACK);
    mmio_w(MMIO_STATUS, ST_ACK | ST_DRIVER);

    mmio_w(MMIO_DEVSEL, 0); lo = mmio_r(MMIO_DEVFEAT);
    mmio_w(MMIO_DEVSEL, 1); hi = mmio_r(MMIO_DEVFEAT);
    offered = (uint64_t)lo | ((uint64_t)hi << 32);

    CHECK((want & ~offered) == 0);          /* never accept what is not offered */
    mmio_w(MMIO_DRVSEL, 0); mmio_w(MMIO_DRVFEAT, (uint32_t)want);
    mmio_w(MMIO_DRVSEL, 1); mmio_w(MMIO_DRVFEAT, (uint32_t)(want >> 32));

    mmio_w(MMIO_STATUS, ST_ACK | ST_DRIVER | ST_FEATURES_OK);
    CHECK((mmio_r(MMIO_STATUS) & ST_FEATURES_OK) != 0);

    vq_setup(&rq, Q_RX, G_RX_DESC, G_RX_AVAIL, G_RX_USED, QUEUE_NUM_MAX);
    vq_setup(&tq, Q_TX, G_TX_DESC, G_TX_AVAIL, G_TX_USED, QUEUE_NUM_MAX);
    rx_pool_reset();
    drain_used(&rq);
    drain_used(&tq);

    mmio_w(MMIO_STATUS, ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK);
    CHECK((mmio_r(MMIO_STATUS) & ST_DRIVER_OK) != 0);
    return offered;
}

/* ---- TX helpers ---- */

static uint64_t tx_slot_pa(int slot) {
    return pa(G_TX_POOL + (uint64_t)slot * TX_SLOT);
}

/* Write hdr+frame into a TX slot and publish it. nfrags > 1 splits the buffer
 * across several descriptors to exercise the gather path. */
static void post_tx(int slot, const uint8_t *hdr12, const uint8_t *frame,
                    uint32_t flen, uint32_t nfrags) {
    uint64_t base = tx_slot_pa(slot);
    uint16_t head = (uint16_t)(slot * 8);
    uint32_t total = NET_HDR_LEN + flen;
    uint32_t per = nfrags ? (total + nfrags - 1) / nfrags : total;
    uint32_t at = 0;
    uint16_t d = head;

    gw(base, hdr12, NET_HDR_LEN);
    if (flen) gw(base + NET_HDR_LEN, frame, flen);

    while (at < total) {
        uint32_t chunk = total - at;
        uint16_t flags = 0;
        if (chunk > per) chunk = per;
        if (at + chunk < total) flags |= VIRTQ_DESC_F_NEXT;
        vq_set_desc(&tq, d, base + at, chunk, flags, (uint16_t)(d + 1));
        at += chunk;
        d++;
    }
    vq_push(&tq, head);
    mmio_w(MMIO_QNOTIFY, Q_TX);
}

static void hdr_of(uint8_t *raw, uint8_t gso_type, uint16_t gso_size,
                   bool needs_csum, uint16_t csum_start, uint16_t csum_offset) {
    VNNetHdrFields h;
    memset(&h, 0, sizeof(h));
    h.gso_type = gso_type;
    h.gso_size = gso_size;
    h.hdr_len = 54;
    if (needs_csum) {
        h.flags = VN_HDR_F_NEEDS_CSUM;
        h.csum_start = csum_start;
        h.csum_offset = csum_offset;
    }
    vn_hdr_write(raw, &h);
}

/* Poll the device the way machine_tick does. */
static void dev_poll(void) { virtio_net_poll(v); }

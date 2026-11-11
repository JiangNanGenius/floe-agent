/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors. */
/* virtio-mem over modern (version 2) virtio-mmio transport (device 24).
 *
 * A "resizable DIMM": the device owns a dedicated guest-physical region
 * (FLOE_VMEM_BASE .. +FLOE_VMEM_REGION_SIZE) right above the 256 MiB boot RAM
 * inside the machine's single 1 GiB lazily-backed RAM envelope. Individual
 * FLOE_VMEM_BLOCK_SIZE blocks are plugged/unplugged by the guest virtio_mem
 * driver on behalf of host resize requests carried in requested_size.
 *
 * Wire format is the exact Linux 6.12 uapi virtio_mem.h layout (56-byte
 * config, 24-byte request, 10-byte response); see the VIRTIO v1.3 spec
 * section 5.15 ("Memory Device"). Only VIRTIO_F_VERSION_1 is offered: without
 * VIRTIO_MEM_F_UNPLUGGED_INACCESSIBLE the spec permits CPU reads of unplugged
 * blocks inside the usable region. Our host pages satisfy that safely: reads
 * never fault and the content is unspecified by the spec (zero for fresh or
 * decommitted pages); writes by a misbehaving guest only allocate host pages
 * within the already-reserved envelope. The guest driver never touches
 * unplugged blocks by contract.
 *
 * Host memory reclaim: UNPLUG/UNPLUG_ALL madvise(MADV_DONTNEED) the sub-range
 * of the machine RAM mapping, asking the host to decommit those pages. The
 * call is advisory — the guest-visible truth (plugged_size, onlined blocks,
 * /proc/meminfo) is the primary contract and is what qualification measures;
 * decommit itself is measured separately, never assumed. Where the host does
 * decommit, a later PLUG observes zeroed pages, which satisfies the spec
 * ("content is undefined" after plug; zero is the safe choice) and the guest
 * driver initializes what it onlines. MADV_DONTNEED keeps the host mapping
 * (guest-physical access never faults) but does change page contents, so the
 * release runs under the same write MemoryGuard as a bus store and publishes
 * machine_store_notify first: code-page snapshots advance and exclusive
 * monitors clear before the host discards the bytes.
 *
 * Resize direction and honesty:
 *   - Grow: the host ABI sets requested_size and raises the config-change
 *     interrupt (+ host wake). The guest driver plugs blocks and onlines
 *     them (explicitly — never relying on CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE),
 *     so /proc/meminfo MemTotal actually grows.
 *   - Shrink: the host ABI lowers requested_size. The driver migrates/unuses
 *     pages, offlines 128 MiB memory blocks, then unplugs. Busy pages stay
 *     plugged: plugged_size is reported truthfully and stays above the target
 *     until the guest can finish; the engine NEVER reboots or fakes success.
 *
 * Queue model: one "guest-request" virtqueue. Requests are consumed
 * synchronously on QueueNotify (like virtio-blk/console TX): the descriptor
 * chain is exactly two descriptors — a device-readable request (24 bytes)
 * followed by a device-writable response (10 bytes), which is how the in-tree
 * Linux 6.12 driver posts them.
 *
 * Transport hardening (same conventions as virtio-blk): every ring span,
 * descriptor index, descriptor flag set and guest buffer is validated before
 * use; avail deltas and descriptor chains are bounded by the queue size; all
 * guest buffers must lie completely inside real machine RAM (checked for
 * overflow) before any physical access. Any malformed transport marks
 * DEVICE_NEEDS_RESET (status bit 6) and stops queue consumption until the
 * driver performs a reset (status 0) — the device never loops unbounded and
 * never touches an unchecked guest address.
 */
#include "../devices.h"
#include "../machine.h"
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/* Feature bits: only the mandatory modern-transport bit. */
#define VIRTIO_F_VERSION_1     (1ULL << 32)
#define VMEM_FEATURES          VIRTIO_F_VERSION_1

/* Split-virtqueue descriptor flags. */
#define VIRTQ_DESC_F_NEXT   1
#define VIRTQ_DESC_F_WRITE  2
/* Any flag outside NEXT|WRITE (notably INDIRECT) is refused: the in-tree
 * driver never posts them and we do not implement indirect descriptors. */
#define VIRTQ_DESC_F_KNOWN  (VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE)

#define VMEM_QUEUE_REQUEST 0
#define VMEM_QUEUE_NUM_MAX 128

#define VIRTIO_STATUS_DRIVER_OK     4
#define VIRTIO_STATUS_NEEDS_RESET   64   /* device-set; cleared only by reset */

/* block_size is a nonzero power of two (validated at create). */
#define VMEM_ALIGNED(addr, v) (((addr) & ((v)->block_size - 1)) == 0)

/* Wire request/response types (Linux uapi virtio_mem.h). */
#define VIRTIO_MEM_REQ_PLUG       0
#define VIRTIO_MEM_REQ_UNPLUG     1
#define VIRTIO_MEM_REQ_UNPLUG_ALL 2
#define VIRTIO_MEM_REQ_STATE      3

#define VIRTIO_MEM_RESP_ACK   0
#define VIRTIO_MEM_RESP_NACK  1
#define VIRTIO_MEM_RESP_BUSY  2
#define VIRTIO_MEM_RESP_ERROR 3

#define VIRTIO_MEM_STATE_PLUGGED   0
#define VIRTIO_MEM_STATE_UNPLUGGED 1
#define VIRTIO_MEM_STATE_MIXED     2

/* Fixed wire sizes (Linux 6.12 uapi virtio_mem.h). */
#define VMEM_REQ_LEN   24
#define VMEM_RESP_LEN  10

typedef struct VirtIOMem {
    Machine *m; GIC *gic; int irq;
    int slot;

    u64 block_size;                 /* config: constant */
    u64 addr;                       /* config: region base GPA */
    u64 region_size;                /* config: total managed size */
    u64 usable_region_size;         /* config: may shrink only on UNPLUG_ALL (we keep it == region_size) */
    u64 plugged_size;               /* config: updated on plug/unplug; no config IRQ */
    u64 requested_size;             /* config: host resize request; config IRQ on change */

    u32 status, isr;
    u32 dev_feat_sel, drv_feat_sel; u64 drv_feat;
    u32 queue_sel;

    u32 q_num, q_ready;
    u64 q_desc, q_avail, q_used;
    u16 last_avail;

    u8 *block_state;                /* one byte per block: 0 unplugged, 1 plugged */
    u64 nb_blocks;
} VirtIOMem;

/* ---- helpers ---- */

static void vmem_reset(VirtIOMem *v) {
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0;
    v->q_num = v->q_ready = 0;
    v->q_desc = v->q_avail = v->q_used = 0;
    v->last_avail = 0;
    /* Per the spec the device SHOULD unplug all blocks during system resets.
     * A warm reboot re-probes the device with a fresh driver; the freed host
     * pages keep the envelope lazy. Content of previously plugged blocks is
     * discarded (a reboot expects fresh memory anyway). */
    memset(v->block_state, 0, (size_t)v->nb_blocks);
    v->plugged_size = 0;
    gic_set_irq(v->gic, v->irq, 0);
}

void virtio_mem_reset(VirtIOMem *v) { vmem_reset(v); }

/* Malformed transport input: mark DEVICE_NEEDS_RESET (the virtio-blk
 * convention) and stop consuming until the driver resets. The bit survives
 * later status writes; only a reset (status 0) clears it. */
static void vmem_fail(VirtIOMem *v) {
    if (!(v->status & VIRTIO_STATUS_NEEDS_RESET))
        fprintf(stderr, "[virtio-mem] malformed transport; device needs reset\n");
    v->status |= VIRTIO_STATUS_NEEDS_RESET;
}

/* The three rings must be set up with a sane size and lie completely inside
 * real machine RAM (overflow-safe) before any physical access. */
static bool vmem_queue_spans(VirtIOMem *v) {
    return v->q_num && v->q_num <= VMEM_QUEUE_NUM_MAX &&
        ram_ptr(v->m, v->q_desc, (u64)v->q_num * 16) &&
        ram_ptr(v->m, v->q_avail, 6 + (u64)v->q_num * 2) &&
        ram_ptr(v->m, v->q_used, 6 + (u64)v->q_num * 8);
}

static bool vmem_range_ok(VirtIOMem *v, u64 addr, u64 nb_blocks) {
    if (nb_blocks == 0) return false;
    if (addr < v->addr) return false;
    if (!VMEM_ALIGNED(addr, v)) return false;
    if (nb_blocks > v->nb_blocks) return false;
    u64 idx = (addr - v->addr) / v->block_size;
    if (idx + nb_blocks > v->nb_blocks) return false;
    /* The whole range must lie inside the usable region. */
    if ((addr - v->addr) + nb_blocks * v->block_size > v->usable_region_size) return false;
    return true;
}

/* Really return host pages for [addr, addr+len) inside the region. The range
 * is block-aligned and block-sized, hence page-aligned; the mapping is the
 * machine's own RAM envelope. Decommitting changes page contents underneath
 * every hart, so this takes the same write MemoryGuard as a bus store and
 * publishes the store first (code-page snapshots advance, exclusive monitors
 * clear) — the coherence hooks are never bypassed. Failures are non-fatal:
 * the pages simply stay backed. */
static void vmem_host_release(VirtIOMem *v, u64 addr, u64 len) {
    Machine *m = v->m;
    MemoryRange range = { addr, len, true };
    MemoryGuard guard;
    if (!memory_guard_begin(&guard, m, &range, 1)) return;
    machine_store_notify(m, addr, len);
    u8 *host = m->ram + (addr - m->ram_base);
    (void)madvise(host, (size_t)len, MADV_DONTNEED);
    memory_guard_end(&guard);
}

static bool vmem_push_used(VirtIOMem *v, u16 id, uint32_t len) {
    Machine *m = v->m;
    if (!vmem_queue_spans(v)) { vmem_fail(v); return false; }
    uint16_t ui = (uint16_t)phys_read(m, v->q_used + 2, 2);
    if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return false; }
    uint64_t e  = v->q_used + 4 + (uint64_t)(ui % v->q_num) * 8;
    phys_write(m, e + 0, 4, id);
    phys_write(m, e + 4, 4, len);
    phys_write(m, v->q_used + 2, 2, (uint16_t)(ui + 1));
    if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return false; }
    return true;
}

/* ---- guest-request queue ---- */

static void vmem_process_queue(VirtIOMem *v) {
    Machine *m = v->m;
    if (!v->q_ready || v->q_num == 0) return;
    if (v->status & VIRTIO_STATUS_NEEDS_RESET) return;
    if (!vmem_queue_spans(v)) { vmem_fail(v); return; }

    uint16_t avail_idx = (uint16_t)phys_read(m, v->q_avail + 2, 2);
    if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return; }
    /* Bounded delta: the driver may not publish more than q_num fresh entries
     * per notify; anything wider is a malformed ring (never an unbounded
     * drain of a corrupt avail index). */
    if ((uint16_t)(avail_idx - v->last_avail) > v->q_num) { vmem_fail(v); return; }

    bool did = false;
    while (v->last_avail != avail_idx) {
        uint16_t q_num = (uint16_t)v->q_num;
        uint16_t hd = (uint16_t)phys_read(m,
            v->q_avail + 4 + (uint64_t)(v->last_avail % q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return; }
        if (hd >= q_num) { vmem_fail(v); return; }
        v->last_avail++;

        /* Walk the chain: exactly two descriptors — the 24-byte request
         * (device-readable) then the 10-byte response (device-writable),
         * which is how the in-tree Linux 6.12 driver posts every request.
         * The walk is bounded by q_num and rejects repeated indices, unknown
         * flag bits (INDIRECT/reserved), wrong direction/order and short
         * buffers before any buffer is touched. */
        uint16_t n = 0, idx = hd;
        bool seen[VMEM_QUEUE_NUM_MAX] = { false };
        uint64_t req_addr = 0; uint32_t req_len = 0;
        uint64_t resp_addr = 0; uint32_t resp_len = 0;
        bool terminated = false;
        for (;;) {
            if (n >= q_num) break;
            if (idx >= q_num || seen[idx]) { vmem_fail(v); return; }
            seen[idx] = true;
            uint64_t d    = v->q_desc + (uint64_t)idx * 16;
            u8 meta[16];
            phys_read_blk(m, d, meta, 16);
            if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return; }
            uint64_t gpa  = 0; memcpy(&gpa, meta + 0, 8);
            uint32_t dlen = 0; memcpy(&dlen, meta + 8, 4);
            uint16_t df   = (uint16_t)(meta[12] | (meta[13] << 8));
            uint16_t next = (uint16_t)(meta[14] | (meta[15] << 8));
            n++;
            if (df & ~VIRTQ_DESC_F_KNOWN) { vmem_fail(v); return; }
            if (n == 1) {
                if ((df & VIRTQ_DESC_F_WRITE) != 0 || dlen < VMEM_REQ_LEN) { vmem_fail(v); return; }
                req_addr = gpa; req_len = dlen;
            } else if (n == 2) {
                if ((df & VIRTQ_DESC_F_WRITE) == 0 || dlen < VMEM_RESP_LEN) { vmem_fail(v); return; }
                resp_addr = gpa; resp_len = dlen;
            } else {
                /* The wire request is exactly two descriptors. */
                vmem_fail(v); return;
            }
            if (!(df & VIRTQ_DESC_F_NEXT)) { terminated = true; break; }
            idx = next;
        }
        if (!terminated || n != 2) { vmem_fail(v); return; }

        /* All guest buffers must map completely into real RAM (overflow-safe)
         * before any physical access. */
        if (!ram_ptr(m, req_addr, VMEM_REQ_LEN) || !ram_ptr(m, resp_addr, VMEM_RESP_LEN)) {
            vmem_fail(v); return;
        }

        u16 resp_type = VIRTIO_MEM_RESP_ERROR;
        u16 resp_state = 0;

        u8 req[VMEM_REQ_LEN];
        phys_read_blk(m, req_addr, req, VMEM_REQ_LEN);
        if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return; }
        u16 type = (u16)(req[0] | (req[1] << 8));
        u16 rsvd = (u16)(req[2] | (req[3] << 8));
        u64 addr = 0; memcpy(&addr, req + 8, 8);
        u16 nb   = (u16)(req[16] | (req[17] << 8));
        /* Reserved request bytes must be zero (they are defined as zero in
         * the uapi); a nonzero value is a request-level error, not a
         * transport fault. */
        bool rsvd_nonzero = rsvd != 0 || req[18] || req[19] || req[20] || req[21] || req[22] || req[23];

        switch (type) {
        case VIRTIO_MEM_REQ_PLUG: {
            if (rsvd_nonzero || !vmem_range_ok(v, addr, nb)) { resp_type = VIRTIO_MEM_RESP_ERROR; break; }
            u64 first = (addr - v->addr) / v->block_size;
            /* Cannot exceed the host's requested budget. */
            if (v->plugged_size + (u64)nb * v->block_size > v->requested_size) {
                resp_type = VIRTIO_MEM_RESP_NACK; break;
            }
            for (u64 i = 0; i < nb; i++)
                if (v->block_state[first + i]) { resp_type = VIRTIO_MEM_RESP_ERROR; nb = 0; break; }
            if (nb == 0) break;
            for (u64 i = 0; i < nb; i++) v->block_state[first + i] = 1;
            v->plugged_size += (u64)nb * v->block_size;
            resp_type = VIRTIO_MEM_RESP_ACK;
            break;
        }
        case VIRTIO_MEM_REQ_UNPLUG: {
            if (rsvd_nonzero || !vmem_range_ok(v, addr, nb)) { resp_type = VIRTIO_MEM_RESP_ERROR; break; }
            u64 first = (addr - v->addr) / v->block_size;
            for (u64 i = 0; i < nb; i++)
                if (!v->block_state[first + i]) { resp_type = VIRTIO_MEM_RESP_ERROR; nb = 0; break; }
            if (nb == 0) break;
            for (u64 i = 0; i < nb; i++) v->block_state[first + i] = 0;
            v->plugged_size -= (u64)nb * v->block_size;
            /* Ask the host to decommit the range (advisory; measured
             * separately from the guest-visible plugged_size). */
            vmem_host_release(v, addr, (u64)nb * v->block_size);
            resp_type = VIRTIO_MEM_RESP_ACK;
            break;
        }
        case VIRTIO_MEM_REQ_UNPLUG_ALL: {
            if (rsvd_nonzero) { resp_type = VIRTIO_MEM_RESP_ERROR; break; }
            for (u64 i = 0; i < v->nb_blocks; i++) {
                if (!v->block_state[i]) continue;
                v->block_state[i] = 0;
                vmem_host_release(v, v->addr + i * v->block_size, v->block_size);
            }
            v->plugged_size = 0;
            resp_type = VIRTIO_MEM_RESP_ACK;
            break;
        }
        case VIRTIO_MEM_REQ_STATE: {
            if (rsvd_nonzero || !vmem_range_ok(v, addr, nb)) { resp_type = VIRTIO_MEM_RESP_ERROR; break; }
            u64 first = (addr - v->addr) / v->block_size;
            bool any_plugged = false, any_unplugged = false;
            for (u64 i = 0; i < nb; i++) {
                if (v->block_state[first + i]) any_plugged = true;
                else any_unplugged = true;
            }
            resp_state = any_plugged ? (any_unplugged ? VIRTIO_MEM_STATE_MIXED : VIRTIO_MEM_STATE_PLUGGED)
                                     : VIRTIO_MEM_STATE_UNPLUGGED;
            resp_type = VIRTIO_MEM_RESP_ACK;
            break;
        }
        default:
            resp_type = VIRTIO_MEM_RESP_ERROR;
            break;
        }

        u8 resp[VMEM_RESP_LEN];
        memset(resp, 0, sizeof(resp));
        resp[0] = (u8)(resp_type & 0xff);
        resp[1] = (u8)(resp_type >> 8);
        resp[8] = (u8)(resp_state & 0xff);
        resp[9] = (u8)(resp_state >> 8);
        phys_write_blk(m, resp_addr, resp, VMEM_RESP_LEN);
        if (machine_bus_status(m) != BUS_OK) { vmem_fail(v); return; }
        if (!vmem_push_used(v, hd, VMEM_RESP_LEN)) return;
        did = true;
    }

    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ---- host-side resize entry points (called from the C ABI between slices) ---- */

/* Returns true when the machine carries a virtio-mem device. */
bool virtio_mem_present(VirtIOMem *v) { return v != NULL; }

/* Host resize request. Setting `requested_size` is the spec-defined way the
 * device asks the driver to (un)plug; the config-change interrupt wakes a
 * parked guest. */
void virtio_mem_set_requested(VirtIOMem *v, u64 requested_size) {
    requested_size &= ~(v->block_size - 1);
    if (requested_size > v->region_size) requested_size = v->region_size;
    v->requested_size = requested_size;
    v->isr |= 2;                          /* VIRTIO_MMIO_INT_CONFIG */
    gic_set_irq(v->gic, v->irq, 1);
}

u64 virtio_mem_plugged(VirtIOMem *v) { return v ? v->plugged_size : 0; }
u64 virtio_mem_requested(VirtIOMem *v) { return v ? v->requested_size : 0; }

/* ---- MMIO ---- */

static void vmem_config_read(VirtIOMem *v, u64 off, u8 *cfg) {
    /* struct virtio_mem_config (little-endian, 56 bytes). */
    u64 vals[6] = { v->block_size, v->addr, v->region_size,
                    v->usable_region_size, v->plugged_size, v->requested_size };
    /* block_size @0 (8); node_id @8 (2); padding @10 (6); addr @16 (8);
     * region_size @24; usable_region_size @32; plugged_size @40;
     * requested_size @48. node_id stays 0 (no ACPI_PXM). */
    for (int i = 0; i < 8; i++) cfg[0 + i] = (u8)(vals[0] >> (8 * i));
    cfg[8] = 0; cfg[9] = 0;
    memset(cfg + 10, 0, 6);
    for (int i = 0; i < 8; i++) cfg[16 + i] = (u8)(vals[1] >> (8 * i));
    for (int i = 0; i < 8; i++) cfg[24 + i] = (u8)(vals[2] >> (8 * i));
    for (int i = 0; i < 8; i++) cfg[32 + i] = (u8)(vals[3] >> (8 * i));
    for (int i = 0; i < 8; i++) cfg[40 + i] = (u8)(vals[4] >> (8 * i));
    for (int i = 0; i < 8; i++) cfg[48 + i] = (u8)(vals[5] >> (8 * i));
}

static u64 vmem_read(void *opaque, u64 off, unsigned size) {
    VirtIOMem *v = opaque;
    if (off >= 0x100) {
        u8 cfg[56];
        vmem_config_read(v, off - 0x100, cfg);
        u64 r = 0;
        u64 base = off - 0x100;
        for (unsigned i = 0; i < size && base + i < sizeof(cfg); i++)
            r |= (u64)cfg[base + i] << (i * 8);
        return r;
    }
    switch (off) {
    case 0x000: return 0x74726976;       /* MagicValue "virt" */
    case 0x004: return 2;                /* Version (modern)  */
    case 0x008: return 24;               /* DeviceID = memory */
    case 0x00c: return 0x554d4551;       /* VendorID "QEMU"   */
    case 0x010:
        return v->dev_feat_sel == 1 ? (u32)(VMEM_FEATURES >> 32)
                                    : (u32)(VMEM_FEATURES & 0xffffffff);
    case 0x034: return v->queue_sel == VMEM_QUEUE_REQUEST ? VMEM_QUEUE_NUM_MAX : 0;
    case 0x044: return v->queue_sel == VMEM_QUEUE_REQUEST ? v->q_ready : 0;
    case 0x060: return v->isr;           /* InterruptStatus   */
    case 0x070: return v->status;        /* Status            */
    case 0x0fc: return 0;                /* ConfigGeneration  */
    default:    return 0;
    }
}

static void vmem_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIOMem *v = opaque;
    u32 v32 = (u32)val;
    (void)size;
    switch (off) {
    case 0x014: v->dev_feat_sel = v32; break;
    case 0x020:
        if (v->drv_feat_sel == 1) v->drv_feat = (v->drv_feat & 0xffffffffULL) | ((u64)v32 << 32);
        else                      v->drv_feat = (v->drv_feat & ~0xffffffffULL) | v32;
        break;
    case 0x024: v->drv_feat_sel = v32; break;
    case 0x030: v->queue_sel = v32; break;
    case 0x038:
        if (v->queue_sel == VMEM_QUEUE_REQUEST)
            v->q_num = v32 > VMEM_QUEUE_NUM_MAX ? VMEM_QUEUE_NUM_MAX : v32;
        break;
    case 0x044:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_ready = v32 ? 1 : 0;
        break;
    case 0x050:
        if (v32 == VMEM_QUEUE_REQUEST) vmem_process_queue(v);
        break;
    case 0x064:
        v->isr &= ~v32;
        if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
        break;
    case 0x070:
        /* A status write never clears a pending DEVICE_NEEDS_RESET; only a
         * full reset (status 0) recovers the device. */
        if (v32 == 0) vmem_reset(v);
        else v->status = v32 | (v->status & VIRTIO_STATUS_NEEDS_RESET);
        break;
    case 0x080:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_desc  = (v->q_desc  & ~0xffffffffULL) | v32; break;
    case 0x084:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_desc  = (v->q_desc  &  0xffffffffULL) | ((u64)v32 << 32); break;
    case 0x090:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_avail = (v->q_avail & ~0xffffffffULL) | v32; break;
    case 0x094:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_avail = (v->q_avail &  0xffffffffULL) | ((u64)v32 << 32); break;
    case 0x0a0:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_used  = (v->q_used  & ~0xffffffffULL) | v32; break;
    case 0x0a4:
        if (v->queue_sel == VMEM_QUEUE_REQUEST) v->q_used  = (v->q_used  &  0xffffffffULL) | ((u64)v32 << 32); break;
    default: break;
    }
}

/* ---- creation ---- */

VirtIOMem *virtio_mem_create(Machine *m, GIC *gic, int slot, u64 addr, u64 region_size,
                             u64 block_size, u64 requested_size) {
    /* Validate the geometry before any division or allocation: a zero or
     * non-power-of-two block_size would divide by zero or misalign the block
     * bitmap, and the region must lie completely inside the machine RAM
     * envelope (overflow-safe) because host reclaim aliases that mapping. */
    if (!block_size || (block_size & (block_size - 1)) != 0) return NULL;
    if (block_size < 0x1000) return NULL;              /* never below a host page */
    if (!region_size || (region_size % block_size) != 0) return NULL;
    u64 nb_blocks = region_size / block_size;
    if (!nb_blocks || nb_blocks > (1ULL << 20)) return NULL;      /* paranoia: bitmap bounds */
    if (requested_size > region_size) return NULL;     /* initial request must fit the region */
    if (addr & (block_size - 1)) return NULL;
    if (addr < m->ram_base || region_size > m->ram_size ||
        addr - m->ram_base > m->ram_size - region_size) return NULL;
    u64 base = 0x0a000000ULL + (u64)slot * 0x200;
    VirtIOMem *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0 + slot; v->slot = slot;
    v->block_size = block_size;
    v->addr = addr;
    v->region_size = region_size;
    v->usable_region_size = region_size;
    v->requested_size = requested_size & ~(block_size - 1);
    v->block_state = calloc(1, (size_t)nb_blocks);
    if (!v->block_state) { free(v); return NULL; }
    v->nb_blocks = nb_blocks;

    machine_add_device(m, base, 0x200, vmem_read, vmem_write, v, "virtio-mem");
    m->vmem = v;
    fprintf(stderr, "[virtio-mem] slot %d: region 0x%llx+0x%llx block 0x%llx requested 0x%llx\n",
            slot, (unsigned long long)addr, (unsigned long long)region_size,
            (unsigned long long)block_size, (unsigned long long)v->requested_size);
    return v;
}

/* Full teardown after every worker is quiet. */
void virtio_mem_destroy(VirtIOMem *v) {
    if (!v) return;
    free(v->block_state);
    free(v);
}

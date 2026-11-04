/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* virtio-blk over a modern (version 2) virtio-mmio transport, slot 0 of QEMU's
 * 'virt' map (0x0a000000, INTID 48 / SPI 16, edge-triggered per the DTB).
 *
 * The device is backed by a host image file opened O_RDWR; guest writes go
 * through to the file via pwrite. Requests are completed synchronously inside
 * the QueueNotify write and the IRQ is raised inline — which fits this
 * single-threaded deterministic interpreter: the guest isn't running while we
 * service the queue, and the kernel's ISR drains the whole used ring per IRQ. */
#include "../devices.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

#define SECTOR_SIZE   512
#define QUEUE_NUM_MAX 256        /* QueueNumMax for the single requestq */
#define VIRTQ_MAX     256        /* descriptor-chain walk bound (== QueueNumMax) */

/* Feature bits we advertise: VIRTIO_F_VERSION_1 (bit 32), mandatory for a modern
 * device, plus VIRTIO_BLK_F_RO (bit 5) for read-only disks. VIRTIO_BLK_F_RO is
 * added per-instance in virtio_blk_create; the base set stays minimal. */
#define VIRTIO_F_VERSION_1 (1ULL << 32)
#define VIRTIO_BLK_F_RO    (1ULL << 5)
#define VIRTIO_BLK_F_FLUSH (1ULL << 9)   /* device honors VIRTIO_BLK_T_FLUSH (fsync) */
#define BLK_FEATURES       (VIRTIO_F_VERSION_1 | VIRTIO_BLK_F_FLUSH)

/* Split-virtqueue descriptor flags. */
#define VIRTQ_DESC_F_NEXT  1
#define VIRTQ_DESC_F_WRITE 2

/* virtio-blk request types and status codes. */
#define VIRTIO_BLK_T_IN      0
#define VIRTIO_BLK_T_OUT     1
#define VIRTIO_BLK_T_FLUSH   4
#define VIRTIO_BLK_T_GET_ID  8
#define VIRTIO_BLK_S_OK      0
#define VIRTIO_BLK_S_IOERR   1
#define VIRTIO_BLK_S_UNSUPP  2

typedef struct VirtIOBlk {
    Machine *m; GIC *gic; int irq;     /* INTID_VIRTIO0 + slot */
    int index;                         /* attach order (0-based); used for the serial */
    int fd; u64 capacity;              /* backing image; capacity in 512B sectors */
    bool ro;                           /* read-only disk (advertises VIRTIO_BLK_F_RO) */
    u64 features;                      /* device feature bits (BLK_FEATURES [| RO]) */

    u32 status, isr;                   /* Status, InterruptStatus */
    u32 dev_feat_sel, drv_feat_sel; u64 drv_feat;
    u32 queue_sel;

    /* single queue (index 0) */
    u32 q_num, q_ready;
    u64 q_desc, q_avail, q_used;
    bool work_pending;
    struct {
        bool active;u32 head,n,index,type,used;u8 status;
        u64 addr[VIRTQ_MAX],off,gpa,status_addr;
        u32 length[VIRTQ_MAX],remaining;u16 flags[VIRTQ_MAX];
    } request;
    u16 last_avail;                    /* our cursor into the available ring */
} VirtIOBlk;

static void blk_reset(VirtIOBlk *v) {
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0;
    v->q_num = 0; v->q_ready = 0;
    v->q_desc = v->q_avail = v->q_used = 0;
    v->last_avail = 0;v->work_pending=false;memset(&v->request,0,sizeof(v->request));
    gic_set_irq(v->gic, v->irq, 0);
}

/* Append {id, len} to the used ring and publish it (element before the index). */
static void blk_fail(VirtIOBlk *v) { v->status|=64;v->work_pending=false;v->request.active=false; }
static bool queue_spans(VirtIOBlk *v) {
    return v->q_num && v->q_num<=VIRTQ_MAX &&
        ram_ptr(v->m,v->q_desc,(u64)v->q_num*16) &&
        ram_ptr(v->m,v->q_avail,6+(u64)v->q_num*2) &&
        ram_ptr(v->m,v->q_used,6+(u64)v->q_num*8);
}
static u64 descriptor_le(const u8 *p,unsigned count) { u64 out=0;for(unsigned i=0;i<count;i++)out|=(u64)p[i]<<(i*8);return out; }
static bool blk_push_used(VirtIOBlk *v,u32 id,u32 len) {
    if(!queue_spans(v)){blk_fail(v);return false;}
    u16 index=(u16)phys_read(v->m,v->q_used+2,2);
    if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}
    u64 entry=v->q_used+4+(u64)(index%v->q_num)*8;
    phys_write(v->m,entry,4,id);if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}
    phys_write(v->m,entry+4,4,len);if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}
    phys_write(v->m,v->q_used+2,2,(u16)(index+1));
    if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}return true;
}

/* Service one request: walk its descriptor chain, do the I/O, write the status
 * byte, and retire it on the used ring. The first descriptor is the 16-byte
 * header (readable), the last is the 1-byte status (writable), the rest is data. */
/* QueueNotify records work. The sole Machine owner advances one 4KiB data
 * chunk at a time before executing the next CPU instruction; DMA completion and
 * used-ring publication occur only after the original work is complete. */
static void request_finish(VirtIOBlk *v) {
    if(!queue_spans(v)||!ram_ptr(v->m,v->request.status_addr,1)){blk_fail(v);return;}
    phys_write(v->m,v->request.status_addr,1,v->request.status);
    if(machine_bus_status(v->m)!=BUS_OK||!blk_push_used(v,v->request.head,v->request.used+1)){blk_fail(v);return;}
    v->request.active=false;
    v->last_avail++;v->isr|=1;gic_set_irq(v->gic,v->irq,1);
}
static bool request_begin(VirtIOBlk *v,u32 head) {
    memset(&v->request,0,sizeof(v->request));v->request.head=head;
    u32 idx=head,n=0;bool seen[VIRTQ_MAX]={0},terminated=false;
    while(n<v->q_num) {
        if(idx>=v->q_num||seen[idx]) { v->status|=64;v->work_pending=false;return false; }
        seen[idx]=true;u64 d=v->q_desc+(u64)idx*16;
        u8 metadata[16];phys_read_blk(v->m,d,metadata,16);
        if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}
        v->request.addr[n]=descriptor_le(metadata,8);v->request.length[n]=(u32)descriptor_le(metadata+8,4);
        u16 flags=(u16)descriptor_le(metadata+12,2),next=(u16)descriptor_le(metadata+14,2);v->request.flags[n]=flags;n++;
        if(flags & ~(VIRTQ_DESC_F_NEXT|VIRTQ_DESC_F_WRITE)){v->status|=64;v->work_pending=false;return false;}
        if(!(flags&VIRTQ_DESC_F_NEXT)){terminated=true;break;}idx=next;
    }
    if(!terminated||n<2||v->request.length[0]<16||(v->request.flags[0]&VIRTQ_DESC_F_WRITE)||
       v->request.length[n-1]<1||!(v->request.flags[n-1]&VIRTQ_DESC_F_WRITE)) {
        v->status|=64;v->work_pending=false;return false;
    }
    v->request.n=n;v->request.active=true;v->request.index=1;
    v->request.status_addr=v->request.addr[n-1];
    if(!ram_ptr(v->m,v->request.addr[0],16)||!ram_ptr(v->m,v->request.status_addr,1)){blk_fail(v);return false;}
    u8 header[16];phys_read_blk(v->m,v->request.addr[0],header,16);
    if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return false;}
    v->request.type=(u32)descriptor_le(header,4);
    if(v->request.type==VIRTIO_BLK_T_IN||v->request.type==VIRTIO_BLK_T_OUT||v->request.type==VIRTIO_BLK_T_GET_ID) {
        bool want_write=v->request.type!=VIRTIO_BLK_T_OUT;
        for(u32 i=1;i+1<n;i++)if(((v->request.flags[i]&VIRTQ_DESC_F_WRITE)!=0)!=want_write) {
            v->request.active=false;v->status|=64;v->work_pending=false;return false;
        }
    }
    u64 sector=descriptor_le(header+8,8),total=0;
    for(u32 i=1;i+1<n;i++)total+=v->request.length[i];
    v->request.off=sector*SECTOR_SIZE;
    if((v->request.type==VIRTIO_BLK_T_OUT&&v->ro)||sector>v->capacity||total>(v->capacity-sector)*SECTOR_SIZE)
        v->request.status=VIRTIO_BLK_S_IOERR;
    return true;
}
bool virtio_blk_has_work(struct VirtIOBlk *v) { return v&&v->work_pending; }
void virtio_blk_service(struct VirtIOBlk *v) {
    if(!v||!v->work_pending)return;
    if(!v->q_ready||!v->q_num){v->work_pending=false;return;}
    if(!queue_spans(v)){blk_fail(v);return;}
    if(!v->request.active) {
        u16 avail=(u16)phys_read(v->m,v->q_avail+2,2);
        if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return;}
        if(avail==v->last_avail){v->work_pending=false;return;}
        if((u16)(avail-v->last_avail)>v->q_num){v->status|=64;v->work_pending=false;return;}
        u16 head=(u16)phys_read(v->m,v->q_avail+4+(u64)(v->last_avail%v->q_num)*2,2);
        if(machine_bus_status(v->m)!=BUS_OK){blk_fail(v);return;}
        if(!request_begin(v,head))return;
    }
    if(v->request.status){request_finish(v);return;}
    u32 type=v->request.type;
    if(type==VIRTIO_BLK_T_IN||type==VIRTIO_BLK_T_OUT) {
        while(!v->request.remaining&&v->request.index+1<v->request.n) {
            u32 i=v->request.index++;v->request.gpa=v->request.addr[i];v->request.remaining=v->request.length[i];
        }
        if(!v->request.remaining){request_finish(v);return;}
        u8 buffer[4096];u32 count=v->request.remaining<sizeof(buffer)?v->request.remaining:(u32)sizeof(buffer);
        if(type==VIRTIO_BLK_T_OUT){phys_read_blk(v->m,v->request.gpa,buffer,count);
            if(machine_bus_status(v->m)!=BUS_OK){v->request.status=VIRTIO_BLK_S_IOERR;request_finish(v);return;}}
        size_t completed=0;unsigned attempts=0;
        while(completed<count&&attempts++<64) {
            ssize_t n=type==VIRTIO_BLK_T_IN?
                pread(v->fd,buffer+completed,count-completed,(off_t)(v->request.off+completed)):
                pwrite(v->fd,buffer+completed,count-completed,(off_t)(v->request.off+completed));
            if(n<0&&errno==EINTR)continue;
            if(n<=0){v->request.status=VIRTIO_BLK_S_IOERR;break;}completed+=(size_t)n;
        }
        if(completed!=count)v->request.status=VIRTIO_BLK_S_IOERR;
        else if(type==VIRTIO_BLK_T_IN){phys_write_blk(v->m,v->request.gpa,buffer,count);if(machine_bus_status(v->m)!=BUS_OK)v->request.status=VIRTIO_BLK_S_IOERR;else v->request.used+=count;}
        v->request.off+=count;v->request.gpa+=count;v->request.remaining-=count;
        if(v->request.status)request_finish(v);
    } else {
        if(type==VIRTIO_BLK_T_FLUSH){if(fsync(v->fd))v->request.status=VIRTIO_BLK_S_IOERR;}
        else if(type==VIRTIO_BLK_T_GET_ID) {
            char text[20];snprintf(text,sizeof(text),"arm64emu-vblk%d",v->index);
            if(v->request.n>=3) {u8 id[20]={0};memcpy(id,text,strlen(text));u32 count=v->request.length[1]<20?v->request.length[1]:20;phys_write_blk(v->m,v->request.addr[1],id,count);v->request.used+=count;}
        } else v->request.status=VIRTIO_BLK_S_UNSUPP;
        request_finish(v);
    }
}
static void virtio_blk_process(VirtIOBlk *v) { v->work_pending=true;machine_owner_yield(v->m); }

static u64 blk_config_read(VirtIOBlk *v, u64 off, unsigned size) {
    u8 cfg[64];
    memset(cfg, 0, sizeof(cfg));
    for (int i = 0; i < 8; i++) cfg[i] = (u8)(v->capacity >> (i * 8));
    u64 r = 0;
    for (unsigned i = 0; i < size && off + i < sizeof(cfg); i++)
        r |= (u64)cfg[off + i] << (i * 8);
    return r;
}

static u64 blk_read(void *opaque, u64 off, unsigned size) {
    VirtIOBlk *v = opaque;
    if (off >= 0x100) return blk_config_read(v, off - 0x100, size);
    switch (off) {
        case 0x000: return 0x74726976;               /* MagicValue "virt" */
        case 0x004: return 2;                        /* Version (modern)  */
        case 0x008: return 2;                        /* DeviceID = block  */
        case 0x00c: return 0x554d4551;               /* VendorID "QEMU"   */
        case 0x010:                                  /* DeviceFeatures    */
            return v->dev_feat_sel == 1 ? (u32)(v->features >> 32)
                                        : (u32)(v->features & 0xffffffff);
        case 0x034:                                  /* QueueNumMax       */
            return v->queue_sel == 0 ? QUEUE_NUM_MAX : 0;
        case 0x044: return v->q_ready;               /* QueueReady        */
        case 0x060: return v->isr;                   /* InterruptStatus   */
        case 0x070: return v->status;                /* Status            */
        case 0x0fc: return 0;                        /* ConfigGeneration  */
        default:    return 0;
    }
}

static void blk_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIOBlk *v = opaque;
    u32 v32 = (u32)val;
    switch (off) {
        case 0x014: v->dev_feat_sel = v32; break;                   /* DeviceFeaturesSel */
        case 0x020:                                                 /* DriverFeatures    */
            if (v->drv_feat_sel == 1) v->drv_feat = (v->drv_feat & 0xffffffffULL) | ((u64)v32 << 32);
            else                      v->drv_feat = (v->drv_feat & ~0xffffffffULL) | v32;
            break;
        case 0x024: v->drv_feat_sel = v32; break;                   /* DriverFeaturesSel */
        case 0x030: v->queue_sel = v32; break;                      /* QueueSel          */
        case 0x038:                                                 /* QueueNum          */
            v->q_num = v32 > QUEUE_NUM_MAX ? QUEUE_NUM_MAX : v32;
            break;
        case 0x044: v->q_ready = v32; break;                        /* QueueReady        */
        case 0x050: if (v32 == 0) virtio_blk_process(v); break;     /* QueueNotify       */
        case 0x064:                                                 /* InterruptACK      */
            v->isr &= ~v32;
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:                                                 /* Status            */
            if (v32 == 0) blk_reset(v); else v->status = v32;
            break;
        case 0x080: v->q_desc  = (v->q_desc  & ~0xffffffffULL) | v32;            break;
        case 0x084: v->q_desc  = (v->q_desc  &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x090: v->q_avail = (v->q_avail & ~0xffffffffULL) | v32;            break;
        case 0x094: v->q_avail = (v->q_avail &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x0a0: v->q_used  = (v->q_used  & ~0xffffffffULL) | v32;            break;
        case 0x0a4: v->q_used  = (v->q_used  &  0xffffffffULL) | ((u64)v32 << 32); break;
        default: break;
    }
}

struct VirtIOBlk *virtio_blk_create(Machine *m, GIC *gic, const char *path, bool ro, int slot) {
    int fd = open(path, (ro ? O_RDONLY : O_RDWR) | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 512) { close(fd); return NULL; }

    u64 base = 0x0a000000ULL + (u64)slot * 0x200;
    VirtIOBlk *v = calloc(1, sizeof(*v));
    if (!v) { close(fd); return NULL; }
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0 + slot;
    v->index = m->n_blk;
    v->fd = fd;
    v->ro = ro;
    v->features = BLK_FEATURES | (ro ? VIRTIO_BLK_F_RO : 0);
    v->capacity = (u64)st.st_size / SECTOR_SIZE;
    machine_add_device(m, base, 0x200, blk_read, blk_write, v, "virtio-blk");
    m->blk[m->n_blk++] = v;
    fprintf(stderr, "[virtio-blk] slot %d: %s: %llu sectors (%llu MiB)%s\n", slot, path,
            (unsigned long long)v->capacity, (unsigned long long)((u64)st.st_size >> 20),
            ro ? " [ro]" : "");
    return v;
}

/* Close only the descriptor this device opened. Guest flush uses fsync. */
void virtio_blk_destroy(struct VirtIOBlk *v) {
    if (v) { if (v->fd >= 0) close(v->fd); free(v); }
}

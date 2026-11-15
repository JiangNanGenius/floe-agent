/* SPDX-License-Identifier: Apache-2.0 */
/* Fixed virtio-media transport backed by the app's compiled VideoToolbox
 * service. Guest ioctl numbers select this finite V4L2 implementation; they
 * are never forwarded to a native ioctl or native object. Codec threads own
 * copied media only. All guest memory/ring/IRQ access stays on the machine's
 * coordinator, with the same memory guards as other DMA devices.
 *
 * Single-planar VIDEO_M2M deliberately exposes contiguous NV12/P010 through
 * standard MMAP. USERPTR, DMABUF, requests and unimplemented formats return a
 * Linux error. Dedicated stable backing survives logical buffer recycling:
 * no native worker can retain a D-TLB pointer to unmapped host storage. */
#include "../devices.h"
#include "../machine.h"
#include "../memory_regions.h"
#include "virtio_media.h"
#include "virtio_media_wire.h"
#include "floe_linux_video.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>
#include <limits.h>

#define VMED_PAGE 4096u
#define VMED_PAGES (FLOE_VIDEO_APERTURE_BYTES/VMED_PAGE)
#define VMED_PACKET_LIMIT (16u*1024u*1024u)
#define VMED_FRAME_LIMIT (64u*1024u*1024u)
#define VMED_DEFAULT_HOST_LIMIT (128u*1024u*1024u)
#define VMED_MODERN (UINT64_C(1)<<32)
#define VMED_NEEDS_RESET 64u
#define VMED_DRIVER_OK 4u
#define VMED_FORMAT_NV12 VMED_FOURCC('N','V','1','2')
#define VMED_FORMAT_P010 VMED_FOURCC('P','0','1','0')
#define VMED_BUF_QUEUED 2u
#define VMED_BUF_DONE 4u
#define VMED_BUF_KEYFRAME 8u
#define VMED_BUF_ERROR 64u
#define VMED_BUF_LAST UINT32_C(0x100000)
#define VMED_BUF_TS_COPY UINT32_C(0x4000)

typedef struct VMediaRing {
    u32 num,ready;
    u64 desc,avail,used;
    u16 last;
} VMediaRing;
typedef struct VMediaSegment { u64 addr;u32 len;bool write; } VMediaSegment;
typedef struct VMediaChain {
    u16 head,n;
    u32 read_bytes,write_bytes;
    VMediaSegment seg[VMED_Q_MAX];
} VMediaChain;
typedef struct VMediaFormat { u32 fourcc,width,height,stride,bytes; } VMediaFormat;
typedef struct VMediaBuffer {
    u32 offset,bytes,used,flags,maps;
    u64 order;
    int64_t pts;
    bool queued;
} VMediaBuffer;
typedef struct VMediaQueue {
    VMediaFormat fmt;
    VMediaBuffer buffers[VMED_MAX_BUFFERS];
    u32 count,sequence;
    bool streaming;
} VMediaQueue;
typedef struct VMediaSession {
    u32 id;
    VMediaQueue queue[2];             /* capture then output */
    FLVSession *codec;
    FLVOutput pending;
    bool have_pending,format_seen,draining,drain_sent,drained,force_keyframe;
    bool faulted,fault_event_sent;
    u32 fault_errno;
    u32 subscriptions,bitrate,fps_num,fps_den;
    u64 next_order,next_tag;
} VMediaSession;
typedef struct VMediaEvent { u32 len;u8 data[VMED_EVENT_BYTES]; } VMediaEvent;
typedef struct VirtIOMedia {
    Machine *m;GIC *gic;
    int irq,slot,region,wake_fd;
    u16 broker_port;u64 broker_token;
    u32 direction,max_sessions;
    FLVHost *host;
    FLVCapability capabilities[22];
    size_t capability_count;
    _Atomic bool ready;
    bool closing,allow_native_software;
    u32 status,isr,dev_feat_sel,drv_feat_sel,queue_sel,shm_sel,next_id;
    u64 driver_features,base;
    VMediaRing ring[2];
    u8 *pages;
    VMediaSession sessions[VMED_MAX_SESSIONS];
    VMediaEvent events[VMED_MAX_EVENTS];
    u32 event_head,event_count;
    u64 submitted,hardware_outputs,errors,owned_mmap_bytes,native_software_outputs;
} VirtIOMedia;

typedef struct VMediaCodecMap { u32 codec,fourcc;const char *name; } VMediaCodecMap;
static const VMediaCodecMap codec_map[] = {
    {FLV_H264,VMED_FOURCC('H','2','6','4'),"H.264"},
    {FLV_HEVC,VMED_FOURCC('H','E','V','C'),"HEVC"},
    {FLV_VP9,VMED_FOURCC('V','P','9','0'),"VP9"},
    {FLV_MJPEG,VMED_FOURCC('M','J','P','G'),"Motion-JPEG"},
    {FLV_MPEG2,VMED_FOURCC('M','P','G','2'),"MPEG-2"},
    {FLV_MPEG4,VMED_FOURCC('M','P','G','4'),"MPEG-4"},
    {FLV_H263,VMED_FOURCC('H','2','6','3'),"H.263"},
    {FLV_VP8,VMED_FOURCC('V','P','8','0'),"VP8"},
    /* Linux6.12's AV1 format is stateless AV1_FRAME, which cannot be
     * advertised by this stateful device. ProRes has no standard mapping.
     * Host support is retained separately until a real frontend exists. */
};

static void media_fail(VirtIOMedia *v) {
    v->status|=VMED_NEEDS_RESET;
    v->isr|=2;gic_set_irq(v->gic,v->irq,1);
}
static int media_error(int status) {
    switch(status) {
    case FLV_OK:return 0;
    case FLV_AGAIN:return VMED_EAGAIN;
    case FLV_LIMIT:return VMED_ENOSPC;
    case FLV_UNSUPPORTED:return VMED_ENOTSUP;
    case FLV_INVALID:case FLV_CORRUPT:return VMED_EINVAL;
    case FLV_CANCELLED:case FLV_CLOSED:return VMED_EPIPE;
    default:return VMED_EIO;
    }
}
static void media_notify(void *opaque,uint64_t session_tag,uint32_t events) {
    VirtIOMedia *v=opaque;(void)session_tag;(void)events;
    atomic_store_explicit(&v->ready,true,memory_order_release);
    if(v->wake_fd>=0){u8 byte=1;(void)write(v->wake_fd,&byte,1);}
}
static bool ring_spans(VirtIOMedia *v,VMediaRing *r) {
    return r->num&&r->num<=VMED_Q_MAX&&!(r->num&(r->num-1))&&
        !(r->desc&15)&&!(r->avail&1)&&!(r->used&3)&&
        ram_ptr(v->m,r->desc,(u64)r->num*16)&&
        ram_ptr(v->m,r->avail,6+(u64)r->num*2)&&
        ram_ptr(v->m,r->used,6+(u64)r->num*8);
}
/* One bounded descriptor chain. Direction changes at most once, and every
 * byte is checked before a command can mutate a session. */
static bool chain_next(VirtIOMedia *v,VMediaRing *r,VMediaChain *c,bool *empty) {
    *empty=true;
    if(!r->ready)return true;
    if(!ring_spans(v,r))return false;
    u16 available=(u16)phys_read(v->m,r->avail+2,2);
    if(machine_bus_status(v->m)!=BUS_OK||(u16)(available-r->last)>r->num)return false;
    if(available==r->last)return true;
    memset(c,0,sizeof(*c));
    c->head=(u16)phys_read(v->m,r->avail+4+(u64)(r->last%r->num)*2,2);
    if(machine_bus_status(v->m)!=BUS_OK||c->head>=r->num)return false;
    bool seen[VMED_Q_MAX]={false},writing=false;
    u16 index=c->head;
    for(unsigned n=0;n<r->num;n++) {
        if(index>=r->num||seen[index])return false;
        seen[index]=true;
        u8 d[16];phys_read_blk(v->m,r->desc+(u64)index*16,d,sizeof(d));
        if(machine_bus_status(v->m)!=BUS_OK)return false;
        u64 addr=vmed_r64(d);u32 len=vmed_r32(d+8);
        u16 flags=(u16)(d[12]|((u16)d[13]<<8));
        if((flags&~3u)||!len||!ram_ptr(v->m,addr,len))return false;
        bool wr=(flags&2)!=0;
        if(writing&&!wr)return false;
        writing|=wr;
        u32 *sum=wr?&c->write_bytes:&c->read_bytes;
        if(len>VMED_MAX_COMMAND||*sum>VMED_MAX_COMMAND-len)return false;
        *sum+=len;c->seg[c->n++]=(VMediaSegment){addr,len,wr};
        if(!(flags&1)){*empty=false;return true;}
        index=(u16)(d[14]|((u16)d[15]<<8));
    }
    return false;
}
static bool chain_read(VirtIOMedia *v,const VMediaChain *c,u8 *data) {
    size_t pos=0;
    for(unsigned i=0;i<c->n;i++)if(!c->seg[i].write){
        phys_read_blk(v->m,c->seg[i].addr,data+pos,c->seg[i].len);pos+=c->seg[i].len;
        if(machine_bus_status(v->m)!=BUS_OK)return false;
    }
    return true;
}
static bool chain_write(VirtIOMedia *v,const VMediaChain *c,const u8 *data,u32 len) {
    if(len>c->write_bytes)return false;
    u32 pos=0;
    for(unsigned i=0;i<c->n&&pos<len;i++)if(c->seg[i].write){
        u32 part=c->seg[i].len<len-pos?c->seg[i].len:len-pos;
        phys_write_blk(v->m,c->seg[i].addr,data+pos,part);pos+=part;
        if(machine_bus_status(v->m)!=BUS_OK)return false;
    }
    return pos==len;
}
static bool ring_complete(VirtIOMedia *v,VMediaRing *r,u16 head,u32 len) {
    if(!ring_spans(v,r))return false;
    u16 used=(u16)phys_read(v->m,r->used+2,2);
    if(machine_bus_status(v->m)!=BUS_OK)return false;
    u64 entry=r->used+4+(u64)(used%r->num)*8;
    phys_write(v->m,entry,4,head);phys_write(v->m,entry+4,4,len);
    phys_write(v->m,r->used+2,2,(u16)(used+1));
    if(machine_bus_status(v->m)!=BUS_OK)return false;
    r->last++;v->isr|=1;gic_set_irq(v->gic,v->irq,1);return true;
}
static bool event_space(VirtIOMedia *v,unsigned n) {
    return n<=VMED_MAX_EVENTS-v->event_count;
}
static bool event_push(VirtIOMedia *v,const void *data,u32 len) {
    if(!event_space(v,1)||len>VMED_EVENT_BYTES)return false;
    VMediaEvent *e=&v->events[(v->event_head+v->event_count)%VMED_MAX_EVENTS];
    memset(e,0,sizeof(*e));e->len=len;memcpy(e->data,data,len);v->event_count++;
    return true;
}
static void event_purge(VirtIOMedia *v,u32 id,u32 type) {
    unsigned keep=0,old=v->event_count;
    for(unsigned i=0;i<old;i++) {
        VMediaEvent *e=&v->events[(v->event_head+i)%VMED_MAX_EVENTS];
        bool remove=vmed_r32(e->data+4)==id&&
            (!type||(vmed_r32(e->data)==VMED_EVT_DQBUF&&vmed_r32(e->data+12)==type));
        if(!remove){if(keep!=i)v->events[(v->event_head+keep)%VMED_MAX_EVENTS]=*e;keep++;}
    }
    v->event_count=keep;
}
static void events_service(VirtIOMedia *v) {
    VMediaRing *r=&v->ring[VMED_Q_EVENT];
    for(unsigned i=0;i<VMED_Q_MAX&&v->event_count;i++) {
        VMediaChain c;bool empty;
        if(!chain_next(v,r,&c,&empty)){media_fail(v);return;}
        if(empty)return;
        VMediaEvent *e=&v->events[v->event_head];
        if(c.read_bytes||c.write_bytes<VMED_EVENT_BYTES||!chain_write(v,&c,e->data,e->len)||
           !ring_complete(v,r,c.head,e->len)){media_fail(v);return;}
        v->event_head=(v->event_head+1)%VMED_MAX_EVENTS;v->event_count--;
    }
}

static VMediaSession *session_find(VirtIOMedia *v,u32 id) {
    if(!id)return NULL;
    for(unsigned i=0;i<v->max_sessions;i++)if(v->sessions[i].id==id)return &v->sessions[i];
    return NULL;
}
static int queue_index(u32 type) { return type==VMED_CAPTURE?0:type==VMED_OUTPUT?1:-1; }
static bool coded_queue(VirtIOMedia *v,int q) { return v->direction==FLV_DECODE?q==1:q==0; }
static const VMediaCodecMap *codec_for_fourcc(u32 fourcc) {
    for(unsigned i=0;i<sizeof(codec_map)/sizeof(codec_map[0]);i++)
        if(codec_map[i].fourcc==fourcc)return &codec_map[i];
    return NULL;
}
static const FLVCapability *codec_capability(VirtIOMedia *v,u32 codec) {
    for(size_t i=0;i<v->capability_count;i++) {
        const FLVCapability *c=&v->capabilities[i];
        if(c->codec==codec&&c->direction==v->direction&&
           (c->flags&FLV_CAP_IMPLEMENTED)&&
           ((c->flags&(FLV_CAP_HW_REPORTED|FLV_CAP_SESSION_PROBED))||
            (v->allow_native_software&&(c->flags&FLV_CAP_NATIVE_SOFTWARE_PROBED))))return c;
    }
    return NULL;
}
static u32 raw_mask(VirtIOMedia *v,VMediaSession *s) {
    int coded=v->direction==FLV_DECODE?1:0;
    const VMediaCodecMap *m=codec_for_fourcc(s->queue[coded].fmt.fourcc);
    const FLVCapability *cap=m?codec_capability(v,m->codec):NULL;
    return cap?cap->pixel_format_mask:0;
}
static u32 first_codec(VirtIOMedia *v) {
    for(unsigned i=0;i<sizeof(codec_map)/sizeof(codec_map[0]);i++)
        if(codec_capability(v,codec_map[i].codec))return codec_map[i].fourcc;
    return 0;
}
static u32 native_pixel(u32 fourcc) {
    return fourcc==VMED_FORMAT_NV12?FLV_NV12:fourcc==VMED_FORMAT_P010?FLV_P010:0;
}
static int format_negotiate(VirtIOMedia *v,VMediaSession *s,int q,VMediaFormat *f) {
    if(coded_queue(v,q)) {
        if(!f->fourcc)f->fourcc=first_codec(v);
        const VMediaCodecMap *m=codec_for_fourcc(f->fourcc);
        if(!m||!codec_capability(v,m->codec))return VMED_EINVAL;
        if(f->width>8192||f->height>4320)return VMED_EINVAL;
        f->stride=0;
        if(!f->bytes)f->bytes=2u*1024u*1024u;
        if(f->bytes<65536)f->bytes=65536;
        if(f->bytes>VMED_PACKET_LIMIT)return VMED_EINVAL;
    } else {
        if(!f->fourcc)f->fourcc=VMED_FORMAT_NV12;
        u32 pixel=native_pixel(f->fourcc);
        if(!pixel||!(raw_mask(v,s)&(1u<<pixel)))return VMED_EINVAL;
        if(!f->width)f->width=1280;if(!f->height)f->height=720;
        if(f->width<2||f->height<2||f->width>8192||f->height>4320||
           (f->width&1)||(f->height&1))return VMED_EINVAL;
        f->stride=f->width*(pixel==FLV_P010?2:1);
        u64 bytes=(u64)f->stride*f->height*3/2;
        if(bytes>VMED_FRAME_LIMIT)return VMED_EINVAL;
        f->bytes=(u32)bytes;
    }
    return 0;
}
static void format_wire(u8 *p,u32 type,const VMediaFormat *f) {
    memset(p,0,VMED_FORMAT_BYTES);vmed_w32(p,type);
    vmed_w32(p+8,f->width);vmed_w32(p+12,f->height);vmed_w32(p+16,f->fourcc);
    vmed_w32(p+20,1); /* V4L2_FIELD_NONE */
    vmed_w32(p+24,f->stride);vmed_w32(p+28,f->bytes);
    /* DEFAULT: the compressed stream remains authoritative for colorimetry.
     * Do not claim a range/transfer matrix absent from the host ABI. */
}
static int pages_alloc(VirtIOMedia *v,u32 bytes,u32 *offset) {
    u32 n=(bytes+VMED_PAGE-1)/VMED_PAGE,run=0;
    if(!n||n>=VMED_PAGES)return VMED_ENOMEM;
    for(u32 i=1;i<VMED_PAGES;i++) {
        run=v->pages[i]?0:run+1;
        if(run==n) {
            u32 first=i+1-n;memset(v->pages+first,1,n);*offset=first*VMED_PAGE;
            /* Clear recycled bytes through the ordinary coherent DMA path. */
            u8 zero[VMED_PAGE]={0};
            for(u32 k=0;k<n;k++)phys_write_blk(v->m,v->base+*offset+(u64)k*VMED_PAGE,zero,sizeof(zero));
            if(machine_bus_status(v->m)!=BUS_OK){memset(v->pages+first,0,n);return VMED_EIO;}
            v->owned_mmap_bytes+=(u64)n*VMED_PAGE;return 0;
        }
    }
    return VMED_ENOMEM;
}
static void pages_free(VirtIOMedia *v,VMediaBuffer *b) {
    if(!b->bytes)return;
    u32 n=(b->bytes+VMED_PAGE-1)/VMED_PAGE,first=b->offset/VMED_PAGE;
    memset(v->pages+first,0,n);v->owned_mmap_bytes-=(u64)n*VMED_PAGE;
    memset(b,0,sizeof(*b));
}
static void codec_close(VMediaSession *s) {
    if(!s->codec)return;
    if(s->have_pending){flv_session_release_output(s->codec,&s->pending);s->have_pending=false;}
    flv_session_cancel(s->codec);flv_session_close(s->codec);s->codec=NULL;
    s->draining=s->drain_sent=s->drained=false;
}
static void session_close(VirtIOMedia *v,VMediaSession *s) {
    codec_close(s);event_purge(v,s->id,0);
    for(unsigned q=0;q<2;q++)for(unsigned i=0;i<s->queue[q].count;i++)pages_free(v,&s->queue[q].buffers[i]);
    memset(s,0,sizeof(*s));
}
static int session_open(VirtIOMedia *v,u32 *id) {
    if(v->next_id==UINT32_MAX)return VMED_ENOSPC;
    for(unsigned i=0;i<v->max_sessions;i++)if(!v->sessions[i].id) {
        VMediaSession *s=&v->sessions[i];memset(s,0,sizeof(*s));s->id=++v->next_id;
        s->bitrate=4000000;s->fps_num=1;s->fps_den=30;
        int coded=v->direction==FLV_DECODE?1:0;
        s->queue[coded].fmt=(VMediaFormat){first_codec(v),0,0,0,2u*1024u*1024u};
        s->queue[1-coded].fmt=(VMediaFormat){VMED_FORMAT_NV12,1280,720,1280,1382400};
        *id=s->id;return 0;
    }
    return VMED_EBUSY;
}
static void buffer_wire(u8 *p,const VMediaBuffer *b,u32 index,u32 type,u32 sequence) {
    memset(p,0,VMED_BUFFER_BYTES);vmed_w32(p,index);vmed_w32(p+4,type);
    vmed_w32(p+8,b->used);
    vmed_w32(p+12,b->flags|(b->maps?1u:0u)|VMED_BUF_TS_COPY);
    vmed_w32(p+16,1);
    int64_t secs=b->pts/INT64_C(1000000000),remainder=b->pts%INT64_C(1000000000);
    if(remainder<0){secs--;remainder+=INT64_C(1000000000);}
    vmed_w64(p+24,(u64)secs);vmed_w64(p+32,(u64)(remainder/1000));
    vmed_w32(p+56,sequence);vmed_w32(p+60,VMED_MEMORY_MMAP);
    vmed_w32(p+64,b->offset);vmed_w32(p+72,b->bytes);
}
static bool buffer_event(VirtIOMedia *v,VMediaSession *s,int q,u32 index,u32 flags,u32 used,int64_t pts) {
    if(!event_space(v,1))return false;
    VMediaQueue *queue=&s->queue[q];VMediaBuffer *b=&queue->buffers[index];
    u8 e[VMED_EVENT_BYTES]={0};vmed_w32(e,VMED_EVT_DQBUF);vmed_w32(e+4,s->id);
    b->queued=false;b->flags=flags|VMED_BUF_DONE;b->used=used;b->pts=pts;
    buffer_wire(e+8,b,index,q==0?VMED_CAPTURE:VMED_OUTPUT,queue->sequence++);
    return event_push(v,e,sizeof(e));
}
static bool session_event(VirtIOMedia *v,VMediaSession *s,u32 type) {
    if(!(s->subscriptions&(1u<<type)))return true;
    u8 e[144]={0};vmed_w32(e,VMED_EVT_EVENT);vmed_w32(e+4,s->id);vmed_w32(e+8,type);
    if(type==VMED_EVENT_SOURCE_CHANGE)vmed_w32(e+16,1);
    return event_push(v,e,sizeof(e));
}
static int queue_request(VirtIOMedia *v,VMediaSession *s,int q,u32 count) {
    VMediaQueue *queue=&s->queue[q];
    if(queue->streaming)return VMED_EBUSY;
    for(unsigned i=0;i<queue->count;i++)if(queue->buffers[i].maps)return VMED_EBUSY;
    for(unsigned i=0;i<queue->count;i++)pages_free(v,&queue->buffers[i]);
    queue->count=0;queue->sequence=0;event_purge(v,s->id,q==0?VMED_CAPTURE:VMED_OUTPUT);
    if(!count)return 0;
    if(!queue->fmt.bytes)return VMED_EINVAL;
    for(unsigned i=0;i<count;i++) {
        VMediaBuffer *b=&queue->buffers[i];
        int error=pages_alloc(v,queue->fmt.bytes,&b->offset);
        if(error){for(unsigned j=0;j<i;j++)pages_free(v,&queue->buffers[j]);queue->count=0;return error;}
        b->bytes=queue->fmt.bytes;queue->count++;
    }
    return 0;
}

static VMediaBuffer *oldest_buffer(VMediaQueue *q,u32 *index) {
    VMediaBuffer *best=NULL;
    for(u32 i=0;i<q->count;i++)if(q->buffers[i].queued&&(!best||q->buffers[i].order<best->order)){
        best=&q->buffers[i];*index=i;
    }
    return best;
}
static void queue_streamoff(VirtIOMedia *v,VMediaSession *s,int q) {
    VMediaQueue *queue=&s->queue[q];queue->streaming=false;queue->sequence=0;
    event_purge(v,s->id,q==0?VMED_CAPTURE:VMED_OUTPUT);
    for(u32 i=0;i<queue->count;i++){
        queue->buffers[i].queued=false;queue->buffers[i].flags=0;queue->buffers[i].used=0;
    }
    /* Stateful decoders may stop/reallocate CAPTURE after SOURCE_CHANGE
     * without discarding the already-decoded pending picture. OUTPUT stop
     * is the cancellation boundary. Encoders stop both queues. */
    if(q==1||v->direction==FLV_ENCODE){codec_close(s);s->format_seen=false;}
}
static int codec_open(VirtIOMedia *v,VMediaSession *s) {
    if(s->codec)return 0;
    int coded=v->direction==FLV_DECODE?1:0,raw=1-coded;
    const VMediaCodecMap *map=codec_for_fourcc(s->queue[coded].fmt.fourcc);
    const FLVCapability *cap=map?codec_capability(v,map->codec):NULL;
    u32 pixel=native_pixel(s->queue[raw].fmt.fourcc);
    if(!map||!cap||!pixel||!(cap->pixel_format_mask&(1u<<pixel)))return VMED_ENOTSUP;
    VMediaFormat *fmt=&s->queue[v->direction==FLV_ENCODE?raw:coded].fmt;
    FLVSessionConfig config={0};
    config.abi_version=FLV_ABI_VERSION;config.codec=map->codec;config.direction=v->direction;
    config.pixel_format=pixel;config.width=fmt->width;config.height=fmt->height;
    config.frame_rate_num=s->fps_den;config.frame_rate_den=s->fps_num;
    config.bitrate=s->bitrate;config.session_tag=s->id;
    config.flags=FLV_LOW_LATENCY;
    if(cap->flags&(FLV_CAP_HW_REPORTED|FLV_CAP_SESSION_PROBED))config.flags|=FLV_REQUIRE_HARDWARE;
    else if(!v->allow_native_software||!(cap->flags&FLV_CAP_NATIVE_SOFTWARE_PROBED))return VMED_ENOTSUP;
    else config.flags|=FLV_ALLOW_NATIVE_SOFTWARE;
    config.bitstream_format=(map->codec==FLV_H264||map->codec==FLV_HEVC)?FLV_ANNEX_B:FLV_RAW_CODED_FRAME;
    return media_error(flv_session_create(v->host,&config,&s->codec));
}

typedef struct VMediaControl { u32 id,type;int32_t min,max,step,def;bool read_only;const char *name; } VMediaControl;
/* Advertise only settings implemented by the frozen native ABI. Fixed
 * low-latency constraints may be accepted at their only supported value. */
static const VMediaControl media_controls[]={
    {UINT32_C(0x00980927),1,2,2,1,2,true,"Minimum capture buffers"},
    {UINT32_C(0x00980928),1,2,2,1,2,true,"Minimum output buffers"},
    {UINT32_C(0x009909cf),1,1000,1000000000,1,4000000,false,"Video bitrate"},
    {UINT32_C(0x009909ca),1,0,0,1,0,false,"B frames"},
    {UINT32_C(0x009909d7),2,1,1,1,1,false,"Frame level rate control"},
    {UINT32_C(0x009909d8),3,1,1,1,1,false,"Stream header mode"},
    {UINT32_C(0x009909e2),2,1,1,1,1,false,"Repeat sequence headers"},
    {UINT32_C(0x009909e5),4,0,0,0,0,false,"Force key frame"},
};
static const VMediaControl *control_find(VirtIOMedia *v,u32 id) {
    for(unsigned i=0;i<sizeof(media_controls)/sizeof(media_controls[0]);i++)
        if(media_controls[i].id==id&&(i<2||v->direction==FLV_ENCODE))return &media_controls[i];
    return NULL;
}
static int control_value(VirtIOMedia *v,VMediaSession *s,u32 id,int32_t *value,bool set,bool commit) {
    const VMediaControl *c=control_find(v,id);
    if(!c)return VMED_EINVAL;
    if(c->type==4){
        /* Linux button controls ignore the written scalar; FFmpeg commonly
         * writes 1 for FORCE_KEY_FRAME. They cannot be read as state. */
        if(!set)return VMED_EACCES;
        *value=0;if(commit)s->force_keyframe=true;return 0;
    }
    if(!set){*value=id==UINT32_C(0x009909cf)?(int32_t)s->bitrate:c->def;return 0;}
    if(c->read_only)return VMED_EACCES;
    if(*value<c->min||*value>c->max)return VMED_EINVAL;
    if(s->codec)return VMED_EBUSY;
    if(commit&&id==UINT32_C(0x009909cf))s->bitrate=(u32)*value;
    return 0;
}
static u32 control_flags(const VMediaControl *c) {
    /* READ_ONLY; or WRITE_ONLY|EXECUTE_ON_WRITE for stateless buttons. */
    return c->read_only?4u:c->type==4?UINT32_C(0x240):0u;
}
static u32 ioctl_size(u32 code) {
    switch(code){
    case 0:return 104;case 2:return 64;case 4:case 5:case 64:return 208;
    case 8:return 20;case 9:case 15:case 93:return 88;
    case 18:case 19:return 4;case 21:case 22:return 204;
    case 27:case 28:return 8;case 36:return 68;case 37:return 44;
    case 71:case 72:case 73:return 32;
    case 74:return 44;case 75:return 52;case 77:case 78:return 40;
    case 90:case 91:return 32;case 94:return 64;
    case 96:case 97:return 72;case 103:return 232;
    default:return 0;
    }
}
static bool ioctl_write_only(u32 code){return code==18||code==19||code==90||code==91;}
static int ioctl_execute(VirtIOMedia *v,VMediaSession *s,u32 code,const u8 *in,u32 in_len,
                         u8 *out,u32 *out_len) {
    u32 size=ioctl_size(code);*out_len=ioctl_write_only(code)?0:size;
    if(!size)return VMED_ENOTTY;
    if(code!=0&&in_len<size)return VMED_EINVAL;
    if(code!=0)memcpy(out,in,size);
    int q;u32 type,index;
    switch(code) {
    case 0: /* QUERYCAP is normally completed locally by the guest driver. */
        memset(out,0,size);memcpy(out,"virtio-media",12);
        snprintf((char *)out+16,32,"Floe native video %s",v->direction==FLV_DECODE?"decoder":"encoder");
        if(v->broker_port)
            snprintf((char *)out+48,32,"floe:v1:%u:%016llx",(unsigned)v->broker_port,
                     (unsigned long long)v->broker_token);
        else memcpy(out+48,"platform:virtio-media",21);
        vmed_w32(out+80,UINT32_C(0x060c00));
        vmed_w32(out+84,VMED_CAPS|UINT32_C(0x80000000));vmed_w32(out+88,VMED_CAPS);return 0;
    case 2: { /* ENUM_FMT */
        index=vmed_r32(in);type=vmed_r32(in+4);q=queue_index(type);if(q<0)return VMED_EINVAL;
        u32 fmt=0;const char *name=NULL;
        if(coded_queue(v,q)) {
            for(unsigned i=0;i<sizeof(codec_map)/sizeof(codec_map[0]);i++)if(codec_capability(v,codec_map[i].codec)){
                if(index--==0){fmt=codec_map[i].fourcc;name=codec_map[i].name;break;}
            }
        } else {
            u32 mask=raw_mask(v,s);
            if(mask&(1u<<FLV_NV12)){if(index--==0){fmt=VMED_FORMAT_NV12;name="NV12";}}
            if(!fmt&&(mask&(1u<<FLV_P010))&&index--==0){fmt=VMED_FORMAT_P010;name="P010";}
        }
        if(!fmt)return VMED_EINVAL;
        memset(out,0,size);vmed_w32(out,vmed_r32(in));vmed_w32(out+4,type);
        vmed_w32(out+8,coded_queue(v,q)?1u:0u);snprintf((char *)out+12,32,"%s",name);
        vmed_w32(out+44,fmt);return 0;
    }
    case 4:case 5:case 64: { /* G/S/TRY_FMT */
        type=vmed_r32(in);q=queue_index(type);if(q<0)return VMED_EINVAL;
        VMediaFormat fmt=s->queue[q].fmt;
        if(code!=4){
            fmt=(VMediaFormat){vmed_r32(in+16),vmed_r32(in+8),vmed_r32(in+12),0,vmed_r32(in+28)};
            int error=format_negotiate(v,s,q,&fmt);if(error)return error;
            if(code==5){
                if(s->queue[q].streaming||s->queue[q].count)return VMED_EBUSY;
                if(s->codec&&!(v->direction==FLV_DECODE&&q==0&&
                    fmt.fourcc==s->queue[q].fmt.fourcc&&fmt.width==s->queue[q].fmt.width&&
                    fmt.height==s->queue[q].fmt.height))return VMED_EBUSY;
                s->queue[q].fmt=fmt;
            }
        }
        format_wire(out,type,&fmt);return 0;
    }
    case 8: { /* REQBUFS (MMAP only) */
        type=vmed_r32(in+4);q=queue_index(type);
        if(q<0||vmed_r32(in+8)!=VMED_MEMORY_MMAP)return VMED_EINVAL;
        u32 count=vmed_r32(in);if(count>VMED_MAX_BUFFERS)count=VMED_MAX_BUFFERS;
        if(!count&&s->queue[q].streaming)queue_streamoff(v,s,q);
        int error=queue_request(v,s,q,count);if(error)return error;
        memset(out,0,size);vmed_w32(out,count);vmed_w32(out+4,type);vmed_w32(out+8,VMED_MEMORY_MMAP);
        vmed_w32(out+12,1);return 0; /* SUPPORTS_MMAP, no orphaned-buffer claim */
    }
    case 9:case 15:case 93: { /* QUERYBUF / QBUF / PREPARE_BUF */
        index=vmed_r32(in);type=vmed_r32(in+4);q=queue_index(type);
        if(q<0||index>=s->queue[q].count||vmed_r32(in+60)!=VMED_MEMORY_MMAP)return VMED_EINVAL;
        VMediaBuffer *b=&s->queue[q].buffers[index];
        if(code!=9){
            if(b->queued)return VMED_EBUSY;
            u32 used=vmed_r32(in+8);
            if(used>b->bytes||(q==1&&!coded_queue(v,q)&&used&&used!=s->queue[q].fmt.bytes))return VMED_EINVAL;
            int64_t sec=(int64_t)vmed_r64(in+24),us=(int64_t)vmed_r64(in+32);
            if(sec<INT64_C(-9000000000)||sec>INT64_C(9000000000)||us<0||us>=1000000)return VMED_EINVAL;
            if(q==1&&s->draining)return VMED_EPIPE;
            b->used=q==1?used:0;b->pts=sec*INT64_C(1000000000)+us*1000;
            b->flags=code==93?UINT32_C(0x400):VMED_BUF_QUEUED;
            if(code==15){b->queued=true;b->order=++s->next_order;
                if(q==1&&!used)s->draining=true;}
        }
        buffer_wire(out,b,index,type,s->queue[q].sequence);return 0;
    }
    case 18:case 19:
        q=queue_index(vmed_r32(in));if(q<0)return VMED_EINVAL;
        if(code==19){queue_streamoff(v,s,q);return 0;}
        if(!s->queue[q].count)return VMED_EINVAL;
        s->queue[q].streaming=true;return 0;
    case 21:case 22: { /* G/S_PARM; timeperframe */
        type=vmed_r32(in);q=queue_index(type);if(q<0)return VMED_EINVAL;
        if(code==22){
            u32 num=vmed_r32(in+12),den=vmed_r32(in+16);
            if(!num||!den||(u64)den>240u*(u64)num||num>1000000||den>1000000)return VMED_EINVAL;
            if(s->codec)return VMED_EBUSY;s->fps_num=num;s->fps_den=den;
        }
        memset(out,0,size);vmed_w32(out,type);vmed_w32(out+4,UINT32_C(0x1000));
        vmed_w32(out+12,s->fps_num);vmed_w32(out+16,s->fps_den);return 0;
    }
    case 27:case 28:{
        int32_t value=(int32_t)vmed_r32(in+4);
        int error=control_value(v,s,vmed_r32(in),&value,code==28,true);
        vmed_w32(out+4,(u32)value);return error;
    }
    case 36:case 103: {
        u32 id=vmed_r32(in);const VMediaControl *control=NULL;
        if(id&UINT32_C(0xc0000000)){
            id&=UINT32_C(0x3fffffff);
            for(unsigned i=0;i<sizeof(media_controls)/sizeof(media_controls[0]);i++){
                const VMediaControl *candidate=control_find(v,media_controls[i].id);
                if(candidate&&candidate->id>id&&(!control||candidate->id<control->id))control=candidate;
            }
        }else control=control_find(v,id);
        if(!control)return VMED_EINVAL;
        memset(out,0,size);vmed_w32(out,control->id);vmed_w32(out+4,control->type);
        snprintf((char *)out+8,32,"%s",control->name);
        if(code==36){vmed_w32(out+40,(u32)control->min);vmed_w32(out+44,(u32)control->max);
            vmed_w32(out+48,(u32)control->step);vmed_w32(out+52,(u32)control->def);vmed_w32(out+56,control_flags(control));
        }else {vmed_w64(out+40,(u64)control->min);vmed_w64(out+48,(u64)control->max);
            vmed_w64(out+56,(u64)control->step);vmed_w64(out+64,(u64)control->def);
            vmed_w32(out+72,control_flags(control));vmed_w32(out+76,4);vmed_w32(out+80,1);}
        return 0;
    }
    case 37: { /* QUERYMENU for the implemented joined-header mode. */
        const VMediaControl *control=control_find(v,vmed_r32(in));
        u32 index=vmed_r32(in+4);
        if(!control||control->type!=3||index!=1)return VMED_EINVAL;
        memset(out,0,size);vmed_w32(out,control->id);vmed_w32(out+4,index);
        snprintf((char *)out+8,32,"Joined with first frame");return 0;
    }
    case 71:case 72:case 73: { /* scalar extended controls, packed 20-byte entries */
        u32 count=vmed_r32(in+4);
        if(count>32||in_len<size+(u64)count*20)return VMED_EINVAL;
        *out_len=size+count*20;memset(out,0,*out_len);memcpy(out,in,size);
        vmed_w64(out+24,0);vmed_w32(out+8,count);
        /* Validate the complete group before committing any setting. */
        for(unsigned pass=0;pass<(code==72?2u:1u);pass++)for(u32 i=0;i<count;i++){
            const u8 *c=in+size+i*20;u8 *d=out+size+i*20;memcpy(d,c,20);
            if(vmed_r32(c+4)){vmed_w32(out+8,i);return VMED_EINVAL;}
            int32_t value=(int32_t)vmed_r32(c+12);
            int error=control_value(v,s,vmed_r32(c),&value,code!=71,code==72&&pass==1);
            if(error){vmed_w32(out+8,i);return error;}
            vmed_w64(d+12,(u64)(int64_t)value);
        }
        return 0;
    }
    case 74:case 75:
        /* Exact per-codec resolution/fps bounds require a successful native
         * session; no invented hardware limits. S_FMT/session creation is
         * the authoritative validation path. */
        return VMED_ENOTTY;
    case 77:case 78:case 96:case 97: {
        if((v->direction==FLV_ENCODE)!=(code==77||code==78))return VMED_ENOTTY;
        u32 command=vmed_r32(in),flags=vmed_r32(in+4);
        if(command>1||flags)return VMED_EINVAL;
        memset(out,0,size);vmed_w32(out,command);
        if(code==78||code==97)return 0;
        if(command==1){s->draining=true;return 0;}
        if(!s->drained&&s->draining)return VMED_EBUSY;
        if(s->drained)codec_close(s);s->draining=s->drain_sent=s->drained=false;return 0;
    }
    case 90:case 91: {
        u32 ev=vmed_r32(in),flags=vmed_r32(in+8);
        if(ev!=VMED_EVENT_EOS&&ev!=VMED_EVENT_SOURCE_CHANGE&&!(code==91&&ev==0))return VMED_EINVAL;
        if(code==91){if(ev==0)s->subscriptions=0;else s->subscriptions&=~(1u<<ev);return 0;}
        if(flags&~1u)return VMED_EINVAL;
        s->subscriptions|=1u<<ev;
        if((flags&1)&&s->format_seen&&ev==VMED_EVENT_SOURCE_CHANGE&&!session_event(v,s,ev))return VMED_EAGAIN;
        return 0;
    }
    case 94: { /* G_SELECTION, full frame and no unimplemented crop/scale */
        q=queue_index(vmed_r32(in));if(q<0)return VMED_EINVAL;
        u32 target=vmed_r32(in+4);
        if(target!=0&&target!=1&&target!=2&&target!=UINT32_C(0x100)&&target!=UINT32_C(0x101)&&target!=UINT32_C(0x102))return VMED_EINVAL;
        memset(out,0,size);vmed_w32(out,vmed_r32(in));vmed_w32(out+4,target);
        vmed_w32(out+20,s->queue[q].fmt.width);vmed_w32(out+24,s->queue[q].fmt.height);return 0;
    }
    default:return VMED_ENOTTY;
    }
}

static void session_fault(VirtIOMedia *v,VMediaSession *s,int error) {
    if(s->faulted)return;
    codec_close(s);s->faulted=true;s->fault_errno=error?error:VMED_EIO;v->errors++;
}
static void fault_service(VirtIOMedia *v,VMediaSession *s) {
    if(s->fault_event_sent||!event_space(v,1))return;
    u8 e[16]={0};vmed_w32(e,VMED_EVT_ERROR);vmed_w32(e+4,s->id);vmed_w32(e+8,s->fault_errno);
    if(event_push(v,e,sizeof(e)))s->fault_event_sent=true;
}
static int frame_copy(VirtIOMedia *v,VMediaSession *s,const FLVOutput *out,VMediaBuffer *b) {
    VMediaFormat *f=&s->queue[0].fmt;
    if(out->plane_count!=2||out->pixel_format!=native_pixel(f->fourcc)||
       out->width!=f->width||out->height!=f->height||out->bytes>VMED_FRAME_LIMIT||
       !out->data||b->bytes<f->bytes)return VMED_EINVAL;
    u8 *flat=malloc(f->bytes);if(!flat)return VMED_ENOMEM;
    size_t offset=0;int error=0;
    for(unsigned plane=0;plane<2;plane++) {
        u32 rows=plane?f->height/2:f->height;
        u64 needed=rows?(u64)(rows-1)*out->plane_strides[plane]+f->stride:0;
        if(out->plane_strides[plane]<f->stride||out->plane_offsets[plane]>out->bytes||
           out->plane_bytes[plane]<needed||needed>out->bytes-out->plane_offsets[plane]){error=VMED_EINVAL;break;}
        for(u32 row=0;row<rows;row++){
            memcpy(flat+offset,out->data+out->plane_offsets[plane]+(u64)row*out->plane_strides[plane],f->stride);
            offset+=f->stride;
        }
    }
    if(!error){phys_write_blk(v->m,v->base+b->offset,flat,f->bytes);
        if(machine_bus_status(v->m)!=BUS_OK)error=VMED_EIO;}
    free(flat);return error;
}
static void output_release(VMediaSession *s) {
    if(s->have_pending&&s->codec)flv_session_release_output(s->codec,&s->pending);
    memset(&s->pending,0,sizeof(s->pending));s->have_pending=false;
}
/* Returns false when buffers/events impose backpressure. The retained host
 * token remains bounded by FLVHostConfig and is released on close/reset. */
static bool output_service(VirtIOMedia *v,VMediaSession *s) {
    if(!s->have_pending)return false;
    FLVOutput *o=&s->pending;
    if(o->kind==FLV_OUTPUT_ERROR||o->status<0){int error=media_error(o->status);session_fault(v,s,error);return true;}
    /* FORMAT carries avcC/hvcC bytes, not decoded picture metadata. Stateful
     * V4L2 learns CAPTURE dimensions from the first real frame, which can be
     * retained while userspace handles SOURCE_CHANGE/reallocates CAPTURE. */
    if(o->kind==FLV_OUTPUT_FORMAT){output_release(s);return true;}
    if(o->kind==FLV_OUTPUT_FRAME) {
        if(v->direction==FLV_DECODE) {
            VMediaFormat fmt={o->pixel_format==FLV_P010?VMED_FORMAT_P010:VMED_FORMAT_NV12,
                              o->width,o->height,0,0};
            if((o->pixel_format!=FLV_NV12&&o->pixel_format!=FLV_P010)||!o->width||!o->height||
               format_negotiate(v,s,0,&fmt)){session_fault(v,s,VMED_EINVAL);return true;}
            VMediaFormat *old=&s->queue[0].fmt;
            bool change=!s->format_seen||old->width!=fmt.width||old->height!=fmt.height||old->fourcc!=fmt.fourcc;
            if(change){
                if(!event_space(v,1))return false;
                *old=fmt;s->format_seen=true;
                if(!session_event(v,s,VMED_EVENT_SOURCE_CHANGE))return false;
            }
        }
    }
    if(o->kind!=FLV_OUTPUT_PACKET&&o->kind!=FLV_OUTPUT_FRAME&&o->kind!=FLV_OUTPUT_EOS){
        session_fault(v,s,VMED_EIO);return true;
    }
    if(!s->queue[0].streaming||!event_space(v,2))return false;
    u32 index=0;VMediaBuffer *b=oldest_buffer(&s->queue[0],&index);if(!b)return false;
    /* SOURCE_CHANGE may grow the picture while old CAPTURE buffers are
     * queued. Retain this bounded output until userspace consumes the event
     * and reallocates; an expected resolution change is not session failure. */
    if(o->kind==FLV_OUTPUT_FRAME&&b->bytes<s->queue[0].fmt.bytes)return false;
    u32 used=0,flags=0;int error=0;int64_t pts=o->pts_ns;
    if(o->kind==FLV_OUTPUT_EOS){flags=VMED_BUF_LAST;pts=0;}
    else {
        if(!o->hardware_used){
            int coded=v->direction==FLV_DECODE?1:0;
            const VMediaCodecMap *map=codec_for_fourcc(s->queue[coded].fmt.fourcc);
            const FLVCapability *cap=map?codec_capability(v,map->codec):NULL;
            if(!v->allow_native_software||!cap||!(cap->flags&FLV_CAP_NATIVE_SOFTWARE_PROBED)){
                session_fault(v,s,VMED_EIO);return true;
            }
        }
        if(o->kind==FLV_OUTPUT_PACKET){
            if(!o->data||!o->bytes||o->bytes>b->bytes||o->bytes>VMED_PACKET_LIMIT)error=VMED_ENOSPC;
            else {phys_write_blk(v->m,v->base+b->offset,o->data,o->bytes);used=(u32)o->bytes;
                if(machine_bus_status(v->m)!=BUS_OK)error=VMED_EIO;}
        }else {error=frame_copy(v,s,o,b);used=s->queue[0].fmt.bytes;}
        if(error){session_fault(v,s,error);return true;}
        if(o->flags&FLV_KEYFRAME)flags|=VMED_BUF_KEYFRAME;
    }
    bool eos=o->kind==FLV_OUTPUT_EOS;
    if(!buffer_event(v,s,0,index,flags,used,pts))return false;
    if(!eos){
        if(o->hardware_used)v->hardware_outputs++;
        else v->native_software_outputs++;
    }
    output_release(s);
    if(eos){s->drained=true;session_event(v,s,VMED_EVENT_EOS);}
    return true;
}
static int input_submit(VirtIOMedia *v,VMediaSession *s,VMediaBuffer *b) {
    if(!s->codec){int error=codec_open(v,s);if(error)return error;}
    u32 bytes=b->used;
    if(!bytes)return 0;
    if(bytes>(coded_queue(v,1)?VMED_PACKET_LIMIT:VMED_FRAME_LIMIT))return VMED_EINVAL;
    u8 *data=malloc(bytes);if(!data)return VMED_ENOMEM;
    phys_read_blk(v->m,v->base+b->offset,data,bytes);
    if(machine_bus_status(v->m)!=BUS_OK){free(data);return VMED_EIO;}
    int status;
    int64_t duration=(int64_t)((u64)s->fps_num*UINT64_C(1000000000)/s->fps_den);
    u64 tag=++s->next_tag;
    if(v->direction==FLV_DECODE){
        FLVPacket packet={0};packet.data=data;packet.bytes=bytes;
        packet.pts_ns=packet.dts_ns=b->pts;packet.duration_ns=duration;packet.tag=tag;
        status=flv_session_submit_packet(s->codec,&packet);
    }else {
        VMediaFormat *f=&s->queue[1].fmt;
        if(bytes!=f->bytes){free(data);return VMED_EINVAL;}
        FLVFrame frame={0};frame.data=data;frame.bytes=bytes;
        frame.width=f->width;frame.height=f->height;frame.pixel_format=native_pixel(f->fourcc);frame.plane_count=2;
        frame.plane_offsets[1]=(u64)f->stride*f->height;
        frame.plane_bytes[0]=frame.plane_offsets[1];frame.plane_bytes[1]=bytes-frame.plane_offsets[1];
        frame.plane_strides[0]=frame.plane_strides[1]=f->stride;
        frame.pts_ns=b->pts;frame.duration_ns=duration;frame.tag=tag;
        frame.flags=s->force_keyframe?FLV_KEYFRAME:0;
        status=flv_session_submit_frame(s->codec,&frame);
        if(status==FLV_OK)s->force_keyframe=false;
    }
    free(data);if(status==FLV_OK)v->submitted++;return media_error(status);
}
static void session_service(VirtIOMedia *v,VMediaSession *s) {
    if(s->faulted){fault_service(v,s);return;}
    /* Events and outputs are bounded, and consuming no progress returns to
     * the coordinator instead of spinning on a missing capture buffer. */
    for(unsigned work=0;work<64;work++) {
        bool progress=false;
        if(s->codec&&!s->have_pending){
            int status=flv_session_dequeue(s->codec,&s->pending);
            if(status==FLV_OK){s->have_pending=true;progress=true;}
            else if(status!=FLV_AGAIN){session_fault(v,s,media_error(status));break;}
        }
        if(s->have_pending)progress|=output_service(v,s);
        if(s->faulted)break;
        u32 index=0;VMediaBuffer *b=oldest_buffer(&s->queue[1],&index);
        bool may_submit=s->queue[1].streaming&&!s->drain_sent&&
            (v->direction==FLV_DECODE||s->queue[0].streaming);
        if(b&&may_submit&&event_space(v,1)){
            int error=b->used?input_submit(v,s,b):0;
            if(error&&error!=VMED_EAGAIN){session_fault(v,s,error);break;}
            if(!error){if(!b->used)s->draining=true;
                buffer_event(v,s,1,index,0,b->used,b->pts);progress=true;}
        }else if(!b&&s->draining&&!s->drain_sent&&s->queue[1].streaming){
            if(!s->codec){
                u32 cap_index=0;VMediaBuffer *capture=oldest_buffer(&s->queue[0],&cap_index);
                if(capture&&s->queue[0].streaming&&event_space(v,2)){
                    buffer_event(v,s,0,cap_index,VMED_BUF_LAST,0,0);session_event(v,s,VMED_EVENT_EOS);
                    s->drain_sent=s->drained=true;progress=true;
                }
            }else {
                int status=flv_session_flush(s->codec,1);
                if(status==FLV_OK){s->drain_sent=true;progress=true;}
                else if(status!=FLV_AGAIN){session_fault(v,s,media_error(status));break;}
            }
        }
        if(!progress)break;
        if(work==63)atomic_store_explicit(&v->ready,true,memory_order_release);
    }
    if(s->faulted)fault_service(v,s);
}

static VMediaBuffer *buffer_at_offset(VirtIOMedia *v,VMediaSession *only,u64 offset) {
    for(unsigned i=0;i<v->max_sessions;i++){
        VMediaSession *s=&v->sessions[i];if(!s->id||(only&&s!=only))continue;
        for(unsigned q=0;q<2;q++)for(unsigned j=0;j<s->queue[q].count;j++)
            if(s->queue[q].buffers[j].offset==offset)return &s->queue[q].buffers[j];
    }
    return NULL;
}
static void command_service(VirtIOMedia *v) {
    VMediaRing *ring=&v->ring[VMED_Q_COMMAND];
    for(unsigned work=0;work<VMED_Q_MAX;work++){
        VMediaChain chain;bool empty;
        if(!chain_next(v,ring,&chain,&empty)){media_fail(v);return;}
        if(empty)return;
        u8 request[VMED_MAX_COMMAND]={0},response[VMED_MAX_COMMAND]={0};u32 response_len=8;
        if(chain.read_bytes<8||!chain_read(v,&chain,request)){media_fail(v);return;}
        u32 cmd=vmed_r32(request),id=chain.read_bytes>=12?vmed_r32(request+8):0;
        VMediaSession *s=session_find(v,id);int error=0;
        if(cmd==VMED_CLOSE){
            if(chain.read_bytes!=16||chain.write_bytes){media_fail(v);return;}
            if(s)session_close(v,s);
            if(!ring_complete(v,ring,chain.head,0)){media_fail(v);return;}continue;
        }
        u32 minimum=cmd==VMED_OPEN?16:cmd==VMED_MMAP?24:8;
        if(cmd==VMED_IOCTL&&chain.read_bytes>=16){
            u32 code=vmed_r32(request+12),size=ioctl_size(code);
            minimum=8+(ioctl_write_only(code)?0:size);
            if(code>=71&&code<=73&&chain.read_bytes>=48){
                u32 count=vmed_r32(request+20);if(count<=32)minimum+=count*20;
            }
        }
        if(minimum>chain.write_bytes){media_fail(v);return;}
        if(vmed_r32(request+4))error=VMED_EINVAL;
        else switch(cmd){
        case VMED_OPEN:
            response_len=16;
            if(chain.read_bytes!=8)error=VMED_EINVAL;
            else {u32 session_id=0;error=session_open(v,&session_id);vmed_w32(response+8,session_id);}
            break;
        case VMED_IOCTL:
            if(chain.read_bytes<16||!s)error=VMED_EINVAL;
            else if(s->faulted)error=VMED_EIO;
            else {u32 payload=0;error=ioctl_execute(v,s,vmed_r32(request+12),request+16,chain.read_bytes-16,response+8,&payload);
                response_len=8+payload;}
            break;
        case VMED_MMAP:{
            response_len=24;
            if(chain.read_bytes!=20||!s||(vmed_r32(request+12)&~1u)){error=VMED_EINVAL;break;}
            VMediaBuffer *b=buffer_at_offset(v,s,vmed_r32(request+16));
            if(!b||b->maps==UINT32_MAX){error=VMED_EINVAL;break;}
            b->maps++;vmed_w64(response+8,b->offset);
            vmed_w64(response+16,((u64)b->bytes+VMED_PAGE-1)&~(u64)(VMED_PAGE-1));break;
        }
        case VMED_MUNMAP:{
            if(chain.read_bytes!=16){error=VMED_EINVAL;break;}
            VMediaBuffer *b=buffer_at_offset(v,NULL,vmed_r64(request+8));
            if(!b||!b->maps){error=VMED_EINVAL;break;}b->maps--;break;
        }
        default:error=VMED_ENOTTY;break;
        }
        vmed_w32(response,(u32)error);
        if(!chain_write(v,&chain,response,response_len)||!ring_complete(v,ring,chain.head,response_len)){
            media_fail(v);return;
        }
    }
}
static void device_service(VirtIOMedia *v) {
    if(!v||v->closing||(v->status&VMED_NEEDS_RESET)||!(v->status&VMED_DRIVER_OK))return;
    atomic_store_explicit(&v->ready,false,memory_order_release);
    events_service(v);
    for(unsigned i=0;i<v->max_sessions;i++)if(v->sessions[i].id)session_service(v,&v->sessions[i]);
    events_service(v);
}
bool virtio_media_has_work(Machine *m) {
    for(unsigned i=0;i<2;i++)if(m->video[i]&&atomic_load_explicit(&m->video[i]->ready,memory_order_acquire))return true;
    return false;
}
void virtio_media_service(Machine *m) {
    for(unsigned i=0;i<2;i++)if(m->video[i])device_service(m->video[i]);
}
void virtio_media_get_stats(Machine *m,VirtIOMediaStats *out) {
    memset(out,0,sizeof(*out));
    for(unsigned i=0;i<2;i++)if(m->video[i]){
        VirtIOMedia *v=m->video[i];FLVStats host={0};out->nodes++;
        if(flv_host_get_stats(v->host,&host)==FLV_OK){out->sessions+=host.sessions;out->inflight+=host.inflight;
            out->queued_outputs+=host.queued_outputs;out->host_owned_bytes+=host.owned_bytes;out->host_peak_bytes+=host.peak_owned_bytes;}
        out->owned_mmap_bytes+=v->owned_mmap_bytes;out->submitted+=v->submitted;
        out->hardware_outputs+=v->hardware_outputs;out->errors+=v->errors;
        out->native_software_outputs+=v->native_software_outputs;
        out->native_software_enabled|=v->allow_native_software?1u:0u;
        for(size_t j=0;j<v->capability_count;j++){
            const FLVCapability *cap=&v->capabilities[j];
            if(cap->direction!=v->direction||!(cap->flags&FLV_CAP_IMPLEMENTED)||
               !(cap->flags&FLV_CAP_NATIVE_SOFTWARE_PROBED))continue;
            if(cap->codec>=1&&cap->codec<=11){
                u32 bit=(cap->codec-1u)*2u+(cap->direction==FLV_DECODE?1u:0u);
                out->native_software_mask|=1u<<bit;out->native_software_formats++;
            }
        }
    }
}
int virtio_media_set_native_software(Machine *m,bool enabled) {
    /* Validate all nodes before committing either one. No open session may
     * see its format enumeration/backend policy change beneath it. */
    for(unsigned i=0;i<2;i++)if(m->video[i]){
        VirtIOMedia *v=m->video[i];
        if(v->allow_native_software==enabled)continue;
        for(unsigned j=0;j<v->max_sessions;j++)if(v->sessions[j].id)return VMED_EBUSY;
    }
    for(unsigned i=0;i<2;i++)if(m->video[i])m->video[i]->allow_native_software=enabled;
    return 0;
}
void virtio_media_reset(VirtIOMedia *v) {
    if(!v)return;
    for(unsigned i=0;i<v->max_sessions;i++)if(v->sessions[i].id)session_close(v,&v->sessions[i]);
    v->status=v->isr=v->dev_feat_sel=v->drv_feat_sel=v->queue_sel=v->shm_sel=0;
    v->driver_features=0;memset(v->ring,0,sizeof(v->ring));
    v->event_head=v->event_count=0;atomic_store_explicit(&v->ready,false,memory_order_release);
    gic_set_irq(v->gic,v->irq,0);
}
static u64 media_read(void *opaque,u64 off,unsigned size) {
    VirtIOMedia *v=opaque;
    if(off>=0x100){
        u8 config[40]={0};vmed_w32(config,VMED_CAPS);vmed_w32(config+4,0); /* VFL_TYPE_VIDEO */
        snprintf((char *)config+8,32,"Floe native video %s",v->direction==FLV_DECODE?"decoder":"encoder");
        u64 value=0,pos=off-0x100;
        for(unsigned i=0;i<size&&i<8&&pos+i<sizeof(config);i++)value|=(u64)config[pos+i]<<(i*8);
        return value;
    }
    if(size!=4||(off&3))return 0;
    VMediaRing *q=v->queue_sel<2?&v->ring[v->queue_sel]:NULL;
    switch(off){
    case 0x000:return UINT32_C(0x74726976);case 0x004:return 2;case 0x008:return 48;
    case 0x00c:return UINT32_C(0x464c4f45);
    case 0x010:return v->dev_feat_sel==1?1u:0;
    case 0x034:return q?VMED_Q_MAX:0;case 0x038:return q?q->num:0;
    case 0x044:return q?q->ready:0;case 0x060:return v->isr;case 0x070:return v->status;
    case 0x0b0:return v->shm_sel==0?(u32)FLOE_VIDEO_APERTURE_BYTES:UINT32_MAX;
    case 0x0b4:return v->shm_sel==0?(u32)(FLOE_VIDEO_APERTURE_BYTES>>32):UINT32_MAX;
    case 0x0b8:return v->shm_sel==0?(u32)v->base:0;
    case 0x0bc:return v->shm_sel==0?(u32)(v->base>>32):0;
    case 0x0fc:return 0;
    default:return 0;
    }
}
static void media_write(void *opaque,u64 off,unsigned size,u64 value) {
    VirtIOMedia *v=opaque;if(size!=4||(off&3))return;u32 val=(u32)value;
    VMediaRing *q=v->queue_sel<2?&v->ring[v->queue_sel]:NULL;
    switch(off){
    case 0x014:v->dev_feat_sel=val;break;
    case 0x020:
        if(v->drv_feat_sel<2){u32 shift=v->drv_feat_sel*32;v->driver_features=(v->driver_features&~(UINT64_C(0xffffffff)<<shift))|((u64)val<<shift);}break;
    case 0x024:v->drv_feat_sel=val;break;case 0x030:v->queue_sel=val;break;
    case 0x038:if(q&&!q->ready)q->num=val;break;
    case 0x044:
        if(q){if(val>1||(val&&!ring_spans(v,q)))media_fail(v);else {q->ready=val;if(!val)q->last=0;}}
        break;
    case 0x050:
        if((v->status&VMED_DRIVER_OK)&&!(v->status&VMED_NEEDS_RESET)){
            if(val==0)command_service(v);
            else if(val!=1){media_fail(v);break;}
            device_service(v);
        }break;
    case 0x064:v->isr&=~(val&3u);gic_set_irq(v->gic,v->irq,v->isr!=0);break;
    case 0x070:
        if(!val){virtio_media_reset(v);break;}
        if((val&8)&&v->driver_features!=VMED_MODERN)val&=~8u;
        v->status=(val&UINT32_C(0xff))|(v->status&VMED_NEEDS_RESET);
        if((v->status&VMED_DRIVER_OK)&&!(v->status&8))media_fail(v);
        break;
    case 0x080:if(q&&!q->ready)q->desc=(q->desc&UINT64_C(0xffffffff00000000))|val;break;
    case 0x084:if(q&&!q->ready)q->desc=(q->desc&UINT64_C(0xffffffff))|((u64)val<<32);break;
    case 0x090:if(q&&!q->ready)q->avail=(q->avail&UINT64_C(0xffffffff00000000))|val;break;
    case 0x094:if(q&&!q->ready)q->avail=(q->avail&UINT64_C(0xffffffff))|((u64)val<<32);break;
    case 0x0a0:if(q&&!q->ready)q->used=(q->used&UINT64_C(0xffffffff00000000))|val;break;
    case 0x0a4:if(q&&!q->ready)q->used=(q->used&UINT64_C(0xffffffff))|((u64)val<<32);break;
    case 0x0ac:v->shm_sel=val;break;
    default:break;
    }
}
VirtIOMedia *virtio_media_create(Machine *m,GIC *gic,int slot,const VirtIOMediaOptions *options) {
    if(!m||!gic||!options||(options->direction!=FLV_ENCODE&&options->direction!=FLV_DECODE)||
       options->max_sessions>VMED_MAX_SESSIONS)return NULL;
    VirtIOMedia *v=calloc(1,sizeof(*v));if(!v)return NULL;
    v->m=m;v->gic=gic;v->slot=slot;v->irq=INTID_VIRTIO0+slot;v->region=-1;
    v->wake_fd=options->wake_fd;v->direction=options->direction;
    v->broker_port=options->broker_port;v->broker_token=options->broker_token;
    v->max_sessions=options->max_sessions?options->max_sessions:VMED_MAX_SESSIONS;
    v->base=v->direction==FLV_DECODE?FLOE_VIDEO_DECODER_BASE:FLOE_VIDEO_ENCODER_BASE;
    atomic_init(&v->ready,false);
    v->pages=calloc(VMED_PAGES,1);if(!v->pages){free(v);return NULL;}
    FLVHostConfig cfg={0};cfg.abi_version=FLV_ABI_VERSION;cfg.max_sessions=v->max_sessions;
    cfg.max_inflight_per_session=8;cfg.max_packet_bytes=VMED_PACKET_LIMIT;cfg.max_frame_bytes=VMED_FRAME_LIMIT;
    cfg.max_owned_bytes=options->host_owned_limit?options->host_owned_limit:VMED_DEFAULT_HOST_LIMIT;
    cfg.notify=media_notify;cfg.notify_opaque=v;
    if(flv_host_create(&cfg,&v->host)!=FLV_OK)goto fail;
    size_t count=0;
    if(flv_host_query_capabilities(v->host,v->capabilities,22,&count)!=FLV_OK||count>22)goto fail;
    v->capability_count=count;
    v->region=machine_region_add(m,v->base,FLOE_VIDEO_APERTURE_BYTES,false,
                                v->direction==FLV_DECODE?"video-decoder":"video-encoder");
    if(v->region<0)goto fail;
    if(m->ndev>=MAX_DEVS)goto fail;
    machine_add_device(m,UINT64_C(0x0a000000)+(u64)slot*0x200,0x200,media_read,media_write,v,"virtio-media");
    return v;
fail:
    if(v->region>=0)machine_region_remove(m,v->region);
    if(v->host)flv_host_destroy(v->host);
    free(v->pages);free(v);return NULL;
}
void virtio_media_destroy(VirtIOMedia *v) {
    if(!v)return;v->closing=true;
    for(unsigned i=0;i<v->max_sessions;i++)if(v->sessions[i].id)session_close(v,&v->sessions[i]);
    /* Joining the host is a callback barrier before opaque/fd/backing release. */
    if(v->host)flv_host_destroy(v->host);v->host=NULL;
    if(v->region>=0)machine_region_remove(v->m,v->region);
    free(v->pages);free(v);
}

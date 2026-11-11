/* Copyright 2026 Floe contributors; SPDX-License-Identifier: Apache-2.0 */
/* Coordinator-owned resources; renderer accounting keeps physical backing
 * charged while exported fds or aliases outlive the creating context. */
#include "fvgpu_priv.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <limits.h>

static int context_slot(FloeGPUSession *s,uint32_t id) {
    for(unsigned i=0;i<FVGPU_MAX_CONTEXTS;i++)
        if(s->contexts[i].used&&s->contexts[i].ctx_id==id) return (int)i;
    return -1;
}
struct fvgpu_resource_entry *fvgpu_resource_find(FloeGPUSession *s,uint32_t id) {
    for(unsigned i=0;i<512;i++) if(s->resources[i].used&&s->resources[i].res_id==id) return &s->resources[i];
    return NULL;
}
static struct fvgpu_resource_entry *allocate_slot(FloeGPUSession *s,uint32_t id) {
    for(unsigned i=0;i<512;i++) if(!s->resources[i].used) {
        struct fvgpu_resource_entry *e=&s->resources[i];
        memset(e,0,sizeof(*e));e->used=true;e->res_id=id;e->fd=-1;return e;
    }
    return NULL;
}
static uint64_t page_align(uint64_t value) {
    long page=sysconf(_SC_PAGESIZE);
    if(page<=0||((uint64_t)page&((uint64_t)page-1))||value>UINT64_MAX-(uint64_t)page+1) return 0;
    return (value+(uint64_t)page-1)&~((uint64_t)page-1);
}
int floe_gpu_resource_create_blob(FloeGPUSession *s,uint32_t ctx,uint32_t id,
    uint32_t memory,uint32_t flags,uint64_t blob_id,uint64_t size,
    const struct iovec *iov,uint32_t niov,void **ptr,uint64_t *mapped_size,int *out_fd) {
    if(!ptr||!mapped_size||!out_fd) return FLOE_GPU_RESP_INVALID;
    *ptr=NULL;*mapped_size=0;*out_fd=-1;
    int slot=context_slot(s,ctx);
    uint64_t rounded=page_align(size);
    if(slot<0||!id||!size||!rounded||rounded>SIZE_MAX||fvgpu_resource_find(s,id)) return FLOE_GPU_RESP_INVALID;
    /* No generic virgl iovec table exists in this standalone vkr renderer.
     * Do not fake a coherent GUEST/HOST3D_GUEST import with a one-time copy. */
    if(memory!=VIRGL_RENDERER_BLOB_MEM_HOST3D||niov) return FLOE_GPU_RESP_INVALID;
    struct fvgpu_resource_entry *e=allocate_slot(s,id);
    if(!e) return FLOE_GPU_RESP_OUT_OF_MEMORY;
    enum virgl_resource_fd_type type;int fd=-1;uint32_t map_info=0;
    struct virgl_resource_vulkan_info vk_info={0};
    if(!vkr_renderer_create_resource(ctx,id,blob_id,size,flags,&type,&fd,&map_info,&vk_info)) {
        memset(e,0,sizeof(*e));return FLOE_GPU_RESP_OUT_OF_MEMORY;
    }
    uint64_t key=vkr_renderer_resource_accounting_key(ctx,id);
    if(fd<0||!key||!vkr_accounting_ref(key)) {
        if(fd>=0) close(fd);vkr_renderer_destroy_resource(ctx,id);memset(e,0,sizeof(*e));return FLOE_GPU_RESP_ERR_UNSPEC;
    }
    e->ctx_id=ctx;e->creator_alive=true;e->context_mask=1ull<<slot;e->accounting_key=key;
    e->is_blob=true;e->fd=fd;e->fd_type=type;e->blob_size=rounded;
    /* Mappable Apple blobs are SHM; an opaque fd is not assumed mmap-able. */
    if(flags&VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE) {
        int rc=floe_gpu_resource_map_transport(s,id,0,ptr,mapped_size);
        if(rc) {floe_gpu_resource_unref(s,id);return rc;}
    }
    *out_fd=fd;return FLOE_GPU_RESP_OK;
}
int floe_gpu_resource_map_transport(FloeGPUSession *s,uint32_t id,uint64_t offset,void **ptr,uint64_t *len) {
    struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);
    if(!e||!ptr||!len||e->fd<0||offset>=e->blob_size||e->fd_type!=VIRGL_RESOURCE_FD_SHM) return FLOE_GPU_RESP_INVALID;
    if(!e->ptr) {
        void *mapped=mmap(NULL,(size_t)e->blob_size,PROT_READ|PROT_WRITE,MAP_SHARED,e->fd,0);
        if(mapped==MAP_FAILED) return FLOE_GPU_RESP_ERR_UNSPEC;
        e->ptr=mapped;e->size=e->blob_size;
    }
    *ptr=(uint8_t *)e->ptr+offset;*len=e->size-offset;return FLOE_GPU_RESP_OK;
}
int floe_gpu_resource_unmap_transport(FloeGPUSession *s,uint32_t id) {
    struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);
    if(!e||!e->ptr) return FLOE_GPU_RESP_INVALID;
    if(munmap(e->ptr,(size_t)e->size)) return FLOE_GPU_RESP_ERR_UNSPEC;
    e->ptr=NULL;e->size=0; /* keep resource fd/length/ref for a later remap */
    return FLOE_GPU_RESP_OK;
}
int floe_gpu_resource_attach_iov(FloeGPUSession *s,uint32_t id,const struct iovec *iov,uint32_t niov) {
    (void)s;(void)id;(void)iov;(void)niov;return FLOE_GPU_RESP_INVALID;
}
int floe_gpu_ctx_attach_resource(FloeGPUSession *s,uint32_t ctx,uint32_t id) {
    int slot=context_slot(s,ctx);struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);
    if(slot<0||!e) return FLOE_GPU_RESP_INVALID;
    if(e->context_mask&(1ull<<slot)) return FLOE_GPU_RESP_OK;
    int fd=fcntl(e->fd,F_DUPFD_CLOEXEC,0);
    if(fd<0) return FLOE_GPU_RESP_ERR_UNSPEC;
    bool imported=vkr_renderer_import_resource(ctx,id,e->fd_type,fd,e->blob_size);
    /* SHM imports own their new mmap, not this transient fd. Opaque imports
     * take ownership of fd on success. The original resource fd stays ours. */
    if(!imported||e->fd_type==VIRGL_RESOURCE_FD_SHM) close(fd);
    if(!imported) return FLOE_GPU_RESP_ERR_UNSPEC;
    if(!vkr_renderer_resource_accounting_import(ctx,id,e->accounting_key)) {
        vkr_renderer_destroy_resource(ctx,id);return FLOE_GPU_RESP_ERR_UNSPEC;
    }
    e->context_mask|=1ull<<slot;return FLOE_GPU_RESP_OK;
}
int floe_gpu_ctx_detach_resource(FloeGPUSession *s,uint32_t ctx,uint32_t id) {
    int slot=context_slot(s,ctx);struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);
    if(slot<0||!e) return FLOE_GPU_RESP_INVALID;
    /* The creating resource remains until UNREF; imported context aliases can
     * be removed independently. A recreated context has a cleared slot bit. */
    if(e->creator_alive&&ctx==e->ctx_id&&(e->context_mask&(1ull<<slot))) return FLOE_GPU_RESP_OK;
    if(e->context_mask&(1ull<<slot)) {vkr_renderer_destroy_resource(ctx,id);e->context_mask&=~(1ull<<slot);}
    return FLOE_GPU_RESP_OK;
}
int floe_gpu_resource_unref(FloeGPUSession *s,uint32_t id) {
    struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);
    if(!e) return FLOE_GPU_RESP_INVALID;
    if(e->ptr) {munmap(e->ptr,(size_t)e->size);e->ptr=NULL;}
    if(e->fd>=0) {close(e->fd);e->fd=-1;}
    for(unsigned i=0;i<FVGPU_MAX_CONTEXTS;i++)
        if((e->context_mask&(1ull<<i))&&s->contexts[i].used)
            vkr_renderer_destroy_resource(s->contexts[i].ctx_id,id);
    vkr_accounting_unref(e->accounting_key);
    memset(e,0,sizeof(*e));return FLOE_GPU_RESP_OK;
}
void fvgpu_resources_destroy_all(FloeGPUSession *s) {
    for(unsigned i=0;i<512;i++) if(s->resources[i].used) floe_gpu_resource_unref(s,s->resources[i].res_id);
}
void fvgpu_resource_remove(FloeGPUSession *s,uint32_t id) {
    struct fvgpu_resource_entry *e=fvgpu_resource_find(s,id);if(e) memset(e,0,sizeof(*e));
}

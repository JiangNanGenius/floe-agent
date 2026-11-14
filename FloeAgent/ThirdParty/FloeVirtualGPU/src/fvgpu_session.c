/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_session.c — session lifecycle, renderer init, caps, contexts.
 * Built on the pinned Venus renderer public API (vkr_renderer.h) and the
 * virglrenderer unstable public header. Single-threaded entry contract;
 * renderer retire callbacks enqueue completions (see fvgpu_priv.h). */
#include "fvgpu_priv.h"

#include <stdlib.h>
#include <string.h>

/* ---- renderer retire callback (may run on a renderer thread) ----------- */
static void
fvgpu_retire_fence_cb(uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id)
{
    fvgpu_enqueue_completion(ctx_id, ring_idx, fence_id);
}

/* Explicit callback owner remains alive until renderer threads join. */
static void fvgpu_accounting_cb(uint64_t bytes,uint32_t type,bool alias,bool alloc,uint64_t key,void *user) {
    (void)type;(void)key;fvgpu_ledger_event(user,bytes,alias,false,alloc);
}
static void fvgpu_blob_accounting_cb(uint64_t bytes,uint32_t type,bool alias,bool alloc,uint64_t key,void *user) {
    (void)type;(void)key;fvgpu_ledger_event(user,bytes,alias,true,alloc);
}
static bool fvgpu_admit(uint64_t bytes,bool alias,bool blob,void *user) {
    (void)blob;return fvgpu_ledger_reserve(user,bytes,alias);
}
static void fvgpu_cancel(uint64_t bytes,bool alias,bool blob,void *user) {
    (void)blob;fvgpu_ledger_cancel(user,bytes,alias);
}
static pthread_mutex_t lifecycle_lock=PTHREAD_MUTEX_INITIALIZER;
static bool renderer_owned;

static void
fvgpu_debug_logger(enum virgl_log_level_flags level, const char *msg, void *user_data)
{
    (void)level;
    (void)user_data;
    flockfile(stderr);
    fprintf(stderr, "[virgl] %s\n", msg ? msg : "");
    funlockfile(stderr);
}

/* ---- vulkan identity probe (direct, not via renderer) ------------------- */
static void
fvgpu_fill_device_identity(FloeGPUSession *s)
{
    /* We intentionally use the Vulkan API directly for identity so the
     * report is independent of renderer state. On failure the fields stay
     * zero — honest, not fabricated. */
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &(VkApplicationInfo){
            .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "floe-virtual-gpu",
            .apiVersion = VK_API_VERSION_1_1,
        },
    };
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS)
        return;
    uint32_t n = 0;
    if (vkEnumeratePhysicalDevices(inst, &n, NULL) || !n) {
        vkDestroyInstance(inst, NULL);
        return;
    }
    if(n>64) {vkDestroyInstance(inst,NULL);return;}
    VkPhysicalDevice *devices=calloc(n,sizeof(*devices));
    if(!devices) {vkDestroyInstance(inst,NULL);return;}
    VkResult listed=vkEnumeratePhysicalDevices(inst,&n,devices);
    if((listed!=VK_SUCCESS&&listed!=VK_INCOMPLETE)||!n) {free(devices);vkDestroyInstance(inst,NULL);return;}
    VkPhysicalDevice pdev=devices[0];free(devices);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pdev, &props);
    snprintf(s->info.device_name, sizeof(s->info.device_name), "%s", props.deviceName);
    switch (props.deviceType) {
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: strcpy(s->info.device_type, "integrated"); break;
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: strcpy(s->info.device_type, "discrete"); break;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: strcpy(s->info.device_type, "virtual"); break;
    case VK_PHYSICAL_DEVICE_TYPE_CPU: strcpy(s->info.device_type, "cpu"); break;
    default: strcpy(s->info.device_type, "other"); break;
    }
    s->info.api_version = props.apiVersion;
    s->info.vendor_id = props.vendorID;
    s->info.device_id = props.deviceID;

    uint32_t next = 0;
    vkEnumerateDeviceExtensionProperties(pdev, NULL, &next, NULL);
    VkExtensionProperties *exts = calloc(next ? next : 1, sizeof(*exts));
    if(!exts) {vkDestroyInstance(inst,NULL);return;}
    if(vkEnumerateDeviceExtensionProperties(pdev,NULL,&next,exts)!=VK_SUCCESS) next=0;
    for (uint32_t i = 0; i < next; i++) {
        if (!strcmp(exts[i].extensionName, VK_KHR_DRIVER_PROPERTIES_EXTENSION_NAME)) {
            VkPhysicalDeviceDriverProperties drv = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
            };
            VkPhysicalDeviceProperties2 p2 = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                .pNext = &drv,
            };
            vkGetPhysicalDeviceProperties2(pdev, &p2);
            snprintf(s->info.driver_info, sizeof(s->info.driver_info), "%s", drv.driverInfo);
        }
    }
    free(exts);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    if (mp.memoryHeapCount)
        s->info.host_heap_size_bytes = mp.memoryHeaps[0].size;
    vkDestroyInstance(inst, NULL);
}

static FloeGPUSession *
create_session(const FloeGPUDeviceInfo **info,const char *app_group,char *err,size_t err_size) {
    if(info) *info=NULL;
    pthread_mutex_lock(&lifecycle_lock);
    if(renderer_owned||vkr_accounting_entry_count()!=0) {
        if(err&&err_size) snprintf(err,err_size,"renderer already owned or retained allocations remain");
        pthread_mutex_unlock(&lifecycle_lock);return NULL;
    }
    if(app_group) {
        size_t n=strnlen(app_group,29);
        bool valid=n>6&&n<=28&&!strncmp(app_group,"group.",6)&&!strstr(app_group,"..");
        for(size_t i=0;valid&&i<n;i++) {
            unsigned char c=(unsigned char)app_group[i];
            if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='-')) valid=false;
        }
        const char *existing=getenv("APP_SANDBOX_GROUP_ID");
        if(!valid||(existing&&*existing&&strcmp(existing,app_group))||setenv("APP_SANDBOX_GROUP_ID",app_group,1)) {
            if(err&&err_size) snprintf(err,err_size,"invalid or conflicting shared-memory namespace");
            pthread_mutex_unlock(&lifecycle_lock);return NULL;
        }
    }
    FloeGPUSession *s=calloc(1,sizeof(*s));
    if(!s) {if(err&&err_size) snprintf(err,err_size,"oom");pthread_mutex_unlock(&lifecycle_lock);return NULL;}
    renderer_owned=true;
    s->budget.limit_bytes=s->budget.requested_bytes=s->budget.target_bytes=FLOE_GPU_DEFAULT_BUDGET_BYTES;
    s->capacity_max_bytes=2ull<<30;
    pthread_mutex_init(&s->res_lock,NULL);pthread_mutex_init(&s->comp_lock,NULL);pthread_cond_init(&s->comp_cond,NULL);
    fvgpu_ledger_init(s);
    static const struct vkr_renderer_callbacks callbacks={
        .debug_logger=fvgpu_debug_logger,.retire_fence=fvgpu_retire_fence_cb};
    if(!vkr_renderer_init(VKR_RENDERER_THREAD_SYNC|VKR_RENDERER_ASYNC_FENCE_CB,&callbacks)) {
        if(err&&err_size) snprintf(err,err_size,"vkr_renderer_init failed");
        fvgpu_ledger_fini(s);pthread_cond_destroy(&s->comp_cond);pthread_mutex_destroy(&s->comp_lock);pthread_mutex_destroy(&s->res_lock);
        free(s);renderer_owned=false;pthread_mutex_unlock(&lifecycle_lock);return NULL;
    }
    s->info.venus_enabled=true;s->info.num_capsets=1;
    struct virgl_renderer_capset_venus venus={0};
    s->info.venus_capset_size=(uint32_t)vkr_get_capset(&venus,0);
    s->info.venus_capset_version=venus.wire_format_version;
    fvgpu_fill_device_identity(s);
    vkr_accounting_set_callback(fvgpu_accounting_cb,s);
    vkr_accounting_set_blob_callback(fvgpu_blob_accounting_cb,s);
    vkr_accounting_set_admission(fvgpu_admit,fvgpu_cancel,s);
    fvgpu_bind_current_session(s);
    if(info) *info=&s->info;
    pthread_mutex_unlock(&lifecycle_lock);return s;
}
FloeGPUSession *floe_gpu_session_create(const FloeGPUDeviceInfo **info,char *err,size_t size) {
    return create_session(info,NULL,err,size);
}
FloeGPUSession *floe_gpu_session_create_in_app_group(const FloeGPUDeviceInfo **info,const char *group,char *err,size_t size) {
    return create_session(info,group,err,size);
}
void floe_gpu_session_destroy(FloeGPUSession *s) {
    if(!s) return;
    pthread_mutex_lock(&lifecycle_lock);
    /* The unbind lock is a real in-flight callback barrier. Keep ledger hooks
     * installed until every resource, context and renderer worker is gone. */
    fvgpu_bind_current_session(NULL);
    fvgpu_resources_destroy_all(s);fvgpu_contexts_destroy_all(s);
    vkr_renderer_fini();
    vkr_accounting_set_admission(NULL,NULL,NULL);
    vkr_accounting_set_callback(NULL,NULL);vkr_accounting_set_blob_callback(NULL,NULL);
    fvgpu_completion_queue_destroy(s);free(s->scanout.scratch);
    fvgpu_ledger_fini(s);pthread_cond_destroy(&s->comp_cond);
    pthread_mutex_destroy(&s->comp_lock);pthread_mutex_destroy(&s->res_lock);
    free(s);renderer_owned=false;pthread_mutex_unlock(&lifecycle_lock);
}

/* ---- caps --------------------------------------------------------------- */
int
floe_gpu_num_capsets(FloeGPUSession *s)
{
    (void)s;
    return 1;
}

int
floe_gpu_get_capset_info(FloeGPUSession *s, uint32_t index,
                         uint32_t *capset_id, uint32_t *max_version,
                         uint32_t *max_size)
{
    (void)s;
    if(index!=0) return -1;
    *capset_id=4;*max_version=s->info.venus_capset_version;*max_size=s->info.venus_capset_size;
    return 0;
}

int
floe_gpu_get_capset(FloeGPUSession *s, uint32_t capset_id,
                    uint32_t version, void *data, uint32_t *size)
{
    (void)version;
    if (capset_id == 4) {
        if (*size < s->info.venus_capset_size)
            return -1;
        size_t got = vkr_get_capset(data, 0);
        *size = (uint32_t)got;
        return 0;
    }
    if (capset_id == 2) {
        /* no VIRGL2 capset from a venus-only renderer */
        return -1;
    }
    return -1;
}

/* ---- contexts ------------------------------------------------------------ */
int floe_gpu_ctx_create(FloeGPUSession *s,uint32_t id,uint32_t init,const char *name) {
    if(!id||fvgpu_context_exists(s,id)||(init&VIRGL_RENDERER_CONTEXT_FLAG_CAPSET_ID_MASK)!=4||
       (init&~VIRGL_RENDERER_CONTEXT_FLAG_CAPSET_ID_MASK)) return FLOE_GPU_RESP_INVALID;
    const char *debug=name?name:"floe-ctx";
    if(!vkr_renderer_create_context(id,4,(uint32_t)strlen(debug),debug)) return FLOE_GPU_RESP_ERR_UNSPEC;
    if(fvgpu_context_add(s,id)) {vkr_renderer_destroy_context(id);return FLOE_GPU_RESP_OUT_OF_MEMORY;}
    return FLOE_GPU_RESP_OK;
}
int floe_gpu_ctx_destroy(FloeGPUSession *s,uint32_t id) {
    int slot=-1;
    for(unsigned i=0;i<FVGPU_MAX_CONTEXTS;i++)
        if(s->contexts[i].used&&s->contexts[i].ctx_id==id) {slot=(int)i;break;}
    if(slot<0) return FLOE_GPU_RESP_INVALID;
    vkr_renderer_destroy_context(id);
    for(unsigned i=0;i<512;i++) if(s->resources[i].used) {
        s->resources[i].context_mask&=~(1ull<<slot);
        if(s->resources[i].ctx_id==id) s->resources[i].creator_alive=false;
    }
    fvgpu_context_remove(s,id);return FLOE_GPU_RESP_OK;
}

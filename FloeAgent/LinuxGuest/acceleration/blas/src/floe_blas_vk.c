/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Headless Vulkan compute backend for the Floe guest BLAS provider.
 *
 * The backend intentionally has no surface, swapchain or display dependency.
 * It opens the standard loader, checks the Venus driver ID and hardware
 * device type, caches the instance/device/pipelines, and uses host-visible storage
 * buffers with explicit flush/invalidate for non-coherent memory.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define VK_NO_PROTOTYPES 1

#include "floe_blas_internal.h"

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vulkan/vulkan.h>

#include "floe_blas_gemv_spv.h"
#include "floe_blas_matmul_spv.h"

#define FLOE_VK_BUFFER_SLOTS 8
#define FLOE_VK_PUSH_BYTES 44

typedef struct floe_gemm_push {
    uint32_t m;
    uint32_t n;
    uint32_t k;
    uint32_t a_row_stride;
    uint32_t a_col_stride;
    uint32_t b_row_stride;
    uint32_t b_col_stride;
    uint32_t c_row_stride;
    uint32_t c_col_stride;
    float alpha;
    float beta;
} floe_gemm_push;

typedef struct floe_gemv_push {
    uint32_t n_out;
    uint32_t k;
    uint32_t a_row_stride;
    uint32_t a_col_stride;
    float alpha;
    float beta;
} floe_gemv_push;

_Static_assert(sizeof(floe_gemm_push) == FLOE_VK_PUSH_BYTES,
               "GEMM push constant layout must match the shader");
_Static_assert(sizeof(floe_gemv_push) == 24,
               "GEMV push constant layout must match the shader");

typedef struct floe_vk_buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;
    size_t bytes;
    size_t allocation_bytes;
    int coherent;
    int in_use;
} floe_vk_buffer;

typedef struct floe_vk_context {
    void *loader;
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceMemoryProperties memory;
    VkDescriptorSetLayout descriptor_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor_set;
    VkPipelineLayout pipeline_layout;
    VkPipeline gemm_pipeline;
    VkPipeline gemv_pipeline;
    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;
    VkFence fence;
    floe_vk_buffer buffers[FLOE_VK_BUFFER_SLOTS];
    size_t buffer_total;
    uint64_t budget_bytes;
    int valid;
} floe_vk_context;

#define FLOE_VK_FUNCS(X) \
    X(vkDestroyInstance) \
    X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties2) \
    X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkCreateDevice) \
    X(vkDestroyDevice) \
    X(vkDeviceWaitIdle) \
    X(vkGetDeviceQueue) \
    X(vkCreateBuffer) \
    X(vkDestroyBuffer) \
    X(vkGetBufferMemoryRequirements) \
    X(vkAllocateMemory) \
    X(vkFreeMemory) \
    X(vkBindBufferMemory) \
    X(vkMapMemory) \
    X(vkUnmapMemory) \
    X(vkFlushMappedMemoryRanges) \
    X(vkInvalidateMappedMemoryRanges) \
    X(vkCreateDescriptorSetLayout) \
    X(vkDestroyDescriptorSetLayout) \
    X(vkCreateDescriptorPool) \
    X(vkDestroyDescriptorPool) \
    X(vkAllocateDescriptorSets) \
    X(vkUpdateDescriptorSets) \
    X(vkCreateShaderModule) \
    X(vkDestroyShaderModule) \
    X(vkCreatePipelineLayout) \
    X(vkDestroyPipelineLayout) \
    X(vkCreateComputePipelines) \
    X(vkDestroyPipeline) \
    X(vkCreateCommandPool) \
    X(vkDestroyCommandPool) \
    X(vkAllocateCommandBuffers) \
    X(vkResetCommandBuffer) \
    X(vkBeginCommandBuffer) \
    X(vkEndCommandBuffer) \
    X(vkCmdPipelineBarrier) \
    X(vkCmdBindPipeline) \
    X(vkCmdBindDescriptorSets) \
    X(vkCmdPushConstants) \
    X(vkCmdDispatch) \
    X(vkCreateFence) \
    X(vkDestroyFence) \
    X(vkResetFences) \
    X(vkQueueSubmit) \
    X(vkWaitForFences)

#define FLOE_VK_DECLARE(name) static PFN_##name name;
FLOE_VK_FUNCS(FLOE_VK_DECLARE)
#undef FLOE_VK_DECLARE

static PFN_vkCreateInstance floe_vkCreateInstance;
static PFN_vkGetInstanceProcAddr floe_vkGetInstanceProcAddr;
static floe_vk_context g_vk;
static pthread_mutex_t g_vk_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_vk_init_attempted;
static int g_vk_faulted;
static _Atomic int g_vk_available = -1; /* -1 unknown, 0 unavailable, 1 ready */
static int g_vk_exit_registered;
static pid_t g_vk_process;

/* A fork child must never use or destroy the parent's copied Vulkan handles
 * or take a mutex inherited while another parent thread owned it. Exec loads
 * a fresh provider and restores normal GPU activation. */
__attribute__((constructor)) static void record_process(void)
{
    g_vk_process = getpid();
}

static int current_process(void)
{
    return getpid() == g_vk_process;
}

static int load_instance_functions(VkInstance instance,
                                   PFN_vkGetInstanceProcAddr get)
{
#define FLOE_VK_LOAD(name) \
    name = (PFN_##name)get(instance, #name); \
    if (name == NULL) return 0;
    FLOE_VK_FUNCS(FLOE_VK_LOAD)
#undef FLOE_VK_LOAD
    return 1;
}

static int pick_memory_type(uint32_t bits, int *coherent)
{
    uint32_t index;
    uint32_t fallback = UINT32_MAX;

    *coherent = 0;
    for (index = 0; index < g_vk.memory.memoryTypeCount; index++) {
        VkMemoryPropertyFlags flags;
        if ((bits & (1u << index)) == 0) continue;
        flags = g_vk.memory.memoryTypes[index].propertyFlags;
        if ((flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0) continue;
        if ((flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) {
            *coherent = 1;
            return (int)index;
        }
        if (fallback == UINT32_MAX) fallback = index;
    }
    if (fallback != UINT32_MAX) return (int)fallback;
    return -1;
}

static VkShaderModule create_shader_module(const uint32_t *code, size_t bytes)
{
    VkShaderModule module = VK_NULL_HANDLE;
    VkShaderModuleCreateInfo information;

    if (code == NULL || bytes < 20 || (bytes % sizeof(uint32_t)) != 0)
        return VK_NULL_HANDLE;
    memset(&information, 0, sizeof information);
    information.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    information.codeSize = bytes;
    information.pCode = code;
    if (vkCreateShaderModule(g_vk.device, &information, NULL, &module) !=
        VK_SUCCESS)
        return VK_NULL_HANDLE;
    return module;
}

static int create_compute_pipeline(VkShaderModule module, VkPipeline *pipeline)
{
    VkComputePipelineCreateInfo information;
    VkResult result;

    memset(&information, 0, sizeof information);
    information.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    information.stage.sType =
        VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    information.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    information.stage.module = module;
    information.stage.pName = "main";
    information.layout = g_vk.pipeline_layout;
    result = vkCreateComputePipelines(g_vk.device, VK_NULL_HANDLE, 1,
                                      &information, NULL, pipeline);
    return result == VK_SUCCESS;
}

static void destroy_buffers_locked(void)
{
    uint32_t index;
    for (index = 0; index < FLOE_VK_BUFFER_SLOTS; index++) {
        floe_vk_buffer *buffer = &g_vk.buffers[index];
        if (buffer->mapped != NULL)
            vkUnmapMemory(g_vk.device, buffer->memory);
        if (buffer->buffer != VK_NULL_HANDLE)
            vkDestroyBuffer(g_vk.device, buffer->buffer, NULL);
        if (buffer->memory != VK_NULL_HANDLE)
            vkFreeMemory(g_vk.device, buffer->memory, NULL);
        memset(buffer, 0, sizeof *buffer);
    }
    g_vk.buffer_total = 0;
}

static void destroy_context_locked(int wait_idle)
{
    if (g_vk.device != VK_NULL_HANDLE && wait_idle && vkDeviceWaitIdle != NULL)
        (void)vkDeviceWaitIdle(g_vk.device);
    if (g_vk.device != VK_NULL_HANDLE) {
        destroy_buffers_locked();
        if (g_vk.fence != VK_NULL_HANDLE)
            vkDestroyFence(g_vk.device, g_vk.fence, NULL);
        if (g_vk.command_pool != VK_NULL_HANDLE)
            vkDestroyCommandPool(g_vk.device, g_vk.command_pool, NULL);
        if (g_vk.gemm_pipeline != VK_NULL_HANDLE)
            vkDestroyPipeline(g_vk.device, g_vk.gemm_pipeline, NULL);
        if (g_vk.gemv_pipeline != VK_NULL_HANDLE)
            vkDestroyPipeline(g_vk.device, g_vk.gemv_pipeline, NULL);
        if (g_vk.pipeline_layout != VK_NULL_HANDLE)
            vkDestroyPipelineLayout(g_vk.device, g_vk.pipeline_layout, NULL);
        if (g_vk.descriptor_pool != VK_NULL_HANDLE)
            vkDestroyDescriptorPool(g_vk.device, g_vk.descriptor_pool, NULL);
        if (g_vk.descriptor_layout != VK_NULL_HANDLE)
            vkDestroyDescriptorSetLayout(g_vk.device, g_vk.descriptor_layout,
                                         NULL);
        vkDestroyDevice(g_vk.device, NULL);
    }
    if (g_vk.instance != VK_NULL_HANDLE && vkDestroyInstance != NULL)
        vkDestroyInstance(g_vk.instance, NULL);
    if (g_vk.loader != NULL) dlclose(g_vk.loader);
    memset(&g_vk, 0, sizeof g_vk);
}

static void cleanup_process(int status, void *argument)
{
    (void)status;
    (void)argument;
    if (!current_process()) return;
    pthread_mutex_lock(&g_vk_lock);
    /* Every successful call already waited its fence before returning. A
     * faulted queue is left to kernel/context teardown: do not add an
     * unbounded DeviceWaitIdle to process exit after a timed-out submission. */
    if (!g_vk_faulted) destroy_context_locked(0);
    g_vk_faulted = 1;
    atomic_store_explicit(&g_vk_available, 0, memory_order_relaxed);
    pthread_mutex_unlock(&g_vk_lock);
}

static int initialize_context_locked(void)
{
    VkApplicationInfo application;
    VkInstanceCreateInfo instance_information;
    VkPhysicalDevice devices[8];
    uint32_t device_count = 0;
    uint32_t chosen = UINT32_MAX;
    uint32_t family_count = 0;
    VkQueueFamilyProperties families[16];
    VkDeviceQueueCreateInfo queue_information;
    VkDeviceCreateInfo device_information;
    float priority = 1.0f;
    VkDescriptorSetLayoutBinding bindings[3];
    VkDescriptorSetLayoutCreateInfo layout_information;
    VkDescriptorPoolSize pool_size;
    VkDescriptorPoolCreateInfo pool_information;
    VkDescriptorSetAllocateInfo set_information;
    VkPushConstantRange push_range;
    VkPipelineLayoutCreateInfo pipeline_information;
    VkShaderModule gemm_module = VK_NULL_HANDLE;
    VkShaderModule gemv_module = VK_NULL_HANDLE;
    VkCommandPoolCreateInfo command_information;
    VkCommandBufferAllocateInfo command_allocate;
    VkFenceCreateInfo fence_information;
    VkResult result;
    uint32_t index;

    memset(&g_vk, 0, sizeof g_vk);
    g_vk.loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (g_vk.loader == NULL) {
        floe_blas_set_error("libvulkan.so.1 is not available");
        return -1;
    }
    floe_vkGetInstanceProcAddr =
        (PFN_vkGetInstanceProcAddr)dlsym(g_vk.loader, "vkGetInstanceProcAddr");
    if (floe_vkGetInstanceProcAddr == NULL) {
        floe_blas_set_error("Vulkan loader has no vkGetInstanceProcAddr");
        return -1;
    }
    floe_vkCreateInstance = (PFN_vkCreateInstance)floe_vkGetInstanceProcAddr(
        NULL, "vkCreateInstance");
    if (floe_vkCreateInstance == NULL) {
        floe_blas_set_error("Vulkan loader has no vkCreateInstance");
        return -1;
    }

    memset(&application, 0, sizeof application);
    application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    application.pApplicationName = "floe-blas";
    application.applicationVersion = 1;
    application.apiVersion = VK_API_VERSION_1_1;
    memset(&instance_information, 0, sizeof instance_information);
    instance_information.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_information.pApplicationInfo = &application;
    result = floe_vkCreateInstance(&instance_information, NULL, &g_vk.instance);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("vkCreateInstance failed: %d", (int)result);
        return -1;
    }
    if (!load_instance_functions(g_vk.instance, floe_vkGetInstanceProcAddr)) {
        floe_blas_set_error("a required Vulkan instance function is missing");
        return -1;
    }

    device_count = 0;
    result = vkEnumeratePhysicalDevices(g_vk.instance, &device_count, NULL);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || device_count == 0) {
        floe_blas_set_error("no Vulkan physical device is visible");
        return -1;
    }
    if (device_count > (uint32_t)(sizeof devices / sizeof devices[0]))
        device_count = (uint32_t)(sizeof devices / sizeof devices[0]);
    result = vkEnumeratePhysicalDevices(g_vk.instance, &device_count, devices);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || device_count == 0) {
        floe_blas_set_error("Vulkan physical devices could not be enumerated");
        return -1;
    }
    for (index = 0; index < device_count; index++) {
        VkPhysicalDeviceDriverProperties driver = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
        };
        VkPhysicalDeviceProperties2 identity = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver,
        };
        vkGetPhysicalDeviceProperties2(devices[index], &identity);
        VkPhysicalDeviceProperties properties = identity.properties;
        if (driver.driverID != VK_DRIVER_ID_MESA_VENUS) continue;
        if (properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU &&
            properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU &&
            properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU) continue;
        if (properties.apiVersion < VK_API_VERSION_1_1) continue;
        if (properties.limits.maxStorageBufferRange < 4) continue;
        if (properties.limits.maxComputeWorkGroupCount[0] == 0) continue;
        if (properties.limits.maxComputeWorkGroupInvocations < 128) continue;
        if (properties.limits.maxComputeWorkGroupSize[0] < 16 ||
            properties.limits.maxComputeWorkGroupSize[1] < 8) continue;
        chosen = index;
        g_vk.properties = properties;
        break;
    }
    if (chosen == UINT32_MAX) {
        floe_blas_set_error("no non-CPU Vulkan Venus device is available");
        return -1;
    }
    g_vk.physical = devices[chosen];

    family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.physical, &family_count,
                                             NULL);
    if (family_count > (uint32_t)(sizeof families / sizeof families[0]))
        family_count = (uint32_t)(sizeof families / sizeof families[0]);
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.physical, &family_count,
                                             families);
    for (index = 0; index < family_count; index++) {
        if (families[index].queueCount > 0 &&
            (families[index].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
            g_vk.queue_family = index;
            break;
        }
    }
    if (g_vk.queue_family == 0 && family_count > 0 &&
        (families[0].queueFlags & VK_QUEUE_COMPUTE_BIT) == 0) {
        floe_blas_set_error("Vulkan Venus device has no compute queue");
        return -1;
    }
    if (family_count == 0) {
        floe_blas_set_error("Vulkan queue families are unavailable");
        return -1;
    }

    memset(&queue_information, 0, sizeof queue_information);
    queue_information.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_information.queueFamilyIndex = g_vk.queue_family;
    queue_information.queueCount = 1;
    queue_information.pQueuePriorities = &priority;
    memset(&device_information, 0, sizeof device_information);
    device_information.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_information.queueCreateInfoCount = 1;
    device_information.pQueueCreateInfos = &queue_information;
    result = vkCreateDevice(g_vk.physical, &device_information, NULL,
                            &g_vk.device);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("vkCreateDevice failed: %d", (int)result);
        return -1;
    }
    vkGetDeviceQueue(g_vk.device, g_vk.queue_family, 0, &g_vk.queue);
    vkGetPhysicalDeviceMemoryProperties(g_vk.physical, &g_vk.memory);

    memset(bindings, 0, sizeof bindings);
    for (index = 0; index < 3; index++) {
        bindings[index].binding = index;
        bindings[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bindings[index].descriptorCount = 1;
        bindings[index].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    memset(&layout_information, 0, sizeof layout_information);
    layout_information.sType =
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_information.bindingCount = 3;
    layout_information.pBindings = bindings;
    result = vkCreateDescriptorSetLayout(g_vk.device, &layout_information, NULL,
                                         &g_vk.descriptor_layout);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("descriptor layout failed: %d", (int)result);
        return -1;
    }

    pool_size.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    pool_size.descriptorCount = 3;
    memset(&pool_information, 0, sizeof pool_information);
    pool_information.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_information.maxSets = 1;
    pool_information.poolSizeCount = 1;
    pool_information.pPoolSizes = &pool_size;
    result = vkCreateDescriptorPool(g_vk.device, &pool_information, NULL,
                                    &g_vk.descriptor_pool);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("descriptor pool failed: %d", (int)result);
        return -1;
    }
    memset(&set_information, 0, sizeof set_information);
    set_information.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    set_information.descriptorPool = g_vk.descriptor_pool;
    set_information.descriptorSetCount = 1;
    set_information.pSetLayouts = &g_vk.descriptor_layout;
    result = vkAllocateDescriptorSets(g_vk.device, &set_information,
                                      &g_vk.descriptor_set);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("descriptor set allocation failed: %d",
                             (int)result);
        return -1;
    }

    push_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    push_range.offset = 0;
    push_range.size = FLOE_VK_PUSH_BYTES;
    memset(&pipeline_information, 0, sizeof pipeline_information);
    pipeline_information.sType =
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_information.setLayoutCount = 1;
    pipeline_information.pSetLayouts = &g_vk.descriptor_layout;
    pipeline_information.pushConstantRangeCount = 1;
    pipeline_information.pPushConstantRanges = &push_range;
    result = vkCreatePipelineLayout(g_vk.device, &pipeline_information, NULL,
                                    &g_vk.pipeline_layout);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("pipeline layout failed: %d", (int)result);
        return -1;
    }

    gemm_module = create_shader_module(
        floe_blas_gemm_spv, sizeof floe_blas_gemm_spv);
    gemv_module = create_shader_module(
        floe_blas_gemv_spv, sizeof floe_blas_gemv_spv);
    if (gemm_module == VK_NULL_HANDLE || gemv_module == VK_NULL_HANDLE) {
        floe_blas_set_error("generated SPIR-V shader asset is invalid");
        if (gemm_module != VK_NULL_HANDLE)
            vkDestroyShaderModule(g_vk.device, gemm_module, NULL);
        if (gemv_module != VK_NULL_HANDLE)
            vkDestroyShaderModule(g_vk.device, gemv_module, NULL);
        return -1;
    }
    if (!create_compute_pipeline(gemm_module, &g_vk.gemm_pipeline) ||
        !create_compute_pipeline(gemv_module, &g_vk.gemv_pipeline)) {
        floe_blas_set_error("Vulkan compute pipeline creation failed");
        vkDestroyShaderModule(g_vk.device, gemm_module, NULL);
        vkDestroyShaderModule(g_vk.device, gemv_module, NULL);
        return -1;
    }
    vkDestroyShaderModule(g_vk.device, gemm_module, NULL);
    vkDestroyShaderModule(g_vk.device, gemv_module, NULL);

    memset(&command_information, 0, sizeof command_information);
    command_information.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    command_information.flags =
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    command_information.queueFamilyIndex = g_vk.queue_family;
    result = vkCreateCommandPool(g_vk.device, &command_information, NULL,
                                 &g_vk.command_pool);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("command pool failed: %d", (int)result);
        return -1;
    }
    memset(&command_allocate, 0, sizeof command_allocate);
    command_allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command_allocate.commandPool = g_vk.command_pool;
    command_allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command_allocate.commandBufferCount = 1;
    result = vkAllocateCommandBuffers(g_vk.device, &command_allocate,
                                      &g_vk.command_buffer);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("command buffer allocation failed: %d",
                             (int)result);
        return -1;
    }
    memset(&fence_information, 0, sizeof fence_information);
    fence_information.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    result = vkCreateFence(g_vk.device, &fence_information, NULL, &g_vk.fence);
    if (result != VK_SUCCESS) {
        floe_blas_set_errorf("fence creation failed: %d", (int)result);
        return -1;
    }

    g_vk.budget_bytes = g_floe_blas_config.max_gpu_bytes;
    g_vk.valid = 1;
    atomic_store_explicit(&g_vk_available, 1, memory_order_relaxed);
    floe_blas_set_device_name(g_vk.properties.deviceName);
    floe_blas_verbose("Vulkan ready: %s", g_vk.properties.deviceName);
    return 0;
}

static int ensure_context_locked(void)
{
    int result;

    if (g_vk.valid) return 0;
    if (g_vk_faulted) return -1;
    if (g_vk_init_attempted) return -1;
    g_vk_init_attempted = 1;
    result = initialize_context_locked();
    if (result != 0) {
        destroy_context_locked(0);
        g_vk_faulted = 1;
        atomic_store_explicit(&g_vk_available, 0, memory_order_relaxed);
        floe_blas_verbose("Vulkan unavailable; CPU BLAS fallback remains active");
        return -1;
    }
    /* This GNU Linux provider registers after loader/driver initialization,
     * so its explicit Vulkan cleanup runs before their finalizers. on_exit
     * is exported by the pinned glibc, unlike the atexit CRT wrapper. */
    if (!g_vk_exit_registered) {
        if (on_exit(cleanup_process, NULL) != 0) {
            floe_blas_set_error("Could not register Vulkan process cleanup");
            destroy_context_locked(0);
            g_vk_faulted = 1;
            atomic_store_explicit(&g_vk_available, 0, memory_order_relaxed);
            return -1;
        }
        g_vk_exit_registered = 1;
    }
    return 0;
}

FLOE_BLAS_EXPORT int floe_blas_vk_state(void)
{
    if (!current_process()) return 0;
    return atomic_load_explicit(&g_vk_available, memory_order_relaxed);
}

FLOE_BLAS_EXPORT int floe_blas_vk_warmup(void)
{
    int result;
    if (!current_process()) return -1;
    pthread_mutex_lock(&g_vk_lock);
    result = ensure_context_locked();
    pthread_mutex_unlock(&g_vk_lock);
    return result;
}

static void destroy_buffer_locked(floe_vk_buffer *buffer)
{
    if (buffer->mapped != NULL)
        vkUnmapMemory(g_vk.device, buffer->memory);
    if (buffer->buffer != VK_NULL_HANDLE)
        vkDestroyBuffer(g_vk.device, buffer->buffer, NULL);
    if (buffer->memory != VK_NULL_HANDLE)
        vkFreeMemory(g_vk.device, buffer->memory, NULL);
    if (g_vk.buffer_total >= buffer->allocation_bytes)
        g_vk.buffer_total -= buffer->allocation_bytes;
    memset(buffer, 0, sizeof *buffer);
}

static int acquire_buffer_locked(size_t bytes, floe_vk_buffer **output)
{
    VkBufferCreateInfo information;
    VkMemoryRequirements requirements;
    VkMemoryAllocateInfo allocate_information;
    floe_vk_buffer *buffer = NULL;
    int coherent = 0;
    int memory_type;
    int slot;
    VkResult result;

    *output = NULL;
    if (bytes == 0 || (uint64_t)bytes > g_vk.budget_bytes)
        return FLOE_BLAS_VK_BUDGET;
    for (slot = 0; slot < FLOE_VK_BUFFER_SLOTS; slot++) {
        if (!g_vk.buffers[slot].in_use && g_vk.buffers[slot].buffer !=
                VK_NULL_HANDLE &&
            g_vk.buffers[slot].bytes == bytes) {
            g_vk.buffers[slot].in_use = 1;
            *output = &g_vk.buffers[slot];
            return FLOE_BLAS_VK_OK;
        }
    }
    for (slot = 0; slot < FLOE_VK_BUFFER_SLOTS; slot++) {
        if (g_vk.buffers[slot].buffer == VK_NULL_HANDLE &&
            !g_vk.buffers[slot].in_use)
            break;
    }
    if (slot == FLOE_VK_BUFFER_SLOTS) {
        for (slot = 0; slot < FLOE_VK_BUFFER_SLOTS; slot++) {
            if (!g_vk.buffers[slot].in_use) {
                destroy_buffer_locked(&g_vk.buffers[slot]);
                break;
            }
        }
    }
    if (slot == FLOE_VK_BUFFER_SLOTS) return FLOE_BLAS_VK_BUDGET;
    buffer = &g_vk.buffers[slot];
    memset(buffer, 0, sizeof *buffer);

    memset(&information, 0, sizeof information);
    information.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    information.size = (VkDeviceSize)bytes;
    information.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    information.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    result = vkCreateBuffer(g_vk.device, &information, NULL, &buffer->buffer);
    if (result != VK_SUCCESS) return FLOE_BLAS_VK_BUDGET;
    vkGetBufferMemoryRequirements(g_vk.device, buffer->buffer, &requirements);
    if (requirements.size > g_vk.properties.limits.maxStorageBufferRange ||
        (uint64_t)requirements.size >
        g_vk.budget_bytes - g_vk.buffer_total) {
        destroy_buffer_locked(buffer);
        return FLOE_BLAS_VK_BUDGET;
    }
    memory_type = pick_memory_type(requirements.memoryTypeBits, &coherent);
    if (memory_type < 0) {
        destroy_buffer_locked(buffer);
        return FLOE_BLAS_VK_UNAVAILABLE;
    }
    memset(&allocate_information, 0, sizeof allocate_information);
    allocate_information.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocate_information.allocationSize = requirements.size;
    allocate_information.memoryTypeIndex = (uint32_t)memory_type;
    result = vkAllocateMemory(g_vk.device, &allocate_information, NULL,
                              &buffer->memory);
    if (result != VK_SUCCESS) {
        destroy_buffer_locked(buffer);
        return FLOE_BLAS_VK_BUDGET;
    }
    result = vkBindBufferMemory(g_vk.device, buffer->buffer, buffer->memory, 0);
    if (result != VK_SUCCESS) {
        destroy_buffer_locked(buffer);
        return FLOE_BLAS_VK_BUDGET;
    }
    result = vkMapMemory(g_vk.device, buffer->memory, 0, requirements.size, 0,
                         &buffer->mapped);
    if (result != VK_SUCCESS) {
        destroy_buffer_locked(buffer);
        return FLOE_BLAS_VK_BUDGET;
    }
    buffer->bytes = bytes;
    buffer->allocation_bytes = (size_t)requirements.size;
    buffer->coherent = coherent;
    buffer->in_use = 1;
    g_vk.buffer_total += (size_t)requirements.size;
    *output = buffer;
    return FLOE_BLAS_VK_OK;
}

static void release_buffer(floe_vk_buffer *buffer)
{
    if (buffer != NULL) buffer->in_use = 0;
}

static void flush_buffer(floe_vk_buffer *buffer)
{
    VkMappedMemoryRange range;
    if (buffer == NULL || buffer->coherent) return;
    memset(&range, 0, sizeof range);
    range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buffer->memory;
    range.offset = 0;
    range.size = VK_WHOLE_SIZE;
    (void)vkFlushMappedMemoryRanges(g_vk.device, 1, &range);
}

static void invalidate_buffer(floe_vk_buffer *buffer)
{
    VkMappedMemoryRange range;
    if (buffer == NULL || buffer->coherent) return;
    memset(&range, 0, sizeof range);
    range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    range.memory = buffer->memory;
    range.offset = 0;
    range.size = VK_WHOLE_SIZE;
    (void)vkInvalidateMappedMemoryRanges(g_vk.device, 1, &range);
}

static int copy_input_floats(floe_vk_buffer *buffer, const float *source,
                             uint64_t count)
{
    uint64_t index;
    if (count == 0) return 1;
    if (count > buffer->bytes / sizeof(float)) return 0;
    memcpy(buffer->mapped, source, (size_t)count * sizeof(float));
    flush_buffer(buffer);
    for (index = 0; index < count; index++) {
        if (!isfinite(source[index])) return 0;
    }
    return 1;
}

static void update_descriptors(floe_vk_buffer *a, floe_vk_buffer *b,
                               floe_vk_buffer *c)
{
    VkDescriptorBufferInfo information[3];
    VkWriteDescriptorSet writes[3];
    uint32_t index;

    memset(information, 0, sizeof information);
    memset(writes, 0, sizeof writes);
    information[0].buffer = a->buffer;
    information[0].offset = 0;
    information[0].range = VK_WHOLE_SIZE;
    information[1].buffer = b->buffer;
    information[1].offset = 0;
    information[1].range = VK_WHOLE_SIZE;
    information[2].buffer = c->buffer;
    information[2].offset = 0;
    information[2].range = VK_WHOLE_SIZE;
    for (index = 0; index < 3; index++) {
        writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[index].dstSet = g_vk.descriptor_set;
        writes[index].dstBinding = index;
        writes[index].dstArrayElement = 0;
        writes[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[index].descriptorCount = 1;
        writes[index].pBufferInfo = &information[index];
    }
    vkUpdateDescriptorSets(g_vk.device, 3, writes, 0, NULL);
}

static VkResult submit_command_locked(VkPipeline pipeline,
                                      const void *push, size_t push_bytes,
                                      uint32_t groups_x, uint32_t groups_y)
{
    VkCommandBufferBeginInfo begin_information;
    VkMemoryBarrier before;
    VkMemoryBarrier after;
    VkSubmitInfo submit_information;
    VkResult result;

    if (groups_x == 0 || groups_y == 0) return VK_ERROR_INITIALIZATION_FAILED;
    result = vkResetCommandBuffer(g_vk.command_buffer, 0);
    if (result != VK_SUCCESS) return result;
    memset(&begin_information, 0, sizeof begin_information);
    begin_information.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_information.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    result = vkBeginCommandBuffer(g_vk.command_buffer, &begin_information);
    if (result != VK_SUCCESS) return result;

    memset(&before, 0, sizeof before);
    before.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    before.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
    before.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(g_vk.command_buffer, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &before,
                         0, NULL, 0, NULL);
    vkCmdBindPipeline(g_vk.command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                      pipeline);
    vkCmdBindDescriptorSets(g_vk.command_buffer,
                            VK_PIPELINE_BIND_POINT_COMPUTE,
                            g_vk.pipeline_layout, 0, 1, &g_vk.descriptor_set,
                            0, NULL);
    vkCmdPushConstants(g_vk.command_buffer, g_vk.pipeline_layout,
                       VK_SHADER_STAGE_COMPUTE_BIT, 0, (uint32_t)push_bytes,
                       push);
    vkCmdDispatch(g_vk.command_buffer, groups_x, groups_y, 1);
    memset(&after, 0, sizeof after);
    after.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    after.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    after.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(g_vk.command_buffer,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &after, 0, NULL, 0,
                         NULL);
    result = vkEndCommandBuffer(g_vk.command_buffer);
    if (result != VK_SUCCESS) return result;

    result = vkResetFences(g_vk.device, 1, &g_vk.fence);
    if (result != VK_SUCCESS) return result;
    memset(&submit_information, 0, sizeof submit_information);
    submit_information.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_information.commandBufferCount = 1;
    submit_information.pCommandBuffers = &g_vk.command_buffer;
    result = vkQueueSubmit(g_vk.queue, 1, &submit_information, g_vk.fence);
    if (result != VK_SUCCESS) return result;
    floe_blas_count(&g_floe_blas_counters.gpu_submitted, 1);
    floe_blas_count(&g_floe_blas_counters.gpu_dispatches, 1);
    result = vkWaitForFences(g_vk.device, 1, &g_vk.fence, VK_TRUE,
                             g_floe_blas_config.timeout_ns);
    return result;
}

static int fail_after_submit(VkResult result)
{
    if (result == VK_ERROR_DEVICE_LOST) {
        floe_blas_set_error("Vulkan device lost");
        floe_blas_count(&g_floe_blas_counters.gpu_failed, 1);
        /* A lost/timed-out command may still be referenced by the driver.
         * Do not destroy its objects from under it; leak this context and
         * serve every later call from CPU BLAS. */
        g_vk.valid = 0;
        g_vk_faulted = 1;
        atomic_store_explicit(&g_vk_available, 0, memory_order_relaxed);
        return FLOE_BLAS_VK_DEVICE_LOST;
    }
    floe_blas_set_errorf("Vulkan fence wait failed: %d", (int)result);
    floe_blas_count(&g_floe_blas_counters.gpu_failed, 1);
    g_vk.valid = 0;
    g_vk_faulted = 1;
    atomic_store_explicit(&g_vk_available, 0, memory_order_relaxed);
    return FLOE_BLAS_VK_SUBMIT_FAILED;
}

FLOE_BLAS_EXPORT int floe_blas_vk_gemm(const floe_blas_gemm_request *request)
{
    floe_vk_buffer *a = NULL;
    floe_vk_buffer *b = NULL;
    floe_vk_buffer *c = NULL;
    floe_gemm_push push;
    uint32_t groups_x;
    uint32_t groups_y;
    VkResult result;
    uint32_t row;
    uint32_t column;
    int finite;
    int gpu_result = FLOE_BLAS_VK_SUBMIT_FAILED;

    if (!current_process()) return FLOE_BLAS_VK_UNAVAILABLE;
    if (request == NULL || request->m == 0 || request->n == 0 ||
        request->k == 0 || request->a == NULL || request->b == NULL ||
        request->c == NULL)
        return FLOE_BLAS_VK_INVALID;
    if (request->a_span > FLOE_BLAS_MAX_ELEMENTS ||
        request->b_span > FLOE_BLAS_MAX_ELEMENTS ||
        request->c_span > FLOE_BLAS_MAX_ELEMENTS)
        return FLOE_BLAS_VK_BUDGET;
    if ((uint64_t)request->m * request->n > UINT32_MAX)
        return FLOE_BLAS_VK_BUDGET;

    pthread_mutex_lock(&g_vk_lock);
    if (ensure_context_locked() != 0) {
        pthread_mutex_unlock(&g_vk_lock);
        return FLOE_BLAS_VK_UNAVAILABLE;
    }
    groups_x = (request->n + 15u) / 16u;
    groups_y = (request->m + 7u) / 8u;
    if (groups_x == 0 || groups_y == 0 ||
        groups_x > g_vk.properties.limits.maxComputeWorkGroupCount[0] ||
        groups_y > g_vk.properties.limits.maxComputeWorkGroupCount[1]) {
        pthread_mutex_unlock(&g_vk_lock);
        return FLOE_BLAS_VK_BUDGET;
    }

    if (acquire_buffer_locked((size_t)request->a_span * sizeof(float), &a) !=
            FLOE_BLAS_VK_OK ||
        acquire_buffer_locked((size_t)request->b_span * sizeof(float), &b) !=
            FLOE_BLAS_VK_OK ||
        acquire_buffer_locked((size_t)request->c_span * sizeof(float), &c) !=
            FLOE_BLAS_VK_OK) {
        gpu_result = FLOE_BLAS_VK_BUDGET;
        goto done;
    }
    finite = copy_input_floats(a, request->a, request->a_span);
    finite = copy_input_floats(b, request->b, request->b_span) && finite;
    floe_blas_count(&g_floe_blas_counters.gpu_floats_uploaded,
                    request->a_span + request->b_span);
    if (request->c_has_original) {
        finite = copy_input_floats(c, request->c, request->c_span) && finite;
        floe_blas_count(&g_floe_blas_counters.gpu_floats_uploaded,
                        request->c_span);
    } else {
        memset(c->mapped, 0, (size_t)request->c_span * sizeof(float));
        flush_buffer(c);
    }
    if (!finite) {
        gpu_result = FLOE_BLAS_VK_NONFINITE;
        goto done;
    }

    memset(&push, 0, sizeof push);
    push.m = request->m;
    push.n = request->n;
    push.k = request->k;
    push.a_row_stride = request->a_row_stride;
    push.a_col_stride = request->a_col_stride;
    push.b_row_stride = request->b_row_stride;
    push.b_col_stride = request->b_col_stride;
    push.c_row_stride = request->c_row_stride;
    push.c_col_stride = request->c_col_stride;
    push.alpha = request->alpha;
    push.beta = request->beta;
    update_descriptors(a, b, c);
    result = submit_command_locked(g_vk.gemm_pipeline, &push, sizeof push,
                                   groups_x, groups_y);
    if (result != VK_SUCCESS) {
        gpu_result = fail_after_submit(result);
        goto done;
    }

    invalidate_buffer(c);
    for (row = 0; row < request->m; row++) {
        for (column = 0; column < request->n; column++) {
            size_t index = (size_t)row * request->c_row_stride +
                           (size_t)column * request->c_col_stride;
            if (index >= request->c_span ||
                !isfinite(((float *)c->mapped)[index])) {
                gpu_result = FLOE_BLAS_VK_NONFINITE;
                goto done;
            }
        }
    }
    for (row = 0; row < request->m; row++) {
        for (column = 0; column < request->n; column++) {
            size_t index = (size_t)row * request->c_row_stride +
                           (size_t)column * request->c_col_stride;
            request->c[index] = ((float *)c->mapped)[index];
        }
    }
    floe_blas_count(&g_floe_blas_counters.gpu_floats_downloaded,
                    (uint64_t)request->m * request->n);
    floe_blas_count(&g_floe_blas_counters.gpu_completed, 1);
    gpu_result = FLOE_BLAS_VK_OK;

done:
    release_buffer(a);
    release_buffer(b);
    release_buffer(c);
    pthread_mutex_unlock(&g_vk_lock);
    return gpu_result;
}

static size_t gemv_vector_index(uint32_t index, int increment,
                                uint32_t length)
{
    if (increment > 0) return (size_t)index * (size_t)increment;
    return (size_t)(length - 1 - index) * (size_t)(-(int64_t)increment);
}

FLOE_BLAS_EXPORT int floe_blas_vk_gemv(const floe_blas_gemv_request *request)
{
    floe_vk_buffer *a = NULL;
    floe_vk_buffer *x = NULL;
    floe_vk_buffer *y = NULL;
    floe_gemv_push push;
    uint32_t groups;
    VkResult result;
    uint32_t index;
    float *mapped_y;
    int finite;
    int gpu_result = FLOE_BLAS_VK_SUBMIT_FAILED;

    if (!current_process()) return FLOE_BLAS_VK_UNAVAILABLE;
    if (request == NULL || request->n_out == 0 || request->k == 0 ||
        request->a == NULL || request->x == NULL || request->y == NULL ||
        request->x_inc == 0 || request->y_inc == 0 ||
        request->x_len != request->k || request->y_len != request->n_out)
        return FLOE_BLAS_VK_INVALID;
    if (request->a_span > FLOE_BLAS_MAX_ELEMENTS)
        return FLOE_BLAS_VK_BUDGET;

    pthread_mutex_lock(&g_vk_lock);
    if (ensure_context_locked() != 0) {
        pthread_mutex_unlock(&g_vk_lock);
        return FLOE_BLAS_VK_UNAVAILABLE;
    }
    groups = (request->n_out + 63u) / 64u;
    if (groups == 0 ||
        groups > g_vk.properties.limits.maxComputeWorkGroupCount[0]) {
        pthread_mutex_unlock(&g_vk_lock);
        return FLOE_BLAS_VK_BUDGET;
    }
    if (acquire_buffer_locked((size_t)request->a_span * sizeof(float), &a) !=
            FLOE_BLAS_VK_OK ||
        acquire_buffer_locked((size_t)request->k * sizeof(float), &x) !=
            FLOE_BLAS_VK_OK ||
        acquire_buffer_locked((size_t)request->n_out * sizeof(float), &y) !=
            FLOE_BLAS_VK_OK) {
        gpu_result = FLOE_BLAS_VK_BUDGET;
        goto done;
    }

    finite = copy_input_floats(a, request->a, request->a_span);
    {
        float *mapped_x = x->mapped;
        for (index = 0; index < request->k; index++) {
            float value = request->x[
                gemv_vector_index(index, request->x_inc, request->k)];
            if (!isfinite(value)) finite = 0;
            mapped_x[index] = value;
        }
        flush_buffer(x);
        floe_blas_count(&g_floe_blas_counters.gpu_floats_uploaded,
                        request->k);
    }
    floe_blas_count(&g_floe_blas_counters.gpu_floats_uploaded,
                    request->a_span);
    if (request->beta_nonzero) {
        mapped_y = y->mapped;
        for (index = 0; index < request->n_out; index++) {
            float value = request->y[
                gemv_vector_index(index, request->y_inc, request->n_out)];
            if (!isfinite(value)) finite = 0;
            mapped_y[index] = value;
        }
        flush_buffer(y);
        floe_blas_count(&g_floe_blas_counters.gpu_floats_uploaded,
                        request->n_out);
    } else {
        memset(y->mapped, 0, (size_t)request->n_out * sizeof(float));
        flush_buffer(y);
    }
    if (!finite) {
        gpu_result = FLOE_BLAS_VK_NONFINITE;
        goto done;
    }

    memset(&push, 0, sizeof push);
    push.n_out = request->n_out;
    push.k = request->k;
    push.a_row_stride = request->a_row_stride;
    push.a_col_stride = request->a_col_stride;
    push.alpha = request->alpha;
    push.beta = request->beta;
    update_descriptors(a, x, y);
    result = submit_command_locked(g_vk.gemv_pipeline, &push, sizeof push,
                                   groups, 1);
    if (result != VK_SUCCESS) {
        gpu_result = fail_after_submit(result);
        goto done;
    }

    invalidate_buffer(y);
    mapped_y = y->mapped;
    for (index = 0; index < request->n_out; index++) {
        if (!isfinite(mapped_y[index])) {
            gpu_result = FLOE_BLAS_VK_NONFINITE;
            goto done;
        }
    }
    for (index = 0; index < request->n_out; index++) {
        request->y[
            gemv_vector_index(index, request->y_inc, request->n_out)] =
            mapped_y[index];
    }
    floe_blas_count(&g_floe_blas_counters.gpu_floats_downloaded,
                    request->n_out);
    floe_blas_count(&g_floe_blas_counters.gpu_completed, 1);
    gpu_result = FLOE_BLAS_VK_OK;

done:
    release_buffer(a);
    release_buffer(x);
    release_buffer(y);
    pthread_mutex_unlock(&g_vk_lock);
    return gpu_result;
}

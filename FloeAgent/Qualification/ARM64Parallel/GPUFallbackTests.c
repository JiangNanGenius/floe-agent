/* SPDX-License-Identifier: MPL-2.0 */
/* Link against the production ARM64 engine objects, replacing only the GPU
 * backend factory with a deterministic failure. No guest image is modified. */
#include "floe_arm64emu.h"
#include "virtio_gpu_backend.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef NDEBUG
#error "GPU fallback qualification requires assertions"
#endif

static unsigned backend_attempts;
FloeVirtioGPUBackend *floe_virtual_gpu_backend_create_in_app_group(
    const char *group, char *error, size_t capacity) {
    (void)group;
    backend_attempts++;
    if (error && capacity) snprintf(error, capacity, "forced renderer failure");
    return NULL;
}

static floe_ae_config_v3 config(const char *firmware) {
    floe_ae_config_v3 value = {0};
    value.v2.machine.abi_version = FLOE_AE_ABI_VERSION;
    value.v2.machine.struct_size = sizeof(value);
    value.v2.machine.ram_mib = 16;
    value.v2.machine.requested_vcpus = 1;
    value.v2.machine.firmware_path = firmware;
    value.v2.devices.struct_size = sizeof(value.v2.devices);
    value.memory.struct_size = sizeof(value.memory);
    value.gpu.struct_size = sizeof(value.gpu);
    value.gpu.enabled = 1;
    value.gpu.app_group_identifier = "group.floe.test";
    return value;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    char firmware[4096];
    assert(snprintf(firmware, sizeof(firmware), "%s/gpu-fallback-fw.bin", argv[1]) < (int)sizeof(firmware));
    int fd = open(firmware, O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(fd >= 0);
    const unsigned branch_forever = 0x14000000;
    assert(write(fd, &branch_forever, sizeof(branch_forever)) == sizeof(branch_forever));
    assert(close(fd) == 0);

    floe_ae_handle handle = 0;
    floe_ae_config_v3 requested = config(firmware);
    assert(floe_ae_create(&requested.v2.machine, &handle) == FLOE_AE_UNSUPPORTED);
    assert(handle == 0 && backend_attempts == 1); /* old strict caller */

    requested.gpu.reserved[0] = UINT64_C(1) << 63;
    assert(floe_ae_create(&requested.v2.machine, &handle) == FLOE_AE_UNSUPPORTED);
    assert(handle == 0 && backend_attempts == 1); /* unknown high ABI bits */

    requested.gpu.reserved[0] = FLOE_AE_GPU_ALLOW_CPU_FALLBACK;
    assert(floe_ae_create(&requested.v2.machine, &handle) == FLOE_AE_OK);
    assert(handle != 0 && backend_attempts == 2);
    floe_ae_gpu_info gpu = {.struct_size = sizeof(gpu)};
    assert(floe_ae_gpu_get_info(handle, &gpu) == FLOE_AE_OK);
    assert(gpu.present == 0 && gpu.effective_bytes == 0);
    assert(floe_ae_gpu_set_budget(handle, FLOE_AE_GPU_DEFAULT_BUDGET_BYTES) == FLOE_AE_UNSUPPORTED);
    char diagnostic[256] = {0};
    size_t count = 0;
    assert(floe_ae_diagnostic_read(handle, diagnostic, sizeof(diagnostic)-1, &count) == FLOE_AE_OK);
    assert(count > 0 && strstr(diagnostic, "continuing on CPU: forced renderer failure"));
    floe_ae_stats stats = {.struct_size = sizeof(stats)};
    assert(floe_ae_get_stats(handle, &stats) == FLOE_AE_OK);
    assert(stats.supported_vcpus == 1 && stats.ram_bytes == 16u * 1024u * 1024u);
    floe_ae_slice slice = {.struct_size = sizeof(slice)};
    assert(floe_ae_run_slice(handle, 1000000, 1000, &slice) == FLOE_AE_OK);
    assert(slice.instructions > 0);
    assert(floe_ae_destroy(handle) == FLOE_AE_OK);

    requested.v2.machine.requested_vcpus = 0;
    handle = 0;
    assert(floe_ae_create(&requested.v2.machine, &handle) == FLOE_AE_UNSUPPORTED);
    assert(handle == 0 && backend_attempts == 2); /* CPU error not hidden */
    requested.v2.machine.requested_vcpus = 1;
    requested.v2.machine.private_writable_disk_path = "/missing-floe-gpu-fallback-disk";
    assert(floe_ae_create(&requested.v2.machine, &handle) != FLOE_AE_OK);
    assert(handle == 0 && backend_attempts == 3); /* disk error not hidden */
    requested.v2.machine.private_writable_disk_path = NULL;
    requested.v2.devices.dns_server = "1.1.1.1";
    requested.v2.devices.network_enabled = 0;
    assert(floe_ae_create(&requested.v2.machine, &handle) == FLOE_AE_INVALID);
    assert(handle == 0 && backend_attempts == 4); /* network error not hidden */

    assert(unlink(firmware) == 0);
    puts("ARM64_GPU_OPTIONAL_CPU_FALLBACK_OK");
    return 0;
}

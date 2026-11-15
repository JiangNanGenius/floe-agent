/* SPDX-License-Identifier: MPL-2.0 */
/* ABI4 layout contract for the video tail and the unchanged v1-v3 prefix.
 *
 * This compiles against the production public header only. It does not create
 * a machine, open a renderer or touch a guest. A mismatch is a compile error,
 * not a runtime warning. */
#include "floe_arm64emu.h"

#include <stddef.h>
#include <stdio.h>

/* The v4 struct is the v3 struct followed by the video tail. */
_Static_assert(offsetof(floe_ae_config_v4, v3) == 0, "v4 must begin with v3");
_Static_assert(offsetof(floe_ae_config_v4, video) == sizeof(floe_ae_config_v3),
               "video tail must start at sizeof(v3)");
_Static_assert(sizeof(floe_ae_config_v4) >=
                   sizeof(floe_ae_config_v3) + sizeof(floe_ae_video_config),
               "v4 must contain the complete video tail");

/* The v3 struct is the v2 struct followed by memory then GPU. */
_Static_assert(offsetof(floe_ae_config_v3, memory) == sizeof(floe_ae_config_v2),
               "memory tail must start at sizeof(v2)");
_Static_assert(offsetof(floe_ae_config_v3, gpu) ==
                   offsetof(floe_ae_config_v3, memory) + sizeof(floe_ae_memory_config),
               "gpu tail must follow memory");
_Static_assert(FLOE_AE_CONFIG_V3_MEMORY_SIZE == offsetof(floe_ae_config_v3, gpu),
               "historical memory-only size must stay the gpu offset");

/* v2 is the v1 struct followed by the device tail. */
_Static_assert(offsetof(floe_ae_config_v2, devices) == sizeof(floe_ae_config),
               "devices tail must start at sizeof(v1)");
_Static_assert(sizeof(floe_ae_config_v2) > sizeof(floe_ae_config),
               "v2 must extend v1");

/* ABI3's GPU fallback opt-in remains reserved[0] == 1. */
_Static_assert(FLOE_AE_GPU_ALLOW_CPU_FALLBACK == 1u,
               "GPU CPU fallback bit changed");
_Static_assert(offsetof(floe_ae_gpu_config, reserved) + sizeof(((floe_ae_gpu_config *)0)->reserved) <=
                   sizeof(floe_ae_gpu_config),
               "GPU config reserved tail overflow");

/* Video tail has no implicit padding before the contract fields. */
_Static_assert(offsetof(floe_ae_video_config, reserved_tail) == 24,
               "unexpected video config padding");
_Static_assert(offsetof(floe_ae_video_config, max_host_owned_bytes_per_node) == 16,
               "unexpected video config field order");
_Static_assert(sizeof(floe_ae_video_config) == 56,
               "video config size changed");

/* Snapshot structs are fixed-layout public values. */
_Static_assert(sizeof(floe_ae_video_info) == 104, "video info size changed");
_Static_assert(sizeof(floe_ae_video_backend_info) == 64,
               "video backend info size changed");
_Static_assert(offsetof(floe_ae_video_backend_info, hardware_outputs) == 16,
               "video backend info field order changed");

int main(void) {
    printf("FLOE_ABI4_LAYOUT_OK v1=%zu v2=%zu v3=%zu v4=%zu video=%zu info=%zu backend=%zu\n",
           sizeof(floe_ae_config), sizeof(floe_ae_config_v2),
           sizeof(floe_ae_config_v3), sizeof(floe_ae_config_v4),
           sizeof(floe_ae_video_config), sizeof(floe_ae_video_info),
           sizeof(floe_ae_video_backend_info));
    return 0;
}

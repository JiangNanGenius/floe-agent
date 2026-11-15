/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Lazy activation helper for the trusted guest C runners.
 *
 * This file is deliberately free of Vulkan, dlopen and provider internals so
 * it can be linked into the static floe-exec runner.  It only mutates the
 * runner's own environment; the provider is loaded later by the dynamic
 * loader for each ordinary child command.
 */
#define _POSIX_C_SOURCE 200809L

#include "floe_blas_activate.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "floe_blas_policy.h"

#define FLOE_BLAS_PRELOAD_MAX 8192

#if defined(__GNUC__)
#define FLOE_BLAS_ACTIVATION_PUBLIC __attribute__((visibility("default")))
#else
#define FLOE_BLAS_ACTIVATION_PUBLIC
#endif

static const char *mode_name(int mode)
{
    switch (mode) {
    case FLOE_BLAS_POLICY_ON:
        return "on";
    case FLOE_BLAS_POLICY_OFF:
        return "off";
    default:
        return "auto";
    }
}

static int preload_contains(const char *list, const char *path)
{
    size_t path_length;
    const char *cursor;

    if (list == NULL || path == NULL) return 0;
    path_length = strlen(path);
    cursor = list;
    while (*cursor != '\0') {
        const char *start;
        size_t length;

        while (*cursor == ':' || *cursor == ' ') cursor++;
        if (*cursor == '\0') break;
        start = cursor;
        while (*cursor != '\0' && *cursor != ':' && *cursor != ' ') cursor++;
        length = (size_t)(cursor - start);
        if (length == path_length && memcmp(start, path, path_length) == 0) return 1;
    }
    return 0;
}

FLOE_BLAS_ACTIVATION_PUBLIC int floe_blas_activation_inspect(
    floe_blas_activation_probe *probe)
{
    int mode;
    int source;

    if (probe == NULL) return -1;
    memset(probe, 0, sizeof *probe);
#ifdef __linux__
    probe->guest = 1;
#endif
    probe->mode = floe_blas_policy_resolve(probe->config_path,
                                           sizeof probe->config_path,
                                           &source);
    probe->mode_source = source;
    probe->library_present = access(FLOE_BLAS_LIBRARY_PATH, F_OK) == 0;
    probe->library_trusted =
        floe_blas_trusted_regular_file(FLOE_BLAS_LIBRARY_PATH, 0);
    probe->gpu_node_present =
        floe_blas_trusted_character_device(FLOE_BLAS_RENDER_NODE);
    probe->icd_present =
        floe_blas_trusted_regular_file(FLOE_BLAS_ICD_PATH, 0) &&
        access(FLOE_BLAS_ICD_PATH, R_OK) == 0;
    probe->would_activate = probe->guest &&
        probe->mode != FLOE_BLAS_POLICY_OFF &&
        probe->library_trusted &&
        probe->gpu_node_present &&
        probe->icd_present;

    mode = probe->mode;
    if (mode == FLOE_BLAS_POLICY_OFF) {
        snprintf(probe->reason, sizeof probe->reason, "off");
    } else if (!probe->guest) {
        snprintf(probe->reason, sizeof probe->reason, "nativehost");
    } else if (!probe->library_present) {
        snprintf(probe->reason, sizeof probe->reason, "library-missing");
    } else if (!probe->library_trusted) {
        snprintf(probe->reason, sizeof probe->reason, "library-untrusted");
    } else if (!probe->gpu_node_present) {
        snprintf(probe->reason, sizeof probe->reason, "gpu-node-missing");
    } else if (!probe->icd_present) {
        snprintf(probe->reason, sizeof probe->reason, "icd-missing");
    } else {
        snprintf(probe->reason, sizeof probe->reason, "ready");
    }
    return 0;
}

FLOE_BLAS_ACTIVATION_PUBLIC int floe_blas_activate_process(void)
{
    floe_blas_activation_probe probe;
    const char *existing;
    char combined[FLOE_BLAS_PRELOAD_MAX];
    size_t existing_length;
    int written;

    if (floe_blas_activation_inspect(&probe) != 0) return 0;
    if (!probe.would_activate) return 0;

    existing = getenv("LD_PRELOAD");
    if (preload_contains(existing, FLOE_BLAS_LIBRARY_PATH)) {
        (void)setenv("FLOE_BLAS_ACTIVE", "1", 1);
        (void)setenv("FLOE_BLAS_MODE", mode_name(probe.mode), 1);
        return 1;
    }

    existing_length = existing != NULL ? strlen(existing) : 0;
    if (existing_length + strlen(FLOE_BLAS_LIBRARY_PATH) + 2 >= sizeof combined)
        return 0;
    if (existing_length > 0) {
        written = snprintf(combined, sizeof combined, "%s:%s",
                           FLOE_BLAS_LIBRARY_PATH, existing);
    } else {
        written = snprintf(combined, sizeof combined, "%s",
                           FLOE_BLAS_LIBRARY_PATH);
    }
    if (written < 0 || (size_t)written >= sizeof combined) return 0;

    if (setenv("FLOE_BLAS_MODE", mode_name(probe.mode), 1) != 0) return 0;
    if (setenv("FLOE_BLAS_ACTIVE", "1", 1) != 0) {
        (void)unsetenv("FLOE_BLAS_MODE");
        return 0;
    }
    if (setenv("LD_PRELOAD", combined, 1) != 0) {
        (void)unsetenv("FLOE_BLAS_ACTIVE");
        (void)unsetenv("FLOE_BLAS_MODE");
        return 0;
    }
    return 1;
}

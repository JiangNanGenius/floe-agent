/* SPDX-License-Identifier: Apache-2.0 */
#ifndef FLOE_BLAS_ACTIVATE_H
#define FLOE_BLAS_ACTIVATE_H

#include <stddef.h>

#define FLOE_BLAS_LIBRARY_PATH "/usr/local/lib/floe-acceleration/libfloe_blas.so"
#define FLOE_BLAS_ICD_PATH "/usr/share/vulkan/icd.d/virtio_icd.json"
#define FLOE_BLAS_RENDER_NODE "/dev/dri/renderD128"

typedef struct floe_blas_activation_probe {
    int guest;              /* compiled for and running on Linux */
    int library_present;
    int library_trusted;
    int gpu_node_present;
    int icd_present;
    int mode;               /* FLOE_BLAS_POLICY_AUTO/ON/OFF */
    int mode_source;        /* 0 default, 1 environment, 2 config */
    int would_activate;
    char config_path[512];
    char reason[96];
} floe_blas_activation_probe;

/*
 * Called by the trusted guest runner after its normal environment is built.
 * It is a no-op on a non-Linux host, when policy is off, or when the exact
 * root-owned library, the virtio-gpu render node, and the Venus ICD are not
 * all present.  It never replaces an existing LD_PRELOAD entry.
 *
 * Returns 1 when LD_PRELOAD now contains the provider, 0 otherwise.
 */
int floe_blas_activate_process(void);

/* Read-only inspection used by floe-blas-probe and source tests. */
int floe_blas_activation_inspect(floe_blas_activation_probe *probe);

#endif /* FLOE_BLAS_ACTIVATE_H */

/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Small optional instrumentation API for the Floe guest BLAS provider.
 *
 * The provider is an LD_PRELOAD interposer.  It never changes a caller's
 * source and it falls back to the original guest BLAS for anything it does
 * not handle.  These counters only describe calls that actually traversed
 * this library in the current process; there is no cross-process aggregation
 * and no synthetic "GPU" counter.
 */
#ifndef FLOE_BLAS_H
#define FLOE_BLAS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FLOE_BLAS_VERSION "0.1.0"
#define FLOE_BLAS_API_VERSION 1u

/* Keep the layout stable: append new counters at the end and bump
 * FLOE_BLAS_API_VERSION only for an incompatible change. */
typedef struct floe_blas_stats {
    uint32_t struct_size;      /* caller: sizeof(floe_blas_stats), or 0 */
    uint32_t api_version;      /* output: FLOE_BLAS_API_VERSION */

    uint64_t calls_total;      /* intercepted public BLAS entries */
    uint64_t gemm_calls;
    uint64_t gemv_calls;

    uint64_t gpu_submitted;    /* vkQueueSubmit returned VK_SUCCESS */
    uint64_t gpu_completed;    /* fence + readback + C publication all passed */
    uint64_t gpu_failed;       /* submit/wait/copy failed after an attempt */
    uint64_t gpu_dispatches;   /* vkCmdDispatch records recorded */

    uint64_t fallback_cpu;     /* delegated to the original guest BLAS */
    uint64_t fallback_reference; /* provider-local portable float32 loops */
    uint64_t cpu_shortcuts;    /* zero-size / scale-only fast paths */
    uint64_t invalid_args;     /* rejected without touching C/Y */
    uint64_t threshold_skipped;
    uint64_t budget_skipped;
    uint64_t nonfinite_skipped;
    uint64_t device_unavailable;
    uint64_t device_lost;
    uint64_t alias_copies;

    uint64_t gpu_floats_uploaded;
    uint64_t gpu_floats_downloaded;

    uint32_t gpu_present;      /* 1 only after a real Venus device was opened */
    uint32_t policy;           /* 0 auto, 1 on, 2 off */
    uint32_t device_name_size;
    uint32_t last_error_size;
    char device_name[128];
    char last_error[160];
} floe_blas_stats;

/* Fill *stats.  Returns 0 on success, -1 for a null pointer and -2 when the
 * caller supplied a struct_size smaller than this header's definition. */
int floe_blas_stats_get(floe_blas_stats *stats);

/* Reset this process's counters.  Does not change the policy or the device. */
int floe_blas_stats_reset(void);

/* Open/verify the headless Vulkan device and pipelines.  Returns 0 when a
 * real Venus device is usable, -1 otherwise.  This never starts a display. */
int floe_blas_warmup(void);

const char *floe_blas_version(void);

/* "auto" (default), "on", or "off".  Returns 0 on success, -1 otherwise. */
int floe_blas_policy_set(const char *policy);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_BLAS_H */

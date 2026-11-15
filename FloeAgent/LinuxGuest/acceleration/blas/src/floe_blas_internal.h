/* SPDX-License-Identifier: Apache-2.0 */
#ifndef FLOE_BLAS_INTERNAL_H
#define FLOE_BLAS_INTERNAL_H

#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>
#include <pthread.h>

#include "floe_blas.h"

#define FLOE_BLAS_EXPORT __attribute__((visibility("default")))
#define FLOE_BLAS_UNUSED __attribute__((unused))

#define FLOE_BLAS_MAX_ELEMENTS ((uint64_t)1u << 30)
#define FLOE_BLAS_MAX_SPAN_BYTES (FLOE_BLAS_MAX_ELEMENTS * sizeof(float))

enum {
    FLOE_BLAS_POLICY_AUTO = 0,
    FLOE_BLAS_POLICY_ON = 1,
    FLOE_BLAS_POLICY_OFF = 2
};

typedef struct floe_blas_config {
    uint64_t min_gemm_flops;
    uint64_t min_gemv_flops;
    uint64_t max_gpu_bytes;
    uint64_t timeout_ns;
    int verbose;
} floe_blas_config;

typedef struct floe_blas_counters {
    _Atomic uint64_t calls_total;
    _Atomic uint64_t gemm_calls;
    _Atomic uint64_t gemv_calls;
    _Atomic uint64_t gpu_submitted;
    _Atomic uint64_t gpu_completed;
    _Atomic uint64_t gpu_failed;
    _Atomic uint64_t gpu_dispatches;
    _Atomic uint64_t fallback_cpu;
    _Atomic uint64_t fallback_reference;
    _Atomic uint64_t cpu_shortcuts;
    _Atomic uint64_t invalid_args;
    _Atomic uint64_t threshold_skipped;
    _Atomic uint64_t budget_skipped;
    _Atomic uint64_t nonfinite_skipped;
    _Atomic uint64_t device_unavailable;
    _Atomic uint64_t device_lost;
    _Atomic uint64_t alias_copies;
    _Atomic uint64_t gpu_floats_uploaded;
    _Atomic uint64_t gpu_floats_downloaded;
} floe_blas_counters;

extern floe_blas_config g_floe_blas_config;
extern floe_blas_counters g_floe_blas_counters;
extern _Atomic int g_floe_blas_policy;

static inline void floe_blas_count(_Atomic uint64_t *counter, uint64_t amount)
{
    atomic_fetch_add_explicit(counter, amount, memory_order_relaxed);
}

static inline uint64_t floe_blas_count_read(const _Atomic uint64_t *counter)
{
    return atomic_load_explicit(counter, memory_order_relaxed);
}

void floe_blas_ensure_init(void);
void floe_blas_set_error(const char *message);
void floe_blas_set_errorf(const char *format, ...)
    __attribute__((format(printf, 1, 2)));
void floe_blas_set_device_name(const char *name);
void floe_blas_verbose(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

/* ---- Vulkan backend (headless; never creates a surface or display) ---- */

typedef struct floe_blas_gemm_request {
    const float *a;
    uint64_t a_span;              /* floats addressable from a */
    const float *b;
    uint64_t b_span;
    float *c;
    uint64_t c_span;
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
    int c_has_original;           /* beta != 0 */
} floe_blas_gemm_request;

typedef struct floe_blas_gemv_request {
    const float *a;
    uint64_t a_span;
    const float *x;
    int x_inc;
    uint32_t x_len;
    float *y;
    int y_inc;
    uint32_t y_len;
    uint32_t n_out;               /* length of op(A) rows / y */
    uint32_t k;                   /* reduction length / x */
    uint32_t a_row_stride;
    uint32_t a_col_stride;
    float alpha;
    float beta;
    int beta_nonzero;
} floe_blas_gemv_request;

enum floe_blas_vk_result {
    FLOE_BLAS_VK_OK = 0,
    FLOE_BLAS_VK_UNAVAILABLE = 1,
    FLOE_BLAS_VK_BUDGET = 2,
    FLOE_BLAS_VK_SUBMIT_FAILED = 3,
    FLOE_BLAS_VK_DEVICE_LOST = 4,
    FLOE_BLAS_VK_NONFINITE = 5,
    FLOE_BLAS_VK_INVALID = 6
};

int floe_blas_vk_warmup(void);
int floe_blas_vk_state(void);     /* -1 unknown, 0 unavailable, 1 available */
int floe_blas_vk_gemm(const floe_blas_gemm_request *request);
int floe_blas_vk_gemv(const floe_blas_gemv_request *request);

#endif /* FLOE_BLAS_INTERNAL_H */

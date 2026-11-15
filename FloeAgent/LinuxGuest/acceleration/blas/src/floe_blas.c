/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Standard LP64 BLAS float32 GEMM/GEMV interposer for the Floe Linux guest.
 *
 * The provider is loaded with LD_PRELOAD inside the resolved Linux project.
 * It never replaces the guest's BLAS library on disk: unsupported calls
 * return to the original provider through a loaded-object scan (RTLD_NEXT is
 * attempted first), and a portable float32 reference implementation is the
 * last resort.  Double precision, complex and every other BLAS symbol are
 * untouched.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "floe_blas_internal.h"
#include "floe_blas_cblas.h"
#include "floe_blas_policy.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <link.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

floe_blas_config g_floe_blas_config = {
    .min_gemm_flops = 268435456ULL, /* 2 * 512^3; conservative default */
    .min_gemv_flops = 4194304ULL,   /* 2 * 2048 * 1024 */
    .max_gpu_bytes = 268435456ULL,  /* 256 MiB per call, below the 1 GiB VM */
    .timeout_ns = 60000000000ULL,   /* 60 s backpressure guard */
    .verbose = 0
};

floe_blas_counters g_floe_blas_counters;
_Atomic int g_floe_blas_policy = -1;

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_meta_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_device_name[128];
static char g_last_error[160];
static __thread int g_in_fallback;

typedef void (*CblasSgemmFn)(int, int, int, int, int, int, float,
                             const float *, int, const float *, int, float,
                             float *, int);
typedef void (*CblasSgemvFn)(int, int, int, int, float, const float *, int,
                             const float *, int, float, float *, int);
typedef void (*SgemmFn)(const char *, const char *, const int *, const int *,
                        const int *, const float *, const float *, const int *,
                        const float *, const int *, const float *, float *,
                        const int *);
typedef void (*SgemvFn)(const char *, const int *, const int *, const float *,
                        const float *, const int *, const float *, const int *,
                        const float *, float *, const int *);

typedef struct floe_blas_fallbacks {
    CblasSgemmFn cblas_sgemm;
    CblasSgemvFn cblas_sgemv;
    SgemmFn sgemm;
    SgemvFn sgemv;
} floe_blas_fallbacks;

static floe_blas_fallbacks g_fallbacks;
static pthread_once_t g_fallback_once = PTHREAD_ONCE_INIT;
static void *g_self_base;
static void *g_fallback_handles[8];
static int g_fallback_handle_count;

static uint64_t environment_u64(const char *name, uint64_t fallback,
                                uint64_t minimum, uint64_t maximum)
{
    const char *text = getenv(name);
    char *end = NULL;
    unsigned long long value;

    if (text == NULL || text[0] == '\0') return fallback;
    errno = 0;
    value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        (uint64_t)value < minimum || (uint64_t)value > maximum) {
        return fallback;
    }
    return (uint64_t)value;
}

static int environment_flag(const char *name)
{
    const char *text = getenv(name);
    return text != NULL && text[0] != '\0' && strcmp(text, "0") != 0;
}

static const char *policy_name(int policy)
{
    switch (policy) {
    case FLOE_BLAS_POLICY_ON:
        return "on";
    case FLOE_BLAS_POLICY_OFF:
        return "off";
    default:
        return "auto";
    }
}

static void init_once(void)
{
    char config_path[512];
    int source = 0;
    int mode;

    mode = floe_blas_policy_resolve(config_path, sizeof config_path, &source);
    if (atomic_load_explicit(&g_floe_blas_policy, memory_order_relaxed) < 0)
        atomic_store_explicit(&g_floe_blas_policy, mode, memory_order_relaxed);
    g_floe_blas_config.min_gemm_flops =
        environment_u64("FLOE_BLAS_MIN_FLOPS", g_floe_blas_config.min_gemm_flops,
                        0, UINT64_MAX);
    g_floe_blas_config.min_gemv_flops =
        environment_u64("FLOE_BLAS_GEMV_MIN_FLOPS",
                        g_floe_blas_config.min_gemv_flops, 0, UINT64_MAX);
    g_floe_blas_config.max_gpu_bytes =
        environment_u64("FLOE_BLAS_MAX_GPU_BYTES",
                        g_floe_blas_config.max_gpu_bytes,
                        1048576, 1073741824ULL);
    g_floe_blas_config.timeout_ns =
        environment_u64("FLOE_BLAS_TIMEOUT_MS", 60000, 1000, 600000) *
        1000000ULL;
    g_floe_blas_config.verbose = environment_flag("FLOE_BLAS_VERBOSE");
    if (g_floe_blas_config.verbose) {
        dprintf(STDERR_FILENO,
                "floe-blas: policy=%s source=%s config=%s\n",
                policy_name(atomic_load_explicit(&g_floe_blas_policy,
                                            memory_order_relaxed)),
                source == 1 ? "environment" : (source == 2 ? "config" : "default"),
                config_path[0] != '\0' ? config_path : "(none)");
    }
}

void floe_blas_ensure_init(void)
{
    (void)pthread_once(&g_init_once, init_once);
}

void floe_blas_set_error(const char *message)
{
    if (message == NULL) return;
    pthread_mutex_lock(&g_meta_lock);
    snprintf(g_last_error, sizeof g_last_error, "%s", message);
    pthread_mutex_unlock(&g_meta_lock);
}

void floe_blas_set_errorf(const char *format, ...)
{
    char buffer[160];
    va_list arguments;

    va_start(arguments, format);
    vsnprintf(buffer, sizeof buffer, format, arguments);
    va_end(arguments);
    floe_blas_set_error(buffer);
}

void floe_blas_set_device_name(const char *name)
{
    pthread_mutex_lock(&g_meta_lock);
    snprintf(g_device_name, sizeof g_device_name, "%s", name != NULL ? name : "");
    pthread_mutex_unlock(&g_meta_lock);
}

void floe_blas_verbose(const char *format, ...)
{
    va_list arguments;

    floe_blas_ensure_init();
    if (!g_floe_blas_config.verbose) return;
    va_start(arguments, format);
    dprintf(STDERR_FILENO, "floe-blas: ");
    vdprintf(STDERR_FILENO, format, arguments);
    dprintf(STDERR_FILENO, "\n");
    va_end(arguments);
}

FLOE_BLAS_EXPORT const char *floe_blas_version(void)
{
    return FLOE_BLAS_VERSION;
}

FLOE_BLAS_EXPORT int floe_blas_policy_set(const char *policy)
{
    int parsed;

    if (policy == NULL) return -1;
    parsed = floe_blas_policy_parse_name(policy);
    if (parsed < 0) return -1;
    atomic_store_explicit(&g_floe_blas_policy, parsed, memory_order_relaxed);
    return 0;
}

static void reset_counter(_Atomic uint64_t *counter)
{
    atomic_store_explicit(counter, 0, memory_order_relaxed);
}

FLOE_BLAS_EXPORT int floe_blas_stats_reset(void)
{
    floe_blas_ensure_init();
    reset_counter(&g_floe_blas_counters.calls_total);
    reset_counter(&g_floe_blas_counters.gemm_calls);
    reset_counter(&g_floe_blas_counters.gemv_calls);
    reset_counter(&g_floe_blas_counters.gpu_submitted);
    reset_counter(&g_floe_blas_counters.gpu_completed);
    reset_counter(&g_floe_blas_counters.gpu_failed);
    reset_counter(&g_floe_blas_counters.gpu_dispatches);
    reset_counter(&g_floe_blas_counters.fallback_cpu);
    reset_counter(&g_floe_blas_counters.fallback_reference);
    reset_counter(&g_floe_blas_counters.cpu_shortcuts);
    reset_counter(&g_floe_blas_counters.invalid_args);
    reset_counter(&g_floe_blas_counters.threshold_skipped);
    reset_counter(&g_floe_blas_counters.budget_skipped);
    reset_counter(&g_floe_blas_counters.nonfinite_skipped);
    reset_counter(&g_floe_blas_counters.device_unavailable);
    reset_counter(&g_floe_blas_counters.device_lost);
    reset_counter(&g_floe_blas_counters.alias_copies);
    reset_counter(&g_floe_blas_counters.gpu_floats_uploaded);
    reset_counter(&g_floe_blas_counters.gpu_floats_downloaded);
    floe_blas_set_error("");
    return 0;
}

FLOE_BLAS_EXPORT int floe_blas_stats_get(floe_blas_stats *stats)
{
    floe_blas_stats output;
    int policy;

    floe_blas_ensure_init();
    if (stats == NULL) return -1;
    if (stats->struct_size != 0 && stats->struct_size < sizeof(floe_blas_stats))
        return -2;

    memset(&output, 0, sizeof output);
    output.struct_size = sizeof output;
    output.api_version = FLOE_BLAS_API_VERSION;
    output.calls_total = floe_blas_count_read(&g_floe_blas_counters.calls_total);
    output.gemm_calls = floe_blas_count_read(&g_floe_blas_counters.gemm_calls);
    output.gemv_calls = floe_blas_count_read(&g_floe_blas_counters.gemv_calls);
    output.gpu_submitted =
        floe_blas_count_read(&g_floe_blas_counters.gpu_submitted);
    output.gpu_completed =
        floe_blas_count_read(&g_floe_blas_counters.gpu_completed);
    output.gpu_failed = floe_blas_count_read(&g_floe_blas_counters.gpu_failed);
    output.gpu_dispatches =
        floe_blas_count_read(&g_floe_blas_counters.gpu_dispatches);
    output.fallback_cpu =
        floe_blas_count_read(&g_floe_blas_counters.fallback_cpu);
    output.fallback_reference =
        floe_blas_count_read(&g_floe_blas_counters.fallback_reference);
    output.cpu_shortcuts =
        floe_blas_count_read(&g_floe_blas_counters.cpu_shortcuts);
    output.invalid_args =
        floe_blas_count_read(&g_floe_blas_counters.invalid_args);
    output.threshold_skipped =
        floe_blas_count_read(&g_floe_blas_counters.threshold_skipped);
    output.budget_skipped =
        floe_blas_count_read(&g_floe_blas_counters.budget_skipped);
    output.nonfinite_skipped =
        floe_blas_count_read(&g_floe_blas_counters.nonfinite_skipped);
    output.device_unavailable =
        floe_blas_count_read(&g_floe_blas_counters.device_unavailable);
    output.device_lost =
        floe_blas_count_read(&g_floe_blas_counters.device_lost);
    output.alias_copies =
        floe_blas_count_read(&g_floe_blas_counters.alias_copies);
    output.gpu_floats_uploaded =
        floe_blas_count_read(&g_floe_blas_counters.gpu_floats_uploaded);
    output.gpu_floats_downloaded =
        floe_blas_count_read(&g_floe_blas_counters.gpu_floats_downloaded);

    policy = atomic_load_explicit(&g_floe_blas_policy, memory_order_relaxed);
    output.policy = (uint32_t)(policy < 0 ? FLOE_BLAS_POLICY_AUTO : policy);
    output.gpu_present = floe_blas_vk_state() == 1 ? 1u : 0u;

    pthread_mutex_lock(&g_meta_lock);
    snprintf(output.device_name, sizeof output.device_name, "%s", g_device_name);
    snprintf(output.last_error, sizeof output.last_error, "%s", g_last_error);
    pthread_mutex_unlock(&g_meta_lock);
    output.device_name_size = (uint32_t)strlen(output.device_name);
    output.last_error_size = (uint32_t)strlen(output.last_error);
    memcpy(stats, &output, sizeof output);
    return 0;
}

FLOE_BLAS_EXPORT int floe_blas_warmup(void)
{
    int result;

    floe_blas_ensure_init();
    result = floe_blas_vk_warmup();
    if (result != 0) {
        floe_blas_count(&g_floe_blas_counters.device_unavailable, 1);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------------- */
/* Portable float32 reference paths                                          */
/* ------------------------------------------------------------------------- */

static size_t index2(uint32_t row, uint32_t column, uint32_t row_stride,
                     uint32_t column_stride)
{
    return (size_t)row * row_stride + (size_t)column * column_stride;
}

static void scale_c(uint32_t m, uint32_t n, float beta, float *c,
                    uint32_t c_row_stride, uint32_t c_column_stride)
{
    uint32_t row;
    uint32_t column;

    if (beta == 1.0f) return;
    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            float *element = c + index2(row, column, c_row_stride,
                                         c_column_stride);
            *element = beta == 0.0f ? 0.0f : beta * *element;
        }
    }
}

static void gemm_reference(uint32_t m, uint32_t n, uint32_t k,
                           const float *a, uint32_t a_row_stride,
                           uint32_t a_column_stride, const float *b,
                           uint32_t b_row_stride, uint32_t b_column_stride,
                           float alpha, float beta, float *c,
                           uint32_t c_row_stride, uint32_t c_column_stride)
{
    uint32_t row;
    uint32_t column;
    uint32_t inner;

    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            float sum = 0.0f;
            for (inner = 0; inner < k; inner++) {
                sum += a[index2(row, inner, a_row_stride, a_column_stride)] *
                       b[index2(inner, column, b_row_stride, b_column_stride)];
            }
            {
                float *element = c + index2(row, column, c_row_stride,
                                             c_column_stride);
                float previous = beta == 0.0f ? 0.0f : *element;
                *element = alpha * sum + beta * previous;
            }
        }
    }
}

static uint64_t vector_span(uint32_t length, int increment)
{
    uint64_t step;
    uint64_t offset;

    if (length == 0) return 0;
    step = increment < 0 ? (uint64_t)(-(int64_t)increment)
                         : (uint64_t)increment;
    if (step != 0 && (uint64_t)(length - 1) > (UINT64_MAX - 1) / step)
        return 0;
    offset = (uint64_t)(length - 1) * step;
    return offset + 1;
}

static size_t vector_index(uint32_t index, int increment, uint32_t length)
{
    if (increment > 0) return (size_t)index * (size_t)increment;
    return (size_t)(length - 1 - index) * (size_t)(-(int64_t)increment);
}

static int gemv_reference(uint32_t n_out, uint32_t k, const float *a,
                          uint32_t a_row_stride, uint32_t a_column_stride,
                          const float *x, int x_increment, float alpha,
                          float beta, float *y, int y_increment,
                          uint32_t y_length)
{
    uint32_t index;
    uint32_t inner;
    float *x_copy = NULL;
    float *y_copy = NULL;

    if (alpha != 0.0f) {
        x_copy = malloc((size_t)k * sizeof(float));
        if (x_copy == NULL) {
            floe_blas_set_error("GEMV x copy allocation failed");
            return -1;
        }
        for (inner = 0; inner < k; inner++)
            x_copy[inner] = x[vector_index(inner, x_increment, k)];
    }
    if (beta != 0.0f) {
        y_copy = malloc((size_t)y_length * sizeof(float));
        if (y_copy == NULL) {
            free(x_copy);
            floe_blas_set_error("GEMV y copy allocation failed");
            return -1;
        }
        for (index = 0; index < y_length; index++)
            y_copy[index] = y[vector_index(index, y_increment, y_length)];
    }

    for (index = 0; index < n_out; index++) {
        float sum = 0.0f;
        float previous;
        if (alpha != 0.0f) {
            for (inner = 0; inner < k; inner++) {
                sum += a[index2(index, inner, a_row_stride, a_column_stride)] *
                       x_copy[inner];
            }
        }
        previous = beta != 0.0f ? y_copy[index] : 0.0f;
        y[vector_index(index, y_increment, y_length)] =
            alpha * sum + beta * previous;
    }
    free(x_copy);
    free(y_copy);
    return 0;
}

static const float *vector_base(const float *pointer, uint32_t length,
                                int increment)
{
    if (length == 0 || increment >= 0) return pointer;
    return pointer - (size_t)(length - 1) * (size_t)(-(int64_t)increment);
}

/* ------------------------------------------------------------------------- */
/* Original guest BLAS discovery                                             */
/* ------------------------------------------------------------------------- */

static void assign_symbol(void *destination, size_t destination_size,
                          void *symbol)
{
    if (symbol != NULL && destination_size == sizeof symbol)
        memcpy(destination, &symbol, sizeof symbol);
}

static void load_symbols_from_handle(void *handle)
{
    void *symbol;

    symbol = dlsym(handle, "cblas_sgemm");
    assign_symbol(&g_fallbacks.cblas_sgemm, sizeof g_fallbacks.cblas_sgemm,
                  symbol);
    symbol = dlsym(handle, "cblas_sgemv");
    assign_symbol(&g_fallbacks.cblas_sgemv, sizeof g_fallbacks.cblas_sgemv,
                  symbol);
    symbol = dlsym(handle, "sgemm_");
    assign_symbol(&g_fallbacks.sgemm, sizeof g_fallbacks.sgemm, symbol);
    symbol = dlsym(handle, "sgemv_");
    assign_symbol(&g_fallbacks.sgemv, sizeof g_fallbacks.sgemv, symbol);
}

static int fallbacks_complete(void)
{
    return g_fallbacks.cblas_sgemm != NULL &&
           g_fallbacks.cblas_sgemv != NULL &&
           g_fallbacks.sgemm != NULL &&
           g_fallbacks.sgemv != NULL;
}

static void keep_handle(void *handle)
{
    int index;
    if (handle == NULL) return;
    for (index = 0; index < g_fallback_handle_count; index++) {
        if (g_fallback_handles[index] == handle) return;
    }
    if (g_fallback_handle_count <
        (int)(sizeof g_fallback_handles / sizeof g_fallback_handles[0])) {
        g_fallback_handles[g_fallback_handle_count++] = handle;
    }
}

static int scan_loaded_object(struct dl_phdr_info *info, size_t size, void *data)
{
    void *handle;
    (void)size;
    (void)data;

    if (info == NULL || info->dlpi_name == NULL || info->dlpi_name[0] == '\0')
        return 0;
    if (info->dlpi_addr == (ElfW(Addr))g_self_base) return 0;
    if (strstr(info->dlpi_name, "libfloe_blas.so") != NULL) return 0;
    handle = dlopen(info->dlpi_name, RTLD_NOW | RTLD_NOLOAD | RTLD_LOCAL);
    if (handle == NULL) return 0;
    load_symbols_from_handle(handle);
    if (g_fallbacks.cblas_sgemm == NULL &&
        g_fallbacks.cblas_sgemv == NULL &&
        g_fallbacks.sgemm == NULL &&
        g_fallbacks.sgemv == NULL) {
        dlclose(handle);
        return 0;
    }
    keep_handle(handle);
    return fallbacks_complete() ? 1 : 0;
}

static void resolve_fallbacks_once(void)
{
    static const char *const known[] = {
        "libopenblas.so.0", "libblas.so.3", "liblapack.so.3",
        "libopenblas.so", "libblas.so", "liblapack.so"
    };
    Dl_info self_info;
    size_t index;

    if (dladdr((void *)&resolve_fallbacks_once, &self_info) != 0)
        g_self_base = self_info.dli_fbase;

    {
        void *symbol = dlsym(RTLD_NEXT, "cblas_sgemm");
        assign_symbol(&g_fallbacks.cblas_sgemm, sizeof g_fallbacks.cblas_sgemm,
                      symbol);
        symbol = dlsym(RTLD_NEXT, "cblas_sgemv");
        assign_symbol(&g_fallbacks.cblas_sgemv, sizeof g_fallbacks.cblas_sgemv,
                      symbol);
        symbol = dlsym(RTLD_NEXT, "sgemm_");
        assign_symbol(&g_fallbacks.sgemm, sizeof g_fallbacks.sgemm, symbol);
        symbol = dlsym(RTLD_NEXT, "sgemv_");
        assign_symbol(&g_fallbacks.sgemv, sizeof g_fallbacks.sgemv, symbol);
    }
    if (fallbacks_complete()) return;

    (void)dl_iterate_phdr(scan_loaded_object, NULL);
    if (fallbacks_complete()) return;

    for (index = 0; index < sizeof known / sizeof known[0]; index++) {
        void *handle = dlopen(known[index], RTLD_NOW | RTLD_LOCAL);
        if (handle == NULL) continue;
        load_symbols_from_handle(handle);
        keep_handle(handle);
        if (fallbacks_complete()) return;
    }
}

static void ensure_fallbacks(void)
{
    (void)pthread_once(&g_fallback_once, resolve_fallbacks_once);
}

static char fortran_transpose(int transposed)
{
    return transposed ? 'T' : 'N';
}

static int fortran_transpose_value(char value)
{
    switch (value) {
    case 'n':
    case 'N':
        return 0;
    case 't':
    case 'T':
    case 'c':
    case 'C':
        return 1;
    default:
        return -1;
    }
}

static void call_fortran_gemm(int order, int transa, int transb,
                              int m, int n, int k, float alpha,
                              const float *a, int lda, const float *b,
                              int ldb, float beta, float *c, int ldc)
{
    char transa_char = fortran_transpose(transa);
    char transb_char = fortran_transpose(transb);

    if (g_fallbacks.sgemm == NULL) return;
    g_in_fallback++;
    if (order == FLOE_CBLAS_COL_MAJOR) {
        g_fallbacks.sgemm(&transa_char, &transb_char, &m, &n, &k, &alpha, a,
                          &lda, b, &ldb, &beta, c, &ldc);
    } else {
        char first = fortran_transpose(transb);
        char second = fortran_transpose(transa);
        g_fallbacks.sgemm(&first, &second, &n, &m, &k, &alpha, b, &ldb, a,
                          &lda, &beta, c, &ldc);
    }
    g_in_fallback--;
}

static void call_fortran_gemv(int order, int transa, int m, int n,
                              float alpha, const float *a, int lda,
                              const float *x, int incx, float beta, float *y,
                              int incy)
{
    char trans = fortran_transpose(transa);
    if (g_fallbacks.sgemv == NULL) return;
    g_in_fallback++;
    if (order == FLOE_CBLAS_COL_MAJOR) {
        g_fallbacks.sgemv(&trans, &m, &n, &alpha, a, &lda, x, &incx, &beta,
                          y, &incy);
    } else {
        char flipped = fortran_transpose(!transa);
        g_fallbacks.sgemv(&flipped, &n, &m, &alpha, a, &lda, x, &incx, &beta,
                          y, &incy);
    }
    g_in_fallback--;
}

static int ranges_overlap(const void *first, size_t first_bytes,
                          const void *second, size_t second_bytes)
{
    uintptr_t first_address = (uintptr_t)first;
    uintptr_t second_address = (uintptr_t)second;

    if (first_bytes == 0 || second_bytes == 0) return 0;
    if (first_address > UINTPTR_MAX - first_bytes ||
        second_address > UINTPTR_MAX - second_bytes)
        return 1;
    return first_address < second_address + second_bytes &&
           second_address < first_address + first_bytes;
}

static int gemm_reference_with_alias(uint32_t m, uint32_t n, uint32_t k,
                                     const float *a, uint64_t a_span,
                                     uint32_t a_row_stride,
                                     uint32_t a_column_stride, const float *b,
                                     uint64_t b_span, uint32_t b_row_stride,
                                     uint32_t b_column_stride, float alpha,
                                     float beta, float *c,
                                     uint32_t c_row_stride,
                                     uint32_t c_column_stride)
{
    float *a_copy = NULL;
    float *b_copy = NULL;
    size_t a_bytes = (size_t)a_span * sizeof(float);
    size_t b_bytes = (size_t)b_span * sizeof(float);

    if (a_span > FLOE_BLAS_MAX_ELEMENTS || b_span > FLOE_BLAS_MAX_ELEMENTS)
        return -1;
    a_copy = malloc(a_bytes);
    b_copy = malloc(b_bytes);
    if (a_copy == NULL || b_copy == NULL) {
        free(a_copy);
        free(b_copy);
        floe_blas_set_error("aliased GEMM copy allocation failed");
        return -1;
    }
    memcpy(a_copy, a, a_bytes);
    memcpy(b_copy, b, b_bytes);
    gemm_reference(m, n, k, a_copy, a_row_stride, a_column_stride, b_copy,
                   b_row_stride, b_column_stride, alpha, beta, c, c_row_stride,
                   c_column_stride);
    free(a_copy);
    free(b_copy);
    return 0;
}

static void gemm_cpu_dispatch(int order, int transa, int transb, int m, int n,
                              int k, float alpha, const float *a, int lda,
                              const float *b, int ldb, float beta, float *c,
                              int ldc, uint32_t a_row_stride,
                              uint32_t a_column_stride, uint32_t b_row_stride,
                              uint32_t b_column_stride, uint32_t c_row_stride,
                              uint32_t c_column_stride, uint64_t a_span,
                              uint64_t b_span, int aliased)
{
    ensure_fallbacks();
    if (g_in_fallback) {
        if (aliased) {
            if (gemm_reference_with_alias((uint32_t)m, (uint32_t)n,
                                          (uint32_t)k, a, a_span,
                                          a_row_stride, a_column_stride, b,
                                          b_span, b_row_stride, b_column_stride,
                                          alpha, beta, c, c_row_stride,
                                          c_column_stride) == 0)
                floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
        } else {
            gemm_reference((uint32_t)m, (uint32_t)n, (uint32_t)k, a,
                           a_row_stride, a_column_stride, b, b_row_stride,
                           b_column_stride, alpha, beta, c, c_row_stride,
                           c_column_stride);
            floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
        }
        return;
    }
    if (aliased) {
        floe_blas_count(&g_floe_blas_counters.alias_copies, 1);
        if (gemm_reference_with_alias((uint32_t)m, (uint32_t)n, (uint32_t)k, a,
                                      a_span, a_row_stride, a_column_stride, b,
                                      b_span, b_row_stride, b_column_stride,
                                      alpha, beta, c, c_row_stride,
                                      c_column_stride) == 0) {
            floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
        }
        return;
    }
    if (g_fallbacks.cblas_sgemm != NULL) {
        g_in_fallback++;
        g_fallbacks.cblas_sgemm(order, transa, transb, m, n, k, alpha, a, lda,
                                b, ldb, beta, c, ldc);
        g_in_fallback--;
        floe_blas_count(&g_floe_blas_counters.fallback_cpu, 1);
        return;
    }
    if (g_fallbacks.sgemm != NULL) {
        g_in_fallback++;
        call_fortran_gemm(order, transa, transb, m, n, k, alpha, a, lda, b,
                          ldb, beta, c, ldc);
        g_in_fallback--;
        floe_blas_count(&g_floe_blas_counters.fallback_cpu, 1);
        return;
    }
    gemm_reference((uint32_t)m, (uint32_t)n, (uint32_t)k, a, a_row_stride,
                   a_column_stride, b, b_row_stride, b_column_stride, alpha,
                   beta, c, c_row_stride, c_column_stride);
    floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
}

static int valid_transpose(int value, int *transposed)
{
    if (value == FLOE_CBLAS_NO_TRANS) {
        *transposed = 0;
        return 1;
    }
    if (value == FLOE_CBLAS_TRANS || value == FLOE_CBLAS_CONJ_TRANS) {
        *transposed = 1;
        return 1;
    }
    return 0;
}

static int gemm_layout(int order, int transa, int transb, int m, int n, int k,
                       int lda, int ldb, int ldc, uint32_t *a_row_stride,
                       uint32_t *a_column_stride, uint32_t *b_row_stride,
                       uint32_t *b_column_stride, uint32_t *c_row_stride,
                       uint32_t *c_column_stride)
{
    if (lda <= 0 || ldb <= 0 || ldc <= 0) return 0;
    if (order == FLOE_CBLAS_ROW_MAJOR) {
        if (transa) {
            if (lda < m) return 0;
            *a_row_stride = 1;
            *a_column_stride = (uint32_t)lda;
        } else {
            if (lda < k) return 0;
            *a_row_stride = (uint32_t)lda;
            *a_column_stride = 1;
        }
        if (transb) {
            if (ldb < k) return 0;
            *b_row_stride = 1;
            *b_column_stride = (uint32_t)ldb;
        } else {
            if (ldb < n) return 0;
            *b_row_stride = (uint32_t)ldb;
            *b_column_stride = 1;
        }
        if (ldc < n) return 0;
        *c_row_stride = (uint32_t)ldc;
        *c_column_stride = 1;
        return 1;
    }
    if (order == FLOE_CBLAS_COL_MAJOR) {
        if (transa) {
            if (lda < k) return 0;
            *a_row_stride = (uint32_t)lda;
            *a_column_stride = 1;
        } else {
            if (lda < m) return 0;
            *a_row_stride = 1;
            *a_column_stride = (uint32_t)lda;
        }
        if (transb) {
            if (ldb < n) return 0;
            *b_row_stride = (uint32_t)ldb;
            *b_column_stride = 1;
        } else {
            if (ldb < k) return 0;
            *b_row_stride = 1;
            *b_column_stride = (uint32_t)ldb;
        }
        if (ldc < m) return 0;
        *c_row_stride = 1;
        *c_column_stride = (uint32_t)ldc;
        return 1;
    }
    return 0;
}

static int matrix_span(uint32_t rows, uint32_t columns, uint32_t row_stride,
                       uint32_t column_stride, uint64_t *span)
{
    uint64_t row_part;
    uint64_t column_part;

    if (rows == 0 || columns == 0) {
        *span = 0;
        return 1;
    }
    row_part = (uint64_t)(rows - 1) * row_stride;
    column_part = (uint64_t)(columns - 1) * column_stride;
    if (row_part > UINT64_MAX - column_part - 1) return 0;
    *span = row_part + column_part + 1;
    return *span <= SIZE_MAX / sizeof(float);
}

static int multiply_u64(uint64_t first, uint64_t second, uint64_t *result)
{
    if (first != 0 && second > UINT64_MAX / first) return 0;
    *result = first * second;
    return 1;
}

static uint64_t gemm_flops(uint32_t m, uint32_t n, uint32_t k)
{
    uint64_t result;
    uint64_t product;

    if (!multiply_u64(m, n, &product) || !multiply_u64(product, k, &result) ||
        !multiply_u64(result, 2, &result))
        return UINT64_MAX;
    return result;
}

static void gemm_impl(int order, int transa, int transb, int m, int n, int k,
                      float alpha, const float *a, int lda, const float *b,
                      int ldb, float beta, float *c, int ldc)
{
    int a_transposed;
    int b_transposed;
    uint32_t a_row_stride;
    uint32_t a_column_stride;
    uint32_t b_row_stride;
    uint32_t b_column_stride;
    uint32_t c_row_stride;
    uint32_t c_column_stride;
    uint64_t a_span = 0;
    uint64_t b_span = 0;
    uint64_t c_span = 0;
    uint64_t total_bytes;
    uint64_t flops;
    int aliased = 0;
    int policy;
    int gpu_result;

    if (m < 0 || n < 0 || k < 0 ||
        !valid_transpose(transa, &a_transposed) ||
        !valid_transpose(transb, &b_transposed) ||
        (order != FLOE_CBLAS_ROW_MAJOR && order != FLOE_CBLAS_COL_MAJOR)) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (m == 0 || n == 0) return;
    if (alpha == 0.0f && beta == 1.0f) return;
    if (c == NULL) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }

    if (order == FLOE_CBLAS_ROW_MAJOR) {
        if (ldc < n) {
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
            return;
        }
        c_row_stride = (uint32_t)ldc;
        c_column_stride = 1;
    } else {
        if (ldc < m) {
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
            return;
        }
        c_row_stride = 1;
        c_column_stride = (uint32_t)ldc;
    }

    if (alpha == 0.0f || k == 0) {
        if (!matrix_span((uint32_t)m, (uint32_t)n, c_row_stride,
                         c_column_stride, &c_span)) {
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
            return;
        }
        scale_c((uint32_t)m, (uint32_t)n, beta, c, c_row_stride,
                c_column_stride);
        floe_blas_count(&g_floe_blas_counters.cpu_shortcuts, 1);
        return;
    }

    if (a == NULL || b == NULL) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (!gemm_layout(order, a_transposed, b_transposed, m, n, k, lda, ldb, ldc,
                     &a_row_stride, &a_column_stride, &b_row_stride,
                     &b_column_stride, &c_row_stride, &c_column_stride)) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (!matrix_span((uint32_t)m, (uint32_t)k, a_row_stride, a_column_stride,
                     &a_span) ||
        !matrix_span((uint32_t)k, (uint32_t)n, b_row_stride, b_column_stride,
                     &b_span) ||
        !matrix_span((uint32_t)m, (uint32_t)n, c_row_stride, c_column_stride,
                     &c_span)) {
        floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
        gemm_cpu_dispatch(order, transa, transb, m, n, k, alpha, a, lda, b,
                          ldb, beta, c, ldc, a_row_stride, a_column_stride,
                          b_row_stride, b_column_stride, c_row_stride,
                          c_column_stride, 0, 0, 0);
        return;
    }
    aliased = ranges_overlap(c, (size_t)c_span * sizeof(float), a,
                             (size_t)a_span * sizeof(float)) ||
              ranges_overlap(c, (size_t)c_span * sizeof(float), b,
                             (size_t)b_span * sizeof(float));
    if (a_span > FLOE_BLAS_MAX_ELEMENTS || b_span > FLOE_BLAS_MAX_ELEMENTS ||
        c_span > FLOE_BLAS_MAX_ELEMENTS) {
        floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
        gemm_cpu_dispatch(order, transa, transb, m, n, k, alpha, a, lda, b,
                          ldb, beta, c, ldc, a_row_stride, a_column_stride,
                          b_row_stride, b_column_stride, c_row_stride,
                          c_column_stride, a_span, b_span, aliased);
        return;
    }

    policy = atomic_load_explicit(&g_floe_blas_policy, memory_order_relaxed);
    if (policy < 0) policy = FLOE_BLAS_POLICY_AUTO;
    if (g_in_fallback) policy = FLOE_BLAS_POLICY_OFF;

    if (policy != FLOE_BLAS_POLICY_OFF) {
        if (!isfinite(alpha) || !isfinite(beta)) {
            floe_blas_count(&g_floe_blas_counters.nonfinite_skipped, 1);
        } else {
            flops = gemm_flops((uint32_t)m, (uint32_t)n, (uint32_t)k);
            if (policy == FLOE_BLAS_POLICY_AUTO &&
                flops < g_floe_blas_config.min_gemm_flops) {
                floe_blas_count(&g_floe_blas_counters.threshold_skipped, 1);
            } else if (!multiply_u64(a_span + b_span + c_span, sizeof(float),
                                     &total_bytes) ||
                       total_bytes > g_floe_blas_config.max_gpu_bytes) {
                floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
            } else {
                floe_blas_gemm_request request;
                memset(&request, 0, sizeof request);
                request.a = a;
                request.a_span = a_span;
                request.b = b;
                request.b_span = b_span;
                request.c = c;
                request.c_span = c_span;
                request.m = (uint32_t)m;
                request.n = (uint32_t)n;
                request.k = (uint32_t)k;
                request.a_row_stride = a_row_stride;
                request.a_col_stride = a_column_stride;
                request.b_row_stride = b_row_stride;
                request.b_col_stride = b_column_stride;
                request.c_row_stride = c_row_stride;
                request.c_col_stride = c_column_stride;
                request.alpha = alpha;
                request.beta = beta;
                request.c_has_original = beta != 0.0f;
                gpu_result = floe_blas_vk_gemm(&request);
                switch (gpu_result) {
                case FLOE_BLAS_VK_OK:
                    return;
                case FLOE_BLAS_VK_NONFINITE:
                    floe_blas_count(&g_floe_blas_counters.nonfinite_skipped, 1);
                    break;
                case FLOE_BLAS_VK_DEVICE_LOST:
                    floe_blas_count(&g_floe_blas_counters.device_lost, 1);
                    break;
                case FLOE_BLAS_VK_BUDGET:
                case FLOE_BLAS_VK_INVALID:
                    floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
                    break;
                case FLOE_BLAS_VK_UNAVAILABLE:
                    floe_blas_count(&g_floe_blas_counters.device_unavailable, 1);
                    break;
                default:
                    break;
                }
            }
        }
    }

    gemm_cpu_dispatch(order, transa, transb, m, n, k, alpha, a, lda, b, ldb,
                      beta, c, ldc, a_row_stride, a_column_stride,
                      b_row_stride, b_column_stride, c_row_stride,
                      c_column_stride, a_span, b_span, aliased);
}

static void gemv_layout(int order, int transa, int m, int n, int lda,
                        uint32_t *n_out, uint32_t *k, uint32_t *row_stride,
                        uint32_t *column_stride)
{
    if (transa) {
        *n_out = (uint32_t)n;
        *k = (uint32_t)m;
        if (order == FLOE_CBLAS_ROW_MAJOR) {
            *row_stride = 1;
            *column_stride = (uint32_t)lda;
        } else {
            *row_stride = (uint32_t)lda;
            *column_stride = 1;
        }
    } else {
        *n_out = (uint32_t)m;
        *k = (uint32_t)n;
        if (order == FLOE_CBLAS_ROW_MAJOR) {
            *row_stride = (uint32_t)lda;
            *column_stride = 1;
        } else {
            *row_stride = 1;
            *column_stride = (uint32_t)lda;
        }
    }
}

static int gemv_valid_leading_dimension(int order, int transa, int m, int n,
                                        int lda)
{
    (void)transa;
    if (lda <= 0) return 0;
    if (order == FLOE_CBLAS_ROW_MAJOR) return lda >= n;
    return lda >= m;
}

static void gemv_cpu_dispatch(int order, int transa, int m, int n, float alpha,
                              const float *a, int lda, const float *x,
                              int incx, float beta, float *y, int incy,
                              uint32_t n_out, uint32_t k, uint32_t row_stride,
                              uint32_t column_stride, uint64_t a_span,
                              uint64_t x_span, uint64_t y_span)
{
    const float *x_base = vector_base(x, k, incx);
    const float *y_base = vector_base(y, (uint32_t)n_out, incy);
    int aliased = ranges_overlap(y_base, (size_t)y_span * sizeof(float), a,
                                 (size_t)a_span * sizeof(float)) ||
                  ranges_overlap(y_base, (size_t)y_span * sizeof(float), x_base,
                                 (size_t)x_span * sizeof(float));
    ensure_fallbacks();
    if (g_in_fallback) {
        if (gemv_reference(n_out, k, a, row_stride, column_stride, x, incx,
                           alpha, beta, y, incy, (uint32_t)n_out) == 0)
            floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
        return;
    }
    if (aliased) {
        floe_blas_count(&g_floe_blas_counters.alias_copies, 1);
        if (gemv_reference(n_out, k, a, row_stride, column_stride, x, incx,
                           alpha, beta, y, incy, (uint32_t)n_out) == 0)
            floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
        return;
    }
    if (g_fallbacks.cblas_sgemv != NULL) {
        g_in_fallback++;
        g_fallbacks.cblas_sgemv(order, transa, m, n, alpha, a, lda, x, incx,
                                beta, y, incy);
        g_in_fallback--;
        floe_blas_count(&g_floe_blas_counters.fallback_cpu, 1);
        return;
    }
    if (g_fallbacks.sgemv != NULL) {
        g_in_fallback++;
        call_fortran_gemv(order, transa, m, n, alpha, a, lda, x, incx, beta, y,
                          incy);
        g_in_fallback--;
        floe_blas_count(&g_floe_blas_counters.fallback_cpu, 1);
        return;
    }
    if (gemv_reference(n_out, k, a, row_stride, column_stride, x, incx, alpha,
                       beta, y, incy, (uint32_t)n_out) == 0)
        floe_blas_count(&g_floe_blas_counters.fallback_reference, 1);
}

static void gemv_impl(int order, int transa, int m, int n, float alpha,
                      const float *a, int lda, const float *x, int incx,
                      float beta, float *y, int incy)
{
    int transposed;
    uint32_t n_out;
    uint32_t k;
    uint32_t row_stride;
    uint32_t column_stride;
    uint64_t a_span;
    uint64_t x_span;
    uint64_t y_span;
    uint64_t total_bytes;
    uint64_t flops;
    uint32_t x_length;
    uint32_t y_length;
    int large_vector = 0;
    int policy;
    int gpu_result;

    if (m < 0 || n < 0 || !valid_transpose(transa, &transposed) ||
        (order != FLOE_CBLAS_ROW_MAJOR && order != FLOE_CBLAS_COL_MAJOR)) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (m == 0 || n == 0) return;
    if (alpha == 0.0f && beta == 1.0f) return;
    if (incx == 0 || incy == 0 || y == NULL) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (!gemv_valid_leading_dimension(order, transposed, m, n, lda)) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }

    gemv_layout(order, transposed, m, n, lda, &n_out, &k, &row_stride,
                &column_stride);
    x_length = k;
    y_length = n_out;
    x_span = vector_span(x_length, incx);
    y_span = vector_span(y_length, incy);
    if (x_span == 0 || y_span == 0) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (x_span > SIZE_MAX / sizeof(float) ||
        y_span > SIZE_MAX / sizeof(float)) {
        large_vector = 1;
        x_span = 0;
        y_span = 0;
    }

    if (alpha == 0.0f) {
        uint32_t index;
        for (index = 0; index < y_length; index++) {
            float *element = y + vector_index(index, incy, y_length);
            float previous = beta == 0.0f ? 0.0f : *element;
            *element = beta * previous;
        }
        floe_blas_count(&g_floe_blas_counters.cpu_shortcuts, 1);
        return;
    }
    if (a == NULL || x == NULL) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    if (!matrix_span(n_out, k, row_stride, column_stride, &a_span)) {
        floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
        return;
    }

    policy = atomic_load_explicit(&g_floe_blas_policy, memory_order_relaxed);
    if (policy < 0) policy = FLOE_BLAS_POLICY_AUTO;
    if (g_in_fallback) policy = FLOE_BLAS_POLICY_OFF;
    if (policy != FLOE_BLAS_POLICY_OFF) {
        if (!isfinite(alpha) || !isfinite(beta)) {
            floe_blas_count(&g_floe_blas_counters.nonfinite_skipped, 1);
        } else {
            if (!multiply_u64(n_out, k, &flops) ||
                !multiply_u64(flops, 2, &flops))
                flops = UINT64_MAX;
            if (policy == FLOE_BLAS_POLICY_AUTO &&
                flops < g_floe_blas_config.min_gemv_flops) {
                floe_blas_count(&g_floe_blas_counters.threshold_skipped, 1);
            } else if (large_vector ||
                       a_span > FLOE_BLAS_MAX_ELEMENTS ||
                       x_span > FLOE_BLAS_MAX_ELEMENTS ||
                       y_span > FLOE_BLAS_MAX_ELEMENTS ||
                       !multiply_u64(a_span + x_length + y_length,
                                     sizeof(float), &total_bytes) ||
                       total_bytes > g_floe_blas_config.max_gpu_bytes) {
                floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
            } else {
                floe_blas_gemv_request request;
                memset(&request, 0, sizeof request);
                request.a = a;
                request.a_span = a_span;
                request.x = x;
                request.x_inc = incx;
                request.x_len = x_length;
                request.y = y;
                request.y_inc = incy;
                request.y_len = y_length;
                request.n_out = n_out;
                request.k = k;
                request.a_row_stride = row_stride;
                request.a_col_stride = column_stride;
                request.alpha = alpha;
                request.beta = beta;
                request.beta_nonzero = beta != 0.0f;
                gpu_result = floe_blas_vk_gemv(&request);
                switch (gpu_result) {
                case FLOE_BLAS_VK_OK:
                    return;
                case FLOE_BLAS_VK_NONFINITE:
                    floe_blas_count(&g_floe_blas_counters.nonfinite_skipped, 1);
                    break;
                case FLOE_BLAS_VK_DEVICE_LOST:
                    floe_blas_count(&g_floe_blas_counters.device_lost, 1);
                    break;
                case FLOE_BLAS_VK_BUDGET:
                case FLOE_BLAS_VK_INVALID:
                    floe_blas_count(&g_floe_blas_counters.budget_skipped, 1);
                    break;
                case FLOE_BLAS_VK_UNAVAILABLE:
                    floe_blas_count(&g_floe_blas_counters.device_unavailable, 1);
                    break;
                default:
                    break;
                }
            }
        }
    }

    gemv_cpu_dispatch(order, transposed ? FLOE_CBLAS_CONJ_TRANS
                                        : FLOE_CBLAS_NO_TRANS,
                      m, n, alpha, a, lda, x, incx, beta, y, incy, n_out, k,
                      row_stride, column_stride, a_span, x_span, y_span);
}

/* ------------------------------------------------------------------------- */
/* Exported ABI                                                              */
/* ------------------------------------------------------------------------- */

FLOE_BLAS_EXPORT void cblas_sgemm(int order, int transa, int transb, int m,
                                  int n, int k, float alpha, const float *a,
                                  int lda, const float *b, int ldb, float beta,
                                  float *c, int ldc)
{
    int a_transposed = 0;
    int b_transposed = 0;

    floe_blas_ensure_init();
    if (g_in_fallback) {
        if (valid_transpose(transa, &a_transposed) &&
            valid_transpose(transb, &b_transposed) && m >= 0 && n >= 0 &&
            k >= 0) {
            gemm_impl(order, transa, transb, m, n, k, alpha, a, lda, b, ldb,
                      beta, c, ldc);
        }
        return;
    }
    floe_blas_count(&g_floe_blas_counters.calls_total, 1);
    floe_blas_count(&g_floe_blas_counters.gemm_calls, 1);
    if (m < 0 || n < 0 || k < 0 ||
        !valid_transpose(transa, &a_transposed) ||
        !valid_transpose(transb, &b_transposed) ||
        (order != FLOE_CBLAS_ROW_MAJOR && order != FLOE_CBLAS_COL_MAJOR)) {
        floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    gemm_impl(order, transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c,
              ldc);
}

FLOE_BLAS_EXPORT void sgemm_(const char *transa, const char *transb,
                             const int *m, const int *n, const int *k,
                             const float *alpha, const float *a,
                             const int *lda, const float *b, const int *ldb,
                             const float *beta, float *c, const int *ldc)
{
    int transa_value;
    int transb_value;

    floe_blas_ensure_init();
    if (!g_in_fallback) {
        floe_blas_count(&g_floe_blas_counters.calls_total, 1);
        floe_blas_count(&g_floe_blas_counters.gemm_calls, 1);
    }
    if (transa == NULL || transb == NULL || m == NULL || n == NULL ||
        k == NULL || alpha == NULL || beta == NULL || lda == NULL ||
        ldb == NULL || ldc == NULL) {
        if (!g_in_fallback)
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    transa_value = fortran_transpose_value(*transa);
    transb_value = fortran_transpose_value(*transb);
    if (transa_value < 0 || transb_value < 0) {
        if (!g_in_fallback)
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    gemm_impl(FLOE_CBLAS_COL_MAJOR,
              transa_value ? FLOE_CBLAS_TRANS : FLOE_CBLAS_NO_TRANS,
              transb_value ? FLOE_CBLAS_TRANS : FLOE_CBLAS_NO_TRANS, *m, *n, *k,
              *alpha, a, *lda, b, *ldb, *beta, c, *ldc);
}

FLOE_BLAS_EXPORT void sgemm(const char *transa, const char *transb,
                            const int *m, const int *n, const int *k,
                            const float *alpha, const float *a,
                            const int *lda, const float *b, const int *ldb,
                            const float *beta, float *c, const int *ldc)
{
    sgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}

FLOE_BLAS_EXPORT void cblas_sgemv(int order, int transa, int m, int n,
                                  float alpha, const float *a, int lda,
                                  const float *x, int incx, float beta,
                                  float *y, int incy)
{
    floe_blas_ensure_init();
    if (!g_in_fallback) {
        floe_blas_count(&g_floe_blas_counters.calls_total, 1);
        floe_blas_count(&g_floe_blas_counters.gemv_calls, 1);
    }
    gemv_impl(order, transa, m, n, alpha, a, lda, x, incx, beta, y, incy);
}

FLOE_BLAS_EXPORT void sgemv_(const char *transa, const int *m, const int *n,
                             const float *alpha, const float *a, const int *lda,
                             const float *x, const int *incx, const float *beta,
                             float *y, const int *incy)
{
    int transa_value;

    floe_blas_ensure_init();
    if (!g_in_fallback) {
        floe_blas_count(&g_floe_blas_counters.calls_total, 1);
        floe_blas_count(&g_floe_blas_counters.gemv_calls, 1);
    }
    if (transa == NULL || m == NULL || n == NULL || alpha == NULL ||
        beta == NULL || lda == NULL || incx == NULL || incy == NULL) {
        if (!g_in_fallback)
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    transa_value = fortran_transpose_value(*transa);
    if (transa_value < 0) {
        if (!g_in_fallback)
            floe_blas_count(&g_floe_blas_counters.invalid_args, 1);
        return;
    }
    gemv_impl(FLOE_CBLAS_COL_MAJOR,
              transa_value ? FLOE_CBLAS_TRANS : FLOE_CBLAS_NO_TRANS, *m, *n,
              *alpha, a, *lda, x, *incx, *beta, y, *incy);
}

FLOE_BLAS_EXPORT void sgemv(const char *transa, const int *m, const int *n,
                            const float *alpha, const float *a, const int *lda,
                            const float *x, const int *incx, const float *beta,
                            float *y, const int *incy)
{
    sgemv_(transa, m, n, alpha, a, lda, x, incx, beta, y, incy);
}

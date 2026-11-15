/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Focused numerical/ABI/fallback tests for the Floe guest BLAS provider.
 * This file is compiled and run later on a real ARM64 Linux guest; the
 * current source-only review cannot execute it.
 *
 * Exit 0: all non-GPU tests passed and the optional GPU counter test either
 *         passed or was skipped because no Venus device was available.
 * Exit 77: all non-GPU tests passed; GPU counter test skipped (no device).
 * Exit 1: at least one assertion failed.
 */
#define _POSIX_C_SOURCE 200809L

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "floe_blas.h"
#include "floe_blas_cblas.h"

static int failures;
static int checks;

#define CHECK(condition, message) \
    do { \
        checks++; \
        if (!(condition)) { \
            failures++; \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
        } \
    } while (0)

static float element(const float *base, int row, int column, int row_stride,
                     int column_stride)
{
    return base[(size_t)row * (size_t)row_stride +
                (size_t)column * (size_t)column_stride];
}

static void fill(float *buffer, size_t count, int seed)
{
    size_t index;
    for (index = 0; index < count; index++)
        buffer[index] = (float)((int)((index * 7u + (unsigned)seed * 11u) % 23u) -
                                11) / 8.0f;
}

static void reference_gemm(int order, int transa, int transb, int m, int n,
                           int k, float alpha, const float *a, int lda,
                           const float *b, int ldb, float beta, const float *c,
                           float *reference, int ldc, int c_row_stride,
                           int c_column_stride)
{
    int row;
    int column;
    int inner;
    int a_row_stride;
    int a_column_stride;
    int b_row_stride;
    int b_column_stride;
    (void)order;
    if (transa) {
        a_row_stride = 1;
        a_column_stride = lda;
    } else {
        a_row_stride = lda;
        a_column_stride = 1;
    }
    if (order == FLOE_CBLAS_COL_MAJOR) {
        if (transa) {
            a_row_stride = lda;
            a_column_stride = 1;
        } else {
            a_row_stride = 1;
            a_column_stride = lda;
        }
    }
    if (transb) {
        b_row_stride = 1;
        b_column_stride = ldb;
    } else {
        b_row_stride = ldb;
        b_column_stride = 1;
    }
    if (order == FLOE_CBLAS_COL_MAJOR) {
        if (transb) {
            b_row_stride = ldb;
            b_column_stride = 1;
        } else {
            b_row_stride = 1;
            b_column_stride = ldb;
        }
    }
    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            float sum = 0.0f;
            for (inner = 0; inner < k; inner++)
                sum += element(a, row, inner, a_row_stride, a_column_stride) *
                       element(b, inner, column, b_row_stride, b_column_stride);
            reference[(size_t)row * (size_t)c_row_stride +
                      (size_t)column * (size_t)c_column_stride] =
                alpha * sum +
                beta * element(c, row, column, c_row_stride, c_column_stride);
        }
    }
}

static void test_gemm_case(int order, int transa, int transb, int m, int n,
                           int k, float alpha, float beta)
{
    int a_stored_rows;
    int a_stored_columns;
    int b_stored_rows;
    int b_stored_columns;
    int lda;
    int ldb;
    int ldc;
    int c_stored_rows = m;
    int c_stored_columns = n;
    size_t a_count;
    size_t b_count;
    size_t c_count;
    float *a;
    float *b;
    float *c;
    float *reference;
    float *c_before;
    int row;
    int column;
    char label[160];

    if (order == FLOE_CBLAS_ROW_MAJOR) {
        lda = (transa ? m : k) + 2;
        ldb = (transb ? k : n) + 2;
        ldc = n + 2;
        a_stored_rows = transa ? k : m;
        a_stored_columns = transa ? m : k;
        b_stored_rows = transb ? n : k;
        b_stored_columns = transb ? k : n;
    } else {
        lda = (transa ? k : m) + 2;
        ldb = (transb ? n : k) + 2;
        ldc = m + 2;
        a_stored_rows = transa ? k : m;
        a_stored_columns = transa ? m : k;
        b_stored_rows = transb ? n : k;
        b_stored_columns = transb ? k : n;
    }
    a_count = order == FLOE_CBLAS_ROW_MAJOR
        ? (size_t)a_stored_rows * lda
        : (size_t)a_stored_columns * lda;
    b_count = order == FLOE_CBLAS_ROW_MAJOR
        ? (size_t)b_stored_rows * ldb
        : (size_t)b_stored_columns * ldb;
    c_count = order == FLOE_CBLAS_ROW_MAJOR
        ? (size_t)c_stored_rows * ldc
        : (size_t)c_stored_columns * ldc;
    a = calloc(a_count, sizeof(float));
    b = calloc(b_count, sizeof(float));
    c = calloc(c_count, sizeof(float));
    reference = calloc(c_count, sizeof(float));
    c_before = calloc(c_count, sizeof(float));
    CHECK(a && b && c && reference && c_before, "allocation");
    if (!a || !b || !c || !reference || !c_before) {
        free(a); free(b); free(c); free(reference); free(c_before);
        return;
    }
    fill(a, a_count, order == FLOE_CBLAS_ROW_MAJOR ? 1 : 2);
    fill(b, b_count, 3);
    fill(c, c_count, 5);
    memcpy(c_before, c, c_count * sizeof(float));
    if (order == FLOE_CBLAS_ROW_MAJOR) {
        for (row = 0; row < c_stored_rows; row++) {
            c[(size_t)row * ldc + (size_t)n] = 1234.5f;
            c_before[(size_t)row * ldc + (size_t)n] = 1234.5f;
        }
    } else {
        for (column = 0; column < c_stored_columns; column++) {
            c[(size_t)m + (size_t)column * ldc] = 1234.5f;
            c_before[(size_t)m + (size_t)column * ldc] = 1234.5f;
        }
    }
    reference_gemm(order, transa, transb, m, n, k, alpha, a, lda, b, ldb, beta,
                   c_before, reference, ldc,
                   order == FLOE_CBLAS_ROW_MAJOR ? ldc : 1,
                   order == FLOE_CBLAS_ROW_MAJOR ? 1 : ldc);
    cblas_sgemm(order, transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c,
                ldc);
    snprintf(label, sizeof label,
             "gemm order=%d ta=%d tb=%d m=%d n=%d k=%d", order, transa, transb,
             m, n, k);
    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            size_t index = (size_t)row * (order == FLOE_CBLAS_ROW_MAJOR ? ldc : 1)
                + (size_t)column * (order == FLOE_CBLAS_ROW_MAJOR ? 1 : ldc);
            float expected = reference[index];
            float actual = c[index];
            float difference = fabsf(expected - actual);
            CHECK(difference <= 2e-5f, label);
        }
        if (order == FLOE_CBLAS_ROW_MAJOR)
            CHECK(c[(size_t)row * ldc + (size_t)n] == 1234.5f,
                  "GEMM must not clobber C padding");
    }
    if (order == FLOE_CBLAS_COL_MAJOR) {
        for (column = 0; column < c_stored_columns; column++)
            CHECK(c[(size_t)m + (size_t)column * ldc] == 1234.5f,
                  "GEMM must not clobber column-major C padding");
    }
    free(a); free(b); free(c); free(reference); free(c_before);
}

static void test_invalid_and_edges(void)
{
    float a[64];
    float b[64];
    float c[64];
    float sentinel[16];
    int index;
    fill(a, 64, 7);
    fill(b, 64, 9);
    fill(c, 64, 11);
    for (index = 0; index < 16; index++) sentinel[index] = 777.0f + (float)index;

    memcpy(c, sentinel, sizeof sentinel);
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, 4, 4, 4, 1.0f, a, 1, b, 4, 0.0f, c, 4);
    for (index = 0; index < 16; index++)
        CHECK(c[index] == sentinel[index],
              "invalid lda must not overwrite C");
    memset(c, 0, sizeof c);
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, 0, 4, 4, 1.0f, a, 4, b, 4, 1.0f, c, 4);
    for (index = 0; index < 16; index++)
        CHECK(c[index] == 0.0f, "zero m must not write C");
    memcpy(c, sentinel, sizeof sentinel);
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, 4, 4, 0, 1.0f, a, 4, b, 4, 0.5f, c, 4);
    for (index = 0; index < 16; index++)
        CHECK(fabsf(c[index] - sentinel[index] * 0.5f) < 1e-6f,
              "k=0 must apply beta*C");

    {
        char transa = 'X';
        char transb = 'N';
        int m = 4;
        int n = 4;
        int k = 4;
        float alpha = 1.0f;
        float beta = 0.0f;
        int lda = 4;
        int ldb = 4;
        int ldc = 4;
        memcpy(c, sentinel, sizeof c);
        sgemm_(&transa, &transb, &m, &n, &k, &alpha, a, &lda, b, &ldb, &beta,
               c, &ldc);
        for (index = 0; index < 16; index++)
            CHECK(c[index] == sentinel[index], "bad Fortran transpose must not write C");
    }
}

static void test_alias(void)
{
    const int n = 24;
    float *a = calloc((size_t)n * n, sizeof(float));
    float *b = calloc((size_t)n * n, sizeof(float));
    float *c = calloc((size_t)n * n, sizeof(float));
    float *expected = calloc((size_t)n * n, sizeof(float));
    int row;
    int column;
    int inner;
    CHECK(a && b && c && expected, "alias allocation");
    if (!a || !b || !c || !expected) {
        free(a); free(b); free(c); free(expected);
        return;
    }
    fill(a, (size_t)n * n, 13);
    fill(b, (size_t)n * n, 17);
    memcpy(c, a, (size_t)n * n * sizeof(float));
    for (row = 0; row < n; row++) {
        for (column = 0; column < n; column++) {
            float sum = 0.0f;
            for (inner = 0; inner < n; inner++)
                sum += a[(size_t)row * n + inner] *
                       b[(size_t)inner * n + column];
            expected[(size_t)row * n + column] =
                0.75f * sum + 0.5f * a[(size_t)row * n + column];
        }
    }
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, n, n, n, 0.75f, c, n, b, n, 0.5f, c, n);
    for (row = 0; row < n; row++) {
        for (column = 0; column < n; column++) {
            size_t index = (size_t)row * n + column;
            CHECK(fabsf(c[index] - expected[index]) <= 2e-5f,
                  "in-place/alias GEMM");
        }
    }
    free(a); free(b); free(c); free(expected);
}

static void test_fortran_gemm(void)
{
    const int m = 3;
    const int n = 4;
    const int k = 5;
    char transa = 'N';
    char transb = 'T';
    int lda = m + 1;
    int ldb = n + 1;
    int ldc = m + 1;
    float alpha = 0.5f;
    float beta = -0.25f;
    float *a = calloc((size_t)lda * k, sizeof(float));
    float *b = calloc((size_t)ldb * k, sizeof(float));
    float *c = calloc((size_t)ldc * n, sizeof(float));
    float *expected = calloc((size_t)ldc * n, sizeof(float));
    int row;
    int column;
    int inner;
    CHECK(a && b && c && expected, "fortran allocation");
    if (!a || !b || !c || !expected) {
        free(a); free(b); free(c); free(expected);
        return;
    }
    fill(a, (size_t)lda * k, 19);
    fill(b, (size_t)ldb * k, 23);
    fill(c, (size_t)ldc * n, 29);
    memcpy(expected, c, (size_t)ldc * n * sizeof(float));
    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            float sum = 0.0f;
            for (inner = 0; inner < k; inner++)
                sum += a[(size_t)row + (size_t)inner * lda] *
                       b[(size_t)column + (size_t)inner * ldb];
            expected[(size_t)row + (size_t)column * ldc] =
                alpha * sum +
                beta * c[(size_t)row + (size_t)column * ldc];
        }
    }
    sgemm_(&transa, &transb, &m, &n, &k, &alpha, a, &lda, b, &ldb, &beta, c,
           &ldc);
    for (row = 0; row < m; row++) {
        for (column = 0; column < n; column++) {
            size_t index = (size_t)row + (size_t)column * ldc;
            CHECK(fabsf(c[index] - expected[index]) <= 2e-5f, "Fortran sgemm_");
        }
    }
    free(a); free(b); free(c); free(expected);
}

static void test_gemv_case(int order, int trans, int m, int n, float alpha,
                           float beta, int incx, int incy)
{
    int lda = order == FLOE_CBLAS_ROW_MAJOR ? n + 2 : m + 2;
    int x_length = trans ? m : n;
    int y_length = trans ? n : m;
    size_t x_span = (size_t)(x_length - 1) * (size_t)(incx < 0 ? -incx : incx) + 1;
    size_t y_span = (size_t)(y_length - 1) * (size_t)(incy < 0 ? -incy : incy) + 1;
    float *a = calloc(order == FLOE_CBLAS_ROW_MAJOR
                          ? (size_t)m * lda : (size_t)n * lda,
                      sizeof(float));
    float *x = calloc(x_span, sizeof(float));
    float *y = calloc(y_span, sizeof(float));
    float *reference = calloc(y_span, sizeof(float));
    int index;
    int inner;
    CHECK(a && x && y && reference, "gemv allocation");
    if (!a || !x || !y || !reference) {
        free(a); free(x); free(y); free(reference);
        return;
    }
    fill(a, order == FLOE_CBLAS_ROW_MAJOR ? (size_t)m * lda
                                         : (size_t)n * lda, 31);
    fill(x, x_span, 37);
    fill(y, y_span, 41);
    memcpy(reference, y, y_span * sizeof(float));
    for (index = 0; index < y_length; index++) {
        float sum = 0.0f;
        for (inner = 0; inner < (trans ? m : n); inner++) {
            float matrix_value;
            int matrix_row = trans ? inner : index;
            int matrix_column = trans ? index : inner;
            if (order == FLOE_CBLAS_ROW_MAJOR)
                matrix_value = a[(size_t)matrix_row * lda + matrix_column];
            else
                matrix_value = a[(size_t)matrix_row + (size_t)matrix_column * lda];
            {
                size_t x_index = incx > 0
                    ? (size_t)inner * (size_t)incx
                    : (size_t)(x_length - 1 - inner) * (size_t)(-incx);
                sum += matrix_value * x[x_index];
            }
        }
        {
            size_t y_index = incy > 0
                ? (size_t)index * (size_t)incy
                : (size_t)(y_length - 1 - index) * (size_t)(-incy);
            reference[y_index] = alpha * sum + beta * reference[y_index];
        }
    }
    cblas_sgemv(order, trans ? FLOE_CBLAS_TRANS : FLOE_CBLAS_NO_TRANS, m, n,
                alpha, a, lda, x, incx, beta, y, incy);
    for (index = 0; index < y_length; index++) {
        size_t y_index = incy > 0
            ? (size_t)index * (size_t)incy
            : (size_t)(y_length - 1 - index) * (size_t)(-incy);
        CHECK(fabsf(y[y_index] - reference[y_index]) <= 2e-5f, "cblas_sgemv");
    }
    free(a); free(x); free(y); free(reference);
}

static void *gemm_thread(void *argument)
{
    const int n = 8;
    float a[64];
    float b[64];
    float c[64];
    float reference[64];
    int row;
    int column;
    int inner;
    int iteration;
    (void)argument;
    for (iteration = 0; iteration < 12; iteration++) {
        fill(a, 64, iteration + 1);
        fill(b, 64, iteration + 2);
        memset(c, 0, sizeof c);
        reference_gemm(FLOE_CBLAS_ROW_MAJOR, 0, 0, n, n, n, 1.0f, a, n, b, n,
                       0.0f, c, n, n, 1);
        cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                    FLOE_CBLAS_NO_TRANS, n, n, n, 1.0f, a, n, b, n, 0.0f, c,
                    n);
        for (row = 0; row < n; row++) {
            for (column = 0; column < n; column++) {
                size_t index = (size_t)row * n + column;
                if (fabsf(c[index] - reference[index]) > 2e-5f)
                    __atomic_add_fetch(&failures, 1, __ATOMIC_RELAXED);
            }
        }
    }
    return NULL;
}

static int test_threads(void)
{
    pthread_t threads[4];
    int index;
    for (index = 0; index < 4; index++)
        CHECK(pthread_create(&threads[index], NULL, gemm_thread, NULL) == 0,
              "pthread_create");
    for (index = 0; index < 4; index++)
        CHECK(pthread_join(threads[index], NULL) == 0, "pthread_join");
    return failures == 0 ? 0 : 1;
}

static int test_gpu_counter(void)
{
    const uint32_t n = 512;
    const size_t count = (size_t)n * n;
    float *a;
    float *b;
    float *c;
    float *reference;
    uint32_t row;
    uint32_t column;
    uint32_t inner;
    uint64_t mismatches = 0;
    float maximum_error = 0.0f;
    floe_blas_stats stats;
    if (floe_blas_warmup() != 0) {
        printf("SKIP gpu counter: no Venus device (CPU fallback remains valid)\n");
        return 77;
    }
    a = malloc(count * sizeof(float));
    b = malloc(count * sizeof(float));
    c = malloc(count * sizeof(float));
    reference = calloc(count, sizeof(float));
    CHECK(a && b && c && reference, "GPU counter allocation");
    if (!a || !b || !c || !reference) {
        free(a); free(b); free(c); free(reference);
        return 1;
    }
    for (row = 0; row < n; row++) {
        for (column = 0; column < n; column++) {
            size_t index = (size_t)row * n + column;
            a[index] = (float)((int)((row * 3u + column * 5u) % 17u) - 8) / 8.0f;
            b[index] = (float)((int)((row * 7u + column * 11u) % 19u) - 9) / 8.0f;
        }
    }
    for (row = 0; row < n; row++) {
        for (inner = 0; inner < n; inner++) {
            float value = a[(size_t)row * n + inner];
            for (column = 0; column < n; column++)
                reference[(size_t)row * n + column] +=
                    value * b[(size_t)inner * n + column];
        }
    }
    CHECK(floe_blas_policy_set("on") == 0, "policy on");
    CHECK(floe_blas_stats_reset() == 0, "stats reset");
    memset(c, 0, count * sizeof(float));
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, (int)n, (int)n, (int)n, 1.0f, a, (int)n,
                b, (int)n, 0.0f, c, (int)n);
    memset(&stats, 0, sizeof stats);
    stats.struct_size = sizeof stats;
    CHECK(floe_blas_stats_get(&stats) == 0, "stats get");
    for (row = 0; row < n; row++) {
        for (column = 0; column < n; column++) {
            size_t index = (size_t)row * n + column;
            float difference = fabsf(c[index] - reference[index]);
            if (difference > maximum_error) maximum_error = difference;
            if (difference != 0.0f) mismatches++;
        }
    }
    CHECK(maximum_error <= 1e-4f, "GPU GEMM output exceeds numerical tolerance");
    CHECK(stats.gpu_submitted >= 1, "gpu_submitted must count a real queue submit");
    CHECK(stats.gpu_completed >= 1, "gpu_completed must count accepted work");
    CHECK(stats.gpu_dispatches >= 1, "gpu_dispatches must count a real dispatch");
    printf("GPU counter: submitted=%llu completed=%llu dispatches=%llu "
           "mismatches=%llu maxError=%g device=%s\n",
           (unsigned long long)stats.gpu_submitted,
           (unsigned long long)stats.gpu_completed,
           (unsigned long long)stats.gpu_dispatches,
           (unsigned long long)mismatches, maximum_error, stats.device_name);
    free(a); free(b); free(c); free(reference);
    return failures == 0 ? 0 : 1;
}

int main(void)
{
    int gpu = 0;
    printf("floe-blas provider ABI tests (source-only build; runtime not yet run)\n");
    test_gemm_case(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                   FLOE_CBLAS_NO_TRANS, 3, 4, 5, 0.75f, -0.5f);
    test_gemm_case(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_TRANS,
                   FLOE_CBLAS_NO_TRANS, 4, 3, 5, 1.0f, 0.25f);
    test_gemm_case(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                   FLOE_CBLAS_TRANS, 3, 4, 5, -0.5f, 0.0f);
    test_gemm_case(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_TRANS,
                   FLOE_CBLAS_TRANS, 4, 3, 5, 0.5f, 0.75f);
    test_gemm_case(FLOE_CBLAS_COL_MAJOR, FLOE_CBLAS_NO_TRANS,
                   FLOE_CBLAS_NO_TRANS, 3, 4, 5, 0.75f, -0.5f);
    test_gemm_case(FLOE_CBLAS_COL_MAJOR, FLOE_CBLAS_TRANS,
                   FLOE_CBLAS_NO_TRANS, 4, 3, 5, 1.0f, 0.25f);
    test_gemm_case(FLOE_CBLAS_COL_MAJOR, FLOE_CBLAS_NO_TRANS,
                   FLOE_CBLAS_TRANS, 3, 4, 5, -0.5f, 0.0f);
    test_gemm_case(FLOE_CBLAS_COL_MAJOR, FLOE_CBLAS_TRANS,
                   FLOE_CBLAS_TRANS, 4, 3, 5, 0.5f, 0.75f);
    test_invalid_and_edges();
    test_alias();
    test_fortran_gemm();
    test_gemv_case(FLOE_CBLAS_ROW_MAJOR, 0, 5, 4, 0.75f, -0.5f, 1, 1);
    test_gemv_case(FLOE_CBLAS_ROW_MAJOR, 1, 5, 4, 1.0f, 0.25f, -2, 2);
    test_gemv_case(FLOE_CBLAS_COL_MAJOR, 0, 5, 4, 0.75f, -0.5f, 2, -1);
    test_gemv_case(FLOE_CBLAS_COL_MAJOR, 1, 5, 4, 1.0f, 0.25f, -1, 2);
    (void)test_threads();
    gpu = test_gpu_counter();
    printf("checks=%d failures=%d\n", checks, failures);
    if (failures != 0) return 1;
    return gpu == 77 ? 77 : 0;
}

/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Explicit diagnostic entry for the Floe guest BLAS provider.
 *
 *   floe-blas-probe --size 512          real GPU GEMM + CPU reference
 *   floe-blas-probe --activation-json   read-only activation facts
 *
 * The probe links the provider directly, so its counters describe this
 * process.  It never treats a CPU reference result as a GPU pass.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "floe_blas.h"
#include "floe_blas_activate.h"
#include "floe_blas_cblas.h"
#include "floe_blas_policy.h"

static const char *policy_text(int policy)
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

static void json_string(const char *value)
{
    const unsigned char *cursor = (const unsigned char *)(value != NULL ? value : "");
    putchar('"');
    while (*cursor != '\0') {
        switch (*cursor) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*cursor < 0x20) printf("\\u%04x", *cursor);
            else putchar(*cursor);
            break;
        }
        cursor++;
    }
    putchar('"');
}

static uint64_t monotonic_ns(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static void fill_inputs(float *a, float *b, size_t count, uint32_t size)
{
    uint32_t row;
    (void)count;
    uint32_t column;
    for (row = 0; row < size; row++) {
        for (column = 0; column < size; column++) {
            size_t index = (size_t)row * size + column;
            a[index] = (float)((int)((row * 3u + column * 5u) % 17u) - 8) / 8.0f;
            b[index] = (float)((int)((row * 7u + column * 11u) % 19u) - 9) / 8.0f;
        }
    }
}

static void reference_gemm(const float *a, const float *b, float *reference,
                           uint32_t size)
{
    uint32_t row;
    uint32_t inner;
    uint32_t column;
    memset(reference, 0, (size_t)size * size * sizeof(float));
    for (row = 0; row < size; row++) {
        for (inner = 0; inner < size; inner++) {
            float value = a[(size_t)row * size + inner];
            for (column = 0; column < size; column++)
                reference[(size_t)row * size + column] +=
                    value * b[(size_t)inner * size + column];
        }
    }
}

static int activation_json(void)
{
    floe_blas_activation_probe probe;
    if (floe_blas_activation_inspect(&probe) != 0) {
        printf("{\"ok\":false,\"error\":\"inspect-failed\"}\n");
        return 2;
    }
    printf("{\"ok\":true,\"guest\":%s,\"library\":\"%s\","
           "\"libraryPresent\":%s,\"libraryTrusted\":%s,"
           "\"gpuNode\":\"%s\",\"gpuNodePresent\":%s,\"icd\":\"%s\","
           "\"icdPresent\":%s,\"mode\":\"%s\",\"modeSource\":%d,"
           "\"wouldActivate\":%s,\"reason\":\"%s\",\"configPath\":",
           probe.guest ? "true" : "false", FLOE_BLAS_LIBRARY_PATH,
           probe.library_present ? "true" : "false",
           probe.library_trusted ? "true" : "false", FLOE_BLAS_RENDER_NODE,
           probe.gpu_node_present ? "true" : "false", FLOE_BLAS_ICD_PATH,
           probe.icd_present ? "true" : "false", policy_text(probe.mode),
           probe.mode_source, probe.would_activate ? "true" : "false",
           probe.reason);
    json_string(probe.config_path);
    printf("}\n");
    return 0;
}

static int run_probe(uint32_t size)
{
    const size_t count = (size_t)size * size;
    const size_t bytes = count * sizeof(float);
    float *a;
    float *b;
    float *c;
    float *reference;
    uint64_t start;
    uint64_t elapsed;
    uint64_t reference_ns;
    float maximum_error = 0.0f;
    float maximum_reference = 0.0f;
    uint64_t mismatches = 0;
    size_t index;
    floe_blas_stats stats;
    int warmup;
    int status;

    if (size == 0 || size > 2048) {
        fprintf(stderr, "floe-blas-probe: --size must be 1..2048\n");
        return 2;
    }
    a = malloc(bytes);
    b = malloc(bytes);
    c = malloc(bytes);
    reference = malloc(bytes);
    if (a == NULL || b == NULL || c == NULL || reference == NULL) {
        fprintf(stderr, "floe-blas-probe: allocation failed\n");
        free(a);
        free(b);
        free(c);
        free(reference);
        return 2;
    }
    fill_inputs(a, b, count, size);
    start = monotonic_ns();
    reference_gemm(a, b, reference, size);
    reference_ns = monotonic_ns() - start;

    if (floe_blas_policy_set("on") != 0) {
        fprintf(stderr, "floe-blas-probe: policy rejected\n");
        free(a); free(b); free(c); free(reference);
        return 2;
    }
    warmup = floe_blas_warmup();
    if (warmup != 0) {
        floe_blas_activation_probe activation;
        (void)floe_blas_activation_inspect(&activation);
        printf("{\"ok\":false,\"kind\":\"floe-blas-probe\",\"size\":%u,"
               "\"error\":\"gpu-unavailable\",\"reason\":\"%s\","
               "\"device\":\"\",\"note\":\"No GPU result was produced; "
               "BLAS remains on the original CPU provider.\"}\n",
               size, activation.reason);
        free(a); free(b); free(c); free(reference);
        return 3;
    }
    memset(c, 0, bytes);
    (void)floe_blas_stats_reset();
    start = monotonic_ns();
    cblas_sgemm(FLOE_CBLAS_ROW_MAJOR, FLOE_CBLAS_NO_TRANS,
                FLOE_CBLAS_NO_TRANS, (int)size, (int)size, (int)size, 1.0f,
                a, (int)size, b, (int)size, 0.0f, c, (int)size);
    elapsed = monotonic_ns() - start;

    for (index = 0; index < count; index++) {
        float difference = fabsf(c[index] - reference[index]);
        if (difference > maximum_error) maximum_error = difference;
        if (fabsf(reference[index]) > maximum_reference)
            maximum_reference = fabsf(reference[index]);
        if (c[index] != reference[index]) mismatches++;
    }
    memset(&stats, 0, sizeof stats);
    stats.struct_size = sizeof stats;
    status = floe_blas_stats_get(&stats);
    printf("{\"ok\":%s,\"kind\":\"floe-blas-probe\",\"size\":%u,"
           "\"device\":", (status == 0 && stats.gpu_completed > 0 &&
                            stats.gpu_submitted > 0 &&
                            maximum_error <= 1e-4f * (maximum_reference > 1.0f
                                                      ? maximum_reference : 1.0f))
                              ? "true" : "false", size);
    json_string(stats.device_name);
    printf(",\"policy\":\"%s\",\"elapsedNs\":%llu,\"cpuReferenceNs\":%llu,"
           "\"maxAbsError\":%.9g,\"mismatches\":%llu,"
           "\"gpuSubmitted\":%llu,\"gpuCompleted\":%llu,"
           "\"gpuFailed\":%llu,\"gpuDispatches\":%llu,"
           "\"fallbackCpu\":%llu,\"fallbackReference\":%llu,"
           "\"gpuPresent\":%s,\"note\":\"This probe measures one explicit "
           "GEMM, not NumPy or OpenBLAS performance.\"}\n",
           policy_text((int)stats.policy), (unsigned long long)elapsed,
           (unsigned long long)reference_ns, maximum_error,
           (unsigned long long)mismatches,
           (unsigned long long)stats.gpu_submitted,
           (unsigned long long)stats.gpu_completed,
           (unsigned long long)stats.gpu_failed,
           (unsigned long long)stats.gpu_dispatches,
           (unsigned long long)stats.fallback_cpu,
           (unsigned long long)stats.fallback_reference,
           stats.gpu_present ? "true" : "false");

    status = (status == 0 && stats.gpu_completed > 0 &&
              stats.gpu_submitted > 0 &&
              maximum_error <= 1e-4f * (maximum_reference > 1.0f
                                        ? maximum_reference : 1.0f)) ? 0 : 1;
    free(a);
    free(b);
    free(c);
    free(reference);
    return status;
}

static void usage(void)
{
    printf("usage: floe-blas-probe [--size N] [--activation-json]\n"
           "  --size N            run one real float32 row-major GEMM (default 512)\n"
           "  --activation-json   print guest/library/GPU activation facts only\n");
}

int main(int argc, char **argv)
{
    uint32_t size = 512;
    int index;
    for (index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--help") == 0 || strcmp(argv[index], "-h") == 0) {
            usage();
            return 0;
        }
        if (strcmp(argv[index], "--activation-json") == 0)
            return activation_json();
        if (strcmp(argv[index], "--size") == 0) {
            char *end = NULL;
            unsigned long parsed;
            if (index + 1 >= argc) {
                fprintf(stderr, "floe-blas-probe: --size needs a value\n");
                return 2;
            }
            errno = 0;
            parsed = strtoul(argv[++index], &end, 10);
            if (errno != 0 || end == argv[index] || *end != '\0' ||
                parsed == 0 || parsed > 2048) {
                fprintf(stderr, "floe-blas-probe: invalid --size\n");
                return 2;
            }
            size = (uint32_t)parsed;
            continue;
        }
        fprintf(stderr, "floe-blas-probe: unknown argument: %s\n", argv[index]);
        return 2;
    }
    return run_probe(size);
}

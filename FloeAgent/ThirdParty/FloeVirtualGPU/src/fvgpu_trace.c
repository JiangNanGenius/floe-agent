/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_trace.c — bounded opt-in tracing. See fvgpu_trace.h for the contract. */
#include "fvgpu_trace.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static pthread_once_t trace_once = PTHREAD_ONCE_INIT;
static int trace_enabled;
static unsigned trace_limit;
static _Atomic unsigned trace_events;

static unsigned parse_limit(const char *value) {
    if (!value || !*value)
        return 4096u;
    char *end = NULL;
    unsigned long n = strtoul(value, &end, 10);
    if (end == value || (end && *end) || n < 16ul)
        return 4096u;
    return n > 65536ul ? 65536u : (unsigned)n;
}

static void trace_init(void) {
    const char *mode = getenv("FLOE_GPU_TRACE");
    trace_enabled = mode && *mode && strcmp(mode, "0") != 0;
    trace_limit = parse_limit(getenv("FLOE_GPU_TRACE_LIMIT"));
}

int fvgpu_trace_enabled(void) {
    pthread_once(&trace_once, trace_init);
    return trace_enabled;
}

void fvgpu_trace(const char *fmt, ...) {
    if (!fvgpu_trace_enabled())
        return;
    unsigned n = atomic_fetch_add_explicit(&trace_events, 1u, memory_order_relaxed);
    if (n >= trace_limit) {
        if (n == trace_limit) {
            flockfile(stderr);
            fprintf(stderr, "fvgpu:trace status=disabled events=%u limit=%u\n",
                    n, trace_limit);
            funlockfile(stderr);
        }
        return;
    }
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    flockfile(stderr);
    fprintf(stderr, "fvgpu:trace t=%llu ",
            (unsigned long long)ts.tv_sec * 1000ull +
                (unsigned long long)(ts.tv_nsec / 1000000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    funlockfile(stderr);
}

/*
 * smp_bench.c — TinyEMU SMP store-path / interpreter benchmark host.
 *
 * This is a MEASUREMENT tool, not a pass/fail gate. It runs the
 * gen_smp_payload.py bare-metal payloads through the public adapter and
 * reports wall-clock medians for equal total work:
 *
 *   store_work_single.bin  one hart, 2*STORE_ITERS store iterations
 *   store_diff_dual.bin    two harts, STORE_ITERS each, own cache line
 *   store_same_dual.bin    two harts, STORE_ITERS each, same cache line
 *   perf_single.bin        pure-ALU interpreter baseline, one hart
 *   perf_dual.bin          pure-ALU interpreter baseline, two harts
 *
 * The store payloads exist because the pure-ALU perf pair cannot see the
 * machine-wide guest-RAM store lock: their loop body has no stores. The
 * equal-work wall ratio single/dual is the store-path scaling metric.
 *
 * Usage: run from the directory holding the payloads
 *   ./smp_bench [--trials N] [--json OUT]
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "floe_vm.h"

typedef struct {
    FloeVM *vm;
    char *sink;
    size_t sink_len, sink_cap;
} BenchVM;

static void sink_out(void *opaque, const uint8_t *data, int len)
{
    BenchVM *b = opaque;
    size_t n = (size_t)(len > 0 ? len : 0);
    if (n > b->sink_cap - b->sink_len)
        n = b->sink_cap - b->sink_len;
    memcpy(b->sink + b->sink_len, data, n);
    b->sink_len += n;
    b->sink[b->sink_len] = '\0';
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Returns wall ms, or -1 when the VM could not be created. */
static int64_t run_payload(const char *path, int vcpu, uint64_t *insns_out)
{
    FloeVMConfig cfg;
    BenchVM b;
    memset(&cfg, 0, sizeof(cfg));
    memset(&b, 0, sizeof(b));
    cfg.ram_mb = 128;
    cfg.bios_path = path;
    cfg.vcpu_count = vcpu;

    b.sink = calloc(1, 1 << 16);
    b.sink_cap = (1 << 16) - 1;
    if (!b.sink)
        return -1;

    int64_t t0 = now_ms();
    FloeVM *vm = floe_vm_create(&cfg, sink_out, &b);
    if (!vm) {
        free(b.sink);
        return -1;
    }
    int rc = 0;
    for (int slices = 0; slices < 20000000; slices++) {
        rc = floe_vm_run_slice(vm, 10);
        if (rc != 0)
            break;
    }
    int64_t wall = now_ms() - t0;
    FloeVMStats st;
    memset(&st, 0, sizeof(st));
    floe_vm_get_stats(vm, &st);
    if (insns_out)
        *insns_out = st.hart_insns[0] + st.hart_insns[1];
    floe_vm_destroy(vm);
    free(b.sink);
    return wall;
}

static int cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

typedef struct {
    const char *name;
    const char *payload;
    int vcpu;
    int64_t wall[9];
    uint64_t insns;
    int64_t median;
} BenchCase;

int main(int argc, char **argv)
{
    int trials = 3;
    const char *json_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--trials") && i + 1 < argc)
            trials = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--json") && i + 1 < argc)
            json_path = argv[++i];
    }
    if (trials < 1 || trials > 9)
        trials = 3;

    BenchCase cases[] = {
        { "perf_single", "perf_single.bin", 1, {0}, 0, 0 },
        { "perf_dual", "perf_dual.bin", 2, {0}, 0, 0 },
        { "store_single", "store_work_single.bin", 1, {0}, 0, 0 },
        { "store_diff_dual", "store_diff_dual.bin", 2, {0}, 0, 0 },
        { "store_same_dual", "store_same_dual.bin", 2, {0}, 0, 0 },
        { "store_idle_dual", "store_idle_dual.bin", 2, {0}, 0, 0 },
    };
    const int ncases = (int)(sizeof(cases) / sizeof(cases[0]));

    for (int c = 0; c < ncases; c++) {
        for (int t = 0; t < trials; t++) {
            int64_t w = run_payload(cases[c].payload, cases[c].vcpu,
                                    &cases[c].insns);
            if (w < 0) {
                fprintf(stderr, "smp_bench: create failed for %s\n",
                        cases[c].payload);
                return 2;
            }
            cases[c].wall[t] = w;
        }
        qsort(cases[c].wall, trials, sizeof(int64_t), cmp_i64);
        cases[c].median = cases[c].wall[trials / 2];
        printf("%-16s vcpu=%d trials=%d walls_ms=[", cases[c].name,
               cases[c].vcpu, trials);
        for (int t = 0; t < trials; t++)
            printf("%s%" PRId64, t ? "," : "", cases[c].wall[t]);
        printf("] median_ms=%" PRId64 " insns=%" PRIu64 "\n",
               cases[c].median, cases[c].insns);
        fflush(stdout);
    }

    int64_t perf_s = 0, perf_d = 0, st_s = 0, st_d = 0, st_same = 0;
    int64_t st_idle = 0;
    for (int c = 0; c < ncases; c++) {
        if (!strcmp(cases[c].name, "perf_single")) perf_s = cases[c].median;
        if (!strcmp(cases[c].name, "perf_dual")) perf_d = cases[c].median;
        if (!strcmp(cases[c].name, "store_single")) st_s = cases[c].median;
        if (!strcmp(cases[c].name, "store_diff_dual")) st_d = cases[c].median;
        if (!strcmp(cases[c].name, "store_same_dual")) st_same = cases[c].median;
        if (!strcmp(cases[c].name, "store_idle_dual")) st_idle = cases[c].median;
    }

    printf("\nALU interpreter speedup (single/dual over equal work): %.3fx\n",
           perf_d ? (double)perf_s / (double)perf_d : 0.0);
    printf("store diff-line speedup (single/dual equal work): %.3fx\n",
           st_d ? (double)st_s / (double)st_d : 0.0);
    printf("store same-line speedup (single/dual equal work): %.3fx\n",
           st_same ? (double)st_s / (double)st_same : 0.0);
    printf("store one-active-hart 2-vcpu overhead (single/dual equal work): "
           "%.3fx\n", st_idle ? (double)st_s / (double)st_idle : 0.0);

    if (json_path) {
        FILE *f = fopen(json_path, "w");
        if (f) {
            fprintf(f, "{\n  \"trials\": %d,\n  \"cases\": [\n", trials);
            for (int c = 0; c < ncases; c++) {
                fprintf(f,
                        "    {\"name\": \"%s\", \"vcpu\": %d, "
                        "\"median_ms\": %" PRId64 ", \"insns\": %" PRIu64
                        ", \"walls_ms\": [",
                        cases[c].name, cases[c].vcpu, cases[c].median,
                        cases[c].insns);
                for (int t = 0; t < trials; t++)
                    fprintf(f, "%s%" PRId64, t ? ", " : "", cases[c].wall[t]);
                fprintf(f, "]%s\n", c + 1 < ncases ? "," : "");
            }
            fprintf(f,
                    "  ],\n  \"speedup_alu\": %g,\n"
                    "  \"speedup_store_diff\": %g,\n"
                    "  \"speedup_store_same\": %g,\n"
                    "  \"speedup_store_idle_2vcpu\": %g\n}\n",
                    perf_d ? (double)perf_s / perf_d : 0.0,
                    st_d ? (double)st_s / st_d : 0.0,
                    st_same ? (double)st_s / st_same : 0.0,
                    st_idle ? (double)st_s / st_idle : 0.0);
            fclose(f);
        }
    }
    return 0;
}

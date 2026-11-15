/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* FVGpuBudgetTests.c — deterministic contract test for the production
 * FloeVirtualGPU budget and split-ledger implementation.
 *
 * Verifies:
 *   - lowering the budget never reclaims live resources;
 *   - admission denies new allocations against the pending lower target while
 *     the report keeps actual = live occupancy;
 *   - the pending target converges only after real releases, never on a timer;
 *   - a release larger than the charged counter is refused, recorded as a
 *     persistent ledger fault and blocks every later admission (assert builds
 *     abort at the same point; this fixture compiles the module with NDEBUG so
 *     the assertion-free path is exercised);
 *   - aliased guest imports are reported separately and never charged.
 *
 * Build with -DNDEBUG for the production assertion-free path. The fixture's
 * own REQUIRE checks stay active. The shm backing test covers the HOST3D
 * export-length guard added for a guest blob longer than its real backing.
 * No renderer, GPU, VM or device is opened. */
#include "fvgpu_priv.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Not exercised here; the real implementation lives in fvgpu_session.c. */
int floe_gpu_ctx_destroy(FloeGPUSession *s, uint32_t id) { (void)s; (void)id; return 0; }

#define REQUIRE(x) do { \
    if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); abort(); } \
} while (0)

#define MIB (1024ull * 1024ull)

static FloeGPUSession *make_session(void) {
    FloeGPUSession *s = calloc(1, sizeof(*s));
    REQUIRE(s != NULL);
    fvgpu_ledger_init(s);
    s->budget.limit_bytes = s->budget.requested_bytes = s->budget.target_bytes = 1024ull * MIB;
    s->capacity_max_bytes = 2ull * 1024ull * MIB;
    return s;
}

static void destroy_session(FloeGPUSession *s) {
    fvgpu_ledger_fini(s);
    free(s);
}

/* A blob commit: admission reservation then the accounting alloc event. */
static void charge_blob(FloeGPUSession *s, uint64_t bytes) {
    REQUIRE(fvgpu_ledger_reserve(s, bytes, false));
    fvgpu_ledger_event(s, bytes, false, true, true, 1);
}

static void test_normal_budget(void) {
    FloeGPUSession *s = make_session();
    FloeGPUBudgetResult r;

    charge_blob(s, 256 * MIB);
    REQUIRE(fvgpu_ledger_live(s) == 256 * MIB);

    /* Lower below live: recorded, reported, but nothing reclaimed. */
    r = fvgpu_budget_set(s, 64 * MIB);
    REQUIRE(r.requested_bytes == 64 * MIB);
    REQUIRE(r.pending_target_bytes == 64 * MIB);
    REQUIRE(r.actual_limit_bytes == 256 * MIB);   /* occupied wins over target */
    REQUIRE(r.live_bytes == 256 * MIB);
    REQUIRE(strcmp(r.reason, "below-live-pending-release") == 0);
    REQUIRE(fvgpu_ledger_live(s) == 256 * MIB);

    /* New admission is refused against the pending 64 MiB target. */
    REQUIRE(!fvgpu_ledger_reserve(s, 1 * MIB, false));

    /* Real release of 200 MiB: pending converges only now. */
    fvgpu_ledger_event(s, 200 * MIB, false, true, false, 1);
    r = floe_gpu_get_budget(s);
    REQUIRE(r.live_bytes == 56 * MIB);
    REQUIRE(r.pending_target_bytes == 64 * MIB);
    REQUIRE(r.actual_limit_bytes == 64 * MIB);
    REQUIRE(s->budget.pending == false);

    /* 56 MiB live + 8 MiB fits; 16 MiB more does not. */
    REQUIRE(fvgpu_ledger_reserve(s, 8 * MIB, false));
    fvgpu_ledger_event(s, 8 * MIB, false, true, true, 2);
    REQUIRE(!fvgpu_ledger_reserve(s, 16 * MIB, false));
    REQUIRE(fvgpu_ledger_live(s) == 64 * MIB);

    /* Raising applies to new allocations and is reported honestly. */
    r = fvgpu_budget_set(s, 128 * MIB);
    REQUIRE(r.actual_limit_bytes == 128 * MIB);
    REQUIRE(r.live_bytes == 64 * MIB);
    REQUIRE(fvgpu_ledger_reserve(s, 16 * MIB, false));
    fvgpu_ledger_event(s, 16 * MIB, false, true, true, 3);
    REQUIRE(fvgpu_ledger_live(s) == 80 * MIB);

    /* Aliased guest memory is reported, never charged against the budget. */
    REQUIRE(fvgpu_ledger_reserve(s, 512 * MIB, true));
    fvgpu_ledger_event(s, 512 * MIB, true, false, true, 5);
    REQUIRE(s->ledger.aliased_guest_bytes == 512 * MIB);
    REQUIRE(fvgpu_ledger_live(s) == 80 * MIB);
    fvgpu_ledger_event(s, 512 * MIB, true, false, false, 5);
    REQUIRE(s->ledger.aliased_guest_bytes == 0);

    /* Release the remaining live bytes through the normal path. */
    fvgpu_ledger_event(s, 8 * MIB, false, true, false, 2);
    fvgpu_ledger_event(s, 16 * MIB, false, true, false, 3);
    fvgpu_ledger_event(s, 56 * MIB, false, true, false, 1);
    REQUIRE(fvgpu_ledger_live(s) == 0);
    REQUIRE(s->ledger.blob_bytes == 0);
    REQUIRE(s->ledger_faults == 0);
    REQUIRE(floe_gpu_ledger_faulted(s) == 0);
    destroy_session(s);
}

static void test_invariant_fault_fail_closed(void) {
    FloeGPUSession *s = make_session();
    FloeGPUBudgetResult r;

    charge_blob(s, 80 * MIB);
    REQUIRE(fvgpu_ledger_live(s) == 80 * MIB);

    /* A release beyond the charged total: assertion builds abort. In this
     * NDEBUG build the module must keep the charge, record a persistent fault
     * and refuse all later admissions, including aliased imports. */
    fvgpu_ledger_event(s, 1024 * MIB, false, true, false, 4);
    REQUIRE(fvgpu_ledger_live(s) == 80 * MIB);
    REQUIRE(s->ledger_faults == 1);
    REQUIRE(floe_gpu_ledger_faulted(s) == 1);
    REQUIRE(!fvgpu_ledger_reserve(s, 1 * MIB, false));
    REQUIRE(!fvgpu_ledger_reserve(s, 1 * MIB, true));

    r = floe_gpu_get_budget(s);
    REQUIRE(strcmp(r.reason, "ledger-invariant-fault") == 0);
    REQUIRE(r.live_bytes == 80 * MIB);

    /* Genuine releases still shrink the real charge; the fault stays set. */
    fvgpu_ledger_event(s, 80 * MIB, false, true, false, 1);
    REQUIRE(fvgpu_ledger_live(s) == 0);
    REQUIRE(s->ledger_faults == 1);
    destroy_session(s);
}

static void test_overflow_fail_closed(void) {
    FloeGPUSession *s = make_session();

    /* Aliased imports bypass the byte budget, so an overflowing alias counter
     * is reachable without first failing admission. The counter must not wrap,
     * the reservation is not counted, and all future admission is refused. */
    s->ledger.aliased_guest_bytes = UINT64_MAX - 8;
    REQUIRE(fvgpu_ledger_reserve(s, 16, true));
    fvgpu_ledger_event(s, 16, true, false, true, 9);
    REQUIRE(s->ledger.aliased_guest_bytes == UINT64_MAX - 8);
    REQUIRE(s->ledger_faults == 1);
    REQUIRE(floe_gpu_ledger_faulted(s) == 1);
    REQUIRE(!fvgpu_ledger_reserve(s, 1, false));
    REQUIRE(!fvgpu_ledger_reserve(s, 1, true));
    destroy_session(s);
}

static void test_shm_backing_length(void) {
    char path[] = "/tmp/floe-fvgpu-shm-XXXXXX";
    int fd = mkstemp(path);
    REQUIRE(fd >= 0);
    REQUIRE(unlink(path) == 0);
    REQUIRE(ftruncate(fd, 4096) == 0);
    REQUIRE(fvgpu_shm_fd_covers(fd, 1));
    REQUIRE(fvgpu_shm_fd_covers(fd, 4096));
    REQUIRE(!fvgpu_shm_fd_covers(fd, 4097));
    REQUIRE(!fvgpu_shm_fd_covers(-1, 1));
    REQUIRE(close(fd) == 0);

    /* mmap treats the partial last page as zero-filled, so a requested size
     * within the real file must pass even when it is not page-aligned. */
    char path2[] = "/tmp/floe-fvgpu-shm-XXXXXX";
    fd = mkstemp(path2);
    REQUIRE(fd >= 0);
    REQUIRE(unlink(path2) == 0);
    REQUIRE(ftruncate(fd, 1000) == 0);
    REQUIRE(fvgpu_shm_fd_covers(fd, 1000));
    REQUIRE(!fvgpu_shm_fd_covers(fd, 1001));
    REQUIRE(close(fd) == 0);
}

int main(int argc, char **argv) {
    const int normal_only = argc > 1 && strcmp(argv[1], "normal") == 0;
    const int fault_only = argc > 1 && strcmp(argv[1], "fault") == 0;
    if (!fault_only) {
        test_normal_budget();
        test_shm_backing_length();
    }
    if (!normal_only) {
        test_invariant_fault_fail_closed();
        test_overflow_fail_closed();
    }
    printf("FVGPU_BUDGET_FIXTURE PASS%s%s\n",
           normal_only ? " normal" : "", fault_only ? " fault" : "");
    return 0;
}

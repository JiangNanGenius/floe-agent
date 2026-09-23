/*
 * smp_host_test.c — Floe TinyEMU SMP (dual-hart) host tests.
 *
 * Runs the generated RISC-V M-mode payloads (gen_smp_payload.py) through
 * the embeddable adapter and checks, on the host:
 *
 *   1. capability query: max vCPUs and SMP capability flag
 *   2. dual-hart functional run (vcpu_count=2): both harts execute,
 *      AMO atomicity (400 == 2 x 200 concurrent amoadd.w), LR/SC
 *      atomicity (200 == 2 x 100 concurrent lr/sc), CLINT IPI + WFI wake,
 *      cross-hart code visibility, FDT with 2 CPU nodes, per-hart stats
 *   3. UP compatibility (vcpu_count=0 and 1): same payload prints UP-OK,
 *      FDT has exactly 1 CPU node
 *   4. stop/cancel: destroy a running 2-hart VM from another thread
 *      (joins hart threads before closing the disk)
 *   5. parallel performance: identical total ALU work, 2 harts vs 1 hart
 *
 * The FDT bytes arrive as a hex dump over the HTIF console and are parsed
 * here (no guest-side tooling needed).
 *
 * Build via the Makefile in this directory (links libfloevm.a).
 */

#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "floe_vm.h"

#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))

static int g_failures;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            g_failures++;                                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);               \
            fprintf(stderr, __VA_ARGS__);                                      \
            fprintf(stderr, "\n");                                             \
        }                                                                      \
    } while (0)

/* ------------------------------------------------------------------ */
/* console collector                                                    */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} ConsoleSink;

static void sink_out(void *opaque, const uint8_t *data, int len)
{
    ConsoleSink *s = opaque;
    if (len <= 0)
        return;
    size_t n = (size_t)len;
    if (n > s->cap - s->len)
        n = s->cap - s->len;
    memcpy(s->buf + s->len, data, n);
    s->len += n;
    s->buf[s->len] = '\0';
}

/* ------------------------------------------------------------------ */
/* VM run helper                                                        */

typedef struct {
    const char *bios_path;
    int vcpu_count;
    int max_slices;
    ConsoleSink sink;
    FloeVMStats stats;
    int rc;             /* 1 = poweroff, 0 = slices exhausted, <0 error */
    int64_t wall_ms;
} RunResult;

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void run_vm(RunResult *r)
{
    FloeVMConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb = 128;
    cfg.bios_path = r->bios_path;
    cfg.vcpu_count = r->vcpu_count;

    r->sink.buf = calloc(1, 1 << 20);
    r->sink.cap = (1 << 20) - 1;

    int64_t t0 = now_ms();
    FloeVM *vm = floe_vm_create(&cfg, sink_out, &r->sink);
    if (!vm) {
        r->rc = -1;
        return;
    }
    int rc = 0, slices = 0;
    while (slices < r->max_slices) {
        rc = floe_vm_run_slice(vm, 10);
        slices++;
        if (rc != 0)
            break;
    }
    r->wall_ms = now_ms() - t0;
    floe_vm_get_stats(vm, &r->stats);
    floe_vm_destroy(vm);
    r->rc = rc;
}

/* ------------------------------------------------------------------ */
/* FDT parsing (big-endian device tree, dumped as hex by the payload)   */

typedef struct {
    int cpu_nodes;
    uint32_t cpu_reg[8];
    int clint_irq_cells;   /* number of u32 cells in interrupts-extended */
    int plic_irq_cells;
} FdtInfo;

static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

/* Parse the FDT blob: count /cpus cpu nodes, read their reg, and the
 * clint/plic interrupts-extended cell counts. Returns 0 on success. */
static int fdt_parse(const uint8_t *dtb, size_t len, FdtInfo *info)
{
    memset(info, 0, sizeof(*info));
    if (len < 40 || be32(dtb) != 0xd00dfeed)
        return -1;
    uint32_t totalsize = be32(dtb + 4);
    uint32_t off_struct = be32(dtb + 8);
    uint32_t off_strings = be32(dtb + 12);
    if (totalsize > len)
        return -1;

    const uint8_t *strs = dtb + off_strings;
    const uint8_t *p = dtb + off_struct;
    const uint8_t *end = dtb + totalsize;
    int depth = 0;
    int in_cpus_depth = -1; /* depth of the /cpus node, -1 = outside */

    while (p + 4 <= end) {
        uint32_t token = be32(p);
        p += 4;
        if (token == 1) { /* BEGIN_NODE */
            const char *name = (const char *)p;
            size_t nlen = strnlen(name, (size_t)(end - p));
            if (nlen == (size_t)(end - p))
                return -1;
            p += (nlen + 4) & ~3u;
            depth++;
            if (!strcmp(name, "cpus"))
                in_cpus_depth = depth;
            else if (!strncmp(name, "cpu@", 4) &&
                     depth == in_cpus_depth + 1) {
                if (info->cpu_nodes < (int)ARRAY_LEN(info->cpu_reg))
                    info->cpu_nodes++;
            }
        } else if (token == 2) { /* END_NODE */
            if (depth == in_cpus_depth)
                in_cpus_depth = -1;
            depth--;
            if (depth <= 0)
                break;
        } else if (token == 3) { /* PROP */
            if (p + 8 > end)
                return -1;
            uint32_t len32 = be32(p);
            uint32_t nameoff = be32(p + 4);
            p += 8;
            if (p + len32 > end)
                return -1;
            const char *pname = (const char *)strs + nameoff;
            if (!strcmp(pname, "reg") && in_cpus_depth > 0 &&
                depth == in_cpus_depth + 1 && len32 >= 4) {
                /* cpu reg: first u32 cell is the hart id */
                if (info->cpu_nodes > 0 &&
                    info->cpu_nodes <= (int)ARRAY_LEN(info->cpu_reg))
                    info->cpu_reg[info->cpu_nodes - 1] = be32(p);
            } else if (!strcmp(pname, "interrupts-extended")) {
                /* parent node name is not tracked here; the clint node
                 * always precedes plic in this FDT and both carry the
                 * property exactly once */
                if (info->clint_irq_cells == 0)
                    info->clint_irq_cells = (int)(len32 / 4);
                else if (info->plic_irq_cells == 0)
                    info->plic_irq_cells = (int)(len32 / 4);
            }
            p += (len32 + 3) & ~3u;
        } else if (token == 4) { /* NOP */
            /* skip */
        } else if (token == 9) { /* END */
            break;
        } else {
            return -1;
        }
    }
    return 0;
}

/* Extract the hex FDT dump between FDT-BEGIN\n and \nFDT-END\n. */
static int extract_fdt(const char *out, uint8_t *dtb, size_t dtb_cap)
{
    const char *b = strstr(out, "FDT-BEGIN\n");
    const char *e = strstr(out, "\nFDT-END\n");
    if (!b || !e || e <= b)
        return -1;
    b += strlen("FDT-BEGIN\n");
    size_t hex_len = (size_t)(e - b);
    size_t n = 0;
    for (size_t i = 0; i + 1 < hex_len && n < dtb_cap; i += 2) {
        char hb[3] = { b[i], b[i + 1], 0 };
        dtb[n++] = (uint8_t)strtoul(hb, NULL, 16);
    }
    return (int)n;
}

/* ------------------------------------------------------------------ */
/* tests                                                                */

static const char *SMP_BIN = "smp_test.bin";
static const char *PERF_DUAL_BIN = "perf_dual.bin";
static const char *MMIO_SOLO_BIN = "mmio_solo.bin";
static const char *PERF_SINGLE_BIN = "perf_single.bin";

static void test_capability(void)
{
    CHECK(floe_vm_max_vcpu_count() == 2,
          "floe_vm_max_vcpu_count()=%d != 2", floe_vm_max_vcpu_count());
    CHECK(floe_vm_smp_capable() == 1, "floe_vm_smp_capable() != 1");
}

static void test_smp_functional(void)
{
    RunResult r;
    memset(&r, 0, sizeof(r));
    r.bios_path = SMP_BIN;
    r.vcpu_count = 2;
    r.max_slices = 400000;
    run_vm(&r);
    CHECK(r.rc == 1, "dual-hart run rc=%d (want poweroff=1)", r.rc);
    const char *out = r.sink.buf ? r.sink.buf : "";

    CHECK(strstr(out, "AMO-OK\n") != NULL, "AMO-OK missing (atomicity)");
    CHECK(strstr(out, "LRSC-OK\n") != NULL, "LRSC-OK missing");
    CHECK(strstr(out, "IPI-OK\n") != NULL, "IPI-OK missing (CLINT msip/WFI)");
    CHECK(strstr(out, "CODE-OK\n") != NULL, "CODE-OK missing (cross-hart code)");
    CHECK(strstr(out, "ADV-OK\n") != NULL,
          "ADV-OK missing (ordinary-store/AMO+store/VA-alias adversarial)");
    CHECK(strstr(out, "AMOMMIO-OK\n") != NULL,
          "AMOMMIO-OK missing (MMIO AMO must be one device critical section)");
    CHECK(strstr(out, "PTEAD-OK\n") != NULL,
          "PTEAD-OK missing (page-walk A/D vs concurrent PTE replacement)");
    CHECK(strstr(out, "TRAP") == NULL, "guest trap: %.80s", out);
    CHECK(strstr(out, "SMP-OK\n") != NULL, "SMP-OK missing (failcnt path)");
    CHECK(strstr(out, "SMP-FAIL") == NULL, "SMP-FAIL in output");

    /* Audit invariants (see riscv_cpu_priv.h / floe_vm.h):
       - lock_order_violations counts device-lock acquisitions made while
         the hart already holds the atomic lock. Virtio DMA takes
         device -> atomic, so that order deadlocks; the payload drives
         MMIO LR/SC/AMO through the device layer, so a regression in the
         LR/MMIO split would show up here deterministically.
       - pte_ad_updates counts page-walk A/D updates applied under the
         atomic lock; the PTE phase forces them (A/D-clear leaves). A walk
         that went back to a plain load+store would either stop counting
         or clobber a replacement (which the payload detects as a mapping
         regression and the guest would report as a failure). */
    CHECK(r.stats.lock_order_violations == 0,
          "lock order violations=%" PRIu64 " (atomic -> device)",
          r.stats.lock_order_violations);
    CHECK(r.stats.pte_ad_updates > 0, "pte_ad_updates=%" PRIu64,
          r.stats.pte_ad_updates);
    printf("smp: lock_order_violations=%" PRIu64 " pte_ad_updates=%" PRIu64
           " pte_ad_conflicts=%" PRIu64 "\n",
           r.stats.lock_order_violations, r.stats.pte_ad_updates,
           r.stats.pte_ad_conflicts);

    /* per-hart stats: both harts retired instructions */
    CHECK(r.stats.vcpu_count == 2, "stats.vcpu_count=%d", r.stats.vcpu_count);
    CHECK(r.stats.host_threads == 2, "stats.host_threads=%d",
          r.stats.host_threads);
    /* Spin-wait iterations (and therefore the exact counts) depend on how
       the two host threads interleave; measured over 10 dual runs: hart0
       618K-635K, hart1 3.7K-38K. Both bounds stay well below the minimum
       while still failing a hart that parked early: hart1 must at least
       run its 200 AMO + 100 LR/SC iterations and the phase protocol
       (>=1.1K instructions), hart0 must run its waits/report path. */
    CHECK(r.stats.hart_insns[0] > 200000, "hart0 insns=%" PRIu64,
          r.stats.hart_insns[0]);
    CHECK(r.stats.hart_insns[1] > 2000, "hart1 insns=%" PRIu64,
          r.stats.hart_insns[1]);

    /* FDT: 2 cpu nodes, clint/plic interrupt maps widened to 2 harts */
    uint8_t dtb[16384];
    int dtb_len = extract_fdt(out, dtb, sizeof(dtb));
    CHECK(dtb_len > 0, "no FDT dump (len=%d)", dtb_len);
    if (dtb_len > 0) {
        FdtInfo info;
        int prc = fdt_parse(dtb, (size_t)dtb_len, &info);
        CHECK(prc == 0, "fdt_parse rc=%d", prc);
        CHECK(info.cpu_nodes == 2, "fdt cpu_nodes=%d (want 2)",
              info.cpu_nodes);
        CHECK(info.cpu_reg[0] == 0 && info.cpu_reg[1] == 1,
              "fdt cpu regs = %u,%u (want 0,1)", info.cpu_reg[0],
              info.cpu_reg[1]);
        CHECK(info.clint_irq_cells == 8, "clint cells=%d (want 8 = 2 harts)",
              info.clint_irq_cells);
        CHECK(info.plic_irq_cells == 8, "plic cells=%d (want 8 = 2 harts)",
              info.plic_irq_cells);
    }
    free(r.sink.buf);
}

/* Deterministic invariant test for the audit findings: MMIO LR and MMIO
 * AMO must not be performed while holding the machine atomic lock, and the
 * walk's A/D update must be a locked read-modify-write. The payload runs
 * one hart only on the MMIO path (the other parks), so a regression cannot
 * deadlock here: it just records the forbidden order, which fails fast. */
static void test_smp_invariants(void)
{
    RunResult r;
    memset(&r, 0, sizeof(r));
    r.bios_path = MMIO_SOLO_BIN;
    r.vcpu_count = 2;
    r.max_slices = 20000;
    run_vm(&r);
    CHECK(r.rc == 1, "mmio solo rc=%d (want poweroff=1)", r.rc);
    CHECK(r.stats.lock_order_violations == 0,
          "mmio solo: lock order violations=%" PRIu64
          " (device lock taken while holding the atomic lock)",
          r.stats.lock_order_violations);
    free(r.sink.buf);
}

static void test_up_compat(void)
{
    for (int vcpu = 0; vcpu <= 1; vcpu++) {
        RunResult r;
        memset(&r, 0, sizeof(r));
        r.bios_path = SMP_BIN;
        r.vcpu_count = vcpu;
        r.max_slices = 200000;
        run_vm(&r);
        CHECK(r.rc == 1, "UP run (vcpu=%d) rc=%d", vcpu, r.rc);
        const char *out = r.sink.buf ? r.sink.buf : "";
        CHECK(strstr(out, "UP-OK\n") != NULL, "UP-OK missing (vcpu=%d): %.60s",
              vcpu, out);
        CHECK(r.stats.vcpu_count == 1, "UP stats.vcpu_count=%d",
              r.stats.vcpu_count);
        CHECK(r.stats.host_threads == 0, "UP host_threads=%d",
              r.stats.host_threads);
        uint8_t dtb[16384];
        int dtb_len = extract_fdt(out, dtb, sizeof(dtb));
        CHECK(dtb_len > 0, "UP: no FDT dump (vcpu=%d)", vcpu);
        if (dtb_len > 0) {
            FdtInfo info;
            int prc = fdt_parse(dtb, (size_t)dtb_len, &info);
            CHECK(prc == 0, "UP fdt_parse rc=%d", prc);
            CHECK(info.cpu_nodes == 1, "UP fdt cpu_nodes=%d (want 1)",
                  info.cpu_nodes);
            CHECK(info.clint_irq_cells == 4,
                  "UP clint cells=%d (want 4 = 1 hart)", info.clint_irq_cells);
            CHECK(info.plic_irq_cells == 4, "UP plic cells=%d (want 4)",
                  info.plic_irq_cells);
        }
        free(r.sink.buf);
    }
}

/* stop/cancel: destroy a running VM (with a disk attached) from another
 * thread; must join the hart threads and close cleanly, repeatably.
 * The runner performs ONE slice and then touches no VM state, so the
 * destroy (which waits for the in-flight slice via api_lock, then stops
 * and joins the hart threads) can race the slice safely. */
typedef struct {
    FloeVM *vm;
    int slices_done;
} StopCtx;

static void *stop_runner(void *arg)
{
    StopCtx *c = arg;
    if (floe_vm_run_slice(c->vm, 10) == 0)
        c->slices_done = 1;
    return NULL;
}

static void test_stop_cancel(void)
{
    for (int round = 0; round < 3; round++) {
        FloeVMConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = PERF_DUAL_BIN; /* long-running payload */
        cfg.vcpu_count = 2;
        cfg.disk_path = "stop_test_disk.img";
        cfg.disk_rw = 0; /* snapshot mode: no host file mutation */

        FloeVM *vm = floe_vm_create(&cfg, NULL, NULL);
        CHECK(vm != NULL, "stop/cancel create round %d", round);
        if (!vm)
            return;
        StopCtx ctx;
        ctx.vm = vm;
        ctx.slices_done = 0;
        pthread_t th;
        pthread_create(&th, NULL, stop_runner, &ctx);
        struct timespec ts = { 0, 20 * 1000 * 1000 }; /* 20 ms */
        nanosleep(&ts, NULL); /* the runner is now inside its slice */
        int64_t t0 = now_ms();
        floe_vm_destroy(vm); /* waits for the slice, joins harts, closes */
        int64_t dt = now_ms() - t0;
        pthread_join(th, NULL);
        CHECK(dt < 5000, "destroy took %" PRId64 " ms (round %d)", dt, round);
        CHECK(ctx.slices_done == 1, "slice did not run (round %d)", round);
    }
}

/* concurrent sampling: one thread runs slices while another samples
 * FloeVMStats, then an ordered stop (join runner, then destroy). */
typedef struct {
    FloeVM *vm;
    volatile int stop;
    int slices_done;
} RunCtx;

static void *slice_runner(void *arg)
{
    RunCtx *c = arg;
    while (!c->stop) {
        if (floe_vm_run_slice(c->vm, 10) != 0)
            break;
        c->slices_done++;
    }
    return NULL;
}

static void test_stats_concurrent(void)
{
    FloeVMConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb = 64;
    cfg.bios_path = PERF_DUAL_BIN;
    cfg.vcpu_count = 2;
    FloeVM *vm = floe_vm_create(&cfg, NULL, NULL);
    CHECK(vm != NULL, "stats concurrent create");
    if (!vm)
        return;
    RunCtx ctx;
    ctx.vm = vm;
    ctx.stop = 0;
    ctx.slices_done = 0;
    pthread_t runner;
    pthread_create(&runner, NULL, slice_runner, &ctx);

    uint64_t last0 = 0, last1 = 0;
    int hart1_active = 0, samples = 0;
    for (int i = 0; i < 100; i++) {
        FloeVMStats st;
        int rc = floe_vm_get_stats(vm, &st);
        CHECK(rc == 0, "get_stats rc=%d", rc);
        if (rc != 0)
            break;
        CHECK(st.vcpu_count == 2, "sample vcpu_count=%d", st.vcpu_count);
        CHECK(st.host_threads == 2, "sample host_threads=%d",
              st.host_threads);
        CHECK(st.hart_insns[0] >= last0,
              "hart0 insns went backwards: %" PRIu64 " -> %" PRIu64, last0,
              st.hart_insns[0]);
        CHECK(st.hart_insns[1] >= last1,
              "hart1 insns went backwards: %" PRIu64 " -> %" PRIu64, last1,
              st.hart_insns[1]);
        last0 = st.hart_insns[0];
        last1 = st.hart_insns[1];
        if (last1 > 0)
            hart1_active++;
        samples++;
        struct timespec ts = { 0, 5 * 1000 * 1000 }; /* 5 ms */
        nanosleep(&ts, NULL);
    }
    CHECK(samples >= 100, "samples=%d", samples);
    CHECK(hart1_active > 0, "hart1 never retired instructions");
    ctx.stop = 1;
    pthread_join(runner, NULL); /* ordered stop before destroy */
    CHECK(ctx.slices_done > 0, "no slices ran");
    floe_vm_destroy(vm);
}

static void test_perf(void)
{
    RunResult single, dual;
    memset(&single, 0, sizeof(single));
    single.bios_path = PERF_SINGLE_BIN;
    single.vcpu_count = 1;
    single.max_slices = 4000000;
    run_vm(&single);
    CHECK(single.rc == 1, "perf single rc=%d", single.rc);

    memset(&dual, 0, sizeof(dual));
    dual.bios_path = PERF_DUAL_BIN;
    dual.vcpu_count = 2;
    dual.max_slices = 4000000;
    run_vm(&dual);
    CHECK(dual.rc == 1, "perf dual rc=%d", dual.rc);

    uint64_t work_single = single.stats.hart_insns[0];
    uint64_t work_dual = dual.stats.hart_insns[0] + dual.stats.hart_insns[1];
    printf("perf: 1 hart  %" PRId64 " ms, %" PRIu64 " insns\n",
           single.wall_ms, work_single);
    printf("perf: 2 harts %" PRId64 " ms, %" PRIu64 " insns "
           "(h0=%" PRIu64 ", h1=%" PRIu64 ")\n",
           dual.wall_ms, work_dual, dual.stats.hart_insns[0],
           dual.stats.hart_insns[1]);
    CHECK(work_single > 100000000, "single work=%" PRIu64, work_single);
    CHECK(work_dual > 100000000, "dual work=%" PRIu64, work_dual);
    /* same total guest work within 15% (payload overhead differs slightly) */
    int64_t diff = (int64_t)(work_single > work_dual
                                 ? work_single - work_dual
                                 : work_dual - work_single);
    CHECK(diff * 100 < (int64_t)work_single * 15,
          "work mismatch: single=%" PRIu64 " dual=%" PRIu64, work_single,
          work_dual);
    /* true parallel speedup: 2 harts must beat 1 hart on equal work */
    CHECK(dual.wall_ms < single.wall_ms,
          "no speedup: dual=%" PRId64 "ms single=%" PRId64 "ms",
          dual.wall_ms, single.wall_ms);
    printf("perf: speedup = %.2fx\n",
           (double)single.wall_ms / (double)(dual.wall_ms ? dual.wall_ms : 1));
    free(single.sink.buf);
    free(dual.sink.buf);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    test_capability();
    test_smp_invariants();
    test_smp_functional();
    test_up_compat();
    test_stop_cancel();
    test_stats_concurrent();
    test_perf();
    if (g_failures) {
        printf("SMP-HOST-TESTS: %d FAILURE(S)\n", g_failures);
        return 1;
    }
    printf("SMP-HOST-TESTS: ALL PASS\n");
    return 0;
}

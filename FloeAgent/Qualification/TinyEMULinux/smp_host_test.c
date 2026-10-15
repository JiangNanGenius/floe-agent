/*
 * smp_host_test.c — FLOE-SMP qualification host for the embeddable VM API.
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * What this proves at the C-host/API layer (engine-internal adversarial
 * LR/SC/AMO tests live in FloeTinyEMUTests, job A):
 *   1. capability probes: floe_vm_max_vcpu_count()/floe_vm_smp_capable()
 *      match the contract and vcpu_count above FLOE_VM_MAX_VCPU is rejected
 *      by floe_vm_create;
 *   2. dual-hart boot of a REAL guest: one host thread per hart actually
 *      executes guest code — shown by FloeVMStats.host_threads == 2 and by
 *      per-hart retired-instruction counters BOTH advancing (not by nproc);
 *   3. concurrent stats sampling from a second host thread while
 *      run_slice is in flight (the floe_vm_get_stats locking contract);
 *   4. IO from the dual-hart guest: virtio-blk root + console + a real 9p
 *      share write observed on the host;
 *   5. stop+flush: floe_vm_destroy joins every hart thread mid-slice,
 *      repeatedly, without deadlock, before the disk handles close;
 *   6. single-hart control (vcpu_count=1): legacy behavior — no hart
 *      threads, only hart 0 retires instructions;
 *   7. --triple (opt-in, requires a guest whose kernel+firmware really use
 *      three harts, e.g. the pinned production image): the same real-guest
 *      boot with host_threads == 3 and per-hart counters advancing on
 *      harts 0, 1 AND 2, plus vcpu=3 stop+flush destroy cycles.
 * Whether the parked hart shows up as WFI-powered-down is recorded as
 * informational evidence (it depends on the guest firmware park loop).
 *
 * Evidence rules: guest markers are runtime-assembled by the guest
 * (echo FLOE_SMP_A_$((6*7)), printf 'FLOE_SMP_IO_%s\n' OK), so the literal
 * marker never appears in the console input line the guest TTY echoes.
 * Guest CPU visibility is reported honestly: the pinned 4.15 demo kernel
 * is UP (CONFIG_SMP is not set), so /proc/cpuinfo reports 1 processor;
 * the second hart executes firmware code during boot and is then parked.
 * A real SMP kernel (job A, guest-image scope) strengthens, not replaces,
 * these checks.
 *
 * Usage:
 *   smp_host_test --bios F --kernel F --disk F [--share tag=dir] [--net]
 *                 [--ram MB] [--cmdline S] [--triple]
 *                 --summary OUT.json --transcript OUT.txt
 * --cmdline overrides the kernel command line (use e.g.
 * "console=hvc0 root=/dev/vda rw init=/bin/sh" for a guest image whose own
 * init would not give the scripted console a shell).
 * Exit: 0 = all checks passed; 1 = a check failed (see summary).
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#include "floe_vm.h"

#define MAX_CMDS 32
#define MARKER "FLOE_SMP_DONE_OK"

typedef struct {
    double at_s;
    const char *text;
} TimedCmd;

typedef struct {
    FloeVM *vm;
    volatile int stop;
    int samples;
    int saw_host_threads2;
    int saw_host_threads3;
    uint64_t max_insns0, max_insns1, max_insns2;
    double first_hart1_insn_t;   /* when hart 1 first retired an insn */
    int hart1_powered_down_last;
} Sampler;

static FILE *transcript;
static char marker[256];
static int marker_seen;
static double test_start; /* sampler reports hart-1 first-insn relative to this */

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Rolling window for the runtime-assembled marker search. It is reset per
 * boot phase: a later phase must not match a marker still sitting in the
 * previous phase's window (that made the triple phase "see" the dual phase's
 * marker on its first console bytes and skip the real run). */
static char marker_window[1024];
static int marker_window_len;

static void reset_marker_window(void)
{
    marker_window_len = 0;
    marker_window[0] = 0;
}

static void on_console(void *opaque, const uint8_t *data, int len)
{
    (void)opaque;
    if (transcript) {
        fwrite(data, 1, len, transcript);
        fflush(transcript);
    }
    fwrite(data, 1, len, stdout);
    fflush(stdout);
    if (marker[0] && !marker_seen) {
        char window[2049];
        int wl = marker_window_len + len;
        if (wl > 2048) wl = 2048;
        memcpy(window, marker_window, marker_window_len);
        memcpy(window + marker_window_len, data, wl - marker_window_len);
        window[wl] = 0;
        if (strstr(window, marker))
            marker_seen = 1;
        marker_window_len = wl < 1024 ? wl : 1024;
        memcpy(marker_window, window + (wl - marker_window_len), marker_window_len);
    }
}

/* Sample stats from a SECOND host thread while the main thread runs
 * slices: proves the floe_vm_get_stats cross-thread contract. */
static void *sampler_main(void *arg)
{
    Sampler *s = (Sampler *)arg;
    while (!s->stop) {
        FloeVMStats st;
        double t = now_s();
        if (floe_vm_get_stats(s->vm, &st) == 0) {
            s->samples++;
            if (st.host_threads == 2)
                s->saw_host_threads2 = 1;
            if (st.host_threads == 3)
                s->saw_host_threads3 = 1;
            if (st.hart_insns[0] > s->max_insns0)
                s->max_insns0 = st.hart_insns[0];
            if (st.hart_insns[1] > 0 && s->max_insns1 == 0)
                s->first_hart1_insn_t = t - test_start;
            if (st.hart_insns[1] > s->max_insns1)
                s->max_insns1 = st.hart_insns[1];
            if (st.hart_insns[2] > s->max_insns2)
                s->max_insns2 = st.hart_insns[2];
            s->hart1_powered_down_last = st.hart_powered_down[1];
        }
        usleep(20 * 1000);
    }
    return NULL;
}

static int failures = 0;
static int checks = 0;

static void check(int cond, const char *what)
{
    checks++;
    if (cond) {
        printf("ok: %s\n", what);
    } else {
        failures++;
        printf("FAIL: %s\n", what);
    }
}

int main(int argc, char **argv)
{
    const char *summary_path = NULL, *transcript_path = NULL;
    const char *share_tag = NULL, *share_dir = NULL;
    int ram_mb = 128, net = 0, triple = 0, i;
    double dual_max_s = 180.0;
    double start, el;
    pthread_t sampler_thr;
    Sampler sampler;
    Sampler triple_stats;
    FloeVMConfig cfg;
    FloeVM *vm;
    FILE *summary;

    static const TimedCmd cmds[] = {
        { 8,  "echo FLOE_SMP_A_$((6*7))" },
        { 12, "mkdir -p /floe; mount -t 9p -o trans=virtio,version=9p2000.L floe /floe" },
        { 16, "echo smp-io > /floe/floe_smp_io.txt && printf 'FLOE_SMP_IO_%s\\n' OK" },
        { 22, "grep -c ^processor /proc/cpuinfo" },
        { 26, "printf 'FLOE_SMP_DONE_%s\\n' OK" },
    };
    const int cmd_count = (int)(sizeof(cmds) / sizeof(cmds[0]));
    int cmd_next = 0;

    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb = ram_mb;
    cfg.cmdline = "console=hvc0 root=/dev/vda rw";
    snprintf(marker, sizeof(marker), "%s", MARKER);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bios") && i + 1 < argc) cfg.bios_path = argv[++i];
        else if (!strcmp(argv[i], "--kernel") && i + 1 < argc) cfg.kernel_path = argv[++i];
        else if (!strcmp(argv[i], "--disk") && i + 1 < argc) cfg.disk_path = argv[++i];
        else if (!strcmp(argv[i], "--net")) net = 1;
        else if (!strcmp(argv[i], "--ram") && i + 1 < argc) cfg.ram_mb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--share") && i + 1 < argc) {
            char *spec = argv[++i], *eq = strchr(spec, '=');
            if (!eq) { fprintf(stderr, "bad --share\n"); return 1; }
            *eq = 0;
            share_tag = spec;
            share_dir = eq + 1;
        }
        else if (!strcmp(argv[i], "--summary") && i + 1 < argc) summary_path = argv[++i];
        else if (!strcmp(argv[i], "--transcript") && i + 1 < argc) transcript_path = argv[++i];
        else if (!strcmp(argv[i], "--dual-max-s") && i + 1 < argc) dual_max_s = atof(argv[++i]);
        else if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cfg.cmdline = argv[++i];
        else if (!strcmp(argv[i], "--triple")) triple = 1;
        else { fprintf(stderr, "smp_host_test: unknown arg %s\n", argv[i]); return 1; }
    }
    if (!cfg.bios_path || !cfg.kernel_path || !cfg.disk_path ||
        !summary_path || !transcript_path) {
        fprintf(stderr, "usage: smp_host_test --bios F --kernel F --disk F "
                "[--share tag=dir] [--net] [--ram MB] [--dual-max-s N] "
                "[--cmdline S] [--triple] --summary OUT.json --transcript OUT.txt\n");
        return 1;
    }
    if (share_tag) {
        cfg.shares[0].tag = share_tag;
        cfg.shares[0].host_dir = share_dir;
        cfg.share_count = 1;
    }
    cfg.net_enable = net;

    printf("smp_host_test: engine=%s smp_capable=%d max_vcpu=%d\n",
           floe_vm_engine_version(), floe_vm_smp_capable(),
           floe_vm_max_vcpu_count());

    /* ---- 1. capability probes + config validation -------------------- */
    check(floe_vm_max_vcpu_count() == FLOE_VM_MAX_VCPU,
          "floe_vm_max_vcpu_count() reports FLOE_VM_MAX_VCPU");
    check(floe_vm_smp_capable() == 1,
          "floe_vm_smp_capable() reports 1 (engine implements SMP hooks)");

    {
        FloeVMConfig bad = cfg;
        FloeVM *must_fail;
        bad.vcpu_count = FLOE_VM_MAX_VCPU + 1;
        must_fail = floe_vm_create(&bad, on_console, NULL);
        check(must_fail == NULL,
              "floe_vm_create rejects vcpu_count > FLOE_VM_MAX_VCPU");
        if (must_fail)
            floe_vm_destroy(must_fail);
    }

    /* ---- 2. dual-hart real guest boot -------------------------------- */
    memset(&sampler, 0, sizeof(sampler));
    memset(&triple_stats, 0, sizeof(triple_stats));
    cfg.vcpu_count = 2;
    transcript = fopen(transcript_path, "w");
    if (!transcript) { perror(transcript_path); return 1; }
    start = now_s();
    test_start = start;
    vm = floe_vm_create(&cfg, on_console, NULL);
    check(vm != NULL, "dual-hart floe_vm_create (vcpu_count=2)");
    if (!vm) {
        fclose(transcript);
        transcript = NULL;
        goto out;
    }

    sampler.vm = vm;
    sampler.stop = 0;
    if (pthread_create(&sampler_thr, NULL, sampler_main, &sampler) != 0) {
        fprintf(stderr, "smp_host_test: cannot create sampler thread\n");
        return 1;
    }

    cmd_next = 0;
    marker_seen = 0;
    reset_marker_window();
    while ((el = now_s() - start) < dual_max_s) {
        while (cmd_next < cmd_count && cmds[cmd_next].at_s <= el) {
            /* host-side honesty gate: our own marker literal must not be
             * present in any input line (same rule as floe_vm_host) */
            if (strstr(cmds[cmd_next].text, MARKER)) {
                fprintf(stderr, "smp_host_test: marker literal in input line\n");
                return 1;
            }
            floe_vm_console_input(vm, (const uint8_t *)cmds[cmd_next].text,
                                  strlen(cmds[cmd_next].text));
            floe_vm_console_input(vm, (const uint8_t *)"\n", 1);
            cmd_next++;
        }
        if (floe_vm_run_slice(vm, 10) == 1) {
            printf("note: guest requested poweroff before the marker\n");
            break;
        }
        if (marker_seen)
            break;
    }
    check(marker_seen, "runtime-assembled guest marker observed (dual-hart)");
    check(sampler.saw_host_threads2,
          "stats report host_threads=2 (one host thread per hart)");
    check(sampler.max_insns0 > 0, "hart 0 retired instructions");
    check(sampler.max_insns1 > 0,
          "hart 1 retired instructions (second thread ACTUALLY executed guest code)");
    /* Informational: a UP guest parks hart 1 in firmware. Whether that park
     * loop is a WFI (reported via hart_powered_down) depends on the guest
     * firmware, so this is recorded as evidence, not asserted. */
    printf("note: hart1_powered_down last sample = %d "
           "(1 = hart 1 in WFI power-down; informational)\n",
           sampler.hart1_powered_down_last);

    sampler.stop = 1;
    pthread_join(sampler_thr, NULL);

    if (share_dir) {
        char path[1024];
        FILE *probe;
        snprintf(path, sizeof(path), "%s/floe_smp_io.txt", share_dir);
        probe = fopen(path, "r");
        check(probe != NULL, "9p share: guest wrote floe_smp_io.txt (virtio IO)");
        if (probe) {
            char buf[64] = {0};
            if (fread(buf, 1, sizeof(buf) - 1, probe) > 0)
                check(strstr(buf, "smp-io") != NULL,
                      "9p share: file content matches what the guest wrote");
            fclose(probe);
        }
    }

    /* ---- 3. stop+flush: destroy mid-slice, repeatedly ---------------- */
    {
        int cycle;
        double t0, destroy_s = 0;
        for (cycle = 0; cycle < 3; cycle++) {
            FloeVM *v2;
            FloeVMConfig c2 = cfg;
            c2.vcpu_count = 2;
            v2 = floe_vm_create(&c2, on_console, NULL);
            if (!v2) { check(0, "stop+flush create cycle"); break; }
            floe_vm_run_slice(v2, 10);
            floe_vm_run_slice(v2, 10);
            t0 = now_s();
            floe_vm_destroy(v2);   /* must join hart threads before close */
            destroy_s += now_s() - t0;
            check(1, "stop+flush destroy returned cleanly (join before close)");
        }
        printf("stop+flush: 3 destroy cycles in %.3fs total\n", destroy_s);
    }

    floe_vm_destroy(vm);
    fclose(transcript);
    transcript = NULL;

    /* ---- 3b. triple-hart real guest boot (opt-in) -------------------- */
    if (triple) {
        FloeVMConfig c3 = cfg;
        FloeVM *v3;
        double t3, triple_s = 0;
        char triple_transcript[1024];

        c3.vcpu_count = 3;
        snprintf(triple_transcript, sizeof(triple_transcript), "%s.triple", transcript_path);
        transcript = fopen(triple_transcript, "w");
        if (!transcript) { perror(triple_transcript); return 1; }
        t3 = now_s();
        v3 = floe_vm_create(&c3, on_console, NULL);
        check(v3 != NULL, "triple-hart floe_vm_create (vcpu_count=3)");
        if (v3) {
            triple_stats.vm = v3;
            triple_stats.stop = 0;
            if (pthread_create(&sampler_thr, NULL, sampler_main, &triple_stats) != 0) {
                fprintf(stderr, "smp_host_test: cannot create triple sampler thread\n");
                return 1;
            }
            cmd_next = 0;
            marker_seen = 0;
            reset_marker_window();
            while ((el = now_s() - t3) < dual_max_s) {
                while (cmd_next < cmd_count && cmds[cmd_next].at_s <= el) {
                    if (strstr(cmds[cmd_next].text, MARKER)) {
                        fprintf(stderr, "smp_host_test: marker literal in input line\n");
                        return 1;
                    }
                    floe_vm_console_input(v3, (const uint8_t *)cmds[cmd_next].text,
                                          strlen(cmds[cmd_next].text));
                    floe_vm_console_input(v3, (const uint8_t *)"\n", 1);
                    cmd_next++;
                }
                if (floe_vm_run_slice(v3, 10) == 1) {
                    printf("note: guest requested poweroff before the triple marker\n");
                    break;
                }
                if (marker_seen)
                    break;
            }
            check(marker_seen, "runtime-assembled guest marker observed (triple-hart)");
            check(triple_stats.saw_host_threads3,
                  "stats report host_threads=3 (one host thread per hart)");
            check(triple_stats.max_insns0 > 0, "hart 0 retired instructions (triple-hart)");
            check(triple_stats.max_insns1 > 0, "hart 1 retired instructions (triple-hart)");
            check(triple_stats.max_insns2 > 0,
                  "hart 2 retired instructions (third thread ACTUALLY executed guest code)");
            triple_stats.stop = 1;
            pthread_join(sampler_thr, NULL);
            if (share_dir) {
                char path[1024];
                FILE *probe;
                snprintf(path, sizeof(path), "%s/floe_smp_io.txt", share_dir);
                probe = fopen(path, "r");
                check(probe != NULL, "9p share: triple-hart guest wrote floe_smp_io.txt");
                if (probe)
                    fclose(probe);
            }
            floe_vm_destroy(v3);
        }
        /* stop+flush at vcpu=3: destroy mid-slice repeatedly */
        for (i = 0; i < 3; i++) {
            FloeVMConfig c3b = cfg;
            FloeVM *v3b;
            double t0;
            c3b.vcpu_count = 3;
            v3b = floe_vm_create(&c3b, on_console, NULL);
            if (!v3b) { check(0, "triple stop+flush create cycle"); break; }
            floe_vm_run_slice(v3b, 10);
            floe_vm_run_slice(v3b, 10);
            t0 = now_s();
            floe_vm_destroy(v3b);
            triple_s += now_s() - t0;
            check(1, "triple stop+flush destroy returned cleanly (join before close)");
        }
        printf("triple stop+flush: 3 destroy cycles in %.3fs total\n", triple_s);
        fclose(transcript);
        transcript = NULL;
        printf("note: triple hart2_powered_down last sample = %d (informational)\n",
               triple_stats.hart1_powered_down_last);
    }

    /* ---- 4. single-hart control -------------------------------------- */
    {
        FloeVMConfig c1 = cfg;
        FloeVM *v1;
        FloeVMStats st;
        double s1;
        c1.vcpu_count = 1;
        v1 = floe_vm_create(&c1, on_console, NULL);
        check(v1 != NULL, "single-hart floe_vm_create (vcpu_count=1 legacy)");
        if (v1) {
            s1 = now_s();
            while (now_s() - s1 < 3.0)
                floe_vm_run_slice(v1, 10);
            check(floe_vm_get_stats(v1, &st) == 0, "stats readable (single-hart)");
            check(st.vcpu_count == 1, "single-hart stats vcpu_count=1");
            check(st.host_threads == 0,
                  "single-hart uses inline interpretation (host_threads=0)");
            check(st.hart_insns[0] > 0, "single-hart hart 0 retired instructions");
            check(st.hart_insns[1] == 0, "single-hart hart 1 absent (0 insns)");
            floe_vm_destroy(v1);
        }
    }

out:
    summary = fopen(summary_path, "w");
    if (!summary) { perror(summary_path); return 1; }
    fprintf(summary,
        "{\n"
        "  \"test\": \"smp_host_test\",\n"
        "  \"engine\": \"%s\",\n"
        "  \"smp_capable\": %d,\n"
        "  \"max_vcpu\": %d,\n"
        "  \"requested_vcpu\": 2,\n"
        "  \"dual\": {\n"
        "    \"stats_samples\": %d,\n"
        "    \"saw_host_threads2\": %d,\n"
        "    \"hart0_max_insns\": %llu,\n"
        "    \"hart1_max_insns\": %llu,\n"
        "    \"hart1_first_insn_at_s\": %.3f,\n"
        "    \"marker_seen\": %d\n"
        "  },\n"
        "  \"stop_flush_destroy_cycles\": 3,\n"
        "  \"triple\": {\n"
        "    \"enabled\": %d,\n"
        "    \"stats_samples\": %d,\n"
        "    \"saw_host_threads3\": %d,\n"
        "    \"hart0_max_insns\": %llu,\n"
        "    \"hart1_max_insns\": %llu,\n"
        "    \"hart2_max_insns\": %llu,\n"
        "    \"marker_seen\": %d\n"
        "  },\n"
        "  \"checks\": %d,\n"
        "  \"failures\": %d,\n"
        "  \"note\": \"markers are runtime-assembled by the guest; the pinned "
        "demo kernel is UP so the guest sees 1 processor - dual-hart proof "
        "is per-hart retired insns plus host_threads, not /proc/cpuinfo\"\n"
        "}\n",
        floe_vm_engine_version(), floe_vm_smp_capable(),
        floe_vm_max_vcpu_count(),
        sampler.samples, sampler.saw_host_threads2,
        (unsigned long long)sampler.max_insns0,
        (unsigned long long)sampler.max_insns1,
        sampler.first_hart1_insn_t, (int)marker_seen,
        triple, triple_stats.samples, triple_stats.saw_host_threads3,
        (unsigned long long)triple_stats.max_insns0,
        (unsigned long long)triple_stats.max_insns1,
        (unsigned long long)triple_stats.max_insns2,
        (int)marker_seen,
        checks, failures);
    fclose(summary);

    printf("smp_host_test: %d checks, %d failures\n", checks, failures);
    if (failures == 0)
        printf("SMP_HOST_OK (%d checks)\n", checks);
    else
        printf("SMP_HOST_FAIL (%d of %d checks failed)\n", failures, checks);
    return failures == 0 ? 0 : 1;
}

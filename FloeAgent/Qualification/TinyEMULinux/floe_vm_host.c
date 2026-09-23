/*
 * floe_vm_host.c — minimal non-interactive qualification host for the
 * Floe embeddable VM API (floe_vm.h). Drives a real guest boot, feeds a
 * timed command script to the guest console, records the transcript, and
 * exits 0 when an expected marker is observed (or the guest powers off).
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage:
 *   floe_vm_host --bios bbl64.bin --kernel kernel.bin --disk rootfs.bin
 *                [--rw] [--share tag=dir]... [--net] [--ram MB]
 *                [--vcpu N] [--cmdline "..."] [--script cmds.txt]
 *                [--transcript out.txt] [--until MARKER] [--max-s N]
 *                [--stats-file out.jsonl] [--stats-interval S]
 *
 * Script line format:  @<delay_seconds> <command text>
 * Exit: 0 = marker seen or guest poweroff; 2 = timeout; 1 = error.
 *
 * FLOE-SMP (--vcpu): 0/1 = legacy single hart (default, bit-compatible),
 * 2 = dual hart on two host threads. The host samples FloeVMStats into
 * --stats-file (JSON lines) so a run proves *actual* per-hart execution
 * (host_threads, per-hart retired insns), not just host CPU count.
 *
 * Evidence rules (enforced here, not just by convention):
 *  - the --until marker must never appear verbatim in any scripted input
 *    line: the guest TTY echoes input, so a literal marker could be
 *    "observed" without the guest executing anything. The host refuses to
 *    run such a script; build markers at runtime inside the guest
 *    (printf 'X_%s' OK, echo X_$((6*7))).
 *  - on timeout (rc=2) the transcript and the final stats sample are kept.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#include "floe_vm.h"

#define MAX_CMDS 128

typedef struct {
    double at_s;
    char text[1024];
} TimedCmd;

static FILE *transcript;
static FILE *stats_file;
static char marker[256];
static int marker_seen;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
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
        /* streaming contains check with 1KB carryover for chunk-split hits */
        static char tail[1024];
        static int tail_len;
        char window[2049];
        int wl = tail_len + len;
        if (wl > 2048) wl = 2048;
        memcpy(window, tail, tail_len);
        memcpy(window + tail_len, data, wl - tail_len);
        window[wl] = 0;
        if (strstr(window, marker))
            marker_seen = 1;
        tail_len = wl < 1024 ? wl : 1024;
        memcpy(tail, window + (wl - tail_len), tail_len);
    }
}

/* One JSON stats sample. Never fails the run: stats are evidence, and a
 * sample failure is recorded as an event instead of hiding it. */
static void stats_sample(FloeVM *vm, const char *event, double t)
{
    FloeVMStats st;
    int i;
    if (!stats_file)
        return;
    if (floe_vm_get_stats(vm, &st) != 0) {
        fprintf(stats_file,
                "{\"event\":\"%s\",\"t\":%.3f,\"error\":\"floe_vm_get_stats failed\"}\n",
                event, t);
        fflush(stats_file);
        return;
    }
    fprintf(stats_file, "{\"event\":\"%s\",\"t\":%.3f,\"vcpu_count\":%d,"
                        "\"host_threads\":%d,\"hart_insns\":[",
            event, t, st.vcpu_count, st.host_threads);
    for (i = 0; i < FLOE_VM_MAX_VCPU; i++)
        fprintf(stats_file, "%s%llu", i ? "," : "",
                (unsigned long long)st.hart_insns[i]);
    fprintf(stats_file, "],\"hart_powered_down\":[");
    for (i = 0; i < FLOE_VM_MAX_VCPU; i++)
        fprintf(stats_file, "%s%d", i ? "," : "", st.hart_powered_down[i]);
    fprintf(stats_file, "]}\n");
    fflush(stats_file);
}

static void usage(void)
{
    fprintf(stderr,
        "usage: floe_vm_host --bios F --kernel F --disk F [--rw]\n"
        "       [--share tag=dir]... [--net] [--ram MB] [--vcpu N]\n"
        "       [--cmdline S] [--script F] [--transcript F] [--until S]\n"
        "       [--max-s N] [--stats-file F] [--stats-interval S]\n");
    exit(1);
}

int main(int argc, char **argv)
{
    FloeVMConfig cfg;
    FloeVM *vm;
    TimedCmd cmds[MAX_CMDS];
    int cmd_count = 0, cmd_next = 0;
    const char *script_path = NULL, *transcript_path = NULL;
    const char *stats_path = NULL;
    double max_s = 120, start, stats_interval = 5.0, last_stats = 0;
    int i, rc = 2, requested_vcpu = 0;

    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb = 128;
    cfg.cmdline = "console=hvc0 root=/dev/vda rw";
    marker[0] = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bios") && i + 1 < argc) cfg.bios_path = argv[++i];
        else if (!strcmp(argv[i], "--kernel") && i + 1 < argc) cfg.kernel_path = argv[++i];
        else if (!strcmp(argv[i], "--initrd") && i + 1 < argc) cfg.initrd_path = argv[++i];
        else if (!strcmp(argv[i], "--disk") && i + 1 < argc) cfg.disk_path = argv[++i];
        else if (!strcmp(argv[i], "--rw")) cfg.disk_rw = 1;
        else if (!strcmp(argv[i], "--net")) cfg.net_enable = 1;
        else if (!strcmp(argv[i], "--ram") && i + 1 < argc) cfg.ram_mb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vcpu") && i + 1 < argc) requested_vcpu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cfg.cmdline = argv[++i];
        else if (!strcmp(argv[i], "--share") && i + 1 < argc) {
            char *spec = argv[++i], *eq = strchr(spec, '=');
            if (!eq || cfg.share_count >= FLOE_VM_MAX_SHARES) usage();
            *eq = 0;
            cfg.shares[cfg.share_count].tag = spec;
            cfg.shares[cfg.share_count].host_dir = eq + 1;
            cfg.share_count++;
        }
        else if (!strcmp(argv[i], "--script") && i + 1 < argc) script_path = argv[++i];
        else if (!strcmp(argv[i], "--transcript") && i + 1 < argc) transcript_path = argv[++i];
        else if (!strcmp(argv[i], "--stats-file") && i + 1 < argc) stats_path = argv[++i];
        else if (!strcmp(argv[i], "--stats-interval") && i + 1 < argc) stats_interval = atof(argv[++i]);
        else if (!strcmp(argv[i], "--until") && i + 1 < argc) {
            snprintf(marker, sizeof(marker), "%s", argv[++i]);
        }
        else if (!strcmp(argv[i], "--max-s") && i + 1 < argc) max_s = atof(argv[++i]);
        else usage();
    }
    if (!cfg.bios_path) usage();

    if (requested_vcpu < 0 || requested_vcpu > floe_vm_max_vcpu_count()) {
        fprintf(stderr,
                "floe_vm_host: --vcpu %d out of range 0..%d\n",
                requested_vcpu, floe_vm_max_vcpu_count());
        return 1;
    }
    cfg.vcpu_count = requested_vcpu; /* 0/1 = legacy single hart */
    if (cfg.vcpu_count > 1 && !floe_vm_smp_capable()) {
        fprintf(stderr,
                "floe_vm_host: --vcpu %d requested but the linked engine is not "
                "SMP capable (floe_vm_smp_capable()=0)\n", cfg.vcpu_count);
        return 1;
    }

    if (script_path) {
        FILE *sf = fopen(script_path, "r");
        char line[1200];
        if (!sf) { perror(script_path); return 1; }
        while (fgets(line, sizeof(line), sf) && cmd_count < MAX_CMDS) {
            double at;
            char *sp;
            if (line[0] != '@') continue;
            at = strtod(line + 1, &sp);
            while (*sp == ' ') sp++;
            line[strcspn(line, "\n")] = 0;
            cmds[cmd_count].at_s = at;
            snprintf(cmds[cmd_count].text, sizeof(cmds[cmd_count].text),
                     "%s", sp);
            cmd_count++;
        }
        fclose(sf);
    }
    if (transcript_path) {
        transcript = fopen(transcript_path, "w");
        if (!transcript) { perror(transcript_path); return 1; }
    }
    if (stats_path) {
        stats_file = fopen(stats_path, "w");
        if (!stats_file) { perror(stats_path); return 1; }
    }

    /* Honest-marker gate: the marker literal must not be present in any
     * scripted input line, otherwise the TTY echo of the input line could
     * satisfy --without the guest executing anything. */
    if (marker[0]) {
        for (i = 0; i < cmd_count; i++) {
            if (strstr(cmds[i].text, marker)) {
                fprintf(stderr,
                    "floe_vm_host: refusing to run: --until marker '%s' appears\n"
                    "verbatim in the scripted input line '%s'; the guest TTY echo\n"
                    "could fake it. Build the marker at runtime inside the guest\n"
                    "(e.g. printf 'NAME_%%s\\n' OK or echo NAME_$((6*7))).\n",
                    marker, cmds[i].text);
                return 1;
            }
        }
    }

    fprintf(stderr, "floe_vm_host: engine=%s smp_capable=%d max_vcpu=%d "
            "vcpu=%d ram=%lluMB net=%d shares=%d\n",
            floe_vm_engine_version(), floe_vm_smp_capable(),
            floe_vm_max_vcpu_count(), cfg.vcpu_count,
            (unsigned long long)cfg.ram_mb, cfg.net_enable, cfg.share_count);

    vm = floe_vm_create(&cfg, on_console, NULL);
    if (!vm)
        return 1;

    if (stats_file)
        stats_sample(vm, "create", 0.0);

    start = now_s();
    while (now_s() - start < max_s) {
        double el = now_s() - start;
        while (cmd_next < cmd_count && cmds[cmd_next].at_s <= el) {
            floe_vm_console_input(vm, (const uint8_t *)cmds[cmd_next].text,
                                  strlen(cmds[cmd_next].text));
            floe_vm_console_input(vm, (const uint8_t *)"\n", 1);
            cmd_next++;
        }
        if (floe_vm_run_slice(vm, 10) == 1) {
            fprintf(stderr, "\nfloe_vm_host: guest poweroff requested\n");
            stats_sample(vm, "poweroff", now_s() - start);
            rc = 0;
            break;
        }
        if (marker[0] && marker_seen) {
            fprintf(stderr, "\nfloe_vm_host: marker '%s' observed\n", marker);
            stats_sample(vm, "marker", now_s() - start);
            rc = 0;
            break;
        }
        if (stats_file && stats_interval > 0 && el - last_stats >= stats_interval) {
            stats_sample(vm, "sample", el);
            last_stats = el;
        }
        if (cmd_next >= cmd_count && !marker[0] && el > max_s / 2)
            break; /* no script and no marker: nothing more to wait for */
    }
    if (rc == 2) {
        fprintf(stderr, "\nfloe_vm_host: timeout after %.1fs (transcript kept)\n",
                now_s() - start);
        if (stats_file)
            stats_sample(vm, "timeout", now_s() - start);
    }

    floe_vm_destroy(vm);
    if (transcript) {
        fflush(transcript);
        fclose(transcript);
    }
    if (stats_file) {
        fprintf(stats_file, "{\"event\":\"end\",\"rc\":%d}\n", rc);
        fclose(stats_file);
    }
    return rc;
}

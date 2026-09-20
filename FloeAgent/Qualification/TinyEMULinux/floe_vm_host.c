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
 *                [--cmdline "..."] [--script cmds.txt]
 *                [--transcript out.txt] [--until MARKER] [--max-s N]
 *
 * Script line format:  @<delay_seconds> <command text>
 * Exit: 0 = marker seen or guest poweroff; 2 = timeout; 1 = error.
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

static void usage(void)
{
    fprintf(stderr,
        "usage: floe_vm_host --bios F --kernel F --disk F [--rw]\n"
        "       [--share tag=dir]... [--net] [--ram MB] [--cmdline S]\n"
        "       [--script F] [--transcript F] [--until S] [--max-s N]\n");
    exit(1);
}

int main(int argc, char **argv)
{
    FloeVMConfig cfg;
    FloeVM *vm;
    TimedCmd cmds[MAX_CMDS];
    int cmd_count = 0, cmd_next = 0;
    const char *script_path = NULL, *transcript_path = NULL;
    double max_s = 120, start;
    int i, rc = 2;

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
        else if (!strcmp(argv[i], "--until") && i + 1 < argc) {
            snprintf(marker, sizeof(marker), "%s", argv[++i]);
        }
        else if (!strcmp(argv[i], "--max-s") && i + 1 < argc) max_s = atof(argv[++i]);
        else usage();
    }
    if (!cfg.bios_path) usage();

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

    fprintf(stderr, "floe_vm_host: engine=%s ram=%lluMB net=%d shares=%d\n",
            floe_vm_engine_version(), (unsigned long long)cfg.ram_mb,
            cfg.net_enable, cfg.share_count);

    vm = floe_vm_create(&cfg, on_console, NULL);
    if (!vm)
        return 1;

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
            rc = 0;
            break;
        }
        if (marker[0] && marker_seen) {
            fprintf(stderr, "\nfloe_vm_host: marker '%s' observed\n", marker);
            rc = 0;
            break;
        }
        if (cmd_next >= cmd_count && !marker[0] && el > max_s / 2)
            break; /* no script and no marker: nothing more to wait for */
    }
    if (rc == 2)
        fprintf(stderr, "\nfloe_vm_host: timeout after %.1fs\n",
                now_s() - start);

    floe_vm_destroy(vm);
    if (transcript)
        fclose(transcript);
    return rc;
}

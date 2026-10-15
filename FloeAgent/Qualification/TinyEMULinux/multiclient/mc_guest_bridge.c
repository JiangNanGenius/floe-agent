/*
 * mc_guest_bridge.c — expose a REAL TinyEMU guest console on stdin/stdout so
 * the multiclient harness can drive the production guest runner
 * (`/usr/local/bin/floe-exec` as PID 1) over the same framed console channel
 * it uses against a host process.
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * The harness (`MultiClientChannelCheck.swift`) spawns its runner binary with
 * no arguments, so configuration comes from the environment:
 *
 *   FLOE_MC_BRIDGE_BIOS     required  bbl64.bin (image manifest biosPath)
 *   FLOE_MC_BRIDGE_KERNEL   required  kernel-riscv64.bin (manifest kernelPath)
 *   FLOE_MC_BRIDGE_DISK     required  writable disk copy (raw image)
 *   FLOE_MC_BRIDGE_RAM      optional  guest RAM in MB (default 512)
 *   FLOE_MC_BRIDGE_VCPU     optional  1 (default) .. floe_vm_max_vcpu_count()
 *   FLOE_MC_BRIDGE_SHARE_DIR optional host directory exported as the guest's
 *                            /floe 9p share (the multiclient work root)
 *   FLOE_MC_BRIDGE_CMDLINE  optional  kernel cmdline override; the default
 *                            boots the image's own runner as PID 1 with the
 *                            image manifest's `console=hvc0 root=/dev/vda rw
 *                            loglevel=4` plus `init=/usr/local/bin/floe-exec`.
 *   FLOE_MC_BRIDGE_MAX_S    optional  hard wall bound in seconds (default 600)
 *
 * stdout carries only raw guest console bytes; diagnostics go to stderr.
 * The guest runner's boot log precedes its first frame and the production
 * channel parser ignores every non-frame byte, so the stream stays honest.
 * Input bytes that arrive before the runner is reading queue in the adapter's
 * console ring (partial writes are re-offered from an internal pending buffer
 * on later slices, never dropped).
 *
 * Usage: build with the qualification Makefile (HOST_DIR=... produces
 * mc_guest_bridge) or standalone:
 *   cc -O2 -I<repo>/FloeAgent/ThirdParty/TinyEMU/adapter -o mc_guest_bridge \
 *      mc_guest_bridge.c <build>/libfloevm.a -lpthread -lm
 */
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#include "floe_vm.h"

#define PENDING_MAX (1 << 20)
#define READ_CHUNK 16384

static FILE *diag;
static int stop_requested;

static void on_signal(int sig)
{
    (void)sig;
    stop_requested = 1;
}

static void on_console(void *opaque, const uint8_t *data, int len)
{
    (void)opaque;
    if (len > 0) {
        fwrite(data, 1, (size_t)len, stdout);
        fflush(stdout);
    }
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *env_or(const char *name, const char *fallback)
{
    const char *value = getenv(name);
    return (value && value[0]) ? value : fallback;
}

int main(void)
{
    FloeVMConfig cfg;
    FloeVM *vm;
    uint8_t pending[PENDING_MAX];
    size_t pending_len = 0;
    int vcpu, rc = 2;
    double max_s, start;
    const char *share_dir;

    diag = stderr;
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    memset(&cfg, 0, sizeof(cfg));
    cfg.bios_path = getenv("FLOE_MC_BRIDGE_BIOS");
    cfg.kernel_path = getenv("FLOE_MC_BRIDGE_KERNEL");
    cfg.disk_path = getenv("FLOE_MC_BRIDGE_DISK");
    if (!cfg.bios_path || !cfg.kernel_path || !cfg.disk_path) {
        fprintf(diag, "mc_guest_bridge: FLOE_MC_BRIDGE_BIOS/KERNEL/DISK are required\n");
        return 2;
    }
    cfg.ram_mb = (uint64_t)strtoul(env_or("FLOE_MC_BRIDGE_RAM", "512"), NULL, 10);
    cfg.disk_rw = 1;
    vcpu = (int)strtol(env_or("FLOE_MC_BRIDGE_VCPU", "1"), NULL, 10);
    if (vcpu < 0 || vcpu > floe_vm_max_vcpu_count()) {
        fprintf(diag, "mc_guest_bridge: vcpu %d out of range 0..%d\n",
                vcpu, floe_vm_max_vcpu_count());
        return 2;
    }
    cfg.vcpu_count = vcpu;
    cfg.cmdline = env_or("FLOE_MC_BRIDGE_CMDLINE",
                         "console=hvc0 root=/dev/vda rw loglevel=4 "
                         "init=/usr/local/bin/floe-exec");
    share_dir = getenv("FLOE_MC_BRIDGE_SHARE_DIR");
    if (share_dir && share_dir[0]) {
        cfg.shares[0].tag = "floe";
        cfg.shares[0].host_dir = share_dir;
        cfg.share_count = 1;
    }
    max_s = atof(env_or("FLOE_MC_BRIDGE_MAX_S", "600"));

    fprintf(diag, "mc_guest_bridge: engine=%s smp=%d max_vcpu=%d vcpu=%d ram=%lluMB share=%s\n",
            floe_vm_engine_version(), floe_vm_smp_capable(),
            floe_vm_max_vcpu_count(), vcpu,
            (unsigned long long)cfg.ram_mb, share_dir ? share_dir : "(none)");
    fflush(diag);

    vm = floe_vm_create(&cfg, on_console, NULL);
    if (!vm) {
        fprintf(diag, "mc_guest_bridge: floe_vm_create failed\n");
        return 2;
    }

    start = now_s();
    int stdin_open = 1;
    while (!stop_requested) {
        fd_set rfds;
        struct timeval tv = {0, 0};

        /* collect stdin bytes (non-blocking); a closed stdin ends the run */
        while (stdin_open) {
            FD_ZERO(&rfds);
            FD_SET(0, &rfds);
            tv.tv_sec = 0;
            tv.tv_usec = 0;
            if (select(1, &rfds, NULL, NULL, &tv) != 1)
                break;
            if (pending_len < sizeof(pending)) {
                ssize_t n = read(0, pending + pending_len, sizeof(pending) - pending_len);
                if (n > 0) {
                    pending_len += (size_t)n;
                } else if (n == 0) {
                    stdin_open = 0;
                } else if (errno != EAGAIN && errno != EINTR) {
                    stdin_open = 0;
                }
            } else {
                break; /* caller must drain first */
            }
        }

        /* offer as many pending bytes as the console ring accepts */
        if (pending_len > 0) {
            int queued = floe_vm_console_input(vm, pending, (int)pending_len);
            if (queued > 0) {
                memmove(pending, pending + queued, pending_len - (size_t)queued);
                pending_len -= (size_t)queued;
            }
        }

        rc = floe_vm_run_slice(vm, pending_len > 0 ? 0 : 5);
        if (rc == 1) {
            fprintf(diag, "mc_guest_bridge: guest requested poweroff\n");
            break;
        }
        if (rc < 0) {
            fprintf(diag, "mc_guest_bridge: run_slice fault %d\n", rc);
            break;
        }
        if (!stdin_open && pending_len == 0) {
            fprintf(diag, "mc_guest_bridge: stdin closed, exiting\n");
            break;
        }
        if (now_s() - start > max_s) {
            fprintf(diag, "mc_guest_bridge: max wall time %.0fs reached\n", max_s);
            rc = 3;
            break;
        }
    }

    floe_vm_destroy(vm);
    fprintf(diag, "mc_guest_bridge: destroyed (rc=%d)\n", rc);
    return rc == 1 ? 0 : rc;
}

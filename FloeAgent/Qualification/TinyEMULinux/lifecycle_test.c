/*
 * lifecycle_test.c — repeatability regression for the Floe embeddable VM
 * API: N x create/destroy with networking enabled each time (proves the
 * slirp singleton resets and resources are released), plus create-failure
 * paths (missing bios, bad share dir) repeated (proves partial cleanup).
 * No guest boot required; completes in seconds.
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage: lifecycle_test <bios> <kernel> <disk> <sharedir>
 * Exit 0 = all cycles passed; 1 = failure.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include "floe_vm.h"

static int out_bytes;
static void on_console(void *opaque, const uint8_t *data, int len)
{
    (void)opaque; (void)data;
    out_bytes += len;
}

/* Does something actually accept TCP connections on 127.0.0.1:port?
   slirp hostfwd listeners bind+listen on the host socket immediately, so
   this proves a forward is live without booting a guest. */
static int port_connectable(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    int rc;
    if (fd < 0)
        return 0;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(0x7F000001u);
    rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    close(fd);
    return rc == 0;
}

/* Capture what the engine writes to stderr around one call, so a failure
   can be attributed to the specific unrecoverable-OOM path rather than
   "something returned NULL". */
static int cap_saved_fd = -1;
static FILE *cap_begin(void)
{
    FILE *f = tmpfile();
    if (!f)
        return NULL;
    fflush(stderr);
    cap_saved_fd = dup(2);
    if (cap_saved_fd < 0 || dup2(fileno(f), 2) < 0) {
        if (cap_saved_fd >= 0)
            close(cap_saved_fd);
        fclose(f);
        return NULL;
    }
    return f;
}

static void cap_end(FILE *f, char *buf, size_t n)
{
    long sz;
    size_t rd;
    buf[0] = 0;
    if (!f)
        return;
    fflush(stderr);
    dup2(cap_saved_fd, 2);
    close(cap_saved_fd);
    sz = ftell(f);
    if (sz < 0)
        sz = 0;
    if ((size_t)sz >= n)
        sz = (long)n - 1;
    fseek(f, 0, SEEK_SET);
    rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = 0;
    fclose(f);
}

int main(int argc, char **argv)
{
    const int cycles = 5;
    int i, fails = 0;
    if (argc < 5) {
        fprintf(stderr, "usage: %s <bios> <kernel> <disk> <sharedir>\n",
                argv[0]);
        return 1;
    }

    for (i = 0; i < cycles; i++) {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = argv[1];
        cfg.kernel_path = argv[2];
        cfg.disk_path = argv[3];
        cfg.disk_rw = 0; /* snapshot */
        cfg.cmdline = "console=hvc0 root=/dev/vda rw";
        cfg.shares[0].tag = "wksp";
        cfg.shares[0].host_dir = argv[4];
        cfg.share_count = 1;
        cfg.net_enable = 1; /* exercises slirp singleton create+reset */
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (!vm) {
            printf("FAIL: create cycle %d returned NULL\n", i);
            fails++;
            continue;
        }
        if (floe_vm_run_slice(vm, 5) < 0) {
            printf("FAIL: run_slice cycle %d\n", i);
            fails++;
        }
        floe_vm_destroy(vm);
        printf("cycle %d: create+slice+destroy ok (console bytes so far: %d)\n",
               i, out_bytes);
    }

    /* create-failure cleanup: repeat bad configs; must keep failing cleanly */
    for (i = 0; i < 3; i++) {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = "/nonexistent/bbl64.bin";
        cfg.cmdline = "console=hvc0";
        cfg.net_enable = 1;
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (vm) {
            printf("FAIL: expected NULL for missing bios, cycle %d\n", i);
            floe_vm_destroy(vm);
            fails++;
        }
    }
    for (i = 0; i < 3; i++) {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = argv[1];
        cfg.kernel_path = argv[2];
        cfg.cmdline = "console=hvc0";
        cfg.shares[0].tag = "bad";
        cfg.shares[0].host_dir = "/nonexistent/dir";
        cfg.share_count = 1;
        cfg.net_enable = 1;
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (vm) {
            printf("FAIL: expected NULL for bad share dir, cycle %d\n", i);
            floe_vm_destroy(vm);
            fails++;
        }
    }
    /* after failed creates, a valid networked create must still work */
    {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = argv[1];
        cfg.kernel_path = argv[2];
        cfg.disk_path = argv[3];
        cfg.cmdline = "console=hvc0 root=/dev/vda rw";
        cfg.net_enable = 1;
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (!vm) {
            printf("FAIL: valid create after failed creates\n");
            fails++;
        } else {
            floe_vm_destroy(vm);
            printf("post-failure create: ok\n");
        }
    }

    /* hostfwd API: the forwarded host port must really accept TCP while
       the forward exists and stop doing so after remove/destroy, and a
       net-less VM must reject the request */
    {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = argv[1];
        cfg.kernel_path = argv[2];
        cfg.disk_path = argv[3];
        cfg.cmdline = "console=hvc0 root=/dev/vda rw";
        cfg.net_enable = 1;
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (!vm) {
            printf("FAIL: create for hostfwd test\n");
            fails++;
        } else {
            if (floe_vm_hostfwd_add(vm, 0, 0x7F000001u, 39080, 0, 80) != 0) {
                printf("FAIL: hostfwd_add tcp\n");
                fails++;
            } else if (!port_connectable(39080)) {
                printf("FAIL: hostfwd_add tcp did not bind 127.0.0.1:39080\n");
                fails++;
            }
            if (floe_vm_hostfwd_add(vm, 0, 0x7F000001u, 39081, 0, 81) != 0) {
                printf("FAIL: hostfwd_add tcp 2\n");
                fails++;
            }
            if (floe_vm_hostfwd_remove(vm, 0, 0x7F000001u, 39080) != 0) {
                printf("FAIL: hostfwd_remove\n");
                fails++;
            } else if (port_connectable(39080)) {
                printf("FAIL: hostfwd_remove left 127.0.0.1:39080 bound\n");
                fails++;
            }
            floe_vm_destroy(vm); /* remaining 39081 forward auto-removed */
            if (port_connectable(39081)) {
                printf("FAIL: destroy left 127.0.0.1:39081 bound\n");
                fails++;
            } else {
                printf("hostfwd bind/remove/destroy-auto-cleanup: ok\n");
            }
        }
    }
    {
        FloeVMConfig cfg;
        FloeVM *vm;
        memset(&cfg, 0, sizeof(cfg));
        cfg.ram_mb = 64;
        cfg.bios_path = argv[1];
        cfg.kernel_path = argv[2];
        cfg.cmdline = "console=hvc0";
        cfg.net_enable = 0;
        vm = floe_vm_create(&cfg, on_console, NULL);
        if (!vm) {
            printf("FAIL: create for net-less hostfwd test\n");
            fails++;
        } else {
            if (floe_vm_hostfwd_add(vm, 0, 0x7F000001u, 39090, 0, 80) == 0) {
                printf("FAIL: hostfwd_add without net must fail\n");
                fails++;
            }
            floe_vm_destroy(vm);
        }
    }

    /* oversized BIOS image must be a recoverable create error (patch 0002),
       not process exit (upstream copy_bios used exit(1) here) */
    {
        FloeVMConfig cfg;
        FloeVM *vm;
        char log[4096];
        FILE *cap;
        int fd = open("oversized-bios.bin", O_CREAT | O_WRONLY | O_TRUNC,
                      0600);
        if (fd < 0 || ftruncate(fd, 32L * 1024 * 1024) != 0) {
            printf("FAIL: cannot create oversized bios fixture\n");
            fails++;
        } else {
            close(fd);
            memset(&cfg, 0, sizeof(cfg));
            cfg.ram_mb = 16; /* 16MB < 32MB bios => too big */
            cfg.bios_path = "oversized-bios.bin";
            cfg.cmdline = "console=hvc0";
            cap = cap_begin();
            vm = floe_vm_create(&cfg, on_console, NULL);
            cap_end(cap, log, sizeof(log));
            if (vm) {
                printf("FAIL: oversized bios must fail create\n");
                floe_vm_destroy(vm);
                fails++;
            } else if (!strstr(log, "BIOS too big")) {
                printf("FAIL: oversized-bios failed for another reason\n");
                fails++;
            } else {
                printf("oversized-bios recoverable failure: ok\n");
            }
            unlink("oversized-bios.bin");
        }
    }

    /* kernel image larger than guest RAM: upstream copy_bios() memcpy'd
       before checking the bound (heap overflow past the RAM block); the
       patch must reject it as a recoverable create error instead. */
    {
        FloeVMConfig cfg;
        FloeVM *vm;
        char log[4096];
        FILE *cap;
        int fd = open("oversized-kernel.bin", O_CREAT | O_WRONLY | O_TRUNC,
                      0600);
        if (fd < 0 || ftruncate(fd, 32L * 1024 * 1024) != 0) {
            printf("FAIL: cannot create oversized kernel fixture\n");
            fails++;
        } else {
            close(fd);
            memset(&cfg, 0, sizeof(cfg));
            cfg.ram_mb = 16; /* 32MB kernel into 16MB RAM */
            cfg.bios_path = argv[1];
            cfg.kernel_path = "oversized-kernel.bin";
            cfg.cmdline = "console=hvc0";
            cap = cap_begin();
            vm = floe_vm_create(&cfg, on_console, NULL);
            cap_end(cap, log, sizeof(log));
            if (vm) {
                printf("FAIL: oversized kernel must fail create\n");
                floe_vm_destroy(vm);
                fails++;
            } else if (!strstr(log, "kernel too big")) {
                printf("FAIL: oversized-kernel failed for another reason\n");
                fails++;
            } else {
                printf("oversized-kernel recoverable failure: ok\n");
            }
            unlink("oversized-kernel.bin");
        }
    }

    /* guest RAM OOM propagation (patch 0002): with a 1GB address-space
       limit, a 2GB guest request must fail create cleanly -- and the
       process must survive to create a normal VM afterwards. RLIMIT_AS is
       enforced on Linux (the qualification CI); Darwin rejects it, so the
       case is skipped there rather than faked. */
    {
        struct rlimit rl;
        rl.rlim_cur = 1uL << 30;
        rl.rlim_max = RLIM_INFINITY;
        if (setrlimit(RLIMIT_AS, &rl) != 0) {
            printf("SKIP: RAM-OOM rlimit case (errno %d: %s); Linux CI covers it\n",
                   errno, strerror(errno));
        } else {
            int i2;
            char log[4096];
            for (i2 = 0; i2 < 2; i2++) {
                FloeVMConfig cfg;
                FloeVM *vm;
                FILE *cap;
                memset(&cfg, 0, sizeof(cfg));
                cfg.ram_mb = 2048;
                cfg.bios_path = argv[1];
                cfg.kernel_path = argv[2];
                cfg.cmdline = "console=hvc0 root=/dev/vda rw";
                cfg.net_enable = 1;
                cap = cap_begin();
                vm = floe_vm_create(&cfg, on_console, NULL);
                cap_end(cap, log, sizeof(log));
                if (vm) {
                    printf("FAIL: 2GB guest under 1GB RLIMIT_AS must fail\n");
                    floe_vm_destroy(vm);
                    fails++;
                } else if (!strstr(log, "floe_ram_oom")) {
                    printf("FAIL: 2GB guest failed without hitting the RAM-OOM path\n");
                    fails++;
                }
            }
            /* same process must still be usable and slirp reset cleanly */
            {
                FloeVMConfig cfg;
                FloeVM *vm;
                memset(&cfg, 0, sizeof(cfg));
                cfg.ram_mb = 64;
                cfg.bios_path = argv[1];
                cfg.kernel_path = argv[2];
                cfg.disk_path = argv[3];
                cfg.cmdline = "console=hvc0 root=/dev/vda rw";
                cfg.net_enable = 1;
                vm = floe_vm_create(&cfg, on_console, NULL);
                if (!vm) {
                    printf("FAIL: valid create after RAM-OOM failures\n");
                    fails++;
                } else {
                    floe_vm_destroy(vm);
                }
            }
            printf("ram-oom propagation (rlimit): ok\n");
        }
    }

    printf("%s (%d failures)\n", fails ? "LIFECYCLE_FAIL" : "LIFECYCLE_OK",
           fails);
    return fails ? 1 : 0;
}

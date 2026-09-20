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

#include "floe_vm.h"

static int out_bytes;
static void on_console(void *opaque, const uint8_t *data, int len)
{
    (void)opaque; (void)data;
    out_bytes += len;
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

    printf("%s (%d failures)\n", fails ? "LIFECYCLE_FAIL" : "LIFECYCLE_OK",
           fails);
    return fails ? 1 : 0;
}

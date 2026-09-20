/*
 * two_vm_test.c — focused native check for per-VM engine isolation: two
 * independent NETWORKED VMs are created (on the main thread), then driven
 * concurrently from two worker threads, each with its own slirp instance,
 * forwarding table and cleanup. The old adapter refused the second networked
 * VM ("only a single slirp instance is allowed") and the engine kept its
 * timers/DNS cache/select scratch in process-wide globals; with patch 0006
 * both VMs must run and each destroy must close only its own listeners.
 *
 * Phase 1 (always): synthetic tiny BIOS, no guest. Concurrent run_slice,
 * independent forwarding tables, independent destroy, create/destroy cycles,
 * create-on-worker-thread.
 *
 * Phase 2 (only when <bios> <kernel> <disk> are given): two REAL guests boot
 * concurrently on two threads, each writing through its own 9p share and
 * emitting its own console marker. Both markers must appear only on their
 * own VM's console and each file only in its own share directory.
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage: two_vm_test [bios kernel disk]
 * Exit 0 = all checks passed; 1 = failure.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include "floe_vm.h"

static int failures;
static int checks;

#define CHECK(cond, ...) do {                                            \
        checks++;                                                        \
        if (!(cond)) {                                                   \
            failures++;                                                  \
            printf("FAIL: ");                                            \
            printf(__VA_ARGS__);                                         \
            printf("\n");                                                \
        }                                                                \
    } while (0)

static char root_dir[4096];
static char bios_path[4096];
static char dir_a[4096];
static char dir_b[4096];
static int port_a, port_b, port_reuse;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

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

static int port_errno(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    int rc, err = 0;
    if (fd < 0)
        return -1;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(0x7F000001u);
    rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc != 0)
        err = errno;
    close(fd);
    return err;
}

/* The slirp host forward listener is created with listen(s, 1) and only
   accepts inside run_slice, so a second connect() without an accept gets
   ECONNRESET until the owning VM runs a slice. Drain with two slices after
   each probe so successive checks stay meaningful. */
static int vm_port_accepts(FloeVM *vm, int port)
{
    int ok = port_connectable(port);
    if (vm) {
        floe_vm_run_slice(vm, 1);
        floe_vm_run_slice(vm, 1);
    }
    return ok;
}

/* A port whose listener was really closed/removed refuses immediately
   (ECONNREFUSED). ECONNRESET means the listener still exists but its
   accept backlog is full (i.e. it belongs to a VM that is still alive). */
static int port_refused(int port)
{
    int err = port_errno(port);
    return err != 0 && err != ECONNRESET;
}

/* ask the host for a currently-free loopback TCP port; used to avoid
   clashing with whatever the test machine already listens on */
static int find_free_port(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    socklen_t alen = sizeof(a);
    int port = -1;
    if (fd < 0)
        return -1;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(0x7F000001u);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) == 0 &&
        getsockname(fd, (struct sockaddr *)&a, &alen) == 0)
        port = ntohs(a.sin_port);
    close(fd);
    return port;
}

/* create the synthetic BIOS fixture: any small blob satisfies copy_bios */
static int make_bios(const char *path)
{
    int fd;
    static uint8_t buf[16384];
    fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0)
        return -1;
    if (write(fd, buf, sizeof(buf)) != (ssize_t)sizeof(buf)) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

typedef struct {
    FloeVM *vm;
    int slices;              /* synthetic phase: slice count */
    int rc;
    int console_bytes;
    /* real-guest phase */
    int max_s;
    double send_at_s;
    int cmd_sent;
    char cmd[512];
    const char *marker;
    const char *forbidden;
    int marker_seen;
    int forbidden_seen;
    char tail[1024];
    int tail_len;
} Worker;

static void on_console(void *opaque, const uint8_t *data, int len)
{
    Worker *w = opaque;
    char window[2049];
    int wl;
    if (!w)
        return;
    w->console_bytes += len;
    if (getenv("TWOVM_DEBUG"))
        fwrite(data, 1, len, stderr);
    /* streaming contains-check with a 1KB carryover for chunk-split hits;
       each VM has its own Worker, so one VM's console can never satisfy the
       other VM's marker */
    wl = w->tail_len + len;
    if (wl > 2048)
        wl = 2048;
    memcpy(window, w->tail, w->tail_len);
    memcpy(window + w->tail_len, data, wl - w->tail_len);
    window[wl] = 0;
    if (w->marker && !w->marker_seen && strstr(window, w->marker))
        w->marker_seen = 1;
    if (w->forbidden && !w->forbidden_seen && strstr(window, w->forbidden))
        w->forbidden_seen = 1;
    w->tail_len = wl < 1024 ? wl : 1024;
    memcpy(w->tail, window + (wl - w->tail_len), w->tail_len);
}

static void *worker_main(void *arg)
{
    Worker *w = arg;
    int i;
    w->rc = 0;
    for (i = 0; i < w->slices; i++) {
        w->rc = floe_vm_run_slice(w->vm, 2);
        if (w->rc != 0)
            break;
    }
    return NULL;
}

/* real guest: feed one command after send_at_s and run until the VM's own
   marker appears, the guest powers off, an error occurs or max_s elapses */
static void *guest_worker(void *arg)
{
    Worker *w = arg;
    double start = now_s();
    w->rc = 0;
    while (now_s() - start < w->max_s) {
        double el = now_s() - start;
        int rc;
        if (!w->cmd_sent && el >= w->send_at_s) {
            floe_vm_console_input(w->vm, (const uint8_t *)w->cmd,
                                  (int)strlen(w->cmd));
            floe_vm_console_input(w->vm, (const uint8_t *)"\n", 1);
            w->cmd_sent = 1;
        }
        rc = floe_vm_run_slice(w->vm, 10);
        if (rc < 0) {
            w->rc = rc;
            break;
        }
        if (w->marker_seen)
            break;
        if (rc == 1)
            break;
    }
    return NULL;
}

static FloeVM *make_vm_tag(const char *share_dir, const char *tag, Worker *w,
                           const char *bios, const char *kernel,
                           const char *disk, int ram_mb)
{
    FloeVMConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.ram_mb = ram_mb;
    cfg.bios_path = bios;
    cfg.kernel_path = kernel;
    cfg.disk_path = disk;
    cfg.disk_rw = 0; /* snapshot: each VM keeps its own sector table */
    cfg.cmdline = "console=hvc0 root=/dev/vda rw";
    cfg.shares[0].tag = tag;
    cfg.shares[0].host_dir = share_dir;
    cfg.share_count = 1;
    cfg.net_enable = 1;
    return floe_vm_create(&cfg, on_console, w);
}

static FloeVM *make_vm(const char *share_dir, Worker *w,
                       const char *bios, const char *kernel,
                       const char *disk, int ram_mb)
{
    return make_vm_tag(share_dir, "wksp", w, bios, kernel, disk, ram_mb);
}

/* create + run + destroy a networked VM entirely from a worker thread */
typedef struct {
    const char *share;
    const char *bios;
    const char *kernel;
    const char *disk;
    int ok;
} Creator;

static void *create_run_destroy(void *arg)
{
    Creator *c = arg;
    Worker w;
    FloeVM *vm;
    memset(&w, 0, sizeof(w));
    vm = make_vm(c->share, &w, c->bios, NULL, NULL, 32);
    if (!vm) {
        c->ok = 0;
        return NULL;
    }
    w.vm = vm;
    w.slices = 40;
    worker_main(&w);
    c->ok = (w.rc == 0);
    floe_vm_destroy(vm);
    return NULL;
}

/* run two slice-storm workers; joins whatever was created */
static int run_pair(FloeVM *x, FloeVM *y, int slices)
{
    Worker wx, wy;
    pthread_t u1, u2;
    int c1, c2, ok = 1;
    memset(&wx, 0, sizeof(wx));
    memset(&wy, 0, sizeof(wy));
    wx.vm = x;
    wy.vm = y;
    wx.slices = slices;
    wy.slices = slices;
    c1 = pthread_create(&u1, NULL, worker_main, &wx);
    c2 = pthread_create(&u2, NULL, worker_main, &wy);
    if (c1 != 0 || c2 != 0)
        ok = 0;
    if (c1 == 0)
        pthread_join(u1, NULL);
    if (c2 == 0)
        pthread_join(u2, NULL);
    if (c1 == 0 && wx.rc != 0)
        ok = 0;
    if (c2 == 0 && wy.rc != 0)
        ok = 0;
    return ok;
}

static char *read_host_file(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "rb");
    size_t got;
    if (!f)
        return NULL;
    got = fread(buf, 1, n - 1, f);
    fclose(f);
    buf[got] = 0;
    return buf;
}

int main(int argc, char **argv)
{
    FloeVM *a, *b;
    Worker wa, wb;
    pthread_t t1, t2;
    int c1, c2;

    printf("== two networked VMs, two host threads (patch 0006 isolation) ==\n");

    snprintf(root_dir, sizeof(root_dir), "/tmp/floe_twovm_XXXXXX");
    if (!mkdtemp(root_dir)) {
        printf("FAIL: mkdtemp(%s): %s\n", root_dir, strerror(errno));
        return 2;
    }
    snprintf(bios_path, sizeof(bios_path), "%s/bios.bin", root_dir);
    snprintf(dir_a, sizeof(dir_a), "%s/share_a", root_dir);
    snprintf(dir_b, sizeof(dir_b), "%s/share_b", root_dir);
    if (make_bios(bios_path) != 0 || mkdir(dir_a, 0700) != 0 ||
        mkdir(dir_b, 0700) != 0) {
        printf("FAIL: cannot create fixtures under %s\n", root_dir);
        return 2;
    }
    port_a = find_free_port();
    port_b = find_free_port();
    port_reuse = port_a;
    if (port_a <= 0 || port_b <= 0 || port_a == port_b) {
        printf("FAIL: cannot reserve test ports (%d, %d)\n", port_a, port_b);
        return 2;
    }

    /* ---- both VMs exist at the same time (the old code refused #2) ---- */
    memset(&wa, 0, sizeof(wa));
    memset(&wb, 0, sizeof(wb));
    a = make_vm(dir_a, &wa, bios_path, NULL, NULL, 32);
    CHECK(a != NULL, "create VM A (networked)");
    b = make_vm(dir_b, &wb, bios_path, NULL, NULL, 32);
    CHECK(b != NULL, "create VM B while A is alive (per-VM slirp)");
    if (!a || !b) {
        if (a) floe_vm_destroy(a);
        if (b) floe_vm_destroy(b);
        printf("checks: %d, failures: %d\n", checks, failures);
        printf("TWO_VM_FAIL\n");
        return 1;
    }
    wa.vm = a;
    wb.vm = b;

    /* ---- independent forwarding tables + listeners ---- */
    CHECK(floe_vm_hostfwd_add(a, 0, 0x7F000001u, port_a, 0, 80) == 0,
          "hostfwd_add A:%d", port_a);
    CHECK(floe_vm_hostfwd_add(b, 0, 0x7F000001u, port_b, 0, 81) == 0,
          "hostfwd_add B:%d", port_b);
    CHECK(vm_port_accepts(a, port_a), "A listener %d not accepting", port_a);
    CHECK(vm_port_accepts(b, port_b), "B listener %d not accepting", port_b);

    /* ---- run both VMs concurrently on separate host threads ---- */
    wa.slices = 200;
    wb.slices = 200;
    c1 = pthread_create(&t1, NULL, worker_main, &wa);
    c2 = pthread_create(&t2, NULL, worker_main, &wb);
    CHECK(c1 == 0 && c2 == 0, "pthread_create for VM workers");
    if (c1 == 0)
        pthread_join(t1, NULL);
    if (c2 == 0)
        pthread_join(t2, NULL);
    CHECK(c1 == 0 && wa.rc == 0,
          "VM A run_slice rc=%d (must be 0 after 200 slices)", wa.rc);
    CHECK(c2 == 0 && wb.rc == 0,
          "VM B run_slice rc=%d (must be 0 after 200 slices)", wb.rc);
    CHECK(floe_vm_poweroff_requested(a) == 0 &&
          floe_vm_poweroff_requested(b) == 0, "unexpected poweroff flag");

    /* listeners survive the concurrent run */
    CHECK(vm_port_accepts(a, port_a), "A listener lost during concurrent run");
    CHECK(vm_port_accepts(b, port_b), "B listener lost during concurrent run");

    /* ---- destroying A must close only A's listeners and state ---- */
    floe_vm_destroy(a);
    a = NULL;
    CHECK(port_refused(port_a), "A destroy left %d bound", port_a);
    CHECK(vm_port_accepts(b, port_b), "A destroy closed B's listener %d",
          port_b);
    CHECK(floe_vm_hostfwd_add(b, 0, 0x7F000001u, port_reuse, 0, 80) == 0,
          "B cannot reuse the port A released (A slirp not cleaned)");
    CHECK(vm_port_accepts(b, port_reuse), "B listener %d not accepting",
          port_reuse);
    CHECK(floe_vm_hostfwd_remove(b, 0, 0x7F000001u, port_reuse) == 0 &&
          port_refused(port_reuse), "B hostfwd_remove %d", port_reuse);
    floe_vm_destroy(b);
    b = NULL;
    CHECK(port_refused(port_b), "B destroy left %d bound", port_b);

    /* ---- lifecycle stress: repeated create/run/destroy cycles ---- */
    {
        int cycle, bad = 0;
        for (cycle = 0; cycle < 3; cycle++) {
            FloeVM *x, *y;
            x = make_vm(dir_a, NULL, bios_path, NULL, NULL, 32);
            y = make_vm(dir_b, NULL, bios_path, NULL, NULL, 32);
            if (!x || !y) {
                bad++;
                if (x) floe_vm_destroy(x);
                if (y) floe_vm_destroy(y);
                continue;
            }
            if (floe_vm_hostfwd_add(x, 0, 0x7F000001u, port_a, 0, 80) != 0 ||
                floe_vm_hostfwd_add(y, 0, 0x7F000001u, port_b, 0, 81) != 0)
                bad++;
            if (!run_pair(x, y, 30))
                bad++;
            floe_vm_destroy(x);
            floe_vm_destroy(y);
        }
        CHECK(bad == 0, "3 create/run/destroy cycles: %d problems", bad);
        CHECK(port_refused(port_a) && port_refused(port_b),
              "forwarded ports leaked across destroy cycles");
    }

    /* ---- create on a worker thread, not the main thread ---- */
    {
        pthread_t d1, d2;
        Creator ca, cb;
        int r1, r2;
        memset(&ca, 0, sizeof(ca));
        memset(&cb, 0, sizeof(cb));
        ca.share = dir_a;
        ca.bios = bios_path;
        ca.ok = -1;
        cb.share = dir_b;
        cb.bios = bios_path;
        cb.ok = -1;
        r1 = pthread_create(&d1, NULL, create_run_destroy, &ca);
        r2 = pthread_create(&d2, NULL, create_run_destroy, &cb);
        CHECK(r1 == 0 && r2 == 0, "pthread_create for creator threads");
        if (r1 == 0)
            pthread_join(d1, NULL);
        if (r2 == 0)
            pthread_join(d2, NULL);
        CHECK(ca.ok == 1, "worker-thread create/run/destroy (A) failed");
        CHECK(cb.ok == 1, "worker-thread create/run/destroy (B) failed");
    }

    /* ---- optional phase 2: two real guests booting concurrently ---- */
    if (argc >= 4) {
        Worker ga, gb;
        pthread_t g1, g2;
        int r1, r2;
        char pa[4096], pb[4096];
        memset(&ga, 0, sizeof(ga));
        memset(&gb, 0, sizeof(gb));
        printf("== real guests: two concurrent boots, own console + own share ==\n");
        ga.marker = "FLOE_TWOVM_A_OK";
        ga.forbidden = "FLOE_TWOVM_B_OK";
        gb.marker = "FLOE_TWOVM_B_OK";
        gb.forbidden = "FLOE_TWOVM_A_OK";
        ga.send_at_s = gb.send_at_s = 8.0;
        ga.max_s = gb.max_s = 90;
        /* markers are assembled at run time by the guest shell; the echoed
           input line contains the literal %s, never the OK marker */
        snprintf(ga.cmd, sizeof(ga.cmd),
                 "mount -t 9p -o trans=virtio,version=9p2000.L /dev/root /mnt"
                 " && echo A > /mnt/two_vm_a.txt"
                 " && printf 'FLOE_TWOVM_A_%%s\\n' OK");
        snprintf(gb.cmd, sizeof(gb.cmd),
                 "mount -t 9p -o trans=virtio,version=9p2000.L /dev/root /mnt"
                 " && echo B > /mnt/two_vm_b.txt"
                 " && printf 'FLOE_TWOVM_B_%%s\\n' OK");
        /* the 2018 demo guest mounts its 9p share as /dev/root (see
           run_local_smoke.sh / the guest /etc/fstab), so use that tag */
        ga.vm = make_vm_tag(dir_a, "/dev/root", &ga, argv[1], argv[2],
                            argv[3], 128);
        gb.vm = make_vm_tag(dir_b, "/dev/root", &gb, argv[1], argv[2],
                            argv[3], 128);
        CHECK(ga.vm != NULL && gb.vm != NULL, "create two real-guest VMs");
        if (ga.vm && gb.vm) {
            r1 = pthread_create(&g1, NULL, guest_worker, &ga);
            r2 = pthread_create(&g2, NULL, guest_worker, &gb);
            CHECK(r1 == 0 && r2 == 0, "pthread_create for guest workers");
            if (r1 == 0)
                pthread_join(g1, NULL);
            if (r2 == 0)
                pthread_join(g2, NULL);
            CHECK(ga.marker_seen && ga.rc == 0,
                  "VM A real-guest marker (console bytes %d)",
                  ga.console_bytes);
            CHECK(gb.marker_seen && gb.rc == 0,
                  "VM B real-guest marker (console bytes %d)",
                  gb.console_bytes);
            CHECK(!ga.forbidden_seen && !gb.forbidden_seen,
                  "console output crossed between VMs");
            snprintf(pa, sizeof(pa), "%s/two_vm_a.txt", dir_a);
            snprintf(pb, sizeof(pb), "%s/two_vm_b.txt", dir_b);
            {
                char ca[256], cb[256];
                CHECK(read_host_file(pa, ca, sizeof(ca)) && ca[0] == 'A',
                      "A wrote its own 9p share (%s)",
                      ca[0] ? ca : "(missing)");
                CHECK(read_host_file(pb, cb, sizeof(cb)) && cb[0] == 'B',
                      "B wrote its own 9p share (%s)",
                      cb[0] ? cb : "(missing)");
                snprintf(pa, sizeof(pa), "%s/two_vm_a.txt", dir_b);
                snprintf(pb, sizeof(pb), "%s/two_vm_b.txt", dir_a);
                CHECK(access(pa, F_OK) != 0, "A's file leaked into B's share");
                CHECK(access(pb, F_OK) != 0, "B's file leaked into A's share");
            }
        }
        if (ga.vm)
            floe_vm_destroy(ga.vm);
        if (gb.vm)
            floe_vm_destroy(gb.vm);
    } else {
        printf("note: pass <bios> <kernel> <disk> to also boot two real guests\n");
    }

    printf("checks: %d, failures: %d\n", checks, failures);
    printf("%s\n", failures ? "TWO_VM_FAIL" : "TWO_VM_OK");
    return failures ? 1 : 0;
}

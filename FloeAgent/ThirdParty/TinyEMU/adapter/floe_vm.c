/*
 * floe_vm.c — Floe embeddable VM adapter over the TinyEMU 2019-12-21 (MIT)
 * RISC-V full-system emulator core.
 *
 * Copyright (c) 2026 Floe contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * The file-backed BlockDevice and the slirp EthernetDevice glue below are
 * adapted from temu.c of TinyEMU 2019-12-21, Copyright (c) 2016-2018
 * Fabrice Bellard, used under the MIT License (see MIT-LICENSE.txt in the
 * pinned source tree). They are re-hosted here because temu.c carries the
 * CLI main() and cannot be linked into an embeddable library.
 *
 * No GPL code is used: this is not a QEMU/iSH derivative.
 */

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <unistd.h>
#include <netinet/in.h>

#include "cutils.h"
#include "iomem.h"
#include "virtio.h" /* also brings in unguarded fs.h — do not include fs.h directly */
#include "machine.h"
#include "riscv_cpu.h" /* FLOE-SMP: per-hart cycle/power stats */
#include "floe_vm.h"

#ifdef CONFIG_SLIRP
#include "slirp/libslirp.h"
#endif

/* provided by the patched riscv_machine.c (see
 * patches/0001-htif-poweroff-callback.patch) */
int riscv_machine_poweroff_requested(VirtMachine *s);

#define FLOE_MAX_EXEC_CYCLE 500000
#define FLOE_MAX_SLEEP_TIME 10 /* ms */
#define FLOE_INPUT_RING     65536

/*******************************************************/
/* file-backed block device (adapted from temu.c, MIT) */

typedef enum {
    BF_MODE_RO,
    BF_MODE_RW,
    BF_MODE_SNAPSHOT,
} BlockDeviceModeEnum;

#define SECTOR_SIZE 512

typedef struct BlockDeviceFile {
    FILE *f;
    int64_t nb_sectors;
    BlockDeviceModeEnum mode;
    uint8_t **sector_table;
} BlockDeviceFile;

static int64_t bf_get_sector_count(BlockDevice *bs)
{
    BlockDeviceFile *bf = bs->opaque;
    return bf->nb_sectors;
}

static int bf_read_async(BlockDevice *bs,
                         uint64_t sector_num, uint8_t *buf, int n,
                         BlockDeviceCompletionFunc *cb, void *opaque)
{
    BlockDeviceFile *bf = bs->opaque;
    (void)cb; (void)opaque;
    if (!bf->f)
        return -1;
    if (bf->mode == BF_MODE_SNAPSHOT) {
        int i;
        for(i = 0; i < n; i++) {
            if (!bf->sector_table[sector_num]) {
                fseek(bf->f, sector_num * SECTOR_SIZE, SEEK_SET);
                fread(buf, 1, SECTOR_SIZE, bf->f);
            } else {
                memcpy(buf, bf->sector_table[sector_num], SECTOR_SIZE);
            }
            sector_num++;
            buf += SECTOR_SIZE;
        }
    } else {
        fseek(bf->f, sector_num * SECTOR_SIZE, SEEK_SET);
        fread(buf, 1, n * SECTOR_SIZE, bf->f);
    }
    /* synchronous read */
    return 0;
}

static int bf_write_async(BlockDevice *bs,
                          uint64_t sector_num, const uint8_t *buf, int n,
                          BlockDeviceCompletionFunc *cb, void *opaque)
{
    BlockDeviceFile *bf = bs->opaque;
    int ret;
    (void)cb; (void)opaque;

    switch(bf->mode) {
    case BF_MODE_RO:
        ret = -1;
        break;
    case BF_MODE_RW:
        fseek(bf->f, sector_num * SECTOR_SIZE, SEEK_SET);
        fwrite(buf, 1, n * SECTOR_SIZE, bf->f);
        fflush(bf->f);
        ret = 0;
        break;
    case BF_MODE_SNAPSHOT:
        {
            int i;
            if ((sector_num + n) > bf->nb_sectors)
                return -1;
            for(i = 0; i < n; i++) {
                if (!bf->sector_table[sector_num]) {
                    bf->sector_table[sector_num] = malloc(SECTOR_SIZE);
                    if (!bf->sector_table[sector_num])
                        return -1;
                }
                memcpy(bf->sector_table[sector_num], buf, SECTOR_SIZE);
                sector_num++;
                buf += SECTOR_SIZE;
            }
            ret = 0;
        }
        break;
    default:
        abort();
    }
    return ret;
}

static BlockDevice *floe_block_device_init(const char *filename,
                                           BlockDeviceModeEnum mode)
{
    BlockDevice *bs;
    BlockDeviceFile *bf;
    int64_t file_size;
    FILE *f;
    const char *mode_str;

    if (mode == BF_MODE_RW) {
        mode_str = "r+b";
    } else {
        mode_str = "rb";
    }
    f = fopen(filename, mode_str);
    if (!f) {
        perror(filename);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    file_size = ftello(f);

    bs = mallocz(sizeof(*bs));
    bf = mallocz(sizeof(*bf));
    if (!bs || !bf) {
        free(bs);
        free(bf);
        fclose(f);
        return NULL;
    }
    bf->mode = mode;
    bf->nb_sectors = file_size / SECTOR_SIZE;
    bf->f = f;
    if (mode == BF_MODE_SNAPSHOT) {
        bf->sector_table = mallocz(sizeof(bf->sector_table[0]) *
                                   bf->nb_sectors);
        if (!bf->sector_table) {
            free(bf);
            free(bs);
            fclose(f);
            return NULL;
        }
    }
    bs->get_sector_count = bf_get_sector_count;
    bs->read_async = bf_read_async;
    bs->write_async = bf_write_async;
    bs->opaque = bf;
    return bs;
}

static void floe_block_device_destroy(BlockDevice *bs)
{
    BlockDeviceFile *bf;
    int64_t i;
    if (!bs)
        return;
    bf = bs->opaque;
    if (bf) {
        if (bf->f)
            fclose(bf->f);
        if (bf->sector_table) {
            for (i = 0; i < bf->nb_sectors; i++)
                free(bf->sector_table[i]);
            free(bf->sector_table);
        }
        free(bf);
    }
    free(bs);
}

/*******************************************************/
/* slirp user-mode networking glue (adapted from temu.c, MIT) */

#ifdef CONFIG_SLIRP
static void floe_slirp_write_packet(EthernetDevice *net,
                                    const uint8_t *buf, int len)
{
    Slirp *slirp_state = net->opaque;
    slirp_input(slirp_state, buf, len);
}

/* required by libslirp.h: */
int slirp_can_output(void *opaque)
{
    EthernetDevice *net = opaque;
    return net->device_can_write_packet(net);
}

void slirp_output(void *opaque, const uint8_t *pkt, int pkt_len)
{
    EthernetDevice *net = opaque;
    net->device_write_packet(net, pkt, pkt_len);
}

static void floe_slirp_select_fill1(EthernetDevice *net, int *pfd_max,
                                    fd_set *rfds, fd_set *wfds, fd_set *efds,
                                    int *pdelay)
{
    Slirp *slirp_state = net->opaque;
    slirp_select_fill(slirp_state, pfd_max, rfds, wfds, efds);
    (void)pdelay;
}

static void floe_slirp_select_poll1(EthernetDevice *net,
                                    fd_set *rfds, fd_set *wfds, fd_set *efds,
                                    int select_ret)
{
    Slirp *slirp_state = net->opaque;
    slirp_select_poll(slirp_state, rfds, wfds, efds, (select_ret <= 0));
}

/* One slirp instance per VM (patch 0006 moved the former process-wide
   timers/DNS cache/select scratch into struct Slirp). Two networked VMs can
   therefore be created and run on two host threads at the same time; each
   one gets its own virtual network and forwarding table. */
static EthernetDevice *floe_slirp_open(Slirp **pslirp)
{
    EthernetDevice *net;
    struct in_addr net_addr = { .s_addr = htonl(0x0a000200) }; /* 10.0.2.0 */
    struct in_addr mask     = { .s_addr = htonl(0xffffff00) }; /* /24 */
    struct in_addr host     = { .s_addr = htonl(0x0a000202) }; /* 10.0.2.2 */
    struct in_addr dhcp     = { .s_addr = htonl(0x0a00020f) }; /* 10.0.2.15 */
    struct in_addr dns      = { .s_addr = htonl(0x0a000203) }; /* 10.0.2.3 */

    net = mallocz(sizeof(*net));
    if (!net)
        return NULL;
    *pslirp = slirp_init(0, net_addr, mask, host, NULL,
                         "", NULL, dhcp, dns, net);
    if (!*pslirp) {
        free(net);
        return NULL;
    }
    /* Each VM has its own slirp network, so the fixed MAC cannot collide
       with another VM's; keep the upstream 52:55:... special-address style
       for the host side by using a stable per-VM guest MAC. */
    net->mac_addr[0] = 0x02;
    net->mac_addr[1] = 0x00;
    net->mac_addr[2] = 0x00;
    net->mac_addr[3] = 0x00;
    net->mac_addr[4] = 0x00;
    net->mac_addr[5] = 0x01;
    net->opaque = *pslirp;
    net->write_packet = floe_slirp_write_packet;
    net->select_fill = floe_slirp_select_fill1;
    net->select_poll = floe_slirp_select_poll1;
    return net;
}

static void floe_slirp_close(EthernetDevice *net)
{
    if (!net)
        return;
    slirp_cleanup(net->opaque);
    free(net);
}
#endif /* CONFIG_SLIRP */

/*******************************************************/
/* console character device backed by callbacks + input ring */

typedef struct {
    FloeVMConsoleOutFn out_fn;
    void *out_opaque;
    pthread_mutex_t lock;
    uint8_t ring[FLOE_INPUT_RING];
    int rd, wr; /* bytes in ring = (wr - rd) mod FLOE_INPUT_RING */
} FloeConsole;

static void floe_console_write(void *opaque, const uint8_t *buf, int len)
{
    FloeConsole *c = opaque;
    if (c->out_fn)
        c->out_fn(c->out_opaque, buf, len);
}

/* virtio console device pulls guest input through here */
static int floe_console_read(void *opaque, uint8_t *buf, int len)
{
    FloeConsole *c = opaque;
    int n = 0;
    pthread_mutex_lock(&c->lock);
    while (n < len && c->rd != c->wr) {
        buf[n++] = c->ring[c->rd];
        c->rd = (c->rd + 1) % FLOE_INPUT_RING;
    }
    pthread_mutex_unlock(&c->lock);
    return n;
}

/*******************************************************/
/* FloeVM */

struct FloeVM {
    VirtMachine *m;
    VirtMachineParams p;
    FloeConsole console;
    CharacterDevice console_dev;
    BlockDevice *disk;
    FSDevice *shares[FLOE_VM_MAX_SHARES];
    int share_opened;
    /* Serializes run_slice/destroy/hostfwd per VM. Different VMs have
       different locks, so two VMs (networked or not) run concurrently.
       Independent from console.lock (console input may be queued from any
       thread at any time). */
    pthread_mutex_t api_lock;
    /* cache for the lock-free poweroff query (updated under api_lock) */
    int poweroff_seen;
    /* FLOE-SMP: hart count (1 or 2). With 2, every hart is driven by its
       own host thread (hart_thread[i]) through the hart_bar slice
       barrier: run_slice publishes one generation with a cycle budget,
       both harts interpret concurrently, the slice ends when every hart
       checked back in. Hart threads never touch api_lock and never run
       outside a published slice. */
    int vcpu_count;
    int hart_threads_spawned;
    pthread_t hart_thread[FLOE_VM_MAX_VCPU];
    struct {
        FloeVM *vm;
        int idx;
    } hart_arg[FLOE_VM_MAX_VCPU];
    struct {
        pthread_mutex_t lock;
        pthread_cond_t cond;
        unsigned generation;
        int pending; /* harts not yet checked in for this generation */
        int stop;
        int budget;
    } hart_bar;
#ifdef CONFIG_SLIRP
    EthernetDevice *net;
    Slirp *slirp; /* this VM's own instance (patch 0006) */
    struct { int is_udp; uint32_t host_ipv4; int host_port; }
        hostfwds[FLOE_VM_MAX_HOSTFWD];
    int hostfwd_count;
#endif
};

/* FLOE-SMP: one host thread per hart (only spawned when vcpu_count == 2).
 * The thread interprets its hart for the published budget, then checks
 * back in; it blocks on the barrier condvar between slices and exits on
 * stop (set by floe_vm_destroy before it joins the threads). */
static void *floe_hart_thread(void *arg)
{
    struct {
        FloeVM *vm;
        int idx;
    } *ha = arg;
    FloeVM *vm = ha->vm;
    unsigned seen_gen = 0;
    int idx = ha->idx;
    for (;;) {
        int budget;
        pthread_mutex_lock(&vm->hart_bar.lock);
        while (!vm->hart_bar.stop && vm->hart_bar.generation == seen_gen)
            pthread_cond_wait(&vm->hart_bar.cond, &vm->hart_bar.lock);
        if (vm->hart_bar.stop) {
            pthread_mutex_unlock(&vm->hart_bar.lock);
            break;
        }
        seen_gen = vm->hart_bar.generation;
        budget = vm->hart_bar.budget;
        pthread_mutex_unlock(&vm->hart_bar.lock);

        virt_machine_interp_cpu(vm->m, idx, budget);

        pthread_mutex_lock(&vm->hart_bar.lock);
        if (--vm->hart_bar.pending == 0)
            pthread_cond_broadcast(&vm->hart_bar.cond);
        pthread_mutex_unlock(&vm->hart_bar.lock);
    }
    return NULL;
}

/* FLOE-SMP: stop and join every hart thread. Called with api_lock held
 * (so no slice is in flight) BEFORE virt_machine_end and before any disk
 * FILE handle is closed. */
static void floe_vm_stop_hart_threads(FloeVM *vm)
{
    int i;
    if (!vm->hart_threads_spawned)
        return;
    pthread_mutex_lock(&vm->hart_bar.lock);
    vm->hart_bar.stop = 1;
    pthread_cond_broadcast(&vm->hart_bar.cond);
    pthread_mutex_unlock(&vm->hart_bar.lock);
    for (i = 0; i < vm->vcpu_count; i++)
        pthread_join(vm->hart_thread[i], NULL);
    vm->hart_threads_spawned = 0;
}

/* Free everything the adapter itself allocated (partial state allowed).
 * The VirtMachine, if created, is ended separately by the caller. */
static void floe_vm_free_resources(FloeVM *vm)
{
    int i;
    floe_block_device_destroy(vm->disk);
    vm->disk = NULL;
    for (i = 0; i < vm->share_opened; i++) {
        if (vm->shares[i])
            fs_end(vm->shares[i]); /* upstream: fs_disk_end + free(fs) */
        free(vm->p.tab_fs[i].tag);
        vm->shares[i] = NULL;
        vm->p.tab_fs[i].tag = NULL;
    }
    vm->share_opened = 0;
#ifdef CONFIG_SLIRP
    /* remove adapter-registered forwards first (closes their listening
       fds; upstream slirp_cleanup does not close them). This touches only
       this VM's slirp instance. */
    if (vm->net && vm->slirp) {
        for (i = 0; i < vm->hostfwd_count; i++) {
            struct in_addr ha = { .s_addr = htonl(vm->hostfwds[i].host_ipv4) };
            slirp_remove_hostfwd(vm->slirp, vm->hostfwds[i].is_udp,
                                 ha, vm->hostfwds[i].host_port);
        }
        vm->hostfwd_count = 0;
    }
    floe_slirp_close(vm->net);
    vm->net = NULL;
    vm->slirp = NULL;
#endif
    free(vm->p.files[VM_FILE_BIOS].buf);
    free(vm->p.files[VM_FILE_KERNEL].buf);
    free(vm->p.files[VM_FILE_INITRD].buf);
    vm->p.files[VM_FILE_BIOS].buf = NULL;
    vm->p.files[VM_FILE_KERNEL].buf = NULL;
    vm->p.files[VM_FILE_INITRD].buf = NULL;
    free(vm->p.machine_name);
    free(vm->p.cmdline);
    vm->p.machine_name = NULL;
    vm->p.cmdline = NULL;
}

static uint8_t *floe_load_file(const char *path, int *plen)
{
    FILE *f = fopen(path, "rb");
    uint8_t *buf;
    long size;
    if (!f) {
        perror(path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || size > (1L << 30)) {
        fclose(f);
        return NULL;
    }
    buf = malloc(size);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, size, f) != (size_t)size) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *plen = (int)size;
    return buf;
}

FloeVM *floe_vm_create(const FloeVMConfig *cfg,
                       FloeVMConsoleOutFn out_fn, void *out_opaque)
{
    FloeVM *vm;
    VirtMachineParams *p;
    int i;

    if (!cfg || !cfg->bios_path || cfg->ram_mb == 0) {
        fprintf(stderr, "floe_vm: bios_path and ram_mb are required\n");
        return NULL;
    }
    /* resource-budget backstop only; the engine itself propagates malloc
       failure as a recoverable create error (patch 0002) */
    if (cfg->ram_mb > (1u << 20)) {
        fprintf(stderr, "floe_vm: ram_mb=%llu exceeds 1TB backstop\n",
                (unsigned long long)cfg->ram_mb);
        return NULL;
    }
    /* FLOE-SMP: 0/1 = single hart (default), 2 = dual hart. */
    if (cfg->vcpu_count < 0 || cfg->vcpu_count > FLOE_VM_MAX_VCPU) {
        fprintf(stderr, "floe_vm: vcpu_count=%d not supported (max %d)\n",
                cfg->vcpu_count, FLOE_VM_MAX_VCPU);
        return NULL;
    }

    vm = mallocz(sizeof(*vm));
    if (!vm)
        return NULL;
    vm->vcpu_count = cfg->vcpu_count > 1 ? cfg->vcpu_count : 1;
    /* Per-VM locks. Nothing here is thread-local: create may run on the
       main thread while run_slice runs later on a worker thread. */
    pthread_mutex_init(&vm->console.lock, NULL);
    pthread_mutex_init(&vm->api_lock, NULL);
    vm->console.out_fn = out_fn;
    vm->console.out_opaque = out_opaque;
    vm->console_dev.opaque = &vm->console;
    vm->console_dev.write_data = floe_console_write;
    vm->console_dev.read_data = floe_console_read;

    p = &vm->p;
    virt_machine_set_defaults(p);
    p->vmc = &riscv_machine_class;
    p->machine_name = strdup("riscv64");
    p->ram_size = cfg->ram_mb << 20;
    p->rtc_real_time = TRUE;
    p->console = &vm->console_dev;
    p->vcpu_count = vm->vcpu_count;
    if (cfg->cmdline)
        p->cmdline = strdup(cfg->cmdline);

    p->files[VM_FILE_BIOS].buf = floe_load_file(cfg->bios_path,
                                                &p->files[VM_FILE_BIOS].len);
    if (!p->files[VM_FILE_BIOS].buf) {
        fprintf(stderr, "floe_vm: cannot load bios %s\n", cfg->bios_path);
        goto fail;
    }
    if (cfg->kernel_path) {
        p->files[VM_FILE_KERNEL].buf =
            floe_load_file(cfg->kernel_path, &p->files[VM_FILE_KERNEL].len);
        if (!p->files[VM_FILE_KERNEL].buf)
            goto fail;
    }
    if (cfg->initrd_path) {
        p->files[VM_FILE_INITRD].buf =
            floe_load_file(cfg->initrd_path, &p->files[VM_FILE_INITRD].len);
        if (!p->files[VM_FILE_INITRD].buf)
            goto fail;
    }

    if (cfg->disk_path) {
        vm->disk = floe_block_device_init(cfg->disk_path,
                                          cfg->disk_rw ? BF_MODE_RW
                                                       : BF_MODE_SNAPSHOT);
        if (!vm->disk)
            goto fail;
        p->tab_drive[0].block_dev = vm->disk;
        p->drive_count = 1;
    }

    for (i = 0; i < cfg->share_count && i < FLOE_VM_MAX_SHARES; i++) {
        FSDevice *fs = fs_disk_init(cfg->shares[i].host_dir);
        if (!fs) {
            fprintf(stderr, "floe_vm: %s: not a directory\n",
                    cfg->shares[i].host_dir);
            goto fail;
        }
        p->tab_fs[p->fs_count].tag = strdup(cfg->shares[i].tag);
        if (!p->tab_fs[p->fs_count].tag) {
            fs_end(fs);
            goto fail;
        }
        p->tab_fs[p->fs_count].fs_dev = fs;
        p->fs_count++;
        vm->shares[vm->share_opened] = fs;
        vm->share_opened++;
    }

#ifdef CONFIG_SLIRP
    if (cfg->net_enable) {
        vm->net = floe_slirp_open(&vm->slirp);
        if (!vm->net)
            goto fail;
        p->tab_eth[0].driver = "user";
        p->tab_eth[0].net = vm->net;
        p->eth_count = 1;
    }
#endif

    vm->m = virt_machine_init(p);
    if (!vm->m) {
        fprintf(stderr, "floe_vm: machine init failed\n");
        goto fail;
    }

    /* FLOE-SMP: spawn one host thread per hart for a dual-hart VM. The
       threads park on the barrier condvar until the first run_slice
       publishes a generation; destroy stops and joins them before ending
       the machine. */
    if (vm->vcpu_count > 1) {
        pthread_mutex_init(&vm->hart_bar.lock, NULL);
        pthread_cond_init(&vm->hart_bar.cond, NULL);
        vm->hart_bar.generation = 0;
        vm->hart_bar.pending = 0;
        vm->hart_bar.stop = 0;
        for (i = 0; i < vm->vcpu_count; i++) {
            vm->hart_arg[i].vm = vm;
            vm->hart_arg[i].idx = i;
            if (pthread_create(&vm->hart_thread[i], NULL, floe_hart_thread,
                               &vm->hart_arg[i]) != 0) {
                fprintf(stderr, "floe_vm: cannot spawn hart thread %d\n", i);
                /* stop and join the already-spawned threads, then tear
                   the machine down through the common fail path */
                pthread_mutex_lock(&vm->hart_bar.lock);
                vm->hart_bar.stop = 1;
                pthread_cond_broadcast(&vm->hart_bar.cond);
                pthread_mutex_unlock(&vm->hart_bar.lock);
                while (--i >= 0)
                    pthread_join(vm->hart_thread[i], NULL);
                pthread_mutex_destroy(&vm->hart_bar.lock);
                pthread_cond_destroy(&vm->hart_bar.cond);
                virt_machine_end(vm->m);
                vm->m = NULL;
                goto fail;
            }
        }
        vm->hart_threads_spawned = 1;
    }

    if (vm->m->net)
        vm->m->net->device_set_carrier(vm->m->net, TRUE);
    __atomic_store_n(&vm->poweroff_seen, 0, __ATOMIC_RELAXED);
    return vm;

 fail:
    fprintf(stderr, "floe_vm: create failed\n");
    floe_vm_free_resources(vm); /* symmetric partial cleanup */
    pthread_mutex_destroy(&vm->console.lock);
    pthread_mutex_destroy(&vm->api_lock);
    free(vm);
    return NULL;
}

int floe_vm_console_input(FloeVM *vm, const uint8_t *data, int len)
{
    FloeConsole *c;
    int n = 0;
    if (!vm || !data || len <= 0)
        return -1;
    c = &vm->console;
    pthread_mutex_lock(&c->lock);
    while (n < len) {
        int next = (c->wr + 1) % FLOE_INPUT_RING;
        if (next == c->rd)
            break; /* ring full: drop remainder, caller may retry */
        c->ring[c->wr] = data[n++];
        c->wr = next;
    }
    pthread_mutex_unlock(&c->lock);
    return n;
}

int floe_vm_run_slice(FloeVM *vm, int timeout_ms)
{
    fd_set rfds, wfds, efds;
    int fd_max, ret, delay, rc;
    struct timeval tv;
    VirtMachine *m;

    if (!vm)
        return -1;
    /* Serializes this VM against destroy/hostfwd calls from other threads;
       other VMs use their own locks and run concurrently. */
    pthread_mutex_lock(&vm->api_lock);
    if (!vm->m) {
        pthread_mutex_unlock(&vm->api_lock);
        return -1;
    }
    m = vm->m;
    if (riscv_machine_poweroff_requested(m)) {
        __atomic_store_n(&vm->poweroff_seen, 1, __ATOMIC_RELAXED);
        pthread_mutex_unlock(&vm->api_lock);
        return 1;
    }

    if (timeout_ms < 0 || timeout_ms > FLOE_MAX_SLEEP_TIME)
        timeout_ms = FLOE_MAX_SLEEP_TIME;
    delay = virt_machine_get_sleep_duration(m, timeout_ms);

    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    FD_ZERO(&efds);
    fd_max = -1;
    if (m->net)
        m->net->select_fill(m->net, &fd_max, &rfds, &wfds, &efds, &delay);
    if (delay > timeout_ms)
        delay = timeout_ms;
    if (delay < 0)
        delay = 0;
    tv.tv_sec = delay / 1000;
    tv.tv_usec = (delay % 1000) * 1000;
    ret = select(fd_max + 1, &rfds, &wfds, &efds, &tv);
    /* a failed select (other than EINTR, which is a valid wakeup) is a
       recoverable host fault: surface it after giving slirp its poll */
    rc = 0;
    if (ret < 0 && errno != EINTR)
        rc = -1;
    if (m->net)
        m->net->select_poll(m->net, &rfds, &wfds, &efds, ret);

    /* deliver queued console input while the device accepts it */
    if (m->console_dev && virtio_console_can_write_data(m->console_dev)) {
        uint8_t buf[512];
        int len = virtio_console_get_write_len(m->console_dev);
        int got;
        len = len < (int)sizeof(buf) ? len : (int)sizeof(buf);
        got = floe_console_read(&vm->console, buf, len);
        if (got > 0)
            virtio_console_write_data(m->console_dev, buf, got);
    }

    if (rc == 0) {
        if (vm->hart_threads_spawned) {
            /* FLOE-SMP: publish one slice generation and wait until every
               hart checked back in. Hart threads interpret concurrently
               on their own host threads; RAM/devices are shared, guest
               atomics and device MMIO are serialized inside the engine. */
            pthread_mutex_lock(&vm->hart_bar.lock);
            vm->hart_bar.pending = vm->vcpu_count;
            vm->hart_bar.budget = FLOE_MAX_EXEC_CYCLE;
            vm->hart_bar.generation++;
            pthread_cond_broadcast(&vm->hart_bar.cond);
            while (vm->hart_bar.pending > 0)
                pthread_cond_wait(&vm->hart_bar.cond, &vm->hart_bar.lock);
            pthread_mutex_unlock(&vm->hart_bar.lock);
        } else {
            virt_machine_interp(m, FLOE_MAX_EXEC_CYCLE);
        }
        rc = riscv_machine_poweroff_requested(m) ? 1 : 0;
        if (rc == 1)
            __atomic_store_n(&vm->poweroff_seen, 1, __ATOMIC_RELAXED);
    }
    pthread_mutex_unlock(&vm->api_lock);
    return rc;
}

int floe_vm_poweroff_requested(const FloeVM *vm)
{
    if (!vm)
        return 0;
    /* lock-free by design: run_slice updates this cache under api_lock, so
       a controller thread may poll it without blocking the VM thread */
    return __atomic_load_n(&((FloeVM *)vm)->poweroff_seen, __ATOMIC_RELAXED);
}

int floe_vm_hostfwd_add(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                        int host_port, uint32_t guest_ipv4, int guest_port)
{
#ifdef CONFIG_SLIRP
    struct in_addr ha, ga;
    int rc;
    if (!vm || !vm->net || !vm->slirp)
        return -1;
    if (host_port <= 0 || host_port > 65535 || guest_port <= 0 ||
        guest_port > 65535)
        return -1;
    ha.s_addr = htonl(host_ipv4);
    ga.s_addr = htonl(guest_ipv4);
    pthread_mutex_lock(&vm->api_lock);
    if (vm->hostfwd_count >= FLOE_VM_MAX_HOSTFWD) {
        rc = -1;
    } else if (slirp_add_hostfwd(vm->slirp, is_udp, ha, host_port,
                                 ga, guest_port) < 0) {
        rc = -1;
    } else {
        vm->hostfwds[vm->hostfwd_count].is_udp = is_udp;
        vm->hostfwds[vm->hostfwd_count].host_ipv4 = host_ipv4;
        vm->hostfwds[vm->hostfwd_count].host_port = host_port;
        vm->hostfwd_count++;
        rc = 0;
    }
    pthread_mutex_unlock(&vm->api_lock);
    return rc;
#else
    (void)vm; (void)is_udp; (void)host_ipv4; (void)host_port;
    (void)guest_ipv4; (void)guest_port;
    return -1;
#endif
}

int floe_vm_hostfwd_remove(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                           int host_port)
{
#ifdef CONFIG_SLIRP
    struct in_addr ha;
    int i, rc;
    if (!vm || !vm->net || !vm->slirp)
        return -1;
    ha.s_addr = htonl(host_ipv4);
    pthread_mutex_lock(&vm->api_lock);
    if (slirp_remove_hostfwd(vm->slirp, is_udp, ha, host_port) < 0) {
        rc = -1;
    } else {
        for (i = 0; i < vm->hostfwd_count; i++) {
            if (vm->hostfwds[i].is_udp == is_udp &&
                vm->hostfwds[i].host_ipv4 == host_ipv4 &&
                vm->hostfwds[i].host_port == host_port) {
                vm->hostfwds[i] = vm->hostfwds[vm->hostfwd_count - 1];
                vm->hostfwd_count--;
                break;
            }
        }
        rc = 0;
    }
    pthread_mutex_unlock(&vm->api_lock);
    return rc;
#else
    (void)vm; (void)is_udp; (void)host_ipv4; (void)host_port;
    return -1;
#endif
}

void floe_vm_destroy(FloeVM *vm)
{
    if (!vm)
        return;
    /* Waits for an in-flight run_slice on this VM to return, then ends the
     * machine (frees CPU state + guest RAM + machine struct). Upstream
     * note: virtio device structs (a few hundred bytes each) are not
     * individually freed by TinyEMU's riscv_machine_end; that is an
     * upstream process-exit design. All adapter-owned resources (disk FILE
     * handles + snapshot tables, per-VM 9p devices + tags, this VM's slirp
     * instance and its forwarding sockets, file buffers) are released
     * below. Other VMs are unaffected. Do not call this from the console
     * output callback: that runs inside run_slice on the same thread and
     * the api_lock is not recursive. */
    pthread_mutex_lock(&vm->api_lock);
    /* FLOE-SMP: stop and join every hart thread BEFORE ending the machine
       (they interpret machine state) and before floe_vm_free_resources
       closes the disk FILE handles. */
    floe_vm_stop_hart_threads(vm);
    if (vm->vcpu_count > 1) {
        /* the barrier was initialized at create when vcpu_count > 1 */
        pthread_mutex_destroy(&vm->hart_bar.lock);
        pthread_cond_destroy(&vm->hart_bar.cond);
    }
    if (vm->m) {
        virt_machine_end(vm->m);
        vm->m = NULL;
    }
    floe_vm_free_resources(vm);
    pthread_mutex_unlock(&vm->api_lock);
    pthread_mutex_destroy(&vm->api_lock);
    pthread_mutex_destroy(&vm->console.lock);
    free(vm);
}

int floe_vm_max_vcpu_count(void)
{
    return FLOE_VM_MAX_VCPU;
}

int floe_vm_smp_capable(void)
{
    /* This adapter and the engine are built from one source revision;
       the per-hart machine hooks exist whenever this adapter links. */
    return 1;
}

int floe_vm_get_stats(FloeVM *vm, FloeVMStats *out)
{
    int i, n;
    if (!vm || !out)
        return -1;
    memset(out, 0, sizeof(*out));
    /* Sampling contract: api_lock serializes the snapshot against
       run_slice/destroy (same discipline as hostfwd_add/remove), so the
       machine and per-hart CPU states stay alive and consistent for the
       whole read; the wait is bounded by one in-flight slice. The
       per-hart counters themselves are read with engine atomics
       (retired-insn counter and power-down flag are __atomic fields).
       Callable from any thread while the VM is alive; NOT from the
       console output callback (that runs inside run_slice holding
       api_lock), and the caller must hold its own reference to the VM
       (a lock cannot fix use-after-destroy). */
    pthread_mutex_lock(&vm->api_lock);
    out->vcpu_count = vm->vcpu_count;
    out->host_threads = vm->hart_threads_spawned ? vm->vcpu_count : 0;
    if (vm->m && vm->m->vmc->virt_machine_get_cpu_count) {
        n = vm->m->vmc->virt_machine_get_cpu_count(vm->m);
        for (i = 0; i < n && i < FLOE_VM_MAX_VCPU; i++) {
            RISCVCPUState *cpu = vm->m->vmc->virt_machine_get_cpu(vm->m, i);
            if (cpu) {
                out->hart_insns[i] = riscv_cpu_get_cycles(cpu);
                out->hart_powered_down[i] =
                    riscv_cpu_get_power_down(cpu) ? 1 : 0;
            }
        }
    }
    pthread_mutex_unlock(&vm->api_lock);
    return 0;
}

const char *floe_vm_engine_version(void)
{
    return "tinyemu-2019-12-21";
}

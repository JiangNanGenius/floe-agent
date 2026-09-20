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
    bf->mode = mode;
    bf->nb_sectors = file_size / SECTOR_SIZE;
    bf->f = f;
    if (mode == BF_MODE_SNAPSHOT) {
        bf->sector_table = mallocz(sizeof(bf->sector_table[0]) *
                                   bf->nb_sectors);
    }
    bs->get_sector_count = bf_get_sector_count;
    bs->read_async = bf_read_async;
    bs->write_async = bf_write_async;
    bs->opaque = bf;
    return bs;
}

/*******************************************************/
/* slirp user-mode networking glue (adapted from temu.c, MIT) */

#ifdef CONFIG_SLIRP
static Slirp *floe_slirp_state;

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

static EthernetDevice *floe_slirp_open(void)
{
    EthernetDevice *net;
    struct in_addr net_addr = { .s_addr = htonl(0x0a000200) }; /* 10.0.2.0 */
    struct in_addr mask     = { .s_addr = htonl(0xffffff00) }; /* /24 */
    struct in_addr host     = { .s_addr = htonl(0x0a000202) }; /* 10.0.2.2 */
    struct in_addr dhcp     = { .s_addr = htonl(0x0a00020f) }; /* 10.0.2.15 */
    struct in_addr dns      = { .s_addr = htonl(0x0a000203) }; /* 10.0.2.3 */

    if (floe_slirp_state) {
        fprintf(stderr, "floe_vm: only a single slirp instance is allowed\n");
        return NULL;
    }
    net = mallocz(sizeof(*net));
    floe_slirp_state = slirp_init(0, net_addr, mask, host, NULL,
                                  "", NULL, dhcp, dns, net);
    net->mac_addr[0] = 0x02;
    net->mac_addr[1] = 0x00;
    net->mac_addr[2] = 0x00;
    net->mac_addr[3] = 0x00;
    net->mac_addr[4] = 0x00;
    net->mac_addr[5] = 0x01;
    net->opaque = floe_slirp_state;
    net->write_packet = floe_slirp_write_packet;
    net->select_fill = floe_slirp_select_fill1;
    net->select_poll = floe_slirp_select_poll1;
    return net;
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
#ifdef CONFIG_SLIRP
    EthernetDevice *net;
#endif
};

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

    vm = mallocz(sizeof(*vm));
    pthread_mutex_init(&vm->console.lock, NULL);
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
    if (cfg->cmdline)
        p->cmdline = strdup(cfg->cmdline);

    p->files[VM_FILE_BIOS].buf = floe_load_file(cfg->bios_path,
                                                &p->files[VM_FILE_BIOS].len);
    if (!p->files[VM_FILE_BIOS].buf)
        goto fail;
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
        p->tab_fs[p->fs_count].fs_dev = fs;
        p->fs_count++;
    }

#ifdef CONFIG_SLIRP
    if (cfg->net_enable) {
        vm->net = floe_slirp_open();
        if (!vm->net)
            goto fail;
        p->tab_eth[0].driver = "user";
        p->tab_eth[0].net = vm->net;
        p->eth_count = 1;
    }
#endif

    vm->m = virt_machine_init(p);
    if (!vm->m)
        goto fail;

    if (vm->m->net)
        vm->m->net->device_set_carrier(vm->m->net, TRUE);
    return vm;

 fail:
    fprintf(stderr, "floe_vm: create failed\n");
    /* conservative cleanup for the qualification prototype */
    free(vm->p.files[VM_FILE_BIOS].buf);
    free(vm->p.files[VM_FILE_KERNEL].buf);
    free(vm->p.files[VM_FILE_INITRD].buf);
    pthread_mutex_destroy(&vm->console.lock);
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
    int fd_max, ret, delay;
    struct timeval tv;
    VirtMachine *m;

    if (!vm || !vm->m)
        return -1;
    m = vm->m;
    if (riscv_machine_poweroff_requested(m))
        return 1;

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

    virt_machine_interp(m, FLOE_MAX_EXEC_CYCLE);
    return riscv_machine_poweroff_requested(m) ? 1 : 0;
}

int floe_vm_poweroff_requested(const FloeVM *vm)
{
    if (!vm || !vm->m)
        return 0;
    return riscv_machine_poweroff_requested(vm->m);
}

void floe_vm_destroy(FloeVM *vm)
{
    if (!vm)
        return;
    if (vm->m)
        virt_machine_end(vm->m);
    free(vm->p.files[VM_FILE_BIOS].buf);
    free(vm->p.files[VM_FILE_KERNEL].buf);
    free(vm->p.files[VM_FILE_INITRD].buf);
    free(vm->p.machine_name);
    free(vm->p.cmdline);
    pthread_mutex_destroy(&vm->console.lock);
    free(vm);
}

const char *floe_vm_engine_version(void)
{
    return "tinyemu-2019-12-21";
}

/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* Machine: physical memory bus (RAM + flash + MMIO devices). */
#ifndef A64_MACHINE_H
#define A64_MACHINE_H

#include "types.h"
#include "cpu.h"
#include "console.h"
#include "memory_sync.h"
#include <stdatomic.h>
struct MachineParallelOps;
struct MachineParallelPollView;

/* Default platform constants (QEMU 'virt', GICv2). */
#define FLASH_BASE   0x00000000ULL
#define FLASH_SIZE   0x08000000ULL   /* 128 MB: 64 MB code + 64 MB vars */
#define FLASH_BANK   0x04000000ULL   /* 64 MB per bank */
#define RAM_BASE     0x40000000ULL
#define RAM_SIZE_DEF (1024ULL << 20) /* 1 GB default */

/* Memory abort reporting from the bus (unmapped access). */
typedef enum { BUS_OK = 0, BUS_FAULT = 1 } BusStatus;

typedef u64  (*mmio_read_fn)(void *opaque, u64 offset, unsigned size);
typedef void (*mmio_write_fn)(void *opaque, u64 offset, unsigned size, u64 value);

typedef struct {
    u64 base, size;
    mmio_read_fn read;
    mmio_write_fn write;
    void *opaque;
    const char *name;
} MMIODev;

#define MAX_DEVS 48
/* Max attachable disks. Ceiling is the 31 non-net virtio-mmio slots (slot 0 is
 * reserved for virtio-net); 8 is plenty and keeps the Machine arrays small. */
#define MAX_DRIVES 8
/* Max host directory shares (virtio-9p). Same 31-slot ceiling shared with disks
 * (net=slot 0, then disks, then shares); 8 keeps the Machine arrays small. */
#define MAX_SHARES 8
/* Max virtio-console devices, each a separate guest tty (hvc0, hvc1, ...).
 * Nine = one supervisor control console (hvc0) + one data console per project
 * (hvc1..hvc8, FLOE_MAX_PROJECTS == 8 in the guest supervisor contract). The
 * hard ceilings are elsewhere and higher — the same 31 virtio-mmio slots, and
 * Linux's MAX_NR_HVC_CONSOLES of 16. The equality with FLOE_AE_MAX_CONSOLES
 * is asserted in Bridge/embedded_internal.h, which sees both headers. */
#define MAX_CONSOLES 9

struct GIC;
struct PL011;
struct PL031;
struct FwCfg;
struct ARMTimer;
struct VirtIOBlk;
struct VirtIONet;
struct VirtIO9P;
struct VirtIOConsole;

typedef struct NetFwd {
    bool is_udp;
    int  host_port;
    int  guest_port;
} NetFwd;

/* A -virtfs host directory share: exported to the guest as a virtio-9p device
 * with mount tag `tag`; `ro` maps the whole tree read-only. guest_uid/gid are
 * the synthetic ids the guest sees (never forwarded to a host chown). */
typedef struct VirtFS {
    const char *path;   /* host directory to export, or NULL for a detached slot */
    const char *tag;    /* 9p mount tag (guest `mount -t 9p <tag> ...`) */
    bool        ro;     /* read-only share */
    uint32_t    guest_uid;
    uint32_t    guest_gid;
} VirtFS;

/* A -drive disk: backing image `path`; `ro` opens it O_RDONLY and advertises
 * VIRTIO_BLK_F_RO so the guest mounts it read-only and writes are rejected. */
typedef struct Drive {
    const char *path;   /* host image file */
    bool        ro;     /* read-only disk */
} Drive;

typedef struct Machine {
    struct MemorySync *memory_sync;
    const struct MachineParallelOps *parallel_ops;
    void *parallel_owner;
    CPU cpu;                     /* hart0 retained for existing component fixtures */
    CPU secondary[A64_MAX_CPUS-1];
    unsigned ncpus,next_hart;     /* immutable possible topology; fair RR cursor */
    CPU *bus_cpu;                /* legacy serial fixture slot; active bus uses TLS */
    CPU *executing_cpu;          /* serial debug counter compatibility; workers use TLS */
    u64 quantum_icount,clock_epoch_ns,counter_hz;
    _Atomic u64 virtual_ticks; /* aggregate completed work, readable by workers */
    _Atomic bool system_off,system_reset; /* Machine state, distinct from per-hart OFF */
    u64 boot_dtb_placements;      /* create/system-reset only, never CPU hotplug */
    _Atomic int host_error; /* construction/board failure, propagated through C ABI */

    u8 *ram;  u64 ram_base, ram_size;
    u8 *flash; u64 flash_base, flash_size;
    bool flash_writable;          /* simple RAM-backed flash writes (CFI added later) */

    /* NOR flash CFI (Intel pflash_cfi01) state, per 64 MB bank. EDK2 keeps its
     * UEFI variable store in the flash and drives it with the Intel command set
     * (read-id/CFI, block erase, word/buffer program, status polling). */
    struct FlashCFI {
        u8  mode;       /* read mode: array/status/id/cfi */
        u8  prog;       /* program/erase phase state machine */
        u8  status;     /* status register (0x80 = ready) */
        u32 buf_base;   /* buffered-program base offset */
        u32 buf_cnt;    /* buffered-program word count */
        u32 buf_seen;   /* buffered words written so far */
    } flash_cfi[2];

    MMIODev dev[MAX_DEVS];
    int ndev;

    /* Device instances (owned). */
    struct GIC      *gic;
    struct ARMTimer *timer;
    struct PL011    *uart;
    struct PL031    *rtc;
    struct FwCfg    *fwcfg;
    struct VirtIOBlk *blk[MAX_DRIVES];  /* attached disks, in attach order */
    int    n_blk;
    struct VirtIONet *net;
    struct VirtIO9P  *fs[MAX_SHARES];   /* attached 9p shares, in attach order */
    int    n_fs;
    struct VirtIOConsole *vcon[MAX_CONSOLES];  /* hvc0..hvc(n_vcon-1) */
    int    n_vcon;

    /* Host console endpoints (console.h): where each console device's bytes
     * actually go. NULL means the process terminal, which is what a plain
     * command-line run wants and what every console shares there. --console-fd
     * binds one to an inherited descriptor instead, which is how an embedding
     * process gives each guest tty its own channel. */
    ConsoleEP *uart_ep;                 /* PL011 (ttyAMA0) */
    ConsoleEP *vcon_ep[MAX_CONSOLES];   /* hvc0..hvc(n_vcon-1) */
    ConsoleCtrl *ctrl;                  /* --ctrl-fd: host control channel */

    Drive  drives[MAX_DRIVES];   /* -drive disks */
    int    n_drives;
    VirtFS shares[MAX_SHARES];    /* -virtfs host directory shares */
    int    n_shares;
    bool net_enabled;             /* -net flag */
    bool console_virtio;          /* --console virtio: the guest console is hvc0
                                   * (default false = pl011/ttyAMA0) */
    int  n_consoles_req;          /* --console ...,count=N: virtio-consoles to
                                   * create. 0 means the default for the mode */
    bool console_active_virtio;   /* input follows output: true once hvc0 (not
                                   * ttyAMA0) last produced output; routes host
                                   * stdin to the console the guest is actually
                                   * using. Only consulted when two consoles
                                   * share the process terminal — an endpoint of
                                   * its own needs no arbitration. */
    NetFwd net_fwds[16];          /* -netfwd rules */
    int    n_net_fwds;
    uint32_t dns_server;          /* host-order IPv4 resolver relay target,
                                   * 0 = probe the host resolver at runtime */

    u64 io_poll_due;              /* icount at which machine_tick next runs the
                                   * host-IO polls (UART/console read, net poll);
                                   * 0 forces a poll on the next tick */

    BusStatus last_bus_status;    /* set by phys_* on fault */

    bool deadlock;                /* set by machine_wait_for_event when the CPU
                                   * halted (WFI/WFE) with no wake source that
                                   * could ever exist: no armed timer, no
                                   * pending IRQ, and no device able to raise
                                   * one. The run can only spin from here, and
                                   * --max-insn cannot fire because a halted CPU
                                   * retires nothing, so the loop stops and
                                   * dumps instead. */
} Machine;

static inline CPU *machine_cpu(Machine *m,unsigned i) {
    return i==0 ? &m->cpu : i<m->ncpus ? &m->secondary[i-1] : NULL;
}
/* Bus scope/status are thread-local. Legacy mirrors are updated only while
 * workers are quiescent; a DMA scope never inherits an accessing PE. */
CPU *machine_bus_cpu(Machine *m);
BusStatus machine_bus_status(Machine *m);
void machine_bus_set_status(Machine *m,BusStatus status);
void machine_owner_yield(Machine *m);
CPUPower machine_hart_power(Machine *m,unsigned hart);
void machine_set_irq(Machine *m,unsigned hart,bool level);
bool machine_parallel_poll(CPU *c);
const struct MachineParallelPollView *machine_parallel_poll_view(CPU *c);
void machine_barrier(CPU *c,unsigned kind);
void machine_tlbi(CPU *c,u64 va,bool page);
int machine_configure_cpus(Machine *m,unsigned count);
void machine_clock_reset(Machine *m);
void machine_send_event(Machine *m,CPU *local);
void machine_store_notify(Machine *m,u64 pa,u64 length);

void machine_init(Machine *m, u64 ram_size);
void machine_free(Machine *m);

/* Return the NOR flash CFI command state machine to read-array/ready (reset). */
void flash_cfi_reset(Machine *m);
void machine_add_device(Machine *m, u64 base, u64 size, mmio_read_fn r,
                        mmio_write_fn w, void *opaque, const char *name);

/* Physical memory access. On unmapped access, sets m->last_bus_status=BUS_FAULT
 * and returns 0 (reads) / ignores (writes). `size` is 1,2,4,8. */
u64  phys_read(Machine *m, u64 pa, unsigned size);
void phys_write(Machine *m, u64 pa, unsigned size, u64 value);
u64 phys_read_cpu(CPU *c,u64 pa,unsigned size);
void phys_write_cpu(CPU *c,u64 pa,unsigned size,u64 value);

/* Bulk copy helpers (used by loaders / fw_cfg DMA). Truncated to mapped RAM. */
void phys_write_blk(Machine *m, u64 pa, const void *src, u64 len);
void phys_read_blk(Machine *m, u64 pa, void *dst, u64 len);

/* Direct host pointer into RAM for [pa, pa+len), or NULL if out of range. */
void *ram_ptr(Machine *m, u64 pa, u64 len);

#endif /* A64_MACHINE_H */

/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Platform wiring: instantiate virt devices, place the DTB, load the kernel
 * via fw_cfg, and drive timer/UART events for the run loop. */
#include "devices.h"
#include "machine.h"
#include "fdt/fdt.h"
#include "fdt/smp_dtb.h"
#include "boot_entropy.h"
#include <stdio.h>
#include <stdlib.h>
#include <poll.h>
#include <unistd.h>

/* Stub MMIO: probed-but-unimplemented devices (virtio/pcie/gpio). Reads return
 * a fixed "absent" value so firmware/OS detect no device instead of faulting. */
static u64 stub_zero_read(void *o, u64 off, unsigned size) { return 0; }
static u64 stub_ones_read(void *o, u64 off, unsigned size) {
    return size >= 8 ? ~0ULL : ((1ULL << (size * 8)) - 1);
}
static void stub_write(void *o, u64 off, unsigned size, u64 v) { (void)o; (void)off; (void)size; (void)v; }

/* Empty virtio-mmio transport: QEMU's 'virt' instantiates 32 transport slots
 * (stride 0x200) even with no backend. An empty slot still answers the probe
 * registers with magic="virt", version=1 (legacy), DeviceID=0 (no device),
 * VendorID="QEMU"; the firmware/OS then skips it. Returning 0 here (as the old
 * stub did) makes firmware believe the transport is absent and take a divergent
 * path. We model the slots as empty (no device) until virtio-blk lands (M6). */
static u64 virtio_mmio_read(void *o, u64 off, unsigned size) {
    (void)o; (void)size;
    switch (off & 0x1ff) {            /* register within the 0x200-byte slot */
        case 0x000: return 0x74726976; /* VIRTIO_MMIO_MAGIC_VALUE "virt" */
        case 0x004: return 0x1;        /* VIRTIO_MMIO_VERSION (legacy)   */
        case 0x008: return 0x0;        /* VIRTIO_MMIO_DEVICE_ID = none    */
        case 0x00c: return 0x554d4551; /* VIRTIO_MMIO_VENDOR_ID "QEMU"    */
        default:    return 0;
    }
}

static int place_board_dtb(Machine *m) {
    switch(m->ncpus){
    case 1:return qualification_place_boot_dtb(m,smp_dtb_1,sizeof(smp_dtb_1));
    case 2:return qualification_place_boot_dtb(m,smp_dtb_2,sizeof(smp_dtb_2));
    case 3:return qualification_place_boot_dtb(m,smp_dtb_3,sizeof(smp_dtb_3));
    case 4:return qualification_place_boot_dtb(m,smp_dtb_4,sizeof(smp_dtb_4));
    case 5:return qualification_place_boot_dtb(m,smp_dtb_5,sizeof(smp_dtb_5));
    default:return -8; /* no clamping or fabricated topology */
    }
}

int platform_build(Machine *m) {
    if(m->net_enabled||m->n_shares||m->n_consoles_req)return -8;
    if (!gic_create(m)) return -6;
    if (!gtimer_create(m)) return -6;
    if (!pl011_create(m,m->gic)) return -6;
    if (!pl031_create(m,m->gic)) return -6;
    if (!fwcfg_create(m) || !fwcfg_valid(m->fwcfg)) return -6;

    /* GICv2m MSI frame: advertised in the device tree but not emulated. Returning
     * 0 for MSI_TYPER makes Linux's is_msi_spi_valid() fail gracefully, so the
     * kernel boots without MSI (virtio-mmio uses wired SPIs); an unmapped read
     * here would instead fault and panic early init. */
    machine_add_device(m, 0x08020000, 0x1000,       stub_zero_read, stub_write, m, "gicv2m");

    /* Absent-device stubs covering the QEMU 'virt' regions we don't model. */
    machine_add_device(m, 0x09030000, 0x1000,       stub_zero_read, stub_write, m, "gpio-stub");

    /* virtio-mmio: 32 slots (0x0a000000–0x0a003fff, stride 0x200).
     * Slot 0 is reserved for virtio-net (-net); disks (-drive) take slots
     * 1..n_drives; host shares (-virtfs) take the next slots. Numbering is
     * deterministic regardless of which devices are present.
     * Real devices must be registered before any stub that covers their range
     * because find_dev uses first-match dispatch — so a device at slot 2+ shadows
     * the catch-all stub below for its own 0x200 window.
     * Unoccupied slots get empty-transport stubs (DeviceID=0). */
    if (m->n_drives + m->n_shares + m->n_consoles_req > 31) {   /* net=slot0, then disks, shares, consoles */
        fprintf(stderr, "too many virtio-mmio devices (%d disks + %d shares + "
                        "%d consoles > 31 slots)\n",
                m->n_drives, m->n_shares, m->n_consoles_req);
        return -1;
    }
    if (m->net_enabled) virtio_net_create(m, m->gic);
    for (int i = 0; i < m->n_drives; i++)
        if (!virtio_blk_create(m,m->gic,m->drives[i].path,m->drives[i].ro,i+1)) return -5;  /* slots 1..n_drives */
    for (int i = 0; i < m->n_shares; i++)                    /* slots after disks  */
        virtio_9p_create(m, m->gic, m->shares[i].path, m->shares[i].tag,
                         m->shares[i].ro, m->n_drives + 1 + i);
    for (int i = 0; i < m->n_consoles_req; i++)              /* slots after disks + shares */
        virtio_console_create(m, m->gic, 1 + m->n_drives + m->n_shares + i);
    if (!m->net_enabled) machine_add_device(m, 0x0a000000, 0x200, virtio_mmio_read, stub_write, m, "virtio-mmio");
    /* Slot 1 (0x0a000200) is stubbed only when nothing real occupies it — no
     * disk, no share, and (when there are neither) no virtio-console either. */
    if (m->n_drives == 0 && m->n_shares == 0 && m->n_consoles_req == 0) machine_add_device(m, 0x0a000200, 0x200, virtio_mmio_read, stub_write, m, "virtio-mmio");
    machine_add_device(m, 0x0a000400, 0x3c00, virtio_mmio_read, stub_write, m, "virtio-mmio");
    machine_add_device(m, 0x3eff0000, 0x10000,      stub_ones_read, stub_write, m, "pcie-pio");
    machine_add_device(m, 0x10000000, 0x2eff0000,   stub_ones_read, stub_write, m, "pcie-mmio");
    machine_add_device(m, 0x4010000000ULL, 0x10000000, stub_ones_read, stub_write, m, "pcie-ecam");

    /* The global template stays unchanged. Each boot gets a private, sized
     * tree and fresh Apple CSPRNG input before firmware can execute. */
    if (place_board_dtb(m)) return -5;
    return m->host_error;
}

void machine_reset(Machine *m, u64 entry, unsigned reset_el) {
    /* PSCI SYSTEM_RESET (warm reboot). Return every device to power-on state and
     * restart the boot CPU without tearing down host-backed resources: the NOR
     * flash (UEFI variable store), fw_cfg payloads, open -drive images and the
     * usernet backend all persist across the reboot, matching real hardware.
     * virtio-blk/9p need no explicit reset here — the rebooting firmware/OS
     * resets each through the virtio STATUS=0 probe handshake before first use;
     * virtio-net is quiesced because it is polled in the background. */
    if (m->gic)   gic_reset(m->gic);
    if (m->uart)  pl011_reset(m->uart);
    if (m->rtc)   pl031_reset(m->rtc);
    if (m->fwcfg) fwcfg_reset(m->fwcfg);
    if (m->net)   virtio_net_reset(m->net);
    for (int i = 0; i < m->n_vcon; i++)
        virtio_console_reset(m->vcon[i]);          /* background-polled: quiesce explicitly */
    flash_cfi_reset(m);

    /* Re-place the flattened device tree at the base of RAM (EDK2 reads it from
     * PcdDeviceTreeInitialBaseAddress): the previous OS reused that memory. Only
     * when a platform was actually built — a raw -bin run has no fw_cfg/DTB. */
    if (m->fwcfg && place_board_dtb(m)) { m->host_error=-5;return; }

    machine_clock_reset(m);m->system_off=m->system_reset=false;m->next_hart=0;
    for(unsigned h=0;h<m->ncpus;h++) {
        CPU *c=machine_cpu(m,h);cpu_reset(c,entry,reset_el);
        if(h)c->power=CPU_POWER_OFF;
    }
    if(m->gic)gic_update(m->gic);
    m->io_poll_due = 0;               /* icount restarted: don't starve the IO polls */
    if (m->timer)timer_update(m);
}

void machine_tick(Machine *m) {
    if (m->timer) timer_check(m);
    if (m->rtc)   pl031_update(m);   /* pure arithmetic (deterministic mode): stays tick-fine */
    /* The host-IO polls below are syscall-bound (stdin read(2), net poll(2))
     * and need none of the per-tick precision the timer/RTC compares above
     * get: run them on a much coarser instruction cadence.
     * machine_wait_for_event zeroes io_poll_due so WFI-idle input/net latency
     * is unchanged. AEIOTICK overrides the cadence (insns; bisection knob). */
    if (m->virtual_ticks < m->io_poll_due) return;
    const u64 io_interval=65536;
    m->io_poll_due = m->virtual_ticks + io_interval;
    /* Before the consoles, so a geometry change lands on the same tick that
     * delivers its config-change interrupt. */
    if (m->ctrl) console_ctrl_poll(m->ctrl, m->uart_ep, m->vcon_ep, m->n_vcon);
    /* A console bound to its own host endpoint is independent of every other:
     * it has its own input stream and its own output buffer to drain, so poll
     * it unconditionally. */
    for (int i=0;i<m->n_vcon;i++) virtio_console_poll(m->vcon[i]);
    if (m->uart) pl011_rx_poll(m);

}

/* Can this halted CPU ever be woken again? Only three things do it: an armed
 * timer reaching its deadline, an interrupt already pending, and host IO. So
 * with no timer armed, no IRQ line raised and no device able to deliver from
 * the host — no UART, virtio-console, NIC or RTC — the machine is finished,
 * and the run loop must stop rather than spin: --max-insn cannot end it,
 * because a halted CPU retires nothing and that limit is only ever reached by
 * executing. A raw --bin image has no devices at all, so a stray WFI there is
 * always terminal; a platform run keeps waiting, since its devices can each
 * deliver at any moment and an idle interactive session must not be cut off.
 * Applies to both clocks: the wall clock advancing wakes nobody when there is
 * no armed timer to reach a deadline. */
static void check_wake_source(Machine *m, bool timer_armed, bool has_input) {
    if (m->cpu.halted && !timer_armed && !has_input && !m->cpu.irq_line &&
        !m->uart && !m->n_vcon && !m->net && !m->rtc)
        m->deadlock = true;
}

/* Every host descriptor that could wake a halted CPU: the input side of each
 * console endpoint, plus the control channel. Deduplicated, since every device
 * left on the process terminal reports the same stdin — and a poll(2) set that
 * named it several times would be legal but pointless. An endpoint that can
 * never produce input (a non-tty stdio, a peer that closed) contributes
 * nothing, so a run with no reachable host input polls no descriptors at all,
 * exactly as the single-stdin version did. */
/* Waiting is owned by the C ABI event/condition layer, never poll(50ms). */
void machine_wait_for_event(Machine *m) { m->io_poll_due=0;machine_tick(m); }

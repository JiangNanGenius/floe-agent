/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* PL031 real-time clock (minimal: host wall-clock seconds, or a fixed epoch in
 * deterministic mode). By default (AE_RTCLOCK=1) we return live host time. The
 * host clock is the last non-reproducible input into the guest, so AE_RTCLOCK=0
 * (deterministic, !g_rtclock) returns a fixed base instead, keeping the whole
 * boot bit-for-bit reproducible. Matches the generic timer's AE_RTCLOCK gating. */
#include "../devices.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Fixed wall-clock base for deterministic mode: 2025-01-01T00:00:00Z. */
#define RTC_FIXED_EPOCH 1735689600u

static const u8 pl031_id[8] = { 0x31, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1 };

/* Host counter feeding the RTC: live wall-clock seconds, or the fixed epoch in
 * deterministic mode. The guest RTC value is this plus tick_offset. */
static u32 rtc_host_count(void) {
    return g_rtclock ? (u32)time(NULL) : RTC_FIXED_EPOCH;
}

/* Guest-visible RTC count (host counter plus the guest's load offset). */
static u32 rtc_count(PL031 *p) {
    return (u32)(rtc_host_count() + p->tick_offset);
}

/* Drive INTID_RTC from the masked interrupt status, but only when the level
 * actually changes -- so an alarm-free system never touches the GIC line and
 * cannot perturb the deterministic boot. */
static void pl031_set_line(PL031 *p) {
    u8 line = (p->ris & p->imsc & 1) ? 1 : 0;
    if (line != p->irq_line) { p->irq_line = line; gic_set_irq(p->gic, INTID_RTC, line); }
}

static u64 rtc_read(void *opaque, u64 off, unsigned size) {
    PL031 *p = opaque;
    if (off >= 0xfe0 && off <= 0xffc) return pl031_id[(off - 0xfe0) / 4];
    switch (off) {
        case 0x00: return rtc_count(p);              /* DR: current count = host + offset */
        case 0x04: return p->mr;
        case 0x08: return p->lr;
        case 0x0c: return p->cr;
        case 0x10: return p->imsc;
        case 0x14: return p->ris;
        case 0x18: return p->ris & p->imsc;
        default: return 0;
    }
}

static void rtc_write(void *opaque, u64 off, unsigned size, u64 val) {
    PL031 *p = opaque;
    switch (off) {
        case 0x04: p->mr = (u32)val; p->armed = true; break;  /* MR: set + arm the alarm */
        case 0x08:                                   /* LR: load the counter (sets current time) */
            p->lr = (u32)val;
            p->tick_offset = (s64)(s32)((u32)val - rtc_host_count());
            break;
        case 0x0c: p->cr = (u32)val; break;
        case 0x10: p->imsc = (u32)val; pl031_set_line(p); break;   /* mask change */
        case 0x1c: p->ris &= ~(u32)val; pl031_set_line(p); break;  /* ICR: clear + de-assert */
        default: break;
    }
}

/* Per-tick alarm evaluation (called from machine_tick). A one-shot RTCMR match
 * -- the count reaching the match value -- latches RTCRIS[0]; RTCMIS = RIS & IMSC
 * drives INTID_RTC. `>=` because a periodic poll can overshoot the exact match
 * tick. In deterministic mode the count is frozen, so a future alarm never fires
 * (reproducible, like the generic timer); a past/zero match fires on the next
 * tick. */
void pl031_update(Machine *m) {
    PL031 *p = m->rtc;
    if (!p) return;
    if (p->armed && rtc_count(p) >= p->mr) { p->ris |= 1; p->armed = false; }
    pl031_set_line(p);
}

PL031 *pl031_create(Machine *m, GIC *gic) {
    PL031 *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->gic = gic;
    machine_add_device(m, RTC_BASE, 0x1000, rtc_read, rtc_write, p, "pl031");
    m->rtc = p;
    return p;
}

/* Return the RTC to power-on state (system reset): clear the match/load/control
 * registers and any pending alarm interrupt; keeps the GIC backpointer. The
 * wall-clock time itself is derived from the host, so it is unaffected. */
void pl031_reset(PL031 *p) {
    GIC *gic = p->gic;
    memset(p, 0, sizeof(*p));
    p->gic = gic;
    gic_set_irq(gic, INTID_RTC, 0);
}

/* Embedded typed ownership; borrowed backpointers are not freed here. */
void pl031_destroy(PL031 *p) { free(p); }

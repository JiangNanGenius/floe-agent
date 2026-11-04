/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* Exception entry/return. All exceptions are routed to EL1 (we model EL0/EL1). */
#include "cpu.h"
#include "esr.h"
#include "memory_sync.h"
#include <stdio.h>

u32 cpu_pack_spsr(CPU *c) {
    u32 s = c->nzcv & (PS_N | PS_Z | PS_C | PS_V);
    s |= c->daif & (PS_D | PS_A | PS_I | PS_F);
    /* M[4]=0 (AArch64); M[3:2]=EL; M[1]=0; M[0]=SPSel */
    s |= ((u32)c->el << 2) | (c->sp_sel ? 1u : 0u);
    return s;
}

void cpu_unpack_spsr(CPU *c, u32 spsr) {
    c->nzcv = spsr & (PS_N | PS_Z | PS_C | PS_V);
    c->daif = spsr & (PS_D | PS_A | PS_I | PS_F);
    unsigned m = spsr & 0xf;
    c->el = (m >> 2) & 3;
    c->sp_sel = m & 1u;
    cpu_refresh_fp_trap(c);        /* ERET may drop to an FPEN-trapped EL */
}

void exception_take(CPU *c, ExcKind kind, u64 esr, u64 far, u64 ret_addr) {
    unsigned tel = 1;            /* route to EL1 */
    if (c->el > tel) tel = c->el;

    u32 spsr = cpu_pack_spsr(c);
    bool from_lower = (c->el < tel);

    u64 off;
    if (from_lower) {
        off = 0x400;            /* lower EL, AArch64 */
    } else {
        off = c->sp_sel ? 0x200 : 0x000;  /* current EL with SP_ELx / SP_EL0 */
    }
    off += (u64)kind * 0x80;

    c->spsr[tel] = spsr;
    c->elr[tel]  = ret_addr;
    c->esr[tel]  = esr;
    c->far[tel]  = far;

    c->el = tel;
    c->sp_sel = 1;
    cpu_refresh_fp_trap(c);                 /* FPEN=0b01 stops trapping at EL1 */
    c->daif |= PS_D | PS_A | PS_I | PS_F;   /* mask on entry */
    c->pc = (c->vbar[tel] & ~0x7ffULL) + off;
    cpu_wake(c);
    c->instruction_partial=false; /* progress lives in MOPS operands/ELR, not this host flag */
    /* Taking an exception clears the local exclusive monitor. Without this, an
     * IRQ landing between a kernel LDXR and its STXR would leave the monitor
     * valid, letting the resumed STXR spuriously succeed and silently drop the
     * concurrent update -> intermittent lock/memory corruption in userspace. */
    memory_monitor_clear(c);

    if (g_trace || g_dbg)
        fprintf(stderr, "[exc] kind=%d -> EL%u vec=0x%llx esr=0x%llx far=0x%llx elr=0x%llx\n",
                kind, tel, (unsigned long long)c->pc, (unsigned long long)esr,
                (unsigned long long)far, (unsigned long long)ret_addr);
}

void cpu_raise_sync(CPU *c, u64 esr, u64 far) {
    unsigned ec = (unsigned)(esr >> 26);
    if (g_iabort_log && (ec == 0x20 || ec == 0x21)) {   /* instruction aborts */
        static int n = 0;
        if (n++ < 60)
            fprintf(stderr, "[iabort] el=%u far=0x%llx esr=0x%llx\n",
                    c->el, (unsigned long long)far, (unsigned long long)esr);
    }
    if (g_tpc && c->cur_insn_pc == g_tpc) {
        fprintf(stderr, "[sync] faulting pc=0x%llx esr=0x%llx (ec=0x%llx) far=0x%llx\n",
                (unsigned long long)c->cur_insn_pc, (unsigned long long)esr,
                (unsigned long long)(esr >> 26), (unsigned long long)far);
        ring_dump();
    }
    exception_take(c, EXC_SYNC, esr, far, c->cur_insn_pc);
}

/* CPACR_EL1.FPEN trap: EC 0x07 with the A64 ISS (CV=1, COND=0b1110 — the
 * encoding QEMU uses for trapped-from-AArch64 FP accesses). Shared by the
 * interpreter dispatch guards, the sysreg FPCR/FPSR guards, and the
 * predecoded tier's specialized vector load/store handlers. */
void cpu_fp_trap(CPU *c) {
    cpu_raise_sync(c, esr_make(EC_FP_SIMD_TRAP, 0x01E00000), 0);
}

/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* System registers: MSR/MRS/SYS/MSR-immediate, ID registers, generic-timer
 * register plumbing. */
#include "sysreg.h"
#include "mmu.h"
#include "machine.h"
#include <stdio.h>
#include <string.h>

/* Generic-timer hooks, provided by timer.c (M3). */
u64 gt_count(CPU *c, bool virt) __attribute__((weak));
void timer_update_cpu(CPU *c) __attribute__((weak));

/* FPSR cumulative-flag fold, provided by exec_fpsimd.c (M4): host FP flags
 * and the software-raised bits accumulate lazily and are only folded into
 * c->fpsr when the guest touches FPSR (or on reset). Weak so M2 standalone
 * links without the FP unit. */
void fpsr_sync(CPU *c) __attribute__((weak));

static u64 timer_count(CPU *c, bool virt) {
    if (gt_count) return gt_count(c, virt);
    return c->icount;   /* rough fallback for M2 standalone */
}

#define KEY(op0, op1, crn, crm, op2) \
    (((op0) << 16) | ((op1) << 13) | ((crn) << 9) | ((crm) << 5) | (op2))

static void msr_immediate(CPU *c, u32 insn) {
    unsigned op1 = (insn >> 16) & 7, op2 = (insn >> 5) & 7, crm = (insn >> 8) & 0xf;
    if (op1 == 0 && op2 == 5) {                 /* SPSel */
        c->sp_sel = crm & 1;
    } else if (op1 == 0 && crm == 0 && op2 == 0) {  /* CFINV (FEAT_FLAGM) */
        c->nzcv ^= PS_C;
    } else if (op1 == 0 && crm == 0 && op2 == 1) {  /* XAFLAG (FEAT_FLAGM2): undo AXFLAG */
        unsigned zf = !!(c->nzcv & PS_Z), cf = !!(c->nzcv & PS_C);
        c->nzcv = ((!cf && !zf) ? PS_N : 0) | ((zf && cf) ? PS_Z : 0) |
                  ((cf || zf)  ? PS_C : 0) | ((!cf && zf) ? PS_V : 0);
    } else if (op1 == 0 && crm == 0 && op2 == 2) {  /* AXFLAG (FEAT_FLAGM2): x86-style CF/ZF */
        unsigned zf = !!(c->nzcv & PS_Z), cf = !!(c->nzcv & PS_C), vf = !!(c->nzcv & PS_V);
        c->nzcv = ((zf || vf) ? PS_Z : 0) | ((cf && !vf) ? PS_C : 0);
    } else if (op1 == 3 && op2 == 6) {          /* DAIFSet */
        c->daif |= (u32)(crm & 0xf) << 6;
    } else if (op1 == 3 && op2 == 7) {          /* DAIFClr */
        if (g_dbg && (c->daif & PS_I) && (crm & 2))
            fprintf(stderr, "[pstate] IRQ unmasked (DAIFClr #%u) pc=0x%llx\n",
                    crm, (unsigned long long)c->cur_insn_pc);
        c->daif &= ~((u32)(crm & 0xf) << 6);
    }
    /* PAN/UAO/DIT/etc: ignored */
}

static void sys_op(CPU *c, u32 insn, unsigned op1, unsigned CRn, unsigned CRm,
                   unsigned op2, unsigned Rt) {
    if (CRn == 8) {                                      /* TLBI * */
        /* EL1 VA forms — VAE1/VAAE1/VALE1/VAALE1, IS (CRm==3) and non-IS
         * (CRm==7) — invalidate a single page: Xt[43:0] holds VA[55:12],
         * rebuilt to a canonical VA by sign-extending bit 55. Every other
         * form (VMALLE1, ASIDE1, the v8.4 OS/range encodings, anything
         * unrecognized) keeps the conservative full flush. */
        if (op1 == 0 && (CRm == 3 || CRm == 7) && (op2 & 1)) {
            u64 va = (reg_x(c, Rt) & 0xFFFFFFFFFFFULL) << 12;
            if (va & (1ULL << 55)) va |= 0xFF00000000000000ULL;
            machine_tlbi(c,va,true);
        } else {
            machine_tlbi(c,0,false);
        }
        return;
    }
    if (CRn == 7) {
        if (CRm == 8 && op1 == 0 && op2 <= 3) {          /* AT S1E1R/W, S1E0R/W */
            c->par_el1 = mmu_at_s1(c, reg_x(c, Rt), op2 & 1, op2 >= 2);
            return;
        }
        if (CRm == 4 && op2 == 1) {                      /* DC ZVA: zero 64 bytes */
            u64 base = reg_x(c, Rt) & ~63ULL;
            /* One D-TLB probe covers the line (64-aligned: never crosses a
             * page): writable-RAM hit -> host memset. Miss/deny falls back
             * to the 8x mem_write loop, which handles faults, MMIO,
             * watchpoint runs (the D-TLB is empty then) and JIT code pages
             * (W refused -> slow path keeps SMC invalidation) identically. */
            DTlbEnt *de = dtlb_ent(c,base);
            if (de->tag == dtlb_tag(c, base) && (de->pte & DTLB_W)) {
                MemoryGuard guard;
                if(!memory_guard_host(&guard,c->m,(u8 *)(uintptr_t)(de->pte&~0xfffULL)+(base&0xfffULL),64,true))return;
                mem_store_host_notify(c,(u8 *)(uintptr_t)(de->pte & ~0xfffULL)+(base & 0xfffULL),64);
                memset((u8 *)(uintptr_t)(de->pte & ~0xfffULL) + (base & 0xfffULL), 0, 64);
                memory_guard_end(&guard);
                return;
            }
            for (unsigned i = 0; i < 64; i += 8)
                if (!mem_write(c, base + i, 8, 0)) return;
            return;
        }
        return;   /* IC/DC clean/invalidate: no-op (flat memory) */
    }
    (void)insn; (void)op1;
}

/* MRS: read system register into Rt. */
static void do_mrs(CPU *c, unsigned key, unsigned Rt) {
    u64 v = 0;
    switch (key) {
        /* --- identification --- */
        case KEY(3,0,0,0,0): v = 0x411fd070; break;          /* MIDR_EL1 (cortex-a57-ish) */
        case KEY(3,0,0,0,5): v = c->mpidr; break;            /* MPIDR_EL1 */
        case KEY(3,0,0,0,6): v = 0; break;                   /* REVIDR_EL1 */
        case KEY(3,3,0,0,1): v = 0x8444c004; break;          /* CTR_EL0 */
        case KEY(3,3,0,0,7): v = 4; break;                   /* DCZID_EL0: BS=4 (64B), DZP=0 */
        case KEY(3,0,0,4,0): v = 0x110022; break;            /* ID_AA64PFR0_EL1: EL0/EL1=AArch64+32, FP[19:16]=1 & AdvSIMD[23:20]=1 (FEAT_FP16, half-precision arith implemented in exec_fpsimd.c) */
        case KEY(3,0,0,4,1): v = 0; break;                   /* ID_AA64PFR1_EL1 */
        case KEY(3,0,0,5,0): v = 0x10305106; break;          /* ID_AA64DFR0_EL1 (QEMU cortex-a57) */
        case KEY(3,0,0,5,1): v = 0; break;                   /* ID_AA64DFR1_EL1 */
        case KEY(3,0,0,6,0): v = 0x21100110212120ULL; break; /* ID_AA64ISAR0_EL1: AES=2,SHA1=1,SHA2=2(+SHA512),CRC32=1,Atomic=2(LSE),RDM=1,SHA3=1,DP=1,FHM=1,TS=2(FLAGM2) */
        case KEY(3,0,0,6,1): v = 0x211000; break;            /* ID_AA64ISAR1_EL1: JSCVT=1,FCMA=1,LRCPC=2(LDAPUR/STLUR) */
        case KEY(3,0,0,6,2): v = 0x10000; break;             /* ID_AA64ISAR2_EL1: MOPS=1 (CPYx/SETx) */
        case KEY(3,0,0,7,0): v = 0x0F001124; break;          /* ID_AA64MMFR0_EL1: like QEMU cortex-a57 but TGran64[27:24]=0xF (only the 4 KB granule is implemented; TGran16[23:20]=0 already says 16 KB unsupported) */
        case KEY(3,0,0,7,1): v = 0; break;                   /* ID_AA64MMFR1_EL1 */
        case KEY(3,0,0,7,2): v = 0; break;                   /* ID_AA64MMFR2_EL1 */
        /* CRm=4..7 other ID slots read as 0 (handled by default) */

        /* --- control / translation --- */
        case KEY(3,0,1,0,0): v = c->sctlr[1]; break;         /* SCTLR_EL1 */
        case KEY(3,0,1,0,1): v = 0; break;                   /* ACTLR_EL1 */
        case KEY(3,0,1,0,2): v = c->cpacr_el1; break;        /* CPACR_EL1 */
        case KEY(3,0,2,0,0): v = c->ttbr0[1]; break;         /* TTBR0_EL1 */
        case KEY(3,0,2,0,1): v = c->ttbr1[1]; break;         /* TTBR1_EL1 */
        case KEY(3,0,2,0,2): v = c->tcr[1]; break;           /* TCR_EL1 */
        case KEY(3,0,10,2,0): v = c->mair[1]; break;         /* MAIR_EL1 */
        case KEY(3,0,10,3,0): v = c->amair[1]; break;        /* AMAIR_EL1 */
        case KEY(3,0,12,0,0): v = c->vbar[1]; break;         /* VBAR_EL1 */
        case KEY(3,0,5,1,0): v = 0; break;                   /* AFSR0_EL1 */
        case KEY(3,0,5,1,1): v = 0; break;                   /* AFSR1_EL1 */
        case KEY(3,0,5,2,0): v = c->esr[1]; break;           /* ESR_EL1 */
        case KEY(3,0,6,0,0): v = c->far[1]; break;           /* FAR_EL1 */
        case KEY(3,0,7,4,0): v = c->par_el1; break;          /* PAR_EL1 */
        case KEY(3,0,13,0,1): v = c->contextidr_el1; break;  /* CONTEXTIDR_EL1 */
        case KEY(3,0,13,0,4): v = c->tpidr[1]; break;        /* TPIDR_EL1 */
        case KEY(3,3,13,0,2): v = c->tpidr[0]; break;        /* TPIDR_EL0 */
        case KEY(3,3,13,0,3): v = c->tpidrro_el0; break;     /* TPIDRRO_EL0 */
        case KEY(2,0,0,2,2): v = c->mdscr_el1; break;        /* MDSCR_EL1 */

        /* --- PSTATE views --- */
        case KEY(3,0,4,2,2): v = (u64)c->el << 2; break;     /* CurrentEL */
        case KEY(3,0,4,2,0): v = c->sp_sel; break;           /* SPSel */
        case KEY(3,3,4,2,0): v = c->nzcv & 0xf0000000; break;/* NZCV */
        case KEY(3,3,4,2,1): v = c->daif & (PS_D|PS_A|PS_I|PS_F); break; /* DAIF */
        /* FPCR/FPSR accesses trap under CPACR_EL1.FPEN too (EC 0x07). */
        case KEY(3,3,4,4,0):
            if (c->fp_trapped) { cpu_fp_trap(c); return; }
            v = c->fpcr; break;                              /* FPCR */
        case KEY(3,3,4,4,1):
            if (c->fp_trapped) { cpu_fp_trap(c); return; }
            if (fpsr_sync) fpsr_sync(c);                     /* fold pending flags */
            v = c->fpsr; break;                              /* FPSR */
        case KEY(3,0,4,0,0): v = c->spsr[1]; break;          /* SPSR_EL1 */
        case KEY(3,0,4,0,1): v = c->elr[1]; break;           /* ELR_EL1 */
        case KEY(3,0,4,1,0): v = c->sp_el[0]; break;         /* SP_EL0 */

        /* --- generic timer --- */
        case KEY(3,3,14,0,0): v = c->cntfrq; break;          /* CNTFRQ_EL0 */
        case KEY(3,3,14,0,1): v = timer_count(c, false); break; /* CNTPCT_EL0 */
        case KEY(3,3,14,0,2): v = timer_count(c, true); break;  /* CNTVCT_EL0 */
        case KEY(3,3,14,2,0): v = (u64)(s32)(c->cntp_cval - timer_count(c, false)); break; /* CNTP_TVAL (signed 32-bit view) */
        case KEY(3,3,14,2,1):                                /* CNTP_CTL_EL0 (+ISTATUS) */
            v = c->cntp_ctl & 3;
            if ((c->cntp_ctl & 1) && timer_count(c, false) >= c->cntp_cval) v |= 4;
            break;
        case KEY(3,3,14,2,2): v = c->cntp_cval; break;       /* CNTP_CVAL_EL0 */
        case KEY(3,3,14,3,0): v = (u64)(s32)(c->cntv_cval - timer_count(c, true)); break;  /* CNTV_TVAL (signed 32-bit view) */
        case KEY(3,3,14,3,1):                                /* CNTV_CTL_EL0 (+ISTATUS) */
            v = c->cntv_ctl & 3;
            if ((c->cntv_ctl & 1) && timer_count(c, true) >= c->cntv_cval) v |= 4;
            break;
        case KEY(3,3,14,3,2): v = c->cntv_cval; break;       /* CNTV_CVAL_EL0 */
        case KEY(3,0,14,1,0): v = c->cntkctl_el1; break;     /* CNTKCTL_EL1 */

        /* --- PMU / misc: read as 0 --- */
        default:
            if (g_trace)
                fprintf(stderr, "[sysreg] MRS unimpl key=0x%x pc=0x%llx -> 0\n",
                        key, (unsigned long long)c->cur_insn_pc);
            v = 0;
            break;
    }
    set_x(c, Rt, v);
}

/* MSR: write Rt to system register. */
static void do_msr(CPU *c, unsigned key, unsigned Rt) {
    u64 v = reg_x(c, Rt);
    switch (key) {
        case KEY(3,0,1,0,0): c->sctlr[1] = v; tlb_flush_all(c); break;  /* SCTLR_EL1 */
        case KEY(3,0,1,0,2):                                           /* CPACR_EL1 */
            c->cpacr_el1 = v;
            cpu_refresh_fp_trap(c);
            break;
        case KEY(3,0,2,0,0): c->ttbr0[1] = v; tlb_flush_all(c); break;  /* TTBR0_EL1 */
        case KEY(3,0,2,0,1): c->ttbr1[1] = v; tlb_flush_all(c); break;  /* TTBR1_EL1 */
        case KEY(3,0,2,0,2): c->tcr[1] = v; tlb_flush_all(c); break;    /* TCR_EL1 */
        case KEY(3,0,10,2,0): c->mair[1] = v; break;                   /* MAIR_EL1 */
        case KEY(3,0,10,3,0): c->amair[1] = v; break;                  /* AMAIR_EL1 */
        case KEY(3,0,12,0,0): c->vbar[1] = v; break;                   /* VBAR_EL1 */
        case KEY(3,0,5,2,0): c->esr[1] = v; break;                     /* ESR_EL1 */
        case KEY(3,0,6,0,0): c->far[1] = v; break;                     /* FAR_EL1 */
        case KEY(3,0,7,4,0): c->par_el1 = v; break;                    /* PAR_EL1 */
        case KEY(3,0,13,0,1): c->contextidr_el1 = v; break;            /* CONTEXTIDR_EL1 */
        case KEY(3,0,13,0,4): c->tpidr[1] = v; break;                  /* TPIDR_EL1 */
        case KEY(3,3,13,0,2): c->tpidr[0] = v; break;                  /* TPIDR_EL0 */
        case KEY(3,3,13,0,3): c->tpidrro_el0 = v; break;               /* TPIDRRO_EL0 */
        case KEY(2,0,0,2,2): c->mdscr_el1 = v; break;                  /* MDSCR_EL1 */

        case KEY(3,0,4,2,0): c->sp_sel = v & 1; break;                 /* SPSel */
        case KEY(3,3,4,2,0): c->nzcv = (u32)(v & 0xf0000000); break;   /* NZCV */
        case KEY(3,3,4,2,1): c->daif = (u32)(v & (PS_D|PS_A|PS_I|PS_F)); break; /* DAIF */
        case KEY(3,3,4,4,0):                                           /* FPCR */
            if (c->fp_trapped) { cpu_fp_trap(c); return; }
            c->fpcr = (u32)v; break;
        case KEY(3,3,4,4,1):                                           /* FPSR */
            if (c->fp_trapped) { cpu_fp_trap(c); return; }
            if (fpsr_sync) fpsr_sync(c);   /* discard pending host/soft flags */
            c->fpsr = (u32)v; break;
        case KEY(3,0,4,0,0): c->spsr[1] = v; break;                    /* SPSR_EL1 */
        case KEY(3,0,4,0,1): c->elr[1] = v; break;                     /* ELR_EL1 */
        case KEY(3,0,4,1,0): c->sp_el[0] = v; break;                   /* SP_EL0 */

        case KEY(3,3,14,0,0): c->cntfrq = v; break;                    /* CNTFRQ_EL0 */
        case KEY(3,3,14,2,0): c->cntp_cval = timer_count(c, false) + (s64)(s32)v; break; /* CNTP_TVAL */
        case KEY(3,3,14,2,1): c->cntp_ctl = v; break;                  /* CNTP_CTL_EL0 */
        case KEY(3,3,14,2,2): c->cntp_cval = v; break;                 /* CNTP_CVAL_EL0 */
        case KEY(3,3,14,3,0): c->cntv_cval = timer_count(c, true) + (s64)(s32)v; break;  /* CNTV_TVAL */
        case KEY(3,3,14,3,1): c->cntv_ctl = v; break;                  /* CNTV_CTL_EL0 */
        case KEY(3,3,14,3,2): c->cntv_cval = v; break;                 /* CNTV_CVAL_EL0 */
        case KEY(3,0,14,1,0): c->cntkctl_el1 = v; break;               /* CNTKCTL_EL1 */

        default:
            if (g_trace)
                fprintf(stderr, "[sysreg] MSR unimpl key=0x%x val=0x%llx pc=0x%llx\n",
                        key, (unsigned long long)v, (unsigned long long)c->cur_insn_pc);
            break;
    }
    /* Re-evaluate the generic timer immediately on any CNT* (CRn==14) write so
     * the interrupt line tracks a reprogrammed compare value without waiting for
     * the next periodic tick (avoids a spurious timer-IRQ storm). */
    if (((key >> 9) & 0xf) == 14 && timer_update_cpu) timer_update_cpu(c);
}

void sysreg_exec(CPU *c, u32 insn) {
    if(!mmu_bind_cpu(c))return;
    unsigned L = (insn >> 21) & 1;
    unsigned op0 = (insn >> 19) & 3, op1 = (insn >> 16) & 7;
    unsigned CRn = (insn >> 12) & 0xf, CRm = (insn >> 8) & 0xf, op2 = (insn >> 5) & 7;
    unsigned Rt = insn & 0x1f;

    if (op0 == 0) { msr_immediate(c, insn); return; }       /* MSR (immediate) */
    if (op0 == 1) {                                          /* SYS / SYSL */
        if (L == 0) sys_op(c, insn, op1, CRn, CRm, op2, Rt);
        else set_x(c, Rt, 0);   /* SYSL reads -> 0 (no SYSL op is modelled) */
        return;
    }
    unsigned key = KEY(op0, op1, CRn, CRm, op2);
    if (L) do_mrs(c, key, Rt);
    else   do_msr(c, key, Rt);
}

void sysreg_init(CPU *c) {
    c->sctlr[1] = 0x00C50838;   /* RES1 bits set, MMU/caches off */
    /* CPACR_EL1 resets architecturally UNKNOWN; reset FPEN=0b11 (no trap) so
     * flat-loaded images and firmware that touch SIMD before programming
     * CPACR keep working — enforcement engages only when a guest explicitly
     * writes a trapping FPEN. */
    c->cpacr_el1 = 0x300000;
    cpu_refresh_fp_trap(c);
    c->mdscr_el1 = 0;
    if (fpsr_sync) { fpsr_sync(c); c->fpsr = 0; }  /* drop pre-reset FP flags */
}

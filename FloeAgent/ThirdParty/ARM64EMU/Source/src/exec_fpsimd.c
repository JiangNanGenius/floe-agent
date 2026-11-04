/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* AArch64 FP/Advanced-SIMD execution. Grown on demand as the firmware/kernel
 * exercise instructions (the "implement on demand" M4 strategy). */
#include "cpu.h"
#include "esr.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <fenv.h>

#define BIT(i)      ((insn >> (i)) & 1u)
#define BITS(hi,lo) ((insn >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1))

static void __attribute__((cold)) fpsimd_undef(CPU *c, u32 insn) {
    /* Always log: drives the on-demand FP/SIMD implementation loop. */
    fprintf(stderr, "[fpsimd] UNIMPL 0x%08x at pc=0x%llx\n",
            insn, (unsigned long long)c->cur_insn_pc);
    cpu_raise_sync(c, esr_make(EC_UNKNOWN, 0), 0);
}

static u64 rep8(u64 b)  { b &= 0xff;   return b * 0x0101010101010101ULL; }
static u64 rep16(u64 h) { h &= 0xffff; return h * 0x0001000100010001ULL; }
static u64 rep32(u64 w) { w &= 0xffffffff; return w | (w << 32); }

/* VFP modified-immediate expansion (for FMOV vector/scalar). */
static u32 vfp_imm32(unsigned imm8) {
    /* sign:imm8<7>  exp8 = NOT(b6):Replicate(b6,5):imm8<5:4>  frac = imm8<3:0> */
    unsigned s = (imm8 >> 7) & 1, b6 = (imm8 >> 6) & 1, e = (imm8 >> 4) & 3;
    u32 exp8 = ((!b6) << 7) | ((b6 ? 0x1f : 0) << 2) | e;
    return ((u32)s << 31) | (exp8 << 23) | ((u32)(imm8 & 0xf) << 19);
}
static u64 vfp_imm64(unsigned imm8) {
    unsigned s = (imm8 >> 7) & 1, b6 = (imm8 >> 6) & 1;
    unsigned e = ((imm8 >> 4) & 3);
    u64 sign = (u64)s << 63;
    u64 exp11 = ((u64)(!b6) << 10) | ((u64)(b6 ? 0xff : 0) << 2) | e;  /* exp[10]=NOT b6, [9:2]=Rep(b6,8), [1:0]=imm8[5:4] */
    u64 frac = (u64)(imm8 & 0xf) << 48;
    return sign | (exp11 << 52) | frac;
}
static u16 vfp_imm16(unsigned imm8) {                 /* half-precision FMOV #imm */
    unsigned s = (imm8 >> 7) & 1, b6 = (imm8 >> 6) & 1, e = (imm8 >> 4) & 3;
    u16 exp5 = (u16)(((!b6) << 4) | ((b6 ? 3u : 0u) << 2) | e);  /* [4]=NOT b6, [3:2]=Rep(b6,2), [1:0]=imm8[5:4] */
    return (u16)((s << 15) | (exp5 << 10) | ((imm8 & 0xf) << 6));
}

/* AdvSIMD modified immediate -> 64-bit element pattern (MOVI value). */
static u64 expand_imm(unsigned op, unsigned cmode, unsigned imm8) {
    unsigned hi = (cmode >> 1) & 7, lo = cmode & 1;
    switch (hi) {
        case 0: return rep32(imm8);
        case 1: return rep32((u64)imm8 << 8);
        case 2: return rep32((u64)imm8 << 16);
        case 3: return rep32((u64)imm8 << 24);
        case 4: return rep16(imm8);
        case 5: return rep16((u64)imm8 << 8);
        case 6: return lo ? rep32(((u64)imm8 << 16) | 0xffff)
                          : rep32(((u64)imm8 << 8) | 0xff);
        default: /* 7 */
            if (lo == 0 && op == 0) return rep8(imm8);
            if (lo == 0 && op == 1) {           /* MOVI 64-bit: bit->byte expand */
                u64 v = 0;
                for (int i = 0; i < 8; i++) if ((imm8 >> i) & 1) v |= 0xffULL << (i * 8);
                return v;
            }
            if (lo == 1 && op == 0) return rep32(vfp_imm32(imm8));   /* FMOV .4S */
            return vfp_imm64(imm8);                                  /* FMOV .2D */
    }
}

static void simd_modified_imm(CPU *c, u32 insn) {
    unsigned Q = BIT(30), op = BIT(29), cmode = BITS(15, 12), Rd = BITS(4, 0);
    unsigned imm8 = (BITS(18, 16) << 5) | BITS(9, 5);
    unsigned hi = (cmode >> 1) & 7, lo = cmode & 1;

    bool orr_bic = (lo == 1) && (hi <= 5);   /* ORR/BIC (vector, immediate) */
    u64 v;
    if (orr_bic) {
        v = expand_imm(0, cmode, imm8);
        if (op == 0) { c->v[Rd].d[0] |= v; if (Q) c->v[Rd].d[1] |= v; }   /* ORR */
        else { c->v[Rd].d[0] &= ~v; if (Q) c->v[Rd].d[1] &= ~v; }         /* BIC */
        if (!Q) c->v[Rd].d[1] = 0;
        return;
    }
    v = expand_imm(op, cmode, imm8);
    /* MVNI: op==1 inverts, except the two cmode==111x special MOVI/FMOV forms */
    if (op == 1 && !(hi == 7)) v = ~v;
    c->v[Rd].d[0] = v;
    c->v[Rd].d[1] = Q ? v : 0;
}

static u64 velem_get(const V128 *v, unsigned size, unsigned idx) {
    switch (size) {
        case 0: return v->b[idx];
        case 1: return v->h[idx];
        case 2: return v->s[idx];
        default: return v->d[idx];
    }
}
static void velem_set(V128 *v, unsigned size, unsigned idx, u64 val) {
    switch (size) {
        case 0: v->b[idx] = (u8)val; break;
        case 1: v->h[idx] = (u16)val; break;
        case 2: v->s[idx] = (u32)val; break;
        default: v->d[idx] = val; break;
    }
}

/* True iff an AdvSIMD-copy encoding (op=bit29, imm4, imm5, Q=bit30) is allocated.
 * imm5<3:0>==0 has no element size (reserved); .d forms need Q=1; and SMOV/UMOV
 * are only defined for the size/Q pairs that fit their destination width. The
 * JIT frontend duplicates this predicate (keep the two in sync). */
static bool simd_copy_enc_valid(unsigned op, unsigned imm4, unsigned imm5, unsigned Q) {
    if ((imm5 & 0xf) == 0) return false;            /* no allocated element size */
    unsigned size = (imm5 & 1) ? 0 : (imm5 & 2) ? 1 : (imm5 & 4) ? 2 : 3;
    if (op) return true;                            /* INS (element): any size */
    switch (imm4) {
        case 0x0: case 0x1: return !(size == 3 && !Q);   /* DUP (element/general): .d needs Q */
        case 0x3: return true;                           /* INS (general): any size */
        case 0x5: return size <= (Q ? 2u : 1u);          /* SMOV: Wd{B,H} / Xd{B,H,S} */
        case 0x7: return Q ? (size == 3) : (size <= 2);  /* UMOV: Wd{B,H,S} / Xd{D} */
        default: return false;                           /* reserved imm4 */
    }
}

/* AdvSIMD copy: DUP/INS/UMOV/SMOV. */
static void simd_copy(CPU *c, u32 insn) {
    unsigned Q = BIT(30), op = BIT(29);
    unsigned imm5 = BITS(20, 16), imm4 = BITS(14, 11);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    if (!simd_copy_enc_valid(op, imm4, imm5, Q)) { fpsimd_undef(c, insn); return; }
    /* element size = position of lowest set bit in imm5 */
    unsigned size = (imm5 & 1) ? 0 : (imm5 & 2) ? 1 : (imm5 & 4) ? 2 : 3;
    unsigned index = imm5 >> (size + 1);

    if (op == 1) {                                  /* INS (element): Vd[idx1]=Vn[idx2] */
        unsigned idx2 = imm4 >> size;
        velem_set(&c->v[Rd], size, index, velem_get(&c->v[Rn], size, idx2));
        return;
    }
    switch (imm4) {
        case 0x0: {                                 /* DUP (element) */
            u64 e = velem_get(&c->v[Rn], size, index);
            V128 r; r.d[0] = r.d[1] = 0;
            unsigned lanes = (16 >> size) >> (Q ? 0 : 1);
            for (unsigned i = 0; i < lanes; i++) velem_set(&r, size, i, e);
            c->v[Rd] = r;
            break;
        }
        case 0x1: {                                 /* DUP (general): lanes = Xn */
            u64 e = reg_x(c, Rn);
            V128 r; r.d[0] = r.d[1] = 0;
            unsigned lanes = (16 >> size) >> (Q ? 0 : 1);
            for (unsigned i = 0; i < lanes; i++) velem_set(&r, size, i, e);
            c->v[Rd] = r;
            break;
        }
        case 0x3:                                   /* INS (general): Vd[idx]=Xn */
            velem_set(&c->v[Rd], size, index, reg_x(c, Rn));
            break;
        case 0x5: {                                 /* SMOV */
            u64 e = velem_get(&c->v[Rn], size, index);
            u64 v = sign_extend(e, 8u << size);
            set_x(c, Rd, Q ? v : (u32)v);
            break;
        }
        case 0x7: {                                 /* UMOV */
            u64 e = velem_get(&c->v[Rn], size, index);
            set_x(c, Rd, Q ? e : (u32)e);
            break;
        }
        default: fpsimd_undef(c, insn); break;
    }
}

/* AdvSIMD scalar copy: the sole member is DUP(element)->scalar, i.e.
 * MOV <V><d>, <Vn>.<T>[index]. Unlike the vector DUP it writes exactly one
 * element and zeroes the rest (bit30 here is a fixed 1, not a Q field). */
static void simd_scalar_copy(CPU *c, u32 insn) {
    unsigned imm5 = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned size = (imm5 & 1) ? 0 : (imm5 & 2) ? 1 : (imm5 & 4) ? 2 : 3;
    unsigned index = imm5 >> (size + 1);
    V128 r; r.d[0] = r.d[1] = 0;
    velem_set(&r, size, 0, velem_get(&c->v[Rn], size, index));
    c->v[Rd] = r;
}

/* ---------------- Scalar floating-point (single/double) ---------------- *
 * Implemented with the host's IEEE-754 float/double (the host is IEEE-754 LE,
 * matching the guest). Covers convert, arithmetic, compare, select, FMOV and
 * fused multiply-add — the scalar FP the firmware and Linux rely on. Half
 * precision (ftype=11) and fixed-point convert scales beyond the common cases
 * fall through to UNDEF and surface via the on-demand trap. */
static double fp_rd_d(CPU *c, unsigned n) { double x; u64 b = c->v[n].d[0]; memcpy(&x, &b, 8); return x; }
static float  fp_rd_s(CPU *c, unsigned n) { float  x; u32 b = c->v[n].s[0]; memcpy(&x, &b, 4); return x; }
static void fp_wr_d(CPU *c, unsigned d, double x) { u64 b; memcpy(&b, &x, 8); c->v[d].d[0] = b; c->v[d].d[1] = 0; }
static void fp_wr_s(CPU *c, unsigned d, float  x) { u32 b; memcpy(&b, &x, 4); c->v[d].d[0] = b; c->v[d].d[1] = 0; }
static u16  fp_rd_h(CPU *c, unsigned n) { return c->v[n].h[0]; }
static void fp_wr_h(CPU *c, unsigned d, u16 h) { c->v[d].d[0] = h; c->v[d].d[1] = 0; }

/* IEEE-754 binary16 <-> binary32/64 conversion in pure integer arithmetic.
 * The host is not assumed to have _Float16, so these avoid host FP16 support.
 * Only FCVT uses half precision so far (the rest of the FP16 surface stays on
 * the on-demand UNDEF path). */

/* binary16 -> binary32, exact (every half value is representable as a single). */
/* ---------------- FPSR cumulative exception flags ----------------
 * Lazy sticky-accumulation model: guest FP arithmetic runs on host FP, whose
 * exception flags are sticky and (on x86 SSE and AArch64 hosts alike) raised
 * under the same conditions ARM architecturally raises IOC/DZC/OFC/UFC/IXC —
 * including the quiet-vs-signaling compare split (C's ==/!= are quiet, the
 * relationals signaling, matching FCMEQ vs FCMGT). So flags are *not*
 * harvested per instruction: they accumulate in the host status word across
 * interpreter helpers AND the JIT's inline SSE/NEON emits (same thread, same
 * status word — the fast engines need no changes), and are folded into
 * c->fpsr only when the guest reads or writes FPSR (fpsr_sync, called from
 * sysreg.c). Paths computed with pure integer code (the f16 narrows, the
 * saturating converts, FRINTX, the estimates) raise their flags by hand into
 * g_fpexc, which fpsr_sync also folds; on armv7 hosts the fused
 * multiply-adds join them (a64_fma below — Bionic's software fma leaks
 * spurious Inexact, so their flags are derived, not harvested). The two invariants that make this
 * sound: helpers never run host-FP ops the guest didn't ask for (the f_trunc
 * family below is raise-free bit arithmetic, compares classify NaNs before
 * ordering), and nothing outside guest FP touches host FP (the one stats
 * printf in jit.c fences itself).
 *
 * WHAT THIS ASKS OF THE COMPILER, and why the invariants above are written the
 * way they are. C does not promise any of it: without #pragma STDC FENV_ACCESS
 * ON — which neither gcc nor clang really implements — the compiler may assume
 * nobody looks at the exception flags, and is then free to (a) hoist an FP
 * operation out of the branch that guards it and run it unconditionally, and
 * (b) implement a C relational with the *quiet* host compare instead of the
 * signaling one. gcc happens to do neither; clang does both, so every Termux
 * build was quietly wrong until 2026-08-01:
 *   - FMAX's NaN arm returned `n + m`, which clang evaluated for every FMAX;
 *     0.5 + a denormal left IXC set on an instruction that raises nothing;
 *   - FCMGT of a quiet NaN stopped raising IOC, because clang compares quiet;
 *   - (u64)double has no x86-64 instruction, and clang's branchless expansion
 *     subtracts 2^63 unconditionally — inexact, so an exact FCVTZU set IXC.
 * All three are now decided in the source instead of left to codegen: NaN is
 * classified before any relational (fcm_test_*), the flag a NaN arm owes is
 * raised by hand, and no FP->int convert is a cast any more — the whole family
 * goes through d_to_u64_exact / d_to_s64_exact, which is also what stops a
 * *libgcc* expansion of the same conversion leaking Inexact on armv7 (see
 * there; that one is not a clang quirk, and gcc has it too). What the source
 * cannot express is an FP op a compiler speculates out of ANY guard —
 * FPRecipStepFused's 0*inf arm, say. No compiler we build with does that
 * today, m22_fpsr pins it, and the escape hatch if one starts is to compile
 * this file with -ffp-exception-behavior=strict (clang; measured ~7% on the
 * FP path, which is why it is not on by default).
 * Known corners vs the architecture, deliberate. All were measured against
 * qemu by sweeping random FP/SIMD words; the counts are per 30000 words with
 * NaN and Inf excluded from every lane width:
 *   - tininess is detected after rounding on x86 (ARM: before) — one boundary
 *     ULP of difference in UFC for float/double;
 *   - f64-input fixed-point converts with 2^1000-scale overflow leak host OFC;
 *   - the FP16 widen-compute-narrow pipeline can miss UFC/IXC on a result
 *     that is inexact in half but exact in double (6/30000, FCMLA).
 * These are values a guest only sees if it inspects the sticky flags after an
 * exceptional operation. NaN *results* used to be a third such corner and are
 * no longer: both which NaN an operation returns and what a generated one
 * looks like are decided here rather than inherited from the host — see the
 * FPProcessNaNs / DefaultNaN block below. FPCR.DN (Default-NaN mode, which
 * would make even a propagated NaN come back as the default) is still not
 * modelled; Linux userspace leaves it clear. */
#define FPSR_IOC 0x01u
#define FPSR_DZC 0x02u
#define FPSR_OFC 0x04u
#define FPSR_UFC 0x08u
#define FPSR_IXC 0x10u
#define FPSR_QC  (1u << 27)
/* The selector is thread-local; the pending value itself belongs to CPU.
 * Helpers without a CPU parameter run only below exec_fpsimd/fpsr_sync. */
static _Thread_local CPU *fp_cpu;
#define g_fpexc (fp_cpu->exec.fp_pending)

/* Fold the host's sticky flags into g_fpexc and clear them: fpsr_sync's
 * host half. */
static void fold_host_fpexc(void) {
    int e = fetestexcept(FE_ALL_EXCEPT);
    if (!e) return;
    if (e & FE_INVALID)   g_fpexc |= FPSR_IOC;
    if (e & FE_DIVBYZERO) g_fpexc |= FPSR_DZC;
    if (e & FE_OVERFLOW)  g_fpexc |= FPSR_OFC;
    if (e & FE_UNDERFLOW) g_fpexc |= FPSR_UFC;
    if (e & FE_INEXACT)   g_fpexc |= FPSR_IXC;
    feclearexcept(FE_ALL_EXCEPT);
}

void fpsr_sync(CPU *c) {
    fp_cpu=c;
    fold_host_fpexc();
    c->fpsr |= g_fpexc;
    g_fpexc = 0;
}

static int is_snan_d(double v) {
    u64 b; memcpy(&b, &v, 8);
    return ((b >> 52) & 0x7ff) == 0x7ff && (b & 0xfffffffffffffULL) &&
           !(b & 0x8000000000000ULL);
}
static int is_snan_s(float v) {
    u32 b; memcpy(&b, &v, 4);
    return ((b >> 23) & 0xff) == 0xff && (b & 0x7fffff) && !(b & 0x400000);
}
static double quiet_d(double v) {
    u64 b; memcpy(&b, &v, 8); b |= 0x8000000000000ULL;
    double r; memcpy(&r, &b, 8); return r;
}

/* ---- NaN results: AArch64 FPProcessNaNs / DefaultNaN --------------------
 *
 * Two things the host gets wrong, both only visible in the result's bits.
 *
 * GENERATED. An invalid operation whose operands hold no NaN produces the
 * architecture's DefaultNaN, and on AArch64 that is POSITIVE (0x7ff8.. /
 * 0x7fc00000). x86 answers with the negative "real indefinite" QNaN, and every
 * helper here computes in host doubles and floats, so the host's sign came
 * through: 0.0/0.0 printed as -nan where hardware prints nan, and signbit()
 * disagreed with it.
 *
 * PROPAGATED. AArch64 takes a signalling operand first and quiets it, and
 * otherwise the first quiet one in the architecture's operand order. x86
 * returns whichever operand the instruction had as its destination -- which
 * for a commutative C expression is the compiler's choice, so this used to come
 * out right only by codegen luck (and stopped being right the moment anything
 * near it changed). Deciding it here makes it explicit instead.
 *
 * Callers pass the operands in the order the architecture scans them, already
 * carrying any FPNeg the instruction applies -- FPNeg flips a NaN's sign too,
 * which is why FMSUB of a NaN multiplicand returns it negated. For the fused
 * multiply-add family that order is (addend, n, m), not (n, m, addend); all of
 * it measured against hardware.
 *
 * On an AArch64 host these are no-ops: the host already produced the
 * architectural value. The JIT needs no counterpart either -- every FP family
 * its backends translate natively hands a NaN result back to this interpreter
 * (vop_slowpath), which is what makes the two engines agree. */
static double dfl_nan_d(void) {
    u64 b = 0x7ff8000000000000ULL; double r; memcpy(&r, &b, 8); return r;
}
static float dfl_nan_s(void) {
    u32 b = 0x7fc00000u; float r; memcpy(&r, &b, 4); return r;
}
static float quiet_s(float v) {
    u32 b; memcpy(&b, &v, 4); b |= 0x400000u;
    float r; memcpy(&r, &b, 4); return r;
}
/* `r` is the host's answer, consulted only for whether a NaN arose at all;
 * one-operand callers (FSQRT) pass their operand twice. */
static double fpnan_d(double r, double a, double b) {
    if (!__builtin_isnan(r)) return r;
    if (is_snan_d(a)) return quiet_d(a);
    if (is_snan_d(b)) return quiet_d(b);
    if (__builtin_isnan(a)) return a;
    if (__builtin_isnan(b)) return b;
    return dfl_nan_d();
}
static float fpnan_s(float r, float a, float b) {
    if (!__builtin_isnan(r)) return r;
    if (is_snan_s(a)) return quiet_s(a);
    if (is_snan_s(b)) return quiet_s(b);
    if (__builtin_isnan(a)) return a;
    if (__builtin_isnan(b)) return b;
    return dfl_nan_s();
}
static double fpnan_d3(double r, double a, double b, double c) {
    if (!__builtin_isnan(r)) return r;
    if (is_snan_d(a)) return quiet_d(a);
    if (is_snan_d(b)) return quiet_d(b);
    if (is_snan_d(c)) return quiet_d(c);
    if (__builtin_isnan(a)) return a;
    if (__builtin_isnan(b)) return b;
    if (__builtin_isnan(c)) return c;
    return dfl_nan_d();
}
static float fpnan_s3(float r, float a, float b, float c) {
    if (!__builtin_isnan(r)) return r;
    if (is_snan_s(a)) return quiet_s(a);
    if (is_snan_s(b)) return quiet_s(b);
    if (is_snan_s(c)) return quiet_s(c);
    if (__builtin_isnan(a)) return a;
    if (__builtin_isnan(b)) return b;
    if (__builtin_isnan(c)) return c;
    return dfl_nan_s();
}

/* FPMulAdd's one departure from plain 3-operand NaN propagation: a QUIET NaN
 * addend beside an inf*0 product comes back as the DEFAULT NaN, with
 * InvalidOp — not as the propagated addend (a SIGNALING addend there still
 * propagates, quieted, like anywhere else). x86 FMA hardware propagates the
 * addend and raises nothing for this triple, so both the payload and the IOC
 * must be decided here; every fused site (scalar dp3, vector MLA/MLS) funnels
 * through these instead of the plain fpnan_*3. */
static double fpnan_muladd_d(double r, double a, double n, double m) {
    if (__builtin_isnan(a) && !is_snan_d(a) &&
        ((__builtin_isinf(n) && m == 0.0) || (n == 0.0 && __builtin_isinf(m)))) {
        g_fpexc |= FPSR_IOC;
        return dfl_nan_d();
    }
    return fpnan_d3(r, a, n, m);
}
static float fpnan_muladd_s(float r, float a, float n, float m) {
    if (__builtin_isnan(a) && !is_snan_s(a) &&
        ((__builtin_isinf(n) && m == 0.0f) || (n == 0.0f && __builtin_isinf(m)))) {
        g_fpexc |= FPSR_IOC;
        return dfl_nan_s();
    }
    return fpnan_s3(r, a, n, m);
}

static float f16_to_f32(u16 h) {
    u32 sign = (u32)(h & 0x8000u) << 16;
    u32 exp  = (h >> 10) & 0x1fu;
    u32 mant = h & 0x3ffu;
    u32 bits;
    if (exp == 0x1f) {                        /* Inf / NaN: payload shifts up 13 */
        bits = sign | 0x7f800000u | (mant << 13);
    } else if (exp == 0) {
        if (mant == 0) {
            bits = sign;                      /* +/- zero */
        } else {                              /* subnormal half -> normal single */
            exp = 127 - 15 + 1;
            while ((mant & 0x400u) == 0) { mant <<= 1; exp--; }
            mant &= 0x3ffu;
            bits = sign | (exp << 23) | (mant << 13);
        }
    } else {                                  /* normal: rebias exponent by +112 */
        bits = sign | ((exp - 15 + 127) << 23) | (mant << 13);
    }
    float f; memcpy(&f, &bits, 4); return f;
}

/* Half -> double, the same pure unpack one level up: exact for every half
 * value, and NaNs keep BOTH payload and signaling-ness (half frac<9:0> lands
 * on double frac<51:42>, so the half quiet bit maps onto the double quiet
 * bit). The scalar half pipeline computes in double, and it must widen
 * through this rather than a host (double)(float) cast: the host cast QUIETS
 * a signaling NaN, after which fpnan_*'s sNaN-priority ranking, FCMP's
 * signaling detection and FPMulAdd's quiet-addend rule all see the wrong
 * class. */
static double f16_to_f64(u16 h) {
    u64 sign = (u64)(h & 0x8000u) << 48;
    u64 exp  = (h >> 10) & 0x1fu;
    u64 mant = h & 0x3ffu;
    u64 bits;
    if (exp == 0x1f) {                        /* Inf / NaN: payload shifts up 42 */
        bits = sign | 0x7ff0000000000000ULL | (mant << 42);
    } else if (exp == 0) {
        if (mant == 0) {
            bits = sign;                      /* +/- zero */
        } else {                              /* subnormal half -> normal double */
            exp = 1023 - 15 + 1;
            while ((mant & 0x400u) == 0) { mant <<= 1; exp--; }
            bits = sign | (exp << 52) | ((mant & 0x3ffu) << 42);
        }
    } else {                                  /* normal: rebias exponent by +1008 */
        bits = sign | ((exp - 15 + 1023) << 52) | (mant << 42);
    }
    double d; memcpy(&d, &bits, 8); return d;
}

/* FCVT widen from half as a *conversion* (vs f16_to_f32's pure unpack, used
 * when a following arithmetic op will process the NaN itself): a signaling
 * NaN raises IOC and the result NaN is quieted, per FPConvertNaN. */
static float fcvt_h2s(u16 h) {
    float f = f16_to_f32(h);
    if ((h & 0x7c00) == 0x7c00 && (h & 0x3ff)) {   /* NaN */
        if (!(h & 0x200)) g_fpexc |= FPSR_IOC;     /* signaling */
        u32 b; memcpy(&b, &f, 4); b |= 0x400000;   /* quiet the payload copy */
        memcpy(&f, &b, 4);
    }
    return f;
}

/* binary64 -> binary16, round-to-nearest-even. This is the single "to half"
 * routine: S->H widens the float to double first (exact), so one rounding step
 * here yields the correct single-rounded result without a second routine.
 * Raises the conversion's FPSR flags into g_fpexc (pure-integer path, so the
 * host never sees them): sNaN -> IOC, overflow -> OFC|IXC (including a
 * round-up into Inf), tiny (before rounding, ARM's default) and inexact ->
 * UFC|IXC, plain inexact -> IXC. */
static u16 f64_to_f16(double x) {
    u64 b; memcpy(&b, &x, 8);
    u16 sign = (u16)((b >> 48) & 0x8000u);
    u64 mag  = b & 0x7fffffffffffffffULL;              /* |x| bit pattern */

    if (mag >= 0x7ff0000000000000ULL) {                /* Inf / NaN */
        if (mag > 0x7ff0000000000000ULL) {             /* NaN: FPConvertNaN */
            if (!(mag & 0x8000000000000ULL))
                g_fpexc |= FPSR_IOC;                   /* signaling NaN */
            /* Carry the TOP payload bits (frac<50:42> -> half frac<8:0>),
             * quiet bit forced: that is FPConvertNaN, and it is also what
             * makes the widen-compute-narrow half pipeline hand a propagated
             * NaN operand back unchanged instead of flattening it to the
             * default (qemu keeps the payload; a flat 0x7e00 diverged on
             * every half op whose NaN operand had one). */
            return (u16)(sign | 0x7e00u | ((mag >> 42) & 0x1ffu));
        }
        return (u16)(sign | 0x7c00u);
    }
    if (mag == 0) return sign;                         /* +/- zero */

    int he  = (int)(mag >> 52) - 1023 + 15;            /* tentative half exponent */
    u64 sig = (mag & 0xfffffffffffffULL) | 0x10000000000000ULL; /* 1.frac, bit52 set */

    if (he >= 0x1f) {                                  /* overflow -> Inf */
        g_fpexc |= FPSR_OFC | FPSR_IXC;
        return (u16)(sign | 0x7c00u);
    }

    int shift;
    if (he > 0) {
        shift = 42;                                    /* 52 - 10 fraction bits */
    } else {                                           /* subnormal / underflow */
        shift = 43 - he;                               /* extra right shift */
        if (shift >= 54) {                             /* below half a ULP -> +/-0 */
            g_fpexc |= FPSR_UFC | FPSR_IXC;
            return sign;
        }
    }

    u64 rounded  = sig >> shift;
    u64 rem      = sig & (((u64)1 << shift) - 1);
    u64 halfway  = (u64)1 << (shift - 1);
    if (rem > halfway || (rem == halfway && (rounded & 1)))
        rounded++;                                     /* nearest, ties to even */

    if (rem) g_fpexc |= (he > 0) ? FPSR_IXC : (FPSR_UFC | FPSR_IXC);

    u16 res;
    if (he > 0)                                        /* normal: carry bumps exp */
        res = (u16)(sign | (u16)(((he - 1) << 10) + rounded));
    else
        res = (u16)(sign | (u16)rounded);              /* subnormal (carry -> normal) */
    if ((res & 0x7c00) == 0x7c00)                      /* round-up crossed into Inf */
        g_fpexc |= FPSR_OFC | FPSR_IXC;
    return res;
}

/* IEEE-754 binary64 -> binary32 with round-to-ODD (FCVTXN). Round-to-odd is
 * truncation with the shifted-out remainder OR'd into the result LSB; unlike
 * round-to-nearest it never rounds a finite value up to Inf (overflow caps at
 * the largest finite float, whose mantissa is all-ones = odd). Pure integer so
 * the host's rounding mode is irrelevant. */
static u32 f64_to_f32_round_odd(double x) {
    u64 b; memcpy(&b, &x, 8);
    u32 sign = (u32)((b >> 32) & 0x80000000u);
    u64 mag  = b & 0x7fffffffffffffffULL;

    if (mag >= 0x7ff0000000000000ULL) {                /* Inf / NaN */
        if (mag > 0x7ff0000000000000ULL && !(mag & 0x8000000000000ULL))
            g_fpexc |= FPSR_IOC;                       /* signaling NaN */
        return sign | (mag > 0x7ff0000000000000ULL ? 0x7fc00000u : 0x7f800000u);
    }
    if (mag == 0) return sign;                         /* +/- zero */
    if (mag < 0x36a0000000000000ULL) {                 /* |x| < 2^-149: tiny -> smallest odd subnormal */
        g_fpexc |= FPSR_UFC | FPSR_IXC;
        return sign | 1u;
    }

    int fe  = (int)(mag >> 52) - 1023 + 127;           /* tentative float exponent */
    u64 sig = (mag & 0xfffffffffffffULL) | 0x10000000000000ULL;  /* 1.frac, bit52 set */

    if (fe >= 0xff) {                                  /* overflow -> largest finite (odd) */
        g_fpexc |= FPSR_OFC | FPSR_IXC;
        return sign | 0x7f7fffffu;
    }

    int shift = (fe > 0) ? 29 : (30 - fe);             /* 52-23 normal; extra for subnormal */
    u64 rounded = sig >> shift;
    if (sig & (((u64)1 << shift) - 1)) {               /* round-to-odd: sticky -> LSB */
        rounded |= 1;
        g_fpexc |= (fe > 0) ? FPSR_IXC : (FPSR_UFC | FPSR_IXC);
    }

    if (fe > 0) return sign | (u32)(((u32)(fe - 1) << 23) + (u32)rounded);  /* implicit 1 carries into exp */
    return sign | (u32)rounded;                        /* subnormal */
}

/* Per-lane FP <-> bits accessors for vector ops (lane i of a V128). */
static float  vget_s(const V128 *v, unsigned i) { float  x; u32 b = v->s[i]; memcpy(&x, &b, 4); return x; }
static double vget_d(const V128 *v, unsigned i) { double x; u64 b = v->d[i]; memcpy(&x, &b, 8); return x; }
static void   vset_s(V128 *v, unsigned i, float  x) { u32 b; memcpy(&b, &x, 4); v->s[i] = b; }
static void   vset_d(V128 *v, unsigned i, double x) { u64 b; memcpy(&b, &x, 8); v->d[i] = b; }

/* Rounding without libm: values >= 2^52 are already integral; otherwise round
 * via an integer cast (which truncates toward zero) and adjust. __builtin_fabs
 * and __builtin_sqrt are inlined to hardware ops (see -fno-math-errno). */
#define FP_INTEGRAL 4503599627370496.0   /* 2^52 */
static double fround_mode(double v, int rmode);        /* defined below */
static double frint_d(double v, int rmode, int exact);  /* defined below */
static u64 fcvt_to_int(double r, double orig, int is_signed, int x64); /* defined below */
static u64 fcvt_fixed(double prod, int is_signed, int x64);   /* defined below */
static u64 d_to_s64_exact(double r);                          /* defined below */

/* All four are raise-free (bit arithmetic + exact adds): a (s64) cast would
 * raise the host inexact flag, which the sticky FPSR accumulation would then
 * misattribute to the guest (FRINTZ & friends must not set IXC). The residual
 * v - t and the ±1.0 adjustments are exact for |v| < 2^52. */
static double f_trunc(double v) {
    if (!(v == v) || __builtin_fabs(v) >= FP_INTEGRAL) return v;
    u64 b; memcpy(&b, &v, 8);
    int e = (int)((b >> 52) & 0x7ff) - 1023;
    if (e < 0) b &= 0x8000000000000000ULL;   /* |v| < 1 -> +/-0 */
    else       b &= ~((1ULL << (52 - e)) - 1);
    double r; memcpy(&r, &b, 8); return r;
}
static double f_floor(double v) {
    if (!(v == v) || __builtin_fabs(v) >= FP_INTEGRAL) return v;
    double t = f_trunc(v); return (t > v) ? t - 1.0 : t;
}
static double f_ceil(double v) {
    if (!(v == v) || __builtin_fabs(v) >= FP_INTEGRAL) return v;
    double t = f_trunc(v); return (t < v) ? t + 1.0 : t;
}
static double f_round(double v) {            /* nearest, ties away from zero */
    if (!(v == v) || __builtin_fabs(v) >= FP_INTEGRAL) return v;
    double t = f_trunc(v), f = v - t;        /* f: signed fractional, exact */
    if (f >= 0.5) t += 1.0;
    else if (f <= -0.5) t -= 1.0;
    return t;
}

/* Ordered-compare classification with ARM's quiet/signaling IOC split: the
 * quiet forms (FCMP/FCCMP) raise IOC only for a signaling NaN, the signaling
 * forms (FCMPE/FCCMPE) for any NaN. NaNs are classified *before* any host
 * relational op runs — a raw C `<` would raise the host invalid flag on a
 * quiet NaN, which the sticky FPSR accumulation would misattribute. */
static int fp_compare_d(double a, double b, int signaling) {
    if (a != a || b != b) {
        if (signaling || is_snan_d(a) || is_snan_d(b)) g_fpexc |= FPSR_IOC;
        return 2;
    }
    return (a < b) ? -1 : (a > b) ? 1 : 0;
}
static int fp_compare_s(float a, float b, int signaling) {
    if (a != a || b != b) {
        if (signaling || is_snan_s(a) || is_snan_s(b)) g_fpexc |= FPSR_IOC;
        return 2;
    }
    return (a < b) ? -1 : (a > b) ? 1 : 0;
}

/* The mask-producing compares — FCMEQ/FCMGE/FCMGT/FCMLE/FCMLT, their
 * compare-with-zero forms and FACGE/FACGT (which pass |x|,|y|; FPAbs leaves a
 * NaN signaling or quiet as it was). Same discipline as fp_compare_* above,
 * for the same reason and one more: which host instruction a C relational
 * becomes — the quiet compare or the signaling one — is the compiler's choice,
 * not ours. gcc happens to pick the signaling form, so FCMGT of a *quiet* NaN
 * raised IOC by luck; clang picks the quiet one and it silently stopped.
 * Classify first, raise by hand. Only EQ is architecturally quiet (IOC for a
 * signaling NaN alone); every other form raises for any NaN, and unordered is
 * false for all of them. */
enum { FCM_EQ = 0, FCM_GE, FCM_GT, FCM_LE, FCM_LT };
static int fcm_ordered(int kind, int lt, int eq, int gt) {
    switch (kind) {
        case FCM_EQ: return eq;
        case FCM_GE: return gt || eq;
        case FCM_GT: return gt;
        case FCM_LE: return lt || eq;
        default:     return lt;
    }
}
static int fcm_test_d(int kind, double x, double y) {
    if (x != x || y != y) {
        if (kind != FCM_EQ || is_snan_d(x) || is_snan_d(y)) g_fpexc |= FPSR_IOC;
        return 0;
    }
    return fcm_ordered(kind, x < y, x == y, x > y);
}
static int fcm_test_s(int kind, float x, float y) {
    if (x != x || y != y) {
        if (kind != FCM_EQ || is_snan_s(x) || is_snan_s(y)) g_fpexc |= FPSR_IOC;
        return 0;
    }
    return fcm_ordered(kind, x < y, x == y, x > y);
}

/* Integer -> floating point, one conversion per call, behind a call boundary a
 * compiler will not speculate across. Every one of these used to be written as
 * a ternary picking between two conversions of the same operand — `U ?
 * (float)(u32)i : (float)(s32)i`, `x64 ? (double)(s64)r : (double)(s32)r` —
 * which clang turns into both conversions and a select, so the Inexact of the
 * conversion NOT performed landed in the guest's FPSR. `scvtf s3, s1` of
 * 0x80808080 is exact read as a signed 32-bit value (24 significant bits) and
 * inexact read as an unsigned one, so it came back with IXC set. Selecting the
 * *integer* first and converting once is the fix; a 32- or 64-bit signed value
 * and a 32-bit unsigned one all reach the FP conversion as s64, which is exact
 * for every one of them, so only a 64-bit unsigned source needs its own. */
#if defined(__GNUC__) || defined(__clang__)
#define A64_NOSPEC __attribute__((noinline))
#else
#define A64_NOSPEC
#endif
/* The conversion's Inexact flag, decided here rather than read from the
 * host: a 32-bit ARM host has no 64-bit-int -> FP instruction, so these
 * casts lower to soft libcalls (__aeabi_l2f and friends) that never touch
 * the host FPSCR -- the result is still correctly rounded, but the flag is
 * lost, and since every integer source funnels through these four helpers,
 * ALL of SCVTF/UCVTF stopped raising IXC there (x86-64 uses cvtsi2ss, i386
 * reaches x87 through fildll, and AArch64 replays scvtf, so only the armv7
 * host ever showed it). An integer is exact in precision p exactly when its
 * significant span -- top set bit down to bottom set bit -- fits in p bits;
 * raising by hand is idempotent beside a host flag where one does fire. */
static void i2f_inexact(u64 mag, int prec) {
    if (!mag) return;
    if ((63 - __builtin_clzll(mag)) - __builtin_ctzll(mag) + 1 > prec)
        g_fpexc |= FPSR_IXC;
}
static A64_NOSPEC double d_from_s64(s64 v) {
    i2f_inexact(v < 0 ? -(u64)v : (u64)v, 53);
    return (double)v;
}
static A64_NOSPEC double d_from_u64(u64 v) {
    i2f_inexact(v, 53);
    return (double)v;
}
static A64_NOSPEC float  f_from_s64(s64 v) {
    i2f_inexact(v < 0 ? -(u64)v : (u64)v, 24);
    return (float)v;
}
static A64_NOSPEC float  f_from_u64(u64 v) {
    i2f_inexact(v, 24);
    return (float)v;
}

/* FSQRT's Invalid-Operation flag, raised here rather than inherited from
 * whatever the host's sqrt() turns out to be. A negative operand is invalid
 * (-0.0 is not, and returns -0.0); a signaling NaN is invalid too. Both come
 * for free when __builtin_sqrt inlines to the hardware instruction, and not at
 * all when it becomes a libm call that answers a negative input with a
 * ready-made NaN — Bionic's does, so on Termux `fsqrt d0, #-1.0` raised
 * nothing. The result is already host-independent (fpnan_* below). */
static void fsqrt_raise_d(double x) {
    if (x != x) { if (is_snan_d(x)) g_fpexc |= FPSR_IOC; return; }
    if (x < 0.0) g_fpexc |= FPSR_IOC;
}
static void fsqrt_raise_s(float x) {
    if (x != x) { if (is_snan_s(x)) g_fpexc |= FPSR_IOC; return; }
    if (x < 0.0f) g_fpexc |= FPSR_IOC;
}

/* ---- Fused multiply-add: result AND flags derived by hand on armv7 ----
 *
 * On an armv7 host __builtin_fma cannot inline (VFPv3 has no fused
 * instruction), so it becomes a call into libm — and Bionic's software
 * fma/fmaf (FreeBSD msun's) fails this emulator twice over. Its internal
 * double-double additions raise Inexact into the live FPSCR even when the
 * fused result is exact (glibc saves and restores the environment on
 * purpose, which is why no x86-64 or i386 build ever showed it). And its
 * fmaf MIS-ROUNDS: when the double-domain sum lands exactly on a float
 * halfway pattern and the true value sits below it, the fixup path answers
 * one ulp too large — fmaf(1.5, 1+2^-23, -2^-60) comes back 0x3fc00002
 * where round-to-nearest is 0x3fc00001, probed native on the device. So
 * this path trusts libm for nothing: both the result and IOC/OFC/UFC/IXC
 * are computed from an exact integer decomposition of n*m + a, and no libm
 * or fenv call is made at all.
 *
 * The decomposition (fused_eval): the 106-bit product and the addend are
 * aligned into a 128-bit window whose floor sits at most 125 below the
 * higher operand's top bit. An operand whose low bits fall outside the
 * window is smaller than the other by at least 2^20 (its whole span lies
 * that far down), so compressing the lost bits into one sticky flag can
 * neither be cancelled away nor turn an exact sum inexact: the kept
 * magnitude stays >= 2^124 of the window, far wider than either precision.
 * The exact (magnitude, window-floor, sticky) triple then rounds to
 * nearest-even — the only mode this can meet: the emulator never moves the
 * host rounding mode, guest FPCR.RMode being honored only in the software
 * paths (FRINT, the converts, the f16 narrows), a documented model corner.
 * Flags fall out of the same pass: Inexact = any bit lost to rounding or
 * the window; Overflow = the rounded unbounded-exponent value's top past
 * the format (which in RN is exactly ARM's FPRound condition); Underflow =
 * tiny before rounding, as the architecture asks, and inexact. NaNs,
 * infinities and zero operands are screened first (invalid = any sNaN, or
 * inf*0 whatever the addend, or an addend infinity opposing an infinite
 * product; every other special case is exact and flag-free; a NaN answer
 * here is only a gate — the call sites' fpnan_muladd_* pick the payload).
 * The core is fenv-free integer code, differentially validated against
 * x86-64 FMA hardware; A64_FMA_DERIVE_FORCE builds this path on any host
 * so the whole suite can run over it against the oracle. */
#if defined(__arm__) || defined(A64_FMA_DERIVE_FORCE)
#define A64_FMA_DERIVE 1
#endif

#ifdef A64_FMA_DERIVE
typedef struct { u64 hi, lo; } fx128;

static int fx_msb(fx128 v) {                /* index of top set bit; v != 0 */
    return v.hi ? 127 - __builtin_clzll(v.hi) : 63 - __builtin_clzll(v.lo);
}
static fx128 fx_shl(fx128 v, int s) {       /* s in [0,127], result fits */
    if (s >= 64)     { v.hi = v.lo << (s - 64); v.lo = 0; }
    else if (s > 0)  { v.hi = (v.hi << s) | (v.lo >> (64 - s)); v.lo <<= s; }
    return v;
}
static fx128 fx_shr_sticky(fx128 v, int s, int *lost) {   /* s >= 1 */
    if (s >= 128) { *lost |= (v.hi | v.lo) != 0; v.hi = v.lo = 0; }
    else if (s >= 64) {
        *lost |= (v.lo | (v.hi & ones((unsigned)(s - 64)))) != 0;
        v.lo = v.hi >> (s - 64); v.hi = 0;
    } else {
        *lost |= (v.lo & ones((unsigned)s)) != 0;
        v.lo = (v.lo >> s) | (v.hi << (64 - s)); v.hi >>= s;
    }
    return v;
}
static int fx_cmp(fx128 a, fx128 b) {
    if (a.hi != b.hi) return a.hi < b.hi ? -1 : 1;
    if (a.lo != b.lo) return a.lo < b.lo ? -1 : 1;
    return 0;
}
static fx128 fx_add(fx128 a, fx128 b) {     /* no overflow by construction */
    fx128 r; r.lo = a.lo + b.lo; r.hi = a.hi + b.hi + (r.lo < a.lo); return r;
}
static fx128 fx_sub(fx128 a, fx128 b) {     /* a >= b */
    fx128 r; r.lo = a.lo - b.lo; r.hi = a.hi - b.hi - (a.lo < b.lo); return r;
}

/* r = (-1)^psign*P*2^pe + (-1)^asign*am*2^ae evaluated exactly, then rounded
 * to nearest-even: the FPSR flags come back as the return value, the
 * result's raw bit pattern lands in *rraw. P is the exact product (nonzero),
 * am the addend mantissa (0 = no addend; then ae/asign are ignored).
 * prec/emin/wmax/wtiny/width/eoff parameterize the format:
 * 53/-1074/1023/-1023/64/1075 for double, 24/-149/127/-127/32/150 for
 * float (eoff turns the mantissa-lsb exponent back into the biased field,
 * the inverse of fused_unpack_*). */
static u32 fused_eval(fx128 P, int pe, int psign, u64 am, int ae, int asign,
                      int prec, int emin, int wmax, int wtiny,
                      int width, int eoff, u64 *rraw) {
    fx128 M;
    int F, sticky = 0, rsign = psign;
    if (!am) { M = P; F = pe; }
    else {
        int topp = pe + fx_msb(P);
        int topa = ae + 63 - __builtin_clzll(am);
        int topmax = topp > topa ? topp : topa;
        F = pe < ae ? pe : ae;                /* full precision when it fits */
        if (F < topmax - 125) F = topmax - 125;
        int p_lost = 0, a_lost = 0;
        fx128 A0 = { 0, am };
        fx128 Pw = pe >= F ? fx_shl(P, pe - F) : fx_shr_sticky(P, F - pe, &p_lost);
        fx128 Aw = ae >= F ? fx_shl(A0, ae - F) : fx_shr_sticky(A0, F - ae, &a_lost);
        if (psign == asign) { M = fx_add(Pw, Aw); sticky = p_lost | a_lost; }
        else {
            int cmp = fx_cmp(Pw, Aw);
            if (!cmp && !p_lost && !a_lost) { *rraw = 0; return 0; } /* n*m == -a: exact +0 in RN */
            int p_big = cmp > 0 || (!cmp && p_lost);
            fx128 big  = p_big ? Pw : Aw, small = p_big ? Aw : Pw;
            int small_lost = p_big ? a_lost : p_lost;
            rsign = p_big ? psign : asign;
            M = fx_sub(big, small);
            if (small_lost) {           /* big - (small + tail): borrow one */
                if (M.hi | M.lo) M = fx_sub(M, (fx128){ 0, 1 });
                sticky = 1;
            } else
                sticky = p_big ? p_lost : a_lost;
        }
    }
    u64 sbit = (u64)rsign << (width - 1);
    if (!M.hi && !M.lo) { *rraw = sbit; return FPSR_IXC; } /* unreachable: window keeps 2^124 */
    int k = fx_msb(M), W = F + k;
    int low = k - (prec - 1);               /* lowest bit the format keeps */
    if (emin - F > low) low = emin - F;     /* subnormal quantum floor */
    u64 RM;
    int E, inexact = sticky;
    if (low <= 0) {                         /* every bit fits; maybe denormal-form */
        RM = M.lo; E = F;
        int sh = (prec - 1) - k;            /* normalize up, floored at emin */
        if (sh > E - emin) sh = E - emin;
        if (sh > 0) { RM <<= sh; E -= sh; }
    } else {                                /* round at bit `low` (guard below it) */
        int lost2 = 0;
        fx128 q = low > 1 ? fx_shr_sticky(M, low - 1, &lost2) : M;
        int guard = (int)(q.lo & 1);        /* q < 2^54: span <= prec+1 bits */
        RM = q.lo >> 1;
        E = F + low;
        sticky |= lost2;
        inexact = sticky | guard;
        if (guard && (sticky || (RM & 1))) {
            RM++;                           /* nearest-even */
            if (RM == 1ull << prec) { RM >>= 1; E++; }
        }
    }
    if (!RM) {                              /* everything rounded away */
        *rraw = sbit;                       /* signed zero, RN keeps the sign */
        return FPSR_IXC | FPSR_UFC;
    }
    int rtop = E + 63 - __builtin_clzll(RM);
    if (rtop > wmax) {                      /* ARM FPRound overflow, in RN */
        *rraw = sbit | (ones((unsigned)(width - prec)) << (prec - 1));  /* inf */
        return FPSR_OFC | FPSR_IXC;
    }
    u32 fl = 0;
    if (inexact) {
        fl = FPSR_IXC;
        if (W <= wtiny) fl |= FPSR_UFC;     /* tiny before rounding */
    }
    if (RM < 1ull << (prec - 1))            /* subnormal: E == emin here */
        *rraw = sbit | RM;
    else
        *rraw = sbit | ((u64)(E + eoff) << (prec - 1)) |
                (RM & (ones((unsigned)(prec - 1))));
    return fl;
}

static void fused_unpack_d(double v, int *sg, u64 *mant, int *e) {
    u64 b; memcpy(&b, &v, 8);
    int be = (int)((b >> 52) & 0x7ff);
    *sg = (int)(b >> 63);
    *mant = (b & 0xfffffffffffffULL) | (be ? 1ULL << 52 : 0);
    *e = (be ? be : 1) - 1075;              /* v = mant * 2^e */
}
static void fused_unpack_s(float v, int *sg, u64 *mant, int *e) {
    u32 b; memcpy(&b, &v, 4);
    int be = (int)((b >> 23) & 0xff);
    *sg = (int)(b >> 31);
    *mant = (b & 0x7fffffu) | (be ? 1u << 23 : 0);
    *e = (be ? be : 1) - 150;
}

/* The a64_fma/a64_fmaf the fused sites call: screen the special operands
 * (any NaN answer is just a gate — the call sites' fpnan_muladd_* decide the
 * payload), then hand the exact product and addend to fused_eval for the
 * rounded result and the flags. Entirely libm- and fenv-free: nothing here
 * touches the host FP state, so there is nothing to fence. */
static double a64_fma(double n, double m, double a) {
    if (__builtin_isnan(n) || __builtin_isnan(m) || __builtin_isnan(a)) {
        int inf0 = (__builtin_isinf(n) && m == 0.0) || (n == 0.0 && __builtin_isinf(m));
        if (is_snan_d(n) || is_snan_d(m) || is_snan_d(a) || inf0)
            g_fpexc |= FPSR_IOC;
        return dfl_nan_d();
    }
    if ((__builtin_isinf(n) && m == 0.0) || (n == 0.0 && __builtin_isinf(m))) {
        g_fpexc |= FPSR_IOC;                                   /* inf * 0 */
        return dfl_nan_d();
    }
    int sp = !!__builtin_signbit(n) ^ !!__builtin_signbit(m);
    if (__builtin_isinf(n) || __builtin_isinf(m)) {            /* inf product: */
        if (__builtin_isinf(a) && !!__builtin_signbit(a) != sp) {
            g_fpexc |= FPSR_IOC;                               /* inf - inf */
            return dfl_nan_d();
        }
        return sp ? -__builtin_inf() : __builtin_inf();        /* exact inf */
    }
    if (__builtin_isinf(a)) return a;                          /* exact */
    if (n == 0.0 || m == 0.0) {                                /* exact +-0 or a */
        if (a == 0.0) return sp && !!__builtin_signbit(a) ? -0.0 : 0.0;
        return a;
    }
    int sn, sm, sa, en, em, ea; u64 mn, mm, ma, rraw;
    fused_unpack_d(n, &sn, &mn, &en);
    fused_unpack_d(m, &sm, &mm, &em);
    fx128 P = { umulh64(mn, mm), mn * mm };
    if (a == 0.0) {
        g_fpexc |= fused_eval(P, en + em, sn ^ sm, 0, 0, 0,
                              53, -1074, 1023, -1023, 64, 1075, &rraw);
    } else {
        fused_unpack_d(a, &sa, &ma, &ea);
        g_fpexc |= fused_eval(P, en + em, sn ^ sm, ma, ea, sa,
                              53, -1074, 1023, -1023, 64, 1075, &rraw);
    }
    double r; memcpy(&r, &rraw, 8); return r;
}
static float a64_fmaf(float n, float m, float a) {
    if (__builtin_isnan(n) || __builtin_isnan(m) || __builtin_isnan(a)) {
        int inf0 = (__builtin_isinf(n) && m == 0.0f) || (n == 0.0f && __builtin_isinf(m));
        if (is_snan_s(n) || is_snan_s(m) || is_snan_s(a) || inf0)
            g_fpexc |= FPSR_IOC;
        return dfl_nan_s();
    }
    if ((__builtin_isinf(n) && m == 0.0f) || (n == 0.0f && __builtin_isinf(m))) {
        g_fpexc |= FPSR_IOC;
        return dfl_nan_s();
    }
    int sp = !!__builtin_signbit(n) ^ !!__builtin_signbit(m);
    if (__builtin_isinf(n) || __builtin_isinf(m)) {
        if (__builtin_isinf(a) && !!__builtin_signbit(a) != sp) {
            g_fpexc |= FPSR_IOC;
            return dfl_nan_s();
        }
        return sp ? -__builtin_inff() : __builtin_inff();
    }
    if (__builtin_isinf(a)) return a;
    if (n == 0.0f || m == 0.0f) {
        if (a == 0.0f) return sp && !!__builtin_signbit(a) ? -0.0f : 0.0f;
        return a;
    }
    int sn, sm, sa, en, em, ea; u64 mn, mm, ma, rraw;
    fused_unpack_s(n, &sn, &mn, &en);
    fused_unpack_s(m, &sm, &mm, &em);
    fx128 P = { 0, mn * mm };               /* 24x24: one limb is enough */
    if (a == 0.0f) {
        g_fpexc |= fused_eval(P, en + em, sn ^ sm, 0, 0, 0,
                              24, -149, 127, -127, 32, 150, &rraw);
    } else {
        fused_unpack_s(a, &sa, &ma, &ea);
        g_fpexc |= fused_eval(P, en + em, sn ^ sm, ma, ea, sa,
                              24, -149, 127, -127, 32, 150, &rraw);
    }
    u32 rb = (u32)rraw;
    float r; memcpy(&r, &rb, 4); return r;
}
#else
#define a64_fma  __builtin_fma
#define a64_fmaf __builtin_fmaf
#endif

/* Set NZCV from an FP compare of a vs b (ordered), per the architecture. */
static void fp_set_flags(CPU *c, int cmp /* -1 lt, 0 eq, 1 gt, 2 unordered */) {
    u32 n = 0;
    switch (cmp) {
        case -1: n = PS_N; break;                 /* less than       N=1 */
        case  0: n = PS_Z | PS_C; break;          /* equal           Z,C */
        case  1: n = PS_C; break;                 /* greater than    C   */
        default: n = PS_C | PS_V; break;          /* unordered       C,V */
    }
    c->nzcv = n;
}

/* FP arithmetic op selectors + kernels. fop_d/fop_s (defined below with the
 * vector helpers) implement FMAX/FMIN with ARM NaN-propagation and +0>-0, and
 * FMAXNM/FMINNM returning the numeric operand — shared by the scalar and vector
 * paths so both agree with the architecture (and with each other). */
#define FOP_ADD 0
#define FOP_SUB 1
#define FOP_MUL 2
#define FOP_DIV 3
#define FOP_MLA 4
#define FOP_MLS 5
#define FOP_MAX 6
#define FOP_MIN 7
#define FOP_MAXNM 8
#define FOP_MINNM 9
#define FOP_ABD 10
#define FOP_MULX 11
#define FOP_RECPS 12
#define FOP_RSQRTS 13
static double fop_d(unsigned op, double n, double m, double d);
static float  fop_s(unsigned op, float  n, float  m, float  d);

static void exec_fp_scalar(CPU *c, u32 insn) {
    unsigned ftype = BITS(23, 22), Rn = BITS(9, 5), Rd = BITS(4, 0);
    bool dbl = (ftype == 1);

    /* FMOV to/from the high 64 bits of a SIMD reg (ptype=10 => 128-bit variant,
     * NOT half-precision). Lives in the FP<->integer conversion space; must be
     * caught before the ftype!=0/1 half-precision deferral below. */
    if (BITS(28, 24) == 0x1e && BIT(21) == 1 && BITS(15, 10) == 0 &&
        BIT(31) == 1 && ftype == 2 && BITS(20, 19) == 1) {
        unsigned opcode = BITS(18, 16);
        if (opcode == 6) { set_x(c, Rd, c->v[Rn].d[1]); return; }   /* FMOV Xd, Vn.D[1] */
        if (opcode == 7) { c->v[Rd].d[1] = reg_x(c, Rn); return; }  /* FMOV Vd.D[1], Xn */
    }

    /* Half-precision FCVT: FP data-processing (1 source). opcode 0x4/0x5 widen
     * from half; 0x7 narrows to half. Handled ahead of the general half-
     * precision deferral below. BIT(21)==1 && BITS(14,10)==0x10 uniquely
     * selects the 1-source group (BITS(28,24)==0x1e is already guaranteed by
     * the exec_fpsimd dispatch), excluding FP<->int/fixed, compare, and imm. */
    if (BIT(21) == 1 && BITS(14, 10) == 0x10) {
        unsigned opc = BITS(20, 15);
        if (opc == 0x4 && ftype == 3) { fp_wr_s(c, Rd, fcvt_h2s(fp_rd_h(c, Rn))); return; }        /* FCVT Sd,Hn */
        if (opc == 0x5 && ftype == 3) { fp_wr_d(c, Rd, (double)fcvt_h2s(fp_rd_h(c, Rn))); return; } /* FCVT Dd,Hn */
        if (opc == 0x7 && ftype == 0) { fp_wr_h(c, Rd, f64_to_f16((double)fp_rd_s(c, Rn))); return; } /* FCVT Hd,Sn */
        if (opc == 0x7 && ftype == 1) { fp_wr_h(c, Rd, f64_to_f16(fp_rd_d(c, Rn))); return; }         /* FCVT Hd,Dn */
    }

    /* FMOV between a general register and a half register (ftype=3): a raw
     * 16-bit move (no conversion), in the FP<->int space (BITS(15,10)==0).
     * Emitted to materialize _Float16 constants (memcpy). */
    if (ftype == 3 && BIT(21) == 1 && BITS(15, 10) == 0 && BITS(20, 19) == 0) {
        unsigned opcode = BITS(18, 16);
        if (opcode == 6) { set_x(c, Rd, c->v[Rn].h[0]); return; }                          /* FMOV Wd, Hn */
        if (opcode == 7) { c->v[Rd].d[0] = (u16)reg_x(c, Rn); c->v[Rd].d[1] = 0; return; }  /* FMOV Hd, Wn */
    }

    /* Half-precision (ftype=3) scalar data-processing: FP immediate, compare,
     * FCCMP, FCSEL, and the 1-source (FMOV/FABS/FNEG/FSQRT/FRINT) and 2-source
     * (FADD/FSUB/FMUL/FDIV/FMAX/FMIN/FMAXNM/FMINNM/FNMUL) groups. Operands widen
     * h->double and compute in double; the single narrow-to-half via f64_to_f16
     * is exact because double's 53-bit mantissa exceeds 2*11+2 (no double-round).
     * FP<->integer (except FMOV above) and FP<->fixed converts stay UNDEF. */
    if (ftype == 3 && BIT(21) == 1 && BITS(15, 10) != 0) {
        unsigned o2 = BITS(11, 10);
        if (o2 == 0 && BIT(12) == 1) {                    /* FMOV Hd, #imm */
            fp_wr_h(c, Rd, vfp_imm16(BITS(20, 13))); return;
        }
        if (o2 == 0 && BIT(13) == 1) {                    /* FCMP / FCMPE (with 0.0 if opcode2<3>) */
            unsigned Rm = BITS(20, 16); bool with_zero = BIT(3);
            double a = f16_to_f64(fp_rd_h(c, Rn));
            double b = with_zero ? 0.0 : f16_to_f64(fp_rd_h(c, Rm));
            fp_set_flags(c, fp_compare_d(a, b, BIT(4))); return;
        }
        if (o2 == 0 && BIT(14) == 1) {                    /* FP data-processing (1 source) */
            unsigned opc = BITS(20, 15); double r;
            double x = f16_to_f64(fp_rd_h(c, Rn));
            switch (opc) {
                case 0x0: fp_wr_h(c, Rd, fp_rd_h(c, Rn)); return;      /* FMOV  */
                case 0x1: r = __builtin_fabs(x); break;               /* FABS  */
                case 0x2: r = -x; break;                              /* FNEG  */
                case 0x3: fsqrt_raise_d(x); r = fpnan_d(__builtin_sqrt(x), x, x); break; /* FSQRT */
                case 0x8: r = frint_d(x, 0, 0); break;                /* FRINTN */
                case 0x9: r = frint_d(x, 1, 0); break;                /* FRINTP */
                case 0xa: r = frint_d(x, 2, 0); break;                /* FRINTM */
                case 0xb: r = frint_d(x, 3, 0); break;                /* FRINTZ */
                case 0xc: r = frint_d(x, 4, 0); break;                /* FRINTA */
                case 0xe: case 0xf:                                   /* FRINTX/I */
                    r = frint_d(x, (int)((c->fpcr >> 22) & 3), opc == 0xe); break;
                default: fpsimd_undef(c, insn); return;
            }
            fp_wr_h(c, Rd, f64_to_f16(r)); return;
        }
        if (o2 == 2) {                                    /* FP data-processing (2 source) */
            unsigned Rm = BITS(20, 16), opc = BITS(15, 12); double r;
            double a = f16_to_f64(fp_rd_h(c, Rn)), b = f16_to_f64(fp_rd_h(c, Rm));
            switch (opc) {
                case 0x0: r = fpnan_d(a * b, a, b); break;        /* FMUL   */
                case 0x1: r = fpnan_d(a / b, a, b); break;        /* FDIV   */
                case 0x2: r = fpnan_d(a + b, a, b); break;        /* FADD   */
                case 0x3: r = fpnan_d(a - b, a, b); break;        /* FSUB   */
                case 0x4: r = fop_d(FOP_MAX,   a, b, 0.0); break; /* FMAX   */
                case 0x5: r = fop_d(FOP_MIN,   a, b, 0.0); break; /* FMIN   */
                case 0x6: r = fop_d(FOP_MAXNM, a, b, 0.0); break; /* FMAXNM */
                case 0x7: r = fop_d(FOP_MINNM, a, b, 0.0); break; /* FMINNM */
                case 0x8: r = -fpnan_d(a * b, a, b); break;       /* FNMUL  */
                default: fpsimd_undef(c, insn); return;
            }
            fp_wr_h(c, Rd, f64_to_f16(r)); return;
        }
        if (o2 == 3) {                                    /* FCSEL */
            unsigned Rm = BITS(20, 16), cond = BITS(15, 12);
            fp_wr_h(c, Rd, fp_rd_h(c, cond_holds(c, cond) ? Rn : Rm)); return;
        }
        if (o2 == 1) {                                    /* FCCMP / FCCMPE */
            unsigned Rm = BITS(20, 16), cond = BITS(15, 12), nzcv = BITS(3, 0);
            if (cond_holds(c, cond)) {
                double a = f16_to_f64(fp_rd_h(c, Rn)), b = f16_to_f64(fp_rd_h(c, Rm));
                fp_set_flags(c, fp_compare_d(a, b, BIT(4)));
            } else {
                c->nzcv = ((nzcv & 8) ? PS_N : 0) | ((nzcv & 4) ? PS_Z : 0) |
                          ((nzcv & 2) ? PS_C : 0) | ((nzcv & 1) ? PS_V : 0);
            }
            return;
        }
    }

    /* Half-precision (ftype=3) FP<->integer converts (GPR form): SCVTF/UCVTF
     * (int->half) and FCVT{N,P,M,Z,A}{S,U} (half->int). Widen h->double / narrow
     * once via f64_to_f16 (exact, 53>=2*11+2); round + saturate reuse the shared
     * fround_mode / fcvt_to_int helpers so half matches the S/D forms and qemu.
     * FMOV general<->half (opcode 6/7) is handled above and returns before here. */
    if (ftype == 3 && BITS(28, 24) == 0x1e && BIT(21) == 1 && BITS(15, 10) == 0) {
        unsigned sf = BIT(31), rmode = BITS(20, 19), opcode = BITS(18, 16);
        if (opcode == 2 || opcode == 3) {                 /* SCVTF / UCVTF: int -> half */
            u64 rv = reg_x(c, Rn);
            double iv = (opcode == 2) ? d_from_s64(sf ? (s64)rv : (s32)rv)
                                      : (sf ? d_from_u64(rv) : d_from_s64((u32)rv));
            fp_wr_h(c, Rd, f64_to_f16(iv)); return;
        }
        if (opcode <= 1 || opcode == 4 || opcode == 5) {  /* FCVT{N,P,M,Z,A}{S,U}: half -> int */
            double x0 = f16_to_f64(fp_rd_h(c, Rn));
            double r = fround_mode(x0, (opcode >= 4) ? 4 : (int)rmode);
            set_x(c, Rd, fcvt_to_int(r, x0, (opcode & 1) == 0, sf != 0)); return;
        }
    }

    /* Half-precision (ftype=3) FP<->fixed-point converts (GPR form, bit21==0):
     * the integer side carries #fbits fractional bits (fbits = 64 - scale).
     * SCVTF/UCVTF divide by 2^fbits; FCVTZS/FCVTZU multiply then round toward
     * zero (saturating). Same widen/narrow-in-double approach as above. */
    if (ftype == 3 && BIT(21) == 0) {
        unsigned sf = BIT(31), rmode = BITS(20, 19), opcode = BITS(18, 16);
        unsigned fbits = 64 - BITS(15, 10);
        u64 pb = (u64)(fbits + 1023) << 52; double pow2; memcpy(&pow2, &pb, 8); /* 2^fbits, exact */
        if (rmode == 0 && (opcode == 2 || opcode == 3)) {       /* SCVTF / UCVTF: fixed -> half */
            u64 rv = reg_x(c, Rn);
            double iv = (opcode == 2) ? d_from_s64(sf ? (s64)rv : (s32)rv)
                                      : (sf ? d_from_u64(rv) : d_from_s64((u32)rv));
            fp_wr_h(c, Rd, f64_to_f16(iv / pow2)); return;
        }
        if (rmode == 3 && (opcode == 0 || opcode == 1)) {       /* FCVTZS / FCVTZU: half -> fixed */
            set_x(c, Rd, fcvt_fixed(f16_to_f64(fp_rd_h(c, Rn)) * pow2,
                                     opcode == 0, sf != 0)); return;
        }
    }

    if (ftype != 0 && ftype != 1) { fpsimd_undef(c, insn); return; }  /* half: on demand */

    /* Floating-point <-> integer / fixed-point conversion (bit21 distinguishes). */
    if (BITS(28, 24) == 0x1e && BIT(21) == 1 && BITS(15, 10) == 0) {
        unsigned sf = BIT(31), rmode = BITS(20, 19), opcode = BITS(18, 16);
        bool x64 = sf != 0;
        switch ((rmode << 3) | opcode) {
            case (0 << 3) | 2:  /* SCVTF (signed int -> fp) */
                if (dbl) fp_wr_d(c, Rd, d_from_s64(x64 ? (s64)reg_x(c, Rn) : (s32)reg_x(c, Rn)));
                else     fp_wr_s(c, Rd, f_from_s64(x64 ? (s64)reg_x(c, Rn) : (s32)reg_x(c, Rn)));
                return;
            case (0 << 3) | 3:  /* UCVTF (unsigned int -> fp) */
                if (dbl) fp_wr_d(c, Rd, x64 ? d_from_u64(reg_x(c, Rn)) : d_from_s64((u32)reg_x(c, Rn)));
                else     fp_wr_s(c, Rd, x64 ? f_from_u64(reg_x(c, Rn)) : f_from_s64((u32)reg_x(c, Rn)));
                return;
            case (0 << 3) | 6:  /* FMOV (fp -> general) */
                if (dbl) set_x(c, Rd, c->v[Rn].d[0]); else set_x(c, Rd, c->v[Rn].s[0]);
                return;
            case (0 << 3) | 7:  /* FMOV (general -> fp) */
                if (dbl) { c->v[Rd].d[0] = reg_x(c, Rn); c->v[Rd].d[1] = 0; }
                else     { c->v[Rd].d[0] = (u32)reg_x(c, Rn); c->v[Rd].d[1] = 0; }
                return;
            case (3 << 3) | 6: {  /* FJCVTZS (FEAT_JSCVT): D -> Wd, ECMAScript ToInt32 */
                if (!dbl || sf) break;         /* only the double -> W form exists */
                double v = fp_rd_d(c, Rn);
                u32 res; int exact = 0;
                if (v != v || v == __builtin_inf() || v == -__builtin_inf()) {
                    res = 0;                   /* NaN / Inf -> 0, Z clear */
                    g_fpexc |= FPSR_IOC;       /* FPToFixedJS: invalid */
                } else {
                    double t = f_trunc(v);     /* round toward zero, then wrap mod 2^32 */
                    if (__builtin_fabs(t) < 9223372036854775808.0) {
                        res = (u32)d_to_s64_exact(t);   /* no cast: see the helper */
                        /* -0.0 is "inexact" for JavaScript: int32 0 round-trips
                         * to +0.0, and engines use Z to detect exactly that. */
                        exact = (t == v && t >= -2147483648.0 && t <= 2147483647.0 &&
                                 !(v == 0.0 && __builtin_signbit(v)));
                        /* flags: wrap -> IOC; in-range rounding -> IXC (the
                         * -0.0 Z quirk is Z-only, not a flag) */
                        if (t < -2147483648.0 || t > 2147483647.0) g_fpexc |= FPSR_IOC;
                        else if (t != v) g_fpexc |= FPSR_IXC;
                    } else {
                        g_fpexc |= FPSR_IOC;   /* far outside int32: wrapped */
                        /* |t| >= 2^63 is outside what d_to_s64_exact answers for
                         * (it saturates instead of wrapping), so take the low 32
                         * bits from the significand directly; they are all zero
                         * once the unbiased exponent reaches 84. */
                        u64 raw = c->v[Rn].d[0];
                        int e = (int)((raw >> 52) & 0x7ff) - 1023;
                        u64 frac = (raw & 0xfffffffffffffULL) | (1ULL << 52);
                        u32 lo = (e - 52 >= 32) ? 0 : (u32)(frac << (e - 52));
                        res = (raw >> 63) ? (u32)0 - lo : lo;
                    }
                }
                c->nzcv = exact ? PS_Z : 0;    /* the full nibble is written */
                set_x(c, Rd, res);
                return;
            }
            default: break;
        }
        /* FCVT*-to-integer. opcode 000/001 = FCVT{N,P,M,Z}{S,U} with the mode in
         * `rmode`; opcode 100/101 = FCVTA{S,U} (round to nearest, ties away,
         * independent of rmode — used by lround/llround). Even opcode = signed.
         * Saturation matches the architecture's clamping. */
        if (opcode <= 1 || opcode == 4 || opcode == 5) {
            double v = dbl ? fp_rd_d(c, Rn) : (double)fp_rd_s(c, Rn);
            double r;
            if (opcode >= 4) {
                r = f_round(v);                  /* A: nearest, ties away */
            } else {
                switch (rmode) {
                    case 0: r = fround_mode(v, 0); break;  /* N: nearest, ties EVEN */
                    case 1: r = f_ceil(v);  break;   /* P: +inf */
                    case 2: r = f_floor(v); break;   /* M: -inf */
                    default: r = f_trunc(v); break;  /* Z: toward zero */
                }
            }
            set_x(c, Rd, fcvt_to_int(r, v, (opcode & 1) == 0, x64));
            return;
        }
        fpsimd_undef(c, insn); return;
    }

    /* Floating-point <-> fixed-point conversion (bit21==0): the integer side
     * carries #fbits fractional bits (fbits = 64 - scale). SCVTF/UCVTF divide
     * the integer by 2^fbits; FCVTZS/FCVTZU multiply the float by 2^fbits then
     * round toward zero (saturating). Emitted by libc float formatting. */
    if (BIT(21) == 0) {
        unsigned sf = BIT(31), rmode = BITS(20, 19), opcode = BITS(18, 16);
        unsigned fbits = 64 - BITS(15, 10);
        bool x64 = sf != 0;
        u64 pb = (u64)(fbits + 1023) << 52; double pow2; memcpy(&pow2, &pb, 8); /* 2^fbits, exact */
        if (rmode == 0 && (opcode == 2 || opcode == 3)) {       /* SCVTF / UCVTF: fixed -> fp */
            if (dbl) {
                u64 rv = reg_x(c, Rn);
                double iv = (opcode == 2) ? d_from_s64(x64 ? (s64)rv : (s32)rv)
                                          : (x64 ? d_from_u64(rv) : d_from_s64((u32)rv));
                fp_wr_d(c, Rd, iv / pow2);
            } else {
                u64 rv = reg_x(c, Rn);
                float iv = (opcode == 2) ? f_from_s64(x64 ? (s64)rv : (s32)rv)
                                         : (x64 ? f_from_u64(rv) : f_from_s64((u32)rv));
                fp_wr_s(c, Rd, iv / (float)pow2);
            }
            return;
        }
        if (rmode == 3 && (opcode == 0 || opcode == 1)) {       /* FCVTZS / FCVTZU: fp -> fixed */
            set_x(c, Rd, fcvt_fixed((dbl ? fp_rd_d(c, Rn) : (double)fp_rd_s(c, Rn)) * pow2,
                                     opcode == 0, x64));
            return;
        }
        fpsimd_undef(c, insn); return;   /* other bit21==0 encodings: on demand */
    }

    unsigned o2 = BITS(11, 10);
    if (o2 == 0) {
        if (BIT(12) == 1) {                       /* FP immediate */
            unsigned imm8 = BITS(20, 13);
            if (dbl) { u64 b = vfp_imm64(imm8); double t; memcpy(&t, &b, 8); fp_wr_d(c, Rd, t); }
            else     { u32 b = vfp_imm32(imm8); float  t; memcpy(&t, &b, 4); fp_wr_s(c, Rd, t); }
            return;
        }
        if (BIT(13) == 1) {                       /* FP compare */
            unsigned Rm = BITS(20, 16);
            bool with_zero = BIT(3);              /* opcode2<3>: compare with 0.0 */
            int cmp;
            if (dbl) {
                double a = fp_rd_d(c, Rn), b = with_zero ? 0.0 : fp_rd_d(c, Rm);
                cmp = fp_compare_d(a, b, BIT(4));
            } else {
                float a = fp_rd_s(c, Rn), b = with_zero ? 0.0f : fp_rd_s(c, Rm);
                cmp = fp_compare_s(a, b, BIT(4));
            }
            fp_set_flags(c, cmp);
            return;
        }
        if (BIT(14) == 1) {                       /* FP data-processing (1 source) */
            unsigned opc = BITS(20, 15);
            switch (opc) {
                case 0x0: if (dbl) fp_wr_d(c, Rd, fp_rd_d(c, Rn)); else fp_wr_s(c, Rd, fp_rd_s(c, Rn)); return; /* FMOV */
                case 0x1: if (dbl) fp_wr_d(c, Rd, __builtin_fabs(fp_rd_d(c, Rn))); else fp_wr_s(c, Rd, __builtin_fabsf(fp_rd_s(c, Rn))); return; /* FABS */
                case 0x2: if (dbl) fp_wr_d(c, Rd, -fp_rd_d(c, Rn)); else fp_wr_s(c, Rd, -fp_rd_s(c, Rn)); return; /* FNEG */
                case 0x3: {                                        /* FSQRT */
                    if (dbl) { double x = fp_rd_d(c, Rn); fsqrt_raise_d(x); fp_wr_d(c, Rd, fpnan_d(__builtin_sqrt(x), x, x)); }
                    else     { float  x = fp_rd_s(c, Rn); fsqrt_raise_s(x); fp_wr_s(c, Rd, fpnan_s(__builtin_sqrtf(x), x, x)); }
                    return;
                }
                case 0x4: if (ftype == 1) fp_wr_s(c, Rd, (float)fp_rd_d(c, Rn)); else fpsimd_undef(c, insn); return;  /* FCVT to single (from double) */
                case 0x5: if (ftype == 0) fp_wr_d(c, Rd, (double)fp_rd_s(c, Rn)); else fpsimd_undef(c, insn); return; /* FCVT to double (from single) */
                /* FRINT<mode>: 0x8 N(even), 0x9 P, 0xa M, 0xb Z, 0xc A(away),
                 * 0xe X and 0xf I use the current FPCR.RMode (bits 23:22). */
                case 0x8: case 0x9: case 0xa: case 0xb: case 0xc:
                case 0xe: case 0xf: {
                    int rm;
                    switch (opc) {
                        case 0x8: rm = 0; break;   /* FRINTN: nearest, ties even */
                        case 0x9: rm = 1; break;   /* FRINTP: +inf */
                        case 0xa: rm = 2; break;   /* FRINTM: -inf */
                        case 0xb: rm = 3; break;   /* FRINTZ: zero */
                        case 0xc: rm = 4; break;   /* FRINTA: nearest, ties away */
                        default: {                 /* FRINTX / FRINTI: FPCR.RMode */
                            static const int map[4] = { 0, 1, 2, 3 };
                            rm = map[(c->fpcr >> 22) & 3];
                            break;
                        }
                    }
                    if (dbl) fp_wr_d(c, Rd, frint_d(fp_rd_d(c, Rn), rm, opc == 0xe));
                    else     fp_wr_s(c, Rd, (float)frint_d((double)fp_rd_s(c, Rn), rm, opc == 0xe));
                    return;
                }
                default: fpsimd_undef(c, insn); return;
            }
        }
        fpsimd_undef(c, insn); return;
    }

    if (o2 == 2) {                                /* FP data-processing (2 source) */
        unsigned Rm = BITS(20, 16), opc = BITS(15, 12);
        if (dbl) {
            double a = fp_rd_d(c, Rn), b = fp_rd_d(c, Rm), r;
            switch (opc) {
                case 0x0: r = fpnan_d(a * b, a, b); break;     /* FMUL */
                case 0x1: r = fpnan_d(a / b, a, b); break;     /* FDIV */
                case 0x2: r = fpnan_d(a + b, a, b); break;     /* FADD */
                case 0x3: r = fpnan_d(a - b, a, b); break;     /* FSUB */
                case 0x4: r = fop_d(FOP_MAX,   a, b, 0.0); break;  /* FMAX   */
                case 0x5: r = fop_d(FOP_MIN,   a, b, 0.0); break;  /* FMIN   */
                case 0x6: r = fop_d(FOP_MAXNM, a, b, 0.0); break;  /* FMAXNM */
                case 0x7: r = fop_d(FOP_MINNM, a, b, 0.0); break;  /* FMINNM */
                /* FPNeg after FPMul, and FPNeg flips a NaN's sign too, so the
                 * canonical result here is the NEGATIVE default NaN. */
                case 0x8: r = -fpnan_d(a * b, a, b); break;    /* FNMUL */
                default: fpsimd_undef(c, insn); return;
            }
            fp_wr_d(c, Rd, r);
        } else {
            float a = fp_rd_s(c, Rn), b = fp_rd_s(c, Rm), r;
            switch (opc) {
                case 0x0: r = fpnan_s(a * b, a, b); break;
                case 0x1: r = fpnan_s(a / b, a, b); break;
                case 0x2: r = fpnan_s(a + b, a, b); break;
                case 0x3: r = fpnan_s(a - b, a, b); break;
                case 0x4: r = fop_s(FOP_MAX,   a, b, 0.0f); break;  /* FMAX   */
                case 0x5: r = fop_s(FOP_MIN,   a, b, 0.0f); break;  /* FMIN   */
                case 0x6: r = fop_s(FOP_MAXNM, a, b, 0.0f); break;  /* FMAXNM */
                case 0x7: r = fop_s(FOP_MINNM, a, b, 0.0f); break;  /* FMINNM */
                case 0x8: r = -fpnan_s(a * b, a, b); break;    /* see above */
                default: fpsimd_undef(c, insn); return;
            }
            fp_wr_s(c, Rd, r);
        }
        return;
    }

    if (o2 == 3) {                                /* FP conditional select (FCSEL) */
        unsigned Rm = BITS(20, 16), cond = BITS(15, 12);
        unsigned src = cond_holds(c, cond) ? Rn : Rm;
        if (dbl) fp_wr_d(c, Rd, fp_rd_d(c, src)); else fp_wr_s(c, Rd, fp_rd_s(c, src));
        return;
    }

    if (o2 == 1) {                                /* FP conditional compare (FCCMP) */
        unsigned Rm = BITS(20, 16), cond = BITS(15, 12), nzcv = BITS(3, 0);
        if (cond_holds(c, cond)) {
            int cmp;
            if (dbl) { double a = fp_rd_d(c, Rn), b = fp_rd_d(c, Rm); cmp = fp_compare_d(a, b, BIT(4)); }
            else     { float  a = fp_rd_s(c, Rn), b = fp_rd_s(c, Rm); cmp = fp_compare_s(a, b, BIT(4)); }
            fp_set_flags(c, cmp);
        } else {
            c->nzcv = ((nzcv & 8) ? PS_N : 0) | ((nzcv & 4) ? PS_Z : 0) |
                      ((nzcv & 2) ? PS_C : 0) | ((nzcv & 1) ? PS_V : 0);
        }
        return;
    }

    fpsimd_undef(c, insn);
}

/* Scalar FP fused multiply-add family (3 source): FMADD/FMSUB/FNMADD/FNMSUB. */
static void exec_fp_dp3(CPU *c, u32 insn) {
    unsigned ftype = BITS(23, 22), Rm = BITS(20, 16), Ra = BITS(14, 10);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0), o1 = BIT(21), o0 = BIT(15);
    if (ftype == 3) {                             /* half: fused in double (exact, no double-round) */
        double n = f16_to_f64(fp_rd_h(c, Rn)), m = f16_to_f64(fp_rd_h(c, Rm)),
               a = f16_to_f64(fp_rd_h(c, Ra)), r;
        if (!o1 && !o0)     r =  a + n * m;       /* FMADD  */
        else if (!o1)       r =  a - n * m;       /* FMSUB  */
        else if (o1 && !o0) r = -a - n * m;       /* FNMADD */
        else                r = -a + n * m;       /* FNMSUB */
        /* Operand order (addend, n, m), each carrying the FPNeg this
         * form applies -- FMSUB of a NaN multiplicand returns it negated. */
        double pa, pn;
        if (!o1 && !o0) { pa = a;  pn =  n; }        /* FMADD  */
        else if (!o1)   { pa = a;  pn = -n; }        /* FMSUB  */
        else if (!o0)   { pa = -a; pn = -n; }        /* FNMADD */
        else            { pa = -a; pn =  n; }        /* FNMSUB */
        fp_wr_h(c, Rd, f64_to_f16(fpnan_muladd_d(r, pa, pn, m))); return;
    }
    if (ftype != 0 && ftype != 1) { fpsimd_undef(c, insn); return; }
    if (ftype == 1) {
        /* Fused: single rounding of n*m+a, matching AArch64 FMADD/FMSUB/FNMADD/
         * FNMSUB. a64_fma is __builtin_fma on hosts whose flags can be trusted
         * (it inlines to a hardware FMA on AArch64 always and x86 with -mfma,
         * and otherwise calls libm's fma — the build links -lm); on armv7 it
         * derives both result and flags by hand because Bionic's software fma
         * leaks its internal Inexact and its fmaf mis-rounds ties (see the
         * fused_eval block above). The JIT inlines this family only where the
         * backend can fuse (native fmadd on AArch64, FMA3 on x86-64); a host
         * without one keeps the exec_a64 helper and still matches bit-for-bit
         * (any correctly-rounded FMA is the same unique answer). */
        double n = fp_rd_d(c, Rn), m = fp_rd_d(c, Rm), a = fp_rd_d(c, Ra), r;
        if (!o1 && !o0) r = a64_fma( n, m,  a);   /* FMADD  */
        else if (!o1)   r = a64_fma(-n, m,  a);   /* FMSUB  */
        else if (o1 && !o0) r = a64_fma(-n, m, -a); /* FNMADD */
        else            r = a64_fma( n, m, -a);   /* FNMSUB */
        /* Operand order (addend, n, m), each carrying the FPNeg this
         * form applies -- FMSUB of a NaN multiplicand returns it negated. */
        double pa, pn;
        if (!o1 && !o0) { pa = a;  pn =  n; }        /* FMADD  */
        else if (!o1)   { pa = a;  pn = -n; }        /* FMSUB  */
        else if (!o0)   { pa = -a; pn = -n; }        /* FNMADD */
        else            { pa = -a; pn =  n; }        /* FNMSUB */
        fp_wr_d(c, Rd, fpnan_muladd_d(r, pa, pn, m));
    } else {
        float n = fp_rd_s(c, Rn), m = fp_rd_s(c, Rm), a = fp_rd_s(c, Ra), r;
        if (!o1 && !o0) r = a64_fmaf( n, m,  a);
        else if (!o1)   r = a64_fmaf(-n, m,  a);
        else if (o1 && !o0) r = a64_fmaf(-n, m, -a);
        else            r = a64_fmaf( n, m, -a);
        /* Operand order (addend, n, m), each carrying the FPNeg this
         * form applies -- FMSUB of a NaN multiplicand returns it negated. */
        float pa, pn;
        if (!o1 && !o0) { pa = a;  pn =  n; }        /* FMADD  */
        else if (!o1)   { pa = a;  pn = -n; }        /* FMSUB  */
        else if (!o0)   { pa = -a; pn = -n; }        /* FNMADD */
        else            { pa = -a; pn =  n; }        /* FNMSUB */
        fp_wr_s(c, Rd, fpnan_muladd_s(r, pa, pn, m));
    }
}

/* Sign-extend an `esize`-bit element value to s64. */
static s64 sx(u64 v, unsigned esize) { return (s64)sign_extend(v, esize); }

/* Wrapping signed arithmetic for the lane maths below. Every *allocated*
 * encoding that reaches these has elements of at most 32 bits, where the
 * result is exact in s64 and nothing ever wraps. What can overflow is the
 * 64-bit element size of the unallocated encodings this decoder executes
 * rather than rejecting (see the note on the fuzzer's chaos mode): there the
 * plain signed operators are undefined behaviour, which a compiler may act on
 * and which does not even agree between hosts -- a 32-bit one builds these out
 * of pairs. Doing the arithmetic in u64 and reinterpreting makes those cases
 * defined, identical everywhere, and unchanged for every real instruction. */
static s64 wadd(s64 x, s64 y) { return (s64)((u64)x + (u64)y); }
static s64 wsub(s64 x, s64 y) { return (s64)((u64)x - (u64)y); }
static s64 wmul(s64 x, s64 y) { return (s64)((u64)x * (u64)y); }
/* |x| as a bit pattern. The negation is unsigned, so INT64_MIN -- which a
 * perfectly legal ABS/SABD on .2d lanes can be handed -- comes back as itself,
 * which is what the architecture's non-saturating absolute value does, rather
 * than being signed overflow. */
static u64 wabs(s64 x) { return x < 0 ? 0u - (u64)x : (u64)x; }

/* ---- integer saturation + register-shift helpers (saturating/shift ops) ---- */
/* Every clamp in the saturating-integer family raises FPSR.QC (sticky). */
static u64 sat_s(s64 v, unsigned e) {
    s64 max = (e >= 64) ? INT64_MAX : (((s64)1 << (e - 1)) - 1);
    s64 min = (e >= 64) ? INT64_MIN : (-((s64)1 << (e - 1)));
    if (v > max) { v = max; g_fpexc |= FPSR_QC; }
    else if (v < min) { v = min; g_fpexc |= FPSR_QC; }
    return (u64)v;
}
/* Clamp an unsigned value to an element mask, flagging the clamp. */
static u64 sat_umask(u64 v, u64 emask) {
    if (v > emask) { g_fpexc |= FPSR_QC; return emask; }
    return v;
}
static u64 sat_u(s64 v, unsigned e) {
    u64 max = (e >= 64) ? ~0ULL : (((u64)1 << e) - 1);
    if (v < 0) { g_fpexc |= FPSR_QC; return 0; }
    if ((u64)v > max) { g_fpexc |= FPSR_QC; return max; }
    return (u64)v;
}
/* Saturating negation, the kernel of SQABS/SQNEG. Negating the most-negative
 * value of the element width saturates. At e < 64 the negation is computed at
 * full s64 width and sat_s clamps it, but at e == 64 negating INT64_MIN is
 * signed overflow: it wraps straight back to INT64_MIN, which sat_s cannot
 * recognize as out of range because INT64_MIN is exactly its lower bound. So
 * the value passed through unclamped and unflagged. Handle it explicitly. */
static u64 sat_neg(s64 v, unsigned e) {
    if (e >= 64 && v == INT64_MIN) { g_fpexc |= FPSR_QC; return (u64)INT64_MAX; }
    return sat_s(-v, e);
}
static u64 ssat_add(s64 a, s64 b, unsigned e) {
    if (e < 64) return sat_s(a + b, e);
    s64 r = (s64)((u64)a + (u64)b);
    if (((a ^ r) & (b ^ r)) < 0) {
        g_fpexc |= FPSR_QC;
        return (a < 0) ? (u64)INT64_MIN : (u64)INT64_MAX;
    }
    return (u64)r;
}
static u64 ssat_sub(s64 a, s64 b, unsigned e) {
    if (e < 64) return sat_s(a - b, e);
    s64 r = (s64)((u64)a - (u64)b);
    if (((a ^ b) & (a ^ r)) < 0) {
        g_fpexc |= FPSR_QC;
        return (a < 0) ? (u64)INT64_MIN : (u64)INT64_MAX;
    }
    return (u64)r;
}
static u64 usat_add(u64 a, u64 b, unsigned e) {
    u64 r = a + b;
    if (e < 64) {
        u64 m = ((u64)1 << e) - 1;
        if (r > m) { g_fpexc |= FPSR_QC; return m; }
        return r;
    }
    if (r < a) { g_fpexc |= FPSR_QC; return ~0ULL; }
    return r;
}
/* USQADD: unsigned accumulator + SIGNED addend, clamped to the unsigned
 * range. The magnitude is formed unsigned so that sa == INT64_MIN (whose
 * negation is not representable) stays well defined. */
static u64 usqadd_sat(u64 d, s64 sa, unsigned e) {
    if (sa >= 0) return usat_add(d, (u64)sa, e);
    u64 mag = (u64)0 - (u64)sa;
    if (d < mag) { g_fpexc |= FPSR_QC; return 0; }
    return d - mag;
}
static u64 usat_sub(u64 a, u64 b, unsigned e) {
    (void)e;
    if (a < b) { g_fpexc |= FPSR_QC; return 0; }
    return a - b;
}

/* FEAT_RDM SQRDMLAH/SQRDMLSH core, shared by the vector, scalar and by-element
 * forms: (d << esize) +/- 2*a*b + (1 << (esize-1)), then one final shift and
 * saturation. The accumulate happens at double width BEFORE the shift, and
 * 2*a*b alone overflows s64 at the INT32_MIN^2 corner, so the sum is formed in
 * two 64-bit words (no __int128: the 32-bit-host build lacks it). esize is 16
 * or 32, so d<<esize + rounding and a*b each fit in s64 on their own; only the
 * doubling of the product can carry into the high word. */
static u64 sqrdmlah_op(s64 d, s64 a, s64 b, unsigned esize, int sub) {
    s64 base = (s64)((u64)d << esize) + ((s64)1 << (esize - 1));
    s64 p = a * b;
    u64 lo = (u64)base, hi = (u64)(base >> 63);
    u64 plo = (u64)p << 1, phi = (u64)(p >> 63);   /* 2*p as a 128-bit pair */
    if (sub) {
        hi -= phi + (lo < plo);
        lo -= plo;
    } else {
        u64 t = lo + plo;
        hi += phi + (t < lo);
        lo = t;
    }
    return sat_s((s64)((hi << (64 - esize)) | (lo >> esize)), esize);
}

/* FEAT_FCMA FCMLA core, shared by the vector and by-element forms. Lanes are
 * complex pairs (even=real, odd=imag); per the pseudocode each output line is
 * one fused FPMulAdd and the rot negation applies to the *Vm* element (which
 * matters for NaN signs). rot 0/90/180/270 -> (e1,e2,e3,e4) so that
 * d.r += e2*e1 and d.i += e4*e3; rot0+rot90 accumulate a full complex multiply.
 * midx: broadcast Vm pair index for the by-element form, -1 = per-pair Vm.
 * Halves widen through f16->double, one fused step, one narrow (53 >= 2*11+2,
 * so the double rounding is exact — the established FP16 pattern). */
#define FCMLA_ROT(rot, nr, ni, mr, mi) \
    switch (rot) { \
        case 0:  e1 = (mr);  e2 = (nr); e3 = (mi);  e4 = (nr); break; \
        case 1:  e1 = -(mi); e2 = (ni); e3 = (mr);  e4 = (ni); break; \
        case 2:  e1 = -(mr); e2 = (nr); e3 = -(mi); e4 = (nr); break; \
        default: e1 = (mi);  e2 = (ni); e3 = -(mr); e4 = (ni); break; \
    }
static void fcmla_core(CPU *c, unsigned size, unsigned Q, unsigned Rn,
                       unsigned Rm, unsigned Rd, unsigned rot, int midx) {
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;
    unsigned pairs = ((Q ? 16u : 8u) >> size) >> 1;
    for (unsigned p = 0; p < pairs; p++) {
        unsigned mp = (midx >= 0) ? (unsigned)midx : p;
        if (size == 2) {
            float nr = vget_s(&vn, 2*p), ni = vget_s(&vn, 2*p + 1);
            float mr = vget_s(&vm, 2*mp), mi = vget_s(&vm, 2*mp + 1);
            float e1, e2, e3, e4;
            FCMLA_ROT(rot, nr, ni, mr, mi)
            vset_s(&r, 2*p,     fop_s(FOP_MLA, e2, e1, vget_s(&vd, 2*p)));
            vset_s(&r, 2*p + 1, fop_s(FOP_MLA, e4, e3, vget_s(&vd, 2*p + 1)));
        } else if (size == 3) {
            double nr = vget_d(&vn, 0), ni = vget_d(&vn, 1);
            double mr = vget_d(&vm, 0), mi = vget_d(&vm, 1);
            double e1, e2, e3, e4;
            FCMLA_ROT(rot, nr, ni, mr, mi)
            vset_d(&r, 0, fop_d(FOP_MLA, e2, e1, vget_d(&vd, 0)));
            vset_d(&r, 1, fop_d(FOP_MLA, e4, e3, vget_d(&vd, 1)));
        } else {                                     /* size == 1: half */
            double nr = f16_to_f64(vn.h[2*p]), ni = f16_to_f64(vn.h[2*p + 1]);
            double mr = f16_to_f64(vm.h[2*mp]), mi = f16_to_f64(vm.h[2*mp + 1]);
            double e1, e2, e3, e4;
            FCMLA_ROT(rot, nr, ni, mr, mi)
            r.h[2*p]     = f64_to_f16(fop_d(FOP_MLA, e2, e1, f16_to_f64(vd.h[2*p])));
            r.h[2*p + 1] = f64_to_f16(fop_d(FOP_MLA, e4, e3, f16_to_f64(vd.h[2*p + 1])));
        }
    }
    c->v[Rd] = r;
}

/* FEAT_FCMA FCADD: complex add with the Vm pair swapped and one side negated.
 * rot=0 (#90): d.r = n.r - m.i, d.i = n.i + m.r; rot=1 (#270) flips the signs. */
static void fcadd_core(CPU *c, unsigned size, unsigned Q, unsigned Rn,
                       unsigned Rm, unsigned Rd, unsigned rot) {
    V128 vn = c->v[Rn], vm = c->v[Rm], r; r.d[0] = r.d[1] = 0;
    unsigned pairs = ((Q ? 16u : 8u) >> size) >> 1;
    for (unsigned p = 0; p < pairs; p++) {
        if (size == 2) {
            float ar = vget_s(&vm, 2*p + 1), ai = vget_s(&vm, 2*p);
            if (rot == 0) ar = -ar; else ai = -ai;
            vset_s(&r, 2*p,     fop_s(FOP_ADD, vget_s(&vn, 2*p), ar, 0));
            vset_s(&r, 2*p + 1, fop_s(FOP_ADD, vget_s(&vn, 2*p + 1), ai, 0));
        } else if (size == 3) {
            double ar = vget_d(&vm, 1), ai = vget_d(&vm, 0);
            if (rot == 0) ar = -ar; else ai = -ai;
            vset_d(&r, 0, fop_d(FOP_ADD, vget_d(&vn, 0), ar, 0));
            vset_d(&r, 1, fop_d(FOP_ADD, vget_d(&vn, 1), ai, 0));
        } else {                                     /* size == 1: half */
            double ar = f16_to_f64(vm.h[2*p + 1]), ai = f16_to_f64(vm.h[2*p]);
            if (rot == 0) ar = -ar; else ai = -ai;
            r.h[2*p]     = f64_to_f16(f16_to_f64(vn.h[2*p]) + ar);
            r.h[2*p + 1] = f64_to_f16(f16_to_f64(vn.h[2*p + 1]) + ai);
        }
    }
    c->v[Rd] = r;
}

/* SUQADD: signed accumulator `d` + UNSIGNED addend `a`, clamped to the signed
 * range. For esize==64 the addend must stay unsigned (casting it to s64 would
 * misread a large value as negative); since a>=0, only the upper bound can be
 * exceeded. */
static u64 suqadd_sat(u64 d, u64 a, unsigned e) {
    u64 emask = (e >= 64) ? ~0ULL : (((u64)1 << e) - 1);
    s64 sd = sx(d, e);
    u64 ua = a & emask;
    if (e < 64) return sat_s(sd + (s64)ua, e);
    u64 lim = (sd >= 0) ? ((u64)INT64_MAX - (u64)sd)      /* headroom above sd */
                        : ((u64)INT64_MAX + (-(u64)sd));  /* INT64_MAX + |sd|  */
    if (ua > lim) { g_fpexc |= FPSR_QC; return (u64)INT64_MAX; }
    return (u64)sd + ua;   /* true sum fits s64; the wrapping sum is its 2's-comp */
}

/* AdvSIMD register variable shift kernel (S/USHL, S/URSHL, S/UQSHL, S/UQRSHL).
 * sh>=0 left, sh<0 right; round adds the rounding bias; sat clamps left-shift
 * overflow. Pure 64-bit arithmetic (portable to 32-bit hosts): saturation is
 * decided by pre-shift range checks, rounding by the shift-and-carry identity
 * (x + 2^(r-1)) >> r  ==  (x >> r) + ((x >> (r-1)) & 1). */
static u64 vreg_shift(u64 val, int sh, unsigned e, int sgn, int round, int sat) {
    u64 emask = (e >= 64) ? ~0ULL : (((u64)1 << e) - 1);
    if (sh >= 0) {                                  /* left shift */
        if (!sat) return (sh >= 64) ? 0 : ((val << sh) & emask);
        if (sgn) {
            s64 sv = sx(val, e);
            s64 max = (e >= 64) ? INT64_MAX : (((s64)1 << (e - 1)) - 1);
            s64 min = (e >= 64) ? INT64_MIN : (-((s64)1 << (e - 1)));
            if (sv == 0) return 0;
            /* A shift by at least the element width overflows for every
             * nonzero value, and the `min >> sh` bound below cannot say so:
             * min is held as a 64-bit value, so for e < 64 it only decays to
             * -1 no matter how large sh gets, and sv == -1 slipped past the
             * test. SQSHL/SQRSHL of -1 by 42 in a .4s lane then returned 0
             * (the shifted bits masked away) instead of saturating to
             * INT32_MIN. Only reachable from the register forms, where the
             * amount comes from a vector lane and is not bounded by e. */
            if (sh >= (int)e || sh >= 64) {
                g_fpexc |= FPSR_QC;
                return (u64)(sv > 0 ? max : min) & emask;
            }
            if (sv > 0) {
                if (sv > (max >> sh)) { g_fpexc |= FPSR_QC; return (u64)max; }
                return ((u64)sv << sh) & emask;
            }
            if (sv < (min >> sh)) { g_fpexc |= FPSR_QC; return (u64)min & emask; }
            return ((u64)sv << sh) & emask;
        } else {
            u64 uv = val & emask;
            u64 max = emask;
            if (uv == 0) return 0;
            if (sh >= 64) { g_fpexc |= FPSR_QC; return max; }
            if (uv > (max >> sh)) { g_fpexc |= FPSR_QC; return max; }
            return (uv << sh) & emask;
        }
    }
    unsigned rs = (unsigned)-sh;                    /* right shift */
    if (sgn) {
        s64 sv = sx(val, e);
        if (rs >= 64) {
            /* rounded: sv + 2^(rs-1) is in [0, 2^rs) for every rs >= 64 -> 0 */
            return round ? 0 : ((u64)(sv < 0 ? -1 : 0) & emask);
        }
        s64 w = sv >> rs;
        if (round && rs >= 1) w += (sv >> (rs - 1)) & 1;
        return (u64)w & emask;
    }
    u64 uv = val & emask;
    if (rs >= 64) {
        if (!round) return 0;
        return (rs == 64) ? ((uv >> 63) & 1) & emask : 0;
    }
    u64 w = uv >> rs;
    if (round && rs >= 1) w += (uv >> (rs - 1)) & 1;
    return w & emask;
}
static u16 pmull8(u8 a, u8 b);                      /* defined in the crypto section */

/* ===================== Floating-point vector helpers =====================
 * Computed in host float/double. NaN-payload propagation, denormal flushing and
 * non-default rounding modes are NOT bit-exact to ARM (same caveat as the scalar
 * FP path); normal values match. FMAX/FMIN propagate NaN (unlike host fmax);
 * FMAXNM/FMINNM return the numeric operand. The FOP_* selectors are declared
 * above (before exec_fp_scalar, their first user). */

static double fop_d_raw(unsigned op, double n, double m, double d) {
    switch (op) {
        case FOP_ADD: return n + m;
        case FOP_SUB: return n - m;
        case FOP_MUL: return n * m;
        case FOP_DIV: return n / m;
        case FOP_MLA: return a64_fma( n, m, d);         /* fused (single rounding) */
        case FOP_MLS: return a64_fma(-n, m, d);
        case FOP_ABD: return __builtin_fabs(n - m);
        case FOP_RECPS:                       /* FPRecipStepFused: fused, and */
            if ((n == 0.0 && __builtin_isinf(m)) ||   /* 0*inf -> 2.0, no IOC */
                (__builtin_isinf(n) && m == 0.0)) return 2.0;
            return a64_fma(-n, m, 2.0);
        case FOP_RSQRTS: {                    /* FPRSqrtStepFused: 0*inf -> 1.5 */
            if ((n == 0.0 && __builtin_isinf(m)) ||
                (__builtin_isinf(n) && m == 0.0)) return 1.5;
            /* (3 - n*m) / 2 with a SINGLE rounding (the pseudocode's halved
             * fused subtract): fold the halving into an operand — fma(-n/2,
             * m, 1.5) — so it stays one rounding. fma-then-divide rounds
             * twice, which shows at the overflow boundary (the fma saturates
             * to inf where the halved value is still representable; found by
             * the a64 JIT's native replay on real silicon, where frsqrts is
             * the reference) and in the subnormal range. Halving is exact
             * only above the bottom exponent, so pick the operand it cannot
             * clip (checked in the integer domain — an FP probe would raise
             * flags the guest never asked for); when both sit at the very
             * bottom the product is far below 3's significance and the old
             * shape is exact, with the right IXC. */
            u64 nb; memcpy(&nb, &n, 8);
            if (((nb >> 52) & 0x7ff) >= 2)
                return a64_fma(-(0.5 * n), m, 1.5);
            memcpy(&nb, &m, 8);
            if (((nb >> 52) & 0x7ff) >= 2)
                return a64_fma(-n, 0.5 * m, 1.5);
            return a64_fma(-n, m, 3.0) / 2.0;
        }
        case FOP_MULX:
            if ((__builtin_isinf(n) && m == 0.0) || (__builtin_isinf(m) && n == 0.0))
                return (__builtin_signbit(n) ^ __builtin_signbit(m)) ? -2.0 : 2.0;
            return n * m;
        case FOP_MAX:
            /* NaN: fop_d's FPProcessNaNs wrapper decides *which* NaN comes
             * back and quiets it, so this only has to return one. It must not
             * compute it as `n + m`: that add is an FP op inside a branch, and
             * a compiler free to assume nothing observes the exception flags
             * (clang's default) hoists it out and runs it for every FMAX —
             * 0.5 + a denormal then leaves the host's IXC set for a guest
             * instruction that raises nothing. sNaN's IOC, which the add used
             * to supply, is raised here instead. */
            if (__builtin_isnan(n) || __builtin_isnan(m)) {
                if (is_snan_d(n) || is_snan_d(m)) g_fpexc |= FPSR_IOC;
                return __builtin_isnan(n) ? n : m;
            }
            if (n == m) return __builtin_signbit(n) ? m : n;   /* +0 > -0 */
            return n > m ? n : m;
        case FOP_MIN:
            if (__builtin_isnan(n) || __builtin_isnan(m)) {
                if (is_snan_d(n) || is_snan_d(m)) g_fpexc |= FPSR_IOC;
                return __builtin_isnan(n) ? n : m;
            }
            if (n == m) return __builtin_signbit(n) ? n : m;
            return n < m ? n : m;
        case FOP_MAXNM:
            if (is_snan_d(n) || is_snan_d(m)) g_fpexc |= FPSR_IOC;
            if (__builtin_isnan(n)) return m;
            if (__builtin_isnan(m)) return n;
            return fop_d_raw(FOP_MAX, n, m, d);
        case FOP_MINNM:
            if (is_snan_d(n) || is_snan_d(m)) g_fpexc |= FPSR_IOC;
            if (__builtin_isnan(n)) return m;
            if (__builtin_isnan(m)) return n;
            return fop_d_raw(FOP_MIN, n, m, d);
    }
    return 0.0;
}
static float fop_s_raw(unsigned op, float n, float m, float d) {
    switch (op) {
        case FOP_ADD: return n + m;
        case FOP_SUB: return n - m;
        case FOP_MUL: return n * m;
        case FOP_DIV: return n / m;
        case FOP_MLA: return a64_fmaf( n, m, d);        /* fused (single rounding) */
        case FOP_MLS: return a64_fmaf(-n, m, d);
        case FOP_ABD: return __builtin_fabsf(n - m);
        case FOP_RECPS:
            if ((n == 0.0f && __builtin_isinf(m)) ||      /* 0*inf -> 2.0, no IOC */
                (__builtin_isinf(n) && m == 0.0f)) return 2.0f;
            return a64_fmaf(-n, m, 2.0f);
        case FOP_RSQRTS: {
            if ((n == 0.0f && __builtin_isinf(m)) ||      /* 0*inf -> 1.5 */
                (__builtin_isinf(n) && m == 0.0f)) return 1.5f;
            /* single-rounded (3 - n*m)/2 — see fop_d_raw */
            u32 nb; memcpy(&nb, &n, 4);
            if (((nb >> 23) & 0xff) >= 2)
                return a64_fmaf(-(0.5f * n), m, 1.5f);
            memcpy(&nb, &m, 4);
            if (((nb >> 23) & 0xff) >= 2)
                return a64_fmaf(-n, 0.5f * m, 1.5f);
            return a64_fmaf(-n, m, 3.0f) / 2.0f;
        }
        case FOP_MULX:
            if ((__builtin_isinf(n) && m == 0.0f) || (__builtin_isinf(m) && n == 0.0f))
                return (__builtin_signbit(n) ^ __builtin_signbit(m)) ? -2.0f : 2.0f;
            return n * m;
        case FOP_MAX:                                  /* see fop_d_raw */
            if (__builtin_isnan(n) || __builtin_isnan(m)) {
                if (is_snan_s(n) || is_snan_s(m)) g_fpexc |= FPSR_IOC;
                return __builtin_isnan(n) ? n : m;
            }
            if (n == m) return __builtin_signbit(n) ? m : n;
            return n > m ? n : m;
        case FOP_MIN:
            if (__builtin_isnan(n) || __builtin_isnan(m)) {
                if (is_snan_s(n) || is_snan_s(m)) g_fpexc |= FPSR_IOC;
                return __builtin_isnan(n) ? n : m;
            }
            if (n == m) return __builtin_signbit(n) ? n : m;
            return n < m ? n : m;
        case FOP_MAXNM:
            if (is_snan_s(n) || is_snan_s(m)) g_fpexc |= FPSR_IOC;
            if (__builtin_isnan(n)) return m;
            if (__builtin_isnan(m)) return n;
            return fop_s_raw(FOP_MAX, n, m, d);
        case FOP_MINNM:
            if (is_snan_s(n) || is_snan_s(m)) g_fpexc |= FPSR_IOC;
            if (__builtin_isnan(n)) return m;
            if (__builtin_isnan(m)) return n;
            return fop_s_raw(FOP_MIN, n, m, d);
    }
    return 0.0f;
}

/* One chokepoint for NaN results (see fpnan_d): every vector and
 * scalar caller of the shared FP helpers goes through here. Only MLA/MLS read
 * the addend, so only they may let a NaN there mark the result propagated --
 * every other opcode ignores `d`, and callers routinely pass a dummy 0. */
static double fop_d(unsigned op, double n, double m, double d) {
    double r = fop_d_raw(op, n, m, d);
    switch (op) {
        case FOP_MLA: return fpnan_muladd_d(r, d,  n, m);   /* FPMulAdd(d,  n, m) */
        case FOP_MLS: return fpnan_muladd_d(r, d, -n, m);   /* FPMulAdd(d, -n, m) */
        case FOP_ABD: return __builtin_fabs(fpnan_d(r, n, m));  /* FPAbs last */
        case FOP_RECPS:                     /* FPRecipStepFused / FPRSqrtStep- */
        case FOP_RSQRTS:                    /* Fused apply FPNeg(op1) BEFORE   */
            return fpnan_d(r, -n, m);       /* the NaN processing, so a        */
        default:      return fpnan_d(r, n, m);  /* propagated n comes back negated */
    }
}
static float fop_s(unsigned op, float n, float m, float d) {
    float r = fop_s_raw(op, n, m, d);
    switch (op) {
        case FOP_MLA: return fpnan_muladd_s(r, d,  n, m);
        case FOP_MLS: return fpnan_muladd_s(r, d, -n, m);
        case FOP_ABD: return __builtin_fabsf(fpnan_s(r, n, m));
        case FOP_RECPS:
        case FOP_RSQRTS:
            return fpnan_s(r, -n, m);
        default:      return fpnan_s(r, n, m);
    }
}

/* AdvSIMD three-same floating-point: opcodes 0x18..0x1f (FADD/FSUB/FMUL/FDIV/
 * FMLA/FMLS/FMAX/FMIN/FMAXNM/FMINNM/FMULX/FRECPS/FRSQRTS/FABD, the compares
 * FCMEQ/FCMGE/FCMGT/FACGE/FACGT, and the pairwise FADDP/FMAXP/FMINP/FMAXNMP/
 * FMINNMP). bit23=a selects the variant page, bit22=sz precision. */
static void simd_three_same_fp(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), a = BIT(23), sz = BIT(22), opc = BITS(15, 11);
    unsigned Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned key = (U << 6) | (a << 5) | opc;
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;

    /* FEAT_FHM FMLAL/FMLSL (keys 0x1d/0x3d) and FMLAL2/FMLSL2 (0x59/0x79):
     * f16 -> f32 widening fused MLA into .2s/.4s lanes; sz must be 0. Decoded
     * ahead of the compare/FADD paths these keys previously fell into. The
     * "2" forms read source halves [n..2n-1] — h[2..3] when Q=0, not h[4..5];
     * FMLSL* negate the Vn f16 sign bit before widening (FPNeg16). */
    if (key == 0x1d || key == 0x3d || key == 0x59 || key == 0x79) {
        if (sz) { fpsimd_undef(c, insn); return; }
        unsigned n = Q ? 4 : 2, sel = (key & 0x40) ? n : 0;
        unsigned neg = (key & 0x20) ? 0x8000u : 0;
        for (unsigned i = 0; i < n; i++)
            vset_s(&r, i, fop_s(FOP_MLA, f16_to_f32(vn.h[sel + i] ^ neg),
                                f16_to_f32(vm.h[sel + i]), vget_s(&vd, i)));
        c->v[Rd] = r; return;
    }

    int pair = (U == 1) && (opc == 0x18 || opc == 0x1e || (opc == 0x1a && a == 0));
    int cmp  = (opc == 0x1c) || (opc == 0x1d);   /* FCMEQ/GE/GT, FACGE/GT */
    unsigned op;
    switch (key) {                                 /* full (U:a:opc) key */
        case 0x18: op = FOP_MAXNM;  break;         /* FMAXNM */
        case 0x38: op = FOP_MINNM;  break;         /* FMINNM */
        case 0x19: op = FOP_MLA;    break;         /* FMLA   */
        case 0x39: op = FOP_MLS;    break;         /* FMLS   */
        case 0x1a: op = FOP_ADD;    break;         /* FADD   */
        case 0x3a: op = FOP_SUB;    break;         /* FSUB   */
        case 0x1b: op = FOP_MULX;   break;         /* FMULX  */
        case 0x1e: op = FOP_MAX;    break;         /* FMAX   */
        case 0x3e: op = FOP_MIN;    break;         /* FMIN   */
        case 0x1f: op = FOP_RECPS;  break;         /* FRECPS */
        case 0x3f: op = FOP_RSQRTS; break;         /* FRSQRTS*/
        case 0x5b: op = FOP_MUL;    break;         /* FMUL   */
        case 0x5f: op = FOP_DIV;    break;         /* FDIV   */
        case 0x7a: op = FOP_ABD;    break;         /* FABD   */
        case 0x58: op = FOP_MAXNM;  break;         /* FMAXNMP */
        case 0x5a: op = FOP_ADD;    break;         /* FADDP   */
        case 0x5e: op = FOP_MAX;    break;         /* FMAXP   */
        case 0x78: op = FOP_MINNM;  break;         /* FMINNMP */
        case 0x7e: op = FOP_MIN;    break;         /* FMINP   */
        default:   op = FOP_ADD;    break;         /* compares: handled via `cmp` */
    }

    if (sz) {                                       /* double: .2d (Q=1) */
        unsigned n = Q ? 2 : 1;
        if (pair) {
            for (unsigned i = 0; i < n; i++) {
                const V128 *src = (i < n/2) ? &vn : &vm;
                unsigned base = (i < n/2) ? 2*i : 2*(i - n/2);
                vset_d(&r, i, fop_d(op, vget_d(src, base), vget_d(src, base+1), 0));
            }
            c->v[Rd] = r; return;
        }
        for (unsigned i = 0; i < n; i++) {
            double x = vget_d(&vn, i), y = vget_d(&vm, i);
            if (cmp) {
                int t = (opc == 0x1c)
                      ? fcm_test_d(key == 0x1c ? FCM_EQ : key == 0x5c ? FCM_GE : FCM_GT, x, y)
                      : fcm_test_d(key == 0x5d ? FCM_GE : FCM_GT,
                                   __builtin_fabs(x), __builtin_fabs(y));
                r.d[i] = t ? ~0ULL : 0; continue;
            }
            vset_d(&r, i, fop_d(op, x, y, vget_d(&vd, i)));
        }
        c->v[Rd] = r; return;
    }

    /* single: .2s (Q=0, lanes 0..1) or .4s (Q=1, lanes 0..3) */
    unsigned n = Q ? 4 : 2;
    if (pair) {
        for (unsigned i = 0; i < n; i++) {
            const V128 *src = (i < n/2) ? &vn : &vm;
            unsigned base = (i < n/2) ? 2*i : 2*(i - n/2);
            vset_s(&r, i, fop_s(op, vget_s(src, base), vget_s(src, base+1), 0));
        }
        c->v[Rd] = r; return;
    }
    for (unsigned i = 0; i < n; i++) {
        float x = vget_s(&vn, i), y = vget_s(&vm, i);
        if (cmp) {
            int t = (opc == 0x1c)
                  ? fcm_test_s(key == 0x1c ? FCM_EQ : key == 0x5c ? FCM_GE : FCM_GT, x, y)
                  : fcm_test_s(key == 0x5d ? FCM_GE : FCM_GT,
                               __builtin_fabsf(x), __builtin_fabsf(y));
            r.s[i] = t ? 0xffffffffu : 0; continue;
        }
        vset_s(&r, i, fop_s(op, x, y, vget_s(&vd, i)));
    }
    c->v[Rd] = r;
}

/* AdvSIMD three-same (FP16): the half-precision page of the FP three-same group.
 * Separate encoding from the single/double form (bit22=1, bit21=0, 3-bit opcode
 * in bits[13:11]). Widen each half lane to double, compute with the shared fop_d
 * kernels, narrow once via f64_to_f16 (exact: 53 >= 2*11+2). Compares write an
 * all-ones/zero half mask. Mirrors simd_three_same_fp lane-for-lane. */
static void simd_three_same_fp16(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), a = BIT(23), op3 = BITS(13, 11);
    unsigned Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned key = (U << 4) | (a << 3) | op3;
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;
    unsigned n = Q ? 8 : 4, op = FOP_ADD; int pair = 0, cmp = 0;
    switch (key) {
        case 0x00: op = FOP_MAXNM;  break;             /* FMAXNM  */
        case 0x08: op = FOP_MINNM;  break;             /* FMINNM  */
        case 0x01: op = FOP_MLA;    break;             /* FMLA    */
        case 0x09: op = FOP_MLS;    break;             /* FMLS    */
        case 0x02: op = FOP_ADD;    break;             /* FADD    */
        case 0x0a: op = FOP_SUB;    break;             /* FSUB    */
        case 0x03: op = FOP_MULX;   break;             /* FMULX   */
        case 0x06: op = FOP_MAX;    break;             /* FMAX    */
        case 0x0e: op = FOP_MIN;    break;             /* FMIN    */
        case 0x07: op = FOP_RECPS;  break;             /* FRECPS  */
        case 0x0f: op = FOP_RSQRTS; break;             /* FRSQRTS */
        case 0x13: op = FOP_MUL;    break;             /* FMUL    */
        case 0x17: op = FOP_DIV;    break;             /* FDIV    */
        case 0x1a: op = FOP_ABD;    break;             /* FABD    */
        case 0x10: op = FOP_MAXNM; pair = 1; break;    /* FMAXNMP */
        case 0x12: op = FOP_ADD;   pair = 1; break;    /* FADDP   */
        case 0x16: op = FOP_MAX;   pair = 1; break;    /* FMAXP   */
        case 0x18: op = FOP_MINNM; pair = 1; break;    /* FMINNMP */
        case 0x1e: op = FOP_MIN;   pair = 1; break;    /* FMINP   */
        case 0x04: case 0x14: case 0x1c:               /* FCMEQ / FCMGE / FCMGT */
        case 0x15: case 0x1d: cmp = 1; break;          /* FACGE / FACGT */
        default: fpsimd_undef(c, insn); return;
    }
    if (pair) {
        for (unsigned i = 0; i < n; i++) {
            const V128 *src = (i < n/2) ? &vn : &vm;
            unsigned base = (i < n/2) ? 2*i : 2*(i - n/2);
            double x = f16_to_f64(src->h[base]), y = f16_to_f64(src->h[base + 1]);
            r.h[i] = f64_to_f16(fop_d(op, x, y, 0));
        }
        c->v[Rd] = r; return;
    }
    for (unsigned i = 0; i < n; i++) {
        double x = f16_to_f64(vn.h[i]), y = f16_to_f64(vm.h[i]);
        if (cmp) {
            int t = (key == 0x04) ? fcm_test_d(FCM_EQ, x, y)                   /* FCMEQ */
                  : (key == 0x14) ? fcm_test_d(FCM_GE, x, y)                   /* FCMGE */
                  : (key == 0x1c) ? fcm_test_d(FCM_GT, x, y)                   /* FCMGT */
                  : (key == 0x15) ? fcm_test_d(FCM_GE, __builtin_fabs(x),      /* FACGE */
                                                       __builtin_fabs(y))
                                  : fcm_test_d(FCM_GT, __builtin_fabs(x),      /* FACGT */
                                                       __builtin_fabs(y));
            r.h[i] = t ? 0xffffu : 0; continue;
        }
        r.h[i] = f64_to_f16(fop_d(op, x, y, f16_to_f64(vd.h[i])));
    }
    c->v[Rd] = r;
}

/* AdvSIMD three-same (vector integer): element-wise ADD/SUB/compare/min/max/mul
 * and the bitwise logical group. The workhorse vector group for string/memory
 * routines (CMEQ/CMHS...) in EDK2 and Linux. */
static void simd_three_same(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22);
    unsigned Rm = BITS(20, 16), opc = BITS(15, 11), Rn = BITS(9, 5), Rd = BITS(4, 0);

    if (opc >= 0x18) { simd_three_same_fp(c, insn); return; }   /* FP three-same */

    if (opc == 0x03) {                         /* logical (size selects op) */
        u64 a0 = c->v[Rn].d[0], a1 = c->v[Rn].d[1];
        u64 b0 = c->v[Rm].d[0], b1 = c->v[Rm].d[1];
        u64 d0 = c->v[Rd].d[0], d1 = c->v[Rd].d[1], r0, r1;
        if (!U) switch (size) {
            case 0: r0 = a0 & b0;  r1 = a1 & b1;  break;          /* AND */
            case 1: r0 = a0 & ~b0; r1 = a1 & ~b1; break;          /* BIC */
            case 2: r0 = a0 | b0;  r1 = a1 | b1;  break;          /* ORR */
            default: r0 = a0 | ~b0; r1 = a1 | ~b1; break;         /* ORN */
        } else switch (size) {
            case 0: r0 = a0 ^ b0; r1 = a1 ^ b1; break;            /* EOR */
            case 1: r0 = b0 ^ ((b0 ^ a0) & d0); r1 = b1 ^ ((b1 ^ a1) & d1); break; /* BSL */
            case 2: r0 = d0 ^ ((d0 ^ a0) & b0); r1 = d1 ^ ((d1 ^ a1) & b1); break; /* BIT */
            default: r0 = d0 ^ ((d0 ^ a0) & ~b0); r1 = d1 ^ ((d1 ^ a1) & ~b1); break; /* BIF */
        }
        c->v[Rd].d[0] = r0; c->v[Rd].d[1] = Q ? r1 : 0;
        return;
    }

    unsigned esize = 8u << size, n = (Q ? 16 : 8) >> size;
    V128 r; r.d[0] = r.d[1] = 0;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);

    /* PMUL (U=1, opc=0x13) is defined only for .8b/.16b (size==0). */
    if (U == 1 && opc == 0x13 && size != 0) { fpsimd_undef(c, insn); return; }

    /* Pairwise: ADDP (0x17, U=0), S/UMAXP (0x14), S/UMINP (0x15). Output lower
     * half folds pairs of Rn, upper half folds pairs of Rm. */
    if ((opc == 0x17 && U == 0) || opc == 0x14 || opc == 0x15) {
        for (unsigned i = 0; i < n / 2; i++) {
            u64 n0 = velem_get(&c->v[Rn], size, 2*i), n1 = velem_get(&c->v[Rn], size, 2*i + 1);
            u64 m0 = velem_get(&c->v[Rm], size, 2*i), m1 = velem_get(&c->v[Rm], size, 2*i + 1);
            u64 lo, hi;
            if (opc == 0x17)        { lo = n0 + n1; hi = m0 + m1; }                 /* ADDP */
            else if (opc == 0x14) {                                                /* MAXP */
                lo = (U ? n0 > n1 : sx(n0,esize) > sx(n1,esize)) ? n0 : n1;
                hi = (U ? m0 > m1 : sx(m0,esize) > sx(m1,esize)) ? m0 : m1;
            } else {                                                               /* MINP */
                lo = (U ? n0 < n1 : sx(n0,esize) < sx(n1,esize)) ? n0 : n1;
                hi = (U ? m0 < m1 : sx(m0,esize) < sx(m1,esize)) ? m0 : m1;
            }
            velem_set(&r, size, i, lo & emask);
            velem_set(&r, size, n / 2 + i, hi & emask);
        }
        c->v[Rd] = r;
        return;
    }

    for (unsigned i = 0; i < n; i++) {
        u64 a = velem_get(&c->v[Rn], size, i), b = velem_get(&c->v[Rm], size, i), v;
        switch ((U << 5) | opc) {
            case (0 << 5) | 0x10: v = a + b; break;                       /* ADD */
            case (1 << 5) | 0x10: v = a - b; break;                       /* SUB */
            case (0 << 5) | 0x11: v = (a & b) ? emask : 0; break;         /* CMTST */
            case (1 << 5) | 0x11: v = (a == b) ? emask : 0; break;        /* CMEQ */
            case (0 << 5) | 0x06: v = (sx(a,esize) >  sx(b,esize)) ? emask : 0; break; /* CMGT */
            case (1 << 5) | 0x06: v = (a >  b) ? emask : 0; break;        /* CMHI */
            case (0 << 5) | 0x07: v = (sx(a,esize) >= sx(b,esize)) ? emask : 0; break; /* CMGE */
            case (1 << 5) | 0x07: v = (a >= b) ? emask : 0; break;        /* CMHS */
            case (0 << 5) | 0x0c: v = (sx(a,esize) >  sx(b,esize)) ? a : b; break;     /* SMAX */
            case (1 << 5) | 0x0c: v = (a > b) ? a : b; break;            /* UMAX */
            case (0 << 5) | 0x0d: v = (sx(a,esize) <  sx(b,esize)) ? a : b; break;     /* SMIN */
            case (1 << 5) | 0x0d: v = (a < b) ? a : b; break;            /* UMIN */
            case (0 << 5) | 0x13: v = a * b; break;                       /* MUL */
            case (1 << 5) | 0x13: v = pmull8((u8)a, (u8)b) & 0xff; break; /* PMUL (.8b/.16b) */
            case (0 << 5) | 0x12: v = velem_get(&c->v[Rd], size, i) + a * b; break;    /* MLA */
            case (1 << 5) | 0x12: v = velem_get(&c->v[Rd], size, i) - a * b; break;    /* MLS */
            /* halving / rounding-halving add & sub (esize<=32) */
            case (0 << 5) | 0x00: v = (u64)(wadd(sx(a,esize), sx(b,esize)) >> 1); break;      /* SHADD */
            case (1 << 5) | 0x00: v = (a + b) >> 1; break;                                      /* UHADD */
            case (0 << 5) | 0x02: v = (u64)(wadd(wadd(sx(a,esize), sx(b,esize)), 1) >> 1); break; /* SRHADD */
            case (1 << 5) | 0x02: v = (a + b + 1) >> 1; break;                                  /* URHADD */
            case (0 << 5) | 0x04: v = (u64)(wsub(sx(a,esize), sx(b,esize)) >> 1); break;        /* SHSUB */
            case (1 << 5) | 0x04: v = (u64)(wsub((s64)(a & emask), (s64)(b & emask)) >> 1); break; /* UHSUB */
            /* saturating add/sub */
            case (0 << 5) | 0x01: v = ssat_add(sx(a,esize), sx(b,esize), esize); break;  /* SQADD */
            case (1 << 5) | 0x01: v = usat_add(a & emask, b & emask, esize); break;      /* UQADD */
            case (0 << 5) | 0x05: v = ssat_sub(sx(a,esize), sx(b,esize), esize); break;  /* SQSUB */
            case (1 << 5) | 0x05: v = usat_sub(a & emask, b & emask, esize); break;      /* UQSUB */
            /* register variable shifts (shift = SInt(Vm element<7:0>)) */
            case (0 << 5) | 0x08: v = vreg_shift(a, (s8)(b & 0xff), esize, 1, 0, 0); break;  /* SSHL */
            case (1 << 5) | 0x08: v = vreg_shift(a, (s8)(b & 0xff), esize, 0, 0, 0); break;  /* USHL */
            case (0 << 5) | 0x0a: v = vreg_shift(a, (s8)(b & 0xff), esize, 1, 1, 0); break;  /* SRSHL */
            case (1 << 5) | 0x0a: v = vreg_shift(a, (s8)(b & 0xff), esize, 0, 1, 0); break;  /* URSHL */
            case (0 << 5) | 0x09: v = vreg_shift(a, (s8)(b & 0xff), esize, 1, 0, 1); break;  /* SQSHL */
            case (1 << 5) | 0x09: v = vreg_shift(a, (s8)(b & 0xff), esize, 0, 0, 1); break;  /* UQSHL */
            case (0 << 5) | 0x0b: v = vreg_shift(a, (s8)(b & 0xff), esize, 1, 1, 1); break;  /* SQRSHL */
            case (1 << 5) | 0x0b: v = vreg_shift(a, (s8)(b & 0xff), esize, 0, 1, 1); break;  /* UQRSHL */
            /* absolute difference (+ accumulate) */
            case (0 << 5) | 0x0e: { v = wabs(wsub(sx(a,esize), sx(b,esize))); } break;                    /* SABD */
            case (1 << 5) | 0x0e: { u64 ua=a&emask, ub=b&emask; v = ua > ub ? ua-ub : ub-ua; } break;      /* UABD */
            case (0 << 5) | 0x0f: { v = velem_get(&c->v[Rd],size,i) + wabs(wsub(sx(a,esize), sx(b,esize))); } break;              /* SABA */
            case (1 << 5) | 0x0f: { u64 ua=a&emask, ub=b&emask; v = velem_get(&c->v[Rd],size,i) + (ua>ub?ua-ub:ub-ua); } break;    /* UABA */
            /* saturating doubling multiply-high. Overflow-safe: form a*b (fits
             * s64 for esize<=32) and shift by esize-1, not 2*a*b (which overflows
             * s64 at the INT32_MIN*INT32_MIN corner and mis-saturates). */
            case (0 << 5) | 0x16: { s64 p = wmul(sx(a,esize), sx(b,esize)); v = sat_s(p >> (esize-1), esize); } break;                  /* SQDMULH */
            case (1 << 5) | 0x16: { s64 p = wadd(wmul(sx(a,esize), sx(b,esize)), (s64)1 << (esize-2)); v = sat_s(p >> (esize-1), esize); } break; /* SQRDMULH */
            default: fpsimd_undef(c, insn); return;
        }
        velem_set(&r, size, i, v & emask);
    }
    c->v[Rd] = r;
}

/* AdvSIMD vector x indexed element: integer multiply-by-element group --
 * MUL/MLA/MLS (same size) and S/U MULL/MLAL/MLSL (widening long; bit30=Q
 * selects the SMULL2-style high source half). The Vm element is broadcast; its
 * index is built from H:L:M with a size-dependent split (and .H restricts Vm to
 * V0-V15). Poly1305 (poly1305-armv8) leans on UMULL/UMLAL by element, so this
 * unblocks the ChaCha20-Poly1305 TLS suite. */
/* AdvSIMD vector x indexed element, floating-point: FMLA(0x1)/FMLS(0x5)/
 * FMUL(0x9,U=0)/FMULX(0x9,U=1). size=10 .4s/.2s (idx=H:L), size=11 .2d (idx=H). */
static void simd_indexed_fp(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22), opc = BITS(15, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0), H = BIT(11), L = BIT(21);
    unsigned Rm = (size == 0) ? BITS(19, 16) : BITS(20, 16);   /* half: Vm limited to v0-v15 */
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;
    unsigned op = (opc == 0x1) ? FOP_MLA : (opc == 0x5) ? FOP_MLS : (U ? FOP_MULX : FOP_MUL);
    if (size == 0) {                              /* .4h/.8h (idx = H:L:M) */
        unsigned idx = (H << 2) | (L << 1) | BIT(20);
        double e = f16_to_f64(vm.h[idx]);
        unsigned n = Q ? 8 : 4;
        for (unsigned i = 0; i < n; i++)
            r.h[i] = f64_to_f16(fop_d(op, f16_to_f64(vn.h[i]), e, f16_to_f64(vd.h[i])));
        c->v[Rd] = r; return;
    }
    if (size == 3) {                              /* .2d (idx = H, L must be 0) */
        double e = vget_d(&vm, H);
        unsigned n = Q ? 2 : 1;
        for (unsigned i = 0; i < n; i++) vset_d(&r, i, fop_d(op, vget_d(&vn, i), e, vget_d(&vd, i)));
        c->v[Rd] = r; return;
    }
    if (size == 2) {                              /* .4s/.2s (idx = H:L) */
        float e = vget_s(&vm, (H << 1) | L);
        unsigned n = Q ? 4 : 2;
        for (unsigned i = 0; i < n; i++) vset_s(&r, i, fop_s(op, vget_s(&vn, i), e, vget_s(&vd, i)));
        c->v[Rd] = r; return;
    }
    fpsimd_undef(c, insn);                        /* half-precision deferred */
}

static u64 sqdmull_sat(s64 sa, s64 sb, unsigned e);   /* defined below (three-different) */

static void simd_indexed(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22), opc = BITS(15, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned L = BIT(21), H = BIT(11), M = BIT(20), Rm, index;
    if (U && (opc & 0x9) == 0x1) {                   /* FCMLA by element (FEAT_FCMA), rot=bits[14:13] */
        unsigned rot = (opc >> 1) & 3, Rm5 = BITS(20, 16);
        /* Vm is read at datasize width, so the pair index stays inside it:
         * .4h pairs 0-1, .8h pairs 0-3, .4s (Q required) pairs 0-1. */
        if (size == 1)      { index = (H << 1) | L; if (!Q && index > 1) { fpsimd_undef(c, insn); return; } }
        else if (size == 2 && Q) index = H;
        else { fpsimd_undef(c, insn); return; }
        fcmla_core(c, size, Q, Rn, Rm5, Rd, rot, (int)index); return;
    }
    if (opc == 0x9 || (!U && (opc == 0x1 || opc == 0x5))) { simd_indexed_fp(c, insn); return; }  /* FP by-element */
    /* FEAT_FHM FMLAL/FMLSL by element (f16 -> f32 widening MLA): size must be
     * 10, Rm is 4-bit and the index is H:L:M (0-7). Same half-selection and
     * FPNeg16 rules as the three-same forms above. */
    if (size == 2 && ((!U && (opc == 0x0 || opc == 0x4)) || (U && (opc == 0x8 || opc == 0xc)))) {
        unsigned Rm4 = BITS(19, 16), idx = (H << 2) | (L << 1) | M;
        V128 vn2 = c->v[Rn], vm2 = c->v[Rm4], vd2 = c->v[Rd], r2; r2.d[0] = r2.d[1] = 0;
        unsigned n = Q ? 4 : 2, sel = U ? n : 0;
        unsigned neg = (opc & 0x4) ? 0x8000u : 0;
        float e = f16_to_f32(vm2.h[idx]);
        for (unsigned i = 0; i < n; i++)
            vset_s(&r2, i, fop_s(FOP_MLA, f16_to_f32(vn2.h[sel + i] ^ neg), e, vget_s(&vd2, i)));
        c->v[Rd] = r2; return;
    }
    if (size == 1)      { Rm = BITS(19, 16); index = (H << 2) | (L << 1) | M; }  /* .H src */
    else if (size == 2) { Rm = BITS(20, 16); index = (H << 1) | L; }             /* .S src */
    else { fpsimd_undef(c, insn); return; }   /* .B/.D have no integer by-element */

    unsigned esize = 8u << size;
    u64 emask = (1ULL << esize) - 1;
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;
    u64 elt = velem_get(&vm, size, index) & emask;
    s64 selt = sx(elt, esize);

    if ((opc == 0x8 && !U) || (opc == 0x0 && U) || (opc == 0x4 && U)) {  /* MUL/MLA/MLS */
        unsigned n = (Q ? 16u : 8u) >> size;
        for (unsigned i = 0; i < n; i++) {
            u64 a = velem_get(&vn, size, i) & emask, prod = a * elt;
            u64 v = (opc == 0x8) ? prod
                  : (opc == 0x0) ? velem_get(&vd, size, i) + prod
                                 : velem_get(&vd, size, i) - prod;
            velem_set(&r, size, i, v & emask);
        }
    } else if (opc == 0xa || opc == 0x2 || opc == 0x6) {                 /* S/U MULL/MLAL/MLSL */
        unsigned ndest = 64u / esize, base = Q ? ndest : 0, dsize = size + 1;
        u64 dmask = (2 * esize >= 64) ? ~0ULL : ((1ULL << (2 * esize)) - 1);
        for (unsigned i = 0; i < ndest; i++) {
            u64 a = velem_get(&vn, size, base + i) & emask;
            u64 prod = U ? (elt * a) : (u64)(selt * sx(a, esize));
            u64 d = velem_get(&vd, dsize, i);
            u64 v = (opc == 0xa) ? prod : (opc == 0x2) ? d + prod : d - prod;
            velem_set(&r, dsize, i, v & dmask);
        }
    } else if (!U && (opc == 0xc || opc == 0xd)) {                      /* SQDMULH/SQRDMULH by elem */
        unsigned n = (Q ? 16u : 8u) >> size;
        for (unsigned i = 0; i < n; i++) {
            /* Overflow-safe: p = a*b fits s64 for esize<=32, so shift instead
             * of forming 2*a*b (which overflows at the INT32_MIN^2 corner). */
            s64 p = sx(velem_get(&vn, size, i) & emask, esize) * selt;
            s64 pre = (opc == 0xd) ? ((p + ((s64)1 << (esize - 2))) >> (esize - 1))
                                   :  (p >> (esize - 1));
            velem_set(&r, size, i, sat_s(pre, esize) & emask);
        }
    } else if (!U && (opc == 0xb || opc == 0x3 || opc == 0x7)) {        /* SQDMULL/SQDMLAL/SQDMLSL by elem */
        unsigned ndest = 64u / esize, base = Q ? ndest : 0, dsize = size + 1;
        for (unsigned i = 0; i < ndest; i++) {
            u64 a = velem_get(&vn, size, base + i) & emask;
            s64 pr = (s64)sqdmull_sat(sx(a, esize), selt, 2 * esize);
            u64 d = velem_get(&vd, dsize, i);
            u64 v = (opc == 0xb) ? (u64)pr
                  : (opc == 0x3) ? ssat_add(sx(d, 2 * esize), pr, 2 * esize)
                                 : ssat_sub(sx(d, 2 * esize), pr, 2 * esize);
            velem_set(&r, dsize, i, v);
        }
    } else if (U && (opc == 0xd || opc == 0xf)) {                       /* SQRDMLAH/SQRDMLSH by elem (FEAT_RDM) */
        unsigned n = (Q ? 16u : 8u) >> size;
        for (unsigned i = 0; i < n; i++)
            velem_set(&r, size, i,
                      sqrdmlah_op(sx(velem_get(&vd, size, i), esize),
                                  sx(velem_get(&vn, size, i), esize),
                                  selt, esize, opc == 0xf) & emask);
    } else if (opc == 0xe && size == 2) {                               /* SDOT/UDOT by elem (FEAT_DotProd) */
        unsigned n = Q ? 4 : 2;
        for (unsigned i = 0; i < n; i++) {           /* one 4-byte Vm group broadcast to every lane */
            u32 acc = vd.s[i];
            for (unsigned j = 0; j < 4; j++)
                acc += U ? (u32)vn.b[4 * i + j] * vm.b[4 * index + j]
                         : (u32)((s32)(s8)vn.b[4 * i + j] * (s8)vm.b[4 * index + j]);
            r.s[i] = acc;
        }
    } else { fpsimd_undef(c, insn); return; }
    c->v[Rd] = r;
}

/* AdvSIMD three-different widening multiply: S/U MULL/MLAL/MLSL (opcodes
 * 0xc/0x8/0xa). Each pair of esize source lanes makes a 2*esize product; bit30=Q
 * picks the SMULL2-style high source half. Poly1305's NEON path multiplies its
 * 32-bit limbs to 64-bit accumulators here (plus the by-element forms). */
/* Saturate an s64 value to e bits (e < 64). */
static u64 sat_s64_to(s64 v, unsigned e) {
    s64 max = ((s64)1 << (e - 1)) - 1;
    s64 min = -((s64)1 << (e - 1));
    if (v > max) { g_fpexc |= FPSR_QC; return (u64)max; }
    if (v < min) { g_fpexc |= FPSR_QC; return (u64)min; }
    return (u64)v;
}

/* Narrowing right shift of a 2*esize-bit source lane to esize bits (esize is
 * 8/16/32, shift in [1, esize*2)). Rounding uses the shift-and-carry identity
 * so everything stays in 64-bit arithmetic (portable to 32-bit hosts). */
static u64 narrow_shr(u64 src, unsigned esize, unsigned shift, int round,
                      int nonsat, int signed_src, int sat_unsigned) {
    u64 emask = (1ULL << esize) - 1;
    if (nonsat) {                                   /* SHRN/RSHRN: truncating */
        u64 w = src >> shift;
        if (round) w += (src >> (shift - 1)) & 1;
        return w & emask;
    }
    if (signed_src) {
        s64 sv = sx(src, 2 * esize);
        s64 w = sv >> shift;
        if (round) w += (sv >> (shift - 1)) & 1;
        if (sat_unsigned) {                         /* SQSHRUN/SQRSHRUN */
            if (w < 0) { g_fpexc |= FPSR_QC; return 0; }
            return sat_umask((u64)w, emask);
        }
        return sat_s64_to(w, esize);                /* SQSHRN/SQRSHRN */
    }
    u64 w = src >> shift;                           /* UQSHRN/UQRSHRN */
    if (round) w += (src >> (shift - 1)) & 1;
    return sat_umask(w, emask);
}

/* SQSHLU: signed source, unsigned saturating left shift (0 <= sh < 64). */
static u64 sqshlu_sat(s64 sv, int sh, u64 emask) {
    if (sv < 0) { g_fpexc |= FPSR_QC; return 0; }   /* negative -> unsigned 0 */
    if (sv == 0) return 0;
    if ((u64)sv > (emask >> sh)) { g_fpexc |= FPSR_QC; return emask; }
    return ((u64)sv << sh) & emask;
}

/* Saturate the doubled product 2*sa*sb to e bits (e = 16/32/64 for every
 * allocated form). sa/sb are sign-extended source lanes of at most 32 bits, so
 * p = sa*sb is exact in s64 (|p| <= 2^62); 2p is saturated by a pre-doubling
 * range check, which keeps the arithmetic in 64 bits (portable to 32-bit
 * hosts). An unallocated 64-bit source makes e 128 -- a destination wider than
 * s64, so nothing can saturate into it and the bound is not computed. */
static u64 sqdmull_sat(s64 sa, s64 sb, unsigned e) {
    s64 max = (e >= 64) ? INT64_MAX : (((s64)1 << (e - 1)) - 1);
    s64 min = (e >= 64) ? INT64_MIN : (-((s64)1 << (e - 1)));
    s64 p = wmul(sa, sb);
    /* 2p > max  <=>  p >= (max+1)/2 = 2^(e-2);  2p < min  <=>  p < -2^(e-2) */
    s64 hi = (e > 64) ? INT64_MAX : ((s64)1 << (e - 2));
    if (p >= hi) { g_fpexc |= FPSR_QC; return (u64)max; }
    if (p < -hi) { g_fpexc |= FPSR_QC; return (u64)min; }
    return (u64)p * 2;
}
static void simd_three_diff(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22), opc = BITS(15, 12);
    unsigned Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned esize = 8u << size, ndest = 64u / esize, base = Q ? ndest : 0, dsize = size + 1;
    u64 emask = (esize >= 64) ? ~0ULL : ((1ULL << esize) - 1);   /* 8/16/32 allocated */
    u64 dmask = (2 * esize >= 64) ? ~0ULL : ((1ULL << (2 * esize)) - 1);
    V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;

    if (opc == 0x4 || opc == 0x6) {                /* ADDHN/RADDHN/SUBHN/RSUBHN: narrow high half */
        V128 res; if (Q) res = vd; else { res.d[0] = res.d[1] = 0; }
        for (unsigned i = 0; i < ndest; i++) {
            u64 a = velem_get(&vn, dsize, i), b = velem_get(&vm, dsize, i);
            u64 wide = (opc == 0x4) ? a + b : a - b;
            if (U) wide += (u64)1 << (esize - 1);  /* rounding variants */
            velem_set(&res, size, base + i, (wide >> esize) & emask);
        }
        c->v[Rd] = res; return;
    }
    if (opc == 0x1 || opc == 0x3) {                /* S/UADDW / S/USUBW: wide ± narrow */
        for (unsigned i = 0; i < ndest; i++) {
            u64 wa = velem_get(&vn, dsize, i), nb = velem_get(&vm, size, base + i) & emask;
            u64 ext = U ? nb : (u64)sx(nb, esize);
            velem_set(&r, dsize, i, ((opc == 0x1) ? wa + ext : wa - ext) & dmask);
        }
        c->v[Rd] = r; return;
    }
    /* long forms (esize source -> 2*esize dest) */
    for (unsigned i = 0; i < ndest; i++) {
        u64 a = velem_get(&vn, size, base + i) & emask, b = velem_get(&vm, size, base + i) & emask;
        u64 d = velem_get(&vd, dsize, i), v;
        u64 adiff = U ? (a > b ? a - b : b - a)
                      : (u64)((sx(a, esize) > sx(b, esize)) ? wsub(sx(a, esize), sx(b, esize))
                                                            : wsub(sx(b, esize), sx(a, esize)));
        u64 prod  = U ? (a * b) : (u64)wmul(sx(a, esize), sx(b, esize));
        switch (opc) {
            case 0x0: v = U ? a + b : (u64)wadd(sx(a,esize), sx(b,esize)); break;  /* S/UADDL */
            case 0x2: v = U ? a - b : (u64)wsub(sx(a,esize), sx(b,esize)); break;  /* S/USUBL */
            case 0x5: v = d + adiff; break;                                    /* S/UABAL */
            case 0x7: v = adiff; break;                                        /* S/UABDL */
            case 0x8: v = d + prod; break;                                     /* S/UMLAL */
            case 0xa: v = d - prod; break;                                     /* S/UMLSL */
            case 0xc: v = prod; break;                                         /* S/UMULL */
            case 0x9: if (U) { fpsimd_undef(c, insn); return; }                /* SQDMLAL */
                      v = ssat_add(sx(d, 2*esize), (s64)sqdmull_sat(sx(a,esize), sx(b,esize), 2*esize), 2*esize); break;
            case 0xb: if (U) { fpsimd_undef(c, insn); return; }                /* SQDMLSL */
                      v = ssat_sub(sx(d, 2*esize), (s64)sqdmull_sat(sx(a,esize), sx(b,esize), 2*esize), 2*esize); break;
            case 0xd: if (U) { fpsimd_undef(c, insn); return; }                /* SQDMULL */
                      v = sqdmull_sat(sx(a,esize), sx(b,esize), 2*esize); break;
            default: fpsimd_undef(c, insn); return;
        }
        velem_set(&r, dsize, i, v & dmask);
    }
    c->v[Rd] = r;
}

/* AdvSIMD across-lanes reductions: ADDV/UMAXV/UMINV/SMAXV/SMINV (horizontal
 * reduce of a vector to a scalar element in Rd). Used by string routines to
 * collapse a per-byte compare mask into a single found/not-found value. */
static void simd_across(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22);
    unsigned opc = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);

    /* FP across (.4s): FMAXNMV/FMINNMV (opc 0x0c), FMAXV/FMINV (opc 0x0f);
     * bit23=a selects min. Result is a scalar in s0. */
    if (U == 1 && (opc == 0x0c || opc == 0x0f)) {
        unsigned a = BIT(23);
        unsigned fop = (opc == 0x0f) ? (a ? FOP_MIN : FOP_MAX) : (a ? FOP_MINNM : FOP_MAXNM);
        float acc = vget_s(&c->v[Rn], 0);
        for (unsigned i = 1; i < 4; i++) acc = fop_s(fop, acc, vget_s(&c->v[Rn], i), 0);
        V128 r; r.d[0] = r.d[1] = 0; vset_s(&r, 0, acc); c->v[Rd] = r;
        return;
    }
    /* FP across (FP16, .4h/.8h): same ops with U=0, sz(bit22)=0; result in h0. */
    if (U == 0 && BIT(22) == 0 && (opc == 0x0c || opc == 0x0f)) {
        unsigned a = BIT(23);
        unsigned fop = (opc == 0x0f) ? (a ? FOP_MIN : FOP_MAX) : (a ? FOP_MINNM : FOP_MAXNM);
        unsigned n = Q ? 8 : 4;
        double acc = f16_to_f64(c->v[Rn].h[0]);
        for (unsigned i = 1; i < n; i++)
            acc = fop_d(fop, acc, f16_to_f64(c->v[Rn].h[i]), 0);
        V128 r; r.d[0] = r.d[1] = 0; r.h[0] = f64_to_f16(acc); c->v[Rd] = r;
        return;
    }

    unsigned esize = 8u << size, n = (Q ? 16 : 8) >> size;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);

    /* SADDLV/UADDLV (opc 0x03): *long* reduction — the destination is 2*esize
     * wide, so the sum must not wrap at the source element width, and SADDLV
     * sign-extends each source lane. */
    if (opc == 0x03) {
        u64 dmask = (2 * esize >= 64) ? ~0ULL : ((1ULL << (2 * esize)) - 1);
        u64 acc = 0;
        for (unsigned i = 0; i < n; i++) {
            u64 e = velem_get(&c->v[Rn], size, i) & emask;
            acc += U ? e : (u64)sx(e, esize);   /* U=1 UADDLV, U=0 SADDLV */
        }
        c->v[Rd].d[0] = acc & dmask;
        c->v[Rd].d[1] = 0;
        return;
    }

    u64 acc = velem_get(&c->v[Rn], size, 0);
    for (unsigned i = 1; i < n; i++) {
        u64 e = velem_get(&c->v[Rn], size, i);
        switch ((U << 5) | opc) {
            case (0 << 5) | 0x1b: acc += e; break;                                  /* ADDV */
            case (0 << 5) | 0x0a: acc = (sx(acc,esize) > sx(e,esize)) ? acc : e; break; /* SMAXV */
            case (1 << 5) | 0x0a: acc = (acc > e) ? acc : e; break;                 /* UMAXV */
            case (0 << 5) | 0x1a: acc = (sx(acc,esize) < sx(e,esize)) ? acc : e; break; /* SMINV */
            case (1 << 5) | 0x1a: acc = (acc < e) ? acc : e; break;                 /* UMINV */
            default: fpsimd_undef(c, insn); return;
        }
    }
    c->v[Rd].d[0] = acc & emask; c->v[Rd].d[1] = 0;
}

/* Exact double -> integer, for a value already known to be integral and in
 * range. Every FP->int convert below goes through these two rather than a host
 * cast, and raises IXC/IOC by hand from the pre-round operand.
 *
 * A cast is not safe for a 64-bit result, because most hosts have no such
 * instruction — x86-64 lacks the unsigned direction, a 32-bit host lacks both —
 * so it becomes synthesized code or a libcall whose *internal* rounding lands
 * in the live status word and is then attributed to the guest's instruction:
 *   - clang's branchless double->u64 evaluates `r - 2^63` on EVERY conversion,
 *     inexact for small values, so an exact FCVTZU came back with IXC set (gcc
 *     branches, and only subtracts when it must);
 *   - on armv7 both directions are libcalls, and libgcc's __aeabi_d2lz just
 *     negates into __aeabi_d2ulz, which splits the operand as
 *     `hi = (u32)(r * 2^-32)` with a *truncating* vcvt — inexact for every r
 *     that is not a multiple of 2^32. `fcvtzs x0, d0` of 1.0 raised IXC on the
 *     armhf-glibc tier, and so did FJCVTZS. Which implementation you get is a
 *     link-time accident and not a property of the compiler: compiler-rt's
 *     hard-float __fixunsdfdi is the same algorithm, but Android's libm
 *     exports its own soft-float __aeabi_d2lz/__aeabi_d2ulz (integer-only,
 *     raise-free) and wins for anything linking -lm, which is why the Termux
 *     armv7 device never showed this and armhf-glibc did.
 * A 32- or 16-bit result does lower to one instruction on every host we build
 * for, but it goes through the same helpers anyway, so that "this file performs
 * no FP->int cast" is an invariant one can grep for — and check in the object,
 * where no vcvt from .f32/.f64 to an integer type and no __aeabi_*2*z helper
 * may survive (the reverse direction, __aeabi_l2d and friends, is expected).
 * Same raise-free bit arithmetic as the f_trunc family above. */
static u64 d_to_u64_exact(double r) {     /* magnitude: the sign bit is ignored */
    u64 b; memcpy(&b, &r, 8);
    int e = (int)((b >> 52) & 0x7ff) - 1023;
    if (e < 0)  return 0;                 /* |r| < 1, and r is integral -> 0 */
    if (e > 63) return UINT64_MAX;        /* caller saturates first; belt only */
    u64 m = (b & 0xfffffffffffffULL) | (1ULL << 52);
    return (e >= 52) ? (m << (e - 52)) : (m >> (52 - e));
}
/* The signed companion, delivered as two's-complement bits because every caller
 * returns the register image anyway. Negating the magnitude in *unsigned*
 * arithmetic is what keeps -2^63 defined behaviour. */
static u64 d_to_s64_exact(double r) {
    u64 m = d_to_u64_exact(r);
    return __builtin_signbit(r) ? 0ULL - m : m;
}

/* FP -> integer convert with saturation (shared clamp logic, scalar and lane
 * alike). x64 selects 64-bit (.2d) vs 32-bit (.4s) result width; is_signed
 * picks the signed form. */
static u64 fcvt_to_int(double r, double orig, int is_signed, int x64) {
    if (r != r) {                      /* NaN -> 0 (FPToFixed), not INT_MIN */
        g_fpexc |= FPSR_IOC;
        return 0;
    }
    /* FPToFixed flags: IOC when the (rounded) value saturates or is Inf,
     * else IXC when rounding discarded bits. orig is the pre-round operand. */
    int sat;
    if (is_signed) sat = x64 ? (r >= 9223372036854775807.0 || r < -9223372036854775808.0)
                             : (r >  2147483647.0          || r < -2147483648.0);
    else           sat = x64 ? (r >= 18446744073709551615.0 || r < 0)
                             : (r >  4294967295.0           || r < 0);
    if (sat) g_fpexc |= FPSR_IOC;
    else if (r != orig) g_fpexc |= FPSR_IXC;
    if (is_signed) {
        if (x64) { u64 m = (r >= 9223372036854775807.0) ? (u64)INT64_MAX : (r <= -9223372036854775808.0) ? (u64)INT64_MIN : d_to_s64_exact(r); return m; }
        u32 m = (r >= 2147483647.0) ? (u32)INT32_MAX : (r <= -2147483648.0) ? (u32)INT32_MIN : (u32)d_to_s64_exact(r); return m;
    }
    if (r < 0) r = 0;
    if (x64) { u64 m = (r >= 18446744073709551615.0) ? UINT64_MAX : d_to_u64_exact(r); return m; }
    u32 m = (r >= 4294967295.0) ? UINT32_MAX : (u32)d_to_u64_exact(r); return m;
}
/* 16-bit saturating fp->int, for the FP16 vector converts (int result sits in a
 * half-width lane). Mirrors fcvt_to_int's clamp at the .8h element width. */
static u16 fcvt_to_int16(double r, double orig, int is_signed) {
    if (r != r) { g_fpexc |= FPSR_IOC; return 0; }  /* NaN -> 0 (FPToFixed) */
    int sat = is_signed ? (r > 32767.0 || r < -32768.0) : (r > 65535.0 || r < 0);
    if (sat) g_fpexc |= FPSR_IOC;
    else if (r != orig) g_fpexc |= FPSR_IXC;
    if (is_signed) { u16 m = (r >= 32767.0) ? 0x7fffu : (r <= -32768.0) ? 0x8000u : (u16)d_to_s64_exact(r); return m; }
    if (r < 0) r = 0;
    return (r >= 65535.0) ? 0xffffu : (u16)d_to_u64_exact(r);
}
/* Fixed-point FP->int: truncate the (exact) 2^fbits-scaled product, flags per
 * FPToFixed with the product as the pre-round value. */
static u64 fcvt_fixed(double prod, int is_signed, int x64) {
    return fcvt_to_int(f_trunc(prod), prod, is_signed, x64);
}
static u16 fcvt_fixed16(double prod, int is_signed) {
    return fcvt_to_int16(f_trunc(prod), prod, is_signed);
}
/* Round to nearest, ties to even (the f_round helper rounds ties away). Built
 * from f_trunc to avoid a libm dependency (see the FP_INTEGRAL helpers above). */
static double f_round_even(double v) {
    if (!(__builtin_fabs(v) < FP_INTEGRAL)) return v;   /* integral / nan / inf */
    double t = f_trunc(v), d = v - t;                   /* d: fractional, signed */
    if (d > 0.5) t += 1.0;
    else if (d < -0.5) t -= 1.0;
    else if (d == 0.5 || d == -0.5) {                   /* tie -> round to even */
        double half = t / 2.0;
        if (f_trunc(half) != half) t += (v > 0) ? 1.0 : -1.0;
    }
    return t;
}
/* Round a double per AdvSIMD FCVT/FRINT mode: 0=N(even) 1=P 2=M 3=Z 4=A(away).
 * A zero result takes the sign of the operand (ARM FRINT/FCVT semantics). */
static double fround_mode(double v, int rmode) {
    double res;
    switch (rmode) {
        case 0:  res = f_round_even(v); break;   /* nearest, ties to even */
        case 1:  res = f_ceil(v);       break;   /* +inf */
        case 2:  res = f_floor(v);      break;   /* -inf */
        case 3:  res = f_trunc(v);      break;   /* zero */
        default: res = f_round(v);      break;   /* nearest, ties away */
    }
    if (res == 0.0 && __builtin_signbit(v)) res = -0.0;
    return res;
}
/* FRINT with the architectural flag behavior: sNaN input raises IOC and the
 * result NaN is quieted (every FRINT variant); only FRINTX (exact=1) raises
 * IXC when the result differs from the operand. Inputs that arrived through a
 * (double) cast of a float/f16 were already quieted (and IOC-raised) by the
 * cast, so the is_snan_d check only fires for the native double forms. */
static double frint_d(double v, int rmode, int exact) {
    if (v != v) {
        if (is_snan_d(v)) g_fpexc |= FPSR_IOC;
        return quiet_d(v);
    }
    double r = fround_mode(v, rmode);
    if (exact && r != v) g_fpexc |= FPSR_IXC;
    return r;
}

/* ---- FRECPE / FRSQRTE reciprocal estimates (exact ARM algorithm) ----------
 * Implemented directly from the Arm Architecture Reference Manual pseudocode
 * (FPRecipEstimate / FPRSqrtEstimate and the RecipEstimate / RecipSqrtEstimate
 * table functions), so the 8-bit-mantissa estimate matches the architecture
 * bit-for-bit (Newton-Raphson refinement via FRECPS/FRSQRTS depends on the
 * precise starting value). Pure-integer; assumes default rounding and
 * FPCR.FZ=0. Bit-exactness is validated against the qemu-aarch64 oracle. */
static u64 bf_extract(u64 v, unsigned start, unsigned len) {
    return (v >> start) & (len >= 64 ? ~0ULL : ((1ULL << len) - 1));
}
static u64 bf_deposit(u64 v, unsigned start, unsigned len, u64 field) {
    u64 m = (len >= 64 ? ~0ULL : ((1ULL << len) - 1)) << start;
    return (v & ~m) | ((field << start) & m);
}
static int recip_estimate(int input) {        /* input,result in [256,512) */
    int a = (input * 2) + 1, b = (1 << 19) / a;
    return (b + 1) >> 1;
}
static int recip_sqrt_estimate(int input) {    /* input in [128,512) */
    int a, b, r;
    if (input < 256) a = input * 2 + 1;
    else { a = (input >> 1) << 1; a = (a + 1) * 2; }
    b = 512;
    while (a * (b + 1) * (b + 1) < (1 << 28)) b += 1;
    r = (b + 1) >> 1;
    return r;
}
/* The fraction these two take always arrives with its MSB at bit 51 -- f64
 * passes its 52 bits as they are, f32 shifts by 29, f16 by 42 -- which is where
 * the architecture's pseudocode reads it (frac<51>) when it normalises a
 * subnormal input. Testing any higher bit tests a bit no format ever sets, so
 * the "already normalised" arm never runs and the exponent is adjusted for a
 * shift that did not happen: every subnormal comes out off by a power of two or
 * worse. Normal inputs never enter these branches, which is why it stayed
 * hidden -- and why the estimate instructions look right until something feeds
 * them a subnormal. */
static u64 call_recip_estimate(int *exp, int exp_off, u64 frac) {
    u32 scaled, estimate; u64 result_frac; int result_exp;
    if (*exp == 0) {
        if (bf_extract(frac, 51, 1) == 0) { *exp = -1; frac <<= 2; }
        else frac <<= 1;
    }
    scaled = (u32)bf_deposit(1 << 8, 0, 8, bf_extract(frac, 44, 8));
    estimate = recip_estimate(scaled);
    result_exp = exp_off - *exp;
    result_frac = bf_deposit(0, 44, 8, estimate);
    if (result_exp == 0)       result_frac = bf_deposit(result_frac >> 1, 51, 1, 1);
    else if (result_exp == -1) { result_frac = bf_deposit(result_frac >> 2, 50, 2, 1); result_exp = 0; }
    *exp = result_exp;
    return result_frac;
}
static u64 call_recip_sqrt_estimate(int *exp, int exp_off, u64 frac) {
    int estimate; u32 scaled;
    if (*exp == 0) {
        while (bf_extract(frac, 51, 1) == 0) { frac <<= 1; *exp -= 1; }
        frac = bf_extract(frac, 0, 51) << 1;   /* frac<50:0>:'0' */
    }
    if (*exp & 1) scaled = (u32)bf_deposit(1 << 7, 0, 7, bf_extract(frac, 45, 7));
    else          scaled = (u32)bf_deposit(1 << 8, 0, 8, bf_extract(frac, 44, 8));
    estimate = recip_sqrt_estimate(scaled);
    *exp = (exp_off - *exp) / 2;
    return (u64)estimate << 44;
}
static u32 recpe_f32(u32 v) {
    u32 sbit = v & 0x80000000u, frac = v & 0x7fffff; int exp = (v >> 23) & 0xff;
    if (exp == 0xff) {                                             /* nan / inf->0 */
        if (frac) {                       /* FPProcessNaN: the operand itself,
                                           * quieted -- sign and payload kept */
            if (!(frac & 0x400000)) g_fpexc |= FPSR_IOC;           /* signaling */
            return v | 0x400000u;
        }
        return sbit;
    }
    if (exp == 0 && frac == 0) {                                   /* 0 -> inf */
        g_fpexc |= FPSR_DZC;
        return sbit | 0x7f800000u;
    }
    if ((v & 0x7fffffff) < (1u << 21)) {                           /* |x|<2^-128 -> inf */
        g_fpexc |= FPSR_OFC | FPSR_IXC;
        return sbit | 0x7f800000u;
    }
    u64 f = call_recip_estimate(&exp, 253, ((u64)frac) << 29);
    return sbit | ((u32)(exp & 0xff) << 23) | (u32)((f >> 29) & 0x7fffff);
}
static u32 rsqrte_f32(u32 v) {
    u32 sbit = v & 0x80000000u, frac = v & 0x7fffff; int exp = (v >> 23) & 0xff;
    if (exp == 0xff && frac) {                                     /* nan */
        if (!(frac & 0x400000)) g_fpexc |= FPSR_IOC;
        return v | 0x400000u;             /* propagated quieted, sign kept */
    }
    if (exp == 0 && frac == 0) {                                   /* 0 -> inf */
        g_fpexc |= FPSR_DZC;
        return sbit | 0x7f800000u;
    }
    if (sbit) { g_fpexc |= FPSR_IOC; return 0x7fc00000u; }         /* negative -> nan */
    if (exp == 0xff) return 0;                                     /* +inf -> 0 */
    u64 f = call_recip_sqrt_estimate(&exp, 380, ((u64)frac) << 29);
    return sbit | (((u32)exp << 23) & 0x7f800000u) | (u32)((f >> 29) & 0x7fffff);
}
static u64 recpe_f64(u64 v) {
    u64 sbit = v & 0x8000000000000000ULL, frac = v & 0xfffffffffffffULL;
    int exp = (v >> 52) & 0x7ff;
    if (exp == 0x7ff) {
        if (frac) {
            if (!(frac & 0x8000000000000ULL)) g_fpexc |= FPSR_IOC;
            return v | 0x8000000000000ULL;
        }
        return sbit;
    }
    if (exp == 0 && frac == 0) {
        g_fpexc |= FPSR_DZC;
        return sbit | 0x7ff0000000000000ULL;
    }
    if ((v & 0x7fffffffffffffffULL) < (1ULL << 50)) {
        g_fpexc |= FPSR_OFC | FPSR_IXC;
        return sbit | 0x7ff0000000000000ULL;
    }
    u64 f = call_recip_estimate(&exp, 2045, frac);   /* 52-bit frac: MSB already at bit 51 */
    return sbit | ((u64)(exp & 0x7ff) << 52) | f;
}
static u64 rsqrte_f64(u64 v) {
    u64 sbit = v & 0x8000000000000000ULL, frac = v & 0xfffffffffffffULL;
    int exp = (v >> 52) & 0x7ff;
    if (exp == 0x7ff && frac) {
        if (!(frac & 0x8000000000000ULL)) g_fpexc |= FPSR_IOC;
        return v | 0x8000000000000ULL;
    }
    if (exp == 0 && frac == 0) {
        g_fpexc |= FPSR_DZC;
        return sbit | 0x7ff0000000000000ULL;
    }
    if (sbit) { g_fpexc |= FPSR_IOC; return 0x7ff8000000000000ULL; }
    if (exp == 0x7ff) return 0;
    u64 f = call_recip_sqrt_estimate(&exp, 3068, frac);   /* 52-bit frac: MSB at bit 51 */
    return sbit | (((u64)exp << 52) & 0x7ff0000000000000ULL) | (f & 0xfffffffffffffULL);
}
/* Half-precision FRECPE/FRSQRTE. Same estimate machinery as the f32/f64 forms;
 * the exp offset follows the (2*bias-1)/(3*bias-1) pattern (bias=15 -> 29/44) and
 * the 10-bit fraction aligns its MSB at bit 51 (shift 42). */
static u16 recpe_f16(u16 v) {
    u16 sbit = v & 0x8000; unsigned frac = v & 0x3ff; int exp = (v >> 10) & 0x1f;
    if (exp == 0x1f) {                                             /* nan / inf -> 0 */
        if (frac) {
            if (!(frac & 0x200)) g_fpexc |= FPSR_IOC;
            return v | 0x200;
        }
        return sbit;
    }
    if (exp == 0 && frac == 0) { g_fpexc |= FPSR_DZC; return sbit | 0x7c00; } /* 0 -> inf */
    if ((v & 0x7fff) < (1u << 8)) {                                /* |x| < 2^-16 -> inf */
        g_fpexc |= FPSR_OFC | FPSR_IXC;
        return sbit | 0x7c00;
    }
    u64 f = call_recip_estimate(&exp, 29, ((u64)frac) << 42);
    return sbit | ((u16)(exp & 0x1f) << 10) | (u16)((f >> 42) & 0x3ff);
}
static u16 rsqrte_f16(u16 v) {
    u16 sbit = v & 0x8000; unsigned frac = v & 0x3ff; int exp = (v >> 10) & 0x1f;
    if (exp == 0x1f && frac) {                                     /* nan */
        if (!(frac & 0x200)) g_fpexc |= FPSR_IOC;
        return v | 0x200;
    }
    if (exp == 0 && frac == 0) { g_fpexc |= FPSR_DZC; return sbit | 0x7c00; } /* 0 -> inf */
    if (sbit) { g_fpexc |= FPSR_IOC; return 0x7e00; }              /* negative -> nan */
    if (exp == 0x1f) return 0;                                     /* +inf -> 0 */
    u64 f = call_recip_sqrt_estimate(&exp, 44, ((u64)frac) << 42);
    return sbit | (((u16)exp << 10) & 0x7c00) | (u16)((f >> 42) & 0x3ff);
}
/* Half-precision FRECPX (reciprocal of the exponent): sign kept, mantissa zeroed,
 * exponent ones-complemented (0x1e for a subnormal input). Mirrors the s/d form. */
static u16 frecpx_f16(u16 x) {
    u16 sign = x & 0x8000; unsigned exp = (x >> 10) & 0x1f, mant = x & 0x3ff;
    if (exp == 0x1f && mant) {                                     /* NaN -> quiet */
        if (!(mant & 0x200)) g_fpexc |= FPSR_IOC;                  /* signaling */
        return x | 0x0200;
    }
    return sign | ((u16)((exp == 0) ? 0x1e : (~exp & 0x1f)) << 10);
}

/* AdvSIMD two-register misc, floating-point page: FABS/FNEG/FSQRT, FRINTx,
 * FCVT{N,M,P,Z,A}{S,U}, SCVTF/UCVTF, FCMxx #0.0, FCVTL/FCVTN/FCVTXN. hsz=bit23
 * selects the opcode page, sz=bit22 the precision (half-precision deferred). */
static void simd_two_misc_fp(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), hsz = BIT(23), sz = BIT(22), opc = BITS(16, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 vn = c->v[Rn], r; r.d[0] = r.d[1] = 0;

    /* Lane-size-changing converts: FCVTL/FCVTN, both half- and single-precision
     * source forms (sz selects .4h<->.4s vs .2s<->.2d). */
    if (opc == 0x17 && U == 0) {                 /* FCVTL: .4h -> .4s or .2s -> .2d */
        if (sz == 0) {                           /* FCVTL/FCVTL2: .4h -> .4s */
            unsigned base = Q ? 4 : 0;
            for (unsigned i = 0; i < 4; i++)
                vset_s(&r, i, fcvt_h2s(vn.h[base + i]));
            c->v[Rd] = r; return;
        }
        unsigned base = Q ? 2 : 0;
        vset_d(&r, 0, (double)vget_s(&vn, base));
        vset_d(&r, 1, (double)vget_s(&vn, base + 1));
        c->v[Rd] = r; return;
    }
    if (opc == 0x16) {                           /* FCVTN (U=0) / FCVTXN (U=1): .2d -> .2s, .4s -> .4h */
        if (sz == 0) {                           /* FCVTN/FCVTN2: .4s -> .4h (U==0 only; no FCVTXN) */
            if (U) { fpsimd_undef(c, insn); return; }
            V128 res; unsigned hbase;
            if (Q) { res = c->v[Rd]; hbase = 4; } else { res.d[0] = res.d[1] = 0; hbase = 0; }
            for (unsigned i = 0; i < 4; i++)
                res.h[hbase + i] = f64_to_f16((double)vget_s(&vn, i));
            c->v[Rd] = res; return;
        }
        V128 res; if (Q) res = c->v[Rd]; else { res.d[0] = res.d[1] = 0; }
        unsigned base = Q ? 2 : 0;
        if (U) {                                 /* FCVTXN/FCVTXN2: round-to-odd */
            res.s[base]     = f64_to_f32_round_odd(vget_d(&vn, 0));
            res.s[base + 1] = f64_to_f32_round_odd(vget_d(&vn, 1));
        } else {                                 /* FCVTN/FCVTN2: round-to-nearest-even */
            vset_s(&res, base,     (float)vget_d(&vn, 0));
            vset_s(&res, base + 1, (float)vget_d(&vn, 1));
        }
        c->v[Rd] = res; return;
    }

    unsigned key = (U << 6) | (hsz << 5) | opc;
    int dbl = sz, x64 = sz;
    unsigned n = dbl ? (Q ? 2 : 1) : (Q ? 4 : 2);
    for (unsigned i = 0; i < n; i++) {
        double x = dbl ? vget_d(&vn, i) : (double)vget_s(&vn, i);
        u64 ires; int is_int = 0, is_mask = 0; double res = 0; u64 mask = 0;
        switch (key) {
            case 0x2f: res = __builtin_fabs(x); break;                 /* FABS  */
            case 0x6f: res = -x; break;                                /* FNEG  */
            case 0x7f: fsqrt_raise_d(x);
                       res = fpnan_d(dbl ? __builtin_sqrt(x) : (double)__builtin_sqrtf((float)x), x, x); break; /* FSQRT */
            case 0x18: res = frint_d(x, 0, 0); break;                  /* FRINTN */
            case 0x38: res = frint_d(x, 1, 0); break;                  /* FRINTP */
            case 0x58: res = frint_d(x, 4, 0); break;                  /* FRINTA */
            case 0x19: res = frint_d(x, 2, 0); break;                  /* FRINTM */
            case 0x39: res = frint_d(x, 3, 0); break;                  /* FRINTZ */
            case 0x59: case 0x79:                                      /* FRINTX/FRINTI: FPCR.RMode */
                res = frint_d(x, (c->fpcr >> 22) & 3, key == 0x59); break;
            case 0x1d: res = d_from_s64(dbl ? (s64)vn.d[i] : (s32)vn.s[i]); break;                        /* SCVTF */
            case 0x5d: res = dbl ? d_from_u64(vn.d[i]) : d_from_s64((u32)vn.s[i]); break;                    /* UCVTF */
            case 0x1a: case 0x3a: case 0x1b: case 0x3b: case 0x1c:     /* FCVT*S (signed) */
            case 0x5a: case 0x7a: case 0x5b: case 0x7b: case 0x5c: {   /* FCVT*U (unsigned) */
                int rmode = (opc == 0x1a) ? (hsz ? 1 : 0) : (opc == 0x1b) ? (hsz ? 3 : 2) : 4;
                ires = fcvt_to_int(fround_mode(x, rmode), x, U == 0, x64); is_int = 1; break;
            }
            case 0x2c: mask = fcm_test_d(FCM_GT, x, 0.0) ? ~0ULL : 0; is_mask = 1; break;  /* FCMGT #0 */
            case 0x6c: mask = fcm_test_d(FCM_GE, x, 0.0) ? ~0ULL : 0; is_mask = 1; break;  /* FCMGE #0 */
            case 0x2d: mask = fcm_test_d(FCM_EQ, x, 0.0) ? ~0ULL : 0; is_mask = 1; break;  /* FCMEQ #0 */
            case 0x6d: mask = fcm_test_d(FCM_LE, x, 0.0) ? ~0ULL : 0; is_mask = 1; break;  /* FCMLE #0 */
            case 0x2e: mask = fcm_test_d(FCM_LT, x, 0.0) ? ~0ULL : 0; is_mask = 1; break;  /* FCMLT #0 */
            case 0x3d:  /* FRECPE  */
                if (dbl) r.d[i] = recpe_f64(vn.d[i]); else r.s[i] = recpe_f32(vn.s[i]);
                continue;
            case 0x7d:  /* FRSQRTE */
                if (dbl) r.d[i] = rsqrte_f64(vn.d[i]); else r.s[i] = rsqrte_f32(vn.s[i]);
                continue;
            case 0x3c:  /* URECPE  (32-bit unsigned reciprocal estimate) */
            case 0x7c:  /* URSQRTE (32-bit unsigned reciprocal-sqrt estimate) */
                if (dbl) { fpsimd_undef(c, insn); return; }   /* size==11 unallocated */
                { u32 op = vn.s[i];                           /* operand<31:23> indexes the table */
                  if (key == 0x3c)                            /* URECPE: operand<31>==0 -> Ones */
                      r.s[i] = (op < 0x80000000u) ? 0xffffffffu
                             : ((u32)recip_estimate((int)(op >> 23)) << 23);
                  else                                        /* URSQRTE: operand<31:30>==00 -> Ones */
                      r.s[i] = ((op & 0xc0000000u) == 0) ? 0xffffffffu
                             : ((u32)recip_sqrt_estimate((int)(op >> 23)) << 23); }
                continue;
            default: fpsimd_undef(c, insn); return;
        }
        if (is_int)       { if (dbl) r.d[i] = ires; else r.s[i] = (u32)ires; }
        else if (is_mask) { if (dbl) r.d[i] = mask; else r.s[i] = (u32)mask; }
        else              { if (dbl) vset_d(&r, i, res); else vset_s(&r, i, (float)res); }
    }
    c->v[Rd] = r;
}

/* AdvSIMD two-register misc (FP16): the half page of the FP two-misc group.
 * Its own encoding (bit22=1, bits[21:17]=0x1c) but the same (U:hsz:opcode) key as
 * simd_two_misc_fp, so the op selection matches lane-for-lane. Half lanes widen
 * to double and narrow once via f64_to_f16; int<->fp converts use the .8h element
 * width (16-bit source ints / fcvt_to_int16 saturation). FCVTL/FCVTN/FCVTXN are
 * NOT here — those stay in the single/double page. */
static void simd_two_misc_fp16(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), hsz = BIT(23), opc = BITS(16, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned key = (U << 6) | (hsz << 5) | opc;
    V128 vn = c->v[Rn], r; r.d[0] = r.d[1] = 0;
    unsigned n = Q ? 8 : 4;
    for (unsigned i = 0; i < n; i++) {
        double x = f16_to_f64(vn.h[i]), res = 0; int done = 0;
        switch (key) {
            case 0x2f: res = __builtin_fabs(x); break;                 /* FABS   */
            case 0x6f: res = -x; break;                                /* FNEG   */
            case 0x7f: fsqrt_raise_d(x);
                       res = fpnan_d(__builtin_sqrt(x), x, x); break; /* FSQRT  */
            case 0x18: res = frint_d(x, 0, 0); break;                  /* FRINTN */
            case 0x38: res = frint_d(x, 1, 0); break;                  /* FRINTP */
            case 0x58: res = frint_d(x, 4, 0); break;                  /* FRINTA */
            case 0x19: res = frint_d(x, 2, 0); break;                  /* FRINTM */
            case 0x39: res = frint_d(x, 3, 0); break;                  /* FRINTZ */
            case 0x59: case 0x79:                                      /* FRINTX/FRINTI: FPCR.RMode */
                res = frint_d(x, (c->fpcr >> 22) & 3, key == 0x59); break;
            case 0x1d: r.h[i] = f64_to_f16((double)(s16)vn.h[i]); done = 1; break; /* SCVTF */
            case 0x5d: r.h[i] = f64_to_f16((double)(u16)vn.h[i]); done = 1; break; /* UCVTF */
            case 0x1a: case 0x3a: case 0x1b: case 0x3b: case 0x1c:     /* FCVT*S (signed) */
            case 0x5a: case 0x7a: case 0x5b: case 0x7b: case 0x5c: {   /* FCVT*U (unsigned) */
                int rmode = (opc == 0x1a) ? (hsz ? 1 : 0) : (opc == 0x1b) ? (hsz ? 3 : 2) : 4;
                r.h[i] = fcvt_to_int16(fround_mode(x, rmode), x, U == 0); done = 1; break;
            }
            case 0x2c: r.h[i] = fcm_test_d(FCM_GT, x, 0.0) ? 0xffffu : 0; done = 1; break;  /* FCMGT #0 */
            case 0x6c: r.h[i] = fcm_test_d(FCM_GE, x, 0.0) ? 0xffffu : 0; done = 1; break;  /* FCMGE #0 */
            case 0x2d: r.h[i] = fcm_test_d(FCM_EQ, x, 0.0) ? 0xffffu : 0; done = 1; break;  /* FCMEQ #0 */
            case 0x6d: r.h[i] = fcm_test_d(FCM_LE, x, 0.0) ? 0xffffu : 0; done = 1; break;  /* FCMLE #0 */
            case 0x2e: r.h[i] = fcm_test_d(FCM_LT, x, 0.0) ? 0xffffu : 0; done = 1; break;  /* FCMLT #0 */
            case 0x3d: r.h[i] = recpe_f16(vn.h[i]);  done = 1; break;   /* FRECPE  */
            case 0x7d: r.h[i] = rsqrte_f16(vn.h[i]); done = 1; break;   /* FRSQRTE */
            default: fpsimd_undef(c, insn); return;
        }
        if (!done) r.h[i] = f64_to_f16(res);
    }
    c->v[Rd] = r;
}

/* AdvSIMD two-register misc: per-element unary ops (NOT, NEG, compare-with-zero,
 * ABS, etc.) plus the common element reductions. */
static void simd_two_misc(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22);
    unsigned opc = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);

    /* Floating-point page (FABS/FNEG/FCMxx#0, FCVT/FRINT family, FSQRT, SCVTF).
     * opcodes 0x0c-0x0f and 0x16-0x1f are exclusively FP here. */
    if ((opc >= 0x0c && opc <= 0x0f) || opc >= 0x16) { simd_two_misc_fp(c, insn); return; }

    if (opc == 0x05 && U == 1 && size == 0) {  /* NOT (bitwise, byte) */
        c->v[Rd].d[0] = ~c->v[Rn].d[0]; c->v[Rd].d[1] = Q ? ~c->v[Rn].d[1] : 0; return;
    }
    /* REV64/REV32/REV16: reverse esize-bit elements within each container.
     * opcode 0x00 U=0 -> REV64, U=1 -> REV32; opcode 0x01 U=0 -> REV16. */
    if (opc == 0x00 || (opc == 0x01 && U == 0)) {
        unsigned container = (opc == 0x01) ? 16 : (U ? 32 : 64);
        unsigned resize = 8u << size;                       /* element size in bits */
        if (resize >= container) { fpsimd_undef(c, insn); return; }   /* arch-UNDEFINED */
        unsigned cb = container / 8, eb = resize / 8, total = Q ? 16 : 8;
        V128 rr; rr.d[0] = rr.d[1] = 0;
        for (unsigned base = 0; base < total; base += cb)
            for (unsigned e = 0; e < cb / eb; e++)
                for (unsigned k = 0; k < eb; k++)
                    rr.b[base + (cb/eb - 1 - e)*eb + k] = c->v[Rn].b[base + e*eb + k];
        c->v[Rd] = rr; return;
    }
    /* XTN/XTN2: narrow each source element (2*esize) to esize; Q=1 -> high half. */
    if (opc == 0x12 && U == 0 && size != 3) {
        unsigned nd = 64u / (8u << size), base = Q ? nd : 0;
        V128 r; if (Q) r = c->v[Rd]; else { r.d[0] = r.d[1] = 0; }
        for (unsigned i = 0; i < nd; i++)
            velem_set(&r, size, base + i, velem_get(&c->v[Rn], size + 1, i));
        c->v[Rd] = r; return;
    }
    /* RBIT (byte bit-reverse): opcode 0x05 U=1 size=01 (NOT is size=00, above). */
    if (opc == 0x05 && U == 1 && size == 1) {
        unsigned total = Q ? 16 : 8; V128 r; r.d[0] = r.d[1] = 0;
        for (unsigned b = 0; b < total; b++) {
            u8 x = c->v[Rn].b[b], y = 0;
            for (int k = 0; k < 8; k++) if (x & (1 << k)) y |= 1 << (7 - k);
            r.b[b] = y;
        }
        c->v[Rd] = r; return;
    }
    /* SADDLP/UADDLP (0x02) and SADALP/UADALP (0x06): pairwise add long (+acc). */
    if (opc == 0x02 || opc == 0x06) {
        unsigned esz = 8u << size, nsrc = (Q ? 16 : 8) >> size, nd = nsrc / 2, dsz = size + 1;
        u64 dmask = (2 * esz >= 64) ? ~0ULL : ((1ULL << (2 * esz)) - 1);
        V128 r; r.d[0] = r.d[1] = 0;
        for (unsigned i = 0; i < nd; i++) {
            u64 e0 = velem_get(&c->v[Rn], size, 2*i), e1 = velem_get(&c->v[Rn], size, 2*i + 1);
            u64 sum = U ? (e0 + e1) : (u64)wadd(sx(e0, esz), sx(e1, esz));
            if (opc == 0x06) sum += velem_get(&c->v[Rd], dsz, i);   /* ADALP accumulate */
            velem_set(&r, dsz, i, sum & dmask);
        }
        c->v[Rd] = r; return;
    }
    /* SQXTN/UQXTN (0x14) and SQXTUN (0x12,U=1): saturating extract narrow. */
    if (opc == 0x14 || (opc == 0x12 && U == 1)) {
        unsigned esz = 8u << size, nd = 64u / esz, base = Q ? nd : 0;
        u64 emask = (esz >= 64) ? ~0ULL : ((1ULL << esz) - 1);   /* 8/16/32 allocated */
        V128 r; if (Q) r = c->v[Rd]; else { r.d[0] = r.d[1] = 0; }
        for (unsigned i = 0; i < nd; i++) {
            u64 src = velem_get(&c->v[Rn], size + 1, i), nv;
            if (opc == 0x12)  nv = sat_u(sx(src, 2*esz), esz);          /* SQXTUN: signed->unsigned */
            else if (U == 0)  nv = sat_s(sx(src, 2*esz), esz);          /* SQXTN: signed */
            else              nv = sat_umask(src, emask);               /* UQXTN: unsigned */
            velem_set(&r, size, base + i, nv & emask);
        }
        c->v[Rd] = r; return;
    }
    /* SHLL/SHLL2 (0x13,U=1): shift left long by the element size. */
    if (opc == 0x13 && U == 1) {
        unsigned esz = 8u << size, nd = 64u / esz, base = Q ? nd : 0, dsz = size + 1;
        u64 emask = (esz >= 64) ? ~0ULL : ((1ULL << esz) - 1);
        u64 dmask = (2 * esz >= 64) ? ~0ULL : ((1ULL << (2 * esz)) - 1);
        V128 r; r.d[0] = r.d[1] = 0;
        for (unsigned i = 0; i < nd; i++)
            velem_set(&r, dsz, i,
                      (esz >= 64 ? 0   /* unallocated .2d: everything shifts out */
                                 : ((velem_get(&c->v[Rn], size, base + i) & emask) << esz))
                      & dmask);
        c->v[Rd] = r; return;
    }
    unsigned esize = 8u << size, n = (Q ? 16 : 8) >> size;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
    V128 r; r.d[0] = r.d[1] = 0;
    for (unsigned i = 0; i < n; i++) {
        u64 a = velem_get(&c->v[Rn], size, i), v;
        switch ((U << 5) | opc) {
            case (0 << 5) | 0x08: v = (sx(a,esize) >  0) ? emask : 0; break;   /* CMGT #0 */
            case (1 << 5) | 0x08: v = (sx(a,esize) >= 0) ? emask : 0; break;   /* CMGE #0 */
            case (0 << 5) | 0x09: v = (a == 0) ? emask : 0; break;             /* CMEQ #0 */
            case (1 << 5) | 0x09: v = (sx(a,esize) <= 0) ? emask : 0; break;   /* CMLE #0 */
            case (0 << 5) | 0x0a: v = (sx(a,esize) <  0) ? emask : 0; break;   /* CMLT #0 */
            case (0 << 5) | 0x05: v = (u64)__builtin_popcount((unsigned)(a & 0xff)); break; /* CNT */
            case (0 << 5) | 0x0b: v = wabs(sx(a,esize)); break;                /* ABS */
            case (1 << 5) | 0x0b: v = 0u - a; break;                           /* NEG */
            case (1 << 5) | 0x04: { u64 val = a & emask; unsigned cnt = 0;     /* CLZ */
                for (int bit = esize - 1; bit >= 0; bit--) { if (val & (1ULL << bit)) break; cnt++; } v = cnt; } break;
            case (0 << 5) | 0x04: { u64 val = a & emask; unsigned msb = (val >> (esize-1)) & 1, cnt = 0; /* CLS */
                for (int bit = esize - 2; bit >= 0; bit--) { if (((val >> bit) & 1) == msb) cnt++; else break; } v = cnt; } break;
            case (0 << 5) | 0x03: { u64 d = velem_get(&c->v[Rd], size, i);     /* SUQADD: signed acc + unsigned */
                v = suqadd_sat(d, a, esize); } break;
            case (1 << 5) | 0x03: { u64 d = velem_get(&c->v[Rd], size, i) & emask; /* USQADD */
                v = usqadd_sat(d, sx(a, esize), esize); } break;
            case (0 << 5) | 0x07: { s64 s = sx(a, esize);                      /* SQABS */
                v = (s < 0) ? sat_neg(s, esize) : sat_s(s, esize); } break;
            case (1 << 5) | 0x07: v = sat_neg(sx(a, esize), esize); break;     /* SQNEG */
            default: fpsimd_undef(c, insn); return;
        }
        velem_set(&r, size, i, v & emask);
    }
    c->v[Rd] = r;
}

/* AdvSIMD scalar two-register misc (FP16): the half Hd,Hn forms — SCVTF/UCVTF,
 * FCVT{N,M,P,Z,A}{S,U}, FCM{EQ,GT,GE,LE,LT}#0, FRECPE/FRSQRTE, and the scalar-only
 * FRECPX. Own page (bit22=1, bits[21:17]=0x1c) but the SAME (U:hsz:opcode) key as
 * simd_two_misc_fp, applied to the single low half lane. */
static void simd_scalar_cvt_fp16(CPU *c, u32 insn) {
    unsigned U = BIT(29), hsz = BIT(23), opc = BITS(16, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned key = (U << 6) | (hsz << 5) | opc;
    u16 h = c->v[Rn].h[0]; double x = f16_to_f64(h);
    V128 r; r.d[0] = r.d[1] = 0;
    switch (key) {
        case 0x1d: r.h[0] = f64_to_f16((double)(s16)h); break;     /* SCVTF */
        case 0x5d: r.h[0] = f64_to_f16((double)(u16)h); break;     /* UCVTF */
        case 0x1a: case 0x3a: case 0x1b: case 0x3b: case 0x1c:     /* FCVT*S (signed) */
        case 0x5a: case 0x7a: case 0x5b: case 0x7b: case 0x5c: {   /* FCVT*U (unsigned) */
            int rmode = (opc == 0x1a) ? (hsz ? 1 : 0) : (opc == 0x1b) ? (hsz ? 3 : 2) : 4;
            r.h[0] = fcvt_to_int16(fround_mode(x, rmode), x, U == 0); break;
        }
        case 0x2c: r.h[0] = fcm_test_d(FCM_GT, x, 0.0) ? 0xffffu : 0; break;  /* FCMGT #0 */
        case 0x6c: r.h[0] = fcm_test_d(FCM_GE, x, 0.0) ? 0xffffu : 0; break;  /* FCMGE #0 */
        case 0x2d: r.h[0] = fcm_test_d(FCM_EQ, x, 0.0) ? 0xffffu : 0; break;  /* FCMEQ #0 */
        case 0x6d: r.h[0] = fcm_test_d(FCM_LE, x, 0.0) ? 0xffffu : 0; break;  /* FCMLE #0 */
        case 0x2e: r.h[0] = fcm_test_d(FCM_LT, x, 0.0) ? 0xffffu : 0; break;  /* FCMLT #0 */
        case 0x3d: r.h[0] = recpe_f16(h);  break;                  /* FRECPE  */
        case 0x7d: r.h[0] = rsqrte_f16(h); break;                  /* FRSQRTE */
        case 0x3f: r.h[0] = frecpx_f16(h); break;                  /* FRECPX  */
        default: fpsimd_undef(c, insn); return;
    }
    c->v[Rd] = r;
}

/* AdvSIMD scalar two-register misc — FP<->integer convert where the integer
 * operand/result sits in a SIMD register lane (not a GPR). Emitted by libc
 * number formatting, e.g. `UCVTF d,d`. Mirrors the GPR-form convert in
 * exec_fp_scalar (rounding + saturation), sourcing/writing the V128 lane. */
static void simd_scalar_cvt(CPU *c, u32 insn) {
    unsigned U = BIT(29), o2 = BIT(23), sz = BIT(22);
    unsigned opcode = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);
    bool dbl = (sz == 1);

    if (o2 == 0 && opcode == 0x1d) {                 /* SCVTF / UCVTF: int -> fp */
        if (dbl) { u64 i = c->v[Rn].d[0]; fp_wr_d(c, Rd, U ? d_from_u64(i) : d_from_s64((s64)i)); }
        else     { u32 i = c->v[Rn].s[0]; fp_wr_s(c, Rd, f_from_s64(U ? (s64)(u32)i : (s64)(s32)i)); }
        return;
    }
    if (opcode == 0x1a || opcode == 0x1b || (opcode == 0x1c && o2 == 0)) { /* FCVT* fp->int */
        /* Same rounding-mode selection and saturating convert as the vector
         * form in simd_two_misc: 0x1a is N/P, 0x1b is M/Z, 0x1c is A. Going
         * through fround_mode + fcvt_to_int rather than open-coding it is what
         * gets FCVTN*'s ties-to-even (f_round is ties-AWAY) and the FPToFixed
         * flags -- IOC on NaN or saturation, IXC when rounding lost bits. */
        double v = dbl ? fp_rd_d(c, Rn) : (double)fp_rd_s(c, Rn);
        int rmode = (opcode == 0x1a) ? (o2 ? 1 : 0)
                  : (opcode == 0x1b) ? (o2 ? 3 : 2) : 4;
        c->v[Rd].d[0] = fcvt_to_int(fround_mode(v, rmode), v, U == 0, dbl);
        c->v[Rd].d[1] = 0;
        return;
    }
    if (opcode == 0x16 && U == 1 && o2 == 0 && sz == 1) {  /* FCVTXN Sd,Dn: round-to-odd .d -> .s */
        V128 r; r.d[0] = r.d[1] = 0;
        r.s[0] = f64_to_f32_round_odd(vget_d(&c->v[Rn], 0));
        c->v[Rd] = r; return;
    }

    /* FP scalar misc: FRECPE/FRSQRTE (opcode 0x1d, hsz=1), FCMxx #0.0 (0x0c-0x0e). */
    if (opcode == 0x1d && o2 == 1) {
        V128 r; r.d[0] = r.d[1] = 0;
        if (dbl) r.d[0] = U ? rsqrte_f64(c->v[Rn].d[0]) : recpe_f64(c->v[Rn].d[0]);
        else     r.s[0] = U ? rsqrte_f32(c->v[Rn].s[0]) : recpe_f32(c->v[Rn].s[0]);
        c->v[Rd] = r; return;
    }
    if (opcode >= 0x0c && opcode <= 0x0e) {
        double x = dbl ? vget_d(&c->v[Rn], 0) : (double)vget_s(&c->v[Rn], 0);
        int t = (opcode == 0x0c) ? fcm_test_d(U ? FCM_GE : FCM_GT, x, 0.0)
              : (opcode == 0x0d) ? fcm_test_d(U ? FCM_LE : FCM_EQ, x, 0.0)
                                 : fcm_test_d(FCM_LT, x, 0.0);
        V128 r; r.d[0] = r.d[1] = 0;
        if (dbl) r.d[0] = t ? ~0ULL : 0; else r.s[0] = t ? 0xffffffffu : 0;
        c->v[Rd] = r; return;
    }
    if (opcode == 0x1f && o2 == 1) {                 /* FRECPX: reciprocal of the exponent */
        V128 r; r.d[0] = r.d[1] = 0;                 /* sign kept, mantissa zeroed, exp = ~exp */
        if (dbl) {
            u64 x = c->v[Rn].d[0], sign = x & (1ULL << 63);
            unsigned exp = (x >> 52) & 0x7ff; u64 mant = x & 0xfffffffffffffULL;
            if (exp == 0x7ff && mant) {                                          /* NaN -> quiet */
                if (!(mant & (1ULL << 51))) g_fpexc |= FPSR_IOC;
                r.d[0] = x | (1ULL << 51);
            }
            else r.d[0] = sign | ((u64)((exp == 0) ? 0x7fe : (~exp & 0x7ff)) << 52);
        } else {
            u32 x = c->v[Rn].s[0], sign = x & 0x80000000u;
            unsigned exp = (x >> 23) & 0xff, mant = x & 0x7fffffu;
            if (exp == 0xff && mant) {                                            /* NaN -> quiet */
                if (!(mant & (1u << 22))) g_fpexc |= FPSR_IOC;
                r.s[0] = x | (1u << 22);
            }
            else r.s[0] = sign | ((u32)((exp == 0) ? 0xfe : (~exp & 0xff)) << 23);
        }
        c->v[Rd] = r; return;
    }

    /* Integer scalar two-misc (size = bits[23:22] selects element width). */
    unsigned size = BITS(23, 22), esize = 8u << size;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
    if (opcode == 0x14 || (opcode == 0x12 && U == 1)) {     /* SQXTN/UQXTN/SQXTUN */
        u64 src = velem_get(&c->v[Rn], size + 1, 0), nv;
        if (opcode == 0x12)  nv = sat_u(sx(src, 2*esize), esize);
        else if (U == 0)     nv = sat_s(sx(src, 2*esize), esize);
        else                 nv = sat_umask(src, emask);
        V128 r; r.d[0] = r.d[1] = 0; velem_set(&r, size, 0, nv & emask); c->v[Rd] = r; return;
    }
    u64 a = velem_get(&c->v[Rn], size, 0), v; int ok = 1;
    switch ((U << 5) | opcode) {
        case (0 << 5) | 0x07: { s64 s = sx(a,esize);                                              /* SQABS */
            v = (s < 0) ? sat_neg(s, esize) : sat_s(s, esize); } break;
        case (1 << 5) | 0x07: v = sat_neg(sx(a,esize), esize); break;                             /* SQNEG */
        case (0 << 5) | 0x03: { u64 d = velem_get(&c->v[Rd],size,0); v = suqadd_sat(d, a, esize); } break; /* SUQADD */
        case (1 << 5) | 0x03: { u64 d = velem_get(&c->v[Rd],size,0) & emask;       /* USQADD */
            v = usqadd_sat(d, sx(a,esize), esize); } break;
        case (0 << 5) | 0x08: v = (sx(a,esize) >  0) ? emask : 0; break;   /* CMGT #0 */
        case (1 << 5) | 0x08: v = (sx(a,esize) >= 0) ? emask : 0; break;   /* CMGE #0 */
        case (0 << 5) | 0x09: v = (a == 0) ? emask : 0; break;             /* CMEQ #0 */
        case (1 << 5) | 0x09: v = (sx(a,esize) <= 0) ? emask : 0; break;   /* CMLE #0 */
        case (0 << 5) | 0x0a: v = (sx(a,esize) <  0) ? emask : 0; break;   /* CMLT #0 */
        case (0 << 5) | 0x0b: v = wabs(sx(a,esize)); break;                                       /* ABS */
        case (1 << 5) | 0x0b: v = 0u - a; break;                           /* NEG */
        default: ok = 0; v = 0; break;
    }
    if (ok) { V128 r; r.d[0] = r.d[1] = 0; velem_set(&r, size, 0, v & emask); c->v[Rd] = r; return; }
    fpsimd_undef(c, insn);
}

/* AdvSIMD shift by immediate: SHL/SSHR/USHR (same width) and SSHLL/USHLL
 * (widening long). Used by musl/busybox string and math routines. */
static void simd_shift_imm(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), immh = BITS(22, 19), immb = BITS(18, 16);
    unsigned opc = BITS(15, 11), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned immhb = (immh << 3) | immb;
    unsigned size = (immh & 8) ? 3 : (immh & 4) ? 2 : (immh & 2) ? 1 : 0;
    unsigned esize = 8u << size;

    if (opc == 0x14) {                         /* SSHLL/USHLL (widening) */
        unsigned shift = immhb - esize, n = 64 / esize, base = Q ? n : 0;
        V128 r; r.d[0] = r.d[1] = 0;
        for (unsigned i = 0; i < n; i++) {
            u64 s = velem_get(&c->v[Rn], size, base + i);
            u64 w = U ? (s << shift) : ((u64)sx(s, esize) << shift);
            velem_set(&r, size + 1, i, w);     /* result element is 2*esize */
        }
        c->v[Rd] = r;
        return;
    }

    /* Narrowing right shifts (source 2*esize -> dest esize):
     * 0x10 SHRN/SQSHRUN, 0x11 RSHRN/SQRSHRUN, 0x12 SQSHRN/UQSHRN, 0x13 SQRSHRN/UQRSHRN. */
    if (opc >= 0x10 && opc <= 0x13) {
        if (immh & 8) { fpsimd_undef(c, insn); return; }   /* reserved (no 128-bit dest) */
        unsigned shift = 2 * esize - immhb, nd = 64 / esize, base = Q ? nd : 0;
        int round = (opc == 0x11 || opc == 0x13);
        int nonsat = ((opc == 0x10 || opc == 0x11) && U == 0);          /* SHRN/RSHRN */
        int signed_src = nonsat ? 0 : ((opc == 0x10 || opc == 0x11) ? 1 : (U == 0));
        int sat_unsigned = (opc == 0x10 || opc == 0x11) ? 1 : (U == 1);
        u64 emask = (1ULL << esize) - 1;
        u64 smask = (2 * esize >= 64) ? ~0ULL : ((1ULL << (2 * esize)) - 1);
        V128 r; if (Q) r = c->v[Rd]; else { r.d[0] = r.d[1] = 0; }
        for (unsigned i = 0; i < nd; i++) {
            u64 src = velem_get(&c->v[Rn], size + 1, i) & smask;
            u64 nv = narrow_shr(src, esize, shift, round, nonsat, signed_src, sat_unsigned);
            velem_set(&r, size, base + i, nv & emask);
        }
        c->v[Rd] = r; return;
    }

    /* Fixed-point convert: SCVTF/UCVTF (0x1c), FCVTZS/FCVTZU (0x1f). */
    if (opc == 0x1c || opc == 0x1f) {
        if (size == 0) { fpsimd_undef(c, insn); return; }   /* 8-bit has no fp form */
        unsigned fbits = 2 * esize - immhb, n = (Q ? 16 : 8) >> size;
        int dbl = (size == 3);
        u64 pb = (u64)(fbits + 1023) << 52; double pw; memcpy(&pw, &pb, 8);  /* 2^fbits */
        V128 r; r.d[0] = r.d[1] = 0;
        if (size == 1) {                                  /* FP16 lanes: int16 <-> half / 2^fbits */
            for (unsigned i = 0; i < n; i++) {
                if (opc == 0x1c)                          /* fixed -> half */
                    r.h[i] = f64_to_f16(d_from_s64(U ? (u16)c->v[Rn].h[i] : (s16)c->v[Rn].h[i]) / pw);
                else                                      /* half -> fixed (trunc, saturating) */
                    r.h[i] = fcvt_fixed16(f16_to_f64(c->v[Rn].h[i]) * pw, U == 0);
            }
            c->v[Rd] = r; return;
        }
        for (unsigned i = 0; i < n; i++) {
            if (opc == 0x1c) {                            /* fixed -> FP */
                if (dbl) vset_d(&r, i, (U ? d_from_u64(c->v[Rn].d[i]) : d_from_s64((s64)c->v[Rn].d[i])) / pw);
                else     vset_s(&r, i, f_from_s64(U ? (s64)(u32)c->v[Rn].s[i] : (s64)(s32)c->v[Rn].s[i]) / (float)pw);
            } else {                                      /* FP -> fixed (trunc, saturating) */
                double x = (dbl ? vget_d(&c->v[Rn], i) : (double)vget_s(&c->v[Rn], i)) * pw;
                u64 iv = fcvt_fixed(x, U == 0, dbl);
                if (dbl) r.d[i] = iv; else r.s[i] = (u32)iv;
            }
        }
        c->v[Rd] = r; return;
    }

    unsigned n = (Q ? 16 : 8) >> size;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
    V128 r; r.d[0] = r.d[1] = 0;
    for (unsigned i = 0; i < n; i++) {
        u64 a = velem_get(&c->v[Rn], size, i), v;
        switch ((U << 5) | opc) {
            case (0 << 5) | 0x0a: v = a << (immhb - esize); break;             /* SHL */
            /* Right-shift amount can equal the element width (e.g. USHR .2d #64),
             * where a plain C `>>` is undefined; route through vreg_shift, which
             * clamps a full-width shift to 0 (USHR) / sign-fill (SSHR). */
            case (0 << 5) | 0x00: v = vreg_shift(a, -(int)(2 * esize - immhb), esize, 1, 0, 0); break; /* SSHR */
            case (1 << 5) | 0x00: v = vreg_shift(a, -(int)(2 * esize - immhb), esize, 0, 0, 0); break; /* USHR */
            case (1 << 5) | 0x0a: {                                           /* SLI */
                unsigned sh = immhb - esize;                                  /* keep low sh bits of Vd */
                v = (a << sh) | (velem_get(&c->v[Rd], size, i) & (((u64)1 << sh) - 1));
                break;
            }
            case (1 << 5) | 0x08: {                                           /* SRI */
                unsigned sh = 2 * esize - immhb;                              /* keep high sh bits of Vd */
                v = ((a & emask) >> sh) | (velem_get(&c->v[Rd], size, i) & ~(emask >> sh));
                break;
            }
            /* shift-right (+accumulate, rounding) — via the register-shift kernel */
            case (0 << 5) | 0x02: v = velem_get(&c->v[Rd],size,i) + vreg_shift(a, -(int)(2*esize-immhb), esize, 1, 0, 0); break; /* SSRA */
            case (1 << 5) | 0x02: v = velem_get(&c->v[Rd],size,i) + vreg_shift(a, -(int)(2*esize-immhb), esize, 0, 0, 0); break; /* USRA */
            case (0 << 5) | 0x04: v = vreg_shift(a, -(int)(2*esize-immhb), esize, 1, 1, 0); break;  /* SRSHR */
            case (1 << 5) | 0x04: v = vreg_shift(a, -(int)(2*esize-immhb), esize, 0, 1, 0); break;  /* URSHR */
            case (0 << 5) | 0x06: v = velem_get(&c->v[Rd],size,i) + vreg_shift(a, -(int)(2*esize-immhb), esize, 1, 1, 0); break; /* SRSRA */
            case (1 << 5) | 0x06: v = velem_get(&c->v[Rd],size,i) + vreg_shift(a, -(int)(2*esize-immhb), esize, 0, 1, 0); break; /* URSRA */
            /* saturating left shift by immediate */
            case (0 << 5) | 0x0e: v = vreg_shift(a, (int)(immhb-esize), esize, 1, 0, 1); break;     /* SQSHL  */
            case (1 << 5) | 0x0e: v = vreg_shift(a, (int)(immhb-esize), esize, 0, 0, 1); break;     /* UQSHL  */
            case (1 << 5) | 0x0c:                                             /* SQSHLU (signed->unsigned) */
                v = sqshlu_sat(sx(a, esize), (int)(immhb - esize), emask); break;
            default: fpsimd_undef(c, insn); return;
        }
        velem_set(&r, size, i, v & emask);
    }
    c->v[Rd] = r;
}

/* AdvSIMD scalar shift by immediate — the 64-bit D-form SHL / SSHR / USHR.
 * Emitted by libc float formatting (e.g. `SHL d,d,#52` to assemble a mantissa).
 * Only esize=64 is defined for these scalar same-width shifts (immh top bit set). */
static void simd_scalar_shift(CPU *c, u32 insn) {
    unsigned U = BIT(29), immh = BITS(22, 19), immb = BITS(18, 16);
    unsigned opc = BITS(15, 11), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned immhb = (immh << 3) | immb;
    unsigned size = (immh & 8) ? 3 : (immh & 4) ? 2 : (immh & 2) ? 1 : 0;
    unsigned esize = 8u << size;

    /* Saturating narrowing right shift (scalar b/h/s dest, 2*esize source):
     * 0x10 SQSHRUN, 0x11 SQRSHRUN, 0x12 SQSHRN/UQSHRN, 0x13 SQRSHRN/UQRSHRN.
     * (0x10/0x11 with U=0 are SHRN/RSHRN — not saturating.) Mirrors the vector
     * narrowing kernel in simd_shift_imm() for a single lane. */
    if (opc >= 0x10 && opc <= 0x13) {
        if (immh & 8) { fpsimd_undef(c, insn); return; }   /* no 128-bit source */
        unsigned shift = 2 * esize - immhb;
        int round = (opc == 0x11 || opc == 0x13);
        int nonsat = ((opc == 0x10 || opc == 0x11) && U == 0);          /* SHRN/RSHRN */
        int signed_src = nonsat ? 0 : ((opc == 0x10 || opc == 0x11) ? 1 : (U == 0));
        int sat_unsigned = (opc == 0x10 || opc == 0x11) ? 1 : (U == 1);
        u64 emask = (1ULL << esize) - 1;
        u64 smask = (2 * esize >= 64) ? ~0ULL : ((1ULL << (2 * esize)) - 1);
        u64 src = velem_get(&c->v[Rn], size + 1, 0) & smask;
        u64 nv = narrow_shr(src, esize, shift, round, nonsat, signed_src, sat_unsigned);
        V128 r; r.d[0] = r.d[1] = 0; velem_set(&r, size, 0, nv & emask); c->v[Rd] = r; return;
    }

    /* Fixed-point convert: SCVTF/UCVTF (0x1c), FCVTZS/FCVTZU (0x1f) — scalar
     * H/S/D form. Mirrors the vector block. */
    if (opc == 0x1c || opc == 0x1f) {
        if (size == 0) { fpsimd_undef(c, insn); return; }   /* 8-bit has no fp form */
        unsigned fbits = 2 * esize - immhb;
        int dbl = (size == 3);
        u64 pb = (u64)(fbits + 1023) << 52; double pw; memcpy(&pw, &pb, 8);  /* 2^fbits */
        V128 r; r.d[0] = r.d[1] = 0;
        if (size == 1) {                              /* FP16: int16 <-> half / 2^fbits */
            if (opc == 0x1c)                          /* fixed -> half */
                r.h[0] = f64_to_f16(d_from_s64(U ? (u16)c->v[Rn].h[0] : (s16)c->v[Rn].h[0]) / pw);
            else                                      /* half -> fixed (trunc, saturating) */
                r.h[0] = fcvt_fixed16(f16_to_f64(c->v[Rn].h[0]) * pw, U == 0);
            c->v[Rd] = r; return;
        }
        if (opc == 0x1c) {                            /* fixed -> FP */
            if (dbl) vset_d(&r, 0, (U ? d_from_u64(c->v[Rn].d[0]) : d_from_s64((s64)c->v[Rn].d[0])) / pw);
            else     vset_s(&r, 0, f_from_s64(U ? (s64)(u32)c->v[Rn].s[0] : (s64)(s32)c->v[Rn].s[0]) / (float)pw);
        } else {                                      /* FP -> fixed (trunc, saturating) */
            double x = (dbl ? vget_d(&c->v[Rn], 0) : (double)vget_s(&c->v[Rn], 0)) * pw;
            u64 iv = fcvt_fixed(x, U == 0, dbl);
            if (dbl) r.d[0] = iv; else r.s[0] = (u32)iv;
        }
        c->v[Rd] = r; return;
    }

    if (!(immh & 8)) { fpsimd_undef(c, insn); return; }   /* remaining same-width shifts are 64-bit */
    u64 a = c->v[Rn].d[0], v;
    int rsh = -(int)(128 - immhb);                                          /* right-shift amount */
    switch ((U << 5) | opc) {
        case (0 << 5) | 0x0a: v = a << (immhb - 64); break;                 /* SHL  */
        case (0 << 5) | 0x00: { unsigned sh = 128 - immhb;                  /* SSHR */
            v = (u64)((s64)a >> (sh >= 64 ? 63 : sh)); } break;
        case (1 << 5) | 0x00: { unsigned sh = 128 - immhb;                  /* USHR */
            v = (sh >= 64) ? 0 : (a >> sh); } break;
        case (1 << 5) | 0x0a: { unsigned sh = immhb - 64;                   /* SLI: keep low sh bits of Vd */
            v = (a << sh) | (c->v[Rd].d[0] & (((u64)1 << sh) - 1)); } break;
        case (1 << 5) | 0x08: { unsigned sh = 128 - immhb;                  /* SRI: keep high sh bits of Vd */
            u64 keep = (sh >= 64) ? ~0ULL : ~(~0ULL >> sh);                 /* sh==64 (#64): result is Vd */
            v = ((sh >= 64) ? 0 : (a >> sh)) | (c->v[Rd].d[0] & keep); } break;
        case (0 << 5) | 0x02: v = c->v[Rd].d[0] + vreg_shift(a, rsh, 64, 1, 0, 0); break; /* SSRA  */
        case (1 << 5) | 0x02: v = c->v[Rd].d[0] + vreg_shift(a, rsh, 64, 0, 0, 0); break; /* USRA  */
        case (0 << 5) | 0x04: v = vreg_shift(a, rsh, 64, 1, 1, 0); break;   /* SRSHR */
        case (1 << 5) | 0x04: v = vreg_shift(a, rsh, 64, 0, 1, 0); break;   /* URSHR */
        case (0 << 5) | 0x06: v = c->v[Rd].d[0] + vreg_shift(a, rsh, 64, 1, 1, 0); break; /* SRSRA */
        case (1 << 5) | 0x06: v = c->v[Rd].d[0] + vreg_shift(a, rsh, 64, 0, 1, 0); break; /* URSRA */
        case (0 << 5) | 0x0e: v = vreg_shift(a, (int)(immhb - 64), 64, 1, 0, 1); break;    /* SQSHL  */
        case (1 << 5) | 0x0e: v = vreg_shift(a, (int)(immhb - 64), 64, 0, 0, 1); break;    /* UQSHL  */
        case (1 << 5) | 0x0c:                                            /* SQSHLU (signed -> unsigned) */
            v = sqshlu_sat((s64)a, (int)(immhb - 64), ~0ULL); break;
        default: fpsimd_undef(c, insn); return;
    }
    c->v[Rd].d[0] = v; c->v[Rd].d[1] = 0;
}

/* ===================== ARMv8 Cryptographic Extensions =====================
 * SHA-1, SHA-256 and AES, implemented from the Arm ARM shared pseudocode and
 * validated against the algorithms' published test vectors. All work on the
 * little-endian V128 lane views: pseudocode Elem[X,e,32] == X.s[e]. */

/* ror32()/ror64() are provided by types.h. */
static inline u32 rol32(u32 x, unsigned n) { n &= 31; return n ? (x << n) | (x >> (32 - n)) : x; }
static inline u64 rol64(u64 x, unsigned n) { n &= 63; return n ? (x << n) | (x >> (64 - n)) : x; }

static u32 sha_ch(u32 x, u32 y, u32 z)  { return (x & y) ^ (~x & z); }
static u32 sha_maj(u32 x, u32 y, u32 z) { return (x & y) ^ (x & z) ^ (y & z); }
static u32 sha_par(u32 x, u32 y, u32 z) { return x ^ y ^ z; }
static u32 sha256_bsig0(u32 x) { return ror32(x,2)  ^ ror32(x,13) ^ ror32(x,22); }
static u32 sha256_bsig1(u32 x) { return ror32(x,6)  ^ ror32(x,11) ^ ror32(x,25); }
static u32 sha256_ssig0(u32 x) { return ror32(x,7)  ^ ror32(x,18) ^ (x >> 3); }
static u32 sha256_ssig1(u32 x) { return ror32(x,17) ^ ror32(x,19) ^ (x >> 10); }

/* Sha256hash(): 4 rounds with the <y,x> = ROL(y:x,32) one-word rotation. */
static V128 sha256_hash(V128 x, V128 y, V128 w, int part1) {
    for (int e = 0; e < 4; e++) {
        u32 chs = sha_ch(y.s[0], y.s[1], y.s[2]);
        u32 maj = sha_maj(x.s[0], x.s[1], x.s[2]);
        u32 t   = y.s[3] + sha256_bsig1(y.s[0]) + chs + w.s[e];
        x.s[3]  = t + x.s[3];
        y.s[3]  = t + sha256_bsig0(x.s[0]) + maj;
        u32 ny0 = x.s[3], ny1 = y.s[0], ny2 = y.s[1], ny3 = y.s[2];
        u32 nx0 = y.s[3], nx1 = x.s[0], nx2 = x.s[1], nx3 = x.s[2];
        x.s[0]=nx0; x.s[1]=nx1; x.s[2]=nx2; x.s[3]=nx3;
        y.s[0]=ny0; y.s[1]=ny1; y.s[2]=ny2; y.s[3]=ny3;
    }
    return part1 ? x : y;
}
static V128 sha256_su0(V128 x, V128 y) {
    u32 T[4] = { x.s[1], x.s[2], x.s[3], y.s[0] };
    V128 r;
    for (int e = 0; e < 4; e++) r.s[e] = sha256_ssig0(T[e]) + x.s[e];
    return r;
}
static V128 sha256_su1(V128 x, V128 y, V128 z) {
    u32 T3[4] = { y.s[1], y.s[2], y.s[3], z.s[0] };
    V128 r;
    r.s[0] = sha256_ssig1(z.s[2]) + x.s[0] + T3[0];
    r.s[1] = sha256_ssig1(z.s[3]) + x.s[1] + T3[1];
    r.s[2] = sha256_ssig1(r.s[0]) + x.s[2] + T3[2];
    r.s[3] = sha256_ssig1(r.s[1]) + x.s[3] + T3[3];
    return r;
}

/* Cryptographic 3-register SHA: SHA1C/P/M/SU0 (op 0-3), SHA256H/H2/SU1 (op 4-6). */
static void crypto_sha3(CPU *c, u32 insn) {
    unsigned op = BITS(14, 12), Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 d = c->v[Rd], n = c->v[Rn], m = c->v[Rm];
    switch (op) {
        case 0: case 1: case 2: {                /* SHA1C / SHA1P / SHA1M */
            for (int i = 0; i < 4; i++) {
                u32 t = (op == 0) ? sha_ch (d.s[1], d.s[2], d.s[3])
                      : (op == 1) ? sha_par(d.s[1], d.s[2], d.s[3])
                                  : sha_maj(d.s[1], d.s[2], d.s[3]);
                t += rol32(d.s[0], 5) + n.s[0] + m.s[i];
                n.s[0] = d.s[3];
                d.s[3] = d.s[2];
                d.s[2] = rol32(d.s[1], 30);
                d.s[1] = d.s[0];
                d.s[0] = t;
            }
            c->v[Rd] = d; return;
        }
        case 3:                                  /* SHA1SU0 Vd,Vn,Vm */
            d.d[0] ^= d.d[1] ^ m.d[0];
            d.d[1] ^= n.d[0] ^ m.d[1];
            c->v[Rd] = d; return;
        case 4: c->v[Rd] = sha256_hash(d, n, m, 1); return;   /* SHA256H  */
        case 5: c->v[Rd] = sha256_hash(n, d, m, 0); return;   /* SHA256H2 */
        case 6: c->v[Rd] = sha256_su1(d, n, m);     return;   /* SHA256SU1 */
        default: fpsimd_undef(c, insn); return;
    }
}

/* Cryptographic 2-register SHA: SHA1H (0), SHA1SU1 (1), SHA256SU0 (2). */
static void crypto_sha2(CPU *c, u32 insn) {
    unsigned op = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 d = c->v[Rd], n = c->v[Rn];
    switch (op) {
        case 0: {                                /* SHA1H Sd,Sn = ROL(Sn,30) */
            V128 r; r.d[0] = r.d[1] = 0; r.s[0] = rol32(n.s[0], 30);
            c->v[Rd] = r; return;
        }
        case 1:                                  /* SHA1SU1 Vd,Vn */
            d.s[0] = rol32(d.s[0] ^ n.s[1], 1);
            d.s[1] = rol32(d.s[1] ^ n.s[2], 1);
            d.s[2] = rol32(d.s[2] ^ n.s[3], 1);
            d.s[3] = rol32(d.s[3] ^ d.s[0], 1);
            c->v[Rd] = d; return;
        case 2: c->v[Rd] = sha256_su0(d, n); return;   /* SHA256SU0 Vd,Vn */
        default: fpsimd_undef(c, insn); return;
    }
}

static const u8 aes_sbox[256] = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};
static const u8 aes_inv_sbox[256] = {
  0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
  0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
  0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
  0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
  0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
  0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
  0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
  0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
  0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
  0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
  0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
  0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
  0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
  0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
  0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
  0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d
};
/* ShiftRows / InvShiftRows byte permutations (output[i] = input[idx[i]]). */
static const u8 aes_shift[16]     = { 0,5,10,15,4,9,14,3,8,13,2,7,12,1,6,11 };
static const u8 aes_inv_shift[16] = { 0,13,10,7,4,1,14,11,8,5,2,15,12,9,6,3 };

static u8 aes_gfmul(u8 a, u8 b) {            /* GF(2^8) multiply, poly 0x11b */
    u8 p = 0;
    for (int i = 0; i < 8; i++) {
        if (b & 1) p ^= a;
        u8 hi = a & 0x80;
        a = (u8)(a << 1);
        if (hi) a ^= 0x1b;
        b >>= 1;
    }
    return p;
}
static void aes_mixcols(const V128 *in, V128 *out, int inv) {
    for (int col = 0; col < 4; col++) {
        const u8 *a = &in->b[col*4];
        u8 *o = &out->b[col*4];
        if (!inv) {
            o[0] = aes_gfmul(a[0],2) ^ aes_gfmul(a[1],3) ^ a[2] ^ a[3];
            o[1] = a[0] ^ aes_gfmul(a[1],2) ^ aes_gfmul(a[2],3) ^ a[3];
            o[2] = a[0] ^ a[1] ^ aes_gfmul(a[2],2) ^ aes_gfmul(a[3],3);
            o[3] = aes_gfmul(a[0],3) ^ a[1] ^ a[2] ^ aes_gfmul(a[3],2);
        } else {
            o[0] = aes_gfmul(a[0],14) ^ aes_gfmul(a[1],11) ^ aes_gfmul(a[2],13) ^ aes_gfmul(a[3],9);
            o[1] = aes_gfmul(a[0],9)  ^ aes_gfmul(a[1],14) ^ aes_gfmul(a[2],11) ^ aes_gfmul(a[3],13);
            o[2] = aes_gfmul(a[0],13) ^ aes_gfmul(a[1],9)  ^ aes_gfmul(a[2],14) ^ aes_gfmul(a[3],11);
            o[3] = aes_gfmul(a[0],11) ^ aes_gfmul(a[1],13) ^ aes_gfmul(a[2],9)  ^ aes_gfmul(a[3],14);
        }
    }
}

/* Cryptographic AES: AESE(4) AESD(5) AESMC(6) AESIMC(7). */
static void crypto_aes(CPU *c, u32 insn) {
    unsigned op = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 in = c->v[Rn], r;
    r.d[0] = r.d[1] = 0;
    switch (op) {
        case 4:                                  /* AESE: SubBytes(ShiftRows(Vd^Vn)) */
            for (int i = 0; i < 16; i++) in.b[i] = (u8)(c->v[Rd].b[i] ^ c->v[Rn].b[i]);
            for (int i = 0; i < 16; i++) r.b[i] = aes_sbox[in.b[aes_shift[i]]];
            c->v[Rd] = r; return;
        case 5:                                  /* AESD: InvSubBytes(InvShiftRows(Vd^Vn)) */
            for (int i = 0; i < 16; i++) in.b[i] = (u8)(c->v[Rd].b[i] ^ c->v[Rn].b[i]);
            for (int i = 0; i < 16; i++) r.b[i] = aes_inv_sbox[in.b[aes_inv_shift[i]]];
            c->v[Rd] = r; return;
        case 6: aes_mixcols(&in, &r, 0); c->v[Rd] = r; return;   /* AESMC  */
        case 7: aes_mixcols(&in, &r, 1); c->v[Rd] = r; return;   /* AESIMC */
        default: fpsimd_undef(c, insn); return;
    }
}

/* Carryless (polynomial, GF(2)) multiplies for PMULL/PMULL2. */
static void pmull64(u64 a, u64 b, u64 *lo, u64 *hi) {
    u64 rl = 0, rh = 0;
    for (int i = 0; i < 64; i++)
        if ((a >> i) & 1) { rl ^= b << i; if (i) rh ^= b >> (64 - i); }
    *lo = rl; *hi = rh;
}
static u16 pmull8(u8 a, u8 b) {
    u16 r = 0;
    for (int i = 0; i < 8; i++) if ((a >> i) & 1) r ^= (u16)b << i;
    return r;
}

/* PMULL/PMULL2 (AdvSIMD three-different, opcode 0b1110): polynomial multiply
 * long. size==3 -> 64x64->128 (needs FEAT_PMULL); size==0 -> 8x(8x8->16). Q
 * selects the low (PMULL) or high (PMULL2) source half. */
static void crypto_pmull(CPU *c, u32 insn) {
    unsigned Q = BIT(30), size = BITS(23, 22), Rm = BITS(20, 16);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 r; r.d[0] = r.d[1] = 0;
    if (size == 3) {                         /* PMULL{2} Vd.1Q, Vn.1D, Vm.1D */
        u64 lo, hi;
        pmull64(c->v[Rn].d[Q ? 1 : 0], c->v[Rm].d[Q ? 1 : 0], &lo, &hi);
        r.d[0] = lo; r.d[1] = hi; c->v[Rd] = r; return;
    }
    if (size == 0) {                         /* PMULL{2} Vd.8H, Vn.8B, Vm.8B */
        unsigned base = Q ? 8 : 0;
        for (int j = 0; j < 8; j++) r.h[j] = pmull8(c->v[Rn].b[base + j], c->v[Rm].b[base + j]);
        c->v[Rd] = r; return;
    }
    fpsimd_undef(c, insn);
}

/* ARMv8.2 SHA-512 64-bit round functions (FEAT_SHA512). */
static u64 sha512_ch (u64 x, u64 y, u64 z) { return (x & y) ^ (~x & z); }
static u64 sha512_maj(u64 x, u64 y, u64 z) { return (x & y) ^ (x & z) ^ (y & z); }
static u64 sha512_S0 (u64 x) { return ror64(x, 28) ^ ror64(x, 34) ^ ror64(x, 39); } /* Sigma0 */
static u64 sha512_S1 (u64 x) { return ror64(x, 14) ^ ror64(x, 18) ^ ror64(x, 41); } /* Sigma1 */
static u64 sha512_s0 (u64 x) { return ror64(x,  1) ^ ror64(x,  8) ^ (x >> 7); }     /* sigma0 */
static u64 sha512_s1 (u64 x) { return ror64(x, 19) ^ ror64(x, 61) ^ (x >> 6); }     /* sigma1 */

/* ARMv8.2 cryptographic extensions in the 0xce encoding space: FEAT_SHA3
 * (EOR3/BCAX/RAX1/XAR) and FEAT_SHA512 (SHA512H/H2/SU0/SU1). Implemented from
 * the Arm ARM pseudocode; SHA-512 lanes use the little-endian view d[0]=low 64,
 * d[1]=high 64. SM3/SM4 (also in this space) are intentionally left
 * UNDEF/unadvertised. */
static void crypto_sha3_512(CPU *c, u32 insn) {
    unsigned Rm = BITS(20, 16), Ra = BITS(14, 10), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 n = c->v[Rn], m = c->v[Rm], r;

    /* Cryptographic four-register (bit23=0, bit15=0): EOR3 / BCAX. */
    if (BIT(23) == 0 && BIT(15) == 0) {
        V128 a = c->v[Ra];
        switch (BITS(22, 21)) {
            case 0:                              /* EOR3 Vd,Vn,Vm,Va = Vn^Vm^Va */
                r.d[0] = n.d[0] ^ m.d[0] ^ a.d[0];
                r.d[1] = n.d[1] ^ m.d[1] ^ a.d[1];
                c->v[Rd] = r; return;
            case 1:                              /* BCAX Vd,Vn,Vm,Va = Vn^(Vm&~Va) */
                r.d[0] = n.d[0] ^ (m.d[0] & ~a.d[0]);
                r.d[1] = n.d[1] ^ (m.d[1] & ~a.d[1]);
                c->v[Rd] = r; return;
            default: fpsimd_undef(c, insn); return;   /* 2=SM3SS1 (unimplemented) */
        }
    }
    /* XAR Vd,Vn,Vm,#imm6 (bits[23:21]=100): per-lane ROR(Vn^Vm, imm6). */
    if (BITS(23, 21) == 4) {
        unsigned imm6 = BITS(15, 10);
        r.d[0] = ror64(n.d[0] ^ m.d[0], imm6);
        r.d[1] = ror64(n.d[1] ^ m.d[1], imm6);
        c->v[Rd] = r; return;
    }
    /* Cryptographic three-register SHA512 / RAX1 (bits[23:21]=011, bit15=1,
     * bits[14:12]=000), selected by bits[11:10]. */
    if (BITS(23, 21) == 3 && BIT(15) == 1 && BITS(14, 12) == 0) {
        V128 d = c->v[Rd];
        switch (BITS(11, 10)) {
            case 0: {                            /* SHA512H Qd,Qn,Vm */
                u64 d0 = d.d[0], d1 = d.d[1];
                d1 += sha512_S1(m.d[1]) + sha512_ch(m.d[1], n.d[0], n.d[1]);
                d0 += sha512_S1(d1 + m.d[0]) + sha512_ch(d1 + m.d[0], m.d[1], n.d[0]);
                r.d[0] = d0; r.d[1] = d1; c->v[Rd] = r; return;
            }
            case 1: {                            /* SHA512H2 Qd,Qn,Vm */
                u64 d0 = d.d[0], d1 = d.d[1];
                d1 += sha512_S0(m.d[0]) + sha512_maj(n.d[0], m.d[1], m.d[0]);
                d0 += sha512_S0(d1) + sha512_maj(d1, m.d[0], m.d[1]);
                r.d[0] = d0; r.d[1] = d1; c->v[Rd] = r; return;
            }
            case 2:                              /* SHA512SU1 Vd,Vn,Vm */
                r.d[0] = d.d[0] + sha512_s1(n.d[0]) + m.d[0];
                r.d[1] = d.d[1] + sha512_s1(n.d[1]) + m.d[1];
                c->v[Rd] = r; return;
            case 3:                              /* RAX1 Vd,Vn,Vm: Vn ^ ROL(Vm,1) */
                r.d[0] = n.d[0] ^ rol64(m.d[0], 1);
                r.d[1] = n.d[1] ^ rol64(m.d[1], 1);
                c->v[Rd] = r; return;
        }
    }
    /* Cryptographic two-register SHA512: SHA512SU0 Vd,Vn. */
    if (BITS(23, 21) == 6 && BITS(20, 16) == 0 && BITS(15, 10) == 0x20) {
        V128 d = c->v[Rd];
        r.d[0] = d.d[0] + sha512_s0(d.d[1]);
        r.d[1] = d.d[1] + sha512_s0(n.d[0]);
        c->v[Rd] = r; return;
    }
    fpsimd_undef(c, insn);                       /* SM3/SM4 and any gaps */
}

/* AdvSIMD TBL/TBX: byte table lookup across 1-4 consecutive table registers.
 * For each index byte in Vm: out = table[idx] if idx < 16*nregs, else 0 (TBL)
 * or the original Vd byte (TBX). */
static void simd_tbl(CPU *c, u32 insn) {
    unsigned Q = BIT(30), Rm = BITS(20, 16), nregs = BITS(14, 13) + 1, op = BIT(12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned tbytes = nregs * 16, nbyte = Q ? 16 : 8;
    V128 idx = c->v[Rm], old = c->v[Rd];   /* snapshot (may alias table regs) */
    u8 table[64];
    for (unsigned r = 0; r < nregs; r++) {
        V128 t = c->v[(Rn + r) & 31];
        for (int b = 0; b < 16; b++) table[r*16 + b] = t.b[b];
    }
    V128 res; res.d[0] = res.d[1] = 0;
    for (unsigned i = 0; i < nbyte; i++) {
        unsigned ix = idx.b[i];
        res.b[i] = (ix < tbytes) ? table[ix] : (op ? old.b[i] : 0);
    }
    c->v[Rd] = res;
}

/* AdvSIMD permute: ZIP1/ZIP2 (opc 3/7), UZP1/UZP2 (1/5), TRN1/TRN2 (2/6). */
static void simd_permute(CPU *c, u32 insn) {
    unsigned Q = BIT(30), size = BITS(23, 22), Rm = BITS(20, 16), opc = BITS(14, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned lanes = (Q ? 16u : 8u) >> size, half = lanes / 2;
    V128 n = c->v[Rn], m = c->v[Rm], r; r.d[0] = r.d[1] = 0;
    switch (opc) {
        case 1: case 5:                          /* UZP1 (even) / UZP2 (odd) */
            for (unsigned e = 0; e < lanes; e++) {
                unsigned s = 2*e + (opc == 5);
                velem_set(&r, size, e, (s < lanes) ? velem_get(&n, size, s)
                                                   : velem_get(&m, size, s - lanes));
            } break;
        case 2: case 6:                          /* TRN1 (even) / TRN2 (odd) */
            for (unsigned p = 0; p < half; p++) {
                unsigned s = 2*p + (opc == 6);
                velem_set(&r, size, 2*p,   velem_get(&n, size, s));
                velem_set(&r, size, 2*p+1, velem_get(&m, size, s));
            } break;
        case 3: case 7:                          /* ZIP1 (low) / ZIP2 (high) */
            for (unsigned p = 0; p < half; p++) {
                unsigned s = (opc == 7 ? half : 0) + p;
                velem_set(&r, size, 2*p,   velem_get(&n, size, s));
                velem_set(&r, size, 2*p+1, velem_get(&m, size, s));
            } break;
        default: fpsimd_undef(c, insn); return;
    }
    c->v[Rd] = r;
}

/* AdvSIMD EXT: extract nbyte bytes starting at byte offset imm4 from the
 * concatenation Vm:Vn (Vn at the low bytes, Vm at the high bytes), per the ARM
 * pseudocode operand3 = V[m]:V[n]. (Vn and Vm only coincide when Rn==Rm, e.g.
 * the half-swap idiom, which hid this swap until GHASH used distinct regs.) */
static void simd_ext(CPU *c, u32 insn) {
    unsigned Q = BIT(30), Rm = BITS(20, 16);
    unsigned imm4 = BITS(14, 11), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned nbyte = Q ? 16 : 8;
    V128 n = c->v[Rn], m = c->v[Rm], r; r.d[0] = r.d[1] = 0;
    for (unsigned i = 0; i < nbyte; i++) {
        unsigned j = i + imm4;
        r.b[i] = (j < nbyte) ? n.b[j] : m.b[j - nbyte];
    }
    c->v[Rd] = r;
}

/* ===================== Scalar Advanced SIMD =====================
 * The scalar forms reuse the vector kernels (fop_s/d, sat_*, vreg_shift, the
 * estimates) operating on lane 0, with the rest of Vd zeroed. */
static unsigned fp3_key_op(unsigned key) {       /* FP three-same arith op map (matches simd_three_same_fp) */
    switch (key) {
        case 0x18: case 0x58: return FOP_MAXNM;
        case 0x38: case 0x78: return FOP_MINNM;
        case 0x19: return FOP_MLA;   case 0x39: return FOP_MLS;
        case 0x1a: case 0x5a: return FOP_ADD;    case 0x3a: return FOP_SUB;
        case 0x1b: return FOP_MULX;  case 0x5b: return FOP_MUL;
        case 0x1e: case 0x5e: return FOP_MAX;    case 0x3e: return FOP_MIN;
        case 0x1f: return FOP_RECPS; case 0x3f: return FOP_RSQRTS;
        case 0x5f: return FOP_DIV;   case 0x7a: return FOP_ABD;   case 0x7e: return FOP_MIN;
        default: return FOP_ADD;
    }
}
static int fp3_cmp_d(unsigned key, double x, double y) {
    switch (key) {
        case 0x1c: return fcm_test_d(FCM_EQ, x, y);   /* FCMEQ */
        case 0x5c: return fcm_test_d(FCM_GE, x, y);   /* FCMGE */
        case 0x7c: return fcm_test_d(FCM_GT, x, y);   /* FCMGT */
        case 0x5d: return fcm_test_d(FCM_GE, __builtin_fabs(x), __builtin_fabs(y)); /* FACGE */
        case 0x7d: return fcm_test_d(FCM_GT, __builtin_fabs(x), __builtin_fabs(y)); /* FACGT */
    }
    return 0;
}
static int fp3_cmp_s(unsigned key, float x, float y) {
    switch (key) {
        case 0x1c: return fcm_test_s(FCM_EQ, x, y);   /* FCMEQ */
        case 0x5c: return fcm_test_s(FCM_GE, x, y);   /* FCMGE */
        case 0x7c: return fcm_test_s(FCM_GT, x, y);   /* FCMGT */
        case 0x5d: return fcm_test_s(FCM_GE, __builtin_fabsf(x), __builtin_fabsf(y)); /* FACGE */
        case 0x7d: return fcm_test_s(FCM_GT, __builtin_fabsf(x), __builtin_fabsf(y)); /* FACGT */
    }
    return 0;
}

static void simd_scalar_three_same(CPU *c, u32 insn) {
    unsigned U = BIT(29), opc = BITS(15, 11), Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 r; r.d[0] = r.d[1] = 0;
    if (opc >= 0x18) {                               /* FP scalar three-same */
        unsigned a = BIT(23), sz = BIT(22), key = (U << 6) | (a << 5) | opc;
        int cmp = (opc == 0x1c || opc == 0x1d);
        if (sz) {
            double x = vget_d(&c->v[Rn], 0), y = vget_d(&c->v[Rm], 0);
            if (cmp) r.d[0] = fp3_cmp_d(key, x, y) ? ~0ULL : 0;
            else vset_d(&r, 0, fop_d(fp3_key_op(key), x, y, vget_d(&c->v[Rd], 0)));
        } else {
            float x = vget_s(&c->v[Rn], 0), y = vget_s(&c->v[Rm], 0);
            if (cmp) r.s[0] = fp3_cmp_s(key, x, y) ? 0xffffffffu : 0;
            else vset_s(&r, 0, fop_s(fp3_key_op(key), x, y, vget_s(&c->v[Rd], 0)));
        }
        c->v[Rd] = r; return;
    }
    unsigned size = BITS(23, 22), esize = 8u << size;
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
    u64 a = velem_get(&c->v[Rn], size, 0), b = velem_get(&c->v[Rm], size, 0), v;
    switch ((U << 5) | opc) {
        case (0 << 5) | 0x01: v = ssat_add(sx(a,esize), sx(b,esize), esize); break;   /* SQADD */
        case (1 << 5) | 0x01: v = usat_add(a & emask, b & emask, esize); break;        /* UQADD */
        case (0 << 5) | 0x05: v = ssat_sub(sx(a,esize), sx(b,esize), esize); break;   /* SQSUB */
        case (1 << 5) | 0x05: v = usat_sub(a & emask, b & emask, esize); break;        /* UQSUB */
        case (0 << 5) | 0x06: v = (sx(a,esize) >  sx(b,esize)) ? emask : 0; break;     /* CMGT */
        case (1 << 5) | 0x06: v = ((a & emask) >  (b & emask)) ? emask : 0; break;     /* CMHI */
        case (0 << 5) | 0x07: v = (sx(a,esize) >= sx(b,esize)) ? emask : 0; break;     /* CMGE */
        case (1 << 5) | 0x07: v = ((a & emask) >= (b & emask)) ? emask : 0; break;     /* CMHS */
        case (0 << 5) | 0x08: v = vreg_shift(a, (s8)(b&0xff), esize, 1, 0, 0); break;  /* SSHL */
        case (1 << 5) | 0x08: v = vreg_shift(a, (s8)(b&0xff), esize, 0, 0, 0); break;  /* USHL */
        case (0 << 5) | 0x09: v = vreg_shift(a, (s8)(b&0xff), esize, 1, 0, 1); break;  /* SQSHL */
        case (1 << 5) | 0x09: v = vreg_shift(a, (s8)(b&0xff), esize, 0, 0, 1); break;  /* UQSHL */
        case (0 << 5) | 0x0a: v = vreg_shift(a, (s8)(b&0xff), esize, 1, 1, 0); break;  /* SRSHL */
        case (1 << 5) | 0x0a: v = vreg_shift(a, (s8)(b&0xff), esize, 0, 1, 0); break;  /* URSHL */
        case (0 << 5) | 0x0b: v = vreg_shift(a, (s8)(b&0xff), esize, 1, 1, 1); break;  /* SQRSHL */
        case (1 << 5) | 0x0b: v = vreg_shift(a, (s8)(b&0xff), esize, 0, 1, 1); break;  /* UQRSHL */
        case (0 << 5) | 0x10: v = a + b; break;                                        /* ADD */
        case (1 << 5) | 0x10: v = a - b; break;                                        /* SUB */
        case (0 << 5) | 0x11: v = ((a & emask) & (b & emask)) ? emask : 0; break;       /* CMTST */
        case (1 << 5) | 0x11: v = ((a & emask) == (b & emask)) ? emask : 0; break;      /* CMEQ */
        case (0 << 5) | 0x16: { s64 p = wmul(sx(a,esize), sx(b,esize)); v = sat_s(p >> (esize-1), esize); } break;                  /* SQDMULH (overflow-safe, see three-same) */
        case (1 << 5) | 0x16: { s64 p = wadd(wmul(sx(a,esize), sx(b,esize)), (s64)1 << (esize-2)); v = sat_s(p >> (esize-1), esize); } break; /* SQRDMULH */
        default: fpsimd_undef(c, insn); return;
    }
    velem_set(&r, size, 0, v & emask); c->v[Rd] = r;
}

static void simd_scalar_pairwise(CPU *c, u32 insn) {
    unsigned U = BIT(29), opc = BITS(16, 12), Rn = BITS(9, 5), Rd = BITS(4, 0);
    V128 r; r.d[0] = r.d[1] = 0;
    if (U == 0 && opc == 0x1b) { r.d[0] = c->v[Rn].d[0] + c->v[Rn].d[1]; c->v[Rd] = r; return; } /* ADDP (d) */
    if (U == 1 && (opc == 0x0c || opc == 0x0d || opc == 0x0f)) {       /* FADDP/FMAXP/FMINP/FMAXNMP/FMINNMP */
        unsigned a = BIT(23), sz = BIT(22);
        unsigned fop = (opc == 0x0d) ? FOP_ADD : (opc == 0x0f) ? (a ? FOP_MIN : FOP_MAX) : (a ? FOP_MINNM : FOP_MAXNM);
        if (sz) vset_d(&r, 0, fop_d(fop, vget_d(&c->v[Rn], 0), vget_d(&c->v[Rn], 1), 0));
        else    vset_s(&r, 0, fop_s(fop, vget_s(&c->v[Rn], 0), vget_s(&c->v[Rn], 1), 0));
        c->v[Rd] = r; return;
    }
    fpsimd_undef(c, insn);
}

static void simd_scalar_three_diff(CPU *c, u32 insn) {
    unsigned size = BITS(23, 22), opc = BITS(15, 12), Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    unsigned esize = 8u << size;
    u64 emask = (esize >= 64) ? ~0ULL : ((1ULL << esize) - 1);   /* 16/32 allocated */
    u64 a = velem_get(&c->v[Rn], size, 0) & emask, b = velem_get(&c->v[Rm], size, 0) & emask;
    s64 pr = (s64)sqdmull_sat(sx(a, esize), sx(b, esize), 2 * esize);
    u64 d = velem_get(&c->v[Rd], size + 1, 0), v;
    V128 r; r.d[0] = r.d[1] = 0;
    switch (opc) {
        case 0xd: v = (u64)pr; break;                                        /* SQDMULL */
        case 0x9: v = ssat_add(sx(d, 2*esize), pr, 2*esize); break;          /* SQDMLAL */
        case 0xb: v = ssat_sub(sx(d, 2*esize), pr, 2*esize); break;          /* SQDMLSL */
        default: fpsimd_undef(c, insn); return;
    }
    velem_set(&r, size + 1, 0, v); c->v[Rd] = r;
}

static void simd_scalar_indexed(CPU *c, u32 insn) {
    unsigned U = BIT(29), size = BITS(23, 22), opc = BITS(15, 12);
    unsigned Rn = BITS(9, 5), Rd = BITS(4, 0), H = BIT(11), L = BIT(21), M = BIT(20);
    V128 r; r.d[0] = r.d[1] = 0;
    if (opc == 0x9 || (!U && (opc == 0x1 || opc == 0x5))) {  /* FP scalar by element (U picks FMULX at 0x9) */
        unsigned op = (opc == 0x1) ? FOP_MLA : (opc == 0x5) ? FOP_MLS : (U ? FOP_MULX : FOP_MUL);
        unsigned Rm = BITS(20, 16);
        if (size == 3)      vset_d(&r, 0, fop_d(op, vget_d(&c->v[Rn], 0), vget_d(&c->v[Rm], H), vget_d(&c->v[Rd], 0)));
        else if (size == 2) vset_s(&r, 0, fop_s(op, vget_s(&c->v[Rn], 0), vget_s(&c->v[Rm], (H<<1)|L), vget_s(&c->v[Rd], 0)));
        else { fpsimd_undef(c, insn); return; }
        c->v[Rd] = r; return;
    }
    unsigned Rm, index;
    if (size == 1)      { Rm = BITS(19, 16); index = (H << 2) | (L << 1) | M; }
    else if (size == 2) { Rm = BITS(20, 16); index = (H << 1) | L; }
    else { fpsimd_undef(c, insn); return; }
    unsigned esize = 8u << size; u64 emask = (1ULL << esize) - 1;
    u64 a = velem_get(&c->v[Rn], size, 0) & emask, e = velem_get(&c->v[Rm], size, index) & emask;
    if (!U && (opc == 0xc || opc == 0xd)) {           /* SQDMULH/SQRDMULH by element */
        s64 p = sx(a, esize) * sx(e, esize);          /* overflow-safe: a*b then >>(esize-1) */
        if (opc == 0xd) p += (s64)1 << (esize - 2);
        velem_set(&r, size, 0, sat_s(p >> (esize - 1), esize) & emask); c->v[Rd] = r; return;
    }
    if (U && (opc == 0xd || opc == 0xf)) {            /* SQRDMLAH/SQRDMLSH by element (FEAT_RDM) */
        velem_set(&r, size, 0,
                  sqrdmlah_op(sx(velem_get(&c->v[Rd], size, 0), esize),
                              sx(a, esize), sx(e, esize), esize, opc == 0xf) & emask);
        c->v[Rd] = r; return;
    }
    if (!U && (opc == 0xb || opc == 0x3 || opc == 0x7)) {  /* SQDMULL/SQDMLAL/SQDMLSL by element */
        s64 pr = (s64)sqdmull_sat(sx(a, esize), sx(e, esize), 2 * esize);
        u64 d = velem_get(&c->v[Rd], size + 1, 0), v;
        v = (opc == 0xb) ? (u64)pr : (opc == 0x3) ? ssat_add(sx(d, 2*esize), pr, 2*esize)
                                                  : ssat_sub(sx(d, 2*esize), pr, 2*esize);
        velem_set(&r, size + 1, 0, v); c->v[Rd] = r; return;
    }
    fpsimd_undef(c, insn);
}

/* AdvSIMD three-same extra (bit21=0, bit15=1, bit10=1): the v8.1+ extension
 * page — SQRDMLAH/SQRDMLSH (FEAT_RDM); SDOT/UDOT (FEAT_DotProd) and
 * FCMLA/FCADD (FEAT_FCMA) share the page. opcode = bits[14:11]. */
static void simd_three_same_extra(CPU *c, u32 insn) {
    unsigned Q = BIT(30), U = BIT(29), size = BITS(23, 22), opc = BITS(14, 11);
    unsigned Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    if (U == 1 && opc <= 1) {                        /* SQRDMLAH (0) / SQRDMLSH (1) */
        if (size != 1 && size != 2) { fpsimd_undef(c, insn); return; }
        unsigned esize = 8u << size;
        u64 emask = (1ULL << esize) - 1;
        V128 vn = c->v[Rn], vm = c->v[Rm], vd = c->v[Rd], r; r.d[0] = r.d[1] = 0;
        unsigned n = (Q ? 16u : 8u) >> size;
        for (unsigned i = 0; i < n; i++)
            velem_set(&r, size, i,
                      sqrdmlah_op(sx(velem_get(&vd, size, i), esize),
                                  sx(velem_get(&vn, size, i), esize),
                                  sx(velem_get(&vm, size, i), esize),
                                  esize, opc) & emask);
        c->v[Rd] = r; return;
    }
    if (opc == 0x2) {                                /* SDOT (U=0) / UDOT (U=1), FEAT_DotProd */
        if (size != 2) { fpsimd_undef(c, insn); return; }
        V128 vn = c->v[Rn], vm = c->v[Rm], r = c->v[Rd];
        unsigned n = Q ? 4 : 2;
        for (unsigned i = 0; i < n; i++) {           /* 4x 8-bit products per 32-bit lane, wrap mod 2^32 */
            u32 acc = r.s[i];
            for (unsigned j = 0; j < 4; j++)
                acc += U ? (u32)vn.b[4 * i + j] * vm.b[4 * i + j]
                         : (u32)((s32)(s8)vn.b[4 * i + j] * (s8)vm.b[4 * i + j]);
            r.s[i] = acc;
        }
        if (!Q) r.d[1] = 0;
        c->v[Rd] = r; return;
    }
    if (U == 1 && (opc & 0xc) == 0x8) {              /* FCMLA #(rot*90), FEAT_FCMA */
        if (size == 0 || (size == 3 && !Q)) { fpsimd_undef(c, insn); return; }
        fcmla_core(c, size, Q, Rn, Rm, Rd, opc & 3, -1); return;
    }
    if (U == 1 && (opc & 0xd) == 0xc) {              /* FCADD #90/#270, FEAT_FCMA */
        if (size == 0 || (size == 3 && !Q)) { fpsimd_undef(c, insn); return; }
        fcadd_core(c, size, Q, Rn, Rm, Rd, (opc >> 1) & 1); return;
    }
    fpsimd_undef(c, insn);
}

/* AdvSIMD scalar three-same extra: single-lane SQRDMLAH/SQRDMLSH (FEAT_RDM),
 * upper result bits zeroed like the other scalar handlers. */
static void simd_scalar_three_same_extra(CPU *c, u32 insn) {
    unsigned U = BIT(29), size = BITS(23, 22), opc = BITS(14, 11);
    unsigned Rm = BITS(20, 16), Rn = BITS(9, 5), Rd = BITS(4, 0);
    if (U != 1 || opc > 1 || (size != 1 && size != 2)) { fpsimd_undef(c, insn); return; }
    unsigned esize = 8u << size;
    u64 emask = (1ULL << esize) - 1;
    V128 r; r.d[0] = r.d[1] = 0;
    velem_set(&r, size, 0,
              sqrdmlah_op(sx(velem_get(&c->v[Rd], size, 0), esize),
                          sx(velem_get(&c->v[Rn], size, 0), esize),
                          sx(velem_get(&c->v[Rm], size, 0), esize),
                          esize, opc) & emask);
    c->v[Rd] = r;
}

void exec_fpsimd(CPU *c, u32 insn) {
    fp_cpu=c;
    /* Scalar floating-point (bit30=0 distinguishes from scalar AdvSIMD). */
    if ((insn & 0x7f000000) == 0x1e000000) { exec_fp_scalar(c, insn); return; }
    if ((insn & 0x7f000000) == 0x1f000000) { exec_fp_dp3(c, insn);    return; }

    /* AdvSIMD across-lanes reductions (ADDV/UMAXV/UMINV/...): bits[11:10]=10. */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BITS(21, 17) == 0x18 && BIT(11) == 1 && BIT(10) == 0) {
        simd_across(c, insn); return;
    }
    /* AdvSIMD two-register misc (NOT/NEG/ABS/compare-with-zero): bits[11:10]=10. */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BITS(21, 17) == 0x10 && BIT(11) == 1 && BIT(10) == 0) {
        simd_two_misc(c, insn); return;
    }
    /* AdvSIMD two-register misc (FP16): FABS/FNEG/FSQRT, FRINTx, FCVT-to-int,
     * SCVTF/UCVTF, FCMxx #0, FRECPE/FRSQRTE on .4h/.8h. Its own encoding page
     * (bit22=1, bits[21:17]=0x1c). */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(22) == 1 && BITS(21, 17) == 0x1c &&
        BIT(11) == 1 && BIT(10) == 0) {
        simd_two_misc_fp16(c, insn); return;
    }
    /* AdvSIMD scalar two-register misc (bit30=1): scalar int<->FP converts. */
    if (BITS(28, 24) == 0x1e && BITS(21, 17) == 0x10 && BIT(11) == 1 && BIT(10) == 0) {
        simd_scalar_cvt(c, insn); return;
    }
    /* AdvSIMD scalar two-register misc (FP16): the Hd,Hn half forms (own page,
     * bit22=1, bits[21:17]=0x1c). */
    if (BITS(28, 24) == 0x1e && BIT(22) == 1 && BITS(21, 17) == 0x1c && BIT(11) == 1 && BIT(10) == 0) {
        simd_scalar_cvt_fp16(c, insn); return;
    }
    /* Cryptographic AES (AESE/AESD/AESMC/AESIMC). */
    if (BITS(31, 24) == 0x4e && BITS(23, 22) == 0 && BITS(21, 17) == 0x14 && BITS(11, 10) == 2) {
        crypto_aes(c, insn); return;
    }
    /* Cryptographic 3-register SHA (SHA1C/P/M/SU0, SHA256H/H2/SU1). bits[11:10]=0
     * distinguishes these from AdvSIMD scalar copy (DUP), which has bit10=1. */
    if (BITS(31, 24) == 0x5e && BITS(23, 21) == 0 && BIT(15) == 0 && BITS(11, 10) == 0) {
        crypto_sha3(c, insn); return;
    }
    /* Cryptographic 2-register SHA (SHA1H/SHA1SU1/SHA256SU0). */
    if (BITS(31, 24) == 0x5e && BITS(23, 22) == 0 && BITS(21, 17) == 0x14 && BITS(11, 10) == 2) {
        crypto_sha2(c, insn); return;
    }
    /* AdvSIMD three-different PMULL/PMULL2 (opcode 0b1110, U=0). */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(29) == 0 && BIT(21) == 1 &&
        BITS(15, 12) == 0xe && BITS(11, 10) == 0) {
        crypto_pmull(c, insn); return;
    }
    /* ARMv8.2 crypto extensions (FEAT_SHA3 EOR3/BCAX/RAX1/XAR, FEAT_SHA512
     * H/H2/SU0/SU1). Nothing else decodes the 0xce top byte. */
    if (BITS(31, 24) == 0xce) { crypto_sha3_512(c, insn); return; }
    /* Scalar Advanced SIMD (after crypto, which shares 0x5e). Scalar two-misc is
     * handled by simd_scalar_cvt above; the rest dispatch here. */
    if (BITS(28, 24) == 0x1e) {
        if (BIT(21) == 1 && BIT(10) == 1)                          { simd_scalar_three_same(c, insn); return; }
        if (BIT(21) == 1 && BITS(11, 10) == 0)                     { simd_scalar_three_diff(c, insn); return; }
        if (BITS(21, 17) == 0x18 && BIT(11) == 1 && BIT(10) == 0)  { simd_scalar_pairwise(c, insn); return; }
        if (BIT(21) == 0 && BIT(15) == 1 && BIT(10) == 1)          { simd_scalar_three_same_extra(c, insn); return; }
    }
    if (BITS(28, 24) == 0x1f && BIT(10) == 0) { simd_scalar_indexed(c, insn); return; }
    /* AdvSIMD three-different (whole group: ADDL/SUBL/ADDW/SUBW/ADDHN/SUBHN/
     * ABAL/ABDL/MULL/MLAL/MLSL/SQDMULL/SQDMLAL/SQDMLSL). PMULL (opcode 0xe) is
     * decoded above; everything else with bits[11:10]=0, bit21=1 lands here. */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(21) == 1 && BITS(11, 10) == 0 &&
        BITS(15, 12) != 0xe) {
        simd_three_diff(c, insn); return;
    }
    /* AdvSIMD TBL/TBX (table vector lookup). */
    if (BIT(31) == 0 && BIT(29) == 0 && BITS(28, 24) == 0x0e && BITS(23, 21) == 0 &&
        BIT(15) == 0 && BITS(11, 10) == 0) {
        simd_tbl(c, insn); return;
    }
    /* AdvSIMD EXT (byte extract from concatenated pair). Only bit10 is fixed 0;
     * bit11 is imm4<0>, so guarding BITS(11,10)==0 would drop odd indices. */
    if (BIT(31) == 0 && BIT(29) == 1 && BITS(28, 24) == 0x0e &&
        BITS(23, 22) == 0 && BIT(21) == 0 && BIT(15) == 0 && BIT(10) == 0) {
        simd_ext(c, insn); return;
    }
    /* AdvSIMD permute (ZIP/UZP/TRN). */
    if (BIT(31) == 0 && BIT(29) == 0 && BITS(28, 24) == 0x0e && BIT(21) == 0 &&
        BIT(15) == 0 && BITS(11, 10) == 2) {
        simd_permute(c, insn); return;
    }
    /* AdvSIMD three-same (FP16): FADD/FMUL/FMLA/FMAX/FCMEQ/... on .4h/.8h. Its own
     * encoding page (bit22=1, bit21=0, bits[15:14]=0), distinct from the s/d form. */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(22) == 1 && BIT(21) == 0 &&
        BITS(15, 14) == 0 && BIT(10) == 1) {
        simd_three_same_fp16(c, insn); return;
    }
    /* AdvSIMD three-same extra (v8.1+ RDM/DotProd/FCMA page). */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(21) == 0 && BIT(15) == 1 && BIT(10) == 1) {
        simd_three_same_extra(c, insn); return;
    }
    /* AdvSIMD three-same (vector integer): ADD/SUB/CMP/MIN/MAX/MUL/logical. */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0e && BIT(21) == 1 && BIT(10) == 1) {
        simd_three_same(c, insn); return;
    }

    /* Advanced SIMD modified immediate (MOVI/MVNI/ORR/BIC/FMOV vector imm). */
    if (BIT(31) == 0 && BITS(28, 19) == 0x1e0 && BIT(10) == 1) { simd_modified_imm(c, insn); return; }
    /* AdvSIMD shift by immediate (SHL/SSHR/USHR/SSHLL/USHLL): immh != 0. */
    if (BIT(31) == 0 && BITS(28, 23) == 0x1e && BIT(10) == 1 && BITS(22, 19) != 0) {
        simd_shift_imm(c, insn); return;
    }
    /* AdvSIMD scalar shift by immediate (bit30=1): D-form SHL/SSHR/USHR. */
    if (BITS(28, 23) == 0x3e && BIT(10) == 1 && BITS(22, 19) != 0) { simd_scalar_shift(c, insn); return; }
    /* AdvSIMD copy (DUP/INS/UMOV/SMOV). */
    if (BIT(31) == 0 && BITS(28, 21) == 0x70 && BIT(15) == 0 && BIT(10) == 1) {
        simd_copy(c, insn); return;
    }
    /* AdvSIMD scalar copy (DUP element -> scalar: MOV Dd, Vn.D[i], etc.). */
    if (BITS(31, 21) == 0x2f0 && BIT(15) == 0 && BITS(14, 11) == 0 && BIT(10) == 1) {
        simd_scalar_copy(c, insn); return;
    }
    /* AdvSIMD vector x indexed element (integer multiply-by-element group). */
    if (BIT(31) == 0 && BITS(28, 24) == 0x0f && BIT(10) == 0) {
        simd_indexed(c, insn); return;
    }

    fpsimd_undef(c, insn);
}

/* Used only at a lifecycle boundary under a saved caller floating environment. */
void ae_fp_reset_pending(CPU *c) { fp_cpu=c;g_fpexc=0;feclearexcept(FE_ALL_EXCEPT); }
void ae_fp_unbind(void) { fp_cpu=NULL; }
void ae_fp_unbind_cpu(const CPU *c) { if(fp_cpu==c)fp_cpu=NULL; }

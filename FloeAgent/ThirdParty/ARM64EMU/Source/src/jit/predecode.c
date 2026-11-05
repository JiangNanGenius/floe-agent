/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* Pre-decode classifier: turn one instruction word into a PDEnt (dense
 * opcode id + pre-extracted operands). Runs at JIT translation time.
 *
 * The classification mirrors decode.c's tree for the covered forms and is
 * deliberately conservative: any encoding not recognized with certainty
 * (including architecturally-unallocated patterns decode.c happens to accept
 * leniently) is left as PD_GENERIC, which the translator turns into a call
 * back into exec_a64 — so behavior for those stays byte-identical by
 * construction. Ported from arm64chroot; deviations marked "coverage:".
 *
 * This file also carries pd_run/pd_step: the opt-in `-pd` direct-threaded
 * interpreter tier (a computed-goto executor over the per-hart PD cache), kept in its own
 * TU so it never perturbs decode.c's codegen. */
#include <stdlib.h>

#include "predecode.h"
#include <string.h>
#define AE_PD_GUARD_SLOT_PRIVATE 1
#include "../mmu.h"
#include "../machine.h"
#include "../parallel_iface.h"

#ifndef UNLIKELY
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif

#define BIT(i)      ((insn >> (i)) & 1u)
#define BITS(hi,lo) ((insn >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1))

/* Duplicated from decode.c (which must stay unmodified). */
static bool pd_bitmasks(unsigned immN, unsigned imms, unsigned immr,
                        bool is64, u64 *wmask) {
    unsigned width = is64 ? 64 : 32;
    u32 nimms = ((immN & 1) << 6) | ((~imms) & 0x3f);
    if (nimms == 0) return false;
    int len = 31 - __builtin_clz(nimms);
    if (len < 1) return false;
    if ((1u << len) > width) return false;
    unsigned levels = (1u << len) - 1;
    unsigned S = imms & levels;
    unsigned R = immr & levels;
    unsigned esize = 1u << len;
    u64 welem = ones(S + 1);
    u64 emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
    welem &= emask;
    unsigned r = R % esize;
    u64 w = r ? (((welem >> r) | (welem << (esize - r))) & emask) : welem;
    u64 wm = 0;
    for (unsigned i = 0; i < 64; i += esize) wm |= w << i;
    if (!is64) wm = (u32)wm;
    *wmask = wm;
    return true;
}

/* ---- DP immediate (top groups 0x8/0x9) ---- */
static void fill_dp_imm(PDEnt *e, u32 insn) {
    unsigned t = BITS(28, 23);
    bool sf = BIT(31);

    if (t == 0x20 || t == 0x21) {                    /* ADR / ADRP */
        u32 immlo = BITS(30, 29), immhi = BITS(23, 5);
        s64 imm = (s64)sign_extend(((u64)immhi << 2) | immlo, 21);
        if (!sf) { e->op = PD_ADR; e->imm = (u64)imm; }
        else { e->op = PD_ADRP; e->imm = (u64)imm << 12; }
        return;
    }
    if (t == 0x22) {                                 /* add/sub immediate */
        bool op = BIT(30), S = BIT(29), sh = BIT(22);
        u64 imm = BITS(21, 10);
        if (sh) imm <<= 12;
        if (S) {
            e->op = op ? (sf ? PD_SUBS64I : PD_SUBS32I)
                       : (sf ? PD_ADDS64I : PD_ADDS32I);
            e->imm = op ? ~imm : imm;   /* SUBS: pre-inverted for add-with-carry */
        } else {
            e->op = op ? (sf ? PD_SUB64I : PD_SUB32I)
                       : (sf ? PD_ADD64I : PD_ADD32I);
            e->imm = imm;
        }
        return;
    }
    if (t == 0x24) {                                 /* logical immediate */
        unsigned opc = BITS(30, 29), N = BIT(22), immr = BITS(21, 16), imms = BITS(15, 10);
        u64 wmask;
        if (!pd_bitmasks(N, imms, immr, sf, &wmask)) return;   /* GENERIC */
        static const u8 ids[4][2] = {
            { PD_AND32I, PD_AND64I }, { PD_ORR32I, PD_ORR64I },
            { PD_EOR32I, PD_EOR64I }, { PD_ANDS32I, PD_ANDS64I },
        };
        e->op = ids[opc][sf];
        e->imm = wmask;
        return;
    }
    if (t == 0x25) {                                 /* move wide */
        unsigned opc = BITS(30, 29), hw = BITS(22, 21), imm16 = BITS(20, 5);
        unsigned shift = hw * 16;
        if (!sf && hw >= 2) return;                  /* 32-bit: hw in {0,1} only */
        if (opc == 0) {                              /* MOVN: precompute */
            u64 r = ~((u64)imm16 << shift);
            e->op = PD_MOVI; e->imm = sf ? r : (u32)r;
        } else if (opc == 2) {                       /* MOVZ: precompute */
            u64 r = (u64)imm16 << shift;
            e->op = PD_MOVI; e->imm = sf ? r : (u32)r;
        } else if (opc == 3) {                       /* MOVK */
            e->op = sf ? PD_MOVK64 : PD_MOVK32;
            e->rm = (u8)shift;
            e->imm = (u64)imm16 << shift;
        }
        return;
    }
    if (t == 0x26) {                                 /* bitfield aliases only */
        unsigned opc = BITS(30, 29), N = BIT(22), immr = BITS(21, 16), imms = BITS(15, 10);
        unsigned width = sf ? 64 : 32;
        if (sf ? (N != 1) : (N != 0 || immr >= 32 || imms >= 32)) return;
        if (opc == 2) {                              /* UBFM */
            if (imms == width - 1) {                 /* LSR */
                e->op = sf ? PD_LSR64I : PD_LSR32I; e->rm = (u8)immr;
            } else if (immr == imms + 1) {           /* LSL */
                e->op = sf ? PD_LSL64I : PD_LSL32I; e->rm = (u8)(width - 1 - imms);
            } else if (imms >= immr) {               /* UBFX / UXTB / UXTH */
                e->op = sf ? PD_UBFX64 : PD_UBFX32;
                e->rm = (u8)immr; e->imm = ones(imms - immr + 1);
            } else {                                 /* UBFIZ */
                e->op = sf ? PD_UBFIZ64 : PD_UBFIZ32;
                e->rm = (u8)(width - immr); e->imm = ones(imms + 1);
            }
        } else if (opc == 0) {                       /* SBFM */
            if (imms == width - 1) {                 /* ASR */
                e->op = sf ? PD_ASR64I : PD_ASR32I; e->rm = (u8)immr;
            } else if (imms >= immr) {               /* SBFX / SXTB / SXTH / SXTW */
                e->op = sf ? PD_SBFX64 : PD_SBFX32;
                e->rm = (u8)(width - 1 - imms);
                e->imm = (u64)(width - 1 - imms + immr);
            }
            /* SBFIZ: GENERIC */
        }
        /* BFM/BFI/BFXIL: GENERIC */
        return;
    }
    if (t == 0x27) {                                 /* EXTR / ROR imm */
        unsigned imms = BITS(15, 10);
        /* bits[30:29] are RES0, N (bit22) must equal sf, bit21 must be 0. */
        if (BITS(30, 29) != 0 || BIT(22) != (unsigned)(sf != 0) || BIT(21) != 0) return;
        if (sf) { e->op = PD_EXTR64; e->imm = imms; }
        else if (imms < 32) { e->op = PD_EXTR32; e->imm = imms; }
        return;
    }
}

/* ---- branches / system (top groups 0xa/0xb) ---- */
static void fill_branch(PDEnt *e, u32 insn) {
    unsigned top6 = BITS(31, 26);

    if (top6 == 0x05) {
        e->op = PD_B;
        e->imm = (sign_extend(BITS(25, 0), 26) << 2);
        return;
    }
    if (top6 == 0x25) {
        e->op = PD_BL;
        e->imm = (sign_extend(BITS(25, 0), 26) << 2);
        return;
    }
    if (BITS(31, 24) == 0x54 && BIT(4) == 0) {       /* B.cond */
        e->op = PD_BCOND;
        e->rd = (u8)BITS(3, 0);
        e->imm = (sign_extend(BITS(23, 5), 19) << 2);
        return;
    }
    if (BITS(30, 25) == 0x1a) {                      /* CBZ/CBNZ */
        bool sf = BIT(31), op = BIT(24);
        e->op = op ? (sf ? PD_CBNZ64 : PD_CBNZ32) : (sf ? PD_CBZ64 : PD_CBZ32);
        e->imm = (sign_extend(BITS(23, 5), 19) << 2);
        return;
    }
    if (BITS(30, 25) == 0x1b) {                      /* TBZ/TBNZ */
        e->op = BIT(24) ? PD_TBNZ : PD_TBZ;
        e->rm = (u8)((BIT(31) << 5) | BITS(23, 19));
        e->imm = (sign_extend(BITS(18, 5), 14) << 2);
        return;
    }
    if (BITS(31, 25) == 0x6b) {                      /* BR/BLR/RET */
        unsigned opc = BITS(24, 21);
        if (opc == 0 || opc == 2) e->op = PD_BR;     /* BR and RET: pc = Xn */
        else if (opc == 1) e->op = PD_BLR;
        return;
    }
    if (BITS(31, 24) == 0xd5) {                      /* hints: NOP and friends */
        unsigned L = BIT(21), op0 = BITS(20, 19), op1 = BITS(18, 16);
        unsigned CRn = BITS(15, 12), CRm = BITS(11, 8), op2 = BITS(7, 5), Rt = BITS(4, 0);
        if (L == 0 && op0 == 0 && op1 == 3 && CRn == 2 && Rt == 31 &&
            !(CRm == 0 && op2>=2 && op2<=5))       /* WFE/WFI/SEV/SEVL stay GENERIC */
            e->op = PD_NOP;
        return;
    }
}

/* ---- loads/stores (top groups 0x4/0x6/0xc/0xe) ---- */

/* Integer single register: id for (size, opc), or 0 if not covered. */
static u8 ldst_int_id(unsigned size, unsigned opc) {
    switch ((size << 2) | opc) {
        case 0x0: return PD_STRB;    case 0x1: return PD_LDRB;
        case 0x2: return PD_LDRSB64; case 0x3: return PD_LDRSB32;
        case 0x4: return PD_STRH;    case 0x5: return PD_LDRH;
        case 0x6: return PD_LDRSH64; case 0x7: return PD_LDRSH32;
        case 0x8: return PD_STR32U;  case 0x9: return PD_LDR32U;
        case 0xa: return PD_LDRSW;
        case 0xc: return PD_STR64U;  case 0xd: return PD_LDR64U;
        case 0xe: return PD_NOP;     /* PRFM: no access, no register write */
        default:  return 0;
    }
}

static void fill_ldst(PDEnt *e, u32 insn) {
    unsigned b2927 = BITS(29, 27);

    if (b2927 == 0x3 && BITS(25, 24) == 0) {         /* literal */
        unsigned opc = BITS(31, 30);
        if (BIT(26)) {                               /* SIMD&FP: LDR St/Dt/Qt */
            if (opc == 3) return;                    /* UNALLOCATED -> GENERIC -> UNDEF */
            e->op  = PD_LDRLITV;
            e->rm  = (u8)(4u << opc);                /* byte count 4/8/16 */
            e->imm = (sign_extend(BITS(23, 5), 19) << 2);
            return;
        }
        if (opc == 0) e->op = PD_LDRLIT32;
        else if (opc == 1) e->op = PD_LDRLIT64;
        else if (opc == 3) e->op = PD_NOP;           /* PRFM literal */
        e->imm = (sign_extend(BITS(23, 5), 19) << 2);
        return;
    }

    if (b2927 == 0x5) {                              /* pairs */
        unsigned opc = BITS(31, 30), mode = BITS(25, 23);
        bool V = BIT(26), L = BIT(22);
        if (mode > 3) return;
        /* mode: 0 = STNP/LDNP (plain offset), 1 = post, 2 = offset, 3 = pre */
        unsigned kind = (mode == 1) ? 2 : (mode == 3) ? 1 : 0;  /* 0 off, 1 pre, 2 post */
        unsigned scale;
        u8 base_id;
        if (V) {
            if (opc == 2)      { scale = 4; base_id = L ? PD_LDPQ : PD_STPQ; }
            else if (opc == 1) { scale = 3; base_id = L ? PD_LDPD : PD_STPD; }
            else return;                             /* S pairs / opc==3: GENERIC */
        } else {
            if (opc == 2)      { scale = 3; base_id = L ? PD_LDP64 : PD_STP64; }
            else if (opc == 0) { scale = 2; base_id = L ? PD_LDP32 : PD_STP32; }
            else return;                             /* LDPSW / opc==3: GENERIC */
        }
        e->op = (u8)(base_id + kind);                /* relies on OFF,PRE,POST id order */
        e->rm = (u8)BITS(14, 10);                    /* Rt2 */
        e->imm = (sign_extend(BITS(21, 15), 7) << scale);
        return;
    }

    if (b2927 == 0x7) {                              /* single register */
        unsigned size = BITS(31, 30), opc = BITS(23, 22);
        bool V = BIT(26);

        if (BIT(24)) {                               /* unsigned immediate offset */
            if (V) {
                if (opc & 2) {                       /* Q form (requires size 0) */
                    if (size != 0) return;
                    e->op = (opc & 1) ? PD_LDRQ : PD_STRQ;
                    e->imm = (u64)BITS(21, 10) << 4;
                } else {
                    e->op = (opc & 1) ? PD_LDRV : PD_STRV;
                    e->rm = (u8)(1u << size);
                    e->imm = (u64)BITS(21, 10) << size;
                }
            } else {
                u8 id = ldst_int_id(size, opc);
                if (!id) return;
                e->op = id;
                e->imm = (u64)BITS(21, 10) << size;
            }
            return;
        }
        if (BIT(21)) {                               /* register offset (or atomics) */
            if (BITS(11, 10) != 2 || V) return;      /* atomics/other: GENERIC */
            u8 id;
            switch ((size << 2) | opc) {
                case 0x0: id = PD_STRBRO;  break; case 0x1: id = PD_LDRBRO;  break;
                case 0x4: id = PD_STRHRO;  break; case 0x5: id = PD_LDRHRO;  break;
                case 0x8: id = PD_STR32RO; break; case 0x9: id = PD_LDR32RO; break;
                case 0xc: id = PD_STR64RO; break; case 0xd: id = PD_LDR64RO; break;
                default: return;                     /* LDRS* reg-offset: GENERIC */
            }
            e->op = id;
            e->imm = (u64)(BITS(15, 13) << 3) | (BIT(12) ? size : 0);
            return;
        }
        {                                            /* imm9 addressing modes */
            unsigned mode = BITS(11, 10);
            u64 imm9 = (u64)(s64)sign_extend(BITS(20, 12), 9);
            if (mode == 2) return;                   /* LDTR/STTR: unprivileged EL0-
                                                      * view access (or UNDEF for the
                                                      * V forms) -> GENERIC, decode.c
                                                      * has the semantics */
            if (mode == 0) {                         /* LDUR/STUR: plain */
                if (V) {
                    if (opc & 2) {
                        if (size != 0) return;
                        e->op = (opc & 1) ? PD_LDRQ : PD_STRQ;
                    } else {
                        e->op = (opc & 1) ? PD_LDRV : PD_STRV;
                        e->rm = (u8)(1u << size);
                    }
                } else {
                    u8 id = ldst_int_id(size, opc);
                    if (!id) return;
                    e->op = id;
                }
                e->imm = imm9;
                return;
            }
            /* mode 1 = post-index, mode 3 = pre-index (writeback) */
            bool post = (mode == 1);
            if (V) {
                if ((opc & 2) && size == 0) {        /* Q with writeback */
                    e->op = (opc & 1) ? (post ? PD_LDRQPOST : PD_LDRQPRE)
                                      : (post ? PD_STRQPOST : PD_STRQPRE);
                    e->imm = imm9;
                }
                return;
            }
            if (size == 3 && opc == 1) e->op = post ? PD_LDR64POST : PD_LDR64PRE;
            else if (size == 3 && opc == 0) e->op = post ? PD_STR64POST : PD_STR64PRE;
            else if (size == 2 && opc == 1) e->op = post ? PD_LDR32POST : PD_LDR32PRE;
            else if (size == 2 && opc == 0) e->op = post ? PD_STR32POST : PD_STR32PRE;
            else if (size == 0 && opc == 1 && post) e->op = PD_LDRBPOST;
            else if (size == 0 && opc == 0 && post) e->op = PD_STRBPOST;
            else return;
            e->imm = imm9;
            return;
        }
    }
    /* exclusives, LSE atomics, vector structure loads: GENERIC */
}

/* ---- DP register (top groups 0x5/0xd) ---- */
static void fill_dp_reg(PDEnt *e, u32 insn) {
    bool sf = BIT(31);
    unsigned op24 = BITS(28, 24);

    if (op24 == 0x0a) {                              /* logical shifted register */
        unsigned opc = BITS(30, 29), shift = BITS(23, 22), N = BIT(21), imm6 = BITS(15, 10);
        if (!sf && imm6 >= 32) return;
        if (shift == 0 && imm6 == 0) {
            static const u8 ids[4][2][2] = {         /* [opc][N][sf] */
                { { PD_AND32,  PD_AND64  }, { PD_BIC32,  PD_BIC64  } },
                { { PD_ORR32,  PD_ORR64  }, { PD_ORN32,  PD_ORN64  } },
                { { PD_EOR32,  PD_EOR64  }, { PD_EON32,  PD_EON64  } },
                { { PD_ANDS32, PD_ANDS64 }, { PD_BICS32, PD_BICS64 } },
            };
            e->op = ids[opc][N][sf];
        } else {
            static const u8 ids[4][2] = {            /* [opc][sf] */
                { PD_AND32S, PD_AND64S }, { PD_ORR32S, PD_ORR64S },
                { PD_EOR32S, PD_EOR64S }, { PD_ANDS32S, PD_ANDS64S },
            };
            e->op = ids[opc][sf];
            e->imm = ((u64)N << 8) | (shift << 6) | imm6;
        }
        return;
    }
    if (op24 == 0x0b) {                              /* add/sub register */
        bool op = BIT(30), S = BIT(29);
        if (BIT(21)) {                               /* extended register */
            /* shift amount 5-7, and a nonzero opt (bits[23:22]): unallocated */
            if (BITS(12, 10) > 4 || BITS(23, 22) != 0) return;
            static const u8 ids[2][2][2] = {         /* [op][S][sf] */
                { { PD_ADDX32, PD_ADDX64 }, { PD_ADDSX32, PD_ADDSX64 } },
                { { PD_SUBX32, PD_SUBX64 }, { PD_SUBSX32, PD_SUBSX64 } },
            };
            e->op = ids[op][S][sf];
            e->imm = (BITS(15, 13) << 3) | BITS(12, 10);
        } else {                                     /* shifted register */
            unsigned shift = BITS(23, 22), imm6 = BITS(15, 10);
            if (shift == 3) return;                  /* ROR: unallocated here */
            if (!sf && imm6 >= 32) return;
            if (shift == 0 && imm6 == 0) {
                static const u8 ids[2][2][2] = {     /* [op][S][sf] */
                    { { PD_ADD32R, PD_ADD64R }, { PD_ADDS32R, PD_ADDS64R } },
                    { { PD_SUB32R, PD_SUB64R }, { PD_SUBS32R, PD_SUBS64R } },
                };
                e->op = ids[op][S][sf];
            } else {
                static const u8 ids[2][2][2] = {
                    { { PD_ADD32RS, PD_ADD64RS }, { PD_ADDS32RS, PD_ADDS64RS } },
                    { { PD_SUB32RS, PD_SUB64RS }, { PD_SUBS32RS, PD_SUBS64RS } },
                };
                e->op = ids[op][S][sf];
                e->imm = (shift << 6) | imm6;
            }
        }
        return;
    }
    if (op24 == 0x1b) {                              /* 3-source */
        unsigned key = (BITS(23, 21) << 1) | BIT(15);
        if (BITS(30, 29) != 0) return;               /* op54 is RES0 */
        e->imm = BITS(14, 10);                       /* Ra */
        switch (key) {
            case 0x0: e->op = sf ? PD_MADD64 : PD_MADD32; break;
            case 0x1: e->op = sf ? PD_MSUB64 : PD_MSUB32; break;
            case 0x2: if (sf) e->op = PD_SMADDL; break;
            case 0x3: if (sf) e->op = PD_SMSUBL; break;
            case 0x4: if (sf) e->op = PD_SMULH; break;
            case 0xa: if (sf) e->op = PD_UMADDL; break;
            case 0xb: if (sf) e->op = PD_UMSUBL; break;
            case 0xc: if (sf) e->op = PD_UMULH; break;
            default: break;
        }
        if (e->op == PD_GENERIC) e->imm = 0;
        return;
    }
    if (op24 == 0x1a) {
        unsigned op21 = BITS(28, 21);
        if (op21 == 0xd2) {                          /* CCMP/CCMN */
            if (!BIT(29) || BIT(10) || BIT(4)) return;   /* S must be 1; o2/o3 RES0 */
            bool op = BIT(30), is_imm = BIT(11);
            unsigned nzcv = BITS(3, 0);
            u32 flags = ((nzcv & 8) ? PS_N : 0) | ((nzcv & 4) ? PS_Z : 0) |
                        ((nzcv & 2) ? PS_C : 0) | ((nzcv & 1) ? PS_V : 0);
            static const u8 ids[2][2][2] = {         /* [op][is_imm][sf] */
                { { PD_CCMN32R, PD_CCMN64R }, { PD_CCMN32I, PD_CCMN64I } },
                { { PD_CCMP32R, PD_CCMP64R }, { PD_CCMP32I, PD_CCMP64I } },
            };
            e->op = ids[op][is_imm][sf];
            e->imm = BITS(15, 12) | ((u64)BITS(20, 16) << 8) | ((u64)flags << 32);
            return;
        }
        if (op21 == 0xd4) {                          /* CSEL family */
            if (BIT(29) || BIT(11)) return;          /* S must be 0; bit11 RES0 */
            bool op = BIT(30), o2 = BIT(10);
            static const u8 ids[2][2][2] = {         /* [op][o2][sf] */
                { { PD_CSEL32, PD_CSEL64 }, { PD_CSINC32, PD_CSINC64 } },
                { { PD_CSINV32, PD_CSINV64 }, { PD_CSNEG32, PD_CSNEG64 } },
            };
            e->op = ids[op][o2][sf];
            e->imm = BITS(15, 12);                   /* cond */
            return;
        }
        if (op21 == 0xd6) {
            unsigned opcode = BITS(15, 10);
            if (BIT(30)) {                           /* 1-source (hot subset) */
                if (opcode == 0x02 && !sf) e->op = PD_REVW;
                else if (opcode == 0x03 && sf) e->op = PD_REV64;
                else if (opcode == 0x04) e->op = sf ? PD_CLZ64 : PD_CLZ32;
            } else {                                 /* 2-source */
                switch (opcode) {
                    case 0x02: e->op = sf ? PD_UDIV64 : PD_UDIV32; break;
                    case 0x03: e->op = sf ? PD_SDIV64 : PD_SDIV32; break;
                    case 0x08: e->op = sf ? PD_LSLV64 : PD_LSLV32; break;
                    case 0x09: e->op = sf ? PD_LSRV64 : PD_LSRV32; break;
                    case 0x0a: e->op = sf ? PD_ASRV64 : PD_ASRV32; break;
                    case 0x0b: e->op = sf ? PD_RORV64 : PD_RORV32; break;
                    default: break;                  /* CRC32: GENERIC */
                }
            }
            return;
        }
        /* ADC/SBC (0xd0): GENERIC */
    }
}

void pd_fill(PDEnt *e, u32 insn) {
    e->insn = insn;
    e->op = PD_GENERIC;
    e->rd = (u8)(insn & 31);
    e->rn = (u8)((insn >> 5) & 31);
    e->rm = (u8)((insn >> 16) & 31);
    e->imm = 0;
    switch ((insn >> 25) & 0xf) {
        case 0x8: case 0x9: fill_dp_imm(e, insn); break;
        case 0xa: case 0xb: fill_branch(e, insn); break;
        case 0x4: case 0x6: case 0xc: case 0xe: fill_ldst(e, insn); break;
        case 0x5: case 0xd: fill_dp_reg(e, insn); break;
        default: break;
    }
}

/* The tier retains a live SP guard rather than demoting every stack access.
 * Only an aligned SP uses the already-validated native memory handlers. A
 * misaligned SP still executes the original decoder, preserving SA/SA0 and
 * FP-access exception ordering. Literal loads do not use SP.
 * rn is otherwise always 31 for this tier-only entry, so it can save the old
 * opcode without widening PDEnt or retaining a CPU/stack snapshot. */
static void pd_fill_tier(PDEnt *e, u32 insn) {
    pd_fill(e, insn);
    if (e->rn == 31 && e->op >= PD_LDR64U && e->op <= PD_STPDPOST &&
        e->op != PD_LDRLIT64 && e->op != PD_LDRLIT32 && e->op != PD_LDRLITV) {
        e->rn = e->op;
        e->op = PD_SP_ALIGNED;
    }
}

/* ================= -pd interpreter tier ================= */

/* ---- helpers transcribed from decode.c (which must stay unmodified) ---- */

static inline u64 pd_awc(u64 x, u64 y, int cin, bool is64, u32 *flags) {
    u64 res;
    u32 N, Z, C, V;
    if (is64) {
        u64 t = x + y;
        res = t + (unsigned)cin;
        C = (t < x) | (res < t);
        V = (u32)((~(x ^ y) & (x ^ res)) >> 63);
        N = (u32)(res >> 63);
        Z = (res == 0);
    } else {
        u32 xx = (u32)x, yy = (u32)y;
        u64 u = (u64)xx + (u64)yy + (unsigned)cin;
        res = (u32)u;
        C = (u32)((u >> 32) & 1);
        s64 s = (s64)(s32)xx + (s64)(s32)yy + cin;
        V = ((s64)(s32)(u32)res != s);
        N = (u32)((u32)res >> 31);
        Z = ((u32)res == 0);
    }
    *flags = (N ? PS_N : 0) | (Z ? PS_Z : 0) | (C ? PS_C : 0) | (V ? PS_V : 0);
    return res;
}

static inline void pd_logical_flags(CPU *c, u64 res, bool is64) {
    u32 f = 0;
    if (is64) { if (res >> 63) f |= PS_N; if (res == 0) f |= PS_Z; }
    else { u32 r = (u32)res; if (r >> 31) f |= PS_N; if (r == 0) f |= PS_Z; }
    c->nzcv = f;   /* C=V=0 */
}

static inline u64 pd_shift_reg(u64 v, unsigned type, unsigned amount, bool is64) {
    unsigned w = is64 ? 64 : 32;
    amount &= (w - 1);
    if (!is64) v = (u32)v;
    switch (type) {
        case 0: return v << amount;
        case 1: return is64 ? (v >> amount) : ((u32)v >> amount);
        case 2: return is64 ? (u64)((s64)v >> amount)
                            : (u64)(u32)((s32)(u32)v >> amount);
        default: return is64 ? ror64(v, amount) : ror32((u32)v, amount);
    }
}

static inline u64 pd_extend_reg(u64 v, unsigned option, unsigned shift) {
    u64 out;
    switch (option & 0x3) {
        case 0: out = (u8)v;  break;
        case 1: out = (u16)v; break;
        case 2: out = (u32)v; break;
        default: out = v;     break;
    }
    if (option & 0x4) {
        unsigned bits = (option & 3) == 0 ? 8 : (option & 3) == 1 ? 16 : (option & 3) == 2 ? 32 : 64;
        out = sign_extend(out, bits);
    }
    return out << shift;
}

/* Direct-threaded execution over the per-hart PD cache. Runs a slice of up to `slice`
 * instructions and returns to the driver on a rare event (deadline, IRQ/FIQ
 * line, halt/stop, or a fetch abort). Mirrors jit_step's contract; the
 * handler bodies are transcribed from decode.c/exec_a64 (arm64chroot pd_run),
 * and anything pd_fill leaves PD_GENERIC runs through exec_a64 (L_GENERIC),
 * so behaviour is byte-identical to the plain interpreter by construction. */
const int g_pd = 1;                /* fixed library profile, not execution state */
PDCache *ae_pd_cache(CPU *c) {
    if(!c->exec.pd) {
        c->exec.pd=ae_exec_cache_alloc(sizeof(PDCache));
        if(!c->exec.pd){if(c->m)c->m->host_error=-6;c->owner_yield=true;}
    }
    return c->exec.pd;
}
void ae_pd_reset_cpu(CPU *c) {
    if(c->exec.pd)memset(c->exec.pd,0,sizeof(PDCache));
}
void ae_pd_destroy_cpu(CPU *c) { ae_exec_cache_free(c->exec.pd);c->exec.pd=NULL; }
size_t ae_pd_cache_bytes(const CPU *c) { return c->exec.pd?sizeof(PDCache):0; }

StepResult pd_step(CPU *c, u64 slice, u64 max_insn) {
    if(machine_parallel_poll(c))return STEP_OK;
    /* Entry preamble, kept in lockstep with cpu_step: deliver a pending
     * interrupt, honour WFI/WFE, then bound the slice by the deadline. */
    if (c->stop) return STEP_HALT;
    if (c->owner_yield) return STEP_OK;
    if (c->fiq_line && !(c->daif & PS_F)) {
        exception_take(c, EXC_FIQ, 0, 0, c->pc); return STEP_OK;
    }
    if (c->irq_line && !(c->daif & PS_I)) {
        exception_take(c, EXC_IRQ, 0, 0, c->pc); return STEP_OK;
    }
    if (c->halted) return STEP_OK;
    PDCache *state=ae_pd_cache(c);if(!state)return STEP_OK;
    /* The address belongs to THIS native thread and THIS invocation only.
     * Actual accesses reload *slot; GENERIC/nested transactions may change it.
     * No CPU/worker identity, reset state or prior owner supplies this address. */
    const PDGuardSlotView guard_view={.slot=&memory_guard_held};
#define PD_READ(c,va,size,out) mem_read_pd_slot((c),(va),(size),(out),&guard_view)
#define PD_IFETCH(c,va,out) mem_ifetch_slot((c),(va),(out),&guard_view)
    /* The full entry poll above is mandatory. Bridge validates this native
     * worker once; the view never escapes this invocation or crosses reset. */
    const MachineParallelPollView *poll_view=machine_parallel_poll_view(c);
    PDEnt *cache=state->entry;
    u64 deadline = c->icount + slice;
    if (max_insn && deadline > max_insn) deadline = max_insn;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Woverride-init"
    static void *const pd_tab[256] = {
        [0 ... 255] = &&L_GENERIC,
        [PD_NOP] = &&L_NOP,
        [PD_SP_ALIGNED] = &&L_SP_ALIGNED,
        [PD_B] = &&L_B,
        [PD_BL] = &&L_BL,
        [PD_BCOND] = &&L_BCOND,
        [PD_CBZ64] = &&L_CBZ64,
        [PD_CBZ32] = &&L_CBZ32,
        [PD_CBNZ64] = &&L_CBNZ64,
        [PD_CBNZ32] = &&L_CBNZ32,
        [PD_TBZ] = &&L_TBZ,
        [PD_TBNZ] = &&L_TBNZ,
        [PD_BR] = &&L_BR,
        [PD_BLR] = &&L_BLR,
        [PD_ADD64I] = &&L_ADD64I,
        [PD_ADD32I] = &&L_ADD32I,
        [PD_SUB64I] = &&L_SUB64I,
        [PD_SUB32I] = &&L_SUB32I,
        [PD_ADDS64I] = &&L_ADDS64I,
        [PD_ADDS32I] = &&L_ADDS32I,
        [PD_SUBS64I] = &&L_SUBS64I,
        [PD_SUBS32I] = &&L_SUBS32I,
        [PD_AND64I] = &&L_AND64I,
        [PD_AND32I] = &&L_AND32I,
        [PD_ORR64I] = &&L_ORR64I,
        [PD_ORR32I] = &&L_ORR32I,
        [PD_EOR64I] = &&L_EOR64I,
        [PD_EOR32I] = &&L_EOR32I,
        [PD_ANDS64I] = &&L_ANDS64I,
        [PD_ANDS32I] = &&L_ANDS32I,
        [PD_MOVI] = &&L_MOVI,
        [PD_MOVK64] = &&L_MOVK64,
        [PD_MOVK32] = &&L_MOVK32,
        [PD_ADR] = &&L_ADR,
        [PD_ADRP] = &&L_ADRP,
        [PD_LSL64I] = &&L_LSL64I,
        [PD_LSL32I] = &&L_LSL32I,
        [PD_LSR64I] = &&L_LSR64I,
        [PD_LSR32I] = &&L_LSR32I,
        [PD_ASR64I] = &&L_ASR64I,
        [PD_ASR32I] = &&L_ASR32I,
        [PD_UBFX64] = &&L_UBFX64,
        [PD_UBFX32] = &&L_UBFX32,
        [PD_UBFIZ64] = &&L_UBFIZ64,
        [PD_UBFIZ32] = &&L_UBFIZ32,
        [PD_SBFX64] = &&L_SBFX64,
        [PD_SBFX32] = &&L_SBFX32,
        [PD_EXTR64] = &&L_EXTR64,
        [PD_EXTR32] = &&L_EXTR32,
        [PD_AND64] = &&L_AND64,
        [PD_AND32] = &&L_AND32,
        [PD_BIC64] = &&L_BIC64,
        [PD_BIC32] = &&L_BIC32,
        [PD_ORR64] = &&L_ORR64,
        [PD_ORR32] = &&L_ORR32,
        [PD_ORN64] = &&L_ORN64,
        [PD_ORN32] = &&L_ORN32,
        [PD_EOR64] = &&L_EOR64,
        [PD_EOR32] = &&L_EOR32,
        [PD_EON64] = &&L_EON64,
        [PD_EON32] = &&L_EON32,
        [PD_ANDS64] = &&L_ANDS64,
        [PD_ANDS32] = &&L_ANDS32,
        [PD_BICS64] = &&L_BICS64,
        [PD_BICS32] = &&L_BICS32,
        [PD_AND64S] = &&L_AND64S,
        [PD_AND32S] = &&L_AND64S,
        [PD_ORR64S] = &&L_AND64S,
        [PD_ORR32S] = &&L_AND64S,
        [PD_EOR64S] = &&L_AND64S,
        [PD_EOR32S] = &&L_AND64S,
        [PD_ANDS64S] = &&L_AND64S,
        [PD_ANDS32S] = &&L_AND64S,
        [PD_ADD64R] = &&L_ADD64R,
        [PD_ADD32R] = &&L_ADD32R,
        [PD_SUB64R] = &&L_SUB64R,
        [PD_SUB32R] = &&L_SUB32R,
        [PD_ADDS64R] = &&L_ADDS64R,
        [PD_ADDS32R] = &&L_ADDS32R,
        [PD_SUBS64R] = &&L_SUBS64R,
        [PD_SUBS32R] = &&L_SUBS32R,
        [PD_ADD64RS] = &&L_ADD64RS,
        [PD_ADD32RS] = &&L_ADD64RS,
        [PD_SUB64RS] = &&L_ADD64RS,
        [PD_SUB32RS] = &&L_ADD64RS,
        [PD_ADDS64RS] = &&L_ADD64RS,
        [PD_ADDS32RS] = &&L_ADD64RS,
        [PD_SUBS64RS] = &&L_ADD64RS,
        [PD_SUBS32RS] = &&L_ADD64RS,
        [PD_ADDX64] = &&L_ADDX64,
        [PD_ADDX32] = &&L_ADDX64,
        [PD_SUBX64] = &&L_ADDX64,
        [PD_SUBX32] = &&L_ADDX64,
        [PD_ADDSX64] = &&L_ADDX64,
        [PD_ADDSX32] = &&L_ADDX64,
        [PD_SUBSX64] = &&L_ADDX64,
        [PD_SUBSX32] = &&L_ADDX64,
        [PD_MADD64] = &&L_MADD64,
        [PD_MADD32] = &&L_MADD32,
        [PD_MSUB64] = &&L_MSUB64,
        [PD_MSUB32] = &&L_MSUB32,
        [PD_SMADDL] = &&L_SMADDL,
        [PD_SMSUBL] = &&L_SMSUBL,
        [PD_UMADDL] = &&L_UMADDL,
        [PD_UMSUBL] = &&L_UMSUBL,
        [PD_SMULH] = &&L_SMULH,
        [PD_UMULH] = &&L_UMULH,
        [PD_CSEL64] = &&L_CSEL64,
        [PD_CSEL32] = &&L_CSEL64,
        [PD_CSINC64] = &&L_CSEL64,
        [PD_CSINC32] = &&L_CSEL64,
        [PD_CSINV64] = &&L_CSEL64,
        [PD_CSINV32] = &&L_CSEL64,
        [PD_CSNEG64] = &&L_CSEL64,
        [PD_CSNEG32] = &&L_CSEL64,
        [PD_CCMP64I] = &&L_CCMP64I,
        [PD_CCMP32I] = &&L_CCMP64I,
        [PD_CCMP64R] = &&L_CCMP64I,
        [PD_CCMP32R] = &&L_CCMP64I,
        [PD_CCMN64I] = &&L_CCMP64I,
        [PD_CCMN32I] = &&L_CCMP64I,
        [PD_CCMN64R] = &&L_CCMP64I,
        [PD_CCMN32R] = &&L_CCMP64I,
        [PD_REV64] = &&L_REV64,
        [PD_REVW] = &&L_REVW,
        [PD_CLZ64] = &&L_CLZ64,
        [PD_CLZ32] = &&L_CLZ32,
        [PD_UDIV64] = &&L_UDIV64,
        [PD_UDIV32] = &&L_UDIV32,
        [PD_SDIV64] = &&L_SDIV64,
        [PD_SDIV32] = &&L_SDIV32,
        [PD_LSLV64] = &&L_LSLV64,
        [PD_LSLV32] = &&L_LSLV32,
        [PD_LSRV64] = &&L_LSRV64,
        [PD_LSRV32] = &&L_LSRV32,
        [PD_ASRV64] = &&L_ASRV64,
        [PD_ASRV32] = &&L_ASRV32,
        [PD_RORV64] = &&L_RORV64,
        [PD_RORV32] = &&L_RORV32,
        [PD_LDR64U] = &&L_LDR64U,
        [PD_LDR32U] = &&L_LDR32U,
        [PD_LDRB] = &&L_LDRB,
        [PD_LDRH] = &&L_LDRH,
        [PD_LDRSB64] = &&L_LDRSB64,
        [PD_LDRSB32] = &&L_LDRSB32,
        [PD_LDRSH64] = &&L_LDRSH64,
        [PD_LDRSH32] = &&L_LDRSH32,
        [PD_LDRSW] = &&L_LDRSW,
        [PD_STR64U] = &&L_STR64U,
        [PD_STR32U] = &&L_STR32U,
        [PD_STRB] = &&L_STRB,
        [PD_STRH] = &&L_STRH,
        [PD_LDR64PRE] = &&L_LDR64PRE,
        [PD_LDR64POST] = &&L_LDR64POST,
        [PD_LDR32PRE] = &&L_LDR32PRE,
        [PD_LDR32POST] = &&L_LDR32POST,
        [PD_STR64PRE] = &&L_STR64PRE,
        [PD_STR64POST] = &&L_STR64POST,
        [PD_STR32PRE] = &&L_STR32PRE,
        [PD_STR32POST] = &&L_STR32POST,
        [PD_LDRBPOST] = &&L_LDRBPOST,
        [PD_STRBPOST] = &&L_STRBPOST,
        [PD_LDR64RO] = &&L_LDR64RO,
        [PD_LDR32RO] = &&L_LDR64RO,
        [PD_LDRBRO] = &&L_LDR64RO,
        [PD_LDRHRO] = &&L_LDR64RO,
        [PD_STR64RO] = &&L_LDR64RO,
        [PD_STR32RO] = &&L_LDR64RO,
        [PD_STRBRO] = &&L_LDR64RO,
        [PD_STRHRO] = &&L_LDR64RO,
        [PD_LDRLIT64] = &&L_LDRLIT64,
        [PD_LDRLIT32] = &&L_LDRLIT32,
        [PD_LDRLITV] = &&L_LDRLITV,
        [PD_LDP64] = &&L_LDP64,
        [PD_LDP64PRE] = &&L_LDP64,
        [PD_LDP64POST] = &&L_LDP64,
        [PD_LDP32] = &&L_LDP64,
        [PD_LDP32PRE] = &&L_LDP64,
        [PD_LDP32POST] = &&L_LDP64,
        [PD_STP64] = &&L_STP64,
        [PD_STP64PRE] = &&L_STP64,
        [PD_STP64POST] = &&L_STP64,
        [PD_STP32] = &&L_STP64,
        [PD_STP32PRE] = &&L_STP64,
        [PD_STP32POST] = &&L_STP64,
        [PD_LDRQ] = &&L_LDRQ,
        [PD_STRQ] = &&L_STRQ,
        [PD_LDRV] = &&L_LDRV,
        [PD_STRV] = &&L_STRV,
        [PD_LDRQPRE] = &&L_LDRQPRE,
        [PD_LDRQPOST] = &&L_LDRQPOST,
        [PD_STRQPRE] = &&L_STRQPRE,
        [PD_STRQPOST] = &&L_STRQPOST,
        [PD_LDPQ] = &&L_LDPQ,
        [PD_LDPQPRE] = &&L_LDPQ,
        [PD_LDPQPOST] = &&L_LDPQ,
        [PD_STPQ] = &&L_STPQ,
        [PD_STPQPRE] = &&L_STPQ,
        [PD_STPQPOST] = &&L_STPQ,
        [PD_LDPD] = &&L_LDPD,
        [PD_LDPDPRE] = &&L_LDPD,
        [PD_LDPDPOST] = &&L_LDPD,
        [PD_STPD] = &&L_STPD,
        [PD_STPDPRE] = &&L_STPD,
        [PD_STPDPOST] = &&L_STPD,
    };
#pragma GCC diagnostic pop
    /* Debug bisection knob (the -pd analogue of AEJIT_PDMAX): AEPD_MAX=N keeps
     * only PD ops <= N on their native handlers; everything above runs through
     * exec_a64 (L_GENERIC). AEPD_MAX=0 is the pure-interpreter floor. Applied
     * once to the dispatch table — the per-instruction path is untouched. */
    if (UNLIKELY(!state->dispatch_ready)) {
        memcpy(state->dispatch,pd_tab,sizeof(state->dispatch));
        const char *s = getenv("AEPD_MAX");
        if (s) {
            int m = atoi(s);
            for (int i = (m < 0 ? 0 : m + 1); i < 256; i++)
                state->dispatch[i] = &&L_GENERIC;
        }
        state->dispatch_ready=true;
    }
    void **dispatch=state->dispatch;
    PDEnt *e;
    PDEnt aligned_sp_entry; /* this invocation only; never stored in the bank */
    u32 insn;

    /* Each handler ends in NEXT: bump icount, run the cheap per-insn rare-event
     * checks (mirroring cpu_step + jit_step), fetch+validate+dispatch. A raised
     * synchronous exception has already set c->pc to the vector (cpu_raise_sync),
     * so there is nothing extra to check here. */
#define NEXT_MODE(force_full) do { \
        if(!c->instruction_partial)c->icount++; \
        if (UNLIKELY((force_full)||machine_parallel_poll_due(c,poll_view))) { \
            if (UNLIKELY(machine_parallel_poll(c))) return STEP_OK; \
        } \
        if (UNLIKELY(c->stop)) return STEP_HALT; \
        if (UNLIKELY(c->halted || c->owner_yield)) return STEP_OK; \
        if (UNLIKELY(c->icount >= deadline)) return STEP_OK; \
        if (UNLIKELY((c->irq_line && !(c->daif & PS_I)) || \
                     (c->fiq_line && !(c->daif & PS_F)))) return STEP_OK; \
        c->cur_insn_pc = c->pc; \
        c->instruction_partial=false; \
        if (UNLIKELY(!PD_IFETCH(c, c->pc, &insn))) return STEP_OK; \
        c->pc += 4; \
        e = &cache[(c->cur_insn_pc >> 2) & PD_MASK]; \
        if (UNLIKELY(e->insn != insn)) pd_fill_tier(e, insn); \
        goto *dispatch[e->op]; \
    } while (0)

#define NEXT NEXT_MODE(false)
    /* First instruction of the slice (the preamble ran the rare-event checks). */
    c->cur_insn_pc = c->pc;
    c->instruction_partial=false;
    if (UNLIKELY(!PD_IFETCH(c, c->pc, &insn))) return STEP_OK;
    c->pc += 4;
    e = &cache[(c->cur_insn_pc >> 2) & PD_MASK];
    if (UNLIKELY(e->insn != insn)) pd_fill_tier(e, insn);
    goto *dispatch[e->op];

L_SP_ALIGNED:
    if (UNLIKELY(reg_xsp(c,31) & 15)) {
        exec_a64(c,insn);
        NEXT_MODE(true);
    }
    /* Restore the original shape on this frame. Cached entries remain pure
     * instruction metadata; SP, EL, FPEN and MMU state are read live. Honor
     * the existing dispatch demotion policy when selecting the old handler. */
    aligned_sp_entry = *e;
    aligned_sp_entry.op = e->rn;
    aligned_sp_entry.rn = 31;
    e = &aligned_sp_entry;
    goto *dispatch[e->op];
L_GENERIC:
    /* GENERIC never inherits the optimized selector: preserve its full poll
     * even though its architectural tail shares the original NEXT body. */
    exec_a64(c, insn); NEXT_MODE(true);
L_NOP:
    NEXT;

    /* ---- branches ---- */
L_B:
    c->pc = c->cur_insn_pc + e->imm; NEXT;
L_BL:
        set_x(c, 30, c->cur_insn_pc + 4);
        c->pc = c->cur_insn_pc + e->imm;
        NEXT;
L_BCOND:
        if (cond_holds(c, e->rd)) c->pc = c->cur_insn_pc + e->imm;
        NEXT;
L_CBZ64:
    if (reg_x(c, e->rd) == 0) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_CBZ32:
    if ((u32)reg_x(c, e->rd) == 0) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_CBNZ64:
    if (reg_x(c, e->rd) != 0) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_CBNZ32:
    if ((u32)reg_x(c, e->rd) != 0) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_TBZ:
    if (!((reg_x(c, e->rd) >> e->rm) & 1)) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_TBNZ:
    if (((reg_x(c, e->rd) >> e->rm) & 1)) c->pc = c->cur_insn_pc + e->imm;
    NEXT;
L_BR:
    c->pc = reg_x(c, e->rn); NEXT;
L_BLR:
    {
        u64 tgt = reg_x(c, e->rn);           /* read before writing x30 */
        set_x(c, 30, c->cur_insn_pc + 4);
        c->pc = tgt;
        NEXT;
    }

    /* ---- add/sub immediate ---- */
L_ADD64I:
    set_xsp(c, e->rd, reg_xsp(c, e->rn) + e->imm); NEXT;
L_ADD32I:
    set_xsp(c, e->rd, (u32)(reg_xsp(c, e->rn) + e->imm)); NEXT;
L_SUB64I:
    set_xsp(c, e->rd, reg_xsp(c, e->rn) - e->imm); NEXT;
L_SUB32I:
    set_xsp(c, e->rd, (u32)(reg_xsp(c, e->rn) - e->imm)); NEXT;
L_ADDS64I:
    {
        u32 fl; u64 r = pd_awc(reg_xsp(c, e->rn), e->imm, 0, true, &fl);
        c->nzcv = fl; set_x(c, e->rd, r); NEXT;
    }
L_ADDS32I:
    {
        u32 fl; u64 r = pd_awc(reg_xsp(c, e->rn), e->imm, 0, false, &fl);
        c->nzcv = fl; set_x(c, e->rd, (u32)r); NEXT;
    }
L_SUBS64I:
    {   /* imm stored pre-inverted (~imm) */
        u32 fl; u64 r = pd_awc(reg_xsp(c, e->rn), e->imm, 1, true, &fl);
        c->nzcv = fl; set_x(c, e->rd, r); NEXT;
    }
L_SUBS32I:
    {
        u32 fl; u64 r = pd_awc(reg_xsp(c, e->rn), e->imm, 1, false, &fl);
        c->nzcv = fl; set_x(c, e->rd, (u32)r); NEXT;
    }

    /* ---- logical immediate (imm = wmask, already width-truncated) ---- */
L_AND64I:
    set_xsp(c, e->rd, reg_x(c, e->rn) & e->imm); NEXT;
L_AND32I:
    set_xsp(c, e->rd, (u32)(reg_x(c, e->rn) & e->imm)); NEXT;
L_ORR64I:
    set_xsp(c, e->rd, reg_x(c, e->rn) | e->imm); NEXT;
L_ORR32I:
    set_xsp(c, e->rd, (u32)(reg_x(c, e->rn) | e->imm)); NEXT;
L_EOR64I:
    set_xsp(c, e->rd, reg_x(c, e->rn) ^ e->imm); NEXT;
L_EOR32I:
    set_xsp(c, e->rd, (u32)(reg_x(c, e->rn) ^ e->imm)); NEXT;
L_ANDS64I:
    {
        u64 r = reg_x(c, e->rn) & e->imm;
        pd_logical_flags(c, r, true); set_x(c, e->rd, r); NEXT;
    }
L_ANDS32I:
    {
        u64 r = (u32)(reg_x(c, e->rn) & e->imm);
        pd_logical_flags(c, r, false); set_x(c, e->rd, r); NEXT;
    }

    /* ---- move wide / PC-relative ---- */
L_MOVI:
    set_x(c, e->rd, e->imm); NEXT;   /* MOVZ/MOVN, precomputed */
L_MOVK64:
        set_x(c, e->rd, (reg_x(c, e->rd) & ~(0xffffULL << e->rm)) | e->imm);
        NEXT;
L_MOVK32:
        set_x(c, e->rd, (u32)((reg_x(c, e->rd) & ~(0xffffULL << e->rm)) | e->imm));
        NEXT;
L_ADR:
    set_x(c, e->rd, c->cur_insn_pc + e->imm); NEXT;
L_ADRP:
    set_x(c, e->rd, (c->cur_insn_pc & ~0xfffULL) + e->imm); NEXT;

    /* ---- bitfield aliases ---- */
L_LSL64I:
    set_x(c, e->rd, reg_x(c, e->rn) << e->rm); NEXT;
L_LSL32I:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) << e->rm)); NEXT;
L_LSR64I:
    set_x(c, e->rd, reg_x(c, e->rn) >> e->rm); NEXT;
L_LSR32I:
    set_x(c, e->rd, (u32)reg_x(c, e->rn) >> e->rm); NEXT;
L_ASR64I:
    set_x(c, e->rd, (u64)((s64)reg_x(c, e->rn) >> e->rm)); NEXT;
L_ASR32I:
    set_x(c, e->rd, (u32)((s32)(u32)reg_x(c, e->rn) >> e->rm)); NEXT;
L_UBFX64:
    set_x(c, e->rd, (reg_x(c, e->rn) >> e->rm) & e->imm); NEXT;
L_UBFX32:
    set_x(c, e->rd, (reg_x(c, e->rn) >> e->rm) & e->imm); NEXT;
L_UBFIZ64:
    set_x(c, e->rd, (reg_x(c, e->rn) & e->imm) << e->rm); NEXT;
L_UBFIZ32:
    set_x(c, e->rd, (u32)((reg_x(c, e->rn) & e->imm) << e->rm)); NEXT;
L_SBFX64:
    /* rm = left shift, imm = arithmetic right shift */
        set_x(c, e->rd, (u64)((s64)(reg_x(c, e->rn) << e->rm) >> e->imm));
        NEXT;
L_SBFX32:
        set_x(c, e->rd, (u32)((s32)((u32)reg_x(c, e->rn) << e->rm) >> e->imm));
        NEXT;
L_EXTR64:
    {
        u64 hi = reg_x(c, e->rn), lo = reg_x(c, e->rm);
        set_x(c, e->rd, e->imm ? ((hi << (64 - e->imm)) | (lo >> e->imm)) : lo);
        NEXT;
    }
L_EXTR32:
    {
        u32 h = (u32)reg_x(c, e->rn), l = (u32)reg_x(c, e->rm);
        set_x(c, e->rd, e->imm ? (u32)((h << (32 - e->imm)) | (l >> e->imm)) : l);
        NEXT;
    }

    /* ---- logical shifted register, LSL #0 ---- */
L_AND64:
    set_x(c, e->rd, reg_x(c, e->rn) & reg_x(c, e->rm)); NEXT;
L_AND32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) & reg_x(c, e->rm))); NEXT;
L_BIC64:
    set_x(c, e->rd, reg_x(c, e->rn) & ~reg_x(c, e->rm)); NEXT;
L_BIC32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) & ~reg_x(c, e->rm))); NEXT;
L_ORR64:
    set_x(c, e->rd, reg_x(c, e->rn) | reg_x(c, e->rm)); NEXT;
L_ORR32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) | reg_x(c, e->rm))); NEXT;
L_ORN64:
    set_x(c, e->rd, reg_x(c, e->rn) | ~reg_x(c, e->rm)); NEXT;
L_ORN32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) | ~reg_x(c, e->rm))); NEXT;
L_EOR64:
    set_x(c, e->rd, reg_x(c, e->rn) ^ reg_x(c, e->rm)); NEXT;
L_EOR32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) ^ reg_x(c, e->rm))); NEXT;
L_EON64:
    set_x(c, e->rd, reg_x(c, e->rn) ^ ~reg_x(c, e->rm)); NEXT;
L_EON32:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) ^ ~reg_x(c, e->rm))); NEXT;
L_ANDS64:
    {
        u64 r = reg_x(c, e->rn) & reg_x(c, e->rm);
        pd_logical_flags(c, r, true); set_x(c, e->rd, r); NEXT;
    }
L_ANDS32:
    {
        u64 r = (u32)(reg_x(c, e->rn) & reg_x(c, e->rm));
        pd_logical_flags(c, r, false); set_x(c, e->rd, r); NEXT;
    }
L_BICS64:
    {
        u64 r = reg_x(c, e->rn) & ~reg_x(c, e->rm);
        pd_logical_flags(c, r, true); set_x(c, e->rd, r); NEXT;
    }
L_BICS32:
    {
        u64 r = (u32)(reg_x(c, e->rn) & ~reg_x(c, e->rm));
        pd_logical_flags(c, r, false); set_x(c, e->rd, r); NEXT;
    }

    /* ---- logical shifted register with shift (imm = N<<8|type<<6|amt) ---- */
L_AND64S:
    {
        bool is64 = (e->op == PD_AND64S || e->op == PD_ORR64S ||
                     e->op == PD_EOR64S || e->op == PD_ANDS64S);
        u64 op2 = pd_shift_reg(reg_x(c, e->rm), (unsigned)(e->imm >> 6) & 3,
                               (unsigned)e->imm & 63, is64);
        if (e->imm & 256) op2 = ~op2;
        u64 n = reg_x(c, e->rn), r;
        if (e->op == PD_AND64S || e->op == PD_AND32S ||
            e->op == PD_ANDS64S || e->op == PD_ANDS32S) r = n & op2;
        else if (e->op == PD_ORR64S || e->op == PD_ORR32S) r = n | op2;
        else r = n ^ op2;
        if (!is64) r = (u32)r;
        if (e->op == PD_ANDS64S || e->op == PD_ANDS32S) pd_logical_flags(c, r, is64);
        set_x(c, e->rd, r);
        NEXT;
    }

    /* ---- add/sub shifted register, LSL #0 ---- */
L_ADD64R:
    set_x(c, e->rd, reg_x(c, e->rn) + reg_x(c, e->rm)); NEXT;
L_ADD32R:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) + reg_x(c, e->rm))); NEXT;
L_SUB64R:
    set_x(c, e->rd, reg_x(c, e->rn) - reg_x(c, e->rm)); NEXT;
L_SUB32R:
    set_x(c, e->rd, (u32)(reg_x(c, e->rn) - reg_x(c, e->rm))); NEXT;
L_ADDS64R:
    {
        u32 fl; u64 r = pd_awc(reg_x(c, e->rn), reg_x(c, e->rm), 0, true, &fl);
        c->nzcv = fl; set_x(c, e->rd, r); NEXT;
    }
L_ADDS32R:
    {
        u32 fl; u64 r = pd_awc(reg_x(c, e->rn), reg_x(c, e->rm), 0, false, &fl);
        c->nzcv = fl; set_x(c, e->rd, (u32)r); NEXT;
    }
L_SUBS64R:
    {
        u32 fl; u64 r = pd_awc(reg_x(c, e->rn), ~reg_x(c, e->rm), 1, true, &fl);
        c->nzcv = fl; set_x(c, e->rd, r); NEXT;
    }
L_SUBS32R:
    {
        u32 fl; u64 r = pd_awc(reg_x(c, e->rn), ~reg_x(c, e->rm), 1, false, &fl);
        c->nzcv = fl; set_x(c, e->rd, (u32)r); NEXT;
    }

    /* ---- add/sub shifted register with shift (imm = type<<6|amt) ---- */
L_ADD64RS:
    {
        bool is64 = (e->op == PD_ADD64RS || e->op == PD_SUB64RS ||
                     e->op == PD_ADDS64RS || e->op == PD_SUBS64RS);
        bool sub = (e->op == PD_SUB64RS || e->op == PD_SUB32RS ||
                    e->op == PD_SUBS64RS || e->op == PD_SUBS32RS);
        bool S = (e->op == PD_ADDS64RS || e->op == PD_ADDS32RS ||
                  e->op == PD_SUBS64RS || e->op == PD_SUBS32RS);
        u64 op2 = pd_shift_reg(reg_x(c, e->rm), (unsigned)(e->imm >> 6) & 3,
                               (unsigned)e->imm & 63, is64);
        u32 fl;
        u64 n = reg_x(c, e->rn);
        u64 r = sub ? pd_awc(n, ~op2, 1, is64, &fl)
                    : pd_awc(n, op2, 0, is64, &fl);
        if (S) c->nzcv = fl;
        set_x_sz(c, e->rd, is64, r);
        NEXT;
    }

    /* ---- add/sub extended register (imm = option<<3|imm3) ---- */
L_ADDX64:
    {
        bool is64 = (e->op == PD_ADDX64 || e->op == PD_SUBX64 ||
                     e->op == PD_ADDSX64 || e->op == PD_SUBSX64);
        bool sub = (e->op == PD_SUBX64 || e->op == PD_SUBX32 ||
                    e->op == PD_SUBSX64 || e->op == PD_SUBSX32);
        bool S = (e->op == PD_ADDSX64 || e->op == PD_ADDSX32 ||
                  e->op == PD_SUBSX64 || e->op == PD_SUBSX32);
        u64 op2 = pd_extend_reg(reg_x(c, e->rm), (unsigned)(e->imm >> 3) & 7,
                                (unsigned)e->imm & 7);
        u64 n = reg_xsp(c, e->rn);
        u32 fl;
        u64 r = sub ? pd_awc(n, ~op2, 1, is64, &fl)
                    : pd_awc(n, op2, 0, is64, &fl);
        if (S) { c->nzcv = fl; set_x_sz(c, e->rd, is64, r); }
        else set_xsp(c, e->rd, is64 ? r : (u32)r);
        NEXT;
    }

    /* ---- 3-source ---- */
L_MADD64:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) + reg_x(c, e->rn) * reg_x(c, e->rm));
        NEXT;
L_MADD32:
        set_x(c, e->rd, (u32)(reg_x(c, (unsigned)e->imm) + reg_x(c, e->rn) * reg_x(c, e->rm)));
        NEXT;
L_MSUB64:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) - reg_x(c, e->rn) * reg_x(c, e->rm));
        NEXT;
L_MSUB32:
        set_x(c, e->rd, (u32)(reg_x(c, (unsigned)e->imm) - reg_x(c, e->rn) * reg_x(c, e->rm)));
        NEXT;
L_SMADDL:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) +
              (u64)((s64)(s32)(u32)reg_x(c, e->rn) * (s64)(s32)(u32)reg_x(c, e->rm)));
        NEXT;
L_SMSUBL:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) -
              (u64)((s64)(s32)(u32)reg_x(c, e->rn) * (s64)(s32)(u32)reg_x(c, e->rm)));
        NEXT;
L_UMADDL:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) +
              (u64)((u64)(u32)reg_x(c, e->rn) * (u64)(u32)reg_x(c, e->rm)));
        NEXT;
L_UMSUBL:
        set_x(c, e->rd, reg_x(c, (unsigned)e->imm) -
              (u64)((u64)(u32)reg_x(c, e->rn) * (u64)(u32)reg_x(c, e->rm)));
        NEXT;
L_SMULH:
        set_x(c, e->rd, (u64)smulh64((s64)reg_x(c, e->rn), (s64)reg_x(c, e->rm)));
        NEXT;
L_UMULH:
        set_x(c, e->rd, umulh64(reg_x(c, e->rn), reg_x(c, e->rm)));
        NEXT;

    /* ---- conditional select (imm = cond) ---- */
L_CSEL64:
    {
        bool is64 = (e->op == PD_CSEL64 || e->op == PD_CSINC64 ||
                     e->op == PD_CSINV64 || e->op == PD_CSNEG64);
        u64 r;
        if (cond_holds(c, (unsigned)e->imm)) r = reg_x(c, e->rn);
        else {
            u64 m = reg_x(c, e->rm);
            if (e->op == PD_CSEL64 || e->op == PD_CSEL32) r = m;
            else if (e->op == PD_CSINC64 || e->op == PD_CSINC32) r = m + 1;
            else if (e->op == PD_CSINV64 || e->op == PD_CSINV32) r = ~m;
            else r = (u64)(-(s64)m);
        }
        set_x_sz(c, e->rd, is64, r);
        NEXT;
    }

    /* ---- conditional compare (imm = cond | imm5<<8 | flags<<32) ---- */
L_CCMP64I:
    {
        bool is64 = (e->op == PD_CCMP64I || e->op == PD_CCMP64R ||
                     e->op == PD_CCMN64I || e->op == PD_CCMN64R);
        bool cmp = (e->op == PD_CCMP64I || e->op == PD_CCMP32I ||
                    e->op == PD_CCMP64R || e->op == PD_CCMP32R);
        bool is_imm = (e->op == PD_CCMP64I || e->op == PD_CCMP32I ||
                       e->op == PD_CCMN64I || e->op == PD_CCMN32I);
        if (cond_holds(c, (unsigned)e->imm & 15)) {
            u64 n = reg_x(c, e->rn);
            u64 m = is_imm ? ((e->imm >> 8) & 31) : reg_x(c, e->rm);
            u32 fl;
            if (cmp) pd_awc(n, ~m, 1, is64, &fl);
            else pd_awc(n, m, 0, is64, &fl);
            c->nzcv = fl;
        } else {
            c->nzcv = (u32)(e->imm >> 32);   /* precomputed flags word */
        }
        NEXT;
    }

    /* ---- 1-source (hot subset) ---- */
L_REV64:
    set_x(c, e->rd, __builtin_bswap64(reg_x(c, e->rn))); NEXT;
L_REVW:
    set_x(c, e->rd, __builtin_bswap32((u32)reg_x(c, e->rn))); NEXT;
L_CLZ64:
    {
        u64 n = reg_x(c, e->rn);
        set_x(c, e->rd, n ? (u64)__builtin_clzll(n) : 64);
        NEXT;
    }
L_CLZ32:
    {
        u32 n = (u32)reg_x(c, e->rn);
        set_x(c, e->rd, n ? (u32)__builtin_clz(n) : 32);
        NEXT;
    }

    /* ---- 2-source ---- */
L_UDIV64:
    {
        u64 n = reg_x(c, e->rn), m = reg_x(c, e->rm);
        set_x(c, e->rd, m == 0 ? 0 : n / m);
        NEXT;
    }
L_UDIV32:
    {
        u32 a = (u32)reg_x(c, e->rn), b = (u32)reg_x(c, e->rm);
        set_x(c, e->rd, b ? a / b : 0);
        NEXT;
    }
L_SDIV64:
    {
        s64 a = (s64)reg_x(c, e->rn), b = (s64)reg_x(c, e->rm);
        set_x(c, e->rd, (b == 0) ? 0 : (u64)((b == -1 && a == INT64_MIN) ? a : a / b));
        NEXT;
    }
L_SDIV32:
    {
        s32 a = (s32)(u32)reg_x(c, e->rn), b = (s32)(u32)reg_x(c, e->rm);
        set_x(c, e->rd, b ? (u32)((b == -1 && a == INT32_MIN) ? a : a / b) : 0);
        NEXT;
    }
L_LSLV64:
    set_x(c, e->rd, pd_shift_reg(reg_x(c, e->rn), 0, (unsigned)reg_x(c, e->rm), true)); NEXT;
L_LSLV32:
    set_x(c, e->rd, (u32)pd_shift_reg(reg_x(c, e->rn), 0, (unsigned)reg_x(c, e->rm), false)); NEXT;
L_LSRV64:
    set_x(c, e->rd, pd_shift_reg(reg_x(c, e->rn), 1, (unsigned)reg_x(c, e->rm), true)); NEXT;
L_LSRV32:
    set_x(c, e->rd, (u32)pd_shift_reg(reg_x(c, e->rn), 1, (unsigned)reg_x(c, e->rm), false)); NEXT;
L_ASRV64:
    set_x(c, e->rd, pd_shift_reg(reg_x(c, e->rn), 2, (unsigned)reg_x(c, e->rm), true)); NEXT;
L_ASRV32:
    set_x(c, e->rd, (u32)pd_shift_reg(reg_x(c, e->rn), 2, (unsigned)reg_x(c, e->rm), false)); NEXT;
L_RORV64:
    set_x(c, e->rd, pd_shift_reg(reg_x(c, e->rn), 3, (unsigned)reg_x(c, e->rm), true)); NEXT;
L_RORV32:
    set_x(c, e->rd, (u32)pd_shift_reg(reg_x(c, e->rn), 3, (unsigned)reg_x(c, e->rm), false)); NEXT;

    /* ---- integer load/store, va = base + imm ---- */
L_LDR64U:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 8, &v)) set_x(c, e->rd, v);
        NEXT;
    }
L_LDR32U:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 4, &v)) set_x(c, e->rd, (u32)v);
        NEXT;
    }
L_LDRB:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 1, &v)) set_x(c, e->rd, v);
        NEXT;
    }
L_LDRH:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 2, &v)) set_x(c, e->rd, v);
        NEXT;
    }
L_LDRSB64:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 1, &v)) set_x(c, e->rd, sign_extend(v, 8));
        NEXT;
    }
L_LDRSB32:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 1, &v)) set_x(c, e->rd, (u32)sign_extend(v, 8));
        NEXT;
    }
L_LDRSH64:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 2, &v)) set_x(c, e->rd, sign_extend(v, 16));
        NEXT;
    }
L_LDRSH32:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 2, &v)) set_x(c, e->rd, (u32)sign_extend(v, 16));
        NEXT;
    }
L_LDRSW:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (PD_READ(c, va, 4, &v)) set_x(c, e->rd, sign_extend(v, 32));
        NEXT;
    }
L_STR64U:
    mem_write(c, reg_xsp(c, e->rn) + e->imm, 8, reg_x(c, e->rd)); NEXT;
L_STR32U:
    mem_write(c, reg_xsp(c, e->rn) + e->imm, 4, reg_x(c, e->rd)); NEXT;
L_STRB:
    mem_write(c, reg_xsp(c, e->rn) + e->imm, 1, reg_x(c, e->rd)); NEXT;
L_STRH:
    mem_write(c, reg_xsp(c, e->rn) + e->imm, 2, reg_x(c, e->rd)); NEXT;

    /* ---- pre/post-indexed (writeback commits only after success) ---- */
L_LDR64PRE:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (!PD_READ(c, va, 8, &v)) NEXT;
        set_x(c, e->rd, v); set_xsp(c, e->rn, va);
        NEXT;
    }
L_LDR64POST:
    {
        u64 base = reg_xsp(c, e->rn), v;
        if (!PD_READ(c, base, 8, &v)) NEXT;
        set_x(c, e->rd, v); set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_LDR32PRE:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm, v;
        if (!PD_READ(c, va, 4, &v)) NEXT;
        set_x(c, e->rd, (u32)v); set_xsp(c, e->rn, va);
        NEXT;
    }
L_LDR32POST:
    {
        u64 base = reg_xsp(c, e->rn), v;
        if (!PD_READ(c, base, 4, &v)) NEXT;
        set_x(c, e->rd, (u32)v); set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_STR64PRE:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm;
        if (!mem_write(c, va, 8, reg_x(c, e->rd))) NEXT;
        set_xsp(c, e->rn, va);
        NEXT;
    }
L_STR64POST:
    {
        u64 base = reg_xsp(c, e->rn);
        if (!mem_write(c, base, 8, reg_x(c, e->rd))) NEXT;
        set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_STR32PRE:
    {
        u64 va = reg_xsp(c, e->rn) + e->imm;
        if (!mem_write(c, va, 4, reg_x(c, e->rd))) NEXT;
        set_xsp(c, e->rn, va);
        NEXT;
    }
L_STR32POST:
    {
        u64 base = reg_xsp(c, e->rn);
        if (!mem_write(c, base, 4, reg_x(c, e->rd))) NEXT;
        set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_LDRBPOST:
    {
        u64 base = reg_xsp(c, e->rn), v;
        if (!PD_READ(c, base, 1, &v)) NEXT;
        set_x(c, e->rd, v); set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_STRBPOST:
    {
        u64 base = reg_xsp(c, e->rn);
        if (!mem_write(c, base, 1, reg_x(c, e->rd))) NEXT;
        set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }

    /* ---- register offset (imm = option<<3|shift) ---- */
L_LDR64RO:
    {
        u64 va = reg_xsp(c, e->rn) +
                 pd_extend_reg(reg_x(c, e->rm), (unsigned)(e->imm >> 3) & 7,
                               (unsigned)e->imm & 7);
        u64 v;
        if (e->op == PD_LDR64RO) { if (PD_READ(c, va, 8, &v)) set_x(c, e->rd, v); }
        else if (e->op == PD_LDR32RO) { if (PD_READ(c, va, 4, &v)) set_x(c, e->rd, (u32)v); }
        else if (e->op == PD_LDRBRO) { if (PD_READ(c, va, 1, &v)) set_x(c, e->rd, v); }
        else if (e->op == PD_LDRHRO) { if (PD_READ(c, va, 2, &v)) set_x(c, e->rd, v); }
        else if (e->op == PD_STR64RO) mem_write(c, va, 8, reg_x(c, e->rd));
        else if (e->op == PD_STR32RO) mem_write(c, va, 4, reg_x(c, e->rd));
        else if (e->op == PD_STRBRO) mem_write(c, va, 1, reg_x(c, e->rd));
        else mem_write(c, va, 2, reg_x(c, e->rd));
        NEXT;
    }

    /* Handlers that touch V registers execute natively (no exec_a64 fallback),
     * so they must apply the CPACR_EL1.FPEN guard themselves; cur_insn_pc is
     * already set by the dispatch preamble, and NEXT follows the redirected
     * c->pc into the vector. FP *data-processing* needs no guard here: it is
     * PD_GENERIC and exec_a64's dispatch guard covers it. */
#define FP_GUARD() do { \
        if (__builtin_expect(c->fp_trapped, 0)) { cpu_fp_trap(c); NEXT; } \
    } while (0)

    /* ---- literal ---- */
L_LDRLIT64:
    {
        u64 v;
        if (PD_READ(c, c->cur_insn_pc + e->imm, 8, &v)) set_x(c, e->rd, v);
        NEXT;
    }
L_LDRLIT32:
    {
        u64 v;
        if (PD_READ(c, c->cur_insn_pc + e->imm, 4, &v)) set_x(c, e->rd, (u32)v);
        NEXT;
    }
L_LDRLITV:
    {   /* SIMD&FP literal: rm = byte count 4/8/16; zero-extends into V[rd] */
        FP_GUARD();
        V128 v; v.d[0] = 0; v.d[1] = 0;
        u64 va = c->cur_insn_pc + e->imm;
        if (e->rm == 16) { if (mem_read128(c, va, &v)) c->v[e->rd] = v; }
        else { u64 t; if (mem_read(c, va, e->rm, &t)) { v.d[0] = t; c->v[e->rd] = v; } }
        NEXT;
    }

    /* ---- integer pairs (rm = Rt2; both loads land before either write) ---- */
L_LDP64:
    {
        bool is64 = (e->op == PD_LDP64 || e->op == PD_LDP64PRE || e->op == PD_LDP64POST);
        bool post = (e->op == PD_LDP64POST || e->op == PD_LDP32POST);
        bool wb = post || e->op == PD_LDP64PRE || e->op == PD_LDP32PRE;
        unsigned esz = is64 ? 8 : 4;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        u64 a, b;
        if (!mem_read(c, addr, esz, &a)) NEXT;
        if (!mem_read(c, addr + esz, esz, &b)) NEXT;
        if (is64) { set_x(c, e->rd, a); set_x(c, e->rm, b); }
        else { set_x(c, e->rd, (u32)a); set_x(c, e->rm, (u32)b); }
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }
L_STP64:
    {
        bool is64 = (e->op == PD_STP64 || e->op == PD_STP64PRE || e->op == PD_STP64POST);
        bool post = (e->op == PD_STP64POST || e->op == PD_STP32POST);
        bool wb = post || e->op == PD_STP64PRE || e->op == PD_STP32PRE;
        unsigned esz = is64 ? 8 : 4;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        if (!mem_write(c, addr, esz, reg_x(c, e->rd))) NEXT;
        if (!mem_write(c, addr + esz, esz, reg_x(c, e->rm))) NEXT;
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }

    /* ---- FP/SIMD register load/store (rd = Vt) ----
     * FP_GUARD (defined above the literal section, which has a V-register form
     * of its own) applies CPACR_EL1.FPEN to each of these. */
L_LDRQ:
    {
        FP_GUARD();
        V128 v;
        if (mem_read128(c, reg_xsp(c, e->rn) + e->imm, &v)) c->v[e->rd] = v;
        NEXT;
    }
L_STRQ:
    FP_GUARD();
    mem_write128(c, reg_xsp(c, e->rn) + e->imm, &c->v[e->rd]); NEXT;
L_LDRV:
    {   /* rm = byte count 1/2/4/8; high half cleared */
        FP_GUARD();
        u64 t;
        if (mem_read(c, reg_xsp(c, e->rn) + e->imm, e->rm, &t)) {
            c->v[e->rd].d[0] = t;
            c->v[e->rd].d[1] = 0;
        }
        NEXT;
    }
L_STRV:
    FP_GUARD();
    mem_write(c, reg_xsp(c, e->rn) + e->imm, e->rm, c->v[e->rd].d[0]); NEXT;
L_LDRQPRE:
    {
        FP_GUARD();
        u64 va = reg_xsp(c, e->rn) + e->imm;
        V128 v;
        if (!mem_read128(c, va, &v)) NEXT;
        c->v[e->rd] = v; set_xsp(c, e->rn, va);
        NEXT;
    }
L_LDRQPOST:
    {
        FP_GUARD();
        u64 base = reg_xsp(c, e->rn);
        V128 v;
        if (!mem_read128(c, base, &v)) NEXT;
        c->v[e->rd] = v; set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }
L_STRQPRE:
    {
        FP_GUARD();
        u64 va = reg_xsp(c, e->rn) + e->imm;
        if (!mem_write128(c, va, &c->v[e->rd])) NEXT;
        set_xsp(c, e->rn, va);
        NEXT;
    }
L_STRQPOST:
    {
        FP_GUARD();
        u64 base = reg_xsp(c, e->rn);
        if (!mem_write128(c, base, &c->v[e->rd])) NEXT;
        set_xsp(c, e->rn, base + e->imm);
        NEXT;
    }

    /* ---- FP/SIMD pairs (rm = Vt2; first element commits even if the
     * second faults — matches decode.c's vreg_load ordering) ---- */
L_LDPQ:
    {
        FP_GUARD();
        bool post = (e->op == PD_LDPQPOST);
        bool wb = post || e->op == PD_LDPQPRE;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        V128 v;
        if (!mem_read128(c, addr, &v)) NEXT;
        c->v[e->rd] = v;
        if (!mem_read128(c, addr + 16, &v)) NEXT;
        c->v[e->rm] = v;
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }
L_STPQ:
    {
        FP_GUARD();
        bool post = (e->op == PD_STPQPOST);
        bool wb = post || e->op == PD_STPQPRE;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        if (!mem_write128(c, addr, &c->v[e->rd])) NEXT;
        if (!mem_write128(c, addr + 16, &c->v[e->rm])) NEXT;
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }
L_LDPD:
    {
        FP_GUARD();
        bool post = (e->op == PD_LDPDPOST);
        bool wb = post || e->op == PD_LDPDPRE;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        u64 t;
        if (!mem_read(c, addr, 8, &t)) NEXT;
        c->v[e->rd].d[0] = t; c->v[e->rd].d[1] = 0;
        if (!mem_read(c, addr + 8, 8, &t)) NEXT;
        c->v[e->rm].d[0] = t; c->v[e->rm].d[1] = 0;
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }
L_STPD:
    {
        FP_GUARD();
        bool post = (e->op == PD_STPDPOST);
        bool wb = post || e->op == PD_STPDPRE;
        u64 base = reg_xsp(c, e->rn);
        u64 addr = post ? base : base + e->imm;
        if (!mem_write(c, addr, 8, c->v[e->rd].d[0])) NEXT;
        if (!mem_write(c, addr + 8, 8, c->v[e->rm].d[0])) NEXT;
        if (wb) set_xsp(c, e->rn, post ? base + e->imm : addr);
        NEXT;
    }

#undef PD_IFETCH
#undef PD_READ
#undef FP_GUARD
#undef NEXT
#undef NEXT_MODE
}
/* =============== end -pd interpreter tier =============== */

/* PD entries contain only decoded words, still reset between lifetimes. */

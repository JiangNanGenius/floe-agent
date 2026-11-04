/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* ESR_ELx exception syndrome construction. */
#ifndef A64_ESR_H
#define A64_ESR_H

#include "types.h"

/* Exception classes (ESR_ELx.EC, bits [31:26]). */
#define EC_UNKNOWN      0x00
#define EC_WFx          0x01
#define EC_FP_SIMD_TRAP 0x07   /* Access to SVE/SIMD/FP trapped (CPACR) */
#define EC_ILLEGAL      0x0E
#define EC_SVC64        0x15
#define EC_HVC64        0x16
#define EC_SMC64        0x17
#define EC_MSR_MRS      0x18   /* Trapped MSR/MRS/System insn */
#define EC_IABORT_LOWER 0x20
#define EC_IABORT_SAME  0x21
#define EC_PC_ALIGN     0x22
#define EC_DABORT_LOWER 0x24
#define EC_DABORT_SAME  0x25
#define EC_SP_ALIGN     0x26
#define EC_MOP          0x27   /* FEAT_MOPS memory copy/set state mismatch */
#define EC_BRK64        0x3C

/* Data/Instruction fault status codes (DFSC/IFSC, ISS bits [5:0]). */
#define FSC_TRANS_L0    0x04
#define FSC_TRANS_L1    0x05
#define FSC_TRANS_L2    0x06
#define FSC_TRANS_L3    0x07
#define FSC_ACCESS_L0   0x08
#define FSC_ACCESS_L1   0x09
#define FSC_ACCESS_L2   0x0A
#define FSC_ACCESS_L3   0x0B
#define FSC_PERM_L0     0x0C
#define FSC_PERM_L1     0x0D
#define FSC_PERM_L2     0x0E
#define FSC_PERM_L3     0x0F
#define FSC_EXTERNAL    0x10   /* synchronous external abort, not on table walk */
#define FSC_ALIGN       0x21

static inline u64 esr_make(unsigned ec, u32 iss) {
    return ((u64)(ec & 0x3f) << 26) | (1u << 25) /* IL: 32-bit insn */ | (iss & 0x1ffffff);
}

/* Build a data-abort ISS: WnR (write), and DFSC. */
static inline u32 iss_dabort(bool write, unsigned dfsc) {
    u32 iss = dfsc & 0x3f;
    if (write) iss |= (1u << 6);   /* WnR */
    return iss;
}

#endif /* A64_ESR_H */

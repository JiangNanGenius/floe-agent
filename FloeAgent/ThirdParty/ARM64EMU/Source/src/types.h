/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Common fixed-width types and small helpers. */
#ifndef A64_TYPES_H
#define A64_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>



typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t   s8;
typedef int16_t  s16;
typedef int32_t  s32;
typedef int64_t  s64;

/* 128-bit SIMD/FP register view. Host is little-endian (x86_64). */
typedef union {
    u8  b[16];
    u16 h[8];
    u32 s[4];
    u64 d[2];
} V128;

/* Sign-extend the low `bits` of x to 64 bits. */
static inline u64 sign_extend(u64 x, unsigned bits) {
    if (bits == 0 || bits >= 64) return x;
    u64 m = (u64)1 << (bits - 1);
    return (x ^ m) - m;
}

/* Replicate / ones helpers */
static inline u64 ones(unsigned n) { return n >= 64 ? ~(u64)0 : (((u64)1 << n) - 1); }

static inline u32 ror32(u32 x, unsigned n) { n &= 31; return n ? (x >> n) | (x << (32 - n)) : x; }
static inline u64 ror64(u64 x, unsigned n) { n &= 63; return n ? (x >> n) | (x << (64 - n)) : x; }

/* High 64 bits of a 64x64 multiply (SMULH/UMULH). Native __int128 where the
 * compiler has it (64-bit hosts); 32-bit limb arithmetic otherwise. */
static inline u64 umulh64(u64 a, u64 b) {
#ifdef __SIZEOF_INT128__
    return (u64)(((unsigned __int128)a * b) >> 64);
#else
    u64 al = (u32)a, ah = a >> 32, bl = (u32)b, bh = b >> 32;
    u64 ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;
    u64 mid = lh + (ll >> 32);
    u64 carry = (mid < lh) ? (1ULL << 32) : 0;
    mid += hl;
    if (mid < hl) carry += 1ULL << 32;
    return hh + (mid >> 32) + carry;
#endif
}
static inline s64 smulh64(s64 a, s64 b) {
#ifdef __SIZEOF_INT128__
    return (s64)(((__int128)a * b) >> 64);
#else
    u64 h = umulh64((u64)a, (u64)b);
    if (a < 0) h -= (u64)b;
    if (b < 0) h -= (u64)a;
    return (s64)h;
#endif
}

#endif /* A64_TYPES_H */

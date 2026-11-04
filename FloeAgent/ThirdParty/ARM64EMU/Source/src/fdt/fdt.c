/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Minimal flattened-device-tree editing.
 *
 * The tree the guest sees is a fixed blob (virt.dts -> virt_dtb.h, compiled from
 * a `-m 1024` reference machine), but one number in it is a property of the run
 * rather than of the modeled board: the size of guest RAM. This does that single
 * edit. Everything else in the tree is a constant of the machine we emulate.
 *
 * Not a libfdt: it only overwrites an existing property value with one of the
 * same length, so the blob's layout — and therefore every offset in its header —
 * is unchanged, and no allocation or resizing is involved. Nothing here trusts
 * the input: a --dtb override is an arbitrary file, so every walk step is bounded
 * by the header's own block sizes and by `len`. */
#include "fdt.h"
#include <string.h>

#define FDT_MAGIC       0xd00dfeedu
#define FDT_BEGIN_NODE  0x1u
#define FDT_END_NODE    0x2u
#define FDT_PROP        0x3u
#define FDT_NOP         0x4u
#define FDT_END         0x9u

#define FDT_HDR_SIZE    40      /* through size_dt_struct, the last field we read */

static u32 be32(const u8 *p) {
    return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | (u32)p[3];
}

static void put_be64(u8 *p, u64 v) {
    for (int i = 0; i < 8; i++) p[i] = (u8)(v >> (56 - 8 * i));
}

/* Property name at `off` into the strings block, or NULL if it runs past the
 * block's end (a truncated or hostile blob). */
static const char *prop_name(const u8 *fdt, u32 off_strings, u32 len_strings,
                             u32 off) {
    if (off >= len_strings) return NULL;
    const char *s = (const char *)fdt + off_strings + off;
    size_t max = len_strings - off;
    return strnlen(s, max) == max ? NULL : s;
}

int fdt_set_memory(void *blob, size_t len, u64 base, u64 size) {
    u8 *fdt = blob;
    if (!fdt || len < FDT_HDR_SIZE || be32(fdt) != FDT_MAGIC) return -1;

    u32 off_struct  = be32(fdt + 8);
    u32 off_strings = be32(fdt + 12);
    u32 len_strings = be32(fdt + 32);
    u32 len_struct  = be32(fdt + 36);
    if ((u64)off_struct + len_struct > len) return -1;
    if ((u64)off_strings + len_strings > len) return -1;

    u8 *p = fdt + off_struct, *end = p + len_struct;

    /* Open nodes (the root itself is depth 1), and the candidate /memory node:
     * its `reg` value and whether it declared device_type = "memory". The two
     * arrive in either order, so the decision waits for the node to close. */
    int depth = 0, cand_depth = -1;
    u8 *reg = NULL;
    bool is_memory = false;

    while (p + 4 <= end) {
        u32 tok = be32(p);
        p += 4;
        if (tok == FDT_NOP) continue;
        if (tok == FDT_END) break;

        if (tok == FDT_BEGIN_NODE) {
            const char *name = (const char *)p;
            size_t max = (size_t)(end - p);
            size_t n = strnlen(name, max);
            if (n == max) return -1;                  /* unterminated node name */
            p += (n + 4) & ~(size_t)3;                /* name + NUL, 4-aligned */
            depth++;
            /* A child of the root named "memory" or "memory@<addr>". */
            if (cand_depth < 0 && depth == 2 && !strncmp(name, "memory", 6) &&
                (name[6] == '\0' || name[6] == '@')) {
                cand_depth = depth;
                reg = NULL;
                is_memory = false;
            }
            continue;
        }

        if (tok == FDT_END_NODE) {
            if (depth == cand_depth) {
                if (is_memory && reg) {
                    put_be64(reg, base);
                    put_be64(reg + 8, size);
                    return 0;
                }
                cand_depth = -1;      /* not the node we want; keep looking */
            }
            if (--depth < 0) return -1;
            continue;
        }

        if (tok == FDT_PROP) {
            if (p + 8 > end) return -1;
            u32 plen = be32(p), noff = be32(p + 4);
            p += 8;
            if ((u64)plen > (u64)(end - p)) return -1;
            u8 *val = p;
            p += (plen + 3) & ~3u;
            if (p > end) return -1;                   /* padding ran off the end */
            if (depth != cand_depth) continue;
            const char *name = prop_name(fdt, off_strings, len_strings, noff);
            if (!name) return -1;
            /* reg is only patchable as <#address-cells=2, #size-cells=2>, which
             * is what a 16-byte value means and what the virt tree uses. */
            if (!strcmp(name, "reg") && plen == 16) reg = val;
            else if (!strcmp(name, "device_type") && plen == 7 &&
                     !memcmp(val, "memory", 7)) is_memory = true;
            continue;
        }

        return -1;                                    /* token we don't know */
    }
    return -1;                                        /* no /memory node found */
}

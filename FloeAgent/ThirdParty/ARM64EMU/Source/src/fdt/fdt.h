/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Minimal in-place flattened-device-tree edits (see fdt.c). */
#ifndef A64_FDT_H
#define A64_FDT_H

#include "../types.h"
#include <stddef.h>

/* Rewrite the /memory node's `reg` to <base size> in the flattened device tree
 * `blob` (`len` bytes, writable). Returns 0 when patched, -1 when the blob is
 * not a device tree this can edit or carries no /memory node with a 64-bit
 * address/size `reg` to patch — in which case `blob` is left untouched. */
int fdt_set_memory(void *blob, size_t len, u64 base, u64 size);

#endif /* A64_FDT_H */

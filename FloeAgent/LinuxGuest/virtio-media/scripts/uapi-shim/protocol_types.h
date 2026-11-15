/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0+ */
/* The unmodified kernel protocol uses internal short integer names. Give
 * userspace ABI probes those names from the exported Linux UAPI types. */
#ifndef FLOE_PROTOCOL_USER_TYPES_H
#define FLOE_PROTOCOL_USER_TYPES_H
#include <linux/types.h>
typedef __u32 u32;
typedef __u64 u64;
_Static_assert(sizeof(u32) == 4 && sizeof(u64) == 8, "kernel integer ABI");
#endif

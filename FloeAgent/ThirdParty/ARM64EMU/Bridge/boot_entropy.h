/* SPDX-License-Identifier: MPL-2.0 */
#ifndef QUALIFICATION_BOOT_ENTROPY_H
#define QUALIFICATION_BOOT_ENTROPY_H
#include <stddef.h>
#include <stdint.h>
#include "machine.h"
/* Returns 0 and a caller-owned private tree, or an error and NULL. No seed
 * bytes, hashes, or derived values are logged. Never changes the template. */
int qualification_boot_dtb_copy(const void *source, size_t length,
                                uint64_t base, uint64_t size, unsigned char **result);
void qualification_boot_dtb_release(unsigned char *tree, size_t length);
int qualification_place_boot_dtb(Machine *machine, const void *source, size_t length);
#ifdef QUALIFICATION_ENTROPY_TESTING
/* Test-only fault injection. This symbol is absent from the shipping CLI. */
typedef int (*QualificationTestRandom)(unsigned char *, size_t, void *);
int qualification_test_boot_dtb(const void *, size_t, uint64_t, uint64_t,
                                unsigned char **, QualificationTestRandom, void *);
#endif
#endif

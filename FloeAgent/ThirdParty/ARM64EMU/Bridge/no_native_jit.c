/* SPDX-License-Identifier: MPL-2.0 */
#include "mmu.h"

/* The only retained JIT-named reference is a coherence hook from the common
 * memory bus. No translated code exists in this build; mmu.c's bitmap remains
 * NULL. The unchanged predecoder fetches the current guest word on every step
 * and checks its cached decode, so this hook must not invalidate guest data. */
void jit_invalidate_phys_range(u64 pa, u64 len) { (void)pa; (void)len; }

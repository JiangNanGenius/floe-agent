/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* System register / SMCCC hooks. Implemented in M2 (sysreg.c) and M3 (psci.c).
 * Declared weak so M1 links standalone. */
#ifndef A64_SYSREG_H
#define A64_SYSREG_H

#include "cpu.h"

/* Execute a System-instruction-group encoding (MSR/MRS/SYS/MSR-imm). */
void sysreg_exec(CPU *c, u32 insn) __attribute__((weak));

/* Initialise ID/feature registers at reset. */
void sysreg_init(CPU *c) __attribute__((weak));

/* Handle an SMC/HVC conduit call (PSCI / SMCCC). Returns true if handled. */
bool smccc_conduit(CPU *c, bool is_hvc) __attribute__((weak));

#endif /* A64_SYSREG_H */

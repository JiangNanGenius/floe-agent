/* SwiftPM compiles each source file exactly once, but upstream builds
 * riscv_cpu.c twice with -DMAX_XLEN=32/64 (see adapter/Makefile). These
 * wrappers reproduce that: the engine copy is excluded from the target and
 * included here with the width define set. Pristine source is unmodified. */
#define MAX_XLEN 32
#include "../engine/riscv_cpu.c"

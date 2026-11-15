#ifndef LINUX_BITS_SHIM
#define LINUX_BITS_SHIM
#ifndef BIT
#define BIT(nr) (1UL << (nr))
#define BIT_ULL(nr) (1ULL << (nr))
#endif
#endif

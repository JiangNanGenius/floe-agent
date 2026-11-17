/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Host portability shim: provide <byteswap.h> for Kbuild host tools on Darwin.
 *
 * scripts/mod/modpost.h includes the glibc header <byteswap.h>, which macOS
 * does not ship. glibc's API is the bswap_16/32/64 macros; clang and gcc
 * both provide __builtin_bswap* since 4.8, so this is behaviour-identical
 * for the host tools. Injected via KBUILD_HOSTCFLAGS; kernel source tree
 * stays untouched.
 */
#ifndef FVM_HOST_COMPAT_BYTESWAP_H
#define FVM_HOST_COMPAT_BYTESWAP_H

#define bswap_16(x) __builtin_bswap16((uint16_t)(x))
#define bswap_32(x) __builtin_bswap32((uint32_t)(x))
#define bswap_64(x) __builtin_bswap64((uint64_t)(x))

#endif /* FVM_HOST_COMPAT_BYTESWAP_H */

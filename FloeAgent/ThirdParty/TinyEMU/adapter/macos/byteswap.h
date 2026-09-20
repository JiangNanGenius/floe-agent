/* Replacement for glibc <byteswap.h> for macOS local smoke builds of
 * TinyEMU 2019-12-21. Added via -I (build-flag-only); pristine TinyEMU
 * sources are NOT modified. Primary supported target remains Linux/glibc.
 */
#ifndef TINYEMU_MACOS_BYTESWAP_H
#define TINYEMU_MACOS_BYTESWAP_H
#include <libkern/OSByteOrder.h>
#define bswap_16(x) OSSwapInt16(x)
#define bswap_32(x) OSSwapInt32(x)
#define bswap_64(x) OSSwapInt64(x)
#endif

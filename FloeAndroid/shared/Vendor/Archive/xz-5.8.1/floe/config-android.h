/* floe config-android/macOS pinned macro set — generated once from the
 * verified xz-5.8.1 CMake build (XZ_THREADS=no, static, Release) and frozen.
 * Reproduce/verify: floe/verify-compile.sh (re-runs both CMake configs and
 * diffs this file's macro sets against compile_commands.json).
 * License of the underlying library: 0BSD (see ../COPYING.0BSD).
 */
#ifndef FLOE_LZMA_CONFIG_ANDROID_H
#define FLOE_LZMA_CONFIG_ANDROID_H
#define HAVE_ARM64_CRC32
#define HAVE_CHECK_CRC32
#define HAVE_CHECK_CRC64
#define HAVE_CHECK_SHA256
#define HAVE_CLOCK_GETTIME
#define HAVE_CLOCK_MONOTONIC
#define HAVE_DECODERS
#define HAVE_DECODER_ARM
#define HAVE_DECODER_ARM64
#define HAVE_DECODER_ARMTHUMB
#define HAVE_DECODER_DELTA
#define HAVE_DECODER_IA64
#define HAVE_DECODER_LZMA1
#define HAVE_DECODER_LZMA2
#define HAVE_DECODER_POWERPC
#define HAVE_DECODER_RISCV
#define HAVE_DECODER_SPARC
#define HAVE_DECODER_X86
#define HAVE_ENCODERS
#define HAVE_ENCODER_ARM
#define HAVE_ENCODER_ARM64
#define HAVE_ENCODER_ARMTHUMB
#define HAVE_ENCODER_DELTA
#define HAVE_ENCODER_IA64
#define HAVE_ENCODER_LZMA1
#define HAVE_ENCODER_LZMA2
#define HAVE_ENCODER_POWERPC
#define HAVE_ENCODER_RISCV
#define HAVE_ENCODER_SPARC
#define HAVE_ENCODER_X86
#define HAVE_FUNC_ATTRIBUTE_CONSTRUCTOR
#define HAVE_INTTYPES_H
#define HAVE_LZIP_DECODER
#define HAVE_MF_BT2
#define HAVE_MF_BT3
#define HAVE_MF_BT4
#define HAVE_MF_HC3
#define HAVE_MF_HC4
#define HAVE_STDBOOL_H
#define HAVE_STDINT_H
#define HAVE_VISIBILITY 0
#define HAVE__BOOL
#define HAVE___BUILTIN_ASSUME_ALIGNED
#define HAVE___BUILTIN_BSWAPXX
#define NDEBUG
#define PACKAGE_BUGREPORT "xz@tukaani.org"
#define PACKAGE_NAME "XZ Utils"
#define PACKAGE_URL "https://tukaani.org/xz/"
#define TUKLIB_FAST_UNALIGNED_ACCESS
#define TUKLIB_PHYSMEM_SYSCONF
#define TUKLIB_SYMBOL_PREFIX lzma_
#define _ALL_SOURCE
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#define _NETBSD_SOURCE
#define _OPENBSD_SOURCE
#define _POSIX_PTHREAD_SEMANTICS
#define _TANDEM_SOURCE
#define __EXTENSIONS__
// Android-only (production):
#define ANDROID
#define HAVE_GETAUXVAL
#define TUKLIB_CPUCORES_SCHED_GETAFFINITY
#define _FORTIFY_SOURCE 2
#endif /* FLOE_LZMA_CONFIG_ANDROID_H */

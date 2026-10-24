#if defined(HAVE_CONFIG_H) && !defined(FLOE_LZMA_CONFIG_WRAPPER_H)
#define FLOE_LZMA_CONFIG_WRAPPER_H
/* Platform selector for the pinned liblzma 5.8.1 macro sets (SwiftPM passes
 * only -DHAVE_CONFIG_H; NDK/Apple clang define __ANDROID__/__APPLE__). */
#if defined(__APPLE__)
#include "config-macos.h"
#elif defined(__ANDROID__)
#include "config-android.h"
#else
#error "liblzma 5.8.1 vendored build is pinned for Apple host tests and Android arm64 only; add a reviewed platform config or extend the verified macro sets"
#endif
#endif

/*
 * FLOE-OVERLAY 20261024-1 (lane job-7320d971f5df43c0, G04-R1, Main-approved):
 * gated wrapper translation unit for upstream common_crypto.c.
 *
 * Why this file exists: upstream libgit2 relies on CMake to exclude
 * src/util/hash/common_crypto.c from non-Apple builds. The vendored SwiftPM
 * overlay compiles a static source list (src/util as a whole), which cannot
 * select sources per target platform without host-evaluated manifest logic
 * (forbidden for this android28 cross build). Upstream common_crypto.h
 * includes <CommonCrypto/CommonDigest.h> BEFORE the GIT_SHA1_COMMON_CRYPTO /
 * GIT_SHA256_COMMON_CRYPTO backend guards, so compiling the original .c
 * unconditionally is fatal on Bionic (no CommonCrypto).
 *
 * Semantics: no upstream bytes are modified. This wrapper re-includes the
 * ORIGINAL common_crypto.c verbatim exactly when one of the upstream
 * CommonCrypto backend macros is defined (Apple host qualification cohort —
 * byte-for-byte the same code, headers and settings as compiling
 * common_crypto.c directly), and is an empty translation unit otherwise
 * (Android: GIT_SHA1_BUILTIN/GIT_SHA256_BUILTIN hashes, selected in
 * hash/sha.h without ever including common_crypto.h).
 *
 * Package.swift (Main-owned common graph) excludes
 * "src/util/hash/common_crypto.c" from the libgit2 target so this wrapper
 * replaces it 1:1. The supported backend set is not narrowed on any
 * platform.
 */

#if defined(GIT_SHA1_COMMON_CRYPTO) || defined(GIT_SHA256_COMMON_CRYPTO)
#include "common_crypto.c"
#endif

/*
 * FLOE-OVERLAY 20261024-2 (lane job-6975418b406c4035, G04-R1 host cohort;
 * same Main-approved gated-wrapper pattern as floe_common_crypto.c
 * 20261024-1): gated translation unit for upstream builtin.c.
 *
 * Why this file exists: upstream libgit2's CMake compiles
 * src/util/hash/builtin.c ONLY when the builtin SHA256 backend
 * (GIT_SHA256_BUILTIN) is selected. The vendored SwiftPM overlay compiles a
 * static source list (src/util as a whole), which cannot select sources per
 * target platform without host-evaluated manifest logic (forbidden for this
 * android28 cross build). builtin.h defines `struct git_hash_sha256_ctx {
 * SHA256Context c; }` unconditionally and builtin.c defines
 * git_hash_sha256_{global_init,ctx_init,ctx_cleanup,init,update,final}
 * unconditionally, so direct compilation collides with the CommonCrypto
 * backend (git_hash_sha256_ctx redefinition at compile time and duplicate
 * git_hash_sha256_* symbols at link time) on Apple hosts, where the
 * upstream Apple define set selects GIT_SHA256_COMMON_CRYPTO instead.
 *
 * Semantics: no upstream bytes are modified. This wrapper re-includes the
 * ORIGINAL builtin.c verbatim exactly when GIT_SHA256_BUILTIN is defined
 * (Android: aarch64-unknown-linux-android28 — byte-for-byte the same code,
 * headers and settings as compiling builtin.c directly, so the accepted
 * Core09 hash behavior is unchanged) and is an empty translation unit
 * otherwise (Apple host qualification cohort — CommonCrypto SHA256, exactly
 * the upstream source set for that branch).
 *
 * Package.swift excludes "src/util/hash/builtin.c" from the libgit2 target
 * so this wrapper replaces it 1:1. The supported backend set is not
 * narrowed on any platform.
 */

#if defined(GIT_SHA256_BUILTIN)
#include "builtin.c"
#endif

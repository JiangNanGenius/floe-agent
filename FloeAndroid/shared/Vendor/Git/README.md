# Vendor/Git — native Git dependency closure (Android overlay)

Lane `job-6cb7731a07774f01` (G04-R1). Purpose: make the ORIGINAL Swift
`FloeGit` services (`Sources/FloeGit`) buildable for `aarch64-unknown-linux-android28`
on the pinned Swift 6.4.1 Android SDK + NDK 30 without a Linux guest, per Main
decision D2 (`r1/entry/MAIN_ARCHITECTURE_DECISION_02.json`): native
libgit2/SwiftGitX preserves Git when no environment is installed; guest `git`
is never a substitute.

## Contents (source-only; no binaries, no nested `.git`)

| Tree | Pin | License (taken) | Role |
| --- | --- | --- | --- |
| `libgit2/` | ibrahimcetin/libgit2 `52287b0914f300f916b58fec80e13d8dd8f6824f` (tag 1.9.2) | GPL-2.0-only WITH libgit2 linking exception | Git engine C sources compiled into `libFloeAndroidCore.so` |
| `swiftgitx/` | ibrahimcetin/SwiftGitX `fcfb71e3dcbbaa70d120b98b7477ce173074aec3` (tag 0.4.0) | MIT | Swift wrapper module imported by `LocalGitService` |
| `mbedtls/` | Mbed-TLS **3.6.7** LTS tarball, sha256 `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6` (verified == official release body) | Apache-2.0 (dual with GPL-2.0-or-later; we take Apache-2.0) | Android TLS backend for libgit2 (`GIT_HTTPS_MBEDTLS`) |

`PINS.json` carries the full pin/license/exclusion facts; `VENDOR_FILE_HASHES.sha256`
hashes every vendored file (951 files, manifest sha256 `4725b4b2b1a494942a11f011c71fc06cf4b7c9869f8bf17f48ae95adc3a71a39`;
the previous 950-file manifest `c5abefcaac976c2ad8e4f8dfd6b60375dd84a9ce40b3ea1287edda261057f8d5` is superseded
by the gated wrapper TU recorded below, lane `job-7320d971f5df43c0`).

## Fidelity

* Every retained libgit2 `.c/.h` and metadata file is byte-identical to the pinned
  revision (verified with `git hash-object` against `git ls-tree -r` — 589/589 matched).
* Every retained SwiftGitX file is byte-identical (85/85 matched).
* Every retained mbedTLS `.c/.h` + `LICENSE` is byte-identical to the official
  3.6.7 release tarball (271 .c/.h + LICENSE, 0 mismatches).
* No upstream `.c/.h` byte was edited. The added overlay file
  `libgit2/src/util/hash/floe_common_crypto.c`
  (lane `job-7320d971f5df43c0`, Main-approved 20261024): a gated translation
  unit that `#include`s the ORIGINAL `common_crypto.c` verbatim only when
  `GIT_SHA1_COMMON_CRYPTO`/`GIT_SHA256_COMMON_CRYPTO` is defined (Apple host
  cohort — identical code path) and compiles empty on Android (BUILTIN
  hashes), replacing direct compilation of that upstream file because static
  SwiftPM source lists cannot select it per platform. `Package.swift`
  (Main-owned) excludes the original `common_crypto.c` so the supported
  backend set is unchanged on every platform.
* All other non-upstream content inside the pinned trees is limited to
  `mbedtls/floe-config/floe_android_mbedtls_config.h`
  (the lane `job-6cb7731a07774f01` hunk):
  a full copy of the release's default config header with exactly one documented,
  inert hunk (`FLOE-ANDROID-PATCH 20261024-1`) that disables `MBEDTLS_SSL_PROTO_TLS1_3`.
  libgit2 1.9.2's mbedTLS backend never calls `psa_crypto_init()`, so TLS 1.3 would
  advertise but fail; TLS 1.2 with libgit2's ECDHE/AEAD suite list remains the
  negotiated ceiling (GitHub requires TLS 1.2+; no promised connectivity is lost).
  An upgrade path (2-line patch calling `psa_crypto_init` in
  `streams/mbedtls.c` global init) is noted but not taken, keeping all C sources unpatched.
* Export deletions are build-system inputs only (CMakeLists, `.in`, `.rc`, tests,
  examples, fuzzers, CI, docs, upstream host-evaluated `Package.swift`s) — see
  `PINS.json.exportExclusions`.

## Why upstream packages cannot be consumed directly on Android

Upstream `libgit2`'s own `Package.swift` chooses Apple vs non-Apple configuration
with **host-evaluated** `#if os(macOS)`; an android28 cross-build driven from a
macOS host compiles SecureTransport/CommonCrypto code for the Android target. Its
non-Apple branch assumes glibc + runtime-dlopen OpenSSL — Android exposes no
public system `libssl`/`libcrypto`. This vendor tree replaces only the *manifest
layer*: the proposed targets in `PROPOSED_PACKAGE_SNIPPET.swift` (lane handoff)
use per-platform `.when(platforms:)` settings, compile from source inside the
same SwiftPM native build (`swift build --build-system native --swift-sdk
swift-6.4.1-RELEASE_android --triple aarch64-unknown-linux-android28`), need no
external library search paths, no CMake, no prebuilt binaries, and add no new
toolchain installs (NDK 30 clang provides the C compiler; `-z max-page-size=16384`
from the existing build script keeps the 16 KiB ELF property).

## Platform backend summary (Android target)

* HTTPS: libgit2 builtin HTTP client + mbedTLS stream backend (TLS ≤1.2).
  *CA trust correction (lane `job-f74b2a485e9a4434`, verified against the
  pinned sources, superseding this README's earlier note):* the vendored
  libgit2 1.9.2 never reads `http.sslVerify`, `http.sslCAInfo` or
  `http.sslCAPath` from ANY config layer (grep of `src/` shows only
  `http.followRedirects`, `http.proxy`, `remote.<name>.proxy` and the
  URL-scoped `http.<url>.proxy` are read), so per-repo CA overrides do NOT
  exist in this build and repository config cannot disable TLS
  verification (`streams/mbedtls.c` verifies every handshake:
  `verify_server_cert` fails the connection on any non-zero verify
  result, and the FloeGit mirrors register no certificate_check
  callback). Trust locations can therefore only be installed through
  `GIT_OPT_SET_SSL_CERT_LOCATIONS` — the platform-trust seam below. The
  Android build must NOT predefine `GIT_DEFAULT_CERT_LOCATION` (the fixed
  legacy `/system/etc/security/cacerts` path is not proof of the current
  OS trust on API 33→37 devices; Main's Package recipe delta from this
  lane removes that define), so no CA chain exists until the seam
  installs one inside a remote operation's runtime epoch, and network Git
  is honestly unavailable until then. Offline status/diff/stage/commit/
  merge is untouched by any of this.
* Redirect policy is pinned at the transport options layer: every
  clone/fetch/push sets `follow_redirects = GIT_REMOTE_REDIRECT_NONE`
  (value 1 — value 0 means "unspecified" and lets the repository's own
  `http.followRedirects` widen the policy, `src/libgit2/remote.c`), which
  makes `util/net.c git_net_url_apply_redirect` reject every cross-host
  redirect (same-HTTPS-host redirects keep working; scheme downgrades are
  always rejected), and the credential callback additionally fails closed
  on any URL outside the HTTPS github.com contract
  (`Sources/FloeGit/GitRemoteTrust.swift` documents the full chain).

## Floe-authored overlay files (non-upstream, provenance in `FLOE_OVERLAY_HASHES.sha256`)

| File | Purpose |
| --- | --- |
| `mbedtls/floe-config/floe_android_mbedtls_config.h` | documented single TLS-1.3 hunk (see Fidelity) |
| `floe-shim/include/floe_git_trust.h`, `floe-shim/floe_git_trust.c` | narrow C shim (new SwiftPM target `FloeGitShim`, dependency delta in the lane handoff): the ONLY non-variadic route for Swift to reach `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, …)`, refuses the (NULL, NULL) clear that would abort inside `git_mbedtls__set_cert_location`'s assert, and pins the `GIT_REMOTE_REDIRECT_NONE` redirect policy constants for fetch/push/clone option structs against the vendored headers. No other logic; upstream trees stay byte-identical. |

`Sources/FloeGit/GitRemoteTrust.swift` (native verifier/installer ports) and
`app/src/main/kotlin/com/floe/android/host/GitPlatformTrust.kt` (platform
export from the public `TrustManagerFactory` trust, per
<https://source.android.com/docs/core/ota/modular-system/conscrypt>) consume
the shim; the typed test source is `Tests/FloeGitTests/GitRemoteTrustSeamTests.swift`.

* Compression/regex/xdiff/http-parser: libgit2 bundled `deps/` sources (identical
  to the upstream SwiftPM path).
* Hashes: builtin collision-detecting SHA1 (sha1dc) + rfc6234 SHA256 — the same
  choice the upstream Linux branch makes; no Apple-only CommonCrypto dependency.
* SSH transport and NTLM auth are NOT compiled on Android: FloeGit's own product
  contract (unchanged) restricts remotes to HTTPS `github.com`
  (`LocalGitService.validateRemote`), so no promised protocol is disabled;
  the flag delta is recorded in `PINS.json`/`SOURCE_READY.json`.
* Apple platforms keep the exact upstream define set (SecureTransport +
  CommonCrypto + iconv), so the host qualification cohort behaves like iOS.

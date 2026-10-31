Embedded Shizuku primitive port — Floe Agent
===========================================

This product includes software adapted from RikkaApps/Shizuku
(https://github.com/RikkaApps/Shizuku), revision
b844bc491f1790c72328e1a8e5b2349f8978f0ea, licensed under the Apache License,
Version 2.0. A copy of that license is in LICENSE.

It also references the architecture/protocol of RikkaApps/Shizuku-API
(https://github.com/RikkaApps/Shizuku-API), revision
a27f6e4151ba7b39965ca47edb2bf0aeed7102e5, licensed under the MIT License. A copy
of that license is in LICENSE-Shizuku-API. No Shizuku-API source file is copied
into this module at this revision.

Native build dependencies (pinned Gradle/Prefab artifacts)
----------------------------------------------------------

The Floe Full APK bundles the executable and shared library built by this
module. Their build links the following pinned artifacts. The artifact AARs do
not embed license files, so the real upstream license texts were taken
byte-for-byte from the exact pinned upstream trees and are shipped next to this
notice in the Full-only legal assets:

| Coordinate | Upstream build provenance | Bundled license files |
| --- | --- | --- |
| `io.github.vvb2060.ndk:boringssl:20250114` | `vvb2060/BoringSSL_Android` tag `20250114` (commit `20b87e2e25a793531c9cd651c629c62976b42e2b`), BoringSSL submodule commit `571a7432a19592c620fa316abde47770dad4f82b` = `google/boringssl` tag `0.20250114.0` | `BoringSSL-LICENSE.txt` (upstream `LICENSE`, git blob `3aa5aa6911da87a6dd95105c27b0e0aed946970c`), `BoringSSL-fiat-LICENSE.txt` (upstream `third_party/fiat/LICENSE`, git blob `70cae03773c68f43a4adc7b1b0421915f5527f13`) |
| `org.lsposed.libcxx:libcxx:27.0.12077973` | `LSPosed/prefab-libcxx` tag `27.0.12077973` (commit `4ba72efedb6d6bee40ad3ac7f484ecdbb1a3ea5c`), embedding LLVM libc++ and libc++abi sources | `libcxx-LICENSE.TXT` (upstream `cxx/jni/libcxx/LICENSE.TXT`, git blob `e159d283443f92ac78b964d2bccebe8f95d5d445`), `libcxxabi-LICENSE.TXT` (upstream `cxx/jni/libcxxabi/LICENSE.TXT`, git blob `b75c0441bcd5be32b5a07e2a1ffc7e67b6d99f16`) |

The `libcxx.a` prefab archive contains both libc++ and libc++abi objects, so
both LLVM license texts apply. BoringSSL's `LICENSE` covers the OpenSSL/ISC
terms and directs users to `third_party/` terms; the static `libcrypto_static.a`
used here contains the fiat-crypto field-arithmetic objects
(`fiat_curve25519_*`, `fiat_p256_*`), so the fiat MIT text is included too.
Test-only BoringSSL `third_party` trees (googletest, wycheproof) are not
compiled into the shipped libraries and are not part of this notice.

The license files above are exact copies of the named upstream files; they are
not summarised, reworded or invented. Upstream file hashes are recorded in
`UPSTREAM.json`.

Modification notice (Apache-2.0 section 4(b)): the Floe-specific changes to the
Shizuku-derived files are listed in README.md and UPSTREAM.json. Files that were
copied unchanged retain their original copyright and license headers.

No Shizuku manager application, Shizuku provider, Shizuku API AAR, Shizuku
service name or third-party manager package is redistributed or required by this
module.

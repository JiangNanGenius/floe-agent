# Embedded Shizuku primitives (Floe-owned subset)

This directory is a **source port**, not a bundled Shizuku manager. It exists so
one Floe Full APK can (a) pair with the device's own wireless ADB endpoint using
the ADB pairing protocol, (b) connect to the local ADB daemon and launch the
Floe-owned embedded system service, and (c) expose the BoringSSL SPAKE2 /
AES-128-GCM pairing primitives used by the Floe client.

It deliberately contains **no** Shizuku manager UI, no `moe.shizuku.privileged.api`
package, no global `shizuku` binder/service, no `transactRemote` API, and no
prebuilt executable, DEX or opaque native blob.

## Upstream pins (immutable)

| Component | Repository | Revision |
| --- | --- | --- |
| Shizuku (manager, starter, JNI pairing, server architecture reference) | `https://github.com/RikkaApps/Shizuku` | `b844bc491f1790c72328e1a8e5b2349f8978f0ea` |
| Shizuku-API (public protocol/architecture reference; no code copied yet) | `https://github.com/RikkaApps/Shizuku-API` | `a27f6e4151ba7b39965ca47edb2bf0aeed7102e5` |

License: Shizuku is Apache-2.0 (see `LICENSE`); Shizuku-API is MIT (see
`LICENSE-Shizuku-API`). Exact upstream paths and the Floe modifications are
listed in `UPSTREAM.json` and below.

## Selection (why these files, not the whole app)

Only components needed by the Floe one-APK local pairing/starter path are
adapted:

| Floe file | Upstream origin | Change |
| --- | --- | --- |
| `src/main/java/moe/shizuku/pairing/PairingWire.kt` | `manager/.../adb/AdbPairingClient.kt` (packet classes) | extracted bounded codec, strict version/type/length checks, no logs |
| `src/main/java/moe/shizuku/pairing/AdbPairingClient.kt` | `manager/.../adb/AdbPairingClient.kt` | injected public/native TLS exporter, typed outcomes, timeouts, code wiped, no peer-info logging |
| `src/main/java/moe/shizuku/pairing/NativePairingContext.kt` + `src/main/cpp/floe_pairing_jni.cpp` | `manager/src/main/jni/adb_pairing.cpp` | renamed JNI class, bounded inputs, nonce-wrap refusal, no secret logging |
| `src/main/java/moe/shizuku/pairing/AdbIdentity.kt` | `manager/.../adb/AdbKey.kt` | host-supplied key material; SHA1withRSA ADB token signature; TLS key/trust managers |
| `src/main/java/moe/shizuku/pairing/AdbPublicKey.kt` | `AdbKey.kt` (`android_pubkey` encoding) | pure, testable, no logging |
| `src/main/java/moe/shizuku/pairing/SelfSignedCertificate.kt` | `AdbKey.kt` (BouncyCastle cert builder) | Floe DER implementation, no BouncyCastle dependency |
| `src/main/java/moe/shizuku/pairing/AdbIdentityCodec.kt` | Floe-authored | bounded storage envelope for approved credential storage |
| `src/main/java/moe/shizuku/pairing/KeyingMaterialExporter.kt` | `AdbPairingClient.kt` hidden Conscrypt call | API 31+ public `SSLSockets.exportKeyingMaterial`; API 30 explicit reflective Conscrypt compatibility; unsupported below 30 |
| `src/main/java/moe/shizuku/adb/*` | `manager/.../adb/AdbClient.kt`, `AdbMessage.kt`, `AdbProtocol.kt` | no logs, bounded payloads/output, typed failures |
| `src/main/java/moe/shizuku/starter/StarterCommand.kt` | Floe-authored | validates and quotes the only allowed starter/root launch commands |
| `src/main/cpp/floe_starter.cpp` | `manager/src/main/jni/starter.cpp` | shell-UID-only ADB launcher, whitelisted args, exact-PID verified replacement only, no scan/name kill, no root path, no token output |
| `src/main/cpp/floe_starter_ownership.{h,cpp}` | Floe-authored | strict PID parser and exact-PID recheck; models the real nice-name-only `/proc` shape; never scans processes |
| `src/test/cpp/floe_starter_ownership_test.cpp` | Floe-authored | host unit test for the stale-PID policy and the actual nice-name-only argv shape; not packaged into the AAR |
| `src/main/cpp/upstream/misc.cpp`, `misc.h`, `logging.h` | `manager/src/main/jni/` | copied unchanged |

## Ownership and replacement

Android's `app_process` rewrites the entire argument block when it applies
`--nice-name`: `AndroidRuntime::setArgv0()` memsets the block and writes only the
nice name. A real running server's `/proc/<pid>/cmdline` therefore contains only
`floe_adb_server`; the package, caller UID, server class and token are gone. A
command-line identity match is impossible, and name-only replacement is not
ownership.

Replacement is instead an App/IPC-owned lifecycle:

1. The App verifies an existing published binder through its `describe()`
   identity: same package, signing, protocol, ADB mode, server UID 2000 and the
   exact published PID.
2. If it is already compatible, the App adopts it and does not launch a second
   server.
3. If it is a verified older Floe server, the App calls its typed
   `stopOwnedService(expectedPid)`; only after that may it pass the same exact
   PID as `--replace-pid` so the native starter can finish a lingering process.
4. The native starter rechecks only that PID's shell UID 2000 and current
   `floe_adb_server` nice name, then kills the exact PID. It never scans `/proc`,
   never matches by name and has no `pkill`/`killall`/wildcard termination.
5. Any unverified binder or PID fails closed: the App does not launch a
   duplicate. Other Floe variants, other Android users, an external Shizuku
   manager and unrelated processes are never touched. The root server has a
   separate name and is not part of this ADB replacement path.

`StarterCommand.adbLaunch(..., replacePid: Int? = null)` is source-compatible;
existing callers keep working. The App-side verify/stop/launch wiring is a
precise private Root controller patch handed to Main, because the Root
controller is outside this vendor scope. The vendor module compiles and tests
the native/command pieces; Main owns applying that patch and actual device
verification.


Integration review notes record Main's verified public-SDK TLS-exporter facts (`android-37.0/android.jar`, `SSLSockets.exportKeyingMaterial`
since API 31). API 30 keeps the pinned upstream Conscrypt reflective path; no
silent fallback to an API 31 call, and no hidden Conscrypt use on API 31+.

## Native build contract (Main)

- NDK `30.0.16248370`, CMake `3.22.1` (see `FloeAndroid/TOOLCHAINS.md`).
- Prefab dependencies: `io.github.vvb2060.ndk:boringssl:20250114`,
  `org.lsposed.libcxx:libcxx:27.0.12077973` (exact upstream coordinates).
- Targets: `libfloe_starter.so` (executable) and `libfloe_adb_pairing.so`.
- All link flags set `-Wl,-z,max-page-size=16384` and
  `-Wl,-z,common-page-size=16384`; verify the final APK with
  `llvm-readelf -lW` and `zipalign -c -P 16`.
- The Full App must package native libraries with
  `packaging.jniLibs.useLegacyPackaging = true` (or
  `android:extractNativeLibs="true"`) so the starter executable is extracted to
  `nativeLibraryDir` and executable by `adb shell`.
- The Play variant must not include this module, its native libraries or the
  provider/DEX that references them.

## Bundled native dependency licenses (Full-only assets)

The pinned Prefab AARs contain no license files. Their exact upstream licenses
are copied byte-for-byte from the pinned revisions and packaged under
`src/main/assets/legal/embedded-shizuku/` (Full-only), next to `NOTICE.md`:

| Artifact | Upstream pin | License file(s) |
| --- | --- | --- |
| `io.github.vvb2060.ndk:boringssl:20250114` | `vvb2060/BoringSSL_Android@20b87e2e25a793531c9cd651c629c62976b42e2b` (tag `20250114`) → `google/boringssl@571a7432a19592c620fa316abde47770dad4f82b` (tag `0.20250114.0`) | `BoringSSL-LICENSE.txt`, `BoringSSL-fiat-LICENSE.txt` |
| `org.lsposed.libcxx:libcxx:27.0.12077973` | `LSPosed/prefab-libcxx@4ba72efedb6d6bee40ad3ac7f484ecdbb1a3ea5c` (tag `27.0.12077973`), embedding LLVM libc++/libc++abi | `libcxx-LICENSE.TXT`, `libcxxabi-LICENSE.TXT` |

`libcxx.a` contains both libc++ and libc++abi objects; `libcrypto_static.a`
contains the fiat-crypto field-arithmetic objects. Exact blob/sha256 hashes are
recorded in `UPSTREAM.json` and `NOTICE.md`. No license text is invented or
paraphrased.

## Security boundaries

- Pairing is explicit user action with a 6-digit code held in RAM; no pairing is
  attempted on app start and no insecure TCP/5555 mode is introduced.
- The ADB identity private key is only serialized through the App's existing
  approved `CredentialStore`; this module has no plaintext preference/file
  fallback and logs no key, code or peer-info bytes.
- The service identity is Floe-specific; the binder descriptor, provider
  authority and process names do not collide with an external Shizuku manager.
- This module does not grant root, does not run a model-provided command and
  does not expose a raw `transact`/shell API.

## Runtime status

This lane assembled the vendor module's release AAR through the real installed
Gradle 9.6.0 / AGP 9.4.0 / NDK 30.0.16248370 boundary, ran the focused JVM tests
and the host stale-PID policy test, and inspected the packaged ARM64 ELF files.
No App/Full APK, device pairing, service start, stale-service stop or Root grant
was exercised. AAR and native proof is not device pairing/start proof; that
acceptance remains with the App integration owner.

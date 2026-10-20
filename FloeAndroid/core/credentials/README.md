# :core:credentials

AndroidKeyStore-backed credential storage for Floe Android. This module implements the
existing stable contract `com.floe.android.contracts.CredentialStore`; it does not change
the contract, add an App dependency, a business database, runtime wiring or profile UI.

**Stage status: component build and JVM tests pass; device execution is pending.** The
debug/release AARs, debug AndroidTest APK and instrumentation sources compile from the
module lock; the pure-JVM codec tests pass. AndroidKeyStore instrumentation and the
host -> Android interop harness have not been executed by this component stage. The
serialized primary device stage owns those runs. The current revision fixes the reviewed
coroutine-lock, caller-input freeze, fail-closed metadata, one-shot consumption and debug
RSA-keypair-generation gaps.

## API

```kotlin
val store: CredentialStore = AndroidKeystoreCredentialStore(context, "floe.providers")
val value: ByteArray? = store.read("provider.openai.api-key") // null only if absent
store.write("provider.openai.api-key", secretBytes)
store.delete("provider.openai.api-key")
```

- `namespace`: ASCII `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. It separates independent
  credential domains (for example provider and Git) and is authenticated in AAD.
- `reference`: ASCII `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`. It is opaque to this module.
- `value`: 0..65,536 bytes. `write` copies the caller's array synchronously before it
  suspends; the internal copy is wiped after completion or failure. The caller's array is
  never captured, modified or wiped.
- All three operations dispatch blocking file/keystore work to one daemon I/O thread;
  callers on the main thread do not perform file or AndroidKeyStore crypto synchronously.
- `read` returns `null` only when the record path is genuinely absent. Permission,
  namespace-path, non-regular-file, symlink and I/O errors fail closed as typed errors; a
  failed stat is never treated as "no record".

`CredentialLimits` exposes the public bounds. `CredentialStoreException` is a sealed,
secret-free failure surface:

| Code | Meaning |
| --- | --- |
| `invalid_reference` | Reference alphabet or length is invalid |
| `invalid_namespace` | Namespace alphabet or length is invalid |
| `invalid_value` | Plaintext exceeds `MAX_SECRET_BYTES` |
| `corrupt_record` | Envelope header/length is malformed |
| `authentication_failed` | GCM tag failed: tamper, cross-reference swap or wrong key |
| `key_unavailable` | Per-reference key absent, permanently invalidated or unrecoverable |
| `keystore_failure` | AndroidKeyStore/provider operation failed; retry may work |
| `storage_failure` | Record I/O failed; the previous committed record is retained |
| `delete_failed` | Record file and/or key removal did not complete |

Exception messages are stable codes. Raw references, values and plaintext never appear in
them. The debug-only sealed helper adds `session_consumed` (replay/spent session),
`session_consumption_failed` (durable marker I/O) and `session_busy` (cancel raced an
in-flight import), and surfaces a failed key/state removal as `session_cleanup_failed`.

## Storage and key lifecycle

- Records are under `Context.noBackupFilesDir/floe-credentials/<namespace-id>/`.
  Both the namespace directory and record filename are SHA-256 identifiers; the raw
  namespace/reference never appears in a path, key alias or error.
- One non-exportable AES-256-GCM key per namespace/reference:
  `floe.cred.key.v1.<record-id>`. The key is created on first write and reused on ordinary
  replacement (the old ciphertext is replaced atomically under the same key).
- If the key is permanently invalidated (or unrecoverable) during a caller-requested write,
  only that alias is deleted and regenerated before the new record is committed. A missing
  key on read is `key_unavailable`; rewriting that reference recovers it. No global reset
  ever occurs, and other references/profile records are untouched.
- Delete removes the record file, then the key. If the record file is already missing,
  delete still removes the owned orphan key. A failure is surfaced as `delete_failed`.
  If the record path cannot be inspected, delete fails before touching the key so an
  existing credential is not made unrecoverable.
- File presence uses `Files.readAttributes(..., NOFOLLOW_LINKS)`. Only
  `NoSuchFileException` is "absent"; permission, namespace-path, symlink, non-regular-file
  and other I/O errors become `storage_failure` (read/write) or `delete_failed` (delete).
- Keys are not user-authentication-bound, so no biometric/permission prompt is added. They
  are AndroidKeyStore-backed and non-exportable through the API. Hardware-backed/TEE or
  StrongBox residency is device-dependent and is not claimed.
- Read/write/delete are serialized per record by an in-process lock shared by all store
  instances, plus a single I/O executor. Multiple Android processes are outside this
  component's contract (the App is single-process); cross-process coordination is not
  claimed.

Envelope (`FCRD`, version 1):

```
0  4  "FCRD"
4  1  version = 1
5  1  IV length = 12
6 12  random AES-GCM IV
18 .. AES-256-GCM ciphertext (includes 16-byte tag)
```

AAD is `"FLCA" | version(1) | u16(namespaceLength) | namespace |
u16(referenceLength) | reference` in UTF-8, big-endian lengths. A ciphertext copied to
another reference/namespace fails authentication.

Writes use a same-directory temporary file, `FileDescriptor.sync()`, then
`ATOMIC_MOVE|REPLACE_EXISTING` over the committed record. A failed write leaves the old
record in place; the only exception is the explicit rotation of a key that was already
permanently invalid, whose old ciphertext was already unreadable. Android offers no
portable Java directory-fsync API, so the claim is atomic visibility plus file-data
durability, not a power-loss journal. Ciphertext-only temp files left by a process crash
are removed for the same record on its next write.

## Backup and recovery

- `noBackupFilesDir` is excluded by the platform from Android Auto Backup and
  device-to-device transfer. The module does not add `allowBackup`, extraction rules,
  services, receivers or permissions; the manifest is empty.
- Ciphertext is device/UID-bound and is deliberately not restorable to another device or
  user. A fresh install/reinstall has no old keys or records: the app must ask the user to
  configure credentials again. Never delete unrelated records to recover one reference.
- There is no plaintext staging, SharedPreferences, SQLite, log or in-memory fallback.
  Plaintext exists in the caller's array, in a short-lived store-owned defensive copy used
  for encryption, and, during sealed debug import, in a temporary decrypted array. The
  store copy and debug decrypted/AES-key buffers are overwritten after use. Java/GCM
  provider internal copies and heap zeroization are not guaranteed; no perfect-zeroization
  claim is made.

## Debug-only sealed QA enrollment

Source lives only in `src/debug`; release variants do not contain it. It is a module-level
protocol/helper, not an App transport. The host script/device integration remains for the
next stage.

1. Device: `DebugSealedEnrollment.begin(context, namespace, reference, ttlMillis)` creates
   a one-shot session and an RSA-3072 AndroidKeyStore key (purpose decrypt, digest SHA-256,
   padding `OAEPPadding`). It returns `EnrollmentDescriptor`: protocol version, 16-byte
   session id (32 lowercase hex), package, namespace, opaque reference, expiry epoch millis
   and X.509 RSA public key. This descriptor is public metadata, not a secret.
2. Host: `DebugSealedEnrollment.seal(descriptor, payload)` (reference implementation, also
   used by instrumentation tests) generates an AES-256 key and 12-byte GCM IV, encrypts the
   bounded payload with AAD, encrypts the 32-byte AES key with RSA-OAEP, and builds the
   sealed envelope.
3. Device: `DebugSealedEnrollment.importSealed(context, sealedBytes)` parses the envelope,
   loads the session state by id, checks package and expiry, confirms no prior consumption,
   RSA-unwraps the AES key, AES-GCM-decrypts with AAD reconstructed from the stored session,
   then **atomically writes a durable `.consumed` marker before touching the credential
   store**. Only after that marker is durable does it write through
   `AndroidKeystoreCredentialStore`, overwrite the temporary plaintext buffer, and delete the
   session key, metadata and marker. Replay then fails as `session_unknown` (or
   `session_consumed` while spent metadata remains).
   Tampered/malformed envelopes and validation failures before the marker do not consume the
   session and can be retried. Once the marker is written the session is spent even if the
   credential write, cleanup or process dies; the import surfaces the typed failure (or
   `session_consumption_failed` / `session_cleanup_failed`) and the caller must reissue a new
   session. `cancel` finishes cleanup; it returns `session_busy` rather than racing an
   in-flight import.
4. Concurrency: imports for one session are serialized with `kotlinx.coroutines.sync.Mutex`,
   which is safe across suspension and continuation thread hops. A second import waits and
   then observes the consumed/absent state; it cannot enter the mutation path twice.

Sealed envelope (`FLQE`, version 1):

```
0   4  "FLQE"
4   1  version = 1
5   1  session id length = 16
6  16  session id
22  1  AES-GCM IV length = 12
23 12  AES-GCM IV
35  2  RSA-wrapped key length, big-endian = 384
37 384 RSA-OAEP-wrapped 32-byte AES key
421 .. AES-256-GCM ciphertext (includes 16-byte tag)
```

AAD is `"FLEN" | version(1) | u16(sessionID) | u16(packageName) | u16(namespace) |
u16(reference) | u64(expiresAtEpochMillis)`, all UTF-8 strings length-prefixed. RSA
parameters are `RSA/ECB/OAEPWithSHA-256AndMGF1Padding` with an explicit
`OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)`.
The MGF1 digest is SHA-1 because that is AndroidKeystore's default on API 28–37; the module
does not call `setMgf1Digests` (API 35+). A future host script must match these parameters.

Session metadata is JSON under `noBackupFilesDir/floe-qa-enrollment/`; the one-shot marker is
a small fixed-text file in the same directory. Neither contains a secret. There is no
socket, exported component, permission, clipboard, argv or log path in the helper. Debug
tests print only fixed pass lines, never payloads. `seal`/`importSealed` perform their
RSA/AES work on the caller thread (the store write itself still dispatches); debug callers
must not invoke them on the main thread.

## Verification sources

JVM unit tests (`src/test`, pure code, no fake AndroidKeyStore):

- `CredentialReferenceCodecTest`: accepted/rejected reference and namespace alphabets,
  traversal/control/oversize rejection, opaque hash/alias derivation, namespace binding,
  deterministic length-framed AAD.
- `CredentialEnvelopeCodecTest`: IV/ciphertext round trip, maximum-size acceptance, bad
  magic/version/IV length, truncation/empty/oversize rejection, encoder bounds, defensive
  buffer copies, constant consistency.

Instrumentation sources (`src/androidTest`, real AndroidKeyStore):

- `CredentialStoreInstrumentedTest`: missing-read null, invalid inputs, round trip with
  Unicode/zero/0xFF and input-array preservation, empty-value round trip,
  replace/delete/idempotent delete, namespace/reference isolation and opaque paths, tamper
  and cross-reference ciphertext swap fail-closed, missing-key typed failure and
  per-reference rewrite recovery, failed write preserves the previous record
  (oversize/invalid reference plus a directory write-revocation I/O failure), concurrent
  instances/writers/readers and delete/write races expose only complete records, no
  plaintext marker in module/files/cache/no-backup storage, orphan-key delete, caller-input
  freezing across a deliberately queued I/O dispatch, strict absence vs inaccessible
  namespace/record paths, unreadable-record fail-closed, delete fail-closed with key
  retention, and symlink rejection.
- `restart/RestartPhase1Test` + `RestartPhase2Test`: real two-phase process restart. Phase 1
  writes the record and a process token; the host force-stops the test package; phase 2
  asserts the token changed, reads the record through AndroidKeyStore again, deletes it and
  verifies key removal. Without `-e floeRestartPhase` both tests are skipped, not silently
  passed in one process.
- `hostinterop/HostInteropPhase1Test`, `HostInteropPhase2Test` and
  `HostInteropCleanupTest`: default-skipped host -> Android interop. Phase 1
  (`-e floeHostInteropPhase 1`) creates one real RSA-3072 AndroidKeyStore session and writes
  only the public seven-field descriptor to
  `noBackupFilesDir/floe-qa-host-interop/descriptor.json`. The host sealer reads it through
  `run-as`, seals a fixed synthetic UTF-8 payload in memory and writes only ciphertext to
  `sealed.bin`. Phase 2 (`-e floeHostInteropPhase 2`) bounds and imports that ciphertext with
  the real `importSealed`, checks the exact payload, one-shot state/key removal and replay
  rejection, then removes only this fixture's record/session/files. The explicit
  `-e floeHostInteropPhase cleanup` entry removes an interrupted run's owned state, keys and
  directory. All three tests are skipped without a phase argument.
- `SealedEnrollmentInstrumentedTest`: one-shot success, replay rejection, session state/key
  removal, tampered envelope rejected without consuming the session and a valid retry,
  wrong-reference and wrong-package AAD rejection, expiry, oversize payload, no plaintext
  payload in no-backup/files/cache storage, consumption marker written before a deliberately
  failed credential write (replay rejected, no credential), cleanup-failure replay cannot
  overwrite a later replacement, and two concurrent imports across threads yield exactly one
  success and one typed rejection.

Synthetic values only. No user credential is read or written by these tests.
`DebugSealedEnrollmentTestHooks` is a debug-only fault injector used solely by the
cleanup-failure test; it is absent from release and cannot change credential encryption.

## Exact next-stage commands

Run from the repository root. The component build commands were run for this revision; the
manual device and host-interop commands remain for the serialized primary device stage.

```sh
cd FloeAndroid
bash <<'SH'
set -euo pipefail
source scripts/env.sh

# Brand-new module: create only THIS module's initial lock state. Existing
# lockfiles must not be rewritten.
./gradlew :core:credentials:dependencies --write-locks --console=plain
git status --short -- core/credentials settings.gradle.kts

./gradlew :core:credentials:testDebugUnitTest --console=plain
./gradlew :core:credentials:assembleDebug :core:credentials:assembleDebugAndroidTest --console=plain
SH
```

If the policy owner prefers to defer initial lock creation, compilation still works with
the repository's default (non-strict) lock mode, but the new module then has no pinned
lock state. Do not regenerate other modules' lockfiles. The initial lock is expected to
include the already-resolved `org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0` for the
debug variant only.

Device phase (verified serial only; never select an ambiguous target):

```sh
export ANDROID_SERIAL=<verified-serial>
cd FloeAndroid
bash <<'SH'
set -euo pipefail
source scripts/env.sh
./gradlew :core:credentials:connectedDebugAndroidTest --console=plain
SH
```

If running the instrumentation APK manually:

```sh
adb -s "$ANDROID_SERIAL" install -r \
  "$(find "$FLOE_ANDROID_BUILD_ROOT/core/credentials" -name '*debug-androidTest.apk' -print -quit)"
adb -s "$ANDROID_SERIAL" shell pm list instrumentation | grep com.floe.android.credentials
adb -s "$ANDROID_SERIAL" shell am instrument -w \
  com.floe.android.credentials.test/androidx.test.runner.AndroidJUnitRunner
```

The library androidTest package is normally `com.floe.android.credentials.test`; confirm
with `pm list instrumentation` before use.

Two-phase restart procedure (the package must be force-stopped between invocations):

```sh
adb -s "$ANDROID_SERIAL" shell am instrument -w \
  -e floeRestartPhase 1 \
  -e class com.floe.android.credentials.restart.RestartPhase1Test \
  com.floe.android.credentials.test/androidx.test.runner.AndroidJUnitRunner

adb -s "$ANDROID_SERIAL" shell am force-stop com.floe.android.credentials.test

adb -s "$ANDROID_SERIAL" shell am instrument -w \
  -e floeRestartPhase 2 \
  -e class com.floe.android.credentials.restart.RestartPhase2Test \
  com.floe.android.credentials.test/androidx.test.runner.AndroidJUnitRunner
```

Phase 2 fails if the process token is unchanged, proving the restart rather than reporting
a same-process pass.

## Boundaries

- `FloeAndroid/settings.gradle.kts` only adds `:core:credentials`; the App does not yet
  depend on the module. No feature/UI/runtime/profile/Swift/transport/persistence changes.
- One version-catalog alias was added for `kotlinx-coroutines-core` 1.9.0, already resolved
  by the existing Compose/app lockfiles. It is a `debugImplementation` dependency because
  only `src/debug` uses the coroutines `Mutex`; no version upgrade or new library family.
  Other dependencies remain the existing `:core:contracts`, JUnit and androidx.test entries.
- Debug signing follows the repository's pinned `floe.debug.keystore` convention (absolute
  existing file, fail closed; AGP debug constants). No keystore or `local.properties` value
  is read by this module's source.
- Component build and JVM tests pass; instrumentation and host -> Android interop are not
  device-executed, not lint-gated and not App-integrated. This is not a G02 goal completion;
  the primary agent owns the serialized device run and acceptance.

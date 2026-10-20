# FloeAndroid G02 shared-core overlay provenance

Promoted 2026-10-18 from the completed adaptation audit
(`Local/Private/android-g02-20261018/adaptation-audit/`, job
`job-dee5658543974844`) into this production package. Audit probe artifacts
are retained there; this overlay is the REAL shared core (not a probe).

## Original-source links (single authority)

Unmodified original iOS Swift files enter as PER-FILE RELATIVE SYMLINKS to
`../../../../FloeAgent/Sources/...` (the G01 `TaskPolicy.swift` precedent).
iOS sources and `FloeAgent/Package.swift` are NOT edited by this overlay.

| Module | Files | Form |
| --- | --- | --- |
| FloeCore | 75 | 69 links + 6 narrow patch copies (see below) |
| FloeModels | 8 | all links |
| FloeProviders | 24 | 23 links + `ProviderAdapter.swift` copy |
| FloeSecurity | 13 → 12 | 12 links + `Resources/catastrophic-patterns.json` copy; **`KeychainStore.swift` excluded entirely** |
| FloeTools | 25 | 23 links + `MCPRemoteToolSource.swift`, `NetworkDestinationPolicy.swift` copies |
| FloeSkills | 22 | all links |
| FloePersistence | 71 | original links plus reviewed `ConversationStore.swift`, `RunLaunchStore.swift`, `ConversationPromoter.swift` and the frozen byte-identical v46 `DatabaseManager.swift` mirrors; same 46-migration chain, no second store |
| FloeAgentRuntime | 40 | all links (ConversationRunService/FloeAgentRuntime actor/HarnessEventChannel authority) |
| FloeAndroidWebTools | 5 | 3 links (`WebRetrievalModels.swift`, `Tools/WebFetchTool.swift`, `Tools/WebSearchTool.swift`) + 2 narrow mirrors (`HTTPRequestService.swift`, `WebSearchService.swift`) — see D1 section |

The former `FloeSharedModels` target (G01 duplicate compile of
`FloeModels/TaskPolicy.swift`) was REMOVED: `Bridge.swift` now imports the
original `FloeModels` module, so exactly one TaskPolicy authority is compiled.
The frozen v1 handshake bytes (`"sharedModels":["TaskPolicy"]`) are unchanged.

## Documented Android mirror patches (copied overlays)

All patches are `#if canImport(Android)` / `#elseif os(Android)` /
`os(Linux) || os(Android)` additions — Darwin/macOS behaviour is identical to
the originals, which is what the host test build verifies.

1. `FloeCore/DesignCanvasMetadata.swift` — CFBoolean island. PRODUCTION
   CORRECTION #1 over the probe and over the first device run: Boolean
   identity comes from the public CoreFoundation runtime type
   (`CFGetTypeID(value) == CFBooleanGetTypeID()`) before any `as? Bool` or
   objCType heuristic. The earlier exact-dynamic-type check did not match
   Foundation.__NSCFBoolean on Android (Samsung API 33 smoke), while a genuine
   one-byte Int8 NSNumber is CFNumber and keeps integer semantics (Main
   directive).
2. `FloeCore/StorageCloneAccounting.swift` — APFS `EF_*` extflags → `false`
   off-Darwin (reader already returned `.unsupported`).
3. `FloeCore/{Digest,DesignFreezeRegistry,StorageAccounting,StorageExtentAccounting}.swift`
   — `#if canImport(Android) import Android #endif` POSIX visibility.
4. `FloeTools/NetworkDestinationPolicy.swift` — bionic `SOCK_STREAM` branch +
   `getnameinfo` socklen_t/size_t signature. PRODUCTION CORRECTION #3: the
   probe applied the bionic cast unconditionally, breaking the macOS host
   compile; the call is now platform-split with the Darwin branch byte-equal
   to the original.
5. `FloeProviders/ProviderAdapter.swift` + `FloeTools/MCPRemoteToolSource.swift`
   — `os(Linux)` → `os(Linux) || os(Android)` around the BUFFERED
   `data(for:)` fallback ONLY. Compile-probe scope; NEVER an Android product
   streaming path (Main directive). No Android bytes(for:) exists; the real
   incremental adapter is package P3.
6. `FloeSecurity` — `KeychainStore.swift` removed from the overlay (its
   non-Security branch is a process-wide RAM store; fail-closed directive).
   `BridgeEnvelope`/`CredentialBackend` provide the typed NEEDS_CONFIGURATION
   seam instead; no memory fallback exists in any compiled path.

## Vendored third-party mirrors (exact audit revisions)

| Component | Pin | Form |
| --- | --- | --- |
| swift-crypto | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` (3.15.1) | Exact-revision remote SwiftPM dependency (`revision:` pin, no floating version/tag) + generated `Package.resolved` lock (transitive swift-asn1 `3b6410f7…` 1.7.3). Main reproducibility directive 2026-10-18: the audit's absolute DerivedData path symlink was REMOVED from product source. |
| GRDB | `18497b68fdbb3a09528d260a0a0e1e7e61c8c53d` (v7.8.0) | 166-file mirror under `Sources/GRDB`, exactly 9 platform-condition patch sites (`DispatchQueueActor`, `StatementAuthorizer`, Support/Foundation `Date/Decimal/NSData/NSNumber/NSString/URL/UUID`), Android treated as corelibs-Linux; no `.docc`, no unrelated deps |
| SQLite | 3.54.1 official amalgamation ZIP: SHA3-256 `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` (verified against the sqlite.org published value, same as the audit; re-verified 2026-10-18 on the retained zip). Extracted `sqlite3.c`: SHA3-256 `e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81`, SHA256 `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`, 9,582,521 B — byte-identical to the audit probe tree | `Sources/GRDBSQLite` C target, `SQLITE_ENABLE_FTS5=1`, `SQLITE_THREADSAFE=2`, `SQLITE_ENABLE_SNAPSHOT=1` (NDK ships no sqlite3; SNAPSHOT is PRODUCTION CORRECTION #4 — the probe left `sqlite3_snapshot_*` undefined in the Android `.so`) |
| ZIPFoundation | `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (0.9.20) | 21-file mirror `Sources/ZIPFoundation` (Swift 5 mode), `funopen`/`mmap` bionic rewrites, `import Android` chain. PRODUCTION CORRECTION #2: the probe's dormant `lchmod→chmod` fallback was replaced with an Android no-op matching upstream non-Darwin semantics (the only Android caller path is already a no-op, so symlink-following chmod is not retained; regular-file permissions are untouched). Main reviewed this 2026-10-18. |
| CZLib | vendored shim (`shim.h` + modulemap `link "z"`) | NDK public zlib; mirrors upstream's host-evaluated `canImport(Compression)` binding gap |

Licenses: `FloeAndroid/shared/licenses/` (GRDB MIT, swift-crypto Apache-2.0 +
NOTICE, ZIPFoundation MIT; SQLite is public-domain per its header statement).

## Android-authored seam sources (native/JNI stage 2026-10-18, job-f86ae143808f47b5)

These are NEW Android-owned files (no iOS original behind them; the original
iOS sources are untouched — nothing was edited through a symlink):

- `Sources/FloeAndroidCore/QualificationSeam.swift` — verified security
  corpus init (`AndroidCatastrophicCorpus`: pinned SHA-256
  `b20667f2…`, same `Corpus{patterns:[Pattern]}` Codable shape and same
  `CatastrophicActionGate.init(patterns:)` regex path as the iOS bundle
  loader; missing/hash/decode/compile failure = rejection, never empty
  patterns) plus bounded `@_cdecl` qualification surface
  (`floe_gate_create_from_corpus/_create_fail_closed/_evaluate/_release`,
  `floe_db_smoke`, `floe_json_kind_smoke`). Classification only; no bridge
  operation, no grant/task authority, no command execution.
- `Package.swift`: `FloeAndroidCore` gained a `GRDBSQLite` target dependency
  so the seam can call the vendored `sqlite3_snapshot_*` C APIs directly.
  The amalgamation was already compiled into the product via GRDB; this only
  imports the existing C target.
- Companion packaging outside `shared/`: `build-swift.sh` now exports the
  corpus byte-copy to `core/swiftbridge/src/main/assets/security/` with the
  pinned-hash gate; `native-manifest.py` records both corpus copies inside
  the provenance `inputDigest` and refuses to generate if they differ;
  `core/swiftbridge/src/main/cpp/floe_qualification.cpp` + CMake target
  `floe_qualification_jni` (debug instrumentation wrapper, loaded only by
  the androidTest `QualificationNative`), the frozen `floe_jni.cpp` is
  byte-unchanged.

## D1 minimal web closure — `FloeAndroidWebTools` (2026-10-19, job-35f36db9026e4076)

Main-decided minimal `web.search`/`web.fetch` closure (BRIDGE_V3_MAIN_DECISIONS
context + runtime-facade-contract D1/RB-6): exactly the FIVE original
`FloeExecution` web files, nothing else. No tool registration, no facade/
service binding, no SSH/shell/workspace code, no full `FloeExecution` port.
The future facade resolver supplies the settings store and the secure
credential gateway by `credentialAccount`; nothing here fabricates
configuration or credential fallbacks. `FloeAndroidCore` depends on the
target so the closure links into the actual `.so` (dependency only).

Three files are unmodified per-file links. `HTTPRequestService.swift` and
`WebSearchService.swift` are narrow copied mirrors; every delta is an
`#if` platform split or an import/type visibility addition — the Apple
branch stays byte-equal to the original, and ALL original policy semantics
(public-HTTPS/DNS fail-closed validation, per-redirect revalidation,
cross-origin credential stripping, header allow/block lists, ephemeral
no-cookie/no-credential-session isolation, cap+1 bounded `truncated` body
return (NOT `responseTooLarge`), download staged-save/cancellation,
provider status/parse/failover taxonomy) are preserved. Documented deltas:

1. Imports: `Android/Glibc/Darwin` POSIX visibility split and
   `FoundationNetworking` guard (SDK-proven on the pinned Swift 6.4.1
   Android toolchain); `FloeTransport` import for the qualified seam.
2. `addrinfo.ai_protocol: Int32(IPPROTO_TCP)` — bionic defines the macro as
   `Int`; identity cast on Darwin, same value, no behavior change.
3. Session construction on `os(Linux)/os(Android)`:
   `StreamingTransport.makeSession(configuration:policyDelegate:)` with the
   ORIGINAL redirect delegate object as the router's policy authority
   (redirect AND authentication/trust callbacks are forwarded; no
   invented policy or trust decision). Apple keeps the original
   `URLSession(configuration:delegate:delegateQueue:)` construction. The
   configuration hardening (copy + cookies/credential storage detached) is
   byte-equal original code above the split.
4. `HTTPRequestService.send` on `os(Linux)/os(Android)`: `WebBoundedStream.execute`
   (compiled on EVERY platform; host suite runs this exact body) consumes
   the real `StreamingTransport.stream` chunks until the ORIGINAL `cap+1`
   crossing, then cancels the owned task; the shared
   `prefix(cap)`/`truncated`/status/headers/finalURL code below is
   unchanged, so an oversized body is still a successful truncated
   response, never an error. Differences documented in-source: explicit
   owned-task cancellation after the break (strictly safer than abandoning
   the iterator); a bounded 1 MiB in-flight queue (the original
   `bytes(for:)` had platform-internal buffering; saturating it is an
   explicit recoverable error mapped to the original `requestFailed`
   taxonomy — it can only fire if the consumer task was starved, since a
   capped read stops at `cap+1 ≤ 256 KiB+1` bytes); a transport failure
   before the response head surfaces as `sessionNotStreamable`/
   `noHTTPResponse`-class detail text under the same
   `requestFailed(…)`, so only the diagnostic wording can differ.
   Declared `Content-Length` beyond the cap does NOT cancel early (stream
   mode matches the original read-anyway behavior).
5. `WebSearchService.run` on `os(Linux)/os(Android)`: `WebSearchCollect.execute`
   (compiled on EVERY platform; host suite runs it) performs the bounded-
   at-saturation full-body collect with `maxBytes: .max`, preserving the
   ORIGINAL `data(for:)` budget exactly — no application ceiling invented
   and no check-after-full-buffer pattern added; status/parse/failure
   strings below the split are byte-equal original code. Apple keeps the
   original `session.data(for:)` line.
6. `download`/`commitDownload` (generic download in the same file):
   UNCHANGED original code; SDK probe confirmed `download(for:)` compiles
   for android28. Async-download cancellation and delegate-parity on
   Android FoundationNetworking is object/proven-only here; DEVICE proof
   remains Main's gate.
7. New seams are `internal` (module/test visibility only):
   `makeStreamingSession` (×2) and the platform bodies. No public API was
   added, removed or renamed.

The original iOS sources behind the links are byte-unchanged (verified by
the manifest link records and `source-hashes`). Android/Linux never uses
the host interpreter, no RAM business store, no trust exception, no
production cleartext; tests use only synthetic loopback fixtures plus the
ORIGINAL internal test seams (`validateDestination` injection, package
resolver seam) — production destination policy was not weakened.

## What is and is not claimed

COMPILED (host macOS, this package): the whole graph above incl. GRDB +
vendored SQLite + FloePersistence + FloeAgentRuntime + bridge v1/v2.
NOT yet compiled here for android28 at delivery time: the actual product
`libFloeAndroidCore.so` (native build stays serialized; see HANDOFF.md).
Host tests prove schema/bridge/store semantics ONLY — no device runtime,
streaming cadence, Keystore, WAL kill/restart or UI claim.

## G02 model configuration publication + host qualification (2026-10-19, job-059dc09dd7bd48f1)

Main-reviewed parent candidate (archive
`b7c2aa550681871182c031345af81df307bf73105d29e0366cc08d7314116b28`, 17 files)
plus the admitted physical/web-search successor (job-97a740a3dbb946ce, archive
`5f8ae1ed67a18b12dc7467954b0e6900597570dfadb649f3d2a34a46337e8edc`, 21 files),
published by the serialized host qualifier:

- 10 NEW core sources (`AndroidProviderSecretSaving`, `ModelConfigPendingCleanup`,
  `ModelConfigurationCommitter`, `ProviderOperationCoordinator`, `RuntimeFacadeConfig`,
  `RuntimeFacadeConfigBinding`, `RuntimeFacadeConfigIngress`, `RuntimeFacadeConfigModels`,
  `RuntimeFacadeConfigOwnedWork`, `WebSearchSecretSaving`) + 7 test files under
  `Tests/FloeAndroidCoreTests/`.
- 3 reviewed additive mirrors replaced the live gateway files in place
  (`CredentialBackend.swift` preimage `e485fb99…`, `SecretGatewayMailbox.swift`
  preimage `64f28bf9…`, `SecretSaveIntentVault.swift` preimage `64eac84b…`):
  existing CRUD, error cases, namespaces and the C/JNI ABI are unchanged.
- `Sources/FloePersistence/ModelConfigurationStore.swift`: the overlay SYMLINK
  to `../../../../FloeAgent/Sources/FloePersistence/ModelConfigurationStore.swift`
  was REPLACED BY ATOMIC RENAME with the reviewed copied regular file (the link
  itself, never a write-through). The protected upstream pin
  `7b8fc23a0e225954e5dd4b0f3108115232ae06b5df9a416d94702ddde4ab7983` was verified
  byte-unchanged before AND after publication. Narrow additive delta only:
  `ProviderBundleExpectedState` expected-state CAS on
  `saveProviderBundle`/`deleteProvider` (nil/default preserves every existing
  caller byte-for-byte).
- Host qualification repaired compiler/concurrency/test defects (delta vs the
  reviewed candidate is exactly
  `Local/Private/android-g02-20261018/runtime-model-configuration-qualification/evidence/QUALIFIER_REPAIR_DELTA.patch`):
  GRDB `changesCount` spelling; explicit `ProviderBundleCommitting` /
  `OwnedWorkRegistryPort` conformances; `Error` conformances for the
  `Result<…>` carriers; `SecretDispositionClassifier` `.internal` case;
  settlement-subscription state transitions moved UNDER the mailbox lock;
  per-attempt physical observation resolution for a mutable registry
  (`PhysicalObservationResolving`); the pending record retains the EXACT
  attempt observer (`ProviderPendingRecord.witness`, MC-OBSERVER-PENDING-OWNER)
  so removal/replacement of the registry cannot strand an old owner; scalar
  Codable (OptionSet) fragment decoding; camelCase raw-credential name
  recognition; the legacy web-search metadata CAS commit in the keep path.
- Final closure repairs (Main model-witness readback, 2026-10-19, same job):
  (a) pending-record `physicalSnapshot`/`resolvePhysical` now require the
  EXACT captured witness — a receipt whose original witness is missing stays
  `.notRecorded` and is never inspected/ACK'd through the current registry
  (a replacement gateway with a colliding claim cannot answer for it);
  (b) the transient per-provider witness slot is consumed into the pending
  record (transfer) or cleared at terminal flow end, so repeated completed
  distinct-provider operations retain no observer objects while an
  outstanding pending owner keeps its original until real settlement.
  Five qualifier-authored regressions cover: immediate-terminal/cancel race,
  non-observing replacement classification, no-reinstall pending settlement,
  witness lifetime (terminal vs pending), and missing-witness collision
  refusal. Runtime-only metadata; no wire/ABI/namespace/persistence change.

## G02 conversation history domain publication (2026-10-19, job-6766e95388c342f0)

Main-reviewed 7-file candidate (archive
`96e2c5a89a90928cda40494135051b88ea913c4a440d9ef005c1be37edc481f8`, parent
archive `5cc3c33dbcdf46b7191fb92c45a1ae1602c98ae70a2b408de1d0e04b2b96b58c`
with only two test-syntax lines repaired per `MAIN_SYNTAX_REPAIR.patch`)
published by the serialized host qualifier after Main accepted the RB1
foundation (`runtime-bootstrap-qualification/MAIN_ACCEPTANCE.json`):

- 6 NEW files: `Sources/FloeAndroidCore/RuntimeFacadeConversations.swift`
  (`f79e1e9b…`), `Sources/FloeAndroidCore/RuntimeFacadeConversationContent.swift`
  (`5563e7cf…`), `Tests/FloeAndroidCoreTests/RuntimeFacadeConversationsTests.swift`
  (`db6dadb4…`), `RuntimeFacadeConversationContentTests.swift` (`eee68e83…`),
  `RuntimeFacadeConversationDeleteTests.swift` (`3b8814d2…`),
  `RuntimeFacadeConversationTestSupport.swift` (`48e74e46…`). All 53 authored
  test methods were source-authored-not-run before this publication; the
  host qualification below executed them for the first time.
- `Sources/FloePersistence/ConversationStore.swift`: the overlay SYMLINK to
  `../../../../FloeAgent/Sources/FloePersistence/ConversationStore.swift` was
  REPLACED BY ATOMIC RENAME with the reviewed copied regular file (the link
  itself, never a write-through; no patch/open/cp of the protected original).
  The protected upstream pin
  `e7f5f616034683672bd740e3a921496f04b5382dd720fdd2af7787fd04e1d876` was
  verified byte-unchanged before AND after publication. Narrow additive delta
  only: ONE 46-line insertion (`RB3-CH-R1 ADDITIVE BEGIN/END`) adding the
  `deleteConversation(id:expectedRow:beforeDelete:)` overload that runs the
  raw-row `expectedRow` CAS, the exact original memory-preservation SQL and
  the original `RunLifecycleRetention` cascade + `DELETE FROM conversations`
  inside ONE `DatabaseManager.writer` transaction, removing spool artifacts
  only AFTER commit. The original default `deleteConversation(id:)` method,
  row codec, cascades and cleanup semantics are unchanged; no schema/data-file
  fork. Published mirror hash `c77dc07c…`.
- Contracts preserved per Main source review CH-R1/R2/R3: same-writer CAS +
  ownership/fence seams at source scope; the actual RB4 producer
  (job-f677…) and the composed all-domain App remain honest gates — no fake
  ready flags, no global-B wait in these sources.
- Host qualification evidence:
  `Local/Private/android-g02-20261018/runtime-conversation-history-qualification/`.
  Build-cohort policy (G02_BUILD_COHORT_POLICY_20261019.json): hostQualified
  only; nativeQualified=false / productQualified=false until Main's one
  composed native/App batch.
- Host-qualification repairs (delta vs the reviewed candidate is exactly
  `Local/Private/android-g02-20261018/runtime-conversation-history-qualification/QUALIFIER_REPAIR_DELTA.patch`):
  (a) cursor tokens: `ConversationCursorCodec.wrap` now base64url-ENCODES the
  JSON keyset payload so it matches the existing `unwrap` decoder (previously
  every minted `nextCursor` was rejected as `invalidCursor` on the next page);
  (b) the delete path maps `drainOwnedWork` `ConversationDeletionLifecycleFailure`s
  onto the SAME frozen wire vocabulary as `beginDeletionFence` (a raw adapter
  failure escaped the facade before);
  (c) Swift 6 strict-concurrency repairs in the reviewed sources/tests:
  immutable capture of the list keyset, public scalar-newline spelling for the
  content-read handle check, an explicit `withLocked` seam for `noasync`
  NSLock use in async test doubles, exhaustive catches, hoisted `await`
  autoclosure arguments, `GRDB.DatabaseError` (GRDB 7 name), sendable-actor
  capture instead of the non-Sendable test bundle, and argument-order fixes.
  No assertion was weakened or removed; the original 4 failing tests
  (generation-retired handles, drain-failure abort/retry, two cursor
  pagination cases) now pass against the repaired sources.
- `Tests/FloeAndroidCoreTests/RuntimeFacadeConfigSameBaseCASRaceTests.swift`
  is the Main-directed dependency regression (NOT part of the 53 conversation
  methods): TWO independent `ModelConfigurationCommitter` actors over the same
  file-backed DB, both staged `.editAtRevision(0)`, committing the same
  observed base concurrently with NO raw/external writer — exactly one typed
  success, one typed `ModelConfigurationRevisionConflict` (expected 0,
  observed 1), persisted revision 1 with the winner's payload, and a late
  base-0 attempt that writes nothing. No model production source changed.


## G02 empty-header first activation (2026-10-20)

`Sources/FloePersistence/RunLaunchStore.swift` is a regular Android mirror of
upstream SHA-256 `71b35d16cf332a7e8bcb45ff9034dfed52631ecea5849128608b1a688d3872fd`.
The existing `prepare(_:)` remains the original default. A trusted request
opt-in, default false and absent from the wire grammar, permits a genuinely
empty ordinary, unarchived header to acquire its canonical private-task
workspace and policy in the original launch writer. Prior runs, messages,
attachments, policy or malformed ownership refuse activation. The existing
conversation identity is retained and `createdConversation` stays false.

An additive `ExistingConversationRunLaunchStore.prepare(_:expectedRow:)`
capability runs a trusted `(Database, Row?)` verifier in that same writer,
before any configuration or launch writes. Only ordinary existing-header
wire starts require it. The facade reuses the exact full raw-row revision
algorithm to reject stale writes. A short per-conversation wire-admission
reservation rejects overlapping admission before its first await and is
released when that start returns; the original parallel live-service
contract remains intact. Missing capability fails closed. New-task, retry and
RAM-only temporary preparation retain the original protocol. Neither the
upstream source, schema, wire grammar nor credential rules change.

The corresponding regression suite is
`RuntimeFacadeEmptyHeaderActivationTests`; authored, compiled and executed
status must be taken from the current qualification receipt, not this source
provenance note.


## G02 temporary-session package — actual qualification (2026-10-20, job-10f263aaecec4d4d)

`Sources/FloePersistence/ConversationPromoter.swift`: the overlay SYMLINK to
`../../../../FloeAgent/Sources/FloePersistence/ConversationPromoter.swift`
was atomically replaced (link itself, never written through) with a reviewed
regular Android mirror of upstream SHA-256
`314dc5e671623e7b21dff65998177b6ed1b0239eea86f0ae965a39dfff1918a4`, whose
upstream bytes remain byte-identical and untouched. The mirror is purely
additive: `promote(_:)` keeps byte-compatible behavior by delegating with a
nil fence; the new `PromotionCommitFence`
(`allowsCommit`/`beginFinalCommit`/`finishFinalCommit`) plus
`promote(_:commitFence:)` implement the TMP-COMMIT-1 repair — discard is
linearized against the ACTUAL SQLite COMMIT (the final guard registers the
commit attempt atomically inside the writer closure; `finishFinalCommit`
resolves only after the writer await really committed or really threw).
No schema, no journal, no second DB, no behavior change for any existing
caller. Mirror SHA-256: `2f1ae3ff90fab50a981d39f3939000c3857adafb05d76f70c8936bf9cea94729`.

New FloeAndroidCore files (this package, all original Android-owned):
`RuntimeFacadeTemporarySupport.swift` (closed vocabulary, the commit-boundary
fence state machine, the synchronous `TemporaryNavigationGate` and the typed
`value.navigationFence` acknowledgement), `RuntimeFacadeTemporary.swift`
(one service-owned RAM session per accepted epoch; start/end/keep/launch;
original Ephemeral stores; original promoter Keep pipeline; retirement),
`RuntimeFacadeTemporaryBridge.swift` (the frozen three binder keys with the
TMP-NAV-2 synchronous admission in the submit path and the
`G02TemporaryDomainExtension` production attach) and
`RuntimeFacadeTemporaryRunAdapter.swift` (the sole production
`TemporaryRunDomainPort` over the live RUN-S2 `start(query:…bundleOverride:)`
seam, RB5 T1-T5).

Narrow additive host edits: `RuntimeFacadeRuns.swift` gained exactly two
public actor methods (`dispatchTemporaryRunCancel(runID:)`,
`hasLiveTemporaryRun(runID:)`) for the RB5 T5 explicit cancel dispatch —
the first-send activation bytes and everything else are unchanged;
`RuntimeFacadeBootstrap.swift` gained exactly one pre-bootstrap line
(`G02TemporaryDomainRegistration.registerIfNeeded()`) so the ordinary base
still installs INDEPENDENTLY of this optional graph. Tests:
`RuntimeFacadeTemporary{Support,Session,Keep,Ceiling,PositiveLaunch}Tests.swift`
carry all 51 original authored intents against the current live API, and
`RuntimeFacadeTemporaryNavigationFenceTests.swift` covers the two mandatory
boundary repairs on the real binder/mailbox/pump/file-backed DB. Three
`G02CompositionIntegrationTests` expectations were rebased because the
temporary family is now REAL-integrated (ready via actual bound keys;
privacy stays honestly blocked; the frozen-family substitute rule kept).
Authored/compiled/executed status lives in the qualification receipt, not
this note.

### G02 DatabaseManager v46 freeze (2026-10-20, Main integration guard)

`Sources/FloePersistence/DatabaseManager.swift`: the overlay SYMLINK was
atomically replaced (link itself; upstream never written) with a byte-identical
regular mirror of upstream `currentSchemaVersion = 46` at SHA-256
`5ab9f989…`-verified freeze (full hash recorded in
`Local/Private/android-g02-20261018/runtime-temporary-session-qualification/databasemanager-v46-freeze.txt`).
This freezes the Android binding at the existing v46 chain while tracked iOS
main moves to v47 (`V47ShortcutInbox`, NOT included on Android); no Swift
logic, schema or migration changed. A later coordinated portable migration is
documented separately (shared/ANDROID_PERSISTENCE_BASELINE.md is a Main-owned
future note), never by silently repointing to newer upstream bytes.

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
| FloeModels | 9 | 8 links + byte-identical original `RunOutputFile.swift` snapshot at `ee1816ae41fd6d74826696f02ffeb3ebcc1f0965` |
| FloeProviders | 24 | 23 links + `ProviderAdapter.swift` copy |
| FloeSecurity | 13 → 12 | 12 links + `Resources/catastrophic-patterns.json` copy; **`KeychainStore.swift` excluded entirely** |
| FloeTools | 25 | 23 links + `MCPRemoteToolSource.swift`, `NetworkDestinationPolicy.swift` copies |
| FloeSkills | 22 | all links |
| FloePersistence | 71 | original links plus reviewed `ConversationStore.swift`, `RunLaunchStore.swift`, `ConversationPromoter.swift` and the frozen byte-identical v46 `DatabaseManager.swift` mirrors; same 46-migration chain, no second store |
| FloeAgentRuntime | 40 | links + the documented Android-owned regulars (`AgentRuntime.swift`, `SubagentRunner.swift`, `ToolWorkflowGuidance.swift`; from the goal-core batch also the narrow reviewed `IntelligenceStore.swift` mirror with an additive-only in-transaction block — see the dated sections below; ConversationRunService/FloeAgentRuntime actor/HarnessEventChannel authority unchanged) |
| FloeAndroidWebTools | 5 | 3 links (`WebRetrievalModels.swift`, `Tools/WebFetchTool.swift`, `Tools/WebSearchTool.swift`) + 2 narrow mirrors (`HTTPRequestService.swift`, `WebSearchService.swift`) — see D1 section |
| FloeEnvironments | 13 | 9 links + 3 narrow mirrors (`ContainerRecord.swift`, `EnvironmentRoots.swift`, `EnvironmentRegistry.swift`) + 1 Android-owned regular (`LinuxExecutionLeaseDescriptor.swift`) — see G03-R1 section |

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

## G03-R1 environment authority — `FloeEnvironments` (2026-10-22, job-d15dbb99ae374286)

G03-R1 Android port of the EXISTING `FloeAgent/Sources/FloeEnvironments`
authority — NOT a second Kotlin/Swift registry and NOT an executor. Depends on
FloeCore+FloeTools only, exactly like `FloeAgent/Package.swift`. Main owns
architecture/isolation; the FloeAndroid/core/linuxruntime lane
(job-32b3d5dded1d4e70) owns the backend launch transport that later consumes
the approved lease descriptor.

**Nine per-file links** reuse the original authority byte-for-byte:
`ContainerCAS.swift`, `ContainerLifecycle.swift`, `ContainerPromote.swift`,
`EnvironmentExecutionCoordinator.swift` (the lease authority: workspace-hash
owner check, layer-stack derivation, lease cancellation tracking,
stopAndWait), `EnvironmentFileTransaction.swift`, `FloeEnvCommand.swift`,
`LayerPackageControl.swift`, `LayerPackageDatabase.swift`, `LayerStack.swift`.
All are portable Foundation+FloeCore(+FloeTools) code; the only platform hook
(`clonefile`) is already `#if canImport(Darwin)`-guarded in the originals, so
non-Darwin falls back to plain copies unchanged.

**Three narrow mirrors**, every delta `#if os(Android)`-split with the Apple
branch byte-equal to the original:

1. `ContainerRecord.swift` — ONE additive enum case
   `EnvironmentExecutionBackend.linuxPRoot`: the Android/Linux
   resolved-execution candidate consumed by the backend launch transport.
   Per Main decision (`Local/Private/android-g03-20261022/r1/
   ARCHITECTURE_DECISIONS.json` `proot-isolation`) it is a COMPATIBILITY
   CANDIDATE, NOT a security boundary (same-UID PRoot is not an app sandbox);
   it is never a default and never advertised as an executable capability
   merely because a record exists. The additive case keeps every persisted
   registry decode-compatible.
2. `EnvironmentRoots.swift` — Android has NO implicit root fallback at all:
   the default `init()` fail-closes (preconditionFailure directing to
   `makeTrusted`), and a non-nil `init(rootURL:)` is validated with the same
   rules as `makeTrusted` (malformed input traps instead of silently owning
   an unintended location). Adds `makeTrusted(rootURL:) throws`, the
   validated trusted-composition entry point (absolute, normalized,
   app-private directory only). `shared`/defaulted `roots:` parameters stay
   source-compatible but trap if evaluated on Android without an explicit
   root.
3. `EnvironmentRegistry.swift` — on Android the three `.linuxVM` iOS-TinyEMU
   DEFAULTS are removed (`defaultExecutionBackend` init parameter,
   `createPinnedEnvironment`, `registerOfficialTemplate`): the trusted
   composition must supply the backend explicitly, so neither TinyEMU nor
   `.native` host execution can be silently selected. `ensureProjectContainer`/
   `ensureSessionContainer` still honor an explicit per-record choice and
   otherwise use the composition-supplied registry default; the legacy
   nil→default migration is unchanged and stays recoverable.

**One Android-owned regular**, `LinuxExecutionLeaseDescriptor.swift`: the
narrow Swift-side routing input handed to the backend launch transport.
Both entry points acquire through the ORIGINAL
`EnvironmentExecutionCoordinator.acquire` (all authority decisions stay
there), then add the Android ownership gates and package the snapshot:
explicit-backend refusal (`.native`/`.linuxVM` rejected), the session
conversation gate (pre-acquire on the addressed record AND re-checked on the
resolved record after prepare/acquire, so a nil or foreign conversation can
never select a session environment), record/backend cross-check (no silent
retargeting), and identity survival (runID, conversationID, workspaceID+root,
environmentID, projectContainerID, ordered layer stack, validated
HOME/TMPDIR/variables). Lease ownership discipline (Main review 2026-10-22):
`acquireHolder` is the ONLY launchable path — its holder keeps the lease
until the transport confirms the owned process ACTUALLY quiesced, and
`release()` before quiescence is a typed refusal (a cancellation request is
not termination). `resolveMetadata` is metadata-only and hands the lease
back BEFORE returning; its bare descriptor is never launch authority.
Exactly one code path finishes any acquired lease (the acquiring entry point
on failure, the holder on release) — no helper finishes, no double finish.

Truthful scope: the descriptor contains only validated existing lease/record
roots/identities and the ordered layer stack (session > project > template >
shared > base). The stack is LOOKUP ORDER, not a kernel overlayfs or process
sandbox; the merged apt rootfs and PRoot mount mechanics belong to the
backend lane and are NOT claimed here. No second persistent DB, no pretend
backend lifecycle, no host/language aliases — later model code runs resolved
Linux `exec.shell` only. NO `ToolEnvironmentRouting` registration in this
target: Main's composition wires routing and supplies the trusted root +
selected backend. Host-runnable ownership/rejection suites:
`Tests/FloeAndroidCoreTests/EnvironmentOwnershipTests.swift` (authored, not
executed by the authoring job).

## What is and is not claimed

COMPILED (host macOS, this package): the whole graph above incl. GRDB +
vendored SQLite + FloePersistence + FloeAgentRuntime + bridge v1/v2.
NOT yet compiled here for android28 at delivery time: the actual product
`libFloeAndroidCore.so` (native build stays serialized; see HANDOFF.md).
Host tests prove schema/bridge/store semantics ONLY — no device runtime,
streaming cadence, Keystore, WAL kill/restart or UI claim.
G03-R1 ADDITION (2026-10-22): the `FloeEnvironments` target + lease
descriptor above are source-ready but NOT yet compiled (object compilation
and the ownership suites run in Main's integrated batch; the descriptor's
Android-only backend-gate branches are compile-checked on the android28
cross build).

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

### goal-core code batch (2026-10-21, job-7efd60bb51d14f02 — SOURCE ONLY, NOT compiled/tested)

Additive native run-control batch (plan.accept / goal.confirm /
conversation.compact, structured `goalDefinition` on ordinary `run.start`,
and the original post-run goal evidence-review/gate/CAS/continuation lane).
Ledger deltas (accepted by MAIN_RUN_CONTROL_CLOSURE_DECISION_20261020.json):
bridge matrix 84→87 tuples / 82→85 distinct commands (three appended
tuples, no rename/delete, mailbox 64/16/64KiB unchanged, no `child.create`);
feature baseline 182→183 operations / 40→41 G02 (ONE explicit
`CHA-MANUAL-COMPACT` operation, append-only; 36 families / 85 work packages
unchanged); `RunDomainError.Reason` gained exactly ONE additive closed case
`conversationActive`; `RunStartQuery.allowedKeys` gained exactly ONE
optional additive key `goalDefinition` (goal mode only, create-intent
refuses).

Module deltas in this overlay:

1. `Sources/FloeAgentRuntime/IntelligenceStore.swift` — the overlay SYMLINK
   was replaced with a regular reviewed mirror. Upstream bytes are
   PRESERVED VERBATIM (upstream SHA-256 at mirror time
   `ce8febbfc7ea31c8d6d769ceb172ee42aaadd79a219ec0c4660491282acca1b5`; the
   mirror's first 1611 lines diff clean against upstream). Everything added
   is a documented suffix block only: closed typed
   `IntelligenceAtomicCommitRefusal`, statement twins that run INSIDE a
   caller-provided writer `Database` (`latestPlanInTransaction`,
   `commitPlanRevisionInTransaction`, `commitGoalInTransaction`,
   `commitStructuredGoalAtLaunch`, `commitManualCompactionInTransaction`,
   `messageTimelineFingerprint`) plus two actor entry points
   (`messageTimelineFingerprint(conversationID:)`,
   `commitManualCompaction(...)`). All existing actor methods/callers above
   the marker are byte-equal to the original; no schema change; ONE
   DatabaseManager; no new table.
2. `Sources/FloePersistence/RunLaunchStore.swift` — reviewed Android mirror
   (already regular): SECOND documented delta only — additive
   `AtomicIntelligenceRunLaunchStore` protocol + `prepare(_, expectedRow:,
   atomicIntelligence:)` overload executing the trusted commit hook AFTER
   the existing-row digest CAS and BEFORE the first durable write of the
   SAME transaction. Original `RunLaunchRequest`/`PreparedRun` fields, the
   first-mirror `activatesEmptyOrdinaryHeader` behavior and every existing
   signature/caller are unchanged (the private helper only gains a
   nil-defaulted parameter).
3. `Sources/FloeAndroidCore` — two new Android-owned regular sources:
   `RuntimeFacadeRunControls.swift` (the three wire handlers + structured
   goal factory + canonical prompt + compaction engine selection) and
   `RuntimeFacadeGoalContinuation.swift` (original post-run lane; real
   `.conversation` owned leases + single flight + CAS + in-process
   continuation via the SAME pipeline with the frozen role vocabulary).
   Narrow additive edits: `BridgeEnvelopeV3.swift` (three appended
   `CommandRule` tuples), `RuntimeFacadeRuns.swift` (launch-pipeline
   internal threading: optional `messageRole` default `"user"`, optional
   `atomicIntelligence` hook (ordinary + digest-CAS paths only), optional
   `capturedLaunch` frozen pair; ONE shared `compactingConversations`
   reservation checked at step 1 AND the step-6 pre-commit re-check;
   goal-mode/frozen-route registration + retire dispatch/cleanup; `Run
   DomainComponents.settings` additive nil-defaulted original settings
   store binding), `RuntimeFacadeRunModels.swift` (`conversationActive`
   reason; goal/plan revision identities; `StructuredGoalDefinition`;
   `PlanAcceptQuery`/`GoalConfirmQuery`/`ConversationCompactQuery`; three
   handler-plan bindings), `RuntimeFacadeRunBridge.swift` (three processor
   cases + retirement Task cancel), `RuntimeFacadeRunIngress.swift`
   (`RunModelAssembly.resolvePreferred` for the compaction lane),
   `G02DomainServices.swift` (bind `cluster.settingsStore`),
   `RuntimeFacadeConversations.swift` (additive `plan`/`goal` durable
   read-projection fields on `conversation.get`, nil-honest, trimmed first
   under page pressure; `checklist` stays OMITTED).
4. Tests (authored, deferred): `BridgeEnvelopeV3Tests` /
   `RunDomainHandlerPlan` counts synced 84→87 / 15→18;
   `GoalCoreRunControlTests.swift` added (real store/handler/lane paths,
   no mirrored constants as proof). The Kotlin
   `SettingsDomainV1Test` matrix case synced 84→87.

`Sources/FloePersistence/DatabaseManager.swift` stays the frozen byte-
identical v46 mirror (verified this batch:
`5ab9f9893f5297b5554b2afd5bbd42fbe6677151bc57accf7e0dd4085676c971`).
Overlay link total moves 257→256 (the IntelligenceStore link became a
regular mirror). The iOS `FloeAgent` tree was NOT written through any link.

Out-of-scope follow-ups Main must apply when composing (NOT edited here):
`scripts/check-settings-domain.py` / `scripts/tests/test_settings_domain_checks.py`
pin 84 entries and the old test literals; `scripts/check-fixtures.py` pins
182/40 operation counts. These constants belong to the same approved
additive ledger (87/85 tuples; 183/41 operations) and must be raised by the
integration owner, never silently bypassed.

### goal-core code batch — additive rounds 2/3 (2026-10-21, SAME job-7efd60bb51d14f02 — SOURCE ONLY, NOT compiled/tested)

Review-accepted follow-up rounds on the SAME candidate files above, per the
Main steers recorded under `Local/Private/android-g02-20261018/goal-core-code-batch-20261021/`
(MAIN_UTF8_BOUND_CORRECTION_STEER / MAIN_APP_API_ADMISSION_AND_DETAIL_READ_DECISION /
MAIN_POSTRUN_STOP_SOURCE_REVIEW / MAIN_ACTIVATION_SUPERSESSION_STEER).
The three action-command wire contracts (`plan.accept` / `goal.confirm` /
`conversation.compact`) and the structured-`goalDefinition` `run.start`
payload declared in API_READY stay byte-stable; every delta below is a
body-only correction, an additive read member on an EXISTING command, or
internal control wiring. Ledger counts stay 87/85/183/41 (no new tuples).

1. UTF-8 prefix BODY correction: `ConversationTextBound.bound`
   (`RuntimeFacadeConversations.swift`) and `FacadeRunDomain.boundText`
   (`RuntimeFacadeRuns.swift`) now walk WHOLE UTF-8 sequences (lead byte
   determines width 1–4) and stop before a sequence that does not fully
   fit. Result is a genuinely valid UTF-8 prefix of at most `maxBytes`
   bytes with zero U+FFFD and correct zero-boundary behavior; the Main
   counterexamples `("中中",3)=="中"` and `("aa中中",3)=="aa"` hold.
   JSON/frame/page budgets are unaffected (measured after the fix; the old
   replacement chars only made output LARGER). No payload contract change.
2. Additive bounded DETAIL read on the EXISTING `conversation.get` (no new
   command tuple/label/store/table/schema; absent `detail` keeps the legacy
   reply byte-identical; a malformed `detail` is a typed envelope refusal
   BEFORE any read): closed request grammar `detail{kind goal|plan,
   id?, offset?(raw UTF-8 bytes), digest?, maxBytes?(1...32768, default
   32768)}` (continuation requires id+digest; mixed legacy arguments
   refused); paged canonical-JSON (sorted-keys, deterministic) delivery of
   the REAL durable `PlanDraft`/`ConversationGoal` rows with exact
   `kind/id/status/revision/digest/encoding/offset/nextOffset/totalBytes/
   truncated/content` plus the action-proof identities
   `revisionResourceID/revisionVersion` (goal `goal.<id>/rev:<n>`) and
   `planDigest`/`isDecisionComplete` (plan). First page without `id`
   resolves the current durable plan / latest NON-terminal goal, falling
   back to the latest TERMINAL goal so a completed goal stays inspectable
   (labelled by real status, never faked active). Every continuation
   re-resolves the owning durable row, proves digest/revision and the
   current owner/epoch/delete fences inside the read (stale content is a
   typed refusal; foreign/nonexistent identities reuse the SAME absence
   response). The FINAL serialized page (with real JSON escaping) is
   measured to fit the frozen 49152 page inside the 65536 frame via
   `FacadeFrameBudget.serializedBytes` shrinkage — never String.count.
   Additive `planAvailability`/`goalAvailability` flags explicitly
   distinguish summary TRIMMING from true ABSENCE. The ORIGINAL task
   checklist stays a SEPARATE service: the documented gap handed to Main
   (`TaskChecklistStore.latest(conversationID:/runID:)` →
   `TaskChecklist{conversationID,runID,revision,title,steps[{id,title,
   status,pending|inProgress|completed|blocked|cancelled,evidence[]}],
   updatedAt}`; `ConversationGoal` has NO checks field; the store is the
   already-linked shared authority; not waived, no parallel model, no new
   write, no arbitrary content/file handle API).
3. Real explicit Stop for the post-run review/continuation lane, wired
   through the EXISTING `run.cancel` only after the authoritative durable
   record/owner/state/revision proof and BEFORE the retired/terminal fast
   paths: `requestGoalReviewStop(runID:conversationID:)` synchronously
   (no await before the revoke) inserts the stop permit and removes the
   goal's continuation admission reservation for the EXACT completed run,
   then cancels the actual conversation-leased Task (transport unwinds
   cooperatively); the `.conversation` `RuntimeOwnedWork` lease stays
   attached until the handler REALLY returns (drain semantics unchanged;
   the existing retirement/privacy drain still waits it). Cancel acks
   `reviewStopping` honestly — never a fake settled/`alreadyRequested`
   while the review can still act, never a completed-history rewrite,
   never touching an unrelated or replacement run. `evaluateAndContinueGoal`
   gained stop/cancellation guards at stream entry, after the review
   await (a cancelled stream yields the ORIGINAL empty verdict and the
   caller then REFUSES), before the goal CAS, and at the final
   pre-`prepare`/launch boundary; the in-process continuation launch
   carries the additive default-nil `continuationStopPermit` through the
   SAME `start` pipeline and refuses at admission AND pre-prepare if the
   user's Stop won (a won C1 settles as the real same-activation run —
   no lossy bypass).
4. Activation SUPERSESSION fence (no timestamps anywhere in the proof):
   the review captures the real conversation-row activation
   stamp/digest via the mirror's additive `conversationRowStamp` actor
   entry, re-proves liveness before launch selection, and the durable goal
   commit now runs in ONE writer transaction via
   `saveGoalIfCurrent(goal,expectedRevision:conversationID:
   expectedConversationStamp:)` — so an OLD delayed review cannot
   re-order/mutate or auto-launch its old objective/frozen route after a
   NEWER explicit user goal/run C1 committed in the same conversation/root
   epoch; the existing `LaunchEpochFence` launch-fence primitive carries
   the liveness proof. Cancelling/invalidating an old review never fences
   or kills the newer user activation. Explicit user resume stays the
   original goal start/checkpoint path; no startup/background
   resurrection.
5. `RunDomainError.Reason` is now cumulative +2 additive closed cases over
   upstream: `conversationActive` (round 1) and `continuationStopped`
   (round 2/3; `.sessionFenced` code). No other vocabulary change.
6. `run.snapshot` gained ONE additive bounded read member `goalReview`
   (`none|active|stopping`, from the real work/stop registry via
   `goalReviewActivity(runID:)`) so the App can keep Stop available during
   review and show stopping until the REAL settlement; an inactive goal
   status is explicitly not a stopped proof. Page/frame budgets re-measured
   with the field present; all existing snapshot members unchanged.
7. Mirror integrity re-verified this round: the `IntelligenceStore.swift`
   regular mirror's first 1611 lines are STILL byte-identical to frozen
   upstream `ce8febbf…a1b5`; the additive tail now also carries the two
   extra actor entry points `conversationRowStamp(conversationID:)` and
   `saveGoalIfCurrent(…)` next to the round-1 `messageTimelineFingerprint`
   / `commitManualCompaction`. The iOS `FloeAgent` tree remains untouched
   (`git status` clean for it; nothing was written through any symlink).
8. Tests (authored, DEFERRED — not compiled/run): new
   `GoalCoreDetailReadTests.swift` (UTF-8 prefix helpers incl. the Main
   counterexamples, 2/3/4-byte cuts, exact/zero boundaries, cross-helper
   agreement; closed detail grammar and mixed-argument refusals; canonical
   reassembly + identity proof; stale-digest/foreign/mid-byte-boundary
   refusals; plan action-identity + availability flags; measured
   page-fit/progress loop) and `GoalCoreRunControlTests.swift` additions
   (stop-during-live-review lease-held-until-real-drain with no late
   writes; delayed review cannot mutate or launch after a newer user
   activation via the controlled barrier; stop scoping refuses
   foreign/replacement/new-generation targets; `reviewStopping` ack +
   snapshot readback follows real settlement).


## Alpha3 native freeze (2026-10-21)

The Android RunStore and IntelligenceStore are reviewed regular mirrors with
additive goal/resume behavior over the original v46 stores. Explicit resume
commits the original preparing state transition and native activation marker
in one writer transaction; cancellation and retirement recheck the exact run
owner before handing off. No Android database migration was added.

ConversationRunService.swift is now an exact-byte regular mirror of the
source used by this Android batch (SHA-256
`8dcb6ce34a18155438daad664c6ee2d691fd04dcbe6d9916d6bdad03a5d307f2`).
The relative link previously resolved to a different body on current iOS main;
this mirror preserves Android build provenance without changing that iOS file.
The remaining 254 relative source links retain their original authority.
This normalization changes file ownership only, not the compiled behavior.
Future upstream adoption requires an explicit diff and relevant checks.

The current ARM64 Android release core was crosslinked with Swift 6.4.1,
API 28 as the compatibility floor and 16 KiB ELF load alignment. Its runtime
closure contains 19 libraries; the ten SDK libraries outside that closure are
excluded from staging. Native compilation and static packaging evidence are
separate from App/device acceptance. Original symbols and canonical versus
packaged hashes are retained with the private exact-source artifacts.

## G02-R7 private-workspace cleanup repair (2026-10-21)

`Sources/FloePersistence/WorkspaceStore.swift` was previously a relative
symlink into the protected iOS tree (`../../../../FloeAgent/Sources/
FloePersistence/WorkspaceStore.swift`). The bridge normalized a symlink
scope to the iOS destination, so the Android owner atomically replaced ONLY
this Android path with an exact byte-for-byte regular mirror before the
cleanup repair. The upstream file was not modified and still has SHA-256
`be046a7c7365116498d724bebf5bf176eb824b39678fe70d01a9c859f63c1da6`;
the regular mirror had the same hash at conversion and carries the
Android-only additions below. Future upstream adoption of this file
requires an explicit diff; the remaining relative links are unchanged.

The Android-only additions are marked `ANDROID-ONLY (G02-R7)` and are the
only changes to that file: `retirePrivateTaskForCleanup(workspaceID:
expectedRelativePath:)` performs the survivor/kind/exact-path/durable-queue
admission and the conditional `workspaces` delete in ONE original
`DatabaseManager.writer` transaction (no rehoming), and
`finishLocalCleanup(workspaceID:expectedRelativePath:)` deletes only the
exact queue binding after a real file effect. The original `pendingLocalCleanup`,
`finishLocalCleanup(workspaceID:)`, `deleteWorkspace`, schema, V36 trigger and
queue are byte-unchanged. No new migration or parallel ownership registry was
introduced.
Main qualification, 2026-10-22: the focused `EnvironmentOwnershipTests`
suite passed all 20 tests after correcting five actor-property assertions
in the test source (the original compiler failure was retained). The
`FloeEnvironments` target then produced all 13 ARM64 object files with
Swift 6.4.1, `aarch64-unknown-linux-android28`, six jobs and the pinned Android
SDK. This is actual object compilation, not typecheck-only evidence. The
nine linked original files were checked against the integration source.
This verifies the environment component; it does not prove the future
App/JNI lease-to-process bridge, merged rootfs, service or tool routing.

G03-R1 integration source check: the occupied iOS checkout predates main's
`ToolExecutionOutput.outputFiles` and `ArtifactNamespace.runOutputs`
additions. Main's shared Tool contracts require the original
`FloeModels/RunOutputFile.swift`, which the older Android per-file source
list omitted. Its byte-identical source at
`ee1816ae41fd6d74826696f02ffeb3ebcc1f0965` is included as an explicit
snapshot, preserving the occupied iOS checkout. Qualification materializes
original linked inputs from the actual public base, retaining only the
existing documented Android overlays; this avoids mistaking the older
local iOS branch for the published integration source. The same source
form must be used for the next full shared-core build.
The integration component was then compiled with the explicit OSS Swift
6.4.1 compiler and matching Android SDK against the actual public-base
originals, including that missing model. All 13 environment object files
were produced for `aarch64-unknown-linux-android28`; this was not a full
App rebuild and did not repeat the device cohort. Initial minimal-host
resource setup and accidental system-compiler failures were retained.


## G03-R2 shell, jobs and lifecycle integration (2026-10-22, implementation)

This section describes source ownership and platform deltas. It does not
claim a qualified native library, product APK or device behavior. The
integration uses the immutable public-main originals plus Android overlays;
the occupied older iOS checkout is not the qualification source.

`FloeAndroidShellTools` retains six original relative links:
`DesignGuestWriteGate`, `SessionExpiryScheduler`, `ShellCommandPolicy`,
`ShellInputValidation`, `ShellOperationJournal`, and `ShellOutputSanitizer`.
Its narrow mirrors retain the original service/session/tool contract:
`LocalShellBackend`, `LocalShellService`, `LocalShellTool`,
`ShellSessionCenter`, `ShellSessionTools`, and `ShellToolRegistration`.
The Android mirrors omit Apple-only guest-shape/backend references and
carry the real original run, conversation, environment and tool-call
identities into the typed Android transport. The additional tool-call
identity is Core-private correlation metadata and is removed before the
runtime command payload. `AndroidLinuxShellBackend` and
`LinuxShellTransport` are Android-owned. They admit only the resolved
Linux backend; uncertain transport, cancellation and caller timeout retain
ownership until actual stop/release proof. A host interpreter is never a
fallback. The single workload gate also covers detached reconciliation.

`FloeAndroidJobTools/NativeJobHandlers` is an original relative link.
`BackgroundJobService` is a narrow original mirror with additive observation
and cancellation of its actual owned processor tasks. The original durable
store, runtime-issued submission provenance, terminal state writes and
dependency resolution remain authoritative. `BackgroundJobTools` requires
an explicit trusted output root and permits composition without tool
advertisement; it does not expose unfinished execution. Android-owned
`JobLiveWork` and `ExecShellJobRunner` bind processor lifetime to actual
Root/foreground ownership and require remote settlement proof before
terminalizing a shell job. An awaited independent task carries stop
reconciliation after cancellation of the processor's caller.

`FloePersistence/RunLifecycleRetention` is now a narrow mirror of the
original file: only the canonical spool-root resolver changes. The accepted
native Root binds an explicit directory and epoch; writer and retention
consume that same resolver. Unbinding follows actual native store close
for that epoch. There is no process-global Application Support fallback.
The original retention transaction and ownership checks stay intact.

Core-owned composition in `RuntimeFacadeLinuxBindings`,
`RuntimeFacadeJobBindings`, `G03JobLifecycle`, `LinuxShellJobSettlement`,
`LinuxShellMailbox` and `RunForegroundProjection` reuses the existing
accepted Root, database, conversation deletion fence and runtime work
registry. Job processors acquire their actual foreground protection before
target execution; original terminal callbacks retain ownership through
output/dependency writes. Root retirement first suspends new admission,
then leaves the proof channel available until real job and shell cleanup
has drained. A stop request, notification click, Binder death, PTY EOF or
reaped root PID alone never releases the environment.

Model shell/job advertisement remains disabled until the actual independent
workspace exchange and runtime capability are qualified. API/JNI binding,
object compilation and App acceptance are separately recorded in the
current progress document; historical component checks do not cover later
source changes automatically.

A configured shell work-tracking hook now fails closed when original Root
ownership is refused; omitting the hook retains standalone module behavior.
The product composition advertises only qualified `exec.shell` at this stage.
Interactive `shell.*` implementations remain reusable source, pending their
IDE/session ownership integration, and are not advertised merely because
an engine can start a PTY. Process exit and Core file-save receipt are distinct:
a zero command exit cannot produce a successful tool result while workspace
save is conflicted or unknown. The trusted host confirms file status from the
Core grant's actual export receipt and drains entered Core file callbacks
before completing the native poll/job proof.


### G03-R2 remote-advance link audit (2026-10-22, job-4d35db884ec64d95)

Origin/main advanced 6b76ede0 → 12e36ba7b41d24634526ea55568fe88e4de26745
(parallel iOS merge; the Android diff from 6b76 is empty). All 268 per-file
original links were independently re-verified against the 12e36 blobs
(`git cat-file` byte compare, 264 identical). Exactly four linked targets
changed upstream and are handled as follows:

| Link | Handling |
| --- | --- |
| `FloeAgentRuntime/DelegateTool.swift` | refreshed to the 12e36 blob: additive `runner(for:)` getter over the existing live-run map; no new platform surface. |
| `FloeAgentRuntime/ChildToolDiscovery.swift` | refreshed to the 12e36 blob: additive bounded durable-checkpoint snapshot of the child's OWN selection; resume re-derives the offered universe from the CURRENT parent ceiling. |
| `FloeSkills/OfficialBundledSkills.generated.swift` | refreshed to the 12e36 blob: generated skill-catalog asset/markdown revision only (floe-office 1.4.0→1.5.0 exact-text guidance). |
| `FloePersistence/TaskScheduleStore.swift` | **pinned Android regular mirror at the OLD 6b76 blob `b9e261f9dbc9dc1bd2fa416f0fb5a3c2386dc035`** (git-blob verified; file is no longer a symlink). The 12e36 version adds cleanup-reminder SQL whose GRDB/schema dependencies are NOT part of the Android R2 package; porting them (or unrelated iOS schedule/migration work) into R2 is out of scope. The mirror preserves the exact previously-qualified bytes; the iOS original was never written through. |

### G03-R2 shell ledger ↔ conversation-deletion lifetime (2026-10-22, job-4d35db884ec64d95, coordinator steer)

A detached `exec.shell` may outlive its parent run. `ledgerIndex` retains
settled dispatches while engine leases or claimed `shell.start` tickets
remain, but the ORIGINAL `RunDomainDeletionLifecycle.drainOwnedWork` loop
previously only saw run ownership (empty once the parent is terminal) and
durable-job tokens. The contract is now closed with the EXISTING
authorities, no new stores:

* admission requires the ORIGINAL `ToolContext.conversationID`; without it
  the tracking hook returns nil and `LocalShellService` refuses dispatch
  (fail closed, no workspace guessing);
* every ledger worker attaches a REAL `RuntimeOwnedWorkRegistry` receipt
  (kind `.tool`, owner `linux-shell:<conversation>:<run>`, durable-job lane
  precedent) before dispatch and detaches it exactly once only on the
  proven release — never on cancel/timeout/EOF;
* target-only surface `tokensForConversation(_:epoch:)` and
  `drainConversationTick(conversationID:epoch:)` mirror the durable-job
  shape and run INSIDE the original fence loop; unrelated conversations and
  global counts never block a target drain;
* the ledger end predicate became run-scoped
  (`LinuxShellMailbox.hasLiveTickets(runID:)` + `ownedSessions(runID:)`),
  while process retirement (`isDrained()`) keeps the conservative global
  view.

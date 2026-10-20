# FloeAndroid G02 Run + Attachment publication provenance (2026-10-20)

Qualification owner: job-e9482f8e79ff4310 (runtime-runs-native-assembly-qualification).

## What was published

1. **Run repair successor (13 files)** from `runtime-runs-native-assembly-repair-source`
   (candidate archive b41f5627…, parent archive 6c36124e immutable). The
   duplicate `RunOwnedToolCancellation` declaration was removed from
   `RuntimeFacadeRunIngress.swift` at publication (canonical
   `RuntimeFacadeRunCancellationPort.swift`, caps-published, retained; the
   candidate block was byte-identical to it). Exact candidate/after hashes:
   `evidence/AFTER_PUBLICATION_MANIFEST.json`.
2. **Attachment staging (11 files)** from `runtime-attachment-staging-source`
   (archive 9dcbed63…) plus three additive patches: ConversationStore staging
   seams, CMake staging TU, androidTest synthetic provider.
3. **Frozen upstream refresh (9 of 10 entries)** from main@5f33702276…
   (`main-upstream-g02-consumed-source-set-20261019/MANIFEST.json`): 8
   symlink mirrors atomically replaced with pinned regular snapshots and
   `ChildRunPayload.swift` ADDED as a regular file (protected root has no
   such original). `TemporaryChatToolPolicy.swift` (3479a0a1) was already the
   caps-published regular mirror and was reused unchanged. Protected FloeAgent
   sources were never written.

## Finite compiler/behavior repairs (all recorded with raw logs)

- Attachment staging: `lock.inside` call-site mismatch (helper is an instance
  method), `FileHandle(forUpdatingTo:)` → `forUpdating:`, nested-lock deadlock
  in BOTH `refs(forLease:)` and `attachmentRef(handle:)` (single lock-held
  projection helper), `retire()` no longer destroys finished
  (readyToPublish) ingresses, `availableCapacity` resolves the nearest
  existing ancestor, strict-decode `Set(payload.keys)`, non-optional digest.
- Run domain: canonical HarnessEvent `approvalReviewChanged`, real
  `AttachmentStagingLaunchAuthority` reserve/commitAcknowledged/
  releaseReservation adapter over the producer batch lease API (bounded
  identity map), production `RunCredentialArgumentNormalizerAdapter` over the
  qualified `CredentialArgumentNormalizer` + same-root
  `AndroidCredentialVault` (temporary runs keep nil), admitted environment/job
  identity preserved into `RunOwnership` and the runtime configuration
  (`localLinuxGuestEnvironment` stays the honest resolved false), REAL P8
  personalization feed adapter awaiting the qualified
  `FacadePersonalizationEvents` handlers inside the owned task with the exact
  `PersonalizationEventOperationLease` and a same-lease-map validator +
  cycle-resolving binder, `FacadeEventPump` epoch fencing reported before
  detach classification, durable window kept sequence-ordered/deduped,
  snapshot pages refuse typed (`payloadTooLarge`) instead of dropping text
  or claiming completion (staging refusal, fitSnapshotPage, mid-stream
  `answerComplete=false`, no-live-owner `Complete=false`), retry admits
  `checkpointed` resumes and checks the conversation delete guard first,
  steer replay surfaces `alreadyAccepted` from the runtime ledger, late
  cancels for this-generation-retired runs answer `alreadyRequested`.
- Test fixtures: REAL bootstrap generations per fixture (monotonic epoch,
  storeReady, same owned DatabaseManager, awaited shutdown control +
  ownedStorePhase=closed + generation-gone; teardown FAILS on incomplete
  retirement), provider-gate/streaming preconditions before cancel/steer/
  retry proofs, nonblocking drain-observation boxes (never `await
  task.result` joins), exact per-conversation exactly-once feed assertions.
- Android mirror delta: NONE (the `AgentRuntime` discovery-append was
  reverted per MAIN_TEMPORARY_DISCOVERY_PRESENTATION_DECISION; canonical
  presentation-only tools.list/tools.search preserved).
- Kotlin: sealed `ScopeCommand.command` accessor, `longOrNull` cast, clean
  `stringOrNull`, test `jsonPrimitive` cast; service: declared-vs-actual
  sizeExceeded, open-failure abort + typed outcome, effect-pump resync walk.

## Verification (this package, exact commands in REPORT.md)

- Swift 6.4.1 host module/object build rc=0; full shared XCTest 825/0;
  Run 87/0; attachment 37/0; JVM 22/22; android28 FloePersistence
  object/module probe rc=0. nativeQualified=false, productQualified=false —
  the one composed native/JNI/16KiB/two-channel App batch remains Main's.

## Production binding qualification follow-up (2026-10-20, job-5c0981e3677f4393)

- Scope: ONE additive test file
  `shared/Tests/FloeAndroidCoreTests/RuntimeFacadeRunProductionBindingTests.swift`
  (6 cases). No production source changed: all 24 published Run/attachment
  files verified byte-identical against the immutable archive 60d6a54b…
  before and after.
- Executed the previously compiled-but-unexercised production seams:
  the REAL `RunCredentialArgumentNormalizerAdapter` over the same-root
  `AndroidCredentialVault` (bootstrap-owned DatabaseManager, exact
  root+token+epoch, real `CredentialStore`, synthetic in-process physical
  gateway, production `RuntimeOwnedWorkRegistryAttachment`) inside REAL
  facade launches; the ORIGINAL approval card, pre-dispatch checkpoint
  boundary and ongoing provider conversation carry ONLY the retained
  handle placeholder — raw synthetic bytes exist nowhere durable.
  The admitted environment/job identities were observed on the REAL
  dispatch `ToolContext` (main path) and on the REAL delegated-child
  dispatch, where the ORIGINAL `deny:child-environment-binding` guard
  refused a retargeted delegated call through the runtime-issued
  dispatcher with exactly one legitimate executor effect and the bound
  ownership observed WHILE LIVE via a test-owned executor-edge hold.
- Original semantics honestly recorded (unchanged): the runtime forwards
  the provider `.toolRequest` to the service BEFORE normalization and the
  durable timeline row persists the SecretRedactor-sanitized intake view;
  `RunApprovalScopeBinding` grants hostID-nil scopes, so a human-allowed
  `.hostPath` call is denied by the unchanged scope guard (the positive
  effect case uses the permitted `.local` scope). `credential_records`
  FKs require real owner rows; qualification fixtures seed them through
  the ORIGINAL atomic prepare.
- Verification: Swift 6.4.1 host build rc=0 (baseline + tests); focused
  6/6 pass rc=0 (logs test-pb-05); full shared XCTest 831/0 rc=0
  (log full-01) preserving all 825 parent identities (0 missing) with the
  6 new cases added. nativeQualified=false, productQualified=false; the
  composed native/App/device batch and G03 Linux resolution remain Main's.

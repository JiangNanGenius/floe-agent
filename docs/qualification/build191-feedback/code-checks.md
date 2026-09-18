# Build 191 feedback repair — pre-build code checks (local)

Date: 2026-09-19. Branch `codex/build191-feedback-repair`. The media/PPT
runners and module probes below were executed against the current working tree
and re-verified after main's integration commits (source HEAD moved from
`ed73c23f` to `900b4952` during the work; the later `b08b9bfa`/`1804b8ee`
commits touch no scoped source, so the results below apply to the current
checkout). Main's `project.yml`/project
regeneration and build number 192 are preserved and not modified by this
record. Task: integrate the media-review fixtures as tracked tests, run the
landed rich-PPT marker end to end, and review the cross-module App/module
interfaces before the cloud App build (final integration review).

No root SwiftPM build, no App/CI build, no simulator/device UI run, no paid
provider call, no commit, no push, no version change. Every command below was
executed in this checkout; results are actual output, not expectations.

## 1. Tracked test integration

| Command | Actual result |
| --- | --- |
| `bash FloeAgent/scripts/tests/media_review/run_media_review_tests.sh` | exit 0 — `REVIEW-PROVIDERS: PASS (89 checks)`, `REVIEW-OWNERSHIP: PASS (45 checks)`, `REVIEW-GIF: PASS (22 checks)`, `MEDIA REVIEW SUITES PASSED` (156 checks) |
| `PPT_EVIDENCE_DIR=Local/Artifacts/build191-ppt bash FloeAgent/scripts/tests/pptx/run_rich_deck_checks.sh` | exit 0 — Swift structure checks `77 passed, 0 failed`; independent `python-pptx/openpyxl` read-back `checks failed=0` (18 checks) |
| `bash FloeAgent/scripts/tests/run_feedback_shell_bridge_host.sh` | 20/20 real `FloeShellBridge.mm` host checks pass (unchanged harness, re-run) |
| `python3 FloeAgent/scripts/tests/test_feedback_python_runner.py` | 13/13 CPython runner checks pass (Python 3.9.6) |
| `python3 FloeAgent/scripts/tests/ide_review/review_invariants.py` | 21/21 review invariant checks pass |
| `cd FloeAgent && python3 -m unittest scripts.tests.test_release_review_workflows scripts.tests.test_verify_direct_unsigned_artifact` | `Ran 32 tests … OK` |

New tracked files: `FloeAgent/scripts/tests/media_review/` (fixtures + runner +
README, ported from the private media-review harness) and
`FloeAgent/scripts/tests/pptx/` (standalone port of
`FloeAgent/Tests/FloeDocumentsTests/RichDeckChecksTests.swift` + runner +
README). The media runner always compiles `FloeCore` freshly from the current
sources before linking any fixture; it never consumes the stale prebuilt
FloeCore interface. Both runners exit 2 with `SKIP` (not a pass) when the
cached Xcode-beta-compatible toolchain or cached dependency artifacts are
missing, and neither reads anything under `Local/Private`.

## 2. Rich PPT marker round trip (marker landed)

`FloeDocuments/OfficeDocumentBuilders.swift:345` writes
`ppt/embeddings/floe-chart-data-<n>.xlsx`. The generated deck
(`Local/Artifacts/build191-ppt/rich-deck.pptx`, 19,258 bytes, run log next to
it) contains `floe-chart-data-1..3.xlsx` with `Sheet1!$...` formulas and
`externalData` relationships; the independent python-pptx/openpyxl parser
(no Floe code) accepted all of it. Strict save validation accepts the deck and
rejects a copy whose chart lost its workbook; a text edit preserves chart and
media bytes byte-for-byte.

## 3. Interface review (App ↔ module)

Checked against the current sources with real modules:

| Command | Actual result |
| --- | --- |
| `swiftc -typecheck` of all 63 `Sources/FloePersistence` sources (fresh FloeCore/Models/Tools modules; cached GRDB/FloeSecurity) | exit 0, 0 errors |
| `swiftc -typecheck` of all 10 `Sources/FloeMedia` sources | exit 0, 0 errors (2 macOS-27 AVFoundation deprecation warnings, unrelated to this change) |
| `bash Local/Private/build191-feedback/final-code-review/app-interface-probe/run_app_interface_probe.sh` (emits fresh FloeCore/Models/Tools/Workspace/Providers/Persistence modules, then typechecks the current `RemoteVideoTools.swift` with the `#if canImport(UIKit)` guard removed and mirrored app declarations) | exit 0, 0 errors |
| `DownloadCoordinatorProbe.swift` (verbatim extraction of `MediaRetryBackoff`, `MediaArtifactBackgroundEvents`, `MediaArtifactDownloadCoordinator` typechecked against the fresh modules) | exit 0, 0 errors |
| `swiftc -typecheck -enable-testing FloeAgent/Tests/FloePersistenceTests/MediaGenerationJobStoreTests.swift` (fresh testable FloePersistence) | exit 0 — the tracked persistence test stays source-compatible with optional ownership/idempotency |

Observations from the review (no defect needed a fix in the scoped files):

* Optional media IDs: `MediaGenerationJob.canvasID/documentID` are `UUID?`
  (`FloeCore/CreativeMediaModels.swift:202-203`), the store stores NULL for
  conversation jobs and never fabricates an owner ID
  (`FloePersistence/MediaGenerationJobStore.swift:47-52,120-121,388-410`), and
  `WorkspaceCanvasView.swift:6269,6286` unwraps at both canvas callsites. No
  other App call site treats these as non-optional.
* Tool registration: `registerRemoteVideoTools(center:)` is wired at
  `AppEnvironment.swift:540`; the four `video.*` names are unique in the
  catalog (`video.inspect/edit/extractFrames/transcode/...` remain media
  tools). `RemoteVideoTools.swift` is in the regenerated
  `FloeAgent.xcodeproj/project.pbxproj` Sources phase (build file line 2844),
  so the earlier "not referenced" residual is resolved by main's regeneration.
* Native host callbacks: the App uses the Swift-imported host API
  (`OfficeDocumentEditorView.swift:434,476,894,921` for
  `enterEditMode { … }`, `onWorkingCopyOpenedWithPermission`,
  `onEnginePermissionChanged`), matching
  `ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.h:38-68`; the host
  workflow run `35373122891` compiled and Swift-imported the same API.
* Cancellation/terminal races: submission applies the provider result through
  `transition` (a concurrent cancel wins), the download coordinator refuses to
  announce a non-`ready` job and closes expired result URLs truthfully
  (`BackgroundRunCoordinator.swift:2058-2101,2158-2166,2606-2619`); all
  typechecked above.
* Swift 6 captures: every harness/probe compiles under Swift 6 language mode
  with `StrictConcurrency` + `NonisolatedNonsendingByDefault`, including the
  `@MainActor @Sendable` tool closures and the `@unchecked Sendable`
  URLSession delegate.

## 4. Limits (not covered here)

* macOS `swiftc` typechecks/probes are not the iOS App target compile. The
  single cloud App build remains the gate for the App files
  (`RemoteVideoTools.swift`, `BackgroundRunCoordinator.swift`,
  `AppEnvironment.swift`, `WorkspaceCanvasView.swift`,
  `OfficeDocumentEditorView.swift`) and for iOS-only module differences.
* The tracked Swift Testing suite (`RichDeckChecksTests.swift`) was not
  executed locally (it needs the package test runner); the `pptx` harness runs
  the same body standalone and the marker makes the suite runnable in cloud
  CI.
* v42→v43 was exercised on fresh fixture databases, not a real device store;
  real provider acceptance with user keys was not performed (no paid calls).
* The media/PPT runners depend on cached Xcode-beta-built dependency objects
  (`.build/apple/Products/Debug`) and checkouts; a clean machine must restore
  them or accept the truthful `SKIP` exit 2. The IDE git harness likewise
  depends on the previously cached libgit2/SwiftGitX artifacts, as stated in
  `FloeAgent/scripts/tests/ide_review/run_git_review_harness.sh`; the
  invariant leg re-run here does not need them.

## 5. Residuals for the main integration

1. Run the cloud App build (build 192) with the regenerated project; it is the
   first semantic compile of the App-target changes.
2. Device: v42→v43 upgrade on a production-sized database, `dash -i`/detach
   shell recovery, Office edit-permission UI, and one minimal paid
   submit/poll/download per provider are still user-side checks.
3. `Local/Private/build191-feedback/release-review` test modules and the
   remaining private review fixtures stay private until their owners decide.

中文摘要：本轮把 media-review 的 156 项夹具测试与 runner 固化为
`FloeAgent/scripts/tests/media_review/`（每次先用当前源码重编 FloeCore），并新增
`FloeAgent/scripts/tests/pptx/` 本地 runner：落地 marker 后真实生成 77 项结构检查
通过、python-pptx/openpyxl 独立回读 0 失败。跨模块接口用真实模块 typecheck 复核
（FloePersistence 63 文件、FloeMedia 10 文件、RemoteVideoTools 探针、下载协调器
探针、tracked 持久化测试 source-compat），未发现需要修改的具体接口缺陷；App 目标
的语义编译仍是后续云端 App 构建的门槛。

Private evidence: `Local/Private/build191-feedback/final-code-review/` (review,
probe sources, commands).

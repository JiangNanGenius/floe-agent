# Phase 2 — Documents / IDE / Office repair evidence

Date: 2026-09-21. Base: `46422286` (post Build211). Branch: `codex/tinyemu-phase2-documents`.

## Crash evidence (log API + verified symbols)

Submission `856863bd-7ddf-4803-a122-8169acbeb20e` (received 2026-09-20T12:25:13Z, 18 diagnostics chunks, build 211, iPad16,10) contained four MetricKit crash payloads. Symbol artifact `release-symbols-1.7.0-build211` (run 35505655482, artifact 10604260760, sha256 b3b7c55d…, app UUID C1017589-E84C-3133-8E62-25AB89663343) was downloaded selectively into `Local/Private/symbols` (≈490 MB) and matched by UUID before symbolication with `atos -l 0x100000000`.

### Crash A — 2026-09-20 22:10:31, SIGKILL 9, `Namespace FOUNDATION, Code 0x1`

App frames (UUID C1017589 verified):

```
LocalGitService.repositoryRoot(at:)            LocalGitService.swift:25
LocalGitService.snapshot(at:commitLimit:)      LocalGitService.swift:37
SourceControlCenter.refreshRepository()        SourceControlCenter.swift:206
```

Preceding frames: `libsystem_pthread` → `ios_system set_session_errno (ios_system.m:197)` (immediately after `ios_exit` at ios_system.m:191, confirmed by nm: `ios_exit`=32576, `set_session_errno`=32624, `_exit`=32668) → `text parse_pos (sort.c:632)` → `_sigtramp` → `pthread_kill` → `abort` → Swift runtime (`swift_*`) → Foundation (`-[NSFileManager fileExistsAtPath:]` region, offsets +7123404/+158424).

Interpretation remains under investigation: the stack identifies the Git
filesystem walk and ios_system/text frames, but symbol adjacency and shared
process membership alone do not prove shell-thread exit caused the Foundation
termination. The dedicated Git task owns root-cause verification and repair.
The build204 payload is separate and was not symbolicated with build211 symbols.

### Crash B — 2026-09-20 22:01:31, SIGABRT 6

Top: `libsystem_kernel __pthread_kill` → `abort` → two `FloeOfficeNative` frames (UUID D14AB08E, offsets +94831684/+25355772; **no dSYM shipped** in the symbol artifact, so these stay unresolved) → `_sigtramp` → app frames that resolve to the **MLX/Qwen35 local-model path** (`getItemND MLXArray+Indexing.swift:695`, `Qwen35GatedDeltaNet.generalConv Qwen35.swift:445`, … `LLMModel.prepare KVCache.swift:128/LLMModel.swift:30`). Frame→binary mapping was re-verified: the app offsets resolve `(in Floe Agent)` in the UUID-matched dSYM, so this is a local-model inference abort with FloeOfficeNative frames on the same thread (shared process), **not** an Office-edit save/close abort. Relayed to the assistant worker owning local-model repair. Do not treat as Office root cause.

## Implemented repairs (this task)

1. **Stale right-hand workspace on conversation switch** — `AppRouter.workbenchSelection.didSet` now repoints workspace-backed inspector panes (`changes/workspaceFiles/browser/progress/childAgents/permissions`) to the newly selected conversation or closes them; `InspectorColumnView` is re-created per route via `.id(route.id)` on both iPad column and iPhone drawer so the previous task's file tree/preview state cannot linger. Outer split hierarchy unchanged.
2. **PDF overlay floating over active TXT** — `WorkspaceIDEView` gates native overlay visibility on `state.activePath == request.path` (the workbench's actual active editor), not only the web-reported `visible` flag that can go stale when the web tab closes.
3. **PDF/Office fixed narrow/clipped region** — `IDEWorkbenchState.applyNativeDocumentMessage(_:in:)` converts the web component rect from viewport CSS pixels into the WKWebView's coordinate space (zoom scale + scrollView→webView conversion) before the native overlay frames/offsets with it.
4. **DOCX Chinese squares** — `OfficeDocumentBuilders`: `w:eastAsia` now names `PingFang SC` (installed system CJK family on all supported iOS/iPadOS targets; previous `Source Han Sans SC` is not installed) in docDefaults, every style, and every generated run; added a valid `word/theme/theme1.xml` (full DrawingML cardinalities) wired through `[Content_Types].xml` and `word/_rels/document.xml.rels`. Engine font discovery on device still needs runtime confirmation (see risks).
5. **Office close/recovery honesty + functional lifecycle recovery** — the engine's unexpected-close callback now points the user at Retained Documents (bilingual), and the failed surface copy is bilingual. More than wording: `OfficeFileSession.recoverFailedSession()` is a new functional recovery path for `.failed` sessions (open watchdog timeout, engine close timeout, runtime failure, unexpected close). It tears the wedged/dead controller down through the existing *bounded* `closeController()` (never blocks on the unsettled engine), refreshes `hasUncommittedChanges` from the actual working-copy digest (conservative `true` when unprovable), and re-activates a fresh read-only preview of the *same retained working copy* — unsaved edits stay reachable, and engine generations under `engine/` are preserved by `workspace.close`. An editable failure previously had no action at all (Retry was read-only-only); the failed surface now offers "恢复文档 / Recover Document" for every failed session. Remaining native limit: the pinned host's `closeWorkingCopy` itself cannot be interrupted (its UIDocument close has no cancel hook), so recovery always detaches at the 8s bound and leaves the engine's own teardown to the host process; the retained copies survive regardless.

## Checks run

- `swift build --target FloeDocumentsTests` (Xcode-beta, shared verified scratch `/var/folders/.../swiftpm-floe`): **Build complete** (real compile, Swift 6 mode).
- `xctest FloeDocumentsTests.xctest`: **139/139 passed**, 0 failures — includes new assertions that generated DOCX names `PingFang SC` in styles/theme/per-run fonts and wires the theme part (macOS package test host; engine rendering itself is iOS-only).
- Full `swift test` was **not** runnable on this Mac: unrelated `FloeLocalModelsTests` require macOS 15.4 availability guards (pre-existing, out of scope).
- App-target SwiftUI files (`FloeApp/*`) have **no local compile** (heavy app build deferred to cloud CI); concurrency-critical edits are small and reviewed, but Swift 6 diagnostics require the cloud App build.

## Cross-worker interface notes

- Git crash repair (`LocalGitService`, `SourceControlCenter`, `Sources/FloeGit`, related tests) is explicitly handed to the dedicated Git task with the stack in §Crash A. This task made **zero** changes there.
- Local-model crash (Crash B stack) relayed to the assistant worker. No FloeOfficeNative C++ source changed, so the release_preflight host source digest/pin (artifact 10599654752) is unaffected; **no native component rebuild is required by this task's changes**.
- `Package.resolved` drifted twice via the shared SwiftPM scratch (stale checkout state) and was restored both times; final tree matches the pinned lockfile.

## Limitations / risks

- DOCX font repair is verified at the package-XML level only. The pinned engine's runtime font discovery (system CoreText vs private fontconfig) is unproven; if the engine does not see system fonts, a licensed bundled CJK font would need to ship in the host resources (native rebuild + pin update) — flagged as the follow-up if device testing still shows squares. Desktop Word without PingFang substitutes an installed CJK font.
- Overlay rect conversion assumes the reported rect is in the web view's viewport CSS space (matches `getBoundingClientRect` + disabled scrolling/zooming). iPad verification pending on device/cloud build.
- Crash A root cause (ios_system session threading) is evidence-supported but the definitive fix belongs to the Git task; Crash B root cause sits in the MLX model path owned by the assistant worker.
- No TestFlight/upload performed here (explicitly out of scope); no secrets, transcripts, or raw log records are included in this document.

## Coordinator integration review

Integrated worker `3b289993` as `143f7793`. Corrected the native overlay's
SwiftUI modifier order: clipping now occurs after the document frame but
**before** its editor-pane offset. The previous clip after offset retained
an unshifted clip boundary, truncating the right/bottom of a moved surface;
this matches the reported partial document region. Device confirmation pending.

Full App dSYM was removed prematurely by the worker during active Git analysis.
Coordinator restored exact artifact `10604260760` into private
`symbols-restore`, reverified App UUID, and notified the Git worker. Retain it
until dependent investigation completes. No private contents are reproduced here.

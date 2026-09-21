# Device feedback repair — Linux/TinyEMU, Office, IDE and local models (2026-09-21)

Base revision: `cbbadcb6` (build 216 delivery). Work branch:
`codex/device-feedback-repair-20260921`. This document records the implemented
repair, the focused validation that ran locally, and the checks that still
require cloud CI, a rebuilt native Office host or a physical device.

Nothing here publishes a release, moves a tag or claims device acceptance.

## 1. Linux / TinyEMU

**Terminal entry (`FloeAgent/FloeApp/Terminal/`)**

- `LocalTerminalView.swift`: a missing or unqualified image no longer shows a
  raw English error plus a dead Start button. `LinuxGuestError.imageNotQualified`
  now sets `missingImageID`, and the surface presents the Download and Start
  Linux card.
- `LinuxImageInstallCard.swift` (new): reuses the App-shared
  `EnvironmentPackageJobs` job keyed `linux-image:<id>` (one job per pinned
  image, shared with settings) and the verified installer through
  `FloePlatformServices.installLinuxGuestImage(id:onProgress:)`. Shows the real
  archive size (HEAD probe, no guessed size), byte progress, cancel and retry,
  and surfaces the truthful unavailable/space/digest/cancel messages. A
  successful install auto-starts the shell once.
- `Localizable.xcstrings`: `terminal.linux.*` (en + zh-Hans).

**Verified installer (`FloeAgent/Sources/FloeExecution/Linux/LinuxGuestImageStore.swift`)**

- `LinuxGuestImageInstallError.insufficientSpace(required:available:)` and
  `.cancelled`; `LinuxGuestVolumeSpace` reads
  `.volumeAvailableCapacityForImportantUsage` and maps Cocoa out-of-space
  errors. Extraction/import checks free space before writing.
- `LinuxGuestImageDownloading` gained a progress callback; the archive is
  space-checked against the HTTP Content-Length before bytes are written.
  `installTrustedImage` propagates cancellation instead of disguising it as a
  download failure.

**Explicit environment preparation**

- `FloeAgent/Sources/FloeExecution/Tools/PrepareLinuxEnvironmentTool.swift`
  (new): `environment.prepareLinux` takes no arguments — no image URL, no
  install script — and returns `prepared` / `prepareFailed` / `cancelled`
  with the installer's reason.
- `RoutingLocalShellBackend.activateWithPreparation` and
  `GuestPythonRuntime.run(prepareLinux:)` prepare once and then resume the
  original command, so a model that explicitly needs Linux waits for the
  install rather than failing or falling back.
- Wired in `AppEnvironment` from
  `FloePlatformServices.prepareLinuxEnvironment(cancellation:)`, which refuses
  to run without durable image storage.

## 2. Office

**CJK fonts (native host source + pin)**

- The engine caches font discovery inside its versioned profile. Stale
  discovery from a build that predates the staged CJK families renders every
  Chinese glyph as a box even though the files are present.
  `FloeOfficeNative.mm` now fingerprints the staged catalog (`<bundle>/Fonts`
  plus `share/fonts`, sorted, size-aware) and folds it into the profile
  identity (`27b21dc1-fonts-<fingerprint>`), so a font-set change re-runs
  discovery and previous profiles are retained for recovery. The engine still
  initializes against the final bundle resource path.
- `engine.lock.json` records the new `FloeOfficeNative.mm` SHA-256 and a
  `SOURCE AHEAD OF ARTIFACT` note: the pinned framework predates this source
  change, so `bootstrap_office_host.py` fails closed until CI rebuilds and
  re-qualifies the host. That rebuild is required before distribution.

**Pencil annotation**

- `FloeOfficeNative.mm` injects a pointer gate for editable documents: while
  annotation mode is on, only Apple Pencil (`pointerType == "pen"`) reaches the
  document's freehand tool; finger pointer events are stopped so a finger keeps
  navigating, and WKWebView's own gestures are untouched. `setDrawingMode:`
  arms the flag together with `.uno:Freeline_Unfilled`, so strokes remain the
  engine's editable vector shapes (undo, save and reopen follow the document).
- Reproducible source/pin checks live in
  `scripts/tests/test_office_fonts_and_pencil.py`, which executes the real
  extracted JavaScript under Node.

**Entrypoint routing**

- Workspace Office preview expand now opens the standalone
  `OfficeStandaloneEditorHost` → `OfficeDocumentEditorView`
  (`FilePreviewView.presentOfficeEditor`), labelled **Edit in Office**
  (`office.editor.open`), releasing the preview session first and releasing the
  editor session on dismiss so one document never has two live working copies.
  Save, ⌘S and the unsaved-exit confirmation come from the shared editor.
- The IDE file tree keeps Office documents as embedded IDE tabs
  (`IDEWorkspaceTabStore` → `.office`), unchanged.

## 3. IDE

**Integrated source-control sidebar**

- `FloeApp/Workspace/IDESidebar.swift` (new) + `WorkspaceIDEView`: the modal
  source-control sheet is replaced by an integrated left sidebar (inline on
  iPad, slide-over drawer on iPhone) that hosts the existing
  `SourceControlView`/`SourceControlCenter`, so staged/unstaged/untracked
  trees, diff, stage, unstage, commit and safe initialize are available beside
  the editor. Errors keep their existing alert surface; the sidebar is keyed to
  the pinned workspace and reports a global workspace/task switch instead of
  silently showing another repository.
- `SourceControlView.swift` strings are now bilingual (`IDELanguageRunText.t`)
  so English and Simplified Chinese stay aligned.

**Archive browsing**

- `Sources/FloeWorkspace/ArchiveBrowserService.swift` (new) reuses
  `WorkspaceArchiveTool`, keeping entry/size bounds, traversal and symlink
  rejection and no-overwrite. zip/tar/7z are native; compressed tar,
  gzip/bzip2/xz and RAR report the concrete reason instead of starting a Linux
  guest.
- `FloeApp/Workspace/ArchiveBrowserView.swift` (new): directory tree, lazy
  per-entry preview with a bounded one-off extraction into a hidden workspace
  directory that is removed on exit, and an explicit "Extract" action.
- `WorkspaceFileRouter`/`WorkspaceFileType` route archives to
  `.archiveBrowser`; the preview gains a Browse Archive entry and the IDE opens
  one document tab.

## 4. Local models (JSONL evidence)

Evidence: `4-floe-task-BA92B96D-…jsonl` — run 1 called `tools.list`; runs 2–3
made no tool call and still reported a file as created (no crash, empty
tool-call stream).

- `Sources/FloeProviders/LocalModelToolPolicy.swift` (new): the stable,
  budgeted base set (read/create/write/list/search/patch/inspect plus
  `environment.prepareLinux`) with a priority admission order.
- `LocalProviderAdapter.selectTools` admits that set first on every local run
  (no `tools.list` needed) and keeps it after tool results, so a create→read
  chain stays callable; cloud adapters keep their dynamic discovery untouched.
  `AgentRuntime` unions and pins the same names for local providers only.
- `Sources/FloeAgentRuntime/ActionClaimGate.swift` (new) + `finishOrSteer`:
  a file-creation/save claim with no successful tool receipt at all earns one
  bounded corrective turn; a repeated claim ends the run with an honest,
  recoverable failure. Any successful receipt disarms the gate, and only
  `.endTurn` prose is inspected, so real tool runs and ordinary chat are
  untouched. Context/compaction limits are unchanged.

## Validation actually run locally

| Command | Result |
| --- | --- |
| `swift build --target FloeAgentRuntime` / `FloeExecution` / `FloeWorkspace` / `FloeLocalModels` (Xcode-beta toolchain) | Build complete |
| `xcrun xctest …/FloeAgentRuntimeTests.xctest` | 321 tests, 13 issues — all 13 reproduced on the pristine runtime (see below); new `ActionClaimGate`/receipt/chain tests pass |
| `xcrun xctest …/FloeExecutionTests.xctest` | 71 tests, 14 issues; pristine baseline is the same 14 (5 unexpected) — new installer/preparation tests pass |
| `xcrun xctest …/FloeWorkspaceTests.xctest` | 77 tests passed, including 6 new archive-browser tests |
| `xcrun xctest …/FloeLocalModelsTests.xctest` | 70 tests, 3 issues; pristine baseline is the same 3 — 4 new base-schema tests pass |
| `python3 scripts/tests/test_office_fonts_and_pencil.py` | 7 passed (Node executes the Pencil gate) |
| `python3 scripts/tests/test_office_ink_bridge.py` | 4 passed (unchanged) |
| `python3 -c json.load(Localizable.xcstrings)` | 1,135 keys, valid JSON, en + zh-Hans |

Pre-existing failures were classified by re-running the same bundles with the
corresponding changes temporarily reverted: `FloeAgentRuntimeTests` 13/13,
`FloeExecutionTests` 14/14 and `FloeLocalModelsTests` 3/3 reproduce without
this patch and are unrelated (context-compaction helpers, conversation-tool
JSON fixtures, guest console scripts, background-job workspace preflight).

## Remaining checks (not claimed)

- **Cloud CI App build/archive**: the app target (FloeApp) was not compiled
  locally; heavy App compilation and packaging belong to CI. Swift 6
  concurrency diagnostics for the new app views need that build.
- **Native Office host rebuild**: `engine.lock.json` is intentionally
  source-ahead-of-artifact. CI must rebuild and re-qualify
  `FloeOfficeNative.framework` (font fingerprint profile identity + Pencil
  gating) and update the pin before any release.
- **Device-only**: CJK heading/body/table rendering through a real engine in
  workspace preview, standalone Office and IDE Office; physical Apple Pencil
  stroke feel, undo and save/reopen; finger navigation during annotation;
  Linux image download over the real network and terminal start; TestFlight
  availability.

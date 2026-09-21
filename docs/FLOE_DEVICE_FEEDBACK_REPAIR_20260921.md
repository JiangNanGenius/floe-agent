# Device feedback repair — Linux/TinyEMU, Office, IDE and local models (2026-09-21)

Base revision: `cbbadcb6` (build 216 delivery). Work branch:
`codex/device-feedback-repair-20260921`. This document records the implemented
repair, the focused validation that ran locally, the rebuilt and pinned native
Office host, and the checks that still require the cloud App build or a
physical device.

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
- `engine.lock.json` records the `FloeOfficeNative.mm` SHA-256, and the
  framework artifact was rebuilt from this revision and pinned (see the
  rebuild section below). The interim revision that only carried the source
  change deliberately kept `pendingHostRebuild: true` and a `SOURCE AHEAD OF
  ARTIFACT` note so `bootstrap_office_host.py` failed closed; that state is
  gone now. No claim is made for device CJK rendering or physical Pencil
  behaviour until the device checks at the end of this document run.

### Native host rebuild / re-pin (executed)

`FloeAgent/scripts/pin_office_host_artifact.py --check` now reports that the
recorded artifact matches the current host sources (exit 0).

1. The existing qualification workflow — `.github/workflows/office-native-host.yml`
   ("Qualify Floe Native Office Host", `workflow_dispatch`) — ran on the work
   branch. Run [`35601638396`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35601638396)
   succeeded on commit `d1e1d593` and uploaded `office-native-host-unsigned`
   (artifact id `10638824111`) plus `office-native-host-evidence`.
2. The artifact was downloaded and its `native-host.json` verified:
   `sourceCommit 27b21dc1…`, `overlaySHA256 4ac3cc3b…`, the four
   `hostSourceSHA256` values equal to the lock, `hostCompilePassed`,
   `hostLinkPassed` and `swiftModuleImportPassed` all true, `resourceFiles
   4780`, `resourceDirectories 174`.
3. The pin was recorded with
   `python3 FloeAgent/scripts/pin_office_host_artifact.py --artifact-zip … --artifact-id 10638824111 --apply`:
   archive `sha256:68489795bcafcb96aceeb147f55fff83d066c7aec84e0131b08b030611c0559a`,
   executable `sha256:a0f2a0de52ebb8e71af4d5d492e3e8ad2611cec24e8d43c104caf87bc41fdf44`
   (byte-identical to the previous host build), manifest
   `sha256:38ba599e61a64d9e4b9a727e5ba98700aa0ddd5cdcc7b54a92258b525039163f`,
   and `pendingHostRebuild` cleared.
4. `bootstrap_office_host.checked_lock()` and `verify_installed()` pass against
   the extracted artifact, so the App build's own bootstrap accepts the pin.
   The App build itself, TestFlight and the device checks below are separate.

CI found and this revision repaired three issues on the rebuild path:

- the first dispatch (`35599544070`) failed to compile: the font fingerprint
  sent `URLByAppendingPathComponent:isDirectory:` to the `NSString`
  `bundle.resourcePath`. The resource path is now wrapped in a file URL
  (`NSURL fileURLWithPath:isDirectory:`) before appending.
- `native-host.json` did not name the CI run that produced it, so `--apply`
  fell back to the previous pin's `runID` and `bootstrap_office_host.py` would
  have re-downloaded the stale artifact. The build now stamps `GITHUB_RUN_ID`
  and `GITHUB_SHA` (`build_office_native_host.run_identity`).
- the pin script compared runtime resources in a different key space
  (artifact-root-relative vs resource-root-relative) and kept the previous
  pin's filter-overlay values, although the overlay archive is reassembled on
  every build. Both made a real artifact unpinnable; the script now compares
  resources like the build records them and refreshes the overlay in the
  pinned key space, which `verify_installed()` exercises.

Check the current state at any time (read-only):
`python3 FloeAgent/scripts/pin_office_host_artifact.py --check` — it exits
non-zero while the source leads the pinned artifact and 0 once the rebuilt
artifact is recorded (the current state).

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
| `python3 scripts/tests/test_office_fonts_and_pencil.py` | 7 passed (Node executes the Pencil gate; the lock is asserted rebuilt-and-pinned) |
| `python3 scripts/tests/test_office_host_pin_path.py` | 5 passed before the rebuild; 9 passed after (pin check passes on the rebuilt pin; still fails closed on a lock owing a rebuild, a drifted source hash, other sources, tampered resources, an unqualified artifact, omitted overlay keys and traversal paths) |
| `python3 scripts/pin_office_host_artifact.py --check` | exits 1 with the rebuild path while a rebuild is owed; exits 0 against the rebuilt pin |
| `bootstrap_office_host.checked_lock()` + `verify_installed()` on the downloaded artifact | passed (manifest, executable, framework auxiliary and 4,780 resource hashes match the pin) |
| `python3 scripts/tests/test_office_ink_bridge.py` | 4 passed (unchanged) |
| `python3 -c json.load(Localizable.xcstrings)` | 1,135 keys, valid JSON, en + zh-Hans |

Local environment note: this Mac runs Python 3.9.6 while the Office CI
workflows pin Python 3.12. `scripts/test_office_engine_bundle.py` therefore
fails locally with `extractall() got an unexpected keyword argument 'filter'`
(14 errors) — an interpreter-version limitation, unrelated to this patch and
covered by CI. The other Office script suites (host bootstrap, mobile
qualification, native host, filter overlay, save receipts, readonly,
fullscreen edit, drain, editor language) all pass locally.

Pre-existing failures were classified by re-running the same bundles with the
corresponding changes temporarily reverted: `FloeAgentRuntimeTests` 13/13,
`FloeExecutionTests` 14/14 and `FloeLocalModelsTests` 3/3 reproduce without
this patch and are unrelated (context-compaction helpers, conversation-tool
JSON fixtures, guest console scripts, background-job workspace preflight).

## Remaining checks (not claimed)

- **Cloud CI App build/archive**: the app target (FloeApp) was not compiled
  locally; heavy App compilation and packaging belong to CI. Swift 6
  concurrency diagnostics for the new app views need that build.
- **Native Office host**: rebuilt and pinned — run
  [`35601638396`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35601638396)
  on `d1e1d593`, artifact `office-native-host-unsigned`
  (`10638824111`), archive `sha256:68489795…`, framework executable
  `sha256:a0f2a0de…`, `pendingHostRebuild` cleared. What remains is the App
  build that embeds it, TestFlight and the device checks below — **no claim is
  made yet that CJK rendering or Pencil input is fixed on a device.**
- **Device-only**: CJK heading/body/table rendering through a real engine in
  workspace preview, standalone Office and IDE Office; physical Apple Pencil
  stroke feel, undo and save/reopen; finger navigation during annotation;
  Linux image download over the real network and terminal start; TestFlight
  availability.

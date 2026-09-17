# Build 178 feedback repair — local model, Office and Notes

Working record for branch `codex/build178-feedback` (base `4bd5d16f`, build 178 /
1.7.0). It tracks the user feedback received for build 178 and the repairs that
are implemented in this branch. It is **not** a release record: nothing here has
been pushed, run through CI or uploaded to TestFlight. The branch retains a
local code checkpoint with the open acceptance items below. Earlier
release records in `docs/` are unchanged.

Last updated: 2026-09-17.

## What the user reported

- **Local model**: the built-in speed benchmark completes and returns text, but
  ordinary chat inference aborts on the iPad shortly after it starts. A crash
  report for build 178 was submitted from the app on 2026-09-17 (Sydney).
- **Office**: embedded-control behavior and explicit-save behavior were
  reported as unreliable inside the Office editor.
- **Notes library**: the document grid only previewed PDF; Word/Excel/PPT
  covers and CAD documents were missing, and CAD files could not be imported.
- **Notes assistant**: large-document reads were inefficient, page-note text
  could not be edited with explicit placement, Word annotation was incomplete,
  and long mind-map text did not paginate.

## Implemented in this branch

### Notes library preview and CAD import

- `NoteDocument.Kind` gains an `engineering` case with bounded
  `engineeringResourceID` / `engineeringFileName`; the archive and store carry
  it, and legacy documents still decode (`FloeAgent/Sources/FloeNotes/NoteModels.swift`,
  `NotesArchive.swift`, `NotesStore.swift`).
- `NotesRootView` import allow-list adds the supported CAD extensions, the card
  meta line shows the CAD file name, and `NoteFileImporter` validates the
  basename/format before storing an immutable resource.
- New `NotesEngineeringView` renders a read-only CAD preview via the existing
  `EngineeringPreviewPackage.single` + `EngineeringFilePreview` path. The read
  is bounded to 20 MB + 1 byte through a cancellable detached worker, and a
  cancelled predecessor never publishes a stale package or error.
- New `NotesDocumentThumbnail` replaces the old PDF-only cover: office covers
  use `QLThumbnailGenerator` against a uniquely scoped temp copy with the
  validated extension, generation is bounded to two concurrent requests, and a
  single-resume request state handles timeout/cancel. Limits stay 128 MiB
  source, 48 MiB cache, 15 s.

### Notes assistant tools

- `notes.read` returns bounded, paginated summaries (document, page, office
  text and map sections) with explicit `returned/total/next*` continuation
  fields; `notes.search` gains `documentID` scoped to existing grants plus
  offset/limit paging.
- `notes.edit addText`/`layoutText` accept an optional validated page-coordinate
  frame, and `moveText` moves/resizes existing text through the existing
  `NoteEdit.upsertElement` case. `NoteDocument.Kind` switches default unknown
  kinds to a metadata-only read-only summary so a preview-only document never
  crashes a tool.

### Office

- `OfficeExplicitSaveBridge.swift` holds the `OfficeLnBridge` message handlers;
  `OfficeDocumentEditorView` installs the embedded controls and owns the bridge
  lifetime. This is an iOS-app adapter change only; the native engine is
  unchanged.

### Local model — diagnosis only

- Matched-binary symbolication of the build-178 crash report places the four
  SIGABRT frames in the Qwen GatedDeltaNet prefill path (`getItemND` /
  `gatedDeltaUpdate`) called from `ModelContainer.generate`, not in container
  load or tokenization. The successful benchmark and the failing chat have
  different request context. Final prepared-token counts were not logged, so
  prompt length and chunking remain hypotheses. Some crashes followed a cancel
  request, while others did not; cancellation alone does not explain them.
- **No root-cause fix has been written.** Candidate fault sites were narrowed
  but not confirmed; this area remains unresolved and must not be described as fixed.

## Verification status

Observed on this checkout unless a line says otherwise:

- **Notes module suite — passed, zero failures.** `swift test --package-path
  FloeAgent/Qualification/Notes`; the final directed run records 42 tests in 4 suites
  (`NoteWorkspaceTabsTests`, `AssistantFocusTests`, `Notes engineering
  documents`, `NotesStoreTests`). This includes the engineering archive
  round-trip regression and legacy archive compatibility checks.
- **NativeNotes SDK 27 arm64 build-for-testing — passed.** `xcodebuild -project
  FloeAgent/Qualification/NativeNotes/FloeNotesNativeQualification.xcodeproj
  -scheme FloeNotesNativeQualification -destination "generic/platform=iOS
  Simulator" -derivedDataPath FloeAgent/.build/native-notes
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
  -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
  build-for-testing` → `TEST BUILD SUCCEEDED`. The newest `FloeAgentRuntime`
  target added to `Qualification/NativeNotes/project.yml` has not been rebuilt
  since that run.
- **Office adapter Python tests — passed.** `python3
  FloeAgent/scripts/test_office_embedded_controls.py` → `Ran 1 test ... OK`;
  `python3 FloeAgent/scripts/test_office_explicit_save.py` → `Ran 1 test ...
  OK`. These exercise the JavaScript adapter and save bridge; they do not
  qualify the native Office UI.
- **iPad simulator execution — not passed.** The simulator run was interrupted
  by host load before any test case executed (`TEST EXECUTE INTERRUPTED`). An
  interrupted run is not a pass and is not counted as one.
- **Localization (this task).** New `notes.engineering.*`, `notes.import.all`
  and `notes.kind.engineering` entries were added to
  `FloeAgent/FloeApp/Resources/Localizable.xcstrings` with `en` and `zh-Hans`
  values, and the three Notes views now use those keys. The catalog parses and
  the diff is additive only (no whole-file reformat); `swiftc -parse` over the
  three iOS-sdk files exits 0. No App/runtime rendering check was performed.

## Not verified / open

- Local-model crash root cause and fix are open; the branch only localizes it.
  The initial tiny probe used a batched rank-2 input although the library expects
  rank 1. Its crash is invalid as product reproduction evidence. A separate
  source review confirms both App chat and benchmark construct rank-1 tokens;
  the corrected rank-1 probe passed 48/96/512 chunk boundaries, a 1,537-token
  equivalence check and 20 repeated prefills. It used tiny random weights on
  macOS and does not reproduce or clear the real iPad crash. Its cancellation
  check was between complete prefills, not mid-prefill cancellation.
- Office native UI (font dropdown, host-owned close, explicit save) is not
  qualified by the adapter tests.
- The Notes simulator/device acceptance run has not completed.
- Mind-map long-text pagination and the runtime response-limit repair are
  implemented. Their latest regression tests compiled in the NativeNotes host
  (`native-notes-final-build2.log`, `TEST BUILD SUCCEEDED`); simulator execution
  has not passed. The third integration review found no new blocking issue in
  resource remapping, server extraction, response limits or target membership.
- Notes Office content editing is implemented; its new tests passed a directed
  NativeNotes build (`native-notes-office-tools-build.log`). The refresh/conflict
  UI and real pinned native API branch passed a separate Swift 6 typecheck using
  existing compiled modules plus small peripheral UI stubs. These checks do not
  establish native engine behavior. The primary additionally fixed pending-copy
  persistence, autosave dirty-state tracking, self-commit suppression and refresh
  task cancellation. A subsequent independent review caught the case where
  Office explicit save only updates the draft, not the Notes resource. External
  refresh now streams hashes of that draft and the immutable base resource even
  in preview mode; mismatches or read failures keep the conflict decision visible.
  Refresh disables its actions and shows progress. The final three-file Swift 6
  semantic check passed again; its script now propagates any compiler failure
  (verified with a deliberate failed-step control). Native behavior remains open.
- The pinned embedded Writer toolbar already exposes Insert Comment in Insert
  and Review; the earlier read-only claim that comments were entirely absent was
  too broad. Comment input/save/reopen still requires operational acceptance.
  The assistant does not yet extract Word comments.
- Operational and visual acceptance belongs to the primary agent. OpenCode
  supplies code, fixtures and automated checks, not UI acceptance. After repeated
  installation/stream stalls, the primary stopped the task-owned iPad simulator
  and mirror. Host evidence indicates memory/IO contention on this 8 GB Mac;
  no device reset or data deletion was performed. Xcode 27 Device Hub then
  opened its first-launch system-component installer. After more than 10 minutes
  it still displayed “Installing system components”; `xcodebuild
  -checkFirstLaunchStatus` returned 69. Logs identify `CoreTypes.pkg` /
  `MobileDevices-0002.bundle` as a pending component. This is an additional
  host setup blocker, not an App UI result; the active installer was preserved.
  Opening Xcode itself and choosing its required component installation showed
  “Waiting for other install tasks on the system”. No installer service was reset.
- CI, `git push`, merge and any TestFlight upload have **not** started.
- Localization rendering in a running App, and English-locale copy review, is
  unverified.
- `notes.kind.engineering` localizes the new CAD fallback only; the sibling
  Notes kind labels (`Office 文件`, `思维导图`, page counts) remain literal
  Chinese and are out of scope for this round.

## References

- Localization: `FloeAgent/FloeApp/Resources/Localizable.xcstrings`;
  `FloeAgent/FloeApp/Notes/NotesEngineeringView.swift`,
  `NotesKnowledgePicker.swift`, `NotesRootView.swift`.
- Notes preview/tools: `NotesDocumentThumbnail.swift`, `NotesEngineeringView.swift`,
  `NotesAgentTools.swift`, `Sources/FloeNotes/NoteModels.swift`,
  `Sources/FloeNotes/NotesStore.swift`.
- Office: `FloeAgent/FloeApp/Workspace/OfficeExplicitSaveBridge.swift`,
  `OfficeDocumentEditorView.swift`,
  `FloeAgent/scripts/test_office_embedded_controls.py`,
  `FloeAgent/scripts/test_office_explicit_save.py`.
- Tests: `FloeAgent/Qualification/Notes/Tests/`,
  `FloeAgent/Qualification/NativeNotes/Tests/`.

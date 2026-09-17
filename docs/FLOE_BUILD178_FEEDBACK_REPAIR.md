# Build 178 feedback repair — local model, Office and Notes

Working record for branch `codex/build178-feedback` (base `4bd5d16f`, build 178 /
1.7.0). It tracks the user feedback received for build 178 and the repairs that
are implemented in this branch. It is **not** a release record: these repairs
have not been uploaded to TestFlight. The branch retains a
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
  source and 48 MiB cache. Transient failure recovery now uses the same product
  and test generator: up to three attempts, 15 s per attempt and 45 s total with
  bounded backoff. The two-request gate also bounds staging copies. Cancellation
  stops retries and suppresses publication, while failed results are not cached.
  Logs identify format, attempt and sanitized error category without document
  names or paths. Cold-start extension failure is a hypothesis, not a proven
  explanation for the first Word sample. Six required fixture tests and two
  cancellation tests passed Swift 6 semantic checks; execution is pending.

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
  target added to `Qualification/NativeNotes/project.yml` was included in the
  later successful `native-notes-office-tools-build.log` build-for-testing run.
  This is compilation evidence; test execution remains separate.
- **Office adapter Python tests — passed.** `python3
  FloeAgent/scripts/test_office_embedded_controls.py` → `Ran 1 test ... OK`;
  `python3 FloeAgent/scripts/test_office_explicit_save.py` → `Ran 1 test ...
  OK`. These exercise the JavaScript adapter and save bridge; they do not
  qualify the native Office UI.
- **Earlier local iPad simulator execution — not passed.** The simulator run was interrupted
  by host load before any test case executed (`TEST EXECUTE INTERRUPTED`). An
  interrupted run is not a pass and is not counted as one.
- **Localization (this task).** New `notes.engineering.*`, `notes.import.all`
  and `notes.kind.engineering` entries were added to
  `FloeAgent/FloeApp/Resources/Localizable.xcstrings` with `en` and `zh-Hans`
  values, and the three Notes views now use those keys. The catalog parses and
  the diff is additive only (no whole-file reformat); `swiftc -parse` over the
  three iOS-sdk files exits 0. No App/runtime rendering check was performed.

- **CAD browser component — primary-operated checks passed.** The bundled DXF
  and DWG fixtures rendered through the real parser/decoder. Layer toggling,
  zoom/Fit and compact-width Fit were exercised. Screenshots and precise limits
  are retained in [the component evidence](qualification/build178-feedback/README.md).
  This does not qualify native Notes import or iPad/iPhone App behavior.

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
- The Notes cloud component suite ran and failed as detailed below; full-App
  simulator/device acceptance remains incomplete.
- Mind-map long-text pagination and the runtime response-limit repair are
  implemented. Their latest regression tests compiled in the NativeNotes host
  (`native-notes-final-build2.log`, `TEST BUILD SUCCEEDED`). The subsequent cloud
  run found one incorrect terminal-page test expectation: offset 1 plus two
  returned attachments reaches a total of 3, so `nextAttachmentOffset` is nil,
  not 3. The correction preserves the nil-at-end contract and adds a real
  nonterminal continuation and an exact once-only attachment walk. The third
  integration review found no new blocking issue in
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
  “Waiting for other install tasks on the system”. No installer service was reset. A subsequent read-only authorization-log
  investigation identified outstanding administrator authentication requests.
  The protected system authorization window cannot be operated by the computer
  tool; the user was asked to complete it locally. Waiting is not being counted
  as installation progress.
- Full-App/release CI, merge and TestFlight upload have **not**
  started. The separate existing macOS local-model diagnostic was dispatched
  on immutable source `4bd5d16f2b3e8ecbb223ebb3f572c5d571622b8e` in
  [run 35179224276](https://github.com/JiangNanGenius/floe-agent/actions/runs/35179224276).
  This uses the unchanged production model engine and exact catalog weights;
  its actual log was retrieved and checked: 31/31/5,773 input tokens produced
  nonempty responses, including `blue` for the long prompt; peak MLX allocation
  was 2,780,685,808 bytes and shutdown left 4,000 active MLX bytes. This passed
  on Xcode 27 (27A5252f), macOS, batch 32 only. It does not represent iPad or
  distribution acceptance. The diagnostic host now additionally covers the
  observed batch 48/96 resource profiles, a synthetic SYSTEM-context turn and
  teardown/reload, with one build and one download per run. The subsequent
  [run 35180378429](https://github.com/JiangNanGenius/floe-agent/actions/runs/35180378429)
  passed on immutable source `6c2bc8ee2171564109ac0f913621470ac8d2ca6b` and
  Xcode 27 (27A5252f). Both profiles processed the same 12,156-character synthetic
  system prompt (3,147 input tokens), answered `Blue.`, shut down, reloaded and
  answered the arithmetic follow-up. Batch 48 took 30.08 seconds for the long
  turn; batch 96 took 23.43 seconds. Overall MLX process peak allocation was
  2,804,000,582 bytes; final shutdown left 15,976 active MLX bytes. These macOS
  results do not establish that the iPad crash is fixed. The original crash
  context and synthetic diagnostic input are different despite similar lengths.
- A separate directed native Notes run was dispatched at
  `84d6500e013c6f0b44b30972c6a6ce19a8b272c1`:
  [run 35180990348](https://github.com/JiangNanGenius/floe-agent/actions/runs/35180990348).
  It selects the development SDK and executes iPad before iPhone. Real Quick Look
  thumbnail images are retained as XCTest attachments when a system generator
  returns them. On Xcode 27 (27A5252f), the build succeeded, but 36 XCTest tests
  reported three assertion failures across two cases: the terminal attachment
  expectation above, and the six-Office-fixture thumbnail case (first Word
  fixture missing; five of six generated). The other 20 Agent tool cases passed,
  including actual Office text read/edit/CAS round-trip and stale revision/hash
  rejection. The original 11-case native suite and the two thumbnail-gate cases
  passed. The separate reader/linked-map UI test passed, but primary inspection
  found its landscape capture still used a portrait system canvas; it is not
  accepted as landscape screenshot evidence. The test now captures the app and
  checks image dimensions. iPhone execution did not start after the iPad failure.
  Primary inspection confirmed real text in the returned Word, Excel and PPT
  thumbnails; these generator images are not full-App library-card acceptance.
  Xcode then spent 600 seconds on optional simulator diagnostics and timed out.
  The workflow now disables only that verbose diagnostic collection, retaining
  assertions, timeouts, console logs, xcresult and explicit image attachments.
- GPU-fix candidate dependencies remain isolated to the diagnostic workflow;
  production pins are unchanged. Run 35181975790 resolved the intended two
  revisions but its guard rejected SwiftPM's equivalent `.git` source URL.
  The corrected guard accepts this alias only for the exact target repositories
  and still rejects unrelated dependency drift. Run 35182411389 then passed real
  resolution but failed Swift compilation on `prepared` sendability in the new
  numeric inference diagnostics. It never ran generation. Commit `e48d771a`
  fixes the diagnostic autoclosure capturing the non-Sendable prepared input:
  the original error was reproduced locally using real production-pin modules,
  while the patch passed typecheck and emit-SIL region-isolation checks.
  [Run 35183627027](https://github.com/JiangNanGenius/floe-agent/actions/runs/35183627027)
  then compiled and generated real answers on both candidate profiles. Both
  3,147-token long turns returned `Blue.` (25.26 s at batch 48, 18.43 s at batch
  96), and reload follow-ups returned the correct arithmetic answer. **The
  candidate is not accepted for adoption:** final shutdown reported
  3,111,710,152 active MLX bytes and 3,419,956,672 process-footprint bytes;
  process peak footprint was 4,937,360,064 bytes. This differs materially from
  the old-pin diagnostic's 15,976 final active bytes. Delayed GPU release versus
  retained resources remains under investigation. A successful generation/CI
  exit is insufficient lifecycle evidence and does not establish an iPad fix.
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

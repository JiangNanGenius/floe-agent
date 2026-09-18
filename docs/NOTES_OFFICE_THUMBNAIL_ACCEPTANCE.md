# Notes Office / CAD cover acceptance

Status: **acceptance record. Section 0 records the build 187 two-tier policy and
the current source status. Sections 1–7 are retained history from the build
183–186 passes; they are evidence records, not current policy where they
conflict.** The build 187 preparation source has local type checks and Python
fixture results only: no 187 build, simulator run, CI run or device run exists,
and nothing below may be read as 187 acceptance. Build 186's final failed result
is recorded in [the beta.43 record](RELEASE_1.7.0_BETA_43.md) and its retained
qualification JSON is [here](qualification/build186-release/result.json).

## 0. Build 187 acceptance policy (current)

The changes in this section are deliberate policy decisions for build 187. They
are not a claim that the earlier tests always behaved this way; historical
results below remain unchanged and are never relabelled.

### Office functional acceptance: real content, not source-only strictness

- A Notes card is accepted only for real content: a system Quick Look content
  representation (`.quickLookThumbnail`) **or** a native content summary
  (`.officeContentSummary`) that is visibly labelled
  (`notes.cover.badge.summary`) and verified by independent fixture-content
  assertions (known text/cells, 320 × 420 geometry, wrong-document rejection).
- Neither path accepts a displayed generic icon, missing image, `.unsupported`
  or `.none`. Summary text, geometry and wrong-document checks are independent
  fixture checks; they do not establish Quick Look layout or semantic fidelity.
  For the known nonblank Quick Look fixtures, a bounded pixel-contrast check also
  rejects uniform/transparent output; it does not recognize words or verify layout.
  `icon=true` describes the failed Quick Look attempt, not the displayed summary: it
  is rejected for a `quickLook` result, but preserved as diagnostic evidence when
  a verified `officeContentSummary` is displayed.
- The summary remains explicitly **not** an original-layout render. Accepting it
  as functional content does not assert Office layout fidelity, and a card that
  only ever shows a summary has not produced a system thumbnail.
- The six component sample tests and the full-App UI test use this allowed set.
  The full-App test additionally requires the summary badge and rejects
  `icon=true` only for a `quickLook` result; it also still requires a strictly newer revision after rename and
  the opener/relaunch path when those stages are reached.

### Strict Quick Look-only diagnostics: separate and fail closed

- The original strict content assertions (six per-sample plus one per-type) moved
  into
  `FloeAgent/Qualification/NativeNotes/Tests/NotesOfficeThumbnailDiagnosticsTests.swift`
  (7 cases). The functional component step excludes that class with
  `-skip-testing`; the workflow runs it in a separate `if: always()` diagnostic
  step with its own `notes-diagnostic-<family>.xcresult`, log, status file and
  original exit code. The three-format diagnostic alone has a 180-second
  XCTest allowance to cover three sequential 45-second resource budgets; the
  per-resource timeout and content assertions are unchanged.
- Classification reads the real `xcresulttool` test-results structure through
  `FloeAgent/scripts/verify_quicklook_diagnostics.py`; stdout/log text is never
  the classifier.
- Non-gating is allowed **only** for a complete 7/7 run with no skips, no runtime
  warnings, no crash, and every failure carrying exactly one fixed marker on the
  matching assertion shape: content source (`:content`), request deadline
  (`:timeout`) or generic icon (`:icon`).
- A missing bundle, zero/partial/extra cases, a skip, a throw/crash, a
  summary/tree count mismatch, or any unmarked assertion failure classifies
  `NOT_EXECUTED` and fails the diagnostic step. Functional failures always keep
  the component job failed; no `continue-on-error` is used anywhere.

### 187 status

The progressive cover source and diagnostics separation are committed as
`1a52dd31cbb5a1b293b525b25124cb12519bb623`. The Office header identifier fix was
committed as `3dc4a2f81ac4b67800b70fd57f8f350debea66c9` after build 186 but has
not been built or run. Local `swiftc` typecheck/object checks and Python fixture
tests are recorded in the internal `Local/Private/build187-*` reports; **no 187
build, component run, full-App run, CI run, tag, upload or physical-device run
has executed**.

## 1. What a "real cover" means

`NotesDocumentCoverSource` (`FloeAgent/FloeApp/Notes/NotesDocumentThumbnail.swift`)
records the exact provenance of every card image, and the card exposes
`<source>#<revision>` through its accessibility identifier/value
(`FloeAgent/FloeApp/Notes/NotesRootView.swift`). A card is only accepted when its
source is a real render of the document's own bytes.

| Document kind | Accepted real source | Explicitly **not** accepted |
| --- | --- | --- |
| Office (docx/xlsx/pptx) | `quickLook` — a system Quick Look content representation; build 187 policy also accepts a labelled `officeContentSummary` proven by independent content assertions (section 0) | generic file icon; unlabelled or unproven summary; absent image; `unsupported` |
| Notebook | `notePage` | `unsupported`, icon |
| Mind map | `mindMap` | `unsupported`, icon |
| Engineering (DXF/DWG/STL/…) | `engineeringPreview` — bundled viewer pixels | `unsupported`, `quickLook`, icon |

### Office: the summary is not an original-layout thumbnail

`officeContentSummary` is a real, bounded native OOXML render that is labelled
**Summary** on the card (`notes.cover.badge.summary`). It is a product fallback
for environments where the system generator cannot render a format offline.
It is explicitly **not** evidence of the original Office layout. Under the build
187 policy (section 0) it can pass *functional* library acceptance when the label
and independent content assertions hold; a card that only ever shows a summary has
still not produced a system thumbnail, and no original-layout claim is made. The
build 185/186 full-App test required `.quickLookThumbnail` only; that stricter
behavior is preserved as the separate diagnostic in section 0 instead of being
silently deleted or converted into a pass.

### CAD: `unsupported` is not acceptance

The bundled `EngineeringViewers` distribution (DXF via `dxf.js`, DWG via
`cad-editor.js`/`floe_cad_engine_bg.wasm`) must render the drawing's own
geometry. A card that reports `unsupported`, or that is satisfied by Quick Look
or a generic icon, is a failure for CAD.

## 2. Mechanism and the races fixed

`NotesEngineeringCoverRenderer` (`FloeAgent/FloeApp/Notes/NotesEngineeringCoverRenderer.swift`)
is one `@MainActor` app-wide renderer: one offscreen `WKWebView` and one
`LocalPreviewServer` rooted at the bundled `EngineeringViewers`, serialized by a
bounded queue (`maximumQueuedRequests = 16`), with 8 MB source cap, 25 s bridge
timeout, and idle teardown. `viewer.js` exposes
`window.floeEngineeringThumbnail(pkgJson, width, height)`, which resets the
previous render, loads the package, waits for the viewer's own `finished`/
`floeEngineeringResult` flag, calls `fit()`, and returns the canvas PNG.

Fixed in this pass (source-level; Swift type-checked, runtime evidence pending):

1. **Hung navigation was unbounded.** `perRequestTimeout` only wrapped the JS
   bridge, so a stuck `WKWebView.load` could suspend the render queue forever.
   `loadPage` now races a `navigationTimeout` (15 s) task and the teardown path
   always reclaims the host.
2. **Cancellation-before-enqueue race.** An already-cancelled `thumbnail` call
   could be enqueued and rendered for nobody. The continuation body now checks
   `Task.isCancelled` before taking a queue slot.
3. **BridgeState finish-before-attach could hang.** The continuation is now
   attached before the JS call starts; a result that arrives first is retained
   and delivered on `attach`, and the timeout task is always cancelled on settle.
4. **Stale WK delegate callbacks.** `didFinish`/`didFail`/`didFailProvisional`/
   `decidePolicyFor`/process-terminate now guard `webView === web`, so a callback
   from a torn-down or replaced host cannot finish a newer navigation or steer
   navigation to an old origin.
5. **Swift 6 concurrency.** `callAsyncJavaScript`'s completion is already
   `@MainActor`; the bridge no longer forwards its non-`Sendable` result through
   a `Task` capture. Page-load and bridge continuations use main-actor
   single-resume state objects. `contentSummary`/`drawParagraphs`/`drawGrid` are
   `nonisolated` and called from `Task.detached`.

## 3. Offscreen WebKit painting boundary

`toDataURL` returning a non-empty PNG only proves the canvas object exists; an
offscreen `WKWebView` whose GPU/compositor never painted can return a uniform
buffer. The renderer therefore rejects a decoded image with no visible geometry
(`hasVisibleGeometry`: transparent-foreground coverage, or ≥ 0.12 luminance
contrast on an opaque canvas) and falls back instead of publishing a blank
`engineeringPreview`.

**This is detection, not a proof that offscreen painting works on every OS.** If
CI reports `viewer painted no geometry` for a valid DXF/DWG, the known hardening
option is to host the offscreen web view in a hidden window (or snapshot a
temporary visible host) — that is an architecture decision for Astra, not
implemented here.

DxfViewer's `preserveDrawingBuffer` option is real upstream: `dxf.js` accepts
`preserveDrawingBuffer` and forwards it to the three.js renderer
(`three.js r161`, default `false`). `viewer.js` passes
`preserveDrawingBuffer: config.thumbnail === true`, so only the offscreen
thumbnail host pays for the readback.

## 4. Tests added / updated (historical: build 183–185; build 187 layout is in section 0)

### Component qualification (`FloeAgent/Qualification/NativeNotes/Tests/NotesOfficeThumbnailTests.swift`)

- `testMindMapCoverIsAStructuredBoundedNodeTree` — updated from the removed
  `mindMapRows` API to `mindMapLayout(nodes:connections:maximumRows:)`, and now
  asserts a real cross-link survives as an edge.
- `testOffscreenRendererPaintsRealDxfGeometry` — renders the bundled
  `sample-plate.dxf` through `NotesEngineeringCoverRenderer` and asserts
  `diagnosis == "bundled viewer"` plus **non-background geometry pixels**
  (blank canvas rejected), with the image attached via `XCTAttachment`.
- `testOffscreenRendererPaintsRealDwgGeometry` — same for
  `sample-editable.dwg`, exercising the CAD-engine conversion path.
- `testCoverServiceRendersDxfAndDwgThroughBundledViewer` — imports both samples
  through `NoteFileImporter` and asserts `NotesDocumentCoverService` returns
  `.engineeringPreview` with non-background geometry.
- `testEngineeringCoverRerendersAfterRenameRevision` — performs a real store
  `apply(.rename)` save, asserts the revision advanced and the immutable
  engineering resource was not replaced, then re-renders the renamed revision.

These run in the `FloeNotesNativeQualification` host, which bundles
`EngineeringViewers`, so `Bundle.main` resolves the real samples.

### Full-App UI (`FloeAgent/Tests/FloeAgentUITests/NotesWorkspaceImportUITests.swift`)

- `testNotesLibraryCardsShowRealContentCovers` now accepts Office **only** with
  `quickLook`; notebook `notePage`; mind map `mindMap`; DXF `engineeringPreview`;
  and a new DWG case `封面验收-图纸-DWG` (`engineeringPreview`). `unsupported`
  and `quickLook` are no longer accepted for CAD.
- The card identifier `<source>#<revision>` is parsed explicitly
  (`parseCover`), and every accepted card must report a revision > 0.
- A real revision cycle: rename the Word card through the context menu (a real
  store save), assert the cover reloads with a strictly newer revision and is
  still `quickLook`, reopen the renamed document, then cold-relaunch and require
  all covers to regenerate from persisted documents. Screenshots are attached
  (`notes-content-covers`, `notes-content-cover-renamed`,
  `notes-content-cover-opened`, `notes-content-covers-relaunch`).
- The context-menu rename action is matched by its real label `重命名` and the
  sheet by the stable identifiers `notes.rename.title` / `notes.rename.save`
  (added in `NotesRootView`), so the test does not depend on SwiftUI menu button
  identifiers that UIKit drops.
- The library is a `LazyVGrid` inside a `ScrollView`, so offscreen rows are not
  in the accessibility tree. `revealCard` now scrolls the grid until the card is
  realized (starting from the top) instead of assuming every row exists on first
  query; `assertContentCover` and the rename path both go through it.

## 5. Observed evidence (historical: build 183–185 type-check pass)

| Check | Command | Result |
| --- | --- | --- |
| Viewer JS syntax | `node --check FloeAgent/FloeApp/Resources/EngineeringViewers/viewer.js` | `viewer.js syntax OK` |
| Pinned asset manifest/network/notices | `python3 FloeAgent/scripts/check_engineering_viewer_assets.py` | `Engineering viewer: 29 hashes, closed network policy and notices verified` |
| Renderer + thumbnail app-local closure | `swiftc -typecheck -swift-version 6 -target arm64-apple-ios27.0-simulator`, iPhoneSimulator27.0 SDK, against the existing `FloeNotes`/`FloeWorkspace`/`FloeCore`/`FloeDocuments` simulator products, over `NotesDocumentThumbnail.swift`, `NotesEngineeringCoverRenderer.swift`, `NoteFileImporter.swift`, `NotePageRenderer.swift`, `NotesTextLayout.swift`, `PDFKitAccess.swift`, `LocalStaticFileServer.swift`, `BrowserURLPolicy.swift` | **exit 0, no warnings** (real Swift 6 semantic check) |
| NativeNotes test file | same `swiftc -typecheck` over `Tests/NotesOfficeThumbnailTests.swift` compiled with that app-local closure (the prebuilt qualification module predates the new APIs, so its one `@testable import` line was substituted by the current sources in a scratch copy) | **exit 0**; this caught a real `fileName:` argument-label mismatch in the renderer test helper, now fixed |
| Full-App UI test file | `swiftc -typecheck -swift-version 6 -target arm64-apple-ios26.0-simulator`, iPhoneSimulator SDK + XCTest, over `Tests/FloeAgentUITests/NotesWorkspaceImportUITests.swift` | **exit 0, no warnings** |
| App-module warning cleanup | The renderer's read-only abort call now uses the async `WKWebView.evaluateJavaScript(_:)`; `isContentRepresentation` is `nonisolated` | Both former Swift 6 warnings are gone from the type-check output |

These are **type-check** results: they prove the Swift 6 source is semantically
valid against the current module APIs. They are **not** a build or a run, so the
offscreen DXF/DWG painting, Quick Look content on the runner, and all unit/UI
test assertions remain unobserved until the CI/device jobs above execute.

### Build 184 correction (added after the type-check above)

The renderer was changed after this type-check: the read-only JS bridge now
normalizes the viewer reply into a `Sendable` `BridgePayload` before the checked
continuation. `swiftc -typecheck` did **not** catch the build-183 non-`Sendable`
continuation transfer, so the type-check rows above are retained as historical
evidence, not as current compiler acceptance for the fixed renderer. The current
renderer's evidence is the mandatory SIL and object emission check in
`qualification/build184-release/focused-compiler-checks.json`; that check compiles
source, it does not execute the offscreen DXF/DWG or Office tests.

### Build 185 component follow-up — development SDK 27

The build 184 component run
[`35287879287`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35287879287)
failed the cold CAD cover-service and bundled mind-map text cases, so source
`f4435d22` bounded the cold path: the renderer now waits for the real
`window.floeEngineeringThumbnail` predicate under a 6 s deadline with
cancellation and single-resume semantics, and the preview server reads complete,
bounded request headers. The subsequent development-only NativeNotes run
[`35290599088`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35290599088)
on that exact source (`f4435d2271d3036d263bea49e7d032688af2bc53`) passed the
`development` job on Xcode 27.0 (27A266a): **72/72 tests on iPad Air 13-inch (M4)
and 72/72 on iPhone 18 Pro**, zero failures and zero skips. The `compatibility`
job was skipped because the dispatch selected the development SDK only.

Ten actual cover-service outputs (Word, Excel, PowerPoint, DXF, DWG per device)
are retained under
[`docs/qualification/build185-release/native-covers/`](qualification/build185-release/native-covers/README.md);
machine-readable results are in
[`native-notes-followup.json`](qualification/build185-release/native-notes-followup.json).
The primary inspected all 21 exported images per device. Office/CAD content and
map/PDF captures are present, but the **iPhone early literal-text map snapshot is
a fully black frame** (1206×2334, every pixel 0) even though its DOM assertions
passed; it is excluded from accepted visual proof. The later linked-map image has
visible rendered content.

These remain component-host results: the pass confirms the cold-path symptom is
repaired, it does **not** prove the original cold-bridge failure cause, and it is
not full-App library-grid, physical-device or release-SDK acceptance.

## 6. Evidence status (build 186 final; build 187 pending)

1. **Build 186 development component (run 35306551280):** iPad 83/84 — one
   strict Excel Quick Look case failed at its 45.679 s request deadline while a
   real labelled summary was returned; iPhone 84/84. The compatibility component
   leg was not selected. Raw xcresults and logs are retained internally.
2. **Build 186 Full-App UI (same run):** both device legs executed 5 tests —
   3 passed, 1 failed, 1 skipped. The failure was the back-control identifier at
   `NotesWorkspaceImportUITests.swift:294`; the real button existed but its
   identifier was overwritten by the parent `notes.office.header`. Real Word,
   Excel and PowerPoint card covers were captured and visually verified; the
   cover cold-relaunch phase was **not reached**, so it remains unobserved.
   See [app UI evidence](qualification/build186-release/app-ui/README.md).
3. **Physical-device acceptance:** Quick Look content availability and DWG
   conversion performance are device claims; a simulator pass is not a device
   pass. This remains unobserved.
4. **Build 187:** all new source and test changes are unexecuted. The project
   must still be regenerated, built, run and qualified under a frozen source
   before any acceptance result exists.

## 7. Limitations

- The 21 new cover strings have been merged into the shared English/Simplified
  Chinese catalog. Rendering and truncation remain part of UI acceptance.
- No performance claim is made for the shared renderer beyond its finite bounds
  (queue depth, byte caps, timeouts).
- The `hasVisibleGeometry` threshold is deliberately conservative; a valid but
  extremely low-contrast drawing could be rejected into the Quick Look /
  unsupported path rather than shown. This is preferred to a blank cover being
  claimed as content.
- Build 187 summary bounds (verified from source, not runtime): modern OOXML up
  to 48 MiB, at most 240 fields, Excel reads the first sheet only (grid drawing
  uses at most the first 60 cells and a 5 × 10 cell area), and paragraph/grid
  drawing truncates to the 320 × 420 card. These are product limits, not
  provisional measurements; see [Office previews](NOTES_OFFICE_PREVIEWS.md).

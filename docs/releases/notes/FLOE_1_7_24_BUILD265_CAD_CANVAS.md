# Floe 1.7.24 (build 265) — CAD / Drawing Assistant / Canvas / image+video refinements candidate note

Status: source validated locally on branch `codex/build265-creative-cad`.
No tag, TestFlight or public release. Version fields now read 1.7.24(265) in
`FloeAgent/project.yml` and the regenerated project; the primary performs
external acceptance/release after UI review.

## Scope landed in this candidate

- **2D CAD engine** (existing Rust/acadrust WASM): typed create/modify/trim/
  extend/offset/layer/measure/check/snap operations, native dimensions and
  leaders, richer `capabilities` v2, strict model-space Z=0/+Z gating, round-trip
  verify before any overwrite. Rebuilt WASM (wasm-bindgen 0.2.126, Rust 1.98.1)
  with 384 MiB linear-memory cap; asset hashes and independent LibreDWG reader
  checks updated.
- **Viewer UI**: draw/modify/layer/measure panels, object snap, boundary
  trim/extend, offset, two-click line/rectangle/circle.
- **`cad.document` tool**: capabilities/read/query/locate/measure/check/propose/
  preview/apply/save/export with revision+SHA-bound proposals, single-use UI
  grants (reserve/commit/release so failures allow retry) and owner/action/
  payload-bound idempotent replay.
- **Headless bridge**: disposable offscreen WKWebView Worker (`cad-host.html`,
  `CadWebEngineSession`); timeout destroys the page. Fixed double-encoded
  edit/query requests (`cad-request.js`), inspect JSON-string return and the
  worker `display_dxf` case; real bridge smoke passes 2/2 on iPad sim.
- **Canvas child projects**: schema-versioned node↔project binding with raw
  preservation for unknown/malformed values, apply-to-original vs explicit
  variant (forked persisted project with parent linkage), copy-fork rule,
  draft flush on close/switch, truthful local/cloud/format asset states, and a
  bounded downsampled thumbnail cache.
- **Image refinements** (model + renderer + validation): vector selections
  (rect/ellipse/lasso, add/subtract/replace, invert, feather) rasterized to
  alpha masks; non-destructive per-layer erase/restore mask; selection-scoped
  fill layers; brush pressure/hardness/opacity; text tracking/leading/
  alignment/stroke/shadow (fixed text color being ignored by Core Text);
  temperature/hue/levels; flipX/flipY.
- **Video refinements** (model + timeline math + commands): exact timecode,
  frame stepping, edge snapping, cover time, caption batch shift/alignment/
  safe-area flags, clip duplication, landscape/portrait/square export presets
  with explicit resolution/fps.
- **Drawing Assistant**: review sheet scope picker (whole/viewport/selection),
  structured context (units/layers/active layer/unsaved/selected handle),
  pending-proposal apply/discard inside the sheet; proposal handle chips now
  locate/highlight the exact engine handle in the live viewer and preview the
  colored added/changed/deleted geometry diff; the review button and panel are
  renamed 图纸助手 / Drawing Assistant throughout the UI.
- **CAD host hardening**: canonical workspace/environment/owner session identity;
  per-document FIFO transaction gates (a queued task cancelled before it runs
  never executes); two grants at one revision can never both edit; uncertain
  mutation/rollback invalidates the engine session and reloads from committed
  bytes; export is full DWG/DXF serialization verified by a fresh same-engine
  reparse (independent reader evidence remains LibreDWG on samples).
- **CAD viewer**: grouped/collapsible categorized panels with >=44pt controls;
  the engineering preview re-adopts the same WKWebView across fullscreen so
  unsaved sessions survive.
- **Image authoring UI**: marquee rect/ellipse/lasso with start-anchored drags,
  brush/eraser settings (size/hardness/opacity/presets/pressure/restore),
  eyedropper, checkerboard, before/after, layer multi-select, duplicate, flip,
  renderer-measured align and render-preserving undoable merge. CUA-found
  coordinate bugs were fixed and regression-tested (drag start, final touch
  sample, pressure-surface local coordinates, flip-preserving transforms).
- **Video UI**: exact timecode + frame stepping, edge snapping, clip duplicate,
  cover-at-playhead, caption style/safe-area guide and batch shift, explicit
  landscape/portrait/square 1080 export presets.
- **Layout**: persisted per-list (files/assets/layers) small/normal/large font
  sizes, 1/2-line file names with extension/path, same-name hint, and a bounded
  persisted iPad sidebar width.
- **Canvas**: video nodes now bind a durable child project (resume, applied
  revision, rendered asset, identity-preserving update); copied bound nodes fork
  through a fixed-document pending/failed lifecycle with file CAS.
- **Workbench AI**: candidates carry their originating request id and are
  grouped accordingly; they remain owned by the request/project and are never
  auto-placed on nodes.

## Executed evidence

| Check | Command | Result |
| --- | --- | --- |
| Rust engine tests | `cargo test --locked` | 39/39 passed |
| Ink contract | `node FloeAgent/scripts/test_cad_ink.mjs` | 73 passed |
| Command surface + normalization | `node FloeAgent/scripts/test_cad_commands.mjs` | 53 passed |
| Viewer assets | `python3 FloeAgent/scripts/check_engineering_viewer_assets.py` | 33 hashes verified |
| Module suites | `swift test` filters | FloeWorkbench media expansion 20, CAD support/gate 6; FloeCore canvas fork 5 + layout 5; FloeNotes page edits 3 |
| Real concurrency | `xcodebuild test -only-testing:FloeAppTests/CadDocumentCenterConcurrencyTests` | 2/2 passed (real WKWebView engine; two grants one revision, same-request replay) |
| Real bridge smoke | `xcodebuild test -only-testing:FloeAppTests/CadWebEngineSessionTests` | 2/2 passed, iPad Air 13-inch (M4) iOS 27.0; xcresult `Test-FloeAppTests-2026.10.08_03-24-42` |
| Full app compile (sim) | `xcodebuild build -scheme FloeAgent -destination generic/platform=iOS Simulator` | BUILD SUCCEEDED (see checkpoint logs) |
| Device Release + symbols | `xcodebuild -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO` | checkpoint build; artifact paths/hashes recorded in the private evidence file |

## Still open before whole-scope completion

Video waveform visuals and edge-drag trim gestures; selected-page PDF export and
per-text search positioning; Office engine-level editing (Word styles/lists/
images/tables, Excel format/freeze/sort/filter/formula, PPT reorder/align) on the
packaged native engine; a canvas backup package that includes child projects and
assets; Notes/Office shared-AI capability parity and the remaining bilingual
schema/example teaching updates; old-node first-edit migration. See
`Local/Private/build265-creative/REQUIREMENT_MATRIX.md` for exact status.

## Completion addendum — Office / Notes / Canvas / CAD (this candidate)

The open list above is superseded for the items below. Device-dependent runtime
qualification is still explicitly pending (a physical iPad was unavailable
during this work); every local test result below is service/package level.

### Engine-level Office editing (Word / Excel / Presentation)

One typed catalog (`OfficeEngineCommandCatalog`) is shared by the editor UI and
the `document.office.edit` agent tool. A proposal binds the document path, the
exact saved SHA-256 and — for commands that act on the current cursor/selection
— an opaque selection fingerprint captured from the live engine. Apply
re-checks that fingerprint, dispatches through the same WKWebView bridge the
ink annotation uses, flushes the private working copy, reopens the SAVED
package and verifies a target-aware delta before the original is committed with
a CAS. A failed batch is restored (engine undo of the dispatched commands, then
a reload from the committed bytes if that cannot be proven) and a failed
restore quarantines the working copy so a manual save can never publish it.

| Format | Operation | Path | Verification | Tier |
| --- | --- | --- | --- | --- |
| docx | style / list / alignment / insert table | engine `.uno:` dispatch | paragraph/style/table delta in `word/document.xml` | engine (device qualification pending) |
| docx | text replace | OOXML rewrite (`document.office.updateText`) | exact field + package reopen | implemented and locally tested |
| docx | image insert | native host attachment (live editor only) | media delta after reopen | engine (device qualification pending) |
| docx / xlsx / pptx | image replace | package rewrite, same image format | media digest + atomic reopen | implemented and locally tested |
| xlsx | number format / rows / columns / freeze / sort / filter / go-to-cell / recalculate | engine `.uno:` dispatch (explicit cell/range first) | addressed cell format, row/column delta, frozen top-left cell, sheet reorder | engine (device qualification pending) |
| xlsx | formula set | OOXML rewrite (`updateText`) | cell `<f>` value after reopen | implemented and locally tested |
| xlsx | formula error locations | saved-package read (`type="e"` cells) | cell + error code list | implemented and locally tested |
| pptx | duplicate slide / align objects / present | engine `.uno:` dispatch | slide-count delta; alignment is dispatch-only (no OOXML geometry claim) | engine (device qualification pending) |
| pptx | move slide | engine duplicate-at-target + delete-original (no `.uno:MoveSlide` exists in the pinned bundle) | saved slide order equals the requested order | engine (device qualification pending) |

Known limits, not hidden: the pinned bundle has no undo-group command, so a
multi-command batch is reverted by restoring the persisted pre-batch bytes
(with a SHA check and unsaved-edit refusal), not by a guessed number of engine
undos; PPT move preserves content and notes but may reset slide identity;
Engine-tier entries still require the device qualification receipts before any
release claim.

Schema examples / 模式示例:

```json
{"action":"read","path":"brief.docx"}
{"action":"propose","path":"brief.docx","expected_sha256":"<64 hex>","summary":"insert table","commands":[{"id":"word.insertTable","arguments":{"rows":"2","columns":"3"}}]}
{"action":"propose","path":"sheet.xlsx","expected_sha256":"<64 hex>","commands":[{"id":"excel.numberFormat","arguments":{"format":"percent","cell":"B2"}}]}
{"action":"apply","path":"brief.docx","proposal_id":"<uuid>","grant_id":"<UI-issued>"}
{"action":"replaceImage","path":"deck.pptx","expected_sha256":"<64 hex>","image":"#1","imagePath":"images/logo.png"}
{"action":"errors","path":"sheet.xlsx"}
{"action":"export","path":"sheet.xlsx","output":"exports/copy.xlsx"}
```

### Notes / PDF shared-AI contract and precise search

- `notes.read section=capabilities` reports a truthful matrix with tiers
  implemented / delegated (workspace `document.pdf.*` on staged copies) /
  unavailable (in-place PDF original-text editing; handwriting text edit).
- `notes.export` exports the selected pages or the whole document to PDF
  (page count re-verified by reopening) or `.floenote` (re-import verified),
  only for conversation-granted documents.
- `notes.edit` gained a propose/preview/apply flow (`action=propose|preview`,
  apply remains the default) with a durable decision outbox: the decision intent
  is persisted before the proposal state changes, delivery is origin-scoped and
  idempotent, and a crash in any gap is reconstructed on restart.
- Search now positions per text: a shared helper returns page + element/node +
  UTF-16 offset/length for elements, extracted text, visual index text, Office
  text and mind-map topics; the library result tap and the agent `notes.search`
  hits carry the same offsets; the editor switches page, centers and highlights
  the matched element, and restores the user's own reading viewport. Flat
  PDF-extracted text without geometry scrolls to the page and says that a
  precise highlight is unavailable instead of guessing.
- The document/resource fingerprint is explicitly a document-JSON SHA-256;
  referenced resource bytes are pinned separately by CAS. Proposal origin
  (conversation/environment) is persisted from the trusted tool context and
  revalidated on preview/apply/recovery.

### Canvas CAD nodes, file-backed packages and draft durability

- Drawing (`.dwg`/`.dxf`) nodes now open the existing CAD editor from the node
  action menu and double-click; the original node is updated with a drawing
  asset (never rasterized), the variant action creates a new node with
  provenance, and dirty sessions survive close with a durable staged draft.
- A failed draft flush is never torn down or deleted: the session is retained
  by a recovery service and retried; LRU eviction only deletes a draft proven
  applied and unchanged. Descriptor writes are serialized with generation CAS
  so a stale marker cannot overwrite a newer applied baseline.
- Canvas package export/import is file-backed and off-main: preflight resolves
  each child project's recorded media root, refuses traversal/symlink/oversize
  sources before writing, carries node drawing assets, and cleans up the
  exported temporary file (reporting any retained file).
- Legacy flattened image/video first edits migrate into a typed child binding
  in ONE canvas patch (asset + binding + refcounts, CAS with retries), keep the
  original asset until the commit, record the original flatten hash, and leave
  retryable `.failed` markers plus the draft when the commit fails. Unknown or
  malformed binding schemas are never overwritten.

### CAD engine additions

- DXF radius/diameter dimensions and leaders round-trip through the engine's
  own save gate again (the mirroring that only applies to DWG no longer leaks
  into DXF); independent LibreDWG evidence covers ARC, LWPOLYLINE
  (open + closed), five DIMENSION kinds and LEADER in DWG AC1024/AC1027/AC1032,
  with the DXF unsupported/rejected cases listed separately.
- CAD live-draft protection: the mutation authority takes a document-level
  lease before apply/save (inside the serialized document gate), refuses a
  dirty viewer, suspends viewer interaction, re-validates the draft revision at
  the final commit boundary and rolls the engine draft back when an edit landed
  meanwhile. The decision outbox now uses a prepared write-ahead record with
  the expected resulting SHA, reconciled only against the exact committed
  bytes.

### Local verification executed for this addendum

| Check | Result |
| --- | --- |
| `swift test --filter FloeDocumentsTests` | 83 tests / 15 suites passed (Office command catalog, target-aware saved-package verification, tool contract) |
| `node FloeAgent/scripts/test_office_command_bridge.mjs` | all checks passed (dispatch, partial-failure, per-batch restore undo, selection fingerprint) |
| FloeCore / FloeWorkspace Canvas suites | 36 + 15 tests passed (migration planner, CAD drawing planner, draft continuity/CAS, backup package) |
| FloeNotes suites (SwiftPM testing helper) | 47 tests / 7 suites passed (search helper, proposals, durable decision outbox) |
| CAD engine | `cargo test --locked` 42/42; LibreDWG 0.13.3 DWG matrix pass; `test_cad_commands.mjs` 58/58; viewer hashes 33/33 |
| Full App simulator build | recorded in the build log referenced by the private evidence file |

English/Chinese UI copy was updated for the new command panel, proposal review,
batch revert refusal and the CAD draft notices. No tag, TestFlight, upload or
public release is performed by this candidate; physical-device acceptance
(engine-tier Office commands, real-page CAD/CAD-in-Canvas interaction) remains
with the primary reviewer.

## Documentation/metadata completion — 2026-10-08

This candidate note is retained as the dated engineering addendum. The complete
aligned bilingual user/tool/capability documentation and release metadata now
live in:

- [Creative tool contracts and format capability table](../../FLOE_1_7_24_CREATIVE_TOOLS.md)
  (shared discover→read→propose→confirm→apply→verify contract, `cad.document`,
  `document.office.edit`, Notes and `media.project` schema/examples, Drawing
  Assistant, truthful CAD/Office capability tiers);
- [release notes 1.7.24 (265)](RELEASE_NOTES_1.7.24_BUILD_265.md) and the
  TestFlight what's-new JSON `../testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_265.json`;
- Build 265 sections in `USER_GUIDE.md` / `USER_GUIDE.zh-CN.md`.

Clarifications carried into those documents: LibreDWG is offline release
qualification on representative outputs (not an in-app per-save reader);
implemented-but-device-unverified engine commands differ from runtime-
unavailable capabilities; and the current Canvas backup export covers media
child projects/assets while unapplied CAD draft descriptors/history are not yet
included (being completed and tested before the freeze), so CAD draft/history
backup is not yet verified. CAD-in-Canvas add/edit/Finish twice was verified in
an iPad simulator CUA with an independent LibreDWG re-read, but physical-device
and native Office engine acceptance remain open.

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

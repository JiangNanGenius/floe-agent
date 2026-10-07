# Floe 1.7.24 (build 265) — CAD / Drawing Assistant / Canvas / image+video refinements candidate note

Status: source validated locally on branch `codex/build265-creative-cad`.
No tag, TestFlight or public release. Version fields still read 1.7.23(265
change pending); the primary must bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
to 1.7.24(265), verify no conflicts, and perform external acceptance/release.

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
  pending-proposal apply/discard inside the sheet.

## Executed evidence

| Check | Command | Result |
| --- | --- | --- |
| Rust engine tests | `cargo test --locked` | 39/39 passed |
| Ink contract | `node FloeAgent/scripts/test_cad_ink.mjs` | 73 passed |
| Command surface + normalization | `node FloeAgent/scripts/test_cad_commands.mjs` | 53 passed |
| Viewer assets | `python3 FloeAgent/scripts/check_engineering_viewer_assets.py` | 33 hashes verified |
| Module suites | `swift test` filters | FloeWorkbench 69+ passed (incl. 9 image refinement, 9 video, 12 tool, 3 fork); FloeCore 245 passed |
| Real bridge smoke | `xcodebuild test -only-testing:FloeAppTests/CadWebEngineSessionTests` | 2/2 passed, iPad Air 13-inch (M4) iOS 27.0; xcresult `Test-FloeAppTests-2026.10.08_03-24-42` |
| Full app compile (sim) | `xcodebuild build -scheme FloeAgent -destination generic/platform=iOS Simulator` | BUILD SUCCEEDED (see checkpoint logs) |
| Device Release + symbols | `xcodebuild -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO` | checkpoint build; artifact paths/hashes recorded in the private evidence file |

## Still open before whole-scope completion

Image selection/brush UI, eyedropper/presets, layer multiselect/align/merge UI,
before/after + checkerboard view; video timecode/frame/snap/preset UI wiring;
Notes/PDF presets/lasso/page operations; Office mode/find/replace/table-
format features; persisted file-list typography and resizable sidebar; remaining
shared-AI schema/example updates. See `Local/Private/build265-creative/REQUIREMENT_MATRIX.md`.

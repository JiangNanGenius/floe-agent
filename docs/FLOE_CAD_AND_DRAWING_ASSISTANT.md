# Floe CAD engine, `cad.document` and Canvas child projects

> **2026-10-08 superseding note:** this page records the early Build 265 candidate
> (its verification counts, "known gaps" and the 1.7.23(264) checkpoint artifact
> note are from that stage). The completed Build 265 surface, current test results
> (engine 42/42, commands 58/58, ink 78/78, 83 FloeDocuments + 47 FloeNotes +
> 19 App tests, simulator CAD-in-Canvas CUA), the Office/Notes shared tools and the
> truthful capability tiers are now documented in
> [creative tool contracts and format capability table](FLOE_1_7_24_CREATIVE_TOOLS.md)
> and the [1.7.24 (265) release notes](releases/notes/RELEASE_NOTES_1.7.24_BUILD_265.md).
> Engine-tier Office editing still needs physical-device qualification; the text
> below is retained as historical evidence.
>
> **2026-10-08 取代说明：** 本页记录 Build 265 早期候选阶段（其中验证计数、“已知缺口”及
> 1.7.23(264) 检查点产物说明均属当时）。Build 265 的最终能力面、当前测试结果、Office/手记
> 共享工具与真实能力分级见[创作工具契约与格式能力表](FLOE_1_7_24_CREATIVE_TOOLS.md)和
> [1.7.24（265）发布说明](releases/notes/RELEASE_NOTES_1.7.24_BUILD_265.md)。引擎层 Office
> 编辑仍待真机资格；下文作为历史证据保留。

Status: implementation validated locally (Build265 branch `codex/build265-creative-cad`).
No tag, TestFlight or public release was produced; primary UI/CUA acceptance and
the release execution remain with the primary agent.

本文件说明 1.7.24（265）候选中的二维 CAD 引擎、`cad.document` 工具以及画布子工程绑定。
状态：本地实现与测试已验证；未打标签、未上传、未发布，UI 实机验收仍由 primary 执行。

## 1. Engine / 引擎

The existing Floe-owned MPL-2.0 binding over acadrust 0.5.5
(`FloeAgent/ThirdParty/CADEngine`) was extended; no parallel CAD engine exists.

| Capability | Support |
| --- | --- |
| Create | `addLine`, `addCircle`, `addArc`, `addLwPolyline` (closed rectangle = 4 points), `addText`, `addLeader` (vertices only), `addDimension` linear/aligned/angular/radius/diameter |
| Modify | `move`, `copy`, `rotate`, `scale` (uniform), `mirror`, `delete`, `setText`, `setRadius`, `setLayer`, `setColor`, `setLineWeight` |
| Geometry | `trim` (line/arc targets), `extend` (line target), `offset` (line/circle/arc/open LWPolyline) |
| Layers | create / rename / update (lock, visibility, ACI color, linetype, canonical line weight) / delete only when unreferenced; move entity to layer |
| Annotation | atomic `addStroke` pencil ink on `FLOE_ANNOTATION` (one undo snapshot, Z preserved) |
| Queries | `capabilities`, `drawing`, `layers`, `entities`/`text` (paginated ≤ 500), `snap`, `measure`, `check`, `locate` |
| Atomicity | every edit validates on a clone; a failed request leaves document and history untouched. `batch` (≤ 64 ops) is all-or-nothing with one undo snapshot |

Coordinate/space rules: edits are limited to model-space entities on the Z=0 XY
plane with a +Z extrusion. Raised/sloped geometry, paper space, non-default OCS,
splines, blocks, xrefs, proxy graphics and 3D content stay read-only and are
never flattened. Undefined `INSUNITS` stays “unitless drawing units”; mm is
never assumed.

Save (`save`) re-encodes DWG or DXF, reparses the actual output, and compares
entities, references, layer values and auxiliary objects before returning
bytes. Lossy unsupported data blocks overwrite rather than silently replacing
the source. This remains a compatibility guard, not proof for arbitrary
third-party files.

Independent cross-check: LibreDWG 0.13.3 (`/opt/homebrew/bin/dwgread`,
`dwg2dxf`) parsed native-test DWG outputs (LINE/CIRCLE/TEXT, including Chinese
text) alongside the acadrust round-trip tests.

## 2. Viewer UI / 查看器界面

`EngineeringViewers/cad-editor.js` + `cad-commands.js` add: draw tools
(line/rectangle/two-click circle/numeric arc/polyline/text/dimension/leader),
modify tools (move/copy/rotate/scale/mirror/delete/trim/extend/offset with a
boundary pick), layer panel (active layer, lock, visibility, counts, add /
rename / delete), measure and check, locate-selected, window selection from
entity bounds, and an object-snap indicator backed by the engine’s own snap
query. All requests are the same typed operations the tool uses; there is no
arbitrary JS or file API.

## 3. Headless host / 无界面宿主

Agent tools and the Drawing Assistant run the same wasm and the same
`cad-worker.js` inside a disposable offscreen WKWebView served from the pinned
`EngineeringViewers` bundle (`cad-host.html`, `CadWebEngineSession.swift`):

* one session per document revision; every call is deadline-bounded;
* a timed-out or failed call destroys the web view (loader stopped, handler
  removed, reference released), terminating the page and its Worker — there is
  no unstoppable in-process evaluation;
* the wasm build caps linear memory at 384 MiB (`-C link-arg=--max-memory=`),
  and the engine bounds files (10 MiB), entities (20k), history (8) and text.

## 4. `cad.document` tool

| Action | Effect |
| --- | --- |
| `capabilities` | engine-declared surface (no document needed) |
| `read`, `query`, `locate`, `measure`, `check` | read-only; structured engine JSON |
| `propose` | validates a typed batch on a throwaway session and returns an added/changed/deleted preview; never writes |
| `preview` | stored proposal overlay |
| `apply` | consumes a single-use UI grant bound to proposal + document + revision + SHA; applies one atomic undoable transaction and commits with SHA compare-and-swap |
| `save` | commits the verified engine output with CAS |
| `export` | writes a separate verified DXF presentation copy; the source stays unchanged |

Confirmation: only the interactive CAD UI mints grants. `apply` reserves the
grant, runs the edit, engine-verifies and commits; on any failure it rolls the
engine draft back (one `undo`) and releases the reservation so the same
authorized proposal can be retried inside the TTL. Tool-call ids replay the
recorded receipt only for the same authenticated owner/environment/workspace/
document/action/payload.

## 5. Canvas child projects / 画布子工程

* `CanvasChildProjectBinding` (schemaVersion 1) is stored in node metadata:
  project id, applied revision, draft revision, rendered asset, source node,
  source asset hash. Legacy nodes without the key decode to `.absent`; unknown
  newer versions and malformed values are preserved raw and surfaced for
  recovery instead of silently starting a new edit.
* Opening an image node resumes the bound project id (not a filename guess).
  A missing bound project is an explicit error with “start new edit”.
* “Apply to canvas” updates the ORIGINAL node (identity, name, position, size,
  edges preserved) after a verified export; “Make variant” is the only path
  that creates a new node + `.generatedFrom` edge, bound to a persisted forked
  project (new identity, `parentProjectID`, fresh undo/redo, shared asset
  bytes). Copied nodes follow the same fork rule.
* Closing or switching the workbench flushes the draft before teardown.
* Asset placeholders distinguish missing local file, cloud-only, undecodable
  format and unsupported types, with a cloud-restore action; node images use a
  bounded downsampled thumbnail cache instead of decoding full files per pass.

## 6. Verification executed in this job

| Check | Command | Result |
| --- | --- | --- |
| Rust engine native tests | `cargo test --locked` (Rust 1.98.1, wasm-bindgen 0.2.126) | **39/39 passed** |
| Viewer ink contract | `node FloeAgent/scripts/test_cad_ink.mjs` | **73 passed, 0 failed** |
| Viewer command surface + bundled WASM | `node FloeAgent/scripts/test_cad_commands.mjs` | **47 passed, 0 failed** |
| Asset inventory/pins | `python3 FloeAgent/scripts/check_engineering_viewer_assets.py` | 32 hashes verified |
| `cad.document` tool tests | `swift test --filter CadDocumentToolTests` | **12/12 passed** |
| Child-project fork tests | `swift test --filter MediaProjectForkTests` | **3/3 passed** |
| Canvas binding tests | `swift test --filter CanvasChildProjectBindingTests` | **7/7 passed** |
| Full app compile (simulator) | `xcodebuild build -scheme FloeAgent -destination 'generic/platform=iOS Simulator' ARCHS=arm64` | **BUILD SUCCEEDED** |
| Independent DWG reader | `dwgread -O JSON edited-AC1032.dwg` | SUCCESS; entities/layers parsed |

## 6b. Checkpoint additions (image/video/assistant)

* Image model+renderer: vector selections with feather/invert and alpha-mask
  rasterization, non-destructive layer erase/restore masks, selection-scoped
  fill layers, brush pressure/hardness/opacity, text tracking/leading/alignment/
  stroke/shadow (a real Core Text color bug was fixed), temperature/hue/levels,
  flipX/flipY. 9 renderer/model tests + command validation tests pass.
* Video: exact `HH:MM:SS:FF` timecode, frame stepping, edge snapping, explicit
  cover time, caption batch shift/alignment/safe-area flags, clip duplication,
  landscape/portrait/square presets with explicit resolution/fps. 9 tests pass.
* Drawing Assistant: scope picker (whole drawing / viewport / selection),
  structured context (units, layers, active layer, unsaved revision, selected
  handle) and pending-proposal apply/discard in the review sheet.

## 7. Known gaps (honest)

* Drawing Assistant scope selector (whole drawing / viewport / selection) and
  the proposal overlay are only partially wired; `CadDocumentCenter` already
  returns structured assistant context including located selection handles.
* Images/video/notes/PDF/Office/layout increments from the approved matrix were
  not implemented in this job; see the private requirement matrix.
* No real paid model/provider workflow was exercised; no CUA/visual acceptance
  was performed here.
* The device artifact is built from source whose version is still
  1.7.23(264); the primary must bump to 1.7.24(265) and verify build numbers
  before any distribution.

---

## Native FloeCAD workbench — unreleased work, 2026-10-09

Status: **implemented in the worktree and locally verified; not merged, not
tagged, not published.** This section records the native 3D/parametric CAD
extraction and integration performed on branch `codex/content-upgrade-20261009`.
It is deliberately separate from the shipped 1.7.24 (265) surface described
above; no release material may claim any of it until the remaining matrix
closes and the primary agent accepts it (UI/CUA, device, release).

### What was built

- **`FloeAgent/ThirdParty/FloeCADKit`** — a local iOS Swift package with:
  - OCCT 7.8.1 static slices behind an ObjC++ façade (`OCCTShim`), vendored
    from OpenShape3D with hashes/provenance in `UPSTREAM.md`;
  - the extracted OpenShape3D kernel, constraint solver, parametric feature
    graph, topology naming, import/export kits, Metal renderer and editor
    state machine (MIT; modification record in `PATCHES.md`);
  - Floe-owned replacements: `CADPreferences`, the versioned `.floecad`
    package store (`manifest.json` + `document.json` + separate binary
    B-rep/mesh blobs, staged commit with `previous/` recovery, revision-guarded
    off-main writes), the public `FloeCADDocument` facade, and
    `CADProposalService`.
- **App integration** — `FloeApp/Workspace/FloeCAD3DBridge.swift` owns one
  live `FloeCADDocument` per canonical path (deduplicating concurrent opens)
  and answers the `cad.document` native actions via
  `CadDocumentCenter.threeDAction` (same access authorization, same
  `CadProposalGrantStore`, same CAS). `FilePreviewView` opens `.floecad`
  through the guarded resolver and embeds `FloeCADWorkbenchView` with an
  interactive proposal banner (Apply/Discard). `WorkspaceTextPolicy` classifies
  `.floecad` as CAD, not text.
- **Tool surface** — `cad.document` gains `three_d_snapshot`,
  `three_d_measure`, `three_d_propose`, `three_d_apply`, `three_d_assembly`,
  `three_d_drawing`. Propose evaluates the typed operation on a *flushed*
  throwaway copy of the exact in-memory revision and never writes; apply needs
  a UI-issued single-use grant bound to proposal + revision + SHA.

### Verification actually run (2026-10-09/10)

| Check | Command | Result |
| --- | --- | --- |
| `FloeCADKit` package tests (fixture, recovery, proposal) | `xcodebuild test -scheme FloeCADKit -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)'` (Xcode 27A266a) | **12/12 passed** |
| Critical fixture: 100×60×10 plate + fully internal Ø10 through-hole | in-suite | exact volume 60000−250π mm³; thickness→20 gives 120000−500π with unchanged hole; analytic B-rep survives save/reopen; undo/redo; CAS revision/SHA move |
| Failure injection: failed overwrite-create / failed commit | in-suite | previous document/commit preserved byte-identically, staging debris cleaned, retry succeeds |
| Proposal contract | in-suite | propose never mutates; unsaved edits are flushed into the preview; forged/missing/stale/consumed grants refused; authorized apply commits and reopens |
| Independent STEP reader (no OCCT, Python) | `python3 scripts/verify_step_independent.py <export.step> --expect-thickness …` | PASS on 10 mm and 20 mm exports: ISO-10303-21, LENGTH_UNIT `.MILLI.`, 1 solid / 7 faces (6 planes + 1 cylinder), parsed bounds/diameter/axial length, analytic volume within 1e-3 mm³ |
| Independent reader tamper tests | `python3 scripts/test_verify_step_independent.py` | 5/5 passed (mm→cm, Ø10→Ø14, solid removal, decimal forms, real fixture) |
| Full App compile (Xcode 27, iOS Simulator, arm64) | `xcodebuild build -project FloeAgent.xcodeproj -scheme FloeAgent …` | **BUILD SUCCEEDED** (OCCT statically linked) |
| App test build + focused app test | `xcodebuild test … -only-testing:FloeAppTests/FloeCADWorkbenchTests` | **BUILD/TEST SUCCEEDED**, 1/1 passed (create→sketch→extrude→measure→save→reopen through the app facade) |

The independent STEP reader is a **restricted fixture geometry check** for the
plane+cylinder class, not a general STEP compatibility reader; the same-kernel
OCCT re-import is reported separately in the suite and is not counted as
independent.

### Completion matrix (honest)

| Area | State |
| --- | --- |
| Versioned `.floecad` kernel: units/tolerance/params/features/B-rep, atomic commit, previous snapshot, revision/CAS, undo/redo | implemented + tested |
| Sketch (constraints/dimensions/solver), exact 3D features (primitives, extrude, revolve, sweep/helix, loft, boolean, pattern, mirror, fillet/chamfer/shell/draft, face push-pull/move/offset, section) | implemented via the vendored kernel; the fixture/STEP and proposal suites exercise a subset (extrude/boolean/measure/rebuild). Full per-feature matrix not re-run here |
| Save/reopen, STEP export/import | implemented + tested (fixture); IGES import not wired |
| AI `cad.document` 3D actions, propose/apply gate, shared live session | implemented; app build + focused test pass |
| Assembly service (instances/constraints/DOF/interference) and drawing service (views/scale/PDF/SVG/DXF) | **superseded 2026-10-10 (part 2)**: both implemented and tested — see the continuation section below |
| ShapeScript interpreter, Euclid mesh tooling UI, Canvas creation path | **partly superseded 2026-10-10 (part 2)**: ShapeScript + mesh services/UI implemented and tested; the native→Canvas entry remains open |
| Workbench UI localization (en/zh-Hans) | **in progress 2026-10-10 (part 2)**: Floe-owned chrome and the new panels are bilingual; imported editor internals and several toolbar/menu strings remain English |
| Real-model provider end-to-end (`describe→measure→propose→confirm→save/reopen/export`) | **not run** — no real provider session was exercised here; the host/UI loop exists and the plan-gate path is unit-tested with a clone, but primary must run it on device/review |
| Physical-device / CUA acceptance, performance baseline (first paint/frame/peak memory/rebuild) | **not run** — remains with the primary agent |

### Commands used

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme FloeCADKit \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
  -derivedDataPath ~/Library/Caches/CodexBuild/floe-cad/DerivedData/pkg \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project FloeAgent.xcodeproj -scheme FloeAgent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ~/Library/Caches/CodexBuild/floe-cad/DerivedData/app \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

### 中文摘要

本轮在 `codex/content-upgrade-20261009` 引入了本地 Swift 包 `FloeCADKit`（OCCT 7.8.1 原生
B-rep 桥接 + 参数化特征图 + 求解器 + Metal 视口 + 编辑状态机，来源与修改见包内
`UPSTREAM.md`/`PATCHES.md`），并完成 `.floecad` 版本化文档内核（原子提交、旧快照恢复、
修订/内容哈希 CAS、离主线程写入）、`FloeCADDocument` 门面、`cad.document` 三维动作与
UI 提案确认回路。已运行证据：包内 12/12 测试（含 100×60×10 带 Ø10 通孔精确体积
60000−250π、厚度改 20 得 120000−500π、保存重开与 STEP）、独立 Python STEP 读取器
（单位/拓扑/圆柱/体积）及 4 个篡改用例、完整 App 编译与定向 App 测试。**未完成**：装配与
出图服务、ShapeScript/网格/画布创建链路、工作台中英文本地化、真机与真实模型端到端验收、
性能基线。以上均未发布，发布与最终验收由主协调者执行。

---

## Native FloeCAD continuation — unreleased work, 2026-10-10 (part 2)

Status: **implemented in the worktree and locally verified; not merged, not tagged, not
published.** Branch `codex/content-upgrade-20261009`. This section records the continuation
that closes the assembly/drawing/script/mesh services, the unified `cad.document` routing,
the reviewed permission/ownership fixes and the workbench UI entry points. Everything here is
still unreleased; primary-agent CUA/device acceptance is required.

### What was added

- **Assembly service** (`CADAssemblyService`): shared/independent instances (body-lifecycle
  commands), constraints (fixed/coaxial/planar align/distance/angle), an iterative projection
  solver with invalid-reference vs conflicting separation, approximate DOF reporting, typed
  `sourceRevision` tracking and exact interference. Exact interference serializes the placed
  B-reps on the main actor and runs OCCT booleans on owned deserialized copies in a detached
  task; task cancellation and the document revision/change count are re-checked before a
  result is accepted (late results are discarded). A test-only probe asserts the worker ran
  off the main actor.
- **Drawing service** (`CADDrawingService`): independent pages (front/top/side/iso/section/
  detail), real orthographic and section projection, linear/diameter/radius dimensions and
  centerlines, and vector PDF/SVG/R12-DXF exports (real projected geometry, no screenshots).
  Pages carry typed `detailOrigin`/`detailSizeMM` (never aliased into the section plane) and
  an ordered per-source content/placement fingerprint; `CADDrawingSet` has an explicit schema
  version with legacy decode defaults.
- **ShapeScript + mesh** (`ShapeScriptKit`, `CADScriptService`, `CADMeshService`): pinned
  interpreter `cda3024…` (1.11.6) evaluated headlessly with a refusing delegate (no imports,
  no host file reads), source/time/triangle limits and task cancellation; script records are
  result-bound by a render-mesh SHA-256 (manual edits/undo are detected; apply refuses or
  explicitly forks/rebuilds); mesh combine/boolean/transform/normals/boundary/repair/simplify/
  material/image operations keep analytic B-reps unless the caller explicitly forces a mesh
  downgrade.
- **Unified `cad.document` routing**: the schema enum now equals the runtime `CadDocumentAction`
  cases (including `three_d_*`, `status`, `cancel`, `op`/`args`/`payload`/`task_id`); `.floecad`
  paths route read/query/locate/measure/check/propose/preview/apply/save/export/status/cancel to
  the native kernel and never through the 2D DWG/DXF loader (capability discovery included).
- **Permission/ownership contract** (review fixes): native apply re-checks the recorded
  propose-time access identity AND the canonical target before reserving a grant; grants use
  the same reserve → commit/release two-phase semantics as the 2D path with idempotent
  receipts; mutating assembly/drawing/script/mesh payload actions are refused
  (`proposal_required`) and reachable only through propose → preview → UI grant → apply;
  durable task records store environment/owner/document and `status`/`cancel` are scoped to
  that exact ownership (foreign owners get notFound/unauthorized).
- **Workbench tools panel** (`CADWorkbenchPanels.swift`): one toolbar sheet with Assembly /
  Drawings / ShapeScript / Mesh panels driving the same services; `FloeCADStrings` routes
  Floe-owned chrome through the host localization catalog.
- **Deterministic fixture launch** (DEBUG only): `-ui-testing --ui-test-cad-fixture` opens the
  real workbench on a 100×60×10 mm plate with an internal Ø10 through-hole built through the
  typed command vocabulary.

### Verification actually run (2026-10-10, part 2)

| Check | Command | Result |
| --- | --- | --- |
| `FloeCADKit` package tests | `xcodebuild test -scheme FloeCADKit` (Xcode 27A266a, iPad Air 13-inch M4 simulator) | **37/37 passed** (assembly 9, drawing 8, script+mesh 9, plate/hole fixture 1, proposal 6, store recovery 4) |
| Full App compile (simulator arm64) | `xcodebuild build -project FloeAgent.xcodeproj -scheme FloeAgent …` | **BUILD SUCCEEDED** |
| Focused App tests | `-only-testing:FloeAppTests/NativeCADProposalAuthorityTests -only-testing:FloeAppTests/FloeCADWorkbenchTests` | **5/5 passed**: cross-document/cross-task apply denial, failed-apply reservation release, direct payload mutation denial + proposal route, ownership-scoped status/cancel, facade create→save→reopen |
| Independent STEP reader / tamper tests | `python3 scripts/verify_step_independent.py`, `test_verify_step_independent.py` | retained from part 1 (5/5); still a restricted fixture check, not general STEP compatibility |

### Fixture launch recipe (primary CUA)

```sh
# Debug simulator build already installed, or build/install it:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FloeAgent.xcodeproj -scheme FloeAgent \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
  -derivedDataPath ~/Library/Caches/CodexBuild/floe-cad/DerivedData/app \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

# Launch with the deterministic CAD fixture (real workbench, no workspace,
# no grants, no credentials):
xcrun simctl launch <booted-device-udid> org.floeagent.ios \
  -ui-testing --ui-test-cad-fixture
```

The harness rebuilds the package deterministically on each launch. Expected part:
volume 60000 − 250π ≈ 59214.6 mm³ (check via the AI `cad.document` measure path or the
viewport info bar). Then exercise: Assembly (place instance, solve, DOF, interference),
Drawings (standard sheet, project, dimensions, PDF/SVG/DXF), ShapeScript (preview/apply),
Mesh (boolean on a mesh copy). Debug-only: no release code path can create this fixture.

### Completion matrix update (honest)

| Area | State |
| --- | --- |
| Versioned `.floecad` kernel, atomic commit, CAS, undo/redo, off-main save | implemented + tested |
| Sketch/parametric features, analytic B-rep, STEP export, plate+hole fixture | implemented + tested (part 1) |
| Assembly service (instances/constraints/DOF/interference/source update) | implemented + tested; exact interference off-main on owned copies; UI panel present |
| Drawing service (pages/views/dimensions/PDF/SVG/DXF) | implemented + tested (real projected geometry); UI panel present |
| ShapeScript + mesh operations | implemented + tested (headless, bounded, sandboxed) |
| Unified `cad.document` routing + schema | implemented; App tests cover native routing; SwiftPM workbench tests for schema/routing in this worktree |
| Workbench tools panel + Floe-owned localization | panel implemented; 216 new `cad.*` keys (panels/settings/toolbar + 173 editor-chrome keys) bilingual en/zh-Hans; remaining imported-editor internals (EditorViewModel labels, materials, some footers) still English |
| Canvas child-project entry from the native workbench | implemented: "Apply to canvas" (PNG asset, original bound node updated atomically, identity/name/position/size/edges preserved) and explicit "Make variant" (new node + generatedFrom edge); no binding → explicit refusal, no parallel node path; planner tests 7/7 |
| IGES import | implemented: real OCCT IGES reader (solids vs surfaces classified honestly, B-rep kept only for solids); round-trip and refusal tests 5/5; no IGES export |
| Durable status/cancel jobs + ownership scoping | implemented + tested; proposal notification outbox durability for native 3D proposals is in-process only (2D path keeps its journal) |
| CUA viewport crash (SIGTRAP, 2026-10-10) | fixed: package shader library is compiled/validated explicitly (host default.metallib no longer selected first) and a missing library surfaces a recoverable alert; `ViewportRenderTests` 2/2 cover context + attach + draw |
| Physical-device / CUA acceptance, real-provider end-to-end, performance baseline | **not run** — primary agent owns device/CUA/provider acceptance (fixture recipe below) |

### 中文摘要（2026-10-10 续作，未发布）

本轮完成装配服务（实例/约束/求解/自由度/干涉/源更新；精确干涉在主线程序列化 B-rep 后于
分离任务中对自有副本执行，带取消与修订检查）、出图服务（独立页面/投影/尺寸/中心线/PDF/
SVG/DXF 真实几何）、ShapeScript 无头求值与脚本结果绑定、网格操作，统一 `cad.document`
路由与模式（`.floecad` 不再经过二维加载器），并按评审意见修复权限：直接 mutation 载荷被
拒绝、提案/授权/预留/幂等回执、任务记录按环境/所有者/文档隔离、失败回执如实记录。工作台
工具面板、原生画布入口（更新原节点 / 显式变体）、IGES 实体/曲面导入与中英文案已接入；
模拟器 CUA 视口崩溃（宿主 default.metallib 被误选、管线缺失后断言）已修复并有视口初始化/渲染
测试。已运行：包内 44/44、完整 App 编译成功、定向 App 测试 5/5、工作台 schema/路由 22/22、
画布规划器 7/7。未完成：导入编辑器剩余内部文案（EditorViewModel 标签、材料名等）中文化、
原生提案通知持久化 outbox、真机/真实模型/性能验收；均未发布。

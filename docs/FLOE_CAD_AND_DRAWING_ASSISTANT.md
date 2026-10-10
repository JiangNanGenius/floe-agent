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
SVG/DXF 真实几何）、ShapeScript 无头求值与脚本结果绑定、网格操作，统一 `cad.document` 路由
与模式（`.floecad` 不再经过二维加载器），并按评审意见修复权限：直接 mutation 载荷被
拒绝、提案/授权/预留/幂等回执、任务记录按环境/所有者/文档隔离、失败回执如实记录。工作台
工具面板、原生画布入口（更新原节点 / 显式变体）、IGES 实体/曲面导入与中英文案已接入；
模拟器 CUA 视口崩溃（宿主 default.metallib 被误选、管线缺失后断言）已修复并有视口初始化/渲染
测试。已运行：包内 44/44、完整 App 编译成功、定向 App 测试 5/5、工作台 schema/路由 22/22、
画布规划器 7/7。未完成：导入编辑器剩余内部文案（EditorViewModel 标签、材料名等）中文化、
原生提案通知持久化 outbox、真机/真实模型/性能验收；均未发布。

---

## Native FloeCAD continuation — unreleased work, 2026-10-10 (part 3: recovery, localization, production entry, CUA repair)

Status: **implemented and locally verified; not merged, not tagged, not
published.** This section records the round that closes the review-hardened
persistence/recovery contract, the production creation/import entry, the
remaining imported-editor localization, the CUA panel repair and the
reproducible performance baselines. Branch `codex/content-upgrade-20261009`.

### What was added

- **Durable native proposal persistence + origin notification.**
  `NativeCADProposalStore` (versioned envelope; corrupt/newer-schema state is
  rejected and preserved, never overwritten — quarantine is explicit; growth
  is bounded: active records never dropped, saturation refuses with a clear
  resource error; writes run off the caller thread) persists the frozen
  operation, owner/environment/canonical document/revision, receipts and
  status (pending/applying/interrupted/applied/rejected/superseded). Apply
  receipts are also written to the SHARED `CadAppliedReceiptJournal`;
  adoption/rejection/manual-conflict/interrupted decisions reach the
  originating conversation through the SHARED durable decision outbox
  (idempotent delivery, retried at launch). Preview enforces the same
  recorded ownership as apply; replay survives relaunch for the same request
  id only; UI-issued grants cannot be forged by a model (authority is the
  recorded propose-time access + canonical target, re-checked before any
  reservation).
- **Crash-safe recovery against the verified package identity.**
  `FloeCADDocument.storedIdentity(at:)` reads the manifest + document JSON +
  every blob through the versioned store (the content digest binds each
  blob's SHA-256). Reconciliation resolves an interrupted apply ONLY against
  that identity: a completed journal entry whose expected SHA equals the
  verified content SHA recovers as applied; an unchanged base revision
  returns to pending (honest retry); an advanced package without that proof
  recovers as **interrupted** — never "applied", never a safe retry. A
  durable `.applying` marker binds the expected result revision before the
  mutation runs (no package-directory hashing anywhere).
- **Production creation + Canvas create-node route.**
  `FloeCADDocument.create` was reachable only from the DEBUG fixture. The
  file tree now offers "New CAD Document" (toolbar + and folder menu)
  creating a real versioned package through the guard resolver in local
  workspaces. The Canvas Add menu gains an explicit "CAD model (parametric
  workbench)" entry next to the 3D scene director (kept distinct — the scene
  editor is not CAD), creating a real `.floecad` bound as a native node; the
  workbench's "Add to canvas" offers an explicit destination picker (no
  first-canvas guessing; a binding that appears between pick and write
  refuses). The contradictory "Make variant without a node" dead end is gone.
- **Localization.** The imported editor's user-facing strings now route
  through the host catalog with live resolution: the full command catalog
  (65 commands + 7 categories), feature option/scalar labels, history
  feature labels (display-time, stored data stays English), material names,
  snap labels, sketch/measure statuses, constraint chips, workbench panel
  reports/empty states and the common import/export/feature errors. The
  catalog carries ~380 `cad.*`/`canvas.cad.*` bilingual keys.
- **CUA panel repair (iPad-first).** The tools sheet fills its width, wraps
  actions in an adaptive grid at a 44pt hit-target floor, renders native
  structured reports (assembly instances/constraints with
  stale/suppressed/invalid/conflict badges + DOF summary; drawing pages with
  scale/stale; script records with applied/stale; mesh selection state) with
  meaningful empty states and readable styled errors — raw JSON never
  reaches the user — and has an explicit Close control. The production
  FilePreview host and the qualification fixture present the SAME Floe-level
  chrome (explicit save with status + fullscreen) via a shared modifier.
- **Script result binding (guidance cad-script-review-1 completed).** Apply
  now enforces the recorded `outputDocumentRevision` against the live
  document, not just the render hash: any committed change refuses an
  automatic re-apply until the caller explicitly chooses `fork`/`rebuild`;
  record + body stay one undoable composite.
- **IGES mixed roots.** A file carrying BOTH a closed solid and loose
  surfaces imports both (exact analytic solid + render-only surface bodies,
  per-body undo) — never "solids only, surfaces dropped".
- **Reproducible performance fixtures.** `CADPerformanceBaselineTests` build
  synthetic medium (96 bodies) and large (600 bodies) models through the
  typed command vocabulary and measure build/snapshot/save/open + resident
  memory with sanity bounds only. Honest baseline on the M5 Pro simulator
  host: medium build 1.18s / save 0.045s / open 0.045s; large build ~33s
  (≈55ms per typed op — the per-op executor/JSON path, not a paint metric) /
  save 0.41s / open 0.28s. These are first measurements, not improvements;
  viewport first-paint/frame latency remains a CUA/physical-device gate.

### Verification actually run (2026-10-10, part 3)

| Check | Command | Result |
| --- | --- | --- |
| Focused App tests (persistence 14, authority 4, creation 2, workbench 1) | `xcodebuild test-without-building … -only-testing:FloeAppTests/…` (Xcode 27A266a, iPad Air 13 M4 sim) | **21/21 passed** |
| FloeCADKit package tests | `xcodebuild test -scheme FloeCADKit …` | **48/48 passed** (assembly 9, drawing 8, script+mesh 10, IGES 6, plate/hole 1, proposal 6, store recovery 4, viewport 2, perf 2) |
| Host UI smoke (iPad regular width) | `… -only-testing:FloeAgentUITests/CADWorkbenchHostIPadUITests` | **1/1 passed** (toolbar chrome, tool-strip response, tools-sheet panels + Close, history panel) |
| Host UI smoke (iPhone compact, serial) | `… CADWorkbenchHostIPhoneUITests` | **passed with 1 recorded skip** — compact toolbar overflow hides `CADWorkbenchToolsButton`; panel reachability on compact phones moves to the primary CUA checklist |
| Full App compile (simulator arm64) | `xcodebuild build-for-testing …` | **TEST BUILD SUCCEEDED** |
| Full App compile (generic iOS device, unsigned) | `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**; unsigned Debug product + provenance (source SHA, toolchain, binary SHA-256) preserved under `Local/Private/content-upgrade/device-artifact-20261010` |
| Independent STEP reader / tamper tests | retained from part 1/2 | 5/5 (unchanged) |

Fixture launch recipe (primary CUA, unchanged):

```sh
xcrun simctl launch <booted-device-udid> org.floeagent.ios \
  -ui-testing --ui-test-cad-fixture
```

Normal production entry for the second pass: Files tree "+" → "New CAD
Document" (or a folder's context menu) → name → the workbench opens with the
Floe-level Save/Fullscreen chrome; Creative → New Canvas → Add → "CAD model
(parametric workbench)" creates a package bound as a native canvas node; the
3D scene director next to it stays a lightweight scene composer and is not
CAD. Canvas binding from the workbench: CAD Tools → "Add to canvas" /
"Apply to canvas" / "Make variant".

### Completion matrix update (honest)

| Area | State |
| --- | --- |
| Versioned `.floecad` kernel, atomic commit, CAS, undo/redo, off-main save | implemented + tested |
| Sketch/parametric features, analytic B-rep, STEP/IGES import, plate+hole fixture | implemented + tested (IGES mixed-roots now covered) |
| Assembly/drawing/script/mesh services | implemented + tested; panels now structured/44pt/localized |
| Script manual-result conflict + `outputDocumentRevision` enforcement | implemented + tested |
| Unified `cad.document` routing + schema | implemented; App tests cover native routing |
| Native proposal persistence/recovery/origin notification | implemented + tested (relaunch replay, crash-after-commit, crash-before-commit, corrupt/newer-schema, saturation, pruning) |
| Production creation + Canvas create-node/import route | implemented + tested end-to-end (create → edit → save → reopen) |
| Workbench + imported-editor localization (en/zh-Hans) | implemented (~380 keys); a full visual zh pass remains CUA |
| CUA acceptance | **in progress**: chrome/toolstrip/panels/history verified in fixture; second confirmation pass pending on the repaired product |
| Physical-device / real-provider acceptance, viewport first-paint & frame latency, compact-phone panel reachability | **not run** — primary/physical-device gates; honest limitations, not claimed |

### 中文摘要（2026-10-10 第三部分，未发布）

本轮关闭评审加固的持久化/恢复契约：原生提案与回执经版本化信封落盘（损坏/更高版本状态只拒绝
不覆盖、可隔离取证；活跃记录永不丢弃、饱和明确报错；写入不阻塞调用方线程），应用回执复用共享
预写日志，采纳/拒绝/人工冲突/中断结果经共享持久 outbox 幂等送达原会话；恢复只依据包存储的已验证
身份（manifest＋文档＋全部 blob），绝不用目录哈希，中断未验证一律记为 interrupted（不冒充已应用、
不暗示可安全重试）。生产入口补齐：文件树“新建 CAD 文档”真实建包；画布 Add 菜单新增显式
“CAD 模型（参数化工作台）”并与 3D 场景编辑器明确区分；工作台“添加到画布”为显式目标选择。
本地化覆盖命令目录、特征/历史标签、材料、捕捉、状态与面板报告（约 380 个双语键）。按 CUA 修复
工具面板：满宽、44pt 目标、结构化报表与空状态、可读错误、显式关闭；生产宿主与夹具共用同一
Floe 级保存/全屏外壳。脚本 apply 强制校验记录的 `outputDocumentRevision`；IGES 混合根（实体＋
曲面）同文件导入有测试。性能基线为可复现合成夹具的首测数值（非提升宣称）。已运行：App 定向
21/21、包内 48/48、iPad 宿主 UI 1/1、iPhone 紧凑通过并记录 1 项跳过（窄栏溢出隐藏工具入口，
移交 CUA 清单）、模拟器与通用设备完整编译均成功（设备产物未签名，已留存来源/哈希/工具链）。
真机、真实模型、视口首帧/帧延迟与紧凑机型面板可达性仍未验收，不在本轮宣称。

## Native FloeCAD continuation — unreleased work, 2026-10-10 (part 4: manual workflows, rank DOF, canvas-owned documents, compact controls)

Status: **implemented and locally verified; not merged, not tagged, not
published.** Branch `codex/content-upgrade-20261009`. The earlier matrices in
this page (parts 1–3) are HISTORICAL checkpoints; the matrix below is the
current one.

### What was added

- **Rank-based assembly DOF, honest failure semantics.**
  `CADAssemblySolver.degreesOfFreedom` builds the linearized screw rows of the
  unsuppressed constraints at the current configuration (fixed 6, coaxial 4,
  planarAlign 3, distance 1, angle 1), normalizes each row, and takes the
  numerical rank (Gauss–Jordan + nullspace). Reported: total mobility, the
  parts-vs-parts relative DOF, the 6 global rigid modes that only a `fixed`
  constraint can remove, per-instance projection dimensions, and
  `fullyConstrained` (TRUE only when grounded with zero mobility — a
  free-floating assembly is never claimed constrained). Duplicate constraints
  add no rank and are listed as `redundantConstraints`; the old weight-heuristic
  (which double-counted and could claim 0 with duplicates) is gone.
- **Failed solves no longer mutate.** `solve` and `sourceUpdate(apply:true)`
  return `ok:false / error:constraint_failed / mutated:false` with conflict and
  invalid-reference ids plus the uncommitted candidate as `previewInstances`;
  the persisted assembly, document revision and undo stack stay untouched.
- **Assembly panel is a real manual workflow.** `CADAssemblyPanelView`: an
  explicit source-body picker (the viewport selection is only a PRESELECTION —
  there is no implicit first body), name/position/Euler-rotation/uniform-scale
  fields and an independent-copy toggle; per-instance edit/hide/show/delete;
  constraint creation for fixed/coaxial/planarAlign/distance/angle with named
  axis presets, reference points, numeric validation (distance ≥ 0, angle
  0–180), and per-constraint suppress/enable/remove. Instance rows select the
  instance in the viewport.
- **Assembly instances now RENDER in the main viewport.** `EditorViewModel.scene`
  appends one `BodyDrawable` per visible instance: it references the shared
  source body's mesh (CoW — the document still has one body), composes the
  instance transform with the source placement via `CADTransform.placement3D()`
  (the same placement function the solver uses), honors per-instance hide and
  selection highlight, and refreshes for solve/setTransform/hide/delete/undo
  and reopen because the scene reads `assemblyData` through the change counter.
  Viewport taps and double-taps on an instance select the INSTANCE
  (`EditorViewModel.selectedAssemblyInstances`), not the underlying body.
- **Drawing panel with a real vector preview and full page editing.**
  `CADDrawingPanelView` renders the projected entities of `pageGeometry`
  (lines/circles/arcs/polylines, dimensions as text) in a SwiftUI Canvas —
  never a screenshot; add/edit/delete pages through `CADDrawingService` with
  kind, source bodies (≤ 12, explicit checklist), scale, paper incl. custom
  size, view normal/up, section plane, detail window, title, part numbers and
  centerline/dimension toggles; PDF/SVG/DXF export uses exactly that page.
- **ShapeScript and mesh panels show TRANSIENT result geometry before apply.**
  `CADTransientMeshPreview` builds a bounded, order-independent-hashed snapshot
  of the result mesh; `CADTransientPreviewView` draws it (isometric,
  depth-sorted) in the panel. Script `preview` and mesh
  `combine/boolean/repair/simplify` with `preview:true` compute the result on
  their own copies and return the snapshot + `previewHash` +
  `previewRevision`/`previewChangeCount` WITHOUT touching the document; the
  following apply passes those values back (`expectedPreviewHash`,
  `expectedRevision`, `expectedChangeCount`) and is refused with
  `preview_stale` when the inputs moved — no no-op previews, no unseen
  commits. Script records get explicit selection, editable parameters,
  conflict choice (auto/fork/rebuild), save/remove, and the apply flow persists
  editor edits before applying the selected record.
- **Mesh panel explicit targets + parameters.** Body checklist (plus “use
  viewport selection”), boolean op + explicit target/tools, combine, transform
  (translate/axis-angle/scale), recompute normals, repair tolerance, simplify
  ratio, boundary check, material colour/opacity and image texture from the
  document's inserted images, and an explicit “allow destructive mesh edits
  (drops B-rep)” acknowledgement — destructive ops never silently downgrade.
- **Canvas-owned native CAD documents (production creation dead-end fixed).**
  `CanvasCADStorage` owns the app-side `Application Support/FloeAgent/CanvasCAD/
  <canvasID>/<package>.floecad` container: creation no longer requires a local
  file workspace or an open chat task, never uses a temp directory. Node
  bindings are `canvas-cad:<canvasUUID>/<file>` keys with traversal/containment
  checks. A failed creation persists a PENDING record, so retry REBINDS the
  same document instead of creating orphans; duplicate forks the package so the
  copy is independently editable; deleting a canvas prunes its container;
  missing packages are reported (not silently recreated). Tapping a canvas CAD
  node opens the full-screen workbench bound to the same bridge session.
- **Compact iPhone controls.** The compact editor no longer relies on the
  navigation bar's automatic overflow (which collapsed whole groups into an
  untappable “…” on iPhone): an in-content 44pt strip carries undo/redo, the
  CAD tools entry (direct, `CADWorkbenchToolsButton`) and an explicit
  `CADCompactMoreMenu` with fit/views/display/isolate/section, history,
  variables, items, import/export, canvas actions, command search and settings.
  The iPhone UI test now PASSES (no skip).
- **Typed string formatting.** `FloeCADStrings.format` understands `%@` and
  printf specifiers (`%lld`, `%d`, `%.2f`, `%%`, …) left to right; the export
  byte-count call no longer leaks a raw token, and missing arguments keep the
  specifier verbatim instead of trapping.
- **Canvas preview is a VIEWPORT render, not a drawing page (production fix).**
  A brand-new blank CAD document can now be created from an ordinary Canvas:
  the node preview comes from the offscreen viewport (`bodies + assembly
  instances + grid`), independent of engineering drawings; when a device
  cannot render (no Metal) an explicit placeholder PNG is used and the node
  metadata records `"preview":"placeholder"` (distinguishable from a real
  `"viewport"` preview). The preview pipeline also REFUSES to publish against
  an uncommitted draft: `save()` must succeed first (`save_failed` otherwise),
  and the node records the verified save's revision + package SHA-256.
- **Canvas ZIP backup carries the EDITABLE package (not only the PNG).**
  `CanvasBackupPackage` gains a `nativeCADPackages` manifest section: every
  regular file of every `<CanvasCAD>/<canvasID>/<name>.floecad` bundle is
  streamed (size + SHA-256) into the archive with ownership-directory
  containment (symlinked/escaping packages refuse the export, a bound but
  absent package is reported). Restore verifies every payload before writing,
  bounds package/file counts, rejects duplicate package identities and
  duplicate normalized destination paths, validates the `.floecad` suffix and
  containment, commits with full rollback, and rewrites node bindings to the
  RESTORED canvas identity — carried packages point at the restored bytes, and
  MISSING ones are rebound into the new namespace so a restored canvas can
  never read the original canvas's live document. Backups predating the field
  decode/restore unchanged. Tests: workspace transport/guard suite (8 cases,
  including legacy compatibility) plus an app-level end-to-end test that
  exports, deletes the source, imports and REOPENS the package with its body
  geometry intact.
- **Panel defaults + localization follow-ups (CUA 2026-10-10).** The
  ShapeScript default source is a valid, previewable `cube { size 10 }` (the
  old `# …` comment prefix failed to parse); a new drawing page starts at
  scale 1 (it used to display 0 and disable Save); drawing kind labels,
  projected-entity count badges, the “selected” instance badge, the script
  conflict picker and the canvas apply/variant/working labels are now
  localized (en + zh-Hans, ~150 new keys in total for this round).
- **Viewport render baseline instrumentation.**
  `CADPerformanceBaselineTests.testViewportFirstPaintFrameAndMemoryBaseline`
  attaches the real coordinator/renderer, renders the scene (48 bodies + 2
  assembly instances) offscreen and reports first paint / average / worst
  frame and resident memory. These are SIMULATOR first measurements — not
  improvements and not physical-device frame times.

### Verification actually run (2026-10-10, part 4)

| Check | Command (retained logs under `Local/evidence/cad-part4/`) | Result |
| --- | --- | --- |
| FloeCADKit full suite | `xcodebuild test -scheme FloeCADKit` (Xcode 27A266a, iOS 27 sim) | **62/62 passed** (assembly 12 incl. rank DOF/duplicate/no-mutation/sourceUpdate refusal, preview binding + panel defaults + strings 10, assembly render 3, drawing 8, script+mesh 10, IGES 6, proposal 6, store 4, viewport 2, perf 3) |
| Workspace backup suite | `swift test --filter "NativeCADBackupTests|CanvasBackupPackageTests"` (internal scratch) | **27/27 passed** (native package round trip, missing/corrupt/duplicate rejection with zero changes, missing-package rebinding, legacy manifest compatibility) |
| App canvas tests | `… -only-testing:FloeAppTests/NativeCADCanvasCreationTests …CanvasBackupTests` | **3/3 passed** (blank canvas creation without workspace or drawing page; failed-save refusal keeps the draft; export→delete→import→REOPEN with body geometry under the restored identity) |
| App focused | `… -only-testing:FloeAppTests/NativeCADProposalPersistenceTests …Authority …Creation …WorkbenchTests` | **21/21 passed** |
| Host UI smoke (iPad regular) | `… CADWorkbenchHostIPadUITests` | **1/1 passed** |
| Host UI smoke (iPhone compact) | `… CADWorkbenchHostIPhoneUITests` | **1/1 passed — NO skip** (compact strip exposed; overflow menu listed its actions) |
| Full App test build | `xcodebuild build-for-testing …` | **TEST BUILD SUCCEEDED** |
| Full App build (simulator) | `xcodebuild build …` | **BUILD SUCCEEDED** |
| Viewport baseline (simulator) | perf test log | firstPaint 25.6 ms, avg frame 9.5 ms, worst 25.6 ms, RSS 817→826 MB (49 bodies incl. 2 instances) |
| CUA fixture | `xcrun simctl launch <iPad> org.floeagent.ios -ui-testing --ui-test-cad-fixture` | fixture now carries TWO separated instances (Plate A at origin, Plate B at x=140) for the primary pass |
| Final device artifact (unsigned) | `xcodebuild build … -destination 'generic/platform=iOS' … CODE_SIGNING_ALLOWED=NO` from commit `3a7a03c9` (clean tree) | **BUILD SUCCEEDED**; binary SHA-256 `d5ee1b9b…dd397c`, dSYM DWARF SHA-256 `b07edd15…3eed9`, UUIDs match (`56596D9C-A192-3C6F-9CEC-847A28258EAF`); artifact + provenance under `Local/evidence/cad-part4/device-artifact-3a7a03c9/` |

### Current completion matrix (2026-10-10, part 4) — supersedes earlier tables

| Area | State |
| --- | --- |
| Versioned `.floecad` kernel, atomic commit, CAS, undo/redo, off-main save | implemented + tested |
| Sketch/parametric features, analytic B-rep, STEP/IGES import | implemented + tested |
| Assembly service: instances, constraints, rank-based DOF, interference, source update | implemented + tested (failed solve/apply preserve the stored model) |
| Assembly MANUAL workflow: explicit place, transform/hide/delete, constraint create/suppress/remove, viewport instancing + instance selection | implemented + tested (deterministic scene tests; fixture for CUA) |
| Drawings: vector page preview, page/view/title/frame/section/detail/part-number editing, PDF/SVG/DXF of the visible page | implemented + tested |
| ShapeScript: record selection/parameters/conflict handling, transient geometry preview bound to apply | implemented + tested |
| Mesh: explicit targets/parameters, transient result preview bound to apply, B-rep downgrade acknowledgement | implemented + tested |
| `FloeCADStrings` typed formatting (%@/%lld/%.2f) | implemented + tested |
| Canvas-owned CAD creation/rebind/duplicate-fork/delete-prune, canvas node editor | implemented + tested; primary CUA confirmed creation now proceeds (viewport preview) |
| Canvas preview = viewport render (drawings independent) + save-outcome guard + placeholder distinguishable | implemented + tested |
| Canvas ZIP backup with editable `.floecad` packages, guarded bounded restore, identity rewrite, legacy compatibility | implemented + tested (workspace 27/27 incl. 8 native-package cases; app end-to-end reopen) |
| Compact iPhone control strip + explicit overflow | implemented; iPhone UI test passes |
| Viewport instancing/perf baseline | implemented; simulator baseline measured (not a device claim) |
| Physical-device acceptance, real configured-provider loop | **not run** — see limitations |
### Honest limitations

- The viewport numbers above are simulator measurements of the CPU/GPU path;
  physical-device frame latency remains a primary/CUA gate.
- A real configured-model-provider loop was NOT run: the app's chat-provider
  credentials live in its protected store and require an interactive session;
  this worker environment has no chat-provider key (only Volc image/search/TTS
  environment keys) and no headless provider entry point. Exact missing
  capability: an interactive app session with the user's configured provider.
- A device without Metal falls back to the explicit placeholder preview
  (recorded as `"preview":"placeholder"`); the simulator/iPad runs used the
  real viewport render (`"viewport"`).
- 中文界面（zh-Hans 目录值）随本轮新增键补齐，最终视觉中文验收仍属 CUA。

### 中文摘要（2026-10-10 第四部分，未发布）

本轮关闭手工工作流与正确性缺口：装配自由度改为基于约束螺旋行秩的真实计算（区分部件间自由度与 6 个
全局刚体自由度，重复约束只计一次并列为冗余；仅“已接地且动度为零”才报告完全约束），求解/来源应用
失败时返回结构化诊断与未提交预览、绝不写入模型（修订/撤销不变）。装配面板提供显式来源实体选择
（视口选择仅为预选，不再隐式取第一个实体）、实例变换/隐藏/删除与固定/同轴/平面对齐/距离/角度约束的
创建、编辑、抑制与删除；装配实例现按共享源网格＋各自变换真实渲染于主视口，支持隐藏、选中高亮与
点选实例，求解/修改/撤销/重开即时更新。图纸面板新增真实矢量页面预览与页面/视图/标题/剖面/详图/
零件号编辑，导出即所见页面；ShapeScript 与网格操作在应用前用临时副本生成真实结果几何（哈希＋版本
绑定，输入变动即拒绝 preview_stale，不产生无效果预览）。画布自有 CAD 文档存储落地（无需聊天或本地
工作区、失败保留待重建记录、重试重绑同一文档、复制画布分叉包、删除画布清理、路径包含校验），
画布节点可直接打开工作台。iPhone 紧凑布局改为内容内 44pt 控制条＋显式溢出菜单，跳过项已消除。
`FloeCADStrings.format` 支持 %@/%lld/%.2f 等类型化占位符。随后按 CUA 第二轮修复：画布节点预览改为视口离屏渲染（与工程图纸无关，空白新文档可直接在普通画布
创建；无 Metal 时使用可区分的占位图并在节点元数据标注），预览前必须保存成功（失败/冲突拒绝发布，
记录已验证保存的修订与包哈希）；画布 ZIP 备份现完整携带可编辑 .floecad 包（清单、逐文件哈希、
有界恢复、重复/缺失/损坏拒绝且零改动、恢复后重写为新区身份、旧备份兼容），并有真实导出→删除→
导入→重开几何体的端到端测试。ShapeScript 默认脚本改为可预览的 cube、图纸新页默认比例 1、绘图
类型/计数/选中徽标等中文标签补齐。已运行：包内 62/62、工作区备份 27/27、App 画布 3/3、App 定向
21/21、iPad UI 1/1、iPhone 紧凑 1/1（无跳过）、视口基线为模拟器首测值。未竟：真实模型 provider
回路（需交互式配置，工作机无凭据入口）、真机验收。

## Native FloeCAD continuation — unreleased work, 2026-10-10 (part 5: canvas node presentation, explicit edit entry, thumbnail isolation, localized title)

Follow-up to primary CUA on the part-4 build. Four concrete, user-visible defects found after
"Apply to canvas"; all addressed in the same worktree, no parallel media subsystem, source
geometry/binding contract unchanged.

### What changed

1. **Real viewport thumbnail on the canvas node (was: generic document icon labelled `image/png`,
   header 产物/导入, title "CAD Model").** A native CAD node now renders through a dedicated
   `CanvasNativeCADNodeContent` (FloeApp): the live asset (the workbench viewport render in the
   material library) is shown through the SAME path-guarded resolver and bounded
   `CanvasImageThumbnailCache` every image node uses. An explicit "Editable CAD · .floecad"
   capsule badge identifies the editable package as the original — the PNG is only its render,
   never presented as the source. A missing/unreadable render shows an explicit cube +
   "CAD viewport preview unavailable" placeholder (still double-tap opens the package), not a
   blank/generic file glyph. The Metal-unavailable fallback placeholder
   (`CADCanvasPreview.placeholderPNG`) now draws an explicit wireframe cube + CAD label instead
   of an empty grey rectangle.
2. **Explicit "Open CAD workbench / 打开 CAD 工作台" action; rename is separate.** The node's
   primary edit action was inline rename only. Three contextual surfaces now expose the workbench
   entry through the SAME binding route as double tap (`openNativeCADEditor` →
   `CanvasNativeCADEditor`, resolving the `canvas-cad:` key with containment guards): the
   long-press node context menu, the selected-node bottom contextual toolbar
   (`canvas.toolbar.openNativeCAD`), and the compact iPhone pencil menu
   (`canvas.pencil.openNativeCAD`). A distinct "Rename / 重命名" pencil action keeps the old
   inline-rename behaviour. Locked nodes keep their lock semantics; non-CAD nodes are unchanged.
3. **Thumbnail capture no longer touches the live viewport (the "cube fills viewport, Top/Front/
   Right labels vanish" defect).** `FloeCADDocument.viewportThumbnailPNG` used to build a SECOND
   `ViewportCoordinator` on the shared cached `EditorViewModel`; attach installed that transient
   coordinator as the view model's `cameraControl`, overwrote its thumbnail/screenshot providers,
   and fitted its own camera. It now renders with a DETACHED `Renderer` over a one-shot value-type
   copy of `viewModel.scene`, fitted by a LOCAL camera
   (`Renderer.makeSceneSnapshotPNG` + a scene/camera-parameterized offscreen encode path). The live
   renderer's camera, MTKView delegate, viewport-size callback, orientation cube, selection and
   mode are never observed or mutated. A new focused test class asserts camera/delegate/
   cameraControl/selection/mode are bit-identical before/after single and repeated captures, that
   cube vs empty scenes render different bytes, and that the cube PNG contains real shaded
   geometry (non-background pixel coverage), not a blank pass.
4. **Localized default node title; identity stays stable.** New-canvas CAD nodes titled "CAD
   Model" in a Chinese UI now use `CADCanvasNodePlanner.defaultDisplayName()` ("CAD Model" /
   "CAD 模型", catalog key `canvas.cad.node_default_name`). Presentation only: the on-disk package
   file name and the `canvas-cad:<canvas>/<package>` binding key keep the stable English stem, so a
   device-language switch cannot break the binding.

DEBUG-only test support: `--ui-test-canvas-cad-fixture` builds an ordinary canvas with one
canvas-owned CAD node through the production bridge and presents the real `WorkspaceCanvasView`
with the node selected, so the contextual "Open CAD workbench" entry is asserted end-to-end
(opens the full-screen real workbench; Done returns to the node). No release code path creates
the fixture.

### Verification actually run (2026-10-10, part 5)

- FloeCADKit build: `xcodebuild build -scheme FloeCADKit -destination generic/platform=iOS
  Simulator` — succeeded (incremental, DerivedData `…/DerivedData/pkg`, Xcode 27.0 27A266a).
- Package focused tests, iPad Air 13-inch (M4) simulator: `CADThumbnailIsolationTests` 3/3,
  `ViewportRenderTests` 2/2, `CADPreviewBindingTests` 7/7 — 12/12 passed, 0 failures
  (`…/logs/accept-part5-thumb-tests*.log`; original failing compiles retained).
- Full App `build-for-testing` (FloeAgent scheme, generic iOS Simulator) — TEST BUILD SUCCEEDED,
  0 errors.
- App canvas creation tests `NativeCADCanvasCreationTests` — 3/3 passed, incl. localized node
  title vs stable `CAD Model*.floecad` package identity (`accept-part5-app-creation-tests2.log`).
- UI: `FloeAgentUITests/CanvasCADEntryUITests` — 1/1 passed (21.0 s): the selected CAD node card
  carries the editable `.floecad` identity on its parent `canvas.node.<uuid>` label, the bottom
  contextual "Open CAD workbench" action (`canvas.toolbar.openNativeCAD`) opens the real workbench
  (`canvas.nativeCAD.done`, `CADWorkbenchToolsButton`), and Done returns to the canvas
  (`accept-part5-canvas-ui-final.log`).
- Independent generic/iOS device build at HEAD `3f91efba` (app source `be0077ea`, the follow-up
  commit is test-only): BUILD SUCCEEDED. Unsigned Debug product 1.7.24 (265), binary sha256
  `3a0a6a97c633daa283a6d78d8ca2629d060a3a86233d65f61b759e2118743e8e`, dwarf UUID
  `13D9E972-2862-39C9-9F78-76F44EA1DB47` (binary == extracted dSYM, verified). Recovery artifact:
  `Local/evidence/cad-part5/device-artifact-3f91efba.tar.zst` (sha256
  `a0d285a5a5af0e0d71f61836053cd8d1a72d111d7a892490fedc74bd5d93ff6b`, packaged binary hash
  verified equal to the build). Compile gate only; the unsigned product is not installable as-is.
- Primary native Device Hub CUA on the simulator product (binary `0f9a579e…`, same app source):
  confirmed the parent node AX label reads as an editable `.floecad` model, the bottom action opens
  the bound editor, ShapeScript cube preview/Apply renders the real cube, and Fit → Apply to
  Canvas → dismiss tools PRESERVES exact framing and the Top/Front/Right orientation labels; the
  card then shows the actual cube thumbnail + editable `.floecad` badge, and reopening via the
  bottom action retains the cube. Screenshots:
  `Local/Private/cad-upgrade-20261009/cua/final-before-canvas-apply.png`,
  `final-after-canvas-apply.png`, `final-cad-canvas-card.png`.

### Observation (not a persistent defect)

- On the first Done transition out of the freshly opened editor the view briefly showed a zoomed
  cube and needed a second tap; every subsequent reopen/Done returned normally. Recorded for the
  CUA history; no source change was warranted from a single non-reproducing transition.

### Honest limitations (part 5)

- The package and App builds/tests above are simulator runs; the device slice is an unsigned
  compile gate (physical-device install/acceptance remains a primary/user gate).
- A real configured-model-provider loop was NOT run (interactive credentials unavailable to this
  worker; Apple Foundation Models unavailable / model downloading in the simulator).

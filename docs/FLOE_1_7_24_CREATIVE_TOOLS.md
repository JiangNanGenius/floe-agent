<!-- docs-updated: 2026-10-09 -->
# Floe 1.7.24 (265) creative tool contracts and format capability table

Status (2026-10-08): implementation merged into `main`; immutable tag `v1.7.24`
pins `246d6c038f0a3f7ec7d7d9f7e19d074f13601bec`; version fields read 1.7.24 (265).
The exact local Xcode 27A266a / iphoneos27.0 Release device artifact was signed
and uploaded without an App rebuild ([run
37763059515](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515));
Apple reports VALID, unexpired and the existing internal Floe QA group
IN_BETA_TESTING. Build 265 was submitted to the existing external publictest1
group on 2026-10-08 and is waiting for review; independent readback is recorded
in [CURRENT_STATUS](CURRENT_STATUS.md). This document describes what the code
actually implements, the tests that ran, and what still needs a physical device /
real model. Where this page and an earlier candidate note disagree, the dated
sections here are current and the older note is historical evidence, not a
promise.

状态（2026-10-08）：实现已合并 `main`；不可变标签 `v1.7.24` 固定
`246d6c038f0a3f7ec7d7d9f7e19d074f13601bec`；版本号为 1.7.24（265）。本地
Xcode 27A266a / iphoneos27.0 Release 设备产物已在不重新编译 App 的情况下完成签名上传
（[运行 37763059515](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515)）；
Apple 显示 VALID、未过期，现有内部 Floe QA 组为 IN_BETA_TESTING。Build 265 已于
2026-10-08 提交至现有外部 publictest1 组，正在等待审核；独立回读记录见
[CURRENT_STATUS](CURRENT_STATUS.md)。本页描述代码实际实现的能力、已执行的测试，
以及仍需真机／真实模型的部分。若本页与早期候选说明冲突，以本页带日期的小节为准，
旧说明仅作历史证据，不是承诺。

## 1. Evidence vocabulary / 证据分级

Every capability below is labelled the same way the tools report it at runtime:

| Tier | Meaning |
| --- | --- |
| **verified / implemented** | Implemented in the module and covered by focused tests that ran locally. |
| **engine** | Implemented and reachable through the packaged native Collabora engine (encoded against the pinned bundle, validated before dispatch, post-save reopen-verified), and structurally/bridge tested locally, but **not yet covered by a physical-device qualification receipt**. This is an on-device *acceptance* gate, **not** a runtime "unavailable" signal: the app does not disable these commands for lack of a receipt. It only means release material must not call them device-accepted. |
| **delegated** | Performed by an existing workspace tool on a staged copy; the Notes original is never modified in place. |
| **unavailable** | The pinned engine/format has **no faithful implementation path at runtime** (for example there is no `.uno:ChangePicture` in the bundled engine). The UI/tool genuinely omits or disables it with a reason; it is never faked with a screenshot, overlay or PDF edit. This is different from an implemented-but-device-unverified **engine** command. |
| **CUA pending** | Implemented and locally built/tested, but the real rendered-page / touch interaction is primary-reviewer (CUA) acceptance. |

**Device-unverified is not runtime-unavailable.** Engine-tier operations are live
commands; whether the running app offers them is decided by actual runtime probes
(format/engine presence), independent of whether the release folder already has a
physical-device receipt. Keep the two questions separate: *can this build perform
it on this file?* (runtime) versus *has the operation been accepted on physical
hardware for release?* (qualification). Section 5.3 lists the actual runtime
checks and the remaining on-device limitation.

| 级别 | 含义 |
| --- | --- |
| **verified / implemented（已验证）** | 模块内已实现，并由本地实际运行的定向测试覆盖。 |
| **engine（引擎层）** | 已实现并可通过内置原生 Collabora 引擎执行（按固定版本引擎编码、派发前校验、保存后重开校验），且本地做了结构/桥接测试，但**尚无真机资格回执**。这是设备*验收*门槛，**不是**运行时“不可用”信号：应用不会因为缺少回执而禁用这些命令；只表示发布材料不能称其已被真机接受。 |
| **delegated（委托）** | 由既有工作区工具在暂存副本上完成，手记原件绝不原地修改。 |
| **unavailable（不支持）** | 固定引擎/格式在运行时**没有忠实实现路径**（如内置引擎没有 `.uno:ChangePicture`）。界面/工具确实不提供或带原因禁用，绝不用截图、浮层或 PDF 编辑冒充。它与“已实现但未经真机验证”的 **engine** 命令是两回事。 |
| **CUA pending（待界面验收）** | 已实现并本地构建/测试，但真实渲染页面/触控交互由主审（CUA）验收。 |

**“未经真机验证”不等于“运行时不可用”。** 引擎层操作是可执行的真实命令；运行中的应用
是否提供，由真实运行时探测（格式/引擎是否在场）决定，与发布文件夹是否已有真机回执无关。
请把两个问题分开：*此构建能否在此文件上执行？*（运行时）与*该操作是否已在真机上被接受、
可用于发布？*（资格）。5.3 节列出实际运行时检查与仍存在的真机限制。

## 2. Shared explicit-effect AI contract / 共享“显式生效”AI 契约

The creative tools `cad.document`, `document.office.edit`, `media.project` and
the Notes tools share one workflow. The model can discover, read, draft and
verify, but only the interactive UI can authorise a mutation.

创作类工具 `cad.document`、`document.office.edit`、`media.project` 与手记工具共用同一
流程：模型可以发现、读取、起草和校验，但只有交互界面能授权修改。

1. **Capabilities / 发现能力** — call the format/engine-specific `capabilities`
   action. The answer is dynamic per format, engine presence, configuration and
   permission; it is never a hard-coded promise. 调用按格式/引擎动态返回的
   `capabilities`，不写死承诺。
2. **Read / query / 读取** — paginated structured reads bound to an explicit
   owner, environment, workspace/task, target and revision. 分页结构化读取，绑定
   明确归属、环境、工作区/任务、目标与修订。
3. **Propose / preview / 提案与预览** — validate a typed draft against the exact
   SHA-256/revision and return a diff/add-changed-deleted preview. Nothing is
   written; a screenshot is never evidence. 按精确 SHA-256/修订校验类型化草稿，返回
   差异/新增-修改-删除预览，不写文件，截图不算证据。
4. **Confirm / 确认** — the user accepts in the editor, which mints a single-use,
   expiring, revision-bound grant. The model cannot mint or guess it. 用户在编辑器
   接受后由界面签发一次性、有时效、绑定修订的授权；模型不能自行生成或猜测。
5. **Apply / 应用** — re-checks target + revision/SHA + selection fingerprint,
   performs one atomic undoable transaction, uses compare-and-swap, and is
   idempotent per operation/request id (a repeated identical authorised call
   returns the original receipt; a different payload under the same id
   conflicts). 复核目标＋修订/SHA＋选区指纹，执行单一原子可撤销事务，比较并交换，
   按操作/请求幂等（同一授权调用重复返回原回执；同 id 不同载荷报冲突）。
6. **Save/export/verify / 保存导出校验** — reopens the SAVED bytes/package and
   verifies a target-aware delta or a fresh same-engine reparse before reporting
   success. Tool receipts distinguish `queued`, `running`, `needsConfirmation`,
   `failed`, `saved`, `exported`. 重新打开已保存字节/包并校验定向差异或同引擎重新
   解析后才报成功；回执区分排队/运行中/待确认/失败/已保存/已导出。

Draft versus applied, modify versus variant / 草稿与已应用、修改与变体：editing the
bound project changes the current draft; a fork (`parent_project_id`) or a new
proposal is an explicit variant. Candidates/proposals stay owned by the
originating request and project and are never auto-placed. Long jobs are durable;
an unknown submission is never automatically re-issued. 编辑绑定工程改变当前草稿；
分叉（`parent_project_id`）或新提案才是显式变体。候选/提案归属于原始请求与工程，绝不
自动摆放；长任务持久化，结果未知的提交绝不自动重发。

## 3. `cad.document` — 2D DWG/DXF / 二维图纸

> **2026-10-09:** a native `.floecad` 3D workbench (parametric history,
> exact B-rep, AI propose/apply) exists unreleased on
> `codex/content-upgrade-20261009`; its honest state and open items are in
> [FLOE_CAD_AND_DRAWING_ASSISTANT.md](FLOE_CAD_AND_DRAWING_ASSISTANT.md),
> not in the shipped 1.7.24 table below. 原生 `.floecad` 三维工作台尚未发布，
> 真实状态见该文档。

Registration: registered in the app's tool environment. Read-only actions need
document read access; `propose/apply/save/export` need the CAD document grant and
a UI-issued token for `apply`. Source:
`FloeAgent/Sources/FloeWorkbench/CadDocumentTool.swift`, host
`FloeAgent/FloeApp/Workspace/CadDocumentCenter.swift`, engine
`FloeAgent/ThirdParty/CADEngine` (MPL-2.0 binding over acadrust 0.5.5, compiled to
WASM, 384 MiB linear-memory cap). 注册于应用工具环境；只读动作需文档读权限，
propose/apply/save/export 需 CAD 文档授权，apply 另需界面签发令牌。

### 3.1 Actions / 动作

| Action | Effect |
| --- | --- |
| `capabilities` | engine-declared surface; no document required. |
| `read` | document structure and current revision/SHA. |
| `query` | `kind=entities|text|layers|drawing|snap`; entities/text paginate (`limit` 1–500, `offset`), filter by `layer`, `entity_type` (Line/Circle/Arc/LwPolyline/Text) or `text`; `snap` needs one finite `points` row. |
| `locate` | exactly one `handles` entry → highlight in the live viewer (CUA surface). |
| `measure` | `distance`: 2 points or 2 handles; `angle`: 3 points or 2 line handles; `radius`: 1 circle/arc handle; `perimeter`: 1+ handles; `area`: 1 closed entity or 3+ points. |
| `check` | zero-length, exact duplicates, layer usage, open contours at a stated `tolerance` — drawing hygiene, not engineering certification. |
| `propose` | validates a typed batch (≤64 ops) on a throwaway session, returns new/changed/deleted preview; never writes. |
| `preview` | fetch a stored proposal (`proposal_id`). |
| `apply` | consumes a single-use UI `grant_id`; one atomic undoable transaction, SHA compare-and-swap, idempotent replay. |
| `save` | commits full DWG/DXF serialization after a fresh same-engine reparse. |
| `export` | writes a separate verified DXF drawing copy; source unchanged. PDF/PNG previews are separate presentation formats. |

| 动作 | 作用 |
| --- | --- |
| `capabilities` | 引擎声明的能力面，无需文档。 |
| `read` | 文档结构与当前修订/SHA。 |
| `query` | `kind=entities|text|layers|drawing|snap`；entities/text 分页（`limit` 1–500），可按图层/图元类型/文字过滤；`snap` 需一个有限坐标点。 |
| `locate` | 仅一个 `handles`，在实时查看器中高亮（界面能力）。 |
| `measure` | 距离需 2 点或 2 个对象；角度需 3 点或 2 条线；半径需 1 个圆/圆弧；周长需至少 1 个对象；面积需 1 个闭合对象或至少 3 点。 |
| `check` | 零长度、完全重复、图层使用、给定容差下开放轮廓——图纸卫生检查，非工程认证。 |
| `propose` | 在校验会话上验证类型化批次（≤64 操作），返回新增/修改/删除预览，不写入。 |
| `preview` | 读取已存提案。 |
| `apply` | 消耗一次性界面 `grant_id`，单一原子可撤销事务，SHA 比较并交换，幂等重放。 |
| `save` | 同引擎重新解析通过后提交完整 DWG/DXF 序列化。 |
| `export` | 另存已校验的 DXF 图纸副本，源文件不变；PDF/PNG 展示副本另行处理。 |

Operations (typed, anything else is refused before reaching the engine):
`addLine`, `addCircle`, `addArc`, `addLwPolyline` (closed 4-point = rectangle),
`addText`, `addLeader`, `addDimension` (linear/aligned/angular/radius/diameter),
`move`, `copy`, `rotate`, `scale` (uniform), `mirror`, `setText`, `setRadius`,
`setLayer`, `setColor`, `setLineWeight`, `delete`, `trim`, `extend`, `offset`,
`addLayer`, `updateLayer`, `renameLayer`, `deleteLayer`, `batch`. Coordinates are
Z=0 drawing units. 类型化操作，未列出的会在到达引擎前被拒绝；坐标为 Z=0 图纸单位。

Point and delta vectors use `[x,y]` or `[x,y,0]`; validated `{x,y}`/`{dx,dy}`
aliases are accepted. Non-default Z coordinates are refused, not projected.
For example, move uses `{"operation":"move","handle":"<current handle>","delta":[1,0,0]}`.
点与位移使用 `[x,y]` 或 `[x,y,0]`，也接受经过校验的对象别名；非默认 Z 坐标
会被拒绝，不会静默投影。对象句柄必须从当前修订重新查询。

### 3.2 Examples / 示例

Discover and read / 发现与读取：
```json
{"action":"capabilities"}
{"action":"read","path":"plates/base.dwg"}
{"action":"query","path":"plates/base.dwg","kind":"entities","entity_type":"Circle","limit":100,"offset":0}
{"action":"query","path":"plates/base.dwg","kind":"snap","points":[[120.5,8.0]],"tolerance":1.5}
{"action":"measure","path":"plates/base.dwg","kind":"distance","points":[[0,0],[100,0]]}
```

Propose → user confirms in the CAD UI → apply → verify / 提案→界面确认→应用→校验：
```json
{"action":"propose","path":"plates/base.dwg","expected_sha256":"<64 hex from read>",
 "summary":"add bolt circle and a radius dimension",
 "operations":[
   {"operation":"addLayer","name":"DIM","color":"3"},
   {"operation":"addCircle","center":[120,40,0],"radius":12,"layer":"0"},
   {"operation":"addDimension","kind":"radius","points":[[120,40,0],[132,40,0]],"layer":"DIM"}]}
```
```json
{"action":"preview","path":"plates/base.dwg","proposal_id":"<uuid>"}
{"action":"apply","path":"plates/base.dwg","proposal_id":"<uuid>","grant_id":"<UI-issued>"}
{"action":"save","path":"plates/base.dwg"}
{"action":"export","path":"plates/base.dwg","output":"exports/base-review.dxf"}
```

### 3.3 CAD format capability table / CAD 格式能力表（真实）

| Subject | Support (tier) | Evidence / limit |
| --- | --- | --- |
| Editable geometry | line, circle, arc, open/closed LWPolyline, single-line text (implemented + engine/JS tests) | `cargo test` 42/42; `test_cad_commands.mjs` 58/58 |
| Modify | move/copy/rotate/uniform scale/mirror/delete, setText/setRadius/setLayer/setColor/setLineWeight | same suites; real WKWebView bridge 2/2 on iPad simulator |
| Trim/extend/offset | trim/extend coplanar line/arc/polysegments against a boundary; offset line/circle/non-self-intersecting open linear polyline | complex closed/spline offsets are refused, not guessed |
| Layers | create/rename/show/lock/active/ACI colour/line type/canonical weight; move entity to layer; delete only when unreferenced | engine + JS panel tests |
| Dimensions/leaders | linear/aligned/angular/radius/diameter native dimensions and text leaders where the format writes them faithfully | DWG AC1024/27/32 + DXF re-read by LibreDWG |
| Pencil annotation | atomic `addStroke` ink on `FLOE_ANNOTATION`, one undo snapshot, Z preserved | ink contract `test_cad_ink.mjs` 78/78 |
| Space/units | model-space Z=0/+Z edits only; paper space, non-default OCS, raised/3D content read-only, never flattened; undefined `INSUNITS` stays drawing units (mm never assumed) | planar/model-space gate tests |
| Blocks / xrefs / splines / proxy / 3D | retained view/reference; **no explode/edit promise** | INSERT round-trips in DXF; strict DWG gate still rejects the representative block sample |
| Save DWG/DXF (in-app, every save) | the **same** engine re-encodes and then reparses its own output and compares entities/layers/references/units before any overwrite; lossy unsupported data blocks the overwrite | engine save-gate tests; this is the runtime gate that actually runs on save |
| LibreDWG independent reader (release qualification only) | LibreDWG 0.13.3 is run **offline by the build/QA process** on representative generated outputs (DWG AC1024/27/32 + DXF projection via `dxf2dwg`); it is **not** bundled in the app and is **not** run on every save | external cross-reader on representative files; neither universal DWG/DXF support nor a per-file guarantee |
| Unknown/proxy save | **unavailable**: unknown entity/object save fails with `[NotImplemented]` diagnostics; source preserved | honest refusal, not claimed preserved |
| Real-page editor across full-screen | implemented; simulator CUA verified | keep-draft/undo/redo across embedded↔full-screen passed on the iPad simulator (owned CUA); physical-device pass still open |
| CAD-in-Canvas node lifecycle | implemented; **simulator CUA verified** | real add-LINE→keep-draft→close→reopen→Finish, then add-CIRCLE→Finish; same node id/name/position/size, exactly one node; LibreDWG LINE1/CIRCLE2→LINE2/CIRCLE3; original source-file hash unchanged; the node points to the newly adopted asset. Simulator CUA only — physical-device pass still open |

| 主题 | 支持（级别） | 证据／限制 |
| --- | --- | --- |
| 可编辑几何 | 线、圆、圆弧、开放/闭合轻量多段线、单行文字（已实现＋引擎/JS 测试） | cargo 42/42、commands 58/58 |
| 修改 | 移动/复制/旋转/等比缩放/镜像/删除、改文字/半径/图层/颜色/线宽 | 同套件；真机 WKWebView 桥接 iPad 模拟器 2/2 |
| 修剪/延伸/偏移 | 共面线/圆弧/折线按边界修剪延伸；线/圆/非自交开放折线偏移 | 复杂闭合/样条偏移明确拒绝 |
| 图层 | 新建/重命名/显隐/锁定/当前/颜色/线型/线宽，图元换层，仅无引用时可删 | 引擎＋JS 面板测试 |
| 标注/引线 | 线性/对齐/角度/半径/直径原生标注与文字引线（格式可忠实写入时） | DWG AC1024/27/32 与 DXF 经 LibreDWG 复读 |
| 铅笔批注 | `FLOE_ANNOTATION` 上原子 `addStroke`，单撤销快照，保留 Z | ink 契约 78/78 |
| 空间/单位 | 仅模型空间 Z=0/+Z；图纸空间、非默认 OCS、抬升/3D 只读且不展平；未定义单位保持图纸单位（不假设毫米） | 平面/模型空间门测试 |
| 块/外部参照/样条/代理/3D | 保留查看/引用，**不承诺分解/编辑** | INSERT 在 DXF 可往返；严格 DWG 门仍拒绝代表性块样例 |
| DWG/DXF 保存（应用内，每次保存） | **同一**引擎重新编码并重新解析自身输出，在覆盖前比对图元/图层/引用/单位；遇到有损不支持数据会阻止覆盖 | 引擎保存门测试；这是保存时实际运行的运行时门 |
| LibreDWG 独立读取器（仅发布资格） | LibreDWG 0.13.3 由构建/QA 流程**离线**运行在代表性导出上（DWG AC1024/27/32 与经 `dxf2dwg` 的 DXF 投影）；**不随 App 打包，也不在每次保存时运行** | 代表性文件的外部交叉读取，不代表普遍支持所有 DWG/DXF，也不是逐文件保证 |
| 未知/代理内容保存 | **不支持**：未知图元/对象保存报 `[NotImplemented]`，保留源文件 | 诚实拒绝 |
| 全屏真实页面编辑 | 已实现；模拟器 CUA 已验证 | iPad 模拟器内嵌↔全屏保留草稿/撤销重做通过；真机仍待验收 |
| 画布里 CAD 节点生命周期 | 已实现；**模拟器 CUA 已验证** | 真实“加线→保留草稿关闭→重开→完成”，再“加圆→完成”；同一节点 id/名称/位置/尺寸、恰好一个节点；LibreDWG LINE1/CIRCLE2→LINE2/CIRCLE3；原始素材文件哈希不变，节点改为引用新采用的素材。仅模拟器 CUA，真机仍待验收 |

## 4. Drawing Assistant / 图纸助手

The engineering review entry is renamed **图纸助手 / Drawing Assistant**
throughout the UI, prompts and docs (general assistants are not renamed). It is a
durable, per-drawing assistant, not a one-off screenshot-and-question sheet:

工程审阅入口在界面、提示词和文档中统一更名为**图纸助手 / Drawing Assistant**（通用
助手不更名）。它是持久、按图纸绑定的助手，而非一次性“截图＋提问”：

- Binds to a canonical document identity (workspace/root + relative path), not a
  filename or a content prefix; two identically named files in different roots
  stay separate, while saving the same drawing keeps its conversation. 按规范
  文档身份（根＋相对路径）绑定；不同根的同名文件互不串话，保存后仍属同一会话。
- Context is structured and current: units, layers, active layer, selection,
  unsaved revision, missing references; scope is whole drawing / viewport /
  selection. A screenshot is auxiliary only. 上下文结构化且最新：单位、图层、当前
  图层、选区、未保存修订、缺失引用；范围为整图/视口/选区，截图仅辅助。
- Answers reference entity handles; `locate` chips highlight the exact handle in
  the live viewer. Numeric geometry comes from deterministic tools, not image
  guessing. 回答引用图元句柄，定位芯片在实时查看器高亮；几何数值来自确定性工具。
- Proposals show colour-coded new/changed/deleted geometry with counts and
  parameter diff; the user confirms one atomic undoable transaction. Asking or
  previewing never writes. Apply is refused while the live drawing is dirty, and
  the committed change reconciles the live viewer as one external undo. 提案以颜色
  区分新增/修改/删除并给出计数与参数差异，确认后为单一原子可撤销事务；图纸有未保存
  修改时拒绝应用，提交后以一次外部撤销同步实时查看器。
- Adopt/reject/manual-change decisions persist a write-ahead intent before
  mutation and are delivered idempotently to the originating task through the
  runtime input channel; model-authored summary text is never elevated to a
  system instruction. 采纳/拒绝/人工改动在修改前持久化预写意图，并经运行时输入通道
  幂等送回原任务；模型撰写的摘要绝不提升为系统指令。

## 5. Office tools and format table / Office 工具与格式能力表

Tools: `document.office.capabilities` (read-only matrix), `document.office.edit`
(propose/confirm/apply plus verified package operations), and the existing
`document.office.inspect` / `document.office.updateText` / create tools. Sources:
`FloeAgent/Sources/FloeDocuments/OfficeCapabilityTool.swift`,
`OfficeDocumentCommandTool.swift`, `OfficeEngineCommand.swift`,
`OfficeOutputValidation.swift`; app host `FloeApp/Workspace/OfficeCommand*.swift`.

### 5.1 `document.office.edit` schema / 模式

`action` ∈ `capabilities|read|query|propose|preview|apply|export|errors|replaceImage`.
`propose` needs `path`, `expected_sha256` (64 hex, from `read`/inspect) and 1–64
`commands`. `apply` needs `proposal_id` and a UI-issued `grant_id`. `request_id`
is an optional idempotency key (defaults to the tool call id). Command arguments
are string-valued.

| id | arguments | Target | Tier |
| --- | --- | --- | --- |
| `word.style` | `style` ∈ Title/Subtitle/Heading 1–4/Normal/Quote/Caption | live selection (fingerprint) | engine |
| `word.bulletList` / `word.numberedList` | – | live selection | engine |
| `word.alignment` | `alignment` ∈ left/center/right/justified | live selection | engine |
| `word.insertTable` | `rows` 1–100, `columns` 1–20 | cursor | engine |
| `excel.numberFormat` | `format` ∈ standard/decimal/percent/currency/date/time/scientific/thousands/increaseDecimals/decreaseDecimals, `cell` A1 | explicit cell | engine |
| `excel.insertRows`/`deleteRows`/`insertColumns`/`deleteColumns` | `count` 1–100, `cell` A1 | explicit cell | engine |
| `excel.freezePanes` | optional `cell` A1 | cell/current | engine |
| `excel.sort` | `ascending` true/false, optional `range` A1:B9 | live selection/range | engine |
| `excel.autoFilter` | – | live selection | engine |
| `excel.goToCell` | `cell` A1 | explicit cell (non-mutating) | engine |
| `excel.recalculate` | – | workbook (non-mutating) | engine |
| `pptx.duplicateSlide` | `at` 1–500 | slide index | engine |
| `pptx.moveSlide` | `from`,`to` 1–500 distinct | slides | engine |
| `pptx.alignObjects` | `alignment` ∈ left/center/right/top/middle/bottom | live object selection | engine |
| text find/replace | `updateText` with expected SHA | paragraphs / slide fields / cells | verified (OOXML) |
| formula set | cell `<f>` via `updateText` | explicit cell | verified (OOXML) |
| `errors` | reads `t="e"` cells + codes from the saved package | sheet | verified (saved-package read) |
| `replaceImage` | `image` (`ppt/media/image2.png` or `#N`), `imagePath` same-format source | package member | verified (package rewrite) |
| docx image insert | native host attachment at cursor | live editor only | engine (native host) |
| pptx engine picture change | – | – | **unavailable** (no `.uno:ChangePicture` in the pinned bundle; use `replaceImage`) |

### 5.2 Format capability matrix / 格式能力矩阵

"Verified package path" edits the OOXML package directly (unit-tested). "Engine
path" is a real runtime command through the packaged engine — it is offered based
on runtime engine/format probes, **not** disabled for lack of a device receipt;
its release status is simply "on-device acceptance pending". Support is bounded
to the listed objects and formats; a specific file (protection, unsupported
object, malformed package) can still make an operation fail at runtime.

“已验证包级路径”直接编辑 OOXML 包（单测覆盖）；“引擎路径”是经内置引擎的真实运行时
命令，是否提供取决于运行时引擎/格式探测，**不会因缺少真机回执而禁用**，其发布状态只是
“真机验收待定”。支持范围限于列出的对象与格式；具体文件（保护、不支持对象、损坏包）仍可能
在运行时失败。

| Format | Read | Verified package path (tested) | Engine path (runtime; device acceptance pending) |
| --- | --- | --- | --- |
| **docx** | yes | inspect paragraphs/headers-footers; paragraph find/replace; createWord; same-format image replace | styles, bullet/numbered lists, alignment, insert table; cursor image insert |
| **xlsx** | yes | shared-string inspect/readSheet; value + formula CAS; createWorkbook; formula-error cell locations; image replace | number format, row/column insert-delete, freeze, sort, AutoFilter, go-to, recalculate |
| **pptx** | yes | slide + notes text; createDeck (charts/images); slide text fields; image replace | duplicate slide, move slide (duplicate-at-target + delete-original), align objects, present |

### 5.3 Actual runtime checks vs on-device limitation / 实际运行时检查与真机限制

What runs on device at runtime (independent of any qualification receipt):
真机运行时实际执行的检查（与资格回执无关）：

- The app probes the packaged engine and the concrete document format; the
  capability matrix reflects that, so a build without the engine reports those
  rows differently from a build with it. 应用探测内置引擎与具体文档格式，能力矩阵
  据此返回；无引擎构建与有引擎构建的报告不同。
- Every engine command is validated before dispatch (argument domains, e.g.
  table 1–100×1–20 rows, rows/cols 1–100, A1 cell/range regex, slide 1–500);
  invalid input never reaches the engine. 每条引擎命令派发前校验参数域；非法输入不进引擎。
- Apply re-checks the saved SHA-256 and the live selection fingerprint, flushes
  the working copy, reopens the SAVED package and verifies a target-aware delta;
  on failure it restores the verified pre-batch snapshot or quarantines. 应用前复核
  SHA 与选区指纹，刷新工作副本，重开已保存包校验定向差异；失败恢复已验证快照或隔离。

What is *not* yet evidenced (a release/acceptance limitation, not a runtime
disablement): physical-iPad exercise of the `.uno:` editing round-trip and real
native Office save/reopen. The engine is device-only and no physical
iPad/iPhone was reachable via `devicectl` when this was prepared, so simulator
bridge tests and the App compile do **not** count as that acceptance. Operations
with no runtime path at all (engine-level picture replacement) are a separate,
genuinely **unavailable** row above.

尚未取得证据的（发布/验收限制，而非运行时禁用）：`.uno:` 编辑往返与原生 Office 保存重开的
真机操作。引擎仅限真机，准备时 `devicectl` 无法连接真机 iPad/iPhone，因此模拟器桥接测试与
App 编译**不算**该验收。完全没有运行时路径的操作（引擎层换图）是上表中另一条真正
**不可用**的记录。

Apply safety / 应用安全：proposal binds the exact saved SHA-256 and, for
selection commands, an opaque selection fingerprint; apply re-checks it,
dispatches via the same WKWebView bridge as ink, flushes the working copy,
reopens the SAVED package and verifies a target-aware delta before the CAS
commit. A pre-batch snapshot is copied and hashed **before** dispatch; the
write-ahead journal is prepared before `workspace.save` with the expected
`after.sha256`; a failed batch restores the verified committed original (no
guessed UNO undo count), and an uncertain restore quarantines the working copy.
提案绑定精确 SHA 与选区指纹；应用前复核、经与笔迹相同的 WKWebView 桥接派发、刷新工作
副本、重开已保存包并校验定向差异后才 CAS 提交。批前先复制并哈希快照，`workspace.save`
前备好含预期 `after.sha256` 的预写日志；失败从已验证原件恢复（不靠猜测撤销次数），无法
确认时隔离工作副本。

Examples / 示例：
```json
{"action":"capabilities","format":"xlsx"}
{"action":"read","path":"budget.xlsx"}
{"action":"propose","path":"budget.xlsx","expected_sha256":"<64 hex>",
 "commands":[{"id":"excel.numberFormat","arguments":{"format":"percent","cell":"B2"}},
             {"id":"excel.freezePanes","arguments":{"cell":"A2"}}]}
{"action":"apply","path":"budget.xlsx","proposal_id":"<uuid>","grant_id":"<UI-issued>"}
{"action":"errors","path":"budget.xlsx"}
{"action":"replaceImage","path":"deck.pptx","expected_sha256":"<64 hex>","image":"#1","imagePath":"images/logo.png"}
{"action":"export","path":"deck.pptx","output":"exports/deck-copy.pptx"}
```

Honest limits / 诚实限制：the pinned bundle exposes the UNO surface (≈1.7k
commands available) but has **no undo-group command**, so multi-command batches
are reverted by restoring pre-batch bytes rather than a guessed undo count; PPT
move preserves content/notes but may reset slide identity. Engine-tier rows need
physical-device qualification receipts
(`scripts/qualify_office_device_capabilities.py`) before any release claim. 内置
引擎暴露 UNO 面但**没有撤销成组命令**；PPT 移动保留内容/备注但可能重置幻灯片身份。引擎
层能力须先取得真机资格回执才能在发布中声称。

## 6. Notes/PDF tools / 手记与 PDF 工具

`notes.read section=capabilities` returns the matrix below. Read sections:
`pages|nodes|connections|summaries|officeText|officeFields|capabilities`.
`notes.edit` actions: `apply` (default), `propose`, `preview`, `applyProposal`;
edit operations include rename/addPage/addText/updateText/moveText/deleteText,
mind-map node/branch ops and `updateOfficeText`.

| Capability | Tier | Tool / action |
| --- | --- | --- |
| per-text search position | implemented | `notes.search` — documentID, pageID/nodeID, elementID + UTF-16 matchOffset/matchLength; library tap and tool hit share one helper; flat PDF text without geometry scrolls to page and says precise highlight is unavailable |
| bounded read | implemented | `notes.read` (pages/elements/text, map nodes/connections/summaries, Office text/fields) |
| edit batch | implemented | `notes.edit` one undoable revision-checked batch, per-call idempotency |
| propose/preview | implemented | `notes.edit action=propose|preview`, binds base revision + document-JSON SHA-256, origin persisted |
| confirmed apply | implemented | `action=applyProposal` needs a single-use UI grant; write-ahead decision before commit, exact-once delivery to the origin conversation |
| export PDF | implemented | `notes.export format=pdf`, selected pages or whole doc, reopen-verified page count |
| export archive | implemented | `notes.export format=floenote`, re-import verified |
| attach / stage | implemented | `notes.attachFile`, `notes.stageAttachment` (stages one resource into the confined workspace; original untouched) |
| PDF inspect/render/edit/export-text/fill-form | delegated | `document.pdf.*` on the staged copy (real PDF annotations come from this tool, not Notes ink) |
| in-place PDF original-text edit | **unavailable** | PDF resource immutable; ink is drawn above and flattened on export; use delegated copy edit |
| edit recognized handwriting as text | **unavailable** | OCR is a per-page-revision search cache only |

PDF annotation is never original-text editing, and `PDFKitGate`/read-only/
encrypted protections are unchanged. PDF 批注不是原文编辑，`PDFKitGate`/只读/加密
保护不变。

## 7. `media.project` and image/video increments / 媒体工具与图像视频增量

The 1.7.23 contract persists (see [media workbench](FLOE_MEDIA_WORKBENCH.md)).
Build 265 adds interactive rect/ellipse/lasso selections with
add/subtract/replace, invert and feather, non-destructive masks, selection
copy/cut/fill through the displayed-mask raster pipeline (overlapping add/
subtract/inverted/feathered cuts are pixel-tested), brush
pressure/hardness/opacity, text tracking/leading/alignment/stroke/shadow,
temperature/hue/levels and flip; video gains a music waveform with volume/fade
visualization and 44-point frame-quantized edge trimming with mapping tests.
1.7.23 契约不变；265 新增选区/蒙版/复制剪切填充（按显示掩膜光栅化并做像素测试）、更丰富
画笔/文字/调色，以及音乐波形、淡入淡出与按帧量化边缘裁切。

## 8. Tests that ran vs still-open gates / 已运行测试与未完成门槛

Passed locally (recorded in the private evidence file and the release note):
full simulator App build; 19/19 focused App tests (transition arbitration, CAD
concurrency/live-draft lease/WAL + rollback/reconciliation, Office traversal/
symlink/ownership security, Office committed-batch journal); FloeDocuments 83/83;
FloeNotes 47/47; Canvas/FloeCore 36 and FloeWorkspace 15 (the backup-package
cases cover the **media** child-project/asset/Materials round-trip and restore
safety); CAD engine 42/42;
`test_cad_commands.mjs` 58/58; `test_office_command_bridge.mjs` all checks;
viewer hashes 33/33; LibreDWG independent matrix. Earlier real CAD bridge 2/2 and
primary CUA circle-save (independent LibreDWG SUCCESS) stand. A primary simulator
CUA pass on the final6 app verified the CAD-in-Canvas lifecycle: add LINE → keep
draft → close → reopen → Finish into the original node, then add CIRCLE → Finish
again, with the same node id/name/position/size and exactly one node; independent
LibreDWG read the first output as LINE 1/CIRCLE 2/TEXT 1 and the second as
LINE 2/CIRCLE 3/TEXT 1, and the original source-file hash was unchanged while the node's asset reference advanced.

Follow-up CAD backup checks: 19/19 focused package tests passed, including
unapplied `CanvasDrawingDraft` restoration, adopted revision assets, collision
remapping and refusal of unsupported history. The original failures were
retained; the successful rerun took 0.106 seconds. Full-App backup interaction
is still separate from these module tests. CAD revision restore has also been
exercised through the simulator UI. Physical asset reclamation remains deferred
conservatively; deleting a node must preserve bytes referenced by other nodes,
drafts or history.

后续 CAD 备份定向测试 19/19 通过，覆盖未应用草稿、已采用修订素材、冲突重映射
和不支持历史的拒绝；原失败证据保留，成功复验用时 0.106 秒。这些模块测试不
代替完整 App 备份交互。CAD 版本恢复另有模拟器界面验证。物理素材回收仍保守延后，
删除节点时保留其他节点、草稿或历史仍引用的文件。

Not run / not claimed: engine-tier Office `.uno:` operations on a physical iPad
(the engine is device-only and `devicectl` physical iPad/iPhone hardware was
unavailable, so real Office save/reopen is unverified and is not a simulator
gate); physical-device CAD/CAD-in-Canvas interaction (the lifecycle above is
simulator CUA only); real-page CAD full-screen keep/undo/redo likewise has
simulator CUA but no physical-device receipt; full-App Notes UI (the NativeNotes
component host separately passed 35/35 tests); other real-model providers;
physical performance/HDR; the final release device build from the reviewed
immutable source. The 2/19 first Office run failed on two `snapshot.liveSession`
expectations; the expectation now asserts file-only status for a
registered-but-not-opened session while retaining ownership-denial assertions.
The failed `.xcresult` bundle path was reused during retries, so only its text
log survives — an evidence gap, not a hidden failure.

### Latest real-model qualification / 最新真实模型验证

The proposal parameter failure is resolved: actual queries, measurement, proposal
preview, UI confirmation, saved revision/hash and original-conversation notification
passed on the simulator. Independent LibreDWG verified the line move from
(0,0)-(10,10) to (1,0)-(11,10), with nine model-space entities; actual close/reopen
rendered the result. Physical-device and all-provider acceptance remain separate.
Post-apply success feedback is being corrected. Final device build, upload and
Apple availability remain pending.

提案参数故障已修复：模拟器实际完成查询、测量、提案预览、界面确认、保存
及哈希核对，通知回到原会话。独立读取器确认直线精确平移，关闭重开正常，
模型空间仍有九个图元。真机及其他供应商待验。应用成功提示仍在修补；
最终设备构建、上传与 Apple 可用性待完成。

### Frozen local build / 本地构建固定

Tag v1.7.24 fixes 246d6c038f0a3f7ec7d7d9f7e19d074f13601bec. The final
Xcode 27A266a iphoneos27.0 Release build passed; matching App/dSYM and hashed
recovery transport are retained. Post-apply outcome feedback is fixed and
compiled. Signing/upload and Apple availability remain pending. This expedited
route uses local focused qualification, not a full cloud CI claim.

最终本地设备构建通过，成功提示已修复并编译验证；匹配设备包、符号和哈希已留存。
标签固定，签名上传及 Apple 可用状态待核验。本轮采用本地定向验证快速分发，
不宣称完整云端 CI 或真机验收。

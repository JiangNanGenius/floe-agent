# 1.7.24 (265) — 2D CAD, Drawing Assistant, Office/Notes shared AI, Canvas

Distribution status: see [current status](../../CURRENT_STATUS.md). The
development branch `codex/build265-creative-cad` was merged into `main` and
deleted; immutable tag `v1.7.24` pins
`246d6c038f0a3f7ec7d7d9f7e19d074f13601bec`. The exact local Xcode 27 device
artifact was signed and uploaded to TestFlight without an App rebuild
([run 37763059515](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515));
Apple reports VALID, unexpired and existing internal Floe QA IN_BETA_TESTING.
Build 265 was submitted to the existing publictest1 external group on
2026-10-08 and is waiting for review
([independent readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37766370762));
external approval remains pending.

## English

- In-app 2D DWG/DXF editing on the existing local engine: lines, circles, arcs,
  open/closed lightweight polylines, single-line text, linear/aligned/angular/
  radius/diameter dimensions and leaders; move/copy/rotate/uniform scale/mirror/
  trim/extend/offset; layers (create/rename/lock/visibility/colour/line type/
  weight, referenced layers cannot be deleted), object snap, geometric
  measurement and geometry checks. Save re-encodes and reparses the actual
  output and verifies entities/layers/references/units before any overwrite.
- Drawing Assistant (图纸助手) is now bound to the current drawing: it knows
  units, layers, active layer, selection and unsaved revision, can locate and
  highlight referenced entities, measure and check geometry, and presents a
  colour-coded added/changed/deleted proposal that the user confirms as one
  undoable transaction. Questioning or previewing never writes the original;
  apply is refused while the drawing is dirty.
- Office gains a typed shared command catalog used by both the editor UI and
  the `document.office.edit` tool. Engine commands cover Word paragraph styles,
  bullet/numbered lists, alignment and table insert; Excel number formats,
  row/column insert-delete, freeze panes, sort, AutoFilter, go-to-cell and
  recalculation; Presentation slide duplicate/reorder and object alignment.
  Text find/replace, cell formulas, formula-error locations and same-format
  image replacement use the reliable package (OOXML) path. Changes bind the
  exact saved SHA-256 and selection fingerprint, apply through a single-use UI
  grant, reopen the saved package and verify a target-aware delta before
  commit, and restore from the verified pre-batch snapshot on failure.
- Notes adds per-text search positioning (page plus element/node and UTF-16
  offset/highlight), selected-page or whole-document PDF export, portable
  `.floenote` archives, and a propose/preview/confirmed-apply flow with a
  durable, idempotent decision outbox. The capability matrix distinguishes
  implemented tools, PDF operations delegated to workspace tools on staged
  copies, and unavailable in-place PDF original-text/handwriting editing.
- Canvas drawing (`.dwg`/`.dxf`) nodes open the vector editor and update the
  original node without rasterizing; variant creates a provenanced new node;
  dirty sessions survive close via durable staged drafts. Canvas backup
  packages are file-backed and include media child projects, their assets and
  Materials/WorkbenchRoot, with path/symlink guards, all-hash verification
  before commit and rollback. Unapplied CAD draft descriptors and adopted
  revision assets are now included; 19 focused backup tests cover restoration,
  collision remapping and rejection of unsupported history. Full-App backup
  interaction remains separately unverified. Legacy flattened
  image/video first edits migrate once into typed child bindings; unknown newer
  binding data stays read-only and is preserved.
- Image workbench adds rectangle/ellipse/lasso selections with
  add/subtract/replace, invert and feather, non-destructive masks, selection
  copy/cut/fill, richer brush and typography controls, and colour adjustments.
  Video adds a music waveform with volume/fade visualization and precise
  44-point frame-quantized edge trimming.
- Shared AI contract across `cad.document`, `document.office.edit`,
  `media.project` and the Notes tools: discover capabilities, read the exact
  revision, propose a validated draft, confirm in the UI (the model cannot
  mint the grant), apply once with compare-and-swap and idempotent replay,
  then verify the saved bytes. Tool output separates queued/running/
  needs-confirmation/failed/saved/exported states and never treats a success
  string or a screenshot as evidence.

## 简体中文

- 在应用内基于现有本地引擎编辑二维 DWG/DXF：线、圆、圆弧、开放/闭合轻量
  多段线、单行文字，线性/对齐/角度/半径/直径标注与引线；移动/复制/旋转/
  等比缩放/镜像/修剪/延伸/偏移；图层（新建/重命名/锁定/显隐/颜色/线型/
  线宽，被引用图层不可删除）、对象捕捉、几何测量与检查。保存时重新编码并
  重新解析实际输出，在覆盖前校验图元、图层、引用与单位。
- “图纸助手”绑定当前图纸：掌握单位、图层、当前图层、选区与未保存修订，可
  定位并高亮被引用图元、测量和检查几何，并以不同颜色显示新增/修改/删除的
  提案，用户确认后作为一个可撤销事务执行。提问或预览绝不写入原图；图纸有
  未保存修改时拒绝应用。
- Office 新增编辑器界面与 `document.office.edit` 工具共用的类型化命令目录。
  引擎命令覆盖 Word 段落样式、项目符号/编号列表、对齐与插入表格；Excel
  数字格式、插入/删除行列、冻结窗格、排序、自动筛选、跳转单元格与重算；
  演示文稿复制/排序幻灯片与对象对齐。文本查找替换、单元格公式、公式错误
  定位与同格式图片替换走可靠的包级（OOXML）路径。修改绑定已保存文件的精确
  SHA-256 与选区指纹，通过一次性界面授权应用，重新打开保存后的包并校验
  定向差异后才提交；失败时从已验证的批前快照恢复。
- 手记新增逐字搜索定位（页码＋元素/节点及 UTF-16 偏移/高亮）、按页或整篇
  导出 PDF、可移植 `.floenote` 归档，以及提案/预览/确认应用流程，配合持久、
  幂等的决策发件箱。能力矩阵明确区分已实现工具、在暂存副本上交由工作区工具
  完成的 PDF 操作，以及不支持的 PDF 原文原地编辑/手写文字编辑。
- 画布图纸（`.dwg`/`.dxf`）节点以矢量方式打开编辑器并更新原节点，绝不
  栅格化；“制作变体”创建带来源的新节点；未保存会话通过持久暂存草稿在关闭后
  保留。画布备份包基于文件，包含媒体子工程及其素材、Materials/WorkbenchRoot，
  带路径/符号链接防护、提交前全量哈希校验与回滚。现已包含未应用的 CAD 草稿
  描述符与已采用修订素材，19 项备份定向测试覆盖恢复、冲突重映射和不支持历史
  的拒绝；完整 App 备份交互尚未单独验收。旧版扁平图片/视频首次编辑一次性迁移为类型化子工程
  绑定；未知的更新版本绑定数据保持只读并原样保留。
- 图片工作台新增矩形/椭圆/套索选区及加选/减选/替换、反相与羽化、非破坏
  蒙版、选区复制/剪切/填充，以及更丰富的画笔、文字与调色控制。视频新增音乐
  波形与音量/淡入淡出可视化，以及 44 点、按帧量化的精确边缘裁切。
- `cad.document`、`document.office.edit`、`media.project` 与手记工具共用
  AI 契约：发现能力 → 读取确切修订 → 提案校验草稿 → 在界面确认（模型不能
  自行生成授权）→ 以比较并交换方式幂等应用一次 → 校验已保存字节。工具输出
  区分排队/运行中/待确认/失败/已保存/已导出状态，绝不把成功文字或截图当作
  完成证据。

## Verification

Local, source-level verification on the development branch
`codex/build265-creative-cad` (since merged into `main` and deleted;
version 1.7.24, build 265; Xcode 27, 27A266a):

- Full simulator App build succeeded after project regeneration
  (`app-build-265-final6.log`); 19 focused App tests across four suites passed on
  the iPad simulator (transition arbitration, CAD concurrency and live-draft
  lease/WAL with concurrent-edit rollback and prepared-receipt reconciliation,
  Office path/traversal/symlink/ownership security, Office committed-batch
  journal). An earlier run failed 2/19 on two Office `snapshot.liveSession`
  expectations and the test expectation was corrected (file-only status for a
  registered-but-not-opened session, ownership-denial assertions retained); the
  failed result bundle path was reused during retries, so only its text log
  survives — an honest evidence gap.
- Package tests: FloeDocuments 83/83 (Office catalog, target-aware saved-package
  verification, tool contract), FloeNotes 47/47 (search helper, proposals,
  durable outbox), Canvas/FloeCore 36 + FloeWorkspace 15 (migration, CAD
  planner; the original 15 backup-package tests cover the **media** child-project/asset
  round-trip, followed by 19/19 backup tests including CAD drafts/history).
  CAD engine `cargo test --locked` 42/42;
  `test_cad_commands.mjs` 58/58; `test_office_command_bridge.mjs` all checks;
  engineering viewer asset hashes 33/33.
- Save-time CAD verification is in-app: on every save the same engine
  re-encodes and reparses its own output and compares entities/layers/
  references/units before overwriting; lossy unsupported data blocks the
  overwrite. Separately, LibreDWG 0.13.3 is run offline by the build/QA process
  on representative generated outputs — DWG AC1024/AC1027/AC1032
  (LINE/CIRCLE/TEXT incl. Chinese text, ARC, open and closed LWPOLYLINE, five
  DIMENSION kinds, LEADER) and the DXF projection re-read through `dxf2dwg`.
  That independent reader is release qualification, not an in-app per-save
  check, not universal DWG/DXF support and not a guarantee for any particular
  third-party file. Block references (INSERT) round-trip in DXF but do not yet
  pass the strict DWG gate on the representative sample; unknown/proxy entities
  and objects cannot be saved.
- Primary simulator CUA on the final6 app (owned iPad simulator, not a physical
  device): the embedded↔full-screen keep-draft/undo/redo path returns directly
  without losing the dirty edit, and the CAD-in-Canvas lifecycle worked end to
  end — add LINE → keep draft and close → reopen with draft/undo → Finish into
  the original node, then add CIRCLE → Finish again — keeping the same node
  id/name/position/size with exactly one node; independent LibreDWG read the
  first output as LINE 1/CIRCLE 2/TEXT 1 and the second as LINE 2/CIRCLE 3/TEXT
  1, and the original source file remained unchanged while the node adopted the new asset (primary CUA record, 2026-10-08).

Not verified this round and not claimed:

- Engine-tier Office commands (the `.uno:` surface) are implemented against
  the pinned Collabora bundle, validated before dispatch and structurally/
  bridge tested locally, but have no physical-device qualification receipt
  (`qualify_office_device_capabilities.py` is the remaining gate). This is an
  on-device acceptance limitation, not a runtime "unsupported" state: the app
  offers these commands from its actual engine/format capability probe rather
  than disabling them for lack of a receipt. The native Office engine is
  device-only, and a physical iPad/iPhone was unreachable through `devicectl`,
  so real Office edit/save/reopen could not be exercised in the simulator and
  must not be inferred from bridge tests or the App compile. Formula
  error-location and same-format image replace use the package path and are
  locally tested; engine-level picture replacement has no implementation in
  the pinned bundle (no `.uno:ChangePicture`), so at runtime that specific
  operation is genuinely unavailable and is reported as such — a different
  category from a device-unverified implemented command, and never faked. PPT
  slide move preserves content/notes but may reset slide identity, and the
  bundle has no undo-group command.
- The CAD-in-Canvas lifecycle and real-page CAD full-screen keep/undo/redo above
  are simulator CUA evidence; the physical-device touch pass is still open.
  NativeNotes component qualification subsequently passed 35/35 tests on an
  iPhone simulator. This is component-host evidence, not full-App Notes UI or
  physical-iPad acceptance; its fixture teardown warning is being corrected
  before the final source freeze.
- Real provider configuration save/reopen and one synthetic in-app cloud-model
  response were verified on the intermediate simulator app. This proves
  credential reuse and basic inference only; the Drawing Assistant
  query/measure/propose/confirm/save closed loop is still pending.
  Physical-device performance, HDR and OS split-window dragging are separately
  reported.

## Additional simulator checks / 补充模拟器验证

- On the intermediate Debug app, saving a configured provider, reopening it,
  and connecting again without re-entering the credential succeeded. A
  synthetic request received the expected real model response. This is not
  acceptance of every provider or of the CAD assistant editing workflow.
- CAD history was exercised through the real UI: adopt an edit, reopen, inspect
  original/adopted revisions, then restore the original. The node identity,
  geometry and relationship remained intact and persisted history contained
  the restoration. Final conflict/metadata guards and the Canvas assistant /
  full-screen entry are being completed before source freeze.
- 中间 Debug 包已验证供应商保存、重开、复用已存凭据连接，以及一次合成请求的
  真实模型响应；这不代表全部供应商或图纸助手编辑闭环通过。
- 图纸历史已通过实际界面验证“采用修改、重开、查看版本、恢复原版”，节点身份、
  位置尺寸及连线保持，恢复记录已持久化。最终冲突保护、元数据一致性以及画布内
  助手／全屏入口仍在源码冻结前收尾，不据此宣称已发布。

## Distribution note

### Final candidate follow-up / 最终候选复验

- A later intermediate Canvas CAD build opened full-screen correctly, but
  returning to the embedded editor left a blank drawing area; re-entering
  full-screen recovered the same saved draft. Drawing Assistant presentation
  was delayed until leaving full-screen, and its real CAD tool run was not
  completed. These are release-blocking regressions under repair; the earlier
  checks above do not establish acceptance of this newer entry path.
- 后续中间包的画布 CAD 全屏入口可打开，但返回嵌入编辑器后绘图区空白；再次
  进入全屏可恢复同一草稿。图纸助手弹窗延迟到退出全屏才显示，真实 CAD 工具
  调用尚未完成。这些问题正在修复，阻止本候选分发；前述历史验证不替代新入口
  的复验。
- Follow-up simulator UI verification passed clean and dirty full-screen
  return, draft save, and immediate Drawing Assistant presentation. The
  assistant's navigation-bar Send action remained unresponsive; its actual
  query/measure/propose run is still blocked and is not claimed as passed.
- 后续模拟器实际操作已通过普通及未保存状态的全屏返回、草稿保存和立即打开
  图纸助手。助手导航栏“发送”仍未响应，真实查询／测量／提案流程仍待修复验证。
- A subsequent in-form Send control was actionable after real keyboard input.
  Accessibility value assignment alone did not update the input binding and
  is not evidence of a normal typing defect. The actual Send then surfaced
  “Conversation has no canonical workspace”; Canvas assistant task
  initialization is being fixed before the real CAD tool loop or distribution.
- 后续表单内“发送”在真实键盘编辑后可用；仅辅助功能赋值未更新输入绑定，
  不能据此宣称正常打字有缺陷。实际发送暴露“会话没有规范工作区”错误，正在
  修复画布助手任务初始化，尚未完成真实 CAD 工具闭环或分发。

- The next simulator build repaired canonical-workspace initialization: real
  Drawing Assistant submission, capability discovery and entity queries passed.
  Coordinate-based measurement returned 14.142135623730951 drawing units.
  Handles-only distance with one entity and edit proposals exposed insufficient
  parameter validation and generic JavaScript errors. The task was stopped with
  its checkpoint retained; the parameter/error contract is being repaired.
  No real-model confirmed apply or save/reopen success is claimed yet.
- 下一模拟器包修复了规范工作区初始化，真实图纸助手发送、能力查询与图元查询
  已通过；按坐标测量返回 14.142135623730951 个图纸单位。仅提供一个图元的距离
  测量及编辑提案暴露参数校验不足、错误信息笼统的问题。已停止任务并保留检查点，
  正在修复参数与错误契约；尚未宣称真实模型确认应用及保存重开通过。

The release preflight (`scripts/release_preflight.sh`) requires this file and
`docs/releases/testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_265.json` to exist in
the frozen source with both language sections; both are prepared here. The final
device build must still be produced from the reviewed immutable source,
re-hashed, and taken through signing/upload, Apple VALID readback, Floe QA and
publictest1 separately; this documentation pass performs none of those steps.

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

### Frozen local build and signed distribution / 本地构建固定与签名分发

Tag v1.7.24 fixes 246d6c038f0a3f7ec7d7d9f7e19d074f13601bec. The final
Xcode 27A266a iphoneos27.0 Release build passed; matching App/dSYM and hashed
recovery transport are retained. Post-apply outcome feedback is fixed and
compiled. The exact local artifact was signed and uploaded to TestFlight without
an App rebuild ([run
37763059515](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515)):
Apple reports VALID, unexpired and existing internal Floe QA IN_BETA_TESTING.
Build 265 was submitted to the existing publictest1 external group and is
waiting for review ([independent readback
37766370762](https://github.com/JiangNanGenius/floe-agent/actions/runs/37766370762));
external approval is pending. This expedited route uses local focused
qualification, not a full cloud CI claim.

最终本地设备构建通过，成功提示已修复并编译验证；匹配设备包、符号和哈希已留存。
本地产物已在不重新编译 App 的前提下完成签名并上传 TestFlight
（[运行 37763059515](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515)）：
Apple 显示 VALID、未过期、现有内部 Floe QA 为 IN_BETA_TESTING；Build 265 已提交至
现有 publictest1 外部组并等待审核（[独立回读
37766370762](https://github.com/JiangNanGenius/floe-agent/actions/runs/37766370762)），
外部批准尚未完成。本轮采用本地定向验证快速分发，不宣称完整云端 CI 或真机验收。

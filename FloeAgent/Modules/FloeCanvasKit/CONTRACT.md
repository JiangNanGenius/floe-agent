# FloeCanvasKit CONTRACT — 基础合同与增量说明（2026-11-04）

本文件冻结 FloeCanvasKit P0.1 阶段的公开 API 与行为合同（P0 合同的全部
内容继续有效），供 FloeCanvasLayout / FloeCanvasUI / FloeCanvasFlow /
FloeCanvasExchange 的实现者直接消费。任何修改都必须显式升版并同步本文件。

- 源码：`FloeAgent/Modules/FloeCanvasKit`（SwiftPM，swift-tools 6.2，iOS 26 / macOS 15，Swift 6）
- 基线：根检出 `49222ba1edd558645900a18909aa2c80aad13d5b`，分支 `codex/office-linux-closure-20261017`
- P0 验证：`swift test` 65 用例全过（Core 28 + Integration 37），exit 0；
  日志 `Local/Private/infinite-canvas-predev-20261103/swift-test-final.log`。
- P0.1 验证：`swift test` **152 用例全过（Core 77 + Integration 75），exit 0**；
  命令 `DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer swift test
  --scratch-path ~/Library/Caches/CodexBuild/FloeCanvasKit/core-complete-20261103/swiftpm --jobs 6`。
  日志与构建记录见 `Local/Private/infinite-canvas-core-complete-20261103/`
  （`swift-test-final.log`、`swift-build-final.log`、`API_READY.md`）。
- 当前增量验证：Core **81**、Integration **81** 项通过（Swift 6 对象编译，
  实际 XCTest 退出 0）。Flow/Layout/Exchange/UI 已为真实独立产品，分别见
  `FLOW_CONTRACT.md`、`LAYOUT_CONTRACT.md`、`FORMAT_SUPPORT.md`、`UI_CONTRACT.md`。
  上述 P0/P0.1 数量为历史阶段记录，不代替当前证据。
- 本包不依赖 FloeCore / FloeApp，核心模块不反向依赖宿主；未来的资格
  适配层可以同时 import 本包与 FloeCore 做映射。Package.swift 由协调者独占，
  由后续独立模块接线更新；FlowData.swift 的基础公开 DTO 保持兼容（修复
  FlowGraphValidator 的 loop-body 声明序实现缺陷）。

## 1. 产品（Products）

| 产品 | 目标 | 状态 |
| --- | --- | --- |
| FloeCanvasCore | 可移植快照 DTO + 纯编辑 + 文档事务 + Flow 数据契约 | ✅ P0.1 已实现 |
| FloeCanvasIntegration | 宿主协议 + 内存/文件资格仓储 + 可信编辑守卫 + 有界资源 + 来源刷新 + 旧版适配 | ✅ P0.1 已实现 |
| FloeCanvasLayout / FloeCanvasUI / FloeCanvasFlow / FloeCanvasExchange | 布局 / UI / 运行引擎 / 交换格式 | 已实现；实际验证分层记录于交付记录 |

## 2. FloeCanvasCore 冻结 DTO

文件：`Sources/FloeCanvasCore/`

- `Support.swift`
  - `JSONValue`（null/bool/number(String 原始字面量)/string/array/object）。
    **数字以源文档字面量保存**；`JSONFidelity.parse/serialize` 保证未知
    数值（超 Int64 整数、高精度小数、1e400 指数）读写不改值。Codable
    路径仅用于包内 DTO 嵌入；经外部 Codable 解码器会规范化拼写，非有限
    字面量用显式标记保留。
  - `CanvasKitError`：missingEntity / revisionConflict(expected,current) /
    requestIDConflict / editScopeViolations / invalidFlowGraph /
    unsupportedLegacySchema / sourceUnavailable / repositoryRootViolation / io。
- `Content.swift`
  - `CanvasContent`：text / markdown / code / formula / table / media /
    pdf(pageRange) / web / editor(CanvasEditorReference) /
    unknown(kind:payload:)。**未知内容原样保留读写**。
  - `CanvasAssetLocator`（资产身份，不含字节）、`CanvasEditorReference`
    （子工程 projectID + appliedRevision + draftRevision + editorKind）、
    `CanvasSourceReference`（sourceID + fragment + usedRevision +
    annotations）、`CanvasSourceAnnotation`。
- `Snapshot.swift`
  - `CanvasSnapshot`（id/schemaVersion/name/pages/selectedPageID/
    viewports/revision，Int64 修订、UUID 身份）。
  - `CanvasPageSnapshot`（nodes/connections/strokes/groups/regions/scenes/
    background）。
  - `CanvasNodeSnapshot`（kind/title/content/frame(center 锚点)/
    rotationDegrees/zIndex/isLocked/groupID/regionID/source/
    createdByRunID/metadata）。`CanvasNodeKind`：content /
    generationTask / scene3D / legacyGroup / sourced / unknown。
  - `CanvasGroupRecord`（成员列表，随组操作）与 `CanvasRegionRecord`
    （可折叠区域，几何包含）是**两种不同**的组织实体。
  - `CanvasSceneRecord`（命名视口场景，ordered 演示）。
  - `CanvasConnectionSnapshot` + `CanvasRelationKind`
    （line/arrow/source/generatedFrom）——**普通关系，永不承载执行数据**。
- `CanvasEdits.swift`
  - `CanvasEditOperation`（insertNode/updateContent/updateTitle/move/resize/
    setLocked/removeNode/insertConnection/removeConnection/
    setRegionCollapsed）。
  - `CanvasEditScope`：wholeDocument / selectedNodes(Set)。**自定义
    Codable：selectedNodes 按 UUID 字符串排序编码**，保证摘要确定性。
  - `CanvasEditEngine.apply(_ batch, to:) throws -> CanvasEditResult`：
    整批先校验后应用；违反锁定节点/选区/悬挂连接收集为
    `editScopeViolations` 一次抛出，输入快照不被部分修改；setLocked 仅
    允许 wholeDocument；removeNode 自动清理连接与分组成员。
- `Identity.swift`
  - `CanvasIdentityMapper.copy(_:newSnapshotID:)`：自有对象 UUID 换新、内部
    链接（分组成员/连接端点/场景聚焦/视口键）跟随重映射、
    `createdByRunID` 清空（复制不继承活跃运行）。
  - `copyFlow(_:)`：图、节点、端口声明、边、条件分支、循环成员、变量与
    typed 参数中的内部引用一致重映射，图修订归零。宿主模板 registry、来源、
    资产和专业子工程身份保持引用，只有宿主实际 fork 定义时才更换；不能
    随机更换模板 ID 后留下悬空引用。卡片自有批注换新身份。
- `FlowData.swift`（未来 Flow 运行时的**纯数据**契约，无解释器/网络）
  - `FlowValue` / `FlowValueType`、`FlowPort`（name+dataType+direction+
    isVariadic）、`FlowPredicate`（结构化比较/and/or/not）、`FlowOperand`。
  - `FlowNode` + `FlowNodeKind`（source/transform/condition/loop/batch/
    subgraph/customScript/customAPI/output）、`FlowConditionBranch`、
    `FlowEdge`（typed data edge，区别于 CanvasRelationKind）。
  - `FlowVariable`（ownerNodeID 作用域，内层遮蔽外层）、
    `FlowScriptDescriptor`（sourceHash+签名，**不携带凭据**）、
    `FlowAPIDescriptor`（credentialHeaderNames 只列名）、
    `FlowGroupDescriptor`（可复用模板）。
  - `FlowRunIdentity`（runID+canvasID+canvasRevision+flowGraphID+
    flowGraphRevision+**environmentID**+owningTaskID，不可变）。
  - `FlowStepRecord`（attempt/inputs/outputs/status/error/events）、
    `FlowStepEvent`、`FlowRunCheckpoint`（completedStepIDs+loopCounters）。
  - `FlowGraphValidator.validate(_:maxLoopIterations:)`：外层 DAG；
    环只能由声明了 bodyNodeIDs 的 `.loop` 结构化节点拥有；循环上限默认
    100 可配置；端口方向/类型/悬挂边/重复 ID/条件分支输出口均校验。

## 3. FloeCanvasIntegration 冻结协议与仓储

文件：`Sources/FloeCanvasIntegration/`

- `CanvasHostAPI.swift`
  - `CanvasRuntimeContext`：canvasID/pageID/revision/owningTaskID/
    environmentID；运行代码的操作必须 hasEnvironment。
  - `CanvasDocumentStore`：`load` / `commit(batch:expectedRevision:requestID:)`
    / `undo(canvasID:expectedRevision:requestID:)` /
    `redo(...)` / `undoHistory`；提供 `undo(canvasID:)` /
    `redo(canvasID:)` 兼容便捷重载（内部 load 现修订、新 requestID）。
  - `CanvasCommitReceipt`（requestID+previousRevision+revision+batchHash+
    undoToken）、`CanvasUndoEntry`、`CanvasHistoryFrame`、
    `CanvasHistoryState`（undoStack+redoStack+appliedEntries）。
  - `CanvasAssetStore`（bytes(for:)/store，字节唯一通道）。
  - `CanvasSourceService`（currentRevision/read）+
    `CanvasSourceOpening`（`@MainActor openSource(sourceID:fragment:)`，
    原件打开由宿主解析，UI 不得自行拼路径）。
  - `CanvasEditorGateway`（openEditor/applyEditorResult）。
  - `CanvasAssistantGateway.perform(CanvasAssistantRequest)`：
    selection-aware；`CanvasResultDisposition` replace/branch（显式指令
    优先，nil 走默认策略）。
  - `CanvasStepExecutor`：
    `submitStep(CanvasStepExecutionRequest)` /
    `queryStep(attemptID:runID:)` → `CanvasStepQueryResult`（status+
    outputs+producedAssets+**hostTaskBinding**）/ `queryRun` / `cancelRun`。
    语义：同 `(runID, attemptID)` 重试**复用宿主已有工作**；提交无法确认
    返回 `.unknown`，**任何一方不得自动重发**。
- `Repository.swift`
  - `CanvasRepositoryEngine`（actor）：全部不变量所在——expectedRevision
    CAS、requestID 幂等（同 ID 同内容重放原回执；同 ID 异内容拒绝；
    **跨画布 ID 拒绝**）、修订只增、一次批次一次撤销单元、新提交清空
    redo、persist 失败全量回滚（含 redo 历史）。
  - `CanvasBatchDigest`：JSONEncoder.sortedKeys + 无空格；依赖
    `CanvasEditScope` 的排序编码保证等价批次摘要一致。
  - `InMemoryCanvasRepository`：工作内存实现。
- `FileRepository.swift`
  - `FileCanvasRepository`（actor，**资格限定，非 App 权威**，仅存于显式
    root）。布局 `canvases/<id>/{<id>.lock, manifest.json, blobs/<sha>.json}`。
    - per-document `flock`（Darwin per-open-description，同进程多实例与
      跨进程一样串行）。
    - **manifest.json 是唯一恢复权威**，原子写最后落盘：绑定 snapshotBlob
      + snapshotRevision + historyBlob + receipts。崩溃在 manifest 之前 =
      什么都没提交；之后 = 完整提交。损坏/缺失 manifest 一律 fail-closed
      （io 错误），**绝不从未提交 blob 猜测**。blob 不可变，旧记录保留。
    - `create(canvasID:snapshot:requestID:)` 建立修订 0 基线；之后 commit。
- `SourceRefresh.swift`
  - `CanvasSourceRefresher.refresh(...instruction:)`：显式刷新；
    `.replace` 显式指令 > `.branch` > 默认策略（`metadata
    ["canvas.manualEditRevision"] > usedRevision` 时保留原件并生成可恢复
    分支节点）；批注与手工修改始终保留；结果 `.unchanged/.updated/
    .conflict(alternativeNodeIDs:nodeIDs:)`。
- `LegacyCanvasAdapter.swift`
  - `import(_ bytes:, fallbackCanvasID:?)` → `LegacyImportResult`
    （snapshot + `LegacyMigrationPlan` + originalTree + **rawBytes 兼容
    权威**）。身份缺失误导：仅接受宿主显式 fallbackID，否则
    missingEntity；节点/文档缺 ID 记 warning `missingIdentity`；连接端点
    无法定位记 `danglingReference` 并保留。schema 1...7，超出抛
    unsupportedLegacySchema。写回 `exportPreservingLegacy` 在原始树上
    覆盖已知字段，未知值逐字保留（数字字面量精确）。
- `ControlledStepExecutor.swift`：契约验证用受控 executor（dedupe、
  unknown、reconcile 语义可作宿主参考实现）。

## 3.1 P0.1 冻结新增 — 文档事务（同管线，一次撤销）

- `CanvasDocumentOperation`（Codable）：显式领域编辑——
  `createPage/renamePage/reorderPages/deletePage/selectPage`、
  `createGroup/updateGroup/removeGroup(deleteMembers:)/moveGroup`、
  `createRegion/updateRegion/removeRegion(deleteContents:)`、
  `createScene/updateScene/removeScene`、`addStroke/updateStroke/removeStroke`、
  `editPage(CanvasEditBatch)`（嵌套经典批次，必须自行声明 wholeDocument；
  嵌套违例使整个文档批次失败）、`updateNodeSource/updateNodeRotation/
  updateNodeStyle/updateNodeMetadata(nodeID:values:removingKeys:)`、
  `insertFlowGraph(pageID:graph:)/replaceFlowGraph(graph:)/
  removeFlowGraph(graphID:)`。
- `CanvasDocumentBatch(scope:operations:)` + `CanvasDocumentEditEngine.apply`
  整批先校验后应用；结构批次要求 wholeDocument（selectedNodes →
  scopeEscalation）。规则：至少保留一页（删选中页→按声明顺序选第一幸存页）；
  删除 group/region 默认保留内容（仅清派生引用），显式 deleteMembers/
  deleteContents 才删除并级联清理连接/分组成员/场景焦点；moveGroup 原子
  平移成员，锁定成员整批拒绝；region 内容判定=几何包含（frame 含
  node center，外层 region 含嵌套成员），regionID 仅为派生缓存（引擎按
  innermost 几何重算，非存储权威）；reorderPages 必须是页面 ID 排列；
  几何必须有限/正；存储快照重复 ID 抛 `invalidSnapshot`（不 trap）。
- `CanvasDocumentStore.commitDocument(...)`：与 `commit` 共用同一
  requestID 幂等域、CAS、撤销栈与持久化回滚；一次批次一次撤销。
- Flow 定义绑定：`CanvasPageSnapshot.flowGraphs:[FlowGraph]` 与
  `pencilDrawingData:Data?`（上限 32 MiB）缺省解码（P0 快照兼容）；
  `CanvasEditOperation.setPencilDrawingData(Data?)`（wholeDocument-only
  手势）。graph replace 要求 revision 严格递增；执行记录/检查点永不入
  文档状态；Flow/画布共享世界坐标。
- `CanvasFlowSourceParameterKey`（`floecanvas.source.canvasID/pageID/
  nodeID/usedRevision`）+ `CanvasFlowSourceBinding`：来源输入节点参数
  是定位符（locator），不是权限；指向本画布时 insert/replace 校验
  page/node 存在。
- `CanvasFlowCardBindingKey`（`floe.flow.graphID/nodeID`）+
  `CanvasFlowCardBinding(metadata:)`：可视卡片仍是普通节点
  （kind `.generationTask`），撤销/锁/选区共用同一画布对象；批次最终态
  校验绑定可解析且无重复 (graph,node)；锁定卡片拒绝其 graph 被 replace；
  copy 同时重映射卡片绑定、graph 内部连线与指向本画布 source locator。
- `CanvasContent.richText(document:)`（`CanvasRichTextDocument.runs` /
  `CanvasRichTextRun`：text+bold/italic/underline/strikethrough+link+
  foregroundColor，默认 false/nil；`makeAttributedString()` 走
  `CanvasRichTextAttribute` 规范键，Foundation-only）与
  `.shape(kind:text:)`（`CanvasShapeKind`：rectangle/roundedRectangle/
  ellipse/diamond/line/arrow）。样式统一走 `CanvasVisualMetadataKeys`
  （fillColor/strokeColor/strokeWidth/textColor，`CanvasVisualStyle` 校验
  `#RGB/#RRGGBB/#RRGGBBAA` 或 lower-case 名称、宽度有限非负）；
  `updateNodeMetadata` 对 visual/binding 键做值校验。
- 未识别 content kind（现存或未来）解码进 `.unknown(kind:payload:)`，
  载荷完整保留、不崩溃；缺失 payload 按空对象；pdf pageRange 反向/负页码
  解码报错（不 trap）。

## 3.2 P0.1 冻结新增 — 可信编辑守卫与提案（Integration）

- `CanvasHostEditContext`：canvasID/pageID/revision/selectedNodeIDs +
  grantsWholeDocument/allowsCreation/allowsRemoval/allowsLockChanges/
  allowsStructuralChanges/allowsSelectedFlowEdits，全部由宿主按用户当前
  意图签发；batch 自带的 scope 只是数据。
- `CanvasAssistantEditGuard.validatedBatch(_:request:)`：wholeDocument
  越权 → scopeEscalation；锁变更默认拒绝（显式 allowsLockChanges 才可）；
  组织手势（setRegionCollapsed/setPencilDrawingData）不能绕过选区；跨页
  需 wholeDocument；effective scope = 宿主真实选区 + 本批实际 insert 的
  新 ID（duplicate ID 无法借此改选区外原件）。
- `CanvasAssistantProposal`（`canvasBatch`/`documentBatch`）+
  `CanvasAssistantProposalGateway`（既有 CanvasAssistantGateway 保留兼容）。
- `validatedProposal(_:request:)`（create-only）与
  `validatedProposal(_:request:against:)`：核对 canvas/revision；
  insertFlowGraph 限本页（跨页拒）；新连接端点必须来自可信选区或本批
  新节点（两个选区外原件不得被新连线）；在 allowsSelectedFlowEdits 下
  允许 replaceFlowGraph 仅改动绑定到可信选中卡片的 flow node/port/edge
  （逐 ID diff 校验，未选中定义不变）与选中节点的属性/metadata 编辑。
  普通已授权编辑仍直接执行，无新增审批提示。

## 3.3 P0.1 冻结新增 — 有界资源与原生保真

- `CanvasCancellationToken`（Foundation-only）+ `CanvasAssetResolving`
  /`FileCanvasAssetResolver`（显式 canonical root；逐级 descriptor 打开以
  防符号链接替换；禁用 symlink 模式明确拒绝；仅普通文件、有界分块读取/
  取消全部强制）、`CanvasAssetMetadataCache`（显式缓存，策略归宿主）、
  `CanvasPreviewRequest/Result`+`CanvasPreviewProviding`、
  `CanvasFileLease`+`CanvasResourceLeasing`、`CanvasAssetStream`+
  `CanvasAssetStreaming`：UI 常规预览消费缩略图/租赁/流，不急切载入整段
  视频；完整归档与显式渲染允许按格式上限读取完整资产。宿主边界协议与
  实际 preview/stream 服务分别验收。资格 resolver 基础测试已过，后续
  descriptor/symlink 回归已对象编译，行为结果以最终测试记录为准。
- `JSONFidelity.parse(_:options:)`：`ParseOptions(maxByteCount 64 MiB,
  maxDepth 128)` 可配；严格 JSON number 语法（`-`/`1.`/`1e`/`01` 拒绝）；
  超限抛错且输入不被消耗。
- `JSONValue` 原生 Codable 恒等：所有 number 一律 tagged exact literal
  `{"$floecanvas.rawNumber":{"literal":"…"}}`（2.0/-0/1e0/超 Int64 bigint/
  高精度小数不再被重类型化）；与 marker 形状碰撞的用户对象经
  escape（fidelity 字符串载荷）原样还原；P0 flat marker 向后兼容解码。
- `CanvasSourceContent.typedContent`（默认 nil，旧服务兼容）：typed
  refresh 只在同 content kind 时原位更新；表格/公式/富文本/媒体等遇
  纯文本读取一律生成可恢复分支（绝不静默转纯文本；批注/布局/手工修改
  始终保留）。
- `CanvasEditorForkGateway`：专业子工程复制不得浅拷贝伪造独立——
  宿主显式 fork，原件绑定保持到宿主返回真实新绑定。
- `LegacyCanvasAdapter`：export 按稳定 ID overlay——连接 label/ports/
  未知字段、笔迹编辑/删除与未知字段、非字符串 metadata 原值全部保留；
  groupID 清除同步删原键；结构化内容写回报 `LegacyExportReport.losses`
  明确迁移损失；缺失实体 ID 确定性派生（路径+子树 SHA-256，重开同字节
  同 ID）+ missingIdentity 警告；时间戳按真实 codec 语义解析（2001
  reference date，ISO-8601 兼容）；pencilDrawingData 映射真实同名字段。
- 新错误：`CanvasKitError.invalidSnapshot(String)`（重复 ID 等存储损坏，
  绝不 trap）、`.cancelled`。

## 4. 宿主绑定候选（下一阶段的适配层，不在本包）

- 文档权威：App 现有 `FloeCore.CanvasDocumentRepository`
  （`project(canvasID:)` / `save(expectedRevision:)`）与
  `CanvasPatch/CanvasCommandService` 保持不变；适配层把
  `CanvasSnapshot` ⇄ `CanvasProject`、`CanvasEditBatch` ⇄ `CanvasPatch`
  做纯映射（几何同为 center 锚点；kind/metadata 映射表以
  `LegacyCanvasAdapter` 为准）。宿主走严格
  `commit/undo/redo(expectedRevision:requestID:)`。
- 来源刷新所有权：`CanvasSourceRefresher` 产出候选快照与替代节点，
  实际提交由宿主经 `CanvasDocumentStore.commit` 执行；来源服务实现
  由宿主内容服务承担（稳定 sourceID，非裸 URL）。
- 步骤执行：宿主以现有 jobs/服务生命周期实现 `CanvasStepExecutor`；
  节点定义以 `CanvasStepExecutionRequest.node`（冻结的 FlowNode）为准。

## 5. 已完成的后续扩展与接入边界

- 媒体/预览：已提供可取消缩略图、受控文件/流租赁协议；UI 仅对可见资源
  加载有界预览。生产媒体服务和受保护 PDF 门由宿主注入。
- FloeCanvasFlow 已实现类型化编译、调度、持久恢复与调试，消费第 2 节数据契约。
- FloeCanvasExchange 已实现完整实验归档及三种开放格式的可编辑投影和损失报告。
- `CanvasHistoryAvailability` 新增 `undoCount/redoCount`；
  `CanvasDocumentStore.historyAvailability(canvasID:)` 必须返回实际可用栈，
  不能由审计历史数量推算。内存/文件资格仓库实现了该接口；旧宿主默认报不支持。
- 文档保存检查循环结构与正整数上限，不以默认执行上限 100 限制可保存定义。
  实际执行仍由编译器按宿主显式配置检查，默认 100 不变；`.json` 类型投影可以
  保存，运行时继续检查真实值类型。文件仓库保留单条已解码记录缓存；每次读取
  都重新读取 manifest，并校验快照/历史两份 blob 哈希与快照身份/修订。
  不因缓存绕过外部写入、损坏检测、CAS 或原子回执；缓存命中只省去重复解码。

## 6. 真实限制（诚实记录）

- undo/redo 历史为整快照帧，资格级够用；大型画布需要增量历史时由
  后续阶段在宿主侧实现。
- `FlowGraphValidator` 的环规则是结构化近似：声明 body 内的环整体合法，
  不逐边判定“环是否真正服务迭代”。
- `CanvasSourceRefresher` 按 content kind 整段刷新；富内容节点（表格/
  公式）的字段级合并属于后续阶段（P0.1 起同 kind 整段替换 + 异 kind
  可恢复分支，绝不静默转纯文本）。
- 文件仓储 receipts 随 manifest 增长，未做裁剪；长期生产使用须定义保留策略。
- 跨进程互斥：P0 仅有两实例同进程证据；P0.1 新增真实子进程 race 测试
  （python3 flock 持锁期间仓储 load 必须阻塞至释放，实测通过）。
- 缩略图/租赁/流为宿主边界协议；`FileCanvasAssetResolver` 为资格级实现，
  生产缩略图由宿主媒体服务实现。
- 真实模型/账户行为、生产接入与双设备同步未测；Flow 运行时已在本包实现，
  其确定性离线验收不能替代真实提供方验证。

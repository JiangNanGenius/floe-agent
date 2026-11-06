# FloeCanvasUI — 原生编辑器与宿主合同（2026-11-04）

本文件冻结 `FloeCanvasUI`（FloeCanvasKit P1b 阶段 + P1c 画板混合内容/可访问性/
多图选择/运行输出放置 + P1d 运行输出事务/批量输出完整保存）的公开宿主 API：
根视图、模型所有权、注入服务束、新建场景/模板入口、Flow 运行/恢复/局部重跑
入口、测试注入方式与无障碍标识。资格宿主（App target
`org.floeagent.canvas.qualification`）按此接线；后续 UI 工作保持本文件签名
兼容（新增为主，不改既有签名）。

- 源码：`FloeAgent/Modules/FloeCanvasKit/Sources/FloeCanvasUI/`
- 测试：`FloeAgent/Modules/FloeCanvasKit/Tests/FloeCanvasUITests/`（**原生
  iOS/UIKit 测试**：整个目录由 `#if canImport(UIKit)` 门控，宿主 iOS 测试
  target 实际执行；macOS 无头包测试不验证 UI）
- 依赖（协调者在 Package.swift 注册）：`FloeCanvasCore`、
  `FloeCanvasIntegration`、`FloeCanvasLayout`、`FloeCanvasFlow`、
  `FloeDiagramCore`、`FloeDiagramExchange`（`DiagramNativeInk` /
  `DiagramNativeRenderer` 复用）。UI 不依赖也不修改 DiagramKit 私有视图。
- 状态：Swift 6 原生对象编译及独立 App/测试目标构建通过。当前 126 项
  hosted 行为测试通过；触控界面与最终可见画布性能的完整运行结果
  以独立宿主交付记录为准。`CanvasEditorStore.swift` 由
  `#if canImport(UIKit)` 门控；macOS 无头测试不计作 UI 验收。

## 1. 依赖与所有权

`CanvasEditorStore` 是 `@MainActor ObservableObject`。两种所有权：

```swift
// A. 视图自持（App 最简单路径）
let view = CanvasEditorView(canvasID: canvasID, services: services)

// B. 宿主/测试持有同一真实 store（推荐用于资格宿主与 UI 测试）
let store = CanvasEditorStore(canvasID: canvasID, services: services)
let view = CanvasEditorView(store: store)
await store.load()
```

模型所有权：store 持有 `CanvasSnapshot`、选区、视口、预建 Layout 索引；
**文档权威唯一**——所有编辑经 `store.commit(_:undoLabel:)` 走
`CanvasDocumentStore`（同 CAS / requestID 幂等 / 一次撤销）。经典页批次走
`commit`，保留可信选区范围；文档级结构编辑走 `commitDocument`。
UI 不维护第二份已提交撤销栈；文本/Pencil 完成手势 = 一次批次。
撤销/重做可用性读取宿主 `historyAvailability(canvasID:)` 的实际栈数量；
`undoHistory` 是审计记录，不能据此推断可用栈。旧宿主未实现此新增方法时
默认报不支持，UI 禁用相应按钮，不伪造可用状态。

## 2. 根视图（稳定签名）

```swift
public struct CanvasEditorView: View {
    // A. 视图创建并持有 store
    public init(
        canvasID: UUID,
        services: CanvasEditorServices,
        configuration: CanvasEditorConfiguration = CanvasEditorConfiguration()
    )
    // B. 宿主持有同一真实 store（资格宿主推荐；store 生命周期归宿主）
    public init(store: CanvasEditorStore)
}
public extension CanvasEditorView {
    var storeOwner: CanvasEditorStore { get }  // 只读访问，便于宿主读取状态
}
```

- `canvasID` 必须已存在于 `services.documentStore`（宿主先
  `create(canvasID:snapshot:requestID:)` 或载入既有画布）。
- 视图 `.task { await store.load() }` 自动载入并建立首个布局索引。
- 系统 compact 或 390pt 及以下时，次级控制收进原生菜单/检查器 sheet；主操作保持 44pt。

## 3. 服务束（宿主注入，全量签名）

```swift
public struct CanvasEditorServices: Sendable {
    public init(
        documentStore: any CanvasDocumentStore,                     // 必需
        assetStore: (any CanvasAssetStore)? = nil,
        sourceService: (any CanvasSourceService)? = nil,
        sourceOpening: (any CanvasSourceOpening)? = nil,
        editorGateway: (any CanvasEditorGateway)? = nil,
        editorForkGateway: (any CanvasEditorForkGateway)? = nil,
        assistantGateway: (any CanvasAssistantGateway)? = nil,
        proposalGateway: (any CanvasAssistantProposalGateway)? = nil,
        previewProvider: (any CanvasPreviewProviding)? = nil,
        resourceLeasing: (any CanvasResourceLeasing)? = nil,
        stepExecutor: (any CanvasStepExecutor)? = nil,
        makeFlowRuntime: (@Sendable () -> FlowRuntimeService)? = nil,
        makeRunConfiguration: (
            @Sendable (_ snapshot: CanvasSnapshot, _ pageID: UUID, _ graph: FlowGraph)
                async throws -> FlowRunConfiguration
        )? = nil,
        labActions: [CanvasLabAction] = []
    )
}
```

宿主职责：
- `documentStore`：生产宿主接 FloeCore 适配；资格宿主直接用
  `InMemoryCanvasRepository` 或 `FileCanvasRepository`（显式 root）。
- `makeFlowRuntime`：宿主用自有 executor/journal/registry 构造
  `FlowRuntimeService`（见 FLOW_CONTRACT §2）。
- `makeRunConfiguration`：**Flow 运行的配置权威**。宿主提供真实
  `FlowRunIdentity`（owningTaskID、按宿主策略的环境）、宿主计算的
  `configurationDigest`、`runInputs`、`sourceDigests`。UI 校验
  identity.canvasID/revision/flowGraph 与实时文档一致后才 startRun；
  不从节点 parameters 推断权限，不自造配置哈希。
- 环境策略：纯本地/确定性图（native registry 变换、明确标注的离线
  测试节点）允许空环境按宿主离线资格策略运行；**customScript/customAPI
  节点必须真实宿主环境/jobs**，缺失时 UI 报可操作错误（ICH10），绝不
  回退宿主 Python/JS 解释器。
- `labActions`：宿主专属样本/测量动作，只出现在 Lab 菜单。
  `CanvasLabAction.group: CanvasLabActionGroup?` 可选分组（默认 nil）；
  `CanvasLabActionGroup(id:title:)` 为稳定身份与本地化标题。多项实验动作由
  宿主分组，避免长菜单中的底部动作不可达。

## 4. 新建场景 / 模板入口

`CanvasEditorView` 顶部工具栏 New 打开原生 sheet（accessibility ID
`floe.canvas.newScene`）。模板选项：Research / Compare Proposals /
Blank / Lab Sample（`floe.canvas.newScene.template.*`）。Lab Sample
明确标注“确定性样本——未调用模型”。

```swift
public enum CanvasSceneTemplate: String, CaseIterable, Sendable {
    case research, compare, blank, lab
}
public struct CanvasTemplateContent: Sendable {
    public var pageName: String
    public var nodes: [CanvasNodeSnapshot]
    public var connections: [CanvasConnectionSnapshot]
    public var flowGraph: FlowGraph?
    public var isDeterministicLabSample: Bool
}
public enum CanvasTemplateFactory {
    public static func make(
        _ template: CanvasSceneTemplate,
        name: String,
        configuration: CanvasEditorConfiguration
    ) -> CanvasTemplateContent
}
```

新建 sheet 还包含**目标描述**输入（ICQA03）：描述文本交给注入的宿主
AI/proposal 能力（`proposalGateway`/`assistantGateway`）生成**可编辑
初稿**；无 gateway 时清楚回退为场景模板/空白，界面明示“助手不可用”，
**绝不把名称文字伪装成 AI 生成**。

```swift
public enum CanvasSceneGoalComposer {
    public static func compose(
        description: String,
        template: CanvasSceneTemplate,
        store: CanvasEditorStore
    ) async -> CanvasTemplateContent   // 无 gateway 时回退模板默认内容
}
```

落地动作（一次文档批次，一个撤销单元）：`createPage(page, select: true)`
+（可选）`insertFlowGraph`。生成内容完全可编辑；**确定性 Lab 模板不声称
模型产出**。

## 5. Flow 运行 / 恢复 / 局部重跑（ICH07–09）

```swift
@MainActor public final class CanvasEditorStore {
    @discardableResult
    public func startFlowRun() async -> Bool
    public func attachFlowRun(runID: UUID, expectedGraphID: UUID) async -> Bool
    @discardableResult
    public func rerunFlowFromPreviousRun(
        previousRunID: UUID,
        previousGraph: FlowGraph,
        previousResult: FlowRunResult
    ) async -> Bool
    public func pauseFlowRun()
    public func resumeFlowRun()
    public func stepFlowRun()
    public func cancelFlowRun()
    public func bypassFlowNode(_ nodeID: UUID)
    public func toggleFlowBreakpoint(_ nodeID: UUID)
}
```

- `startFlowRun`：取活动图 → `makeRunConfiguration` → 校验 identity →
  编译 → `runtime.startRun` → 订阅真实事件流（先回放保留历史再转实时，
  无计时器、无伪造成功）。
- `attachFlowRun`：宿主从自己的 journal 列表给出 runID +
  expectedGraphID（journal 候选已绑定 run→canvas/graph）；UI 校验图属于
  当前页、run 存在于可信 runtime，然后监听真实事件。宿主用
  `FlowRunJournal` + `resumeRun` 恢复冻结定义（见 FLOW_CONTRACT §5）。
- `rerunFlowFromPreviousRun`：**局部重跑**。`FlowRerunPlanner.plan`
  基于旧 run 真实结果产出 seed；新 run 显式采纳有效结果，旧 run 记录
  保留；仅失效节点及下游闭包重新运行。禁止以全图重跑冒充。
- 迟到回调：runtime 记 `lateDeliveries`；UI 展示恢复清单，绝不把结果
  写进别的 run/文档（ICH09）。
- 运行保存（checkpoint）失败是真实状态：`CanvasFlowRunSnapshot.
  checkpointFailure`（宿主诊断）在调试器状态头以警告呈现，
  `FlowRuntimeEvent.checkpointFailed` 以失败样式入事件流——绝不把
  失败的保存显示为成功。
- 调试面板动作（pause/step/resume/bypass/cancel/断点）在
  `floe.canvas.debugger.*` 上可触达。

## 6. 编辑命令（宿主/测试可直接驱动）

```swift
public enum CanvasEditCommand: Sendable { /* 见 CanvasEditCommand.swift */ }
@MainActor public extension CanvasEditorStore {
    func apply(_ command: CanvasEditCommand) async   // 一次命令 = 一次提交
}
```

命令层（`CanvasCommandBatchBuilder.makeBatch(_:in:pageID:selection:configuration:)`
为纯函数）把意图译为单次 `CanvasDocumentBatch`；Flow 步骤创建/删除/
拷贝保证 graph+卡片+边同一批次，卡片删除不留下未绑定回退定义。

## 7. 测试注入（资格宿主与 UI 测试共用）

```swift
let snapshot = CanvasSnapshot(name: "ICH01", pages: [page])
let repository = InMemoryCanvasRepository(snapshot: snapshot)
let services = CanvasEditorServices(
    documentStore: repository,
    sourceService: mySourceService,
    makeFlowRuntime: { FlowRuntimeService(executor: myExecutor, journal: nil) },
    makeRunConfiguration: { snapshot, pageID, graph in
        FlowRunConfiguration(
            identity: FlowRunIdentity(
                canvasID: snapshot.id,
                canvasRevision: snapshot.revision,
                flowGraphID: graph.id,
                flowGraphRevision: graph.revision,
                environmentID: myEnvironmentOrEmpty),
            pageID: pageID,
            configurationDigest: myHostDigest)
    },
    labActions: [CanvasLabAction(id: "load500", title: "Load 500 cards", run: { store in
        try await store.apply(.createPage(name: "500", select: true))
    })])
let store = CanvasEditorStore(canvasID: snapshot.id, services: services)
let view = CanvasEditorView(canvasID: snapshot.id, services: services)
```

UI 测试用 `CanvasAccessibilityID`（§8）绑组件；服务缺失时断言可操作
缺失态而非崩溃。

## 7.1 编辑与视图状态边界

- 切页、选区、视口和场景跳转属于编辑器视图状态，不产生保存修订或撤销单元。
  新建页面/场景对象仍为一个文档批次；提交和撤销后的重载保留仍存在的当前页。
- 聚焦内容编辑器持有打开时的快照、页身份和预期修订。只有显式 Save 才等待
  提交；Cancel 丢弃未提交输入。保存失败保留编辑器与恢复草稿，不在消失回调
  偷偷保存，不用较新修订提交旧编辑结果。
- 来源卡手工内容编辑同时记录所用来源修订之后的本地修改标志。
  显式刷新保留批注和本地内容，产生可检查的更新分支；不覆盖手工修改。
- 恢复草稿保留原始端点（页或文档）、载荷、修订和 requestID；显式重定基
  才产生新 requestID。可信选区批次不提升成全局文档权限。
- Pencil 笔迹始终显示；工具切换只改变交互。采用独立的
  `PKCanvasViewDelegate` 转发对象，不能将 PKCanvasView 自身设为 delegate。
  世界坐标笔迹、lasso 和手绘转换经同一保存/撤销权威处理。
  结束回调会等待 PencilKit 发布最终绘图，禁止把临时空绘图保存为新笔迹；
  落笔时冻结页身份、修订及坐标变换。`finishInkGesture` 的可选 `pageID` /
  `expectedRevision` 和识别会话中的同名字段保证保存/转换不会写进另一页，
  也不会用较新修订覆盖旧编辑。
- UIKit 画布暴露有界可见元素。SwiftUI 根面板使用 contain，避免容器 ID
  覆盖子控件；窄屏主操作保持 44pt，其余归入原生菜单和 sheet。

## 7.2 专业流程定义编辑

流程卡片检查器提供“编辑流程定义”入口，打开显式 JSON 配置界面，可编辑
完整 `FlowGraph`：类型化端口、条件谓词、循环/批量体、变量、子图引用、
脚本/API 描述符及结构化参数。原生文本输入禁用智能引号、破折号替换和自动
改写，提供全选操作；只有 Save 提交，Cancel 丢弃输入。

`CanvasFlowGraphEditing.replaceDefinitionBatch(snapshot:pageID:definition:)`
保持图身份，自动推进图修订，在一个文档批次中同步新增/删除步骤的卡片绑定
和名称，保留既有卡片身份与布局。重复节点身份、锁定卡片、悬挂绑定或非法
结构整批拒绝。编辑器将打开时的快照/页/图身份保存在 `@State` 草稿，保存
携带原预期修订；远端更新只能产生可恢复冲突，不会改用最新修订覆盖。

此入口配置定义，不授予执行能力。运行仍需宿主提供配置与权限，经过严格
编译器；循环的保存结构检查与宿主运行上限分离，运行缺省上限仍为 100。
变参连线的界面校验与编译规则一致：变参输出必须进入集合或对应变参输入。

稳定标识：`floe.canvas.flow.editDefinition`、`.definitionEditor`、
`.definitionText`、`.selectDefinition`、`.saveDefinition`、`.definitionError`。

## 8. 稳定无障碍标识（ICH01–12）

`CanvasAccessibilityID`（`CanvasAccessibility.swift`）冻结，宿主/XCUI
直接用 rawValue：`floe.canvas.root`、`floe.canvas.board(.content/.ink)`、
`floe.canvas.toolbar.*`、`floe.canvas.sidebar.*`、`floe.canvas.inspector.*`、
`floe.canvas.newScene.*`、`floe.canvas.debugger.*`（含
`floe.canvas.debugger.placeOutputs`）、`floe.canvas.draft.*`、
P1c 新增 `floe.canvas.toolbar.flowGraph`。
标识不含文档 UUID；身份细节走 accessibility value。

## 8.1 保存/恢复幂等合同（ICH02/ICH11 必要项）

- `store.commit` 为每次手势保存稳定 `requestID` 与原始 `expectedRevision`。
- 失败转 `CanvasTransientDraft` 时**原样携带**该 requestID / expectedRevision /
  payload。`retryDraft(_:)` 以原 ID + 原 payload + 原修订重放：仓储 receipt
  查找先于 CAS，丢失确认（已提交后抛 I/O）重试只返回原回执，**不会**产生
  第二次 mutation / revision / undo 单元（一操作一撤销）。
- 真实 CAS 冲突：draft 标记 `didConflict=true`，两侧内容都可恢复；
  `rebaseDraft(_:)` 是唯一"明确新意图"路径——以**新** requestID 对当前
  修订提交。绝不自动换 ID 盲重放，也不静默重定基。
- 覆盖测试：`testLostAcknowledgementRetryIsIdempotent`、
  `testRealConflictKeepsBothSidesRecoverableAndRebasesExplicitly`、
  `testFailedCommitBecomesRecoverableDraft`。

## 9. 画板混合内容渲染与有界预览（P1c 新增）

`CanvasBoardView.drawNodeContent` 对每种内容渲染真实结构化内容（同一画板，
绝不每节点实例化重量级编辑器，绝不用扁平文本冒充）：

- richText → 原生 attributed runs（`CanvasBoardNodeContentRenderer.attributedString`
  映射 bold/italic/underline/strikethrough/颜色/链接，按 rect 截断）；
- table → 真实有界网格（表头加粗、行线、"更多…"指示，行数按高度截断）；
- code → 等宽行 + 语言 chip（行数按高度截断）；
- formula → 公共 DiagramKit 渲染器 `DiagramNativeRenderer`（复用，无平行
  渲染器）；有 `renderedAssetID` 时优先走宿主有界缩略图，无效源码诚实显示
  原文（聚焦公式编辑器负责标错）；
- media/PDF/渲染公式资产 → 宿主 `CanvasPreviewProviding` 门的有界缩略图。

预览生命周期归宿主共享的单一权威 `CanvasPreviewPipeline`
（`CanvasEditorStore.previews`，检查器与画板同一缓存/取消权威；画板侧
`CanvasBoardPreviewDemandController` 提供）：

- 仅可见资源注册需求（draw pass 内同步查缓存，未命中才登记）；
- key = assetID + contentHash + maxPixel（256pt 画板侧），同 key 合并；
- 每 draw pass 至多 `maxConcurrent`(6) 个新任务、队列 ≤ 32：无逐帧任务洪泛；
- 滚出视口的排队需求在启动前丢弃；布局/页面边界 `invalidateAll()` 取消
  in-flight（generation fence，迟到的过期结果绝不落板）；管线缓存保留，
  回滚即时；
- 宿主无法解析的 key 记为 failed（橙色可操作缺失态 + 检查器重关联），
  不会被逐帧重试；in-flight 期间只显示中性占位，绝不显示"缺失"。

PDF 一律经宿主预览服务门（`mimeType: application/pdf` 的
`CanvasPreviewRequest`）；UI 不引入无守卫的 PDF 渲染路径。资源动作可达：
节点上下文菜单含 Open Original（`sourceOpening` 注入时）与 Open Editor
（editor 引用节点）。

## 10. 画板可访问性（P1c 新增）

`CanvasBoardView.accessibilityElements` 由 `CanvasBoardAccessibilityBuilder`
合成**有界、仅可见**元素：节点/区域来自 prepared layout index 的可见查询 +
store O(1) 节点查找，frame 经 world→view→screen 变换；每类上限
`maxNodeElements`(120)/`maxRegionElements`(40)，万卡画板不会每次平移
生成万级对象。label = 标题或内容摘要（≤80 字符），选中态用
`.selected` trait；custom actions 走同一 store 管线（Select /
Open Inspector / Open Original / Open Editor）。Pencil/触摸手势路径不变。

## 11. 同页多 Flow 图选择（P1c 新增）

```swift
@MainActor public extension CanvasEditorStore {
    func selectFlowGraph(_ graphID: UUID)   // 校验属于当前页；调度重布线
}
```

- 页面可持多张图；`activeFlowGraphID` 决定画板布线/运行/调试对象。
- 选中原图卡片自动激活其绑定图（校验 graphID 属于本页）；任意 commit
  触发的重建保留仍存在的 active 图，**不再回退第一张**。
- 工具栏图选择菜单（>1 张图时出现，`floe.canvas.toolbar.flowGraph`，
  当前项打勾）；其他图的卡片保持普通可见内容，数据与状态不合并、不丢失。
- 画板只渲染 active 图的 flow 边——选择由该菜单明示。

## 12. 运行输出放置（run → compare → 保存/导出，P1c 新增，P1d 事务补全）

```swift
@MainActor public extension CanvasEditorStore {
    @discardableResult
    func placeFlowRunOutputsOnPage() async -> CanvasRunOutputPlacementResult?
    // placedCount / alreadyPlacedCount / unsupportedCount / committed(Bool, P1d 新增)
}

public extension CanvasEditorStore {
    enum CanvasCommitOutcome: Hashable, Sendable {
        case committed
        case pending(CanvasTransientDraft)
    }
    // retryDraft(_:) / rebaseDraft(_:) 现返回 CanvasCommitOutcome（@discardableResult，
    // 既有调用点源兼容）
}
```

- 调试器完成态出现 `floe.canvas.debugger.placeOutputs` 动作；真实
  `FlowRunResult.runOutputs` 1:1 映射为可编辑卡片（string/number/bool→text、
  table→table、asset→media、json→JSON code）。
- **批量（`.list`）输出完整保存（P1d）**：整张列表存为**一张可编辑 JSON
  code 卡**（合法 JSON、全值、精确 Unicode/转义、精确数字字面量——绝不
  `Int64(Double)` 重定型）；列表内嵌的**类型化 `.asset` 叶**另各生成一张
  media 卡，`runOutputKey = key + 结构路径`（如 `items[2][2]`）并带
  `floe.canvas.runOutputAssetPath` 结构化路径元数据——原生归档的类型化资产
  收集据此嵌入真实字节，**绝不扫描不透明 JSON/纯文本**。
  映射为纯函数 `CanvasRunOutputPlacement.prepareBatch`（同值树恒得同卡，
  重试/去重稳定）。
- **资源界限（显式、可恢复）**：列表嵌套 ≤64 层、JSON ≤512KB、asset 叶 ≤64
  张；超限给可操作 alert（`debuggerRunBatchTooLarge` en+zh），**运行结果
  原样保留，绝不截断或丢弃后谎报成功**。
- **异步围栏（P1d）**：放置前在**首个挂起点之前**捕获 canvas/run/graph/page
  身份；`runtime.result` 返回后（以及任何相关挂起之后）按捕获值**重验**
  selectedPageID / flowRunPageID / flowRun.runID / 目标页图归属，再触碰
  可变状态或提交。批次只命名**捕获的原始页**，绝不落到新选页面/run；
  手工内容仅以新卡保留，stale/未完成结果给可操作 alert。
- **真实提交结果（P1d）**：放置经唯一权威管线 `perform` 提交并消费
  `CanvasCommitOutcome`——**只有仓储确认的提交才计数/报成功**
  （`committed == true` 恰好一次撤销单元）；失败/丢失确认保留原
  batch/requestID/expectedRevision 为可恢复 draft（`committed == false`、
  `placedCount == 0`），绝不假成功。**重复按钮**发现同 run 的未决放置
  draft 时按**原 request 幂等重放**（receipt 查找先于 CAS），不产生重复
  输出；普通编辑/撤销/平移行为不变。
- **布局锚定（P1d）**：新卡锚定**目标页当前提交节点帧的并集**右侧
  （≥48pt 间隙），绝不使用 prepared layout index（可能过期或属前页），
  绝不覆盖既有卡。
- 去重：卡片以节点一等字段 `createdByRunID` + metadata
  `floe.canvas.runOutputKey` 标记；asset 卡以 `key+path` 参与
  run+outputkey+path 粒度去重；同一 run 重复放置只补缺失卡。
- 画板以 `tray.and.arrow.down.fill` 绿色徽章区分运行产出卡
  （`CanvasRunOutputStateBadge`）。

## 14. 平台门控与测试边界（P1d 新增）

- `CanvasEditorStore.swift` 整体 `#if canImport(UIKit)`：store 依赖
  仅 UIKit 的 `CanvasPreviewPipeline`，macOS 无头包（Core/Flow/Exchange/
  Layout）保持可编译；无 AppKit 回退。
- `Tests/FloeCanvasUITests` 全部文件同一 UIKit 门控；该目录由 Root 的
  iOS 宿主测试 target 整目录注册，断言在受支持的 iPad SDK 上**实际执行**。
  **macOS 无头包测试不验证 UI。**

## 13. 待验证清单（诚实边界，原 §9 顺延）

- 本阶段 CODE-ONLY：未跑 `swift build/test`、未启动模拟器；协调者
  注册 target 后批编译。P1c 新增测试（画板内容/需求生命周期/可访问性/
  多图选择/输出放置）与 P1d 新增测试
  （`CanvasRunOutputTransactionTests`：异步围栏/真实 CAS/丢失确认/
  重复按钮重放/全量 JSON+类型化资产/资源界限/重开持久）同批待跑，
  全部仅原生 iOS（UIKit 门控，见 §14）。
- Pencil 物理延迟不测；合成笔迹像素往返测试计划见
  `Tests/FloeCanvasUITests`（ICH05）。
- 真实模型/账户行为未测；provider 走宿主配置与错误回退。
- 大规模（500/3000/10000）样本经 `labActions` 注入，性能测量归宿主
  benchmark JSON（ICH12）；画板预览需求上限（6 并发/32 队列）与
  accessibility 元素上限（120 节点/40 区域）已按有界实现，实测归宿主
  资格宿主。
- 选择子集拷贝由 UI `CanvasSelectionDuplicator` 正确重映射自身子集
  （含端口声明/branch 输出口/body/变量宿主/操作数；
  subgraphTemplateID 保持引用不变）。Core `CanvasIdentityMapper.copyFlow`
  的整图重映射缺陷由 Root 在 Core 修复，UI 不依赖该方法做专业流程
  复制，两者互不冲突。

The editor exposes `isMutating`/`activeMutationCount` for real pending document commits and undo/redo. A visible saving indicator and disabled edit actions cover acknowledgement/reload/history refresh, including failures. Search results precede long page lists and dismiss the keyboard on selection. The editor snapshot follows the active page after reload for explicit exports without saving navigation to the production authority.

Card text and padding render in document coordinates, clipped to the card's
actual geometry. Preview zoom shows a bounded label rather than oversized body
text. Title height follows Dynamic Type. A visible viewport control offers fit,
zoom and actual size without adding a permanent side panel. Current-page list
position follows navigation, and search results use stable node identities.
These checks qualify the native component; the lab remains a prototype and does
not replace the production material/model/editor navigation.

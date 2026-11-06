# FloeCanvasFlow — 运行引擎合同（2026-11-04）

本文件冻结 FloeCanvasFlow 的公开 API、节点参数约定、宿主绑定入口与限制，
供资格宿主与 UI 直接接线。消费方只依赖本文件与
`FloeAgent/Modules/FloeCanvasKit/CONTRACT.md`（P0 冻结合同）。

- 源码：`FloeAgent/Modules/FloeCanvasKit/Sources/FloeCanvasFlow`
- 测试：`FloeAgent/Modules/FloeCanvasKit/Tests/FloeCanvasFlowTests`
- 依赖：仅 `FloeCanvasCore` + `FloeCanvasIntegration`（冻结模型）。Package
  target `FloeCanvasFlow` 依赖 Core+Integration；`FloeCanvasFlowTests` 依赖三者。
- 状态：Swift 6 对象编译和 **89 项 Flow 测试通过，0 失败/跳过**。
  原生宿主和界面验收另记；离线测试不代表真实模型/Linux jobs 已验证。

## 1. 模块构成

| 文件 | 职责 |
| --- | --- |
| `FlowSupport.swift` | 错误类型、SHA-256/RFC4122 v5 确定性 ID（CryptoKit）、JSONValue↔FlowValue 字面量转换（拒绝非有限数 1e400 等） |
| `FlowCompiler.swift` | 严格编译器：`FlowGraph → CompiledFlow`，DAG/结构化循环体分析、requiredInputs、变量写冲突、变参真实类型兼容 |
| `FlowEvaluation.swift` | 纯求值：变量帧词法链解析（同名不同类型遮蔽）、谓词/操作数、`.json` 通配投影规则 |
| `FlowConfiguration.swift` | `FlowRunConfiguration`、`FlowNativeStepRegistry`、`FlowCanvasBindingResolver`、`FlowSubgraphTemplate` |
| `FlowEvents.swift` | `FlowRuntimeEvent`、`FlowRunPhase`、`FlowEventStream`（真实 `.bufferingNewest(capacity)` 需求跟踪流） |
| `FlowJournal.swift` | `FlowRunJournal`（显式 root、tmp+fsync+rename 原子写、fail-closed 读、读取界限）、`FlowRunDefinitions` 冻结定义 |
| `FlowRuntime.swift` | `FlowRuntimeService` actor：调度、条件/循环/批量/子图、外部步骤、调试控制、resume/reconcile |
| `FlowCache.swift` | `FlowRevisionKey`、节点语义签名、失效传播、`FlowRerunPlanner`、`FlowRunSeed`、`FlowRunResult` |

## 2. 宿主接线最小路径

```swift
let registry = FlowNativeStepRegistry()
registry.register("math.add") { ctx in
    let a = ctx.inputs["a"], b = ctx.inputs["b"] // FlowValue
    // 纯确定性本地变换；返回 [portName: FlowValue]
}
let journal = try FlowRunJournal(root: qualificationRoot)   // 显式资格 root
let runtime = FlowRuntimeService(
    executor: hostExecutor,          // 宿主 CanvasStepExecutor（jobs 生命周期）
    journal: journal,                // 可 nil（纯内存资格）
    nativeRegistry: registry,
    bindingResolver: hostResolver,   // 可选，source 节点 canvasBinding 用
    subgraphTemplates: templates)     // 可选，子图模板定义

let compiled = try runtime.compile(graph)
let configuration = FlowRunConfiguration(
    identity: FlowRunIdentity(canvasID: canvas, canvasRevision: rev,
                              flowGraphID: graph.id, flowGraphRevision: graph.revision,
                              environmentID: env, owningTaskID: task),
    configurationDigest: hostConfigDigest)
// startRun 会先校验可达模板闭包：每个模板按同一严格规则编译、重复模板 ID
// 拒绝（不明确）、模板引用环以引用路径诊断（迭代 DFS，无无限栈）。
// 纯本地/确定性图允许 environmentID 为空；只有真正提交外部 script/API
// 步骤时才要求真实 environment + 宿主 owningTaskID，缺失则该步骤诚实失败，
// 绝不回退宿主解释器，executor 不会收到调用。
let runID = try await runtime.startRun(compiled: compiled, configuration: configuration)
for await event in runtime.events(runID: runID) { /* UI */ }
let result = await runtime.result(runID: runID)   // 终态后
```

调试控制：`pause/resume(runID:)`、`step(runID:)`（执行一个可调度单元后暂停）、
`setBreakpoints/addBreakpoint`、`bypass(nodeID:runID:)`、`retry(runID:nodeID:)`、
`cancel(runID:)`、`reconcile(runID:attemptID:)`、`externalStepDidFinish(runID:attemptID:)`
（宿主在已提交外部步骤完成时调用；提交返回 `.queued/.running` 时运行时将单元标记为
running 并登记 in-flight 坐标后立即返回调度循环，不挂起调度器；此通知到达时采纳结果
并继续调度）。`startRun`/`resumeRun` 在调度被接受后即返回 runID/状态，不阻塞整个
外部任务或全流程；宿主可随即 pause/step/debug。
**`pause(runID:)` 是 `async` 且持久确认**：它 await 检查点落盘后才返回——返回后即可
安全当作进程死亡点，`resumeRun` 确定性重建 paused 态（无分离 Task 竞争）。
对已经 `await` 调用的外部 actor 调用方源码兼容。

状态：`status(runID:) → RunStatusSnapshot(phase, completedSteps, totalUnits,
pendingReconciliations, failureCount, checkpointFailure?)`；`stepRecords(runID:)`；
`lateDeliveries(runID:)`；`result(runID:)`（仅终态）。
`retainedEvents(runID:)` 返回当前有界事件历史的只读快照，适用于绑定已结束运行；
不必等待一个已经结束的实时流。`failureCount` 包含已被批量节点吸收的失败步骤，
运行最终是否失败由未处理失败决定，两者不能混用。
`resumeRun(runID:)` 从 journal 冻结定义重建原编译图继续；
`resumeRun(runID:compiled:configuration:)` 由宿主自带同字节图时使用（digest 必须一致）。

## 3. 节点参数键（宿主/UI 建图约定）

通用：键值均为 `JSONValue` 结构化字面量，从不放自由代码串/凭据。

- 所有节点：`writeVariables` = `{ "输出端口名": "变量名" }`（成功后写最近可见声明帧，类型必须兼容）。
- transform：`nativeKey`（缺省时回退 `node.name`——**name 此时是执行语义的一部分，
  纳入失效签名**；显式 nativeKey 时改名/移动 position 不影响签名与缓存）。
- source：
  - `sourceKind = "constant"`，`literal` = 按唯一输出端口类型解码的结构化字面量；
  - `sourceKind = "canvasBinding"`，`bindingKey` = 宿主可信解析名（缺 resolver/解析失败 = 真实
    不可用结果）。宿主解析画布来源输入时优先使用 Core 的
    `CanvasFlowSourceBinding.parameters()`（键 `CanvasFlowSourceParameterKey.canvasID/pageID/
    nodeID/usedRevision` = `floecanvas.source.*`）；locator 是身份不是权限。
- condition：`branches`（冻结模型），按优先级；谓词操作数 `literal / variable(name) /
  nodeOutput(nodeID, portName)`；未命中分支输出 → 下游 `skipped(reason: branchNotTaken)`。
- loop：`maxIterations`（缺省 100，超出 `FlowRunConfiguration.maxLoopIterations` 编译失败）；
  `stopWhen` = `FlowLiterals.encodeToJSON(FlowPredicate)`；回边只能 body→loop 输入端口
  （carry，体内以变量 `carry.<端口名>` 读取；初始值 = 外部输入或 null）；
  体内变量 `iteration`（0 起）。
- batch：`items` 输入端口（list，必需）；`collectVariable`（缺省 `itemResult`，体内必须写入）；
  每 item 绑定 `item`/`itemIndex` 变量；单 item 失败记入 `failures` 输出（声明时）且不中断批次。
- subgraph：`subgraphTemplateID`（+ 宿主经 `FlowSubgraphTemplate` 提供图与 exposedPorts）；
  `inputBindings = { "暴露端口名": encodeToJSON(FlowOperand) }`（外层作用域求值）；
  模板内 output 节点 `resultKey` 映射到实例输出端口。
  **模板内允许嵌套结构化组合**（condition/loop/batch/subgraph）：
  每个实例以独立 call path 隔离变量帧、输出与 attempt 坐标；宿主 cap 仍对每个
  嵌套 loop 生效（默认 100）。模板引用环（含自引用）在 `startRun` 以引用路径
  诊断拒绝；同一模板 ID 重复定义同样在 `startRun` 诊断拒绝（注册时不 trap）。
  `FlowSubgraphTemplate` 为显式可综合 `Codable`（字段与初始化器不变、模板图
  原样编码、不含凭据/权限）——画布快照仅存 `subgraphTemplateID`，可复用模板
  定义的归档由宿主/Exchange 层另行负责。
- output：`resultKey`（可选；缺省按端口名收集全部输入）→ 进入 `FlowRunResult.runOutputs`。
- customScript / customAPI：只走宿主 `CanvasStepExecutor`（描述符随行，绝无本地执行）。

类型兼容（严格编译器执行，`.json` 为唯一通配/投影类型）：
普通→普通同型或任一端 `.json`；普通(T)→变参输入(E) 按元素 T→E；变参输出(T)→变参输入(E)
元素级 T→E（运行时把产出的 list 展开为各项）；变参输出(T)→普通(D) 要求 D ∈ {list, json}。
**单非变参输入端口多条边 = 编译错误**；变参输入零边 = 空 list（合法）。

保存层支持 `.json` 投影；其结构校验允许显式正循环上限，实际运行始终按
宿主 `FlowRunConfiguration.maxLoopIterations` 再编译检查（默认 100）。编辑
一个较大的声明上限不会自动扩大宿主执行权限或运行预算。

## 4. 外部步骤与幂等合同

- attemptID = RFC4122 v5(runID, nodeID, attempt, callPath, iteration)，确定性可重建。
  callPath 包含每一层循环/批量的 `@loop=N` / `@item=N`，不能只保留最内层
  iteration。不同祖先迭代中相同叶节点的 attempt 必须不同。恢复已有旧格式
  journal 时只对实际存在的旧路径保持兼容，不为新运行生成缺失祖先的坐标。
  **attempt 编号按执行坐标（node, callPath, iteration）惰性递增**：只统计已
  终结的先行 attempt——被打断的组合体（暂停/取消/未知提交）重入时未决坐标
  再生成同一 attemptID，宿主 `(runID, attemptID)` dedupe 因此保证不重复计费；
  显式 `retry` 在终结结果上铸造下一个编号（真正的新工作）。
- 提交前把 `FlowAttemptRecord`（含不可变 inputs）落盘；同 `(runID, attemptID)` 重入直接复用。
- 提交不可确认（抛错或 `.unknown`）→ `pendingAttempts` + `reconcileRequired` 事件 +
  phase `waitingReconcile`；只经 `queryStep` reconcile，**绝不自动重发**。
- cancel 用 runID+attemptID+generation 围栏；迟到回调记入 `lateDeliveries` 恢复清单，
  不触碰其它 run/文档。
- **恢复重建按完整执行坐标对齐台账**（P2d）：checkpoint 可能落后于 attempt 台账
  （pause 可持久化"提交前"视图）。`resumeRun` 对**每个非终结单元**以
  `(callPath, nodeID, iteration)` 精确匹配持久化 attempt（绝不止按 nodeID）：
  最新记录为终结 → 直接采纳（状态 + step 记录 + 变量写），**绝不再次 perform**；
  最新记录为未决（含 `.persisted`）→ 单元保持 running 并入 `pendingAttempts`
  先经 `queryStep` reconcile（绝不自动重发）；坐标无记录 → 陈旧 `.running`
  复位为 pending，重入再生成同一确定性 attemptID，宿主 dedupe 保证不重复计费。
  嵌套模板/循环/批量坐标因此永远不会收养其它实例/迭代的迟到回调。
- 宿主必须实现 P0 `CanvasStepExecutor` 语义（dedupe / unknown / queryRun / cancelRun）。

## 5. 持久化与恢复（`FlowRunJournal`）

布局：`<root>/runs/<runID>/{manifest.json, definitions.json, journal.jsonl,
checkpoint.json, attempts/<attemptID>.json}`。全部 tmp+fsync+rename(2)+目录 fsync；
JSONL 仅容忍最后无换行的半行；**损坏/越界一律 fail-closed 抛错**（不静默跳过，
防止凭损坏记录重发已计费工作）；读取有字节/条数界限。

- `definitions.json` 在任何 attempt 提交前写入并哈希绑定 manifest：冻结的
  FlowGraph + 子图模板**定义**（`FlowSubgraphTemplate`，显式 Codable）+
  runInputs + sourceDigests + configurationDigest。恢复用它重建**原**编译图，
  并采纳冻结模板定义（当前宿主注册表不覆盖）；当前画布改图/undo 裁剪不影响 run。
  归档导入不自动复活 run 权限——宿主须重新核对原 task/environment 执行能力。
  stepRecords/checkpoint 只进 run 仓库，**不进文档 undo**。
- checkpoint 含 loopCounters、batchProgress 和可选 activeBatchIndex：循环从中断迭代恢复，批量从
  已完成 item 之后恢复（已收集结果不回滚、不重交）。
- 恢复时先查宿主 reconcile；已完成的外部输出直接采纳，不产生第二次付费调用。
- **检查点写失败诚实语义**（P2d）：`checkpoint` 的 journal 写失败绝不发
  `checkpointSaved`；非终态 run 立即转入 `.failed`（发 `checkpointFailed` +
  `runFinished(.failed)`，manifest 尽力写 `failed`），停止后续调度——不再把
  状态当作可恢复；已提交 attempt 的单文件持久化在提交前已 fsync，仍可用于
  后续 `resumeRun` reconcile/收养。失败**不**代宿主取消任何在途工作
  （不调 `cancelRun`）；迟到回调仍按 reconcile 路径收养进持久记录。
  终态 run 的收尾检查点失败只追加 `checkpointFailed` 事件，不改变已持久结果。

## 6. 失效传播与局部重跑

- `FlowRerunPlanner.plan(previous:previousGraph:editedGraph:editedCompiled:configuration:)`：
  逐节点语义签名（kind、effectiveKey、ports、parameters、branches、script/api 描述符、
  子图模板 id/version、body 成员、writeVariables；**不含 position，显式 nativeKey 时
  不含显示 name**）+ runInputs/sourceDigests 变化 → 失效根集合，沿编辑后图的收缩
  DAG 做下游闭包。纯几何移动/显示改名（有 nativeKey）/不相干分支修改 → 已付费步骤
  判有效。配置摘要变化保守失效所有外部类节点（nativeKey transform 除外）。
- 新 run 经 `startRun(seed:)` 显式采纳有效结果；旧 run 记录保留；新 attempt 只为
  失效节点与显式 `retry` 生成。
- 应用输出前宿主必须核对 `result.isStale(currentCanvasRevision:)`：文档已前进时输出
  标记 stale/unapplied，**不得覆盖较新修订**。

## 7. 事件流（UI 绑定）

`events(runID:)` → `AsyncStream<FlowRuntimeEvent>`：先回放有界保留历史再转实时；
底层 `FlowEventStream` 为真实容量缓冲（`bufferingNewest`：慢消费者内存有界，
同键进度事件就地合并，终态事件必达）。观察者断开**不取消**服务持有的 run。
关键事件：`stepScheduled/Started/Completed/Failed/Skipped`、`conditionSelected`、
`loopIteration`、`batchProgress`、`breakpointHit`、`paused/steppingPaused/resumed`、
`reconcileRequired/reconciled`、`lateDeliveryRecorded`、`checkpointSaved`、
`checkpointFailed(runID:error:)`（P2d 新增：检查点写失败，绝不与 `checkpointSaved`
同写）、`runFinished`。

宿主/UI 绑定固定键（禁止自造拼写，见 Core API_READY）：
- 流程卡片 metadata：`CanvasFlowCardBinding`（`floe.flow.graphID` / `floe.flow.nodeID`；
  `init?(metadata:)` 解析、`applied(to:)` 写回；旧卡片缺键完全兼容）。
- 节点视觉样式：`CanvasVisualMetadataKeys`（`floeCanvas.visual.fillColor/strokeColor/
  strokeWidth/textColor`）——不要用裸 `fillColor`。
- 图持久化：宿主经 `DocumentBatch.editPage`/`insertFlowGraph`/`replaceFlowGraph`
  （要求 revision 严格递增）把 `FlowGraph` 存入 `page.flowGraphs`；**运行记录、检查点、
  attempt 永远不进文档状态/undo**，只存运行仓库。

## 8. 调试语义（诚实边界）

- pause 在单元边界停止调度新工作；已提交的外部步骤按提供方实际能力取消/查询，
  不承诺把远端推理冻结在中途。pause 的返回即持久确认（检查点已落盘）。
- step = 调度一个真实可运行单元后暂停；断点在单元执行前命中（**组合体内部
  同样生效**）；绕过 = 记 skipped 不执行，必需输入缺失的下游照常 skip 传播。
- 组合体（loop/batch/subgraph）被暂停/单步/断点打断时**保留已完成工作**：
  已成功的体内单元是既成事实不再重跑（不会重复计费），循环从被中断的迭代、
  批量从已完成 item 之后确定性恢复；挂在未决宿主 attempt 上的单元保持等待，
  由 `externalStepDidFinish`/reconcile 收养后继续。取消仍立即终止并以
  run+attempt+generation 围栏记录迟到回调。
- resume 持久接受继续意图后泵送调度；从断点继续只略过当前这次断点。
  单步在实际叶步骤完成后暂停，未决外部步骤完成前不调度后继。
  等待 reconcile 时的暂停同样持久化；查询得知完成后仍保持暂停，直到显式继续。
- 失败（非打断）走另一路径：循环/批量体重置并从失败点重入，终结坐标铸造新
  attempt（显式 retry 语义=新工作）。

## 9. 本阶段限制（诚实记录）

- 执行模型为确定性顺序调度：root 单元按拓扑序内联执行；外部步骤把单元标记为 running、
  登记 in-flight 坐标（无 continuation，调度器不挂起）并返回调度循环，宿主完成通知到达后
  采纳结果并继续调度。结构化体内外部步骤顺序执行（不做体内并行波）；`maxConcurrency`
  字段保留（未实现并行波，宿主不应把它当作已生效的并行设置）。
- 变量写冲突在编译期按"可并发调度"保守判定（互斥条件分支也视为并发；分支内变量
  建议各自 owner 作用域）。
- retry 覆盖 root 级单元；循环/批量体重置重入后，失败迭代/当前 item 内**已成功的外部
  单元会以新 attempt 重跑**（终结坐标推进编号）——打断（暂停/单步/断点）路径无此问题。
- 基准测试（3000/10000 轻量本地节点）只证明编译+调度量级，不等于真实 provider 或
  设备性能。

## 10. 已完成的消费方接线与兼容项

1. **新增事件 case**：`FlowRuntimeEvent.checkpointFailed(runID:error:)`。两处穷尽
   switch 已同步处理：
   - `FloeCanvasUI/CanvasFlowDebuggerView.swift` `eventTitle(_:)`：
     `case .checkpointFailed: return "checkpoint failed"`（可选 `eventIcon`
     加 `case .checkpointFailed: return "exclamationmark.triangle"`）。
   - `FloeCanvasExamples/FlowQualification.swift` `describe(_:)`：输出
     `{"event":"checkpointFailed","runID":"…","error":"…"}`。
2. **`pause(runID:)` 变为 `async`**：仓库内全部既有调用点（UI `CanvasEditorStore`、
   Examples 资格宿主、全部 Flow 测试）本就已 `await`，无需改动；仅新增调用方需 `await`。
3. **`RunStatusSnapshot` 新增 `checkpointFailure: String?`**（默认 nil，附加字段）：
   只读消费方无感；UI 可选择展示检查点失败原因。
4. 恢复语义变化（行为修复，非 API）：陈旧 checkpoint + 新台账记录时按坐标
   query/收养、零重复 perform；检查点写失败即 `.failed` 并停调度。若宿主依赖
   "检查点失败仍继续调度"的旧（错误）行为需知悉此修正。

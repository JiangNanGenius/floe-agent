# FloeCanvasLayout — P1a 布局合同（2026-11-03）

本文件冻结 `FloeCanvasLayout`（FloeCanvasKit P1a 阶段）的公开 API 与行为
合同，供原生画布 UI 编写者直接消费。输入为 P0 冻结的
`FloeCanvasCore` 快照 DTO；全部实现为无状态、纯函数式、Swift 6
`Sendable`、Foundation + 公开 FloeDiagramKit 组件，不持有任何编辑状态。

- 源码：`FloeAgent/Modules/FloeCanvasKit/Sources/FloeCanvasLayout/`
- 测试：`FloeAgent/Modules/FloeCanvasKit/Tests/FloeCanvasLayoutTests/`
- 状态：**CODE-READY（未编译）**。协调者负责把 target 加入
  `Package.swift` 并跑批量验证；本文件末尾记录代码就绪边界。
- 基线：根检出 `49222ba1edd558645900a18909aa2c80aad13d5b`（共享脏分支）。

## 1. 依赖（协调者接线）

`FloeCanvasLayout` import 三个公开产品：

| 依赖 | 产品 | 用途 |
| --- | --- | --- |
| 同包 | `FloeCanvasCore` | 冻结快照 DTO / Flow 数据契约 |
| FloeDiagramKit 包 | `FloeDiagramCore` | `DiagramRect/Point/Size` 几何 |
| FloeDiagramKit 包 | `FloeDiagramLayout` | `DiagramSpatialIndex`、`DiagramRouter` |

`Package.swift` 需由协调者新增（本 lane 不改动 manifest）：

```swift
// Package dependency:
.package(name: "FloeDiagramKit", path: "../FloeDiagramKit"),
// Target:
.target(
    name: "FloeCanvasLayout",
    dependencies: [
        "FloeCanvasCore",
        .product(name: "FloeDiagramCore", package: "FloeDiagramKit"),
        .product(name: "FloeDiagramLayout", package: "FloeDiagramKit"),
    ]),
.testTarget(
    name: "FloeCanvasLayoutTests",
    dependencies: ["FloeCanvasLayout", "FloeCanvasCore"]),
```

复用合同：空间索引、线路由与**整理拓扑**直接走 FloeDiagramKit **公开**
API（DTO 适配器把 canvas 节点映射为 `DiagramElement(kind: .rectangle/.group)` +
`DiagramConnection`；整理走 `DiagramLayoutEngine.layout(page:sizes:)`，见 §6）。
不改 DiagramKit、不共享其编辑器状态/撤销、不 import 其私有 UIKit 视图，
不重写其算法。生产 `CanvasAutoLayout` 语义由 §6 的锚定/锁保护规则对齐。

## 2. 几何适配（`CanvasLayoutGeometry`）

- `rect(from:)` / `frame(from:)`：center 锚点 ⇄ origin 矩形，**保号**
  （负坐标/负中心无翻转）。旋转通过 `rotatedBounds(_:rotationDegrees:)`
  折入轴对齐包围盒；空间索引与命中使用 AABB，精细旋转命中留给 UI。
- `innermostRegion(containing:among:)`：最小面积包含规则，平局取较小
  region UUID —— 重叠 region 的确定性归属。
- **坐标安全**：`safeWorldExtent = 1e15`（角点）+ `safeWorldSpan = 1e7`
  （宽高）。两者共同保证 DiagramKit 内部 Double→Int 格元转换与
  `(x1-x0+1)*(y1-y0+1)` 格数乘法永不溢出（每轴格数 ≤ 3.1e5，乘积
  ≤ ~1e11 ≪ Int64.max）。超出范围或超大有限尺寸的节点/region 记录
  `.coordinatesOutOfRange` 诊断并排除；越界/超大查询矩形返回空。
  测试覆盖巨大原点与巨大有限 extent 两种帧。

## 3. 页面索引（`CanvasPageLayoutIndex`）——核心消费入口

```swift
let index = try CanvasPageLayoutIndex(page: canvasPage, flowGraph: optionalFlowGraph)
```

一次快照修订构建一次（编辑后的显式边界）；之后平移/缩放查询只走空间
索引，成本 ∝ 可见候选数，**绝不 O(全 N) 扫描、绝不每 pan 重建**。

### 3.1 折叠与代理（重要语义）

- region 是几何包含容器；**group 是成员移动/锁定单位；命名 scene 只是
  视口相机**（`CanvasSceneRecord`，跳转/适配用 §7 transform，不复制内容）。
  三者不混用。
- 折叠隐藏成员节点，但**数据原样保留**（快照值语义，index 不修改输入）。
- 可见 chip：`CanvasPreparedRegion` 数组（expanded 容器 + 可见折叠 chip，
  按面积降序）。**被外层折叠隐藏的 inner region 不暴露**（不出现在
  `regions`/`regionFrames`/`collapsedRegionIDs`），其成员与连接全部归入
  最外层可见 chip。
- 嵌套折叠：成员的 `representativeID` = **最外层可见 collapsed 祖先**
  （实现上等价于"可见 collapsed 集合中的最内层包含"，因为可见 collapsed
  互不嵌套；重叠非嵌套时按最小面积+UUID 确定性选择）。
- 连接代理：端点解析到 representative 后，`source==destination` 且
  **至少一端真的被折叠**才隐藏（`hiddenConnectionCount` 计数）；
  未折叠合法自环保留。跨边界连接以 `CanvasProxyEdge` 保留
  kind/label，`isProxy=true`。
- 折叠 chip 纳入 `bounds`、视口查询与命中（`CanvasHitTarget.region`），
  全折叠页面也能 fit/命中 chip。

### 3.2 查询

| API | 语义 |
| --- | --- |
| `nodes` / `node(id:)` | 可见节点，渲染序（zIndex 升序，平局按源序） |
| `regions` / `region(id:)` / `visibleRegions(in:overscan:)` | 可见 region/chip |
| `visibleNodes(in:overscan:)` | 视口+外扩命中，渲染序 |
| `hitTest(_:zoom:screenTolerance:) -> CanvasHitTarget?` | 常数**屏幕**命中目标：`worldTolerance = screenTolerance / max(0.05, zoom)`（与 `CanvasViewportTransform.worldHitTolerance`、`CanvasFlowPortAnchor.hitBounds` 同一换算；屏幕偏移 ÷ zoom = 世界偏移），容差扩展 bounds 后节点优先、region 取最小包含；`screenTolerance == 0` 退化为精确点命中（空间探针仍非零）；点/zoom/容差非有限或 zoom ≤ 0 安全返回 nil |
| `lasso(_:)` | 相交即选（marquee） |
| `nearby(to:radius:)` | 中心距排序 |
| `nodeIDs(innermostInRegion:)` | **仅**最内层归属成员 |
| `nodeIDs(containedInRegion:)` | 几何包含**含嵌套内层成员**（外层局部整理用） |
| `nestedRegionIDs(of:)` / `descendantRegionIDs(of:)` | 直接/传递嵌套 region |
| `bounds` | 可见节点 ∪ 可见 region 帧并集 |

### 3.3 Flow 端口（可选 FlowGraph 输入）

- `flowPortAnchors`（按 **Flow node ID** 键控）、`flowDisplayFrames`、
  `flowDisplayRepresentatives`、`flowCardBindings` —— 见 §5。

## 4. 关系线路由（`CanvasEdgeRouter`）——永不执行

- `routeRelationEdges(index:) throws -> [CanvasRelationEdgeGeometry]`：
  把 index 的 proxyEdges 经 DTO 适配交给 `DiagramRouter`（曲线，自动
  正交避障回退），障碍只含可见节点；可见折叠 chip 作为容器端点。
- `visibleEdges(_:in:overscan:)`：UI 按视口+overscan 取可见边子集。
- 普通关系（`CanvasRelationKind`）**永不承载执行数据**；
  `CanvasRelationEdgeGeometry` 无从表达执行。昂贵路由检查
  `Task.checkCancellation`。

## 5. Flow 卡片绑定与 Flow 线（Root 已定案）

**绑定模型**：流程可视卡片是普通 `CanvasNodeSnapshot(kind: .generationTask)`。
Canvas node ID 与 Flow node ID **相互独立**，唯一联系是绑定。
Root 的 Core writer 将落地 `CanvasFlowCardBinding(graphID:nodeID:)` +
固定 metadata 键 `floe.flow.graphID` / `floe.flow.nodeID`。Core helper
未落盘前，`CanvasFlowCardBindingReader`（本模块唯一集中读点）按这两个
固定键兼容读取；Core API 落地后只改这一处。

- 显示帧解析（index 构建时）：绑定 card → **真实 canvas 节点帧**（折叠时
  → 可见 region chip 帧）；**未绑定** flow 节点 →
  `CanvasFlowEdgeLayout.defaultFrame(for:)`（200×100，中心 =
  `FlowNode.position`）。该 fallback 仅显示用，**不持久化、不制造第二套
  卡片**。
- 分组/折叠/锁定/选区一律以**真实 canvas 节点**为准；flow 线的 proxy
  沿绑定映射（`flowDisplayRepresentatives`），**不改写真实 flow 身份**：
  `CanvasFlowEdgeGeometry` 的 `sourceNodeID/destinationNodeID/
  sourcePortID/destinationPortID` 永远是真实值，`isProxy` 仅标记显示端点
  被 chip 化；运行状态不受影响。
- `routeEdges(flowGraph:nodeFrames:representatives:endpointFrames:)`：
  端口锚点按 **声明顺序**（`FlowNode.ports` 数组序，非 UUID 序）分布在
  leading/trailing 边缘；路由复用 `DiagramRouter` 结果后把起终点**安全
  调整到精确端口坐标**（首段平移 start 增量、末段平移 end 增量；单三次
  曲线即等价于从端口出发的外向控制点构造）；折叠端点在 chip 朝向对端
  的边界点接入。
- 畸形输入出诊断不 trap：重复 node/edge/port ID（先到先得）、
  端口方向错（离开 input / 进入 output → `.flowPortDirectionMismatch`）、
  端口类型不匹配（`.flowPortTypeMismatch`，**variadic 不等于任意类型**，
  混合类型同样诊断；Flow 编译器是执行权威）、缺帧
  （`.missingFlowNodeFrame`）；同一 chip 内部显示线隐藏并计数，真实自环
  保留。深度语义校验仍归 `FlowGraphValidator`，layout 不重复。

## 6. 局部整理（`CanvasPartialArrange`）——纯提案

```swift
let proposal = try CanvasPartialArrange.proposeArrangement(page:selection:direction:layerSpacing:itemSpacing:)
// proposal.placements: [UUID: CanvasGeometry.Point]（中心点提案，Core 稍后校验）
```

- **拓扑复用（主路径）**：选区经 DTO 适配为
  `DiagramPage(structure: .flow)`（可移动节点 = 无帧 rectangle，真实尺寸
  经 `sizes:` 传入；选区内视觉关系 = connections），交给公开
  `DiagramLayoutEngine.layout(page:sizes:)`（SwiftDagre rank 布局，
  **原生处理关系环**：greedy feedback arc breaking），方向经
  `metadata["direction"]` = LR/TB。引擎拒绝（`DiagramError`，如非有限
  输出）时才走**窄 fallback**：确定性 size-aware 分层（Kahn 最长路径 +
  视觉环单额外层 + cross 轴稳定序）。不因不能 import 根 FloeCore 而重写
  拓扑算法。
- 锚定：采用引擎公开 `arrangeEdits` 同款 delta 规则——结果平移使选区
  新包围盒中心 = 原包围盒中心；未选中/锁定节点永不移动。
- 整单拒绝（`CanvasLayoutError.arrangeRejected`，无任何部分放置）：
  空选区；选中节点所属 group 含锁定成员（`.groupLockedMember`）；
  group 未全选（`.partialGroupSelection`）；重复 node/group ID
  （`.duplicateNodeID`，先到先得）。执行环是 Flow 编译器职责。
- 区域整理：选区用 `index.nodeIDs(containedInRegion:)`（含嵌套成员）。

## 7. 视口变换（`CanvasViewportTransform`）

- 世界⇄视图可逆：`view = (world - center) * scale + viewCenter`；
  初始化校验有限性与范围（`scaleRange = 0.05...8`，比持久化
  `CanvasViewport` 的 0.3...3 更宽，供大画布 overview；宿主可自行收窄）。
- `visibleWorldRect(overscan:)`（screen-point overscan 经 scale 换算）、
  `worldHitTolerance(screenPoints:)`（常数屏幕命中目标 / zoom）、
  `panned(byViewDelta:)`、`zoomed(byFactor:anchorViewPoint:)`（锚点世界
  固定，越界返回 nil）、`fitting(_:padding:)`（支持 390pt 窄视口）。
- 精细旋转命中建议：UI 先用 `hitTest` 的容差 AABB 候选，再做旋转精确
  判定。

## 8. 层级细节（`CanvasLODPolicy`）

- 级别：overview(<0.12) / preview(<0.35) / standard(<0.75) / full。
- `allowsHeavyweightContent`：standard 及以上；overview/preview 对重型
  节点（media/pdf/web/editor 内容或 scene3D）出 `previewDemandIDs`
  占位需求；`representativeNodeIDs` 为确定性 stride 采样，上限 240。
  只描述需求，不做媒体加载实现。离屏内容本来就不进 `visibleNodes`。

## 9. 诊断（`CanvasLayoutIssue` / `CanvasLayoutError`）

`duplicateNodeID / degenerateNodeFrame / coordinatesOutOfRange /
duplicateConnectionID / danglingConnection / degenerateRegionFrame /
emptyArrangeSelection / partialGroupSelection / groupLockedMember /
missingFlowNodeFrame / malformedFlowLink / duplicateFlowNodeID /
duplicateFlowEdgeID / duplicateFlowPortID / flowPortDirectionMismatch /
flowPortTypeMismatch`。`CanvasLayoutError.invalidInput`（变换输入非法）、
`.arrangeRejected([issues])`（整理整单拒绝）。所有构建/路由/整理长操作
响应 `Task.checkCancellation()`。

## 10. 规模与诚实边界

- 测试含 **500 / 3000 / 10000** 生成网格夹具：精确可见计数（999×999
  视口恰 4 节点）、命中局部性、100 次 pan 查询可见数 ≤16、超大坐标
  (±1e6) 场景、构建取消。结构断言 + 宽松墙钟护栏（<10s 每档）。
- **未编译**（CODE-ONLY）：本 lane 不跑 `swift build/test`、不建私有
  副包绕过构建串行化。协调者接线后跑 `swift test
  --filter FloeCanvasLayoutTests` 才会得到真实编译/用例结果。
- 不声称模拟器/实机 FPS；CPU 计时只作退化护栏。
- 未覆盖（后续阶段）：缩略图/媒体解码生命周期（只出需求 ID）、
  真实 UI 命中旋转精判、Flow 运行时（本模块只有几何）。

## 11. 原始需求映射核对

| 需求 | 落点 |
| --- | --- |
| 复用 DiagramKit 空间索引/路由/拓扑（DTO 适配，不动 DiagramKit） | §1、§4、§5 |
| 预建索引、视口/hit/lasso/nearby 查询、near-visible 成本、显式边界重建 | §3 |
| group/region/scene 三概念分离；折叠保数据、proxy 路由、嵌套折叠 | §3.1 |
| Flow 线独立布局、端口几何、正交/曲线、畸形诊断、取消、可见子集 | §4、§5 |
| 局部整理：复用公开拓扑引擎、不动未选/锁定、group 锁定整拒、环原生处理+窄 fallback、锚定 | §6 |
| 视口变换可逆、有限校验、fit、390pt、常数屏幕命中 | §7 |
| LOD 分级、离屏无重内容、需求 ID 而非媒体实现 | §8 |
| 测试：旋转/负坐标/roundtrip、嵌套/重叠折叠+数据不变、proxy、锁定、环、取消、畸形、500/3000/10000 | 全部用例 |

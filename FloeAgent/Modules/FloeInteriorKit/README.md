# FloeInteriorKit

室内与建筑工程在 Floe 的二维／三维 CAD 核心上管理柜体、家具、楼层线稿、项目资料、料单、系统规划和分析。

在建筑工作区或从图纸打开的 CAD 工作区点「工程」即可建立或重开同一个工程。建立时先保存当前图形，再复制其原生包，核对修订号、内容摘要和模型摘要。工程目录按图形路径区分，家具库由当前工作区共用。工程编辑、撤销、保存和重开由 `BuildingEditorProjectSession` 和 `BuildingEditorView` 负责。

交付页通过 App 的 PDF 阅读器预览图纸，也可将已验证的原生二维或三维成果添加到空间。空间持有独立副本，同一交付重复添加时复用既有项目。原图与工程分别保存；移动或重命名原图会产生新的关联路径，旧工程仍可从原目录打开。二维每层有一张主线稿，进程结束会丢弃尚未确认的原生输入。

2026-11-14 的组件资格记录。Core42、资源15项和工程仓库31项分别实际通过。UI状态12项＋生命周期3项也已原生通过，native退出0；汇总器因警告穿插一条状态行而退出1，原始失败完整保留，并用精确方法名／源码／实际前端参数逐项对账。没有重跑或修改断言。此前123项及冻结UI03证据只覆盖各自源码。当时的资格范围未包含完整 App 和实机。详见[本轮证据](../../../docs/qualification/FLOE_BUILDING_PREDEVELOPMENT_20261113.zh-CN.md)与[基础联调门槛](../../../docs/design/building-project/integration-candidate-v1.json)。

## 独立工程入口

`BuildingEditorProjectHost` 和 `BuildingEditorView` 同时用于 App 的两个 CAD 入口及[独立 EditorHost](../../Qualification/Interior/EditorHost/)。宿主传入工程目录、资源库目录和文件交付动作。

```swift
BuildingEditorProjectHost(
    projectDirectory: authorizedProjectDirectory,
    assetLibraryDirectory: authorizedLibraryDirectory,
    launch: .open,
    hostActions: existingHostActions
)
```

由宿主解析并授权目录，直接呈现该根视图，不再套一层导航或 CAD 保存工具栏。原有 `BuildingWorkbenchView(projectDirectory:)` 仍可用于旧资料／参数工作台资格验证。

助手入口接收 `BuildingEditorToolContext`，由已有任务／授权服务绑定；上下文固定当前挂载，关闭或重新打开后失效。不要让旧助手通过可变的 session 指针取得重开后的文档。文件预览由宿主已有 PDF gate 承担；组件没有另建助手会话、权限系统或 PDF 渲染入口。

`BuildingEditorHostActions.registerIndependentCAD` 是导出成果添加到空间的宿主接口。交付页只对已验证的原生二维／三维包显示该操作；请求包含二维／三维类型、项目与成果身份、已读回的原生内容身份及不随工作副本路径变化的 `idempotencyKey`。宿主使用已有空间服务复制、核对副本并持久去重；不能把工程工作目录直接登记成可写共享项目。此接线及真实文件复制回归仍待原生运行，尚未验证主 App 入库。

- `FloeBuildingProject`：不可变代次、manifest 最后发布、真实 SQLite 快照、资源文件、编辑引用、工作副本与恢复；resume06实际31项通过，原生CAD联合仍未运行。
- `FloeBuildingAssets`：OBJ／MTL／贴图依赖入库、版本固定、比较和离线副本；resume05实际15项通过并复用，原生放置与渲染仍未运行。本地用户导入不因再分发权限未知而禁用。
- `FloeBuildingCAD`：同一原生 CAD 文档的建筑、19 板柜体、五视图、家具与导出适配；已有 29 项测试源码待运行。新增内部立面、装配／爆炸页和真实原生二维／三维成果路径已接入交付页，但没有原生验证证据。二维目前是纸面毫米的可编辑线稿，格式与关联损失写入回执。
- `FloeBuildingEditor`：统一工程保存、发布后连续编辑、显式恢复副本、房间 ID 关联与名称冲突处理、家具页和图纸交付页；11 项工程联合测试源码和 4 项宿主 UI 用例待运行。
- `FloeBuildingResources`：一份真实 CC0 扶手椅源包，供用户基础库和原生资格测试共用；资源 hash 已核对，原生准入／纹理／比例尚未验证。

新UI的12项交互状态测试和3项工作区生命周期测试已在macOS实际通过，原汇总器exit1与逐方法日志对账分别保留；不等于屏幕验收。语言从宿主的locale环境读取；原建筑视图嵌套三维时的重复撤销／重做、内层模型保存与整工程保存的语义冲突已定位。候选修正仍为私有补丁，主线CAD未改，须在独立iPad宿主中实际核验。

独立iOS检查已拆为 CAD29＋联合11 和界面4项两个 scheme；构建产物校验、分流日志及共享构建服务的资源／取消控制已准备，并通过合成规则检查，本轮没有新增原生执行。另补了两处私有生命周期保存 guard 候选，防止宿主负责整工程时内嵌编辑器仍在切页／后台直接提交。完整二维 CAD 入口仍须接入已有自有核心，并验证楼层／草图平面和导航恢复；画墙平面与二维导出不算这一项完成。

Source16私有代码候选继续增加楼层二维入口、稳定主线稿、撤销后只读刷新、标高核对、未确认输入跨页面保留和工程快照期间的编辑／离开围栏，并纳入两处生命周期guard。11个Swift文件只读语法解析与增量补丁应用检查通过；新增15项原生回归及1项界面用例尚未运行，未计入原40＋4冻结检查。当前每层一张主线稿；多线稿／图层、双向构件更新、完整楼层隔离和未确认输入的进程终止恢复继续保留为缺口。生产CAD和主App未改，仍为NOT_READY／NOT_CLOSED。

## 开发安排与复用

阶段按数据和技术依赖组织，全部需求保留，不要求用户再选择其中一条：

| 实施包 | 结果与复用边界 | 验证要求 |
| --- | --- | --- |
| 项目资料、版本与料单 | 直接复用主项目相同版本 GRDB／SQLite；实现原件归档、房间／来源关联、CSV 和结构化提取表、去重及版本采用 | 实际数据库重开、CAS／回滚、重复导入不加量、原件与出处保留；Office／OCR 使用已有服务适配 |
| 智能家居、图例与 AP 快估 | 类型化设备／端口／线路／点位；研究复用已有 EDA 符号及资源适配；提供有明确假设的快速覆盖计算 | 图例与连接有实际语义；错误／未知分别报告；热力图与输入版本、单位、预算和取消一致 |
| 光度与暖通分析边界 | 复用成熟光度解析与 Radiance／OpenStudio／EnergyPlus 等候选后端，保留自有 CAD；原生快速计算与外部精细任务分开 | 输入有依据、单位与坐标正确、结果真实可读回；参考引擎和适用范围分别验证 |
| 柜体与成套图纸 | 复用现有柜体核心和 Floe CAD 图纸服务；继续组合页、斜视、关联尺寸、板件／五金和正式图纸链 | 改尺寸后视图／标注／明细更新，人工补充保留；解决整柜源体预算，不能截断部件 |
| 资源库、材料与制造 | 复用已取得家具包、品牌官方数据与版本库；PackingSolver 等算法按固定来源接入 | 原生素材入库、依赖和尺度，封边／木纹／五金／开料规则，排板及旧工程版本固定分别验证 |
| 建筑、扫描与专业系统 | 复用原生建筑／CAD、RoomPlan／摄像头适配与成熟领域／格式内核；完整结构、机电、暖通范围保持 | 多房间校正、未知对象保留、系统计算／选型／协调及输入输出版本验证 |
| 独立工作台及 AI 接入 | 独立原生宿主先验证资料／料单／系统／计算操作，再交主线集成；AI 和 UI 使用同一项目服务 | 真实交互、保存重开、取消与失败恢复；后续主 App 入口、授权及原生 CAD 联合提交独立验收 |

当前源实现包：`FloeBuildingRecords`、`FloeBuildingSystems`、`FloeBuildingAnalysis`、`FloeBuildingWorkspace` 和 `FloeBuildingUI`。Records 与 Radio 子包由独立源码 owner 交接；首次 Systems 委派未交付源码，图例／连接图由协调者实现。Package.swift、分析、UI、总体集成与验收由协调者负责。共享仓库不切分支、不修改当前稳定版 App／版本／发布配置。

公共原生资源按主线协调的短窗口串行使用；不自行排锁。独立 macOS 对象编译／行为测试与 canonical iPad 宿主验收分开安排。源码就绪、编译通过、组件运行及 App 集成是不同阶段。

## 当前范围

- `FloeInteriorCore`：带版本的柜体配方、材料和构造规则；生成侧板、顶底板、背板、隔板、固定层板和可选平板门面。
- `InteriorResearchFixture`：生成 2400／2600 mm 两个方案的 JSON、原生 CAD 命令输入、图纸计划和设计尺寸 CSV。输出目录必须不存在，避免覆盖已有成果。
- [原生验证宿主](../../Qualification/Interior/)：通过公开的 `FloeCADDocument` 接口创建新的 CAD 草稿，执行草图、拉伸、变换、保存、重开、投影及文件导出。宿主与 App 分开，不修改用户已有工程。

领域坐标为 X 宽、Y 由前向后的深度、Z 高，单位 mm。`carcassDepthMM` 仅指柜身；门板厚度和前部间距另外计算。示例柜身深 600 mm，包含门板后整体深 620 mm。原生 CAD 适配遵循其地面坐标 `(u,v) → (x,0,-v)`、沿 +Y 拉伸的实际约定。

`InteriorDrawingFrame` 为立面、侧剖和水平投影提供显式方向及原点转换；原生适配器将水平轴传入 CAD 当前名为 `viewUp` 的 X 轴提示参数。两项新增领域测试已实际通过，三种样图的宽高、纸面位置和渲染复查也已完成。

当前唯一构造规则是 `between-sides-inset-back@1`：顶底板置于两侧板之间，背板内嵌于顶底板之间，层板固定。它没有涵盖全部柜体构造。板件 ID 使用配方／分格／层板的稳定身份；改宽度保留身份并更新尺寸与依赖指纹，材料版本变更单独更新清单依赖。已有板件数组必须与配方重新生成的快照一致，才允许派生 CAD 命令、图纸计划和 CSV。

第二轮新增两个纯值适配器，已在 `native-domain-resume01` 通过领域测试：

- `FurniturePlacementPlanner`：分开已知源单位和目录声明尺寸拟合；显式源朝向、底部锚点、楼层标高、安装高度和旋转，生成原生 CAD 坐标矩阵。资产／依赖文件哈希与版本参与失效判断。10 项领域测试通过；尚未执行原生几何导入、渲染或离线资源保存。
- `CabinetManufacturingPlanner`：按每块板的局部轴、封边尺寸规则、加工余量、木纹、实际库存／余料和修边生成完成／基材／开料尺寸及排板输入。缺项保留，不推断原板尺寸、锯缝或孔位。14 项领域测试通过；`readyForNesting` 只表示输入条件齐备，`manufacturingVerified` 仍为 false，尚未运行排板优化器或制造验证。

全部 28 项 QA 的 [12 条整体验收场景](../../../docs/design/building-project/closure-scenarios-v2.json)和 [8 个原生实现包](../../../docs/design/building-project/native-core-gap-v2.json)继续保留；没有以两个新适配器替代完整模块闭环。

## 运行

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path FloeAgent/Modules/FloeInteriorKit \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeInteriorKit/ios-ai-agent/Xcode27.2/core" \
  --jobs 6

"$HOME/Library/Caches/CodexBuild/FloeInteriorKit/ios-ai-agent/Xcode27.2/core/debug/InteriorResearchFixture" \
  Local/Artifacts/interior-component-research-20261112/a-new-fixture
```

原有柜体切片曾通过 13 项领域测试；本轮增加组合页和尺寸后，Core 共 18 项实际通过，包含尺寸／不重叠、稳定身份、材料依赖、坐标与视图方向、出图预算、未知制造条件、无效输入、重复身份、保存数据往返、失效快照和 CSV 转义。历史原生 CAD 结果与命令另见 [Qualification/Interior/README.md](../../Qualification/Interior/README.md)。其中三项通过使用了私有 CAD 单文件补丁，修复导入 STEP 实体的移动来源保存；该补丁未由本任务合入主线，组件测试不能替代完整 App 验收。新写的 19 板整柜装配投影测试尚未运行。

## 尚未完成

图纸计划包含外观、内部立面、剖面、爆炸、单件、清单、封边、加工及排板九类；计划不是这些生成器均已实现。现有 CAD 出图对每页来源数量有预算，复杂整柜出图需要继续设计和验证。

原有设计 CSV 是**设计完成尺寸**，不是开料尺寸。新增生产准备适配器的独立 CSV 分别列出设计面、完成、基材和开料尺寸，并保留工艺规则版本；纯值规则及 CSV 测试通过，尚未进行真实制造验证。封边／纹理、裁切余量、连接件、铰链／导轨、孔位、五金开合避让、排板和机床输出均未完成制造验证；`manufacturingVerified` 始终为 false。当前没有结构承载计算或可下发工厂的 CNC 数据。正式工程仍需跨资料数据库／CAD 文件的版本协调和可恢复提交。

完整需求继续保留在 [QA 记录](../../../docs/FLOE_BUILDING_EDITOR_REQUIREMENTS_QA_20261112.zh-CN.md)与[室内图纸深化方案](../../../docs/FLOE_INTERIOR_DRAWINGS_AND_CABINET_DETAILING_20261112.zh-CN.md)中。

后续来源与数据预研见[真实家具目录](../../../docs/FLOE_INTERIOR_FURNITURE_INTAKE_20261112.zh-CN.md)及[制造／排板内核](../../../docs/FLOE_INTERIOR_MANUFACTURING_REUSE_20261112.zh-CN.md)。它们没有作为本 Package 的依赖或 App 成品功能接入。

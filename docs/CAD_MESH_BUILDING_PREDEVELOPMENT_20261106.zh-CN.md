# CAD、Mesh、建筑与渲染预研发

本轮把精确实体／曲面和网格放入同一个原生 CAD 文档与工作台；建筑设计使用独立工作区，复用三维核心。实现与验证按用户确认的代表流程收口，不把全部专业精度或所有格式组合列为首轮门槛。没有修改版本号或发布设置。

后续按用户“不在 Linux 进行专业计算”和“不用做重验证”的要求，专业计算与离线渲染已改为设备端代码路径。当前接入与最小检查见[本机移植记录](qualification/cad-ondevice-professional-20261106/README.md)。下方 34 项原生测试、3 条界面流程及旧 pbrt 结果属于前一阶段的冻结证据，不能代表移植后的设备运行结果。

## 编辑器与入口

- 文件工作区直接打开 STL、OBJ、IGS／IGES、STEP／STP，建立独立的 `.floecad` 工作副本。原交换文件保留；无单位网格需要明确选择单位。IGES 中的精确开放曲面保留曲面身份。
- CAD 和 Mesh 共用视口、选择、对象树、历史、撤销与保存。混合建模提供孔、切除、凸台和布尔，并保存原网格与可修改的新增参数。精确输入需要明确接受派生网格结果，原精确体继续保留。
- 二维编辑器提供“转三维草图”和“建筑设计”入口。三维／建筑页面独立呈现，返回同一二维会话，保留完整二维草稿与撤销；不以所选图元替代整张草稿。
- CAD 工具栏提供“建筑设计”。建筑工作区包含平面、三维、图纸、楼层、构件、专业检查及离线渲染入口，共用原文档。

## SolidWorks 的参考方式

SolidWorks 在同一零件中区分标准 BRep、Mesh BRep 和图形网格；混合建模按表示类型使用相应操作。网格转标准 BRep 是单独工具，不能把三角面模型普遍解释为原始精确设计。Floe 因此保留输入类型、原始来源与新增特征，把派生结果的几何等级写进结果和历史。[SolidWorks 混合建模](https://blogs.solidworks.com/products/solidworks/hybrid-modeling/)、[网格转标准 BRep](https://help.solidworks.com/2025/English/SolidWorks/sldworks/r_convert_mesh_standard_brep_pm.htm)

二维导入采用可编辑草图与明确的平面、单位、参考点和对齐方式；正／顶／侧视图分别导入和对齐，不宣称从任意三视图自动恢复原参数模型。[SolidWorks DXF／DWG 导入](https://help.solidworks.com/2026/english/SolidWorks/slddxf/HIDD_IMPORT_PARTPAGE1.htm?id=17.23.4.4)、[草图对齐](https://help.solidworks.com/2026/english/solidworks/sldworks/t_Aligning_Sketches.htm)

## 复用项目与实际接入

| 部分 | 项目 | 本轮接入与边界 |
| --- | --- | --- |
| 精确几何 | 现有 OCCT 7.8.1 | 继续使用原内核；新增受限网格面缝合／片体缝合到闭合实体，保留来源和容差 |
| 网格布尔 | [Manifold 3.5.4](https://github.com/elalish/manifold/tree/ce50d78021d64507f89e8c9fc2c2e51018117857) | Apache-2.0，已接原生 C++ 桥；闭合网格结果，不冒充精确 BRep |
| 识别研究 | [MeshToFeatures](https://github.com/MasoudMiM/MeshToFeatures/tree/9d964cfa1e2600a5c30411112cf54933856eb4dc)、[Detessellate](https://github.com/DesignWeaver3D/Detessellate/tree/b55794a2012a7a5e079e0ca6f1d76048e5ecf788) | 参考分割、拟合和转换流程；MeshToFeatures 57 项核心测试通过。原生识别首轮限经核对的轴对齐长方体；没有嵌入 FreeCAD GUI |
| DWG／DXF | 现有 acadrust／CADEngine | 复用实际 DWG 读写；增加精确曲线移交和有界工程图导出。普通保存仍保留严格写后重读门槛 |
| 建筑交换 | [web-ifc 0.0.75](https://github.com/ThatOpen/engine_web-ifc/tree/ac5de14d320dde70515ce1619e48cfb6a5eaf51b) | 随 App 打包 WASM，在设备内生成、保存及重读 IFC4；层级、构件身份与实际三角面保持对应 |
| 信息要求 | web-ifc 与本机固定 IDS 子集 | 从重读 IFC 检查 Name 存在并导出 IDS；不宣称完整 IfcTester 或建筑法规校核 |
| 结构 | [PyNite](https://github.com/JWock82/Pynite) 单梁多项式的 Swift 移植 | 明确矩形等截面、简支／悬臂、材料与均布荷载；不嵌入 Python 或推断整栋结构 |
| 机电协调 | 既有原生 Manifold 3.5.4 | AABB 仅筛候选，实际实体交集报告体积；开放或失败网格明确未计算 |
| 离线渲染 | [three-gpu-pathtracer 0.0.24](https://github.com/gkjohnson/three-gpu-pathtracer/tree/3c6cda19d1788d7d93705eee704328e66823c845) | 固定依赖随 App 打包，在设备 WebGL2 上渐进路径追踪并导出 PNG |

原生 Manifold 切片、源码标识、许可证和逐文件摘要在 `FloeAgent/ThirdParty/FloeCADKit/Vendor/Manifold-SOURCE.json`。许可清单由现有生成器生成，读校验保持只读。非商用项目、AGPL 编辑器与未验证的源码入口没有作为本轮产品依赖。

## 建筑的首轮范围

平面图选中的直线先预览为墙中心线，明确单位、墙厚、墙高和未转换对象，再生成模型。支持直接画墙、尺寸编辑、楼层复制，以及墙、楼板、平屋顶、楼梯、柱、梁、门、窗、矩形空间、管线和风管。门窗在宿主墙中实际切除开洞。复杂双线墙、弧墙、任意屋面与全自动户型识别没有宣称完成。

IFC 交换使用保存时的实际 CAD 三角面，建立建筑／楼层／构件层级，保留标识；输出明确属于网格化 IFC，不将其称为原精确参数模型。施工图复用既有投影、剖面、标注及图纸导出。当前原生图纸每页最多 12 个源体；超限进入图纸工作区选择分组，不输出被截断的“整层图纸”。

国家／地区、州省／主管机构、用途分类、规范版本与采用日期分别记录；提供中国大陆、澳大利亚、美国、英国、欧洲、加拿大、新西兰、新加坡和自定义地区的配置与官方资料入口。可执行规则需要限值、条款和来源。缺少适用范围或规则时显示“未检查”，没有默认的全球合规通过。

官方规范的发布与地方采用不能混为一谈。例如澳大利亚 NSW 明确单列采用日期和本地变更，加拿大也要求向省／地区确认适用规范；英国资料入口对应英格兰，欧洲规范仍有国家参数。[NSW 采用说明](https://www.nsw.gov.au/housing-and-construction/compliance-and-regulation/how-to-comply-national-construction-code)、[加拿大官方规范入口](https://nrc.canada.ca/en/certifications-evaluations-standards/codes-canada/codes-canada-publications/national-building-code-canada-2025)、[英格兰 Approved Documents](https://www.gov.uk/government/collections/approved-documents)、[Eurocodes](https://eurocodes.jrc.ec.europa.eu/)

## 光影、动画与离线渲染

继续使用现有灯光、环境、PBR 材质、镜头／构件动画与 MP4 导出；新增随场景尺度变化的实时阴影范围和 Reveal 镜头预设。离线入口冻结当前几何、相机、实例和支持的材质，由本机服务拥有 WK 渲染任务，支持进度、取消、结果保存和冷重开验真。

离线首轮是高质量静帧 PNG。高级材质层、部分纹理及透明材质的转换差异显示在详情；缺体、场景预算截断和无效变换拒绝导出。无需下载计算环境；能力不足或任务中断会明确失败，不回退到 Linux。没有将离线路径追踪动画、降噪或全材质等价列为已完成能力。

前期真实 pbrt 静帧、左右方向、取消和旧输出拒绝的历史组件证据见[离线渲染资格记录](qualification/cad-offline-render-predev-20261106/README.md)。本机路径追踪器另行记录，不沿用 pbrt 的画质或执行证据。

## 文档与事务

新记录沿用原文档的单次撤销、版本检查、原子提交及失败恢复。建筑语义、几何和来源同时提交；几何失败保留旧模型。历史交错或已由其他 CAD 操作改写的建筑几何，不会被尺寸面板静默覆盖。设置类编辑保留现有几何。

已冻结的 `v1.7.79` 支持格式 8。本轮建筑、二维来源、混合建模及转换来源首次出现时才要求格式 9；普通文档保持原最低格式。未知嵌套数据保留为只读，防止旧写入器丢记录。建筑数据也进入命名版本恢复快照和差异查询。

## 移植前的验证边界

用户确认的 CAD／Mesh 六类代表流程、建筑单条贯穿流程、专业菜单简单调用、渲染／动画代表流程是本轮验收范围。未运行完整专业精度矩阵，也未使用用户的物理 iPhone。

- 已有组件证据：Manifold 原生库及 iPad 模拟器组件运行；Rust 68 项通过；bundled WASM 转移、命令、绘制与标注检查通过；独立 LibreDWG 读回通过。
- 建筑后端：真实 IFC 重读、PyNite 简支梁结果、IFC 几何碰撞与 IDS 调用通过。MEP 首次失败及修正后结果保留。
- 原生包与完整 App：Xcode 27.1、SDK 27.1、arm64 Simulator 的实际对象编译及测试包构建通过；使用唯一复用 iPad mini（iOS Simulator 27.0）运行定向测试。

| 已确认的验证项 | 代表覆盖 | 当前结果 |
| --- | --- | --- |
| STL／IGS／STEP 直接导入 | 实际交换文件、独立工作副本、单位、精确体／网格身份、保存重开 | 3 项 App 原生测试通过 |
| 网格孔／切除／凸台及混合布尔 | 实际 Manifold 运算、体积、原网格保留、精确工具保留 | 通过；参数历史的保存重开复测通过 |
| 简单识别、网格／片体转实体 | 实际 OCCT 闭合体检查、来源保留、长方体识别 | 通过；转换来源的保存重开复测通过 |
| 二维转草图／三视图对齐 | 精确线圆弧、单位、参考点及不同平面放置，单次撤销与来源保存 | 4 项原生测试通过 |
| 三维转 DWG／DXF／PDF、DWG 编辑 | 实际 OCCT 图纸、bundled WASM 写 DWG、改线、撤销重做、重读与转回原生草图；建筑 DXF／PDF | App 原生与独立 LibreDWG 重读通过 |
| 撤销／保存重开 | 建筑单次事务、失败回滚、版本恢复、草图来源；网格新增参数 | 通过；另有真实写入暂停后同路径重新接管的释放竞态回归通过 |
| 建筑贯穿流程 | 平面图→墙、楼板、门、梁→保存→冷重开→模型／实际矢量图纸→DXF 文件 | 原生 4 项与完整界面流程通过 |
| 建筑专业流程 | IFC 层级及实际几何重读、单梁、一次管墙碰撞、IDS 名称检查；专业菜单 | 后端组件与 App 菜单通过；Linux 任务实际调用未验证 |
| 光影／材质／动画／短片 | 选择真实模型，修改环境、阴影与粗糙度，应用后重开核值；相机关键帧与停止、HEVC MP4 编码重读 | 通过 |
| 离线高质量渲染 | 真实 CPU 路径追踪 PNG、方向、中断、旧输出拒绝、App 场景／回执验真 | macOS 渲染器组件及 App 定向测试通过；Linux 任务实际调用未验证 |

首次运行的 3 项网格保存失败、建筑生成按钮不可直接到达、项目检查首次空列表及后端 MEP 的首次失败均保留原始记录。修复没有跳过断言：网格使用仅统一正负零的稳定数值摘要，并加入非零数值／拓扑篡改反例；路由另外补了旧保存释放与晚到二维回调的会话边界。建筑检查改为由同一个结果载荷呈现弹窗，保留“缺少规则就未检查”的状态。

App 原生测试按唯一用例的最新结果统计为 **34 项通过、0 项失败、0 项跳过**。该统计复用未改路径的已通过结果，并单独重跑受修复影响的用例；不表示全仓测试或所有 CAD 组合已验收。工具参数枚举与能力表也已验证 DWG 可发现、Mesh 可新增混合特征，同时保留原始网格与精确体身份。

三条代表界面流程均通过。建筑样例含 7 个构件，保存冷重开后生成 4 视图、6,084 个真实矢量图元，并实际写出 713,894 字节的 DXF。最后的加强用例仅重编测试包，逐文件核对 App 的 5,508 个文件字节完全相同，复用已保存产物。各批原始失败和结果保留，最新去重结果见[验证清单](qualification/cad-unified-predev-20261106/results.json)。

实际页面：[建筑冷重开](qualification/cad-unified-predev-20261106/building-reopened.png)、[矢量出图](qualification/cad-unified-predev-20261106/building-vectors.png)、[DXF 生成](qualification/cad-unified-predev-20261106/building-dxf-ready.png)。本轮没有执行 Linux guest 中专业／离线渲染任务的完整运行，也没有版本升级、TestFlight 上传或生产发布。

测试入口：`CADDirectModelImportTests`、`CADHybridModelingTests`、`CADSketchTransferTests`、`CADUnifiedDrawingBridgeTests`、`CADBuildingWorkflowTests`、`CADBuildingWorkflowUITests`、`CADOfflineRenderTests`、`CADAnimationRevealTests`、`CADNativeStudyReceiptTests`，以及既有动画 MP4 读回和灯光／材质页面代表测试。

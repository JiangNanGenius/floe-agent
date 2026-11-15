# 建筑设计编辑器：成熟工作流调研与设计补充

日期：2026-11-12。范围：建筑项目、室内与家具、材质、柜体、自动设计、量尺采集与项目资料，以及它们与结构／机电／图纸的关系。本文是研究和设计建议，不是已实现或已验证的功能清单。

用户已确认的 19 项 QA 继续有效，见[需求 QA](FLOE_BUILDING_EDITOR_REQUIREMENTS_QA_20261112.zh-CN.md)。本轮新增明确要求包括家具库及摆放、各类材质库、墙体材料、柜子设计、自动贴材质和自动设计，以及量尺助手、手绘／零散信息的项目化整理。研究先于界面定稿，不用通用二维／三维 CAD 工具代替建筑专业工作流。

## 一、成熟项目提供的实际参照

| 参照 | 核对的工作流 | 对 Floe 的意义与复用边界 |
| --- | --- | --- |
| Archicad | 构件与楼层的联系、复合构造、材料优先级连接、参数对象、二维／三维表现及结构分析模型 | 学习领域关系与交互；不是可直接移入 App 的开源引擎 |
| Revit | 物理模型与结构分析模型的关系，机电连接器、系统和分析网络 | 结构及机电需要专门的数据和结果生命周期，不能直接对显示模型套结果面板 |
| Bonsai／IfcOpenShell | 原生 IFC 编制、空间／类型／几何／材料定义、图纸、结构与机电模块边界 | 用于 OpenBIM 语义与交换研究；Blender/Python 宿主与 iPad 原生实现不同，文档目录也不等于已验证的完整求解器 |
| Sweet Home 3D | 分类家具库、实例尺寸与位置编辑、平面摆放和三维同步、模型导入、工程内保存家具数据 | 参考室内布置的连续操作；不能据此承诺整栋结构或完整机电设计 |
| SketchUp | 面／组／构件的材质应用、纹理位置、比例与旋转、PBR 外观 | 参考选面、取样与贴材交互；建筑物理材料和构造层还需单独表达 |
| Blum Cabinet Configurator | 柜体与内部板件、门板与五金、碰撞、清单、制造图和 CAD 结果 | 定义柜体设计的完整操作对象；厂商五金数据与制造规则不能由通用长方体或默认孔位代替 |
| OpenCutList | 板件清单、封边、纹理方向、排板、标签和成本／重量报告 | 参考生产准备的数据和计算边界。它是 SketchUp 扩展，不能直接等同于独立柜体建模器 |

依据与边界：

- Archicad 的墙可关联归属楼层和上方楼层，支持复合结构，并可分别覆盖内、外及边缘表面；交接按构造材料优先级处理。[墙](https://help.graphisoft.com/AC/28/INT/_AC28_Help/040_ElementsVB/040_ElementsVB-6.htm)、[复合构造](https://help.graphisoft.com/AC/28/INT/_AC28_Help/025_Attributes/025_Attributes-26.htm)、[交接原则](https://help.graphisoft.com/AC/28/INT/_AC28_Help/040_ElementsVB/040_ElementsVB-271.htm)。
- 参数对象是库中定义的实例，放置后可修改实例参数；二维符号与三维精度可分别控制。[参数对象](https://help.graphisoft.com/AC/28/INT/_AC28_Help/040_ElementsVB/040_ElementsVB-278.htm)、[对象二维与三维表现](https://help.graphisoft.com/AC/28/INT/_AC28_Help/040_ElementsVB/040_ElementsVB-284.htm)。
- Archicad 与 Revit 的分析模型工作流并不相同，二者都说明物理形体与分析表达之间需要明确的联系及更新规则。[Archicad 分析模型](https://help.graphisoft.com/AC/28/INT/_AC28_Help/090_StructuralAnalyticalModelTools/090_StructuralAnalyticalModelTools-1.htm)、[Revit 分析模型自动化](https://help.autodesk.com/cloudhelp/2027/ENU/Revit-HaveYouTried/files/GUID-5C8E93DF-87C1-4378-A497-6355401B7002.htm)。
- Revit 的机电连接器区分专业域及物理／逻辑连接；分析网络用于流量和压降分析。[连接器](https://help.autodesk.com/cloudhelp/2027/ENU/Revit-API/files/Revit_API_Developers_Guide/Discipline_Specific_Functionality/MEP_Engineering/Revit_API_Revit_API_Developers_Guide_Discipline_Specific_Functionality_MEP_Engineering_Connectors_html.html)、[机电分析模型](https://help.autodesk.com/cloudhelp/2027/ENU/Revit-API/files/Revit_API_Developers_Guide/Discipline_Specific_Functionality/MEP_Engineering/Revit_API_Revit_API_Developers_Guide_Discipline_Specific_Functionality_MEP_Engineering_MEP_Analytical_Model_html.html)。
- Bonsai 稳定版文档把空间、类型、材料、出图、结构和机电分成不同领域；材料、出图及专业指南仍有未完成段落，本轮不从栏目名称推定完整功能或计算精度。[稳定版文档](https://docs.bonsaibim.org/studio/)、[材料定义](https://docs.bonsaibim.org/studio/guides/authoring/advanced_modeling/material_assignment.html)、[结构范围](https://docs.bonsaibim.org/studio/guides/structural_analysis/index.html)。
- Sweet Home 3D 可在家具分类库和已放置家具列表中管理对象，编辑尺寸、位置、朝向与材质；导入时明确方向和尺寸。[用户指南](https://www.sweethome3d.com/users-guide/)。
- SketchUp 提供面、组和构件的贴材以及纹理位置调整。[应用材质](https://help.sketchup.com/en/sketchup/applying-materials)、[纹理位置](https://help.sketchup.com/en/sketchup/positioning-textures)。
- Blum 的柜体流程包含内部设计、五金规划和制造准备；OpenCutList 的排板考虑锯切方式及木纹是否允许旋转。[Blum 柜体配置](https://www.blum.com/gb/en/services/planning-construction-product-selection/cabinet-configurator/)、[OpenCutList 排板](https://docs.opencutlist.org/features/parts/parts-list/cutting-diagrams)、[项目源码与范围](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension)。

以上是官方资料与部分源代码的查阅结果，本轮未安装、操作或复测这些外部产品。FreeCAD Wiki 被访问防护拒绝，因此没有把该页面作为已读的功能证据。

## 二、需要补充的建筑领域关系

下列是基于调研给出的 Floe 设计建议，尚不代表逐项实现完成：

1. **工程、场地、楼栋、楼层、轴网、房间与坐标。** 构件有明确的层级归属、标高和局部坐标；调整楼层高度时更新关联构件，而不是逐个移动网格。
2. **构件类型与实例。** 类型提供复合构造和默认尺寸；实例保存位置、局部尺寸、表面覆盖与参数差异。类型更新与实例覆盖有可检查的规则。
3. **约束与连接。** 墙端相交、墙板／屋顶交接、门窗宿主、楼梯连接楼层和洞口保持关系。几何改变后更新依赖，并保留失败前的工程。
4. **模型、视图与图纸。** 一个模型可有不同楼层切面、专业、比例、精度及显示规则；图纸上的尺寸、标签、详图和图签不是一张重新生成的图片。
5. **工程量与属性。** 数量来自相应构件和构造层，明确扣洞、净量／毛量、单位、材料和统计范围，并可追溯到对象。
6. **设计模型与专业分析。** 分析节点、连通关系、偏心、释放、支撑、荷载、网格和工况有独立表达；结果绑定输入版本。机电以设备端口、系统与分析网络为基础。
7. **装修与可制造部件。** 家具实例、饰面铺装和柜体板件均具有领域身份，不能都降为无属性的普通体。

## 三、材质库应包含什么

### 3.1 分开表示三类信息

| 信息 | 典型内容 | 影响 |
| --- | --- | --- |
| 工程材料与构造 | 混凝土、砌体、保温、石膏板、板材；厚度、物理参数及组合顺序 | 几何、剖面、算量与相应专业输入 |
| 饰面与铺装 | 内外墙漆、墙砖、地板、石材、吊顶、柜门饰面、封边；铺设区域、分缝、收口及方向 | 装修几何、排布、清单和局部外观 |
| 渲染外观 | 颜色、粗糙度、法线、金属度、透明与纹理贴图等 | 视口和渲染表现 |

采用上述区分后，换墙漆颜色只改变相应饰面／外观；修改承重层厚度则更新几何、工程量及相关分析状态。外观贴图不能提供缺失的工程物理参数。

材质库分类建议覆盖涂料、墙纸、瓷砖、石材、混凝土、砖、木材／木饰面、金属、玻璃、织物、皮革、塑料和室外铺装。构造组合与饰面方案作为可复用定义，保留来源、版本和所需贴图。

### 3.2 “自动贴”需要明确规则

| 目标 | 自动处理 | 必须保留的局部控制 |
| --- | --- | --- |
| 墙面 | 根据构件方向识别内侧／外侧／边缘，沿墙长和标高建立映射 | 单面覆盖、踢脚及墙裙、分段、洞口侧面、起铺点 |
| 地面 | 根据房间边界、实际板／砖尺寸和朝向生成铺装 | 直铺、错缝、人字等方式；缝宽、收边和裁切 |
| 柜门与板件 | 按板件局部轴设木纹方向、比例及饰面 | 正反面差异、封边、纹理连续及门板对纹 |
| 导入家具 | 优先保留原模型 UV 和分材质槽，允许局部替换 | 不覆盖用户已有 UV、比例与单面设置 |
| 非平面或复杂对象 | 选择适用投影或展开，预览接缝与拉伸 | 手动接缝、UV 编辑、失败与不支持提示 |

完整操作是“选定目标 → 识别表面角色 → 按实际单位映射 → 检查局部覆盖 → 应用可撤销变更”。不要把任意对象统一投影叫作完整自动贴材。

建议用以下代表操作验收：

- 只给客厅内墙换漆，外立面、门窗与局部保留面不变。
- 给地面铺 600 × 600 mm 的样例砖，尺寸改变后纹理不被拉伸，并显示起铺与裁切。
- 柜门改变宽高后仍保持板材纹理的实际尺度和既定方向。
- 弧墙、洞口侧面及转角保留正确表面归属；无法续接时显示需要调整。
- 改墙高、开门窗、保存重开和导出后，面材质仍绑定到正确的表面。

### 3.3 资产来源与离线使用

建议采用少量内置精选、在线按需下载、用户导入及个人收藏／自建库。工程内保存所用资产的确定版本与必要内容，不能依赖会变化或失效的远程图片链接。

ambientCG 和 Poly Haven 的官方资产许可均为 CC0，可作为候选来源；实际入库仍记录具体资产及其来源。[ambientCG 许可](https://docs.ambientcg.com/license/)、[Poly Haven 许可](https://polyhaven.com/license)。第三方家具按各自条目处理，不把“免费下载”自动视为可随 App 重分发。

材质包需要角色与色彩空间、物理尺度、法线方向、内容摘要及分辨率。PBR 渲染与资产交换以明确的通道语义为基础，可参照 [glTF 规范与扩展登记](https://registry.khronos.org/glTF/)。

资源预算必须区分磁盘压缩包和实际解码／GPU 内容。例如 4096² 的 RGBA8 单张解码图约 64 MiB，五张约 320 MiB，尚未计 mipmap 和其他对象；这是容量算例，不是当前设备的实测占用。因此浏览使用缩略图、交互使用适当分辨率，高清由任务按需加载。

### 3.4 图片生成材质的边界

Adobe 的 Image to Material 从图片生成多个 PBR 通道，并提供去光照等处理，可作为工作流参照。[官方说明](https://experienceleague.adobe.com/en/docs/substance-3d-sampler/using/filters/tools/image-to-material)。

Floe 的产品建议是提供图片导入、透视／光照调整、无缝化、通道预览和真实尺寸确认；模型生成的外观参数标注来源。此项不意味着采购、嵌入 Adobe 服务，也不从材质照片推断工程强度等物理参数。具体生成模型与运行方式仍需技术验证。

## 四、家具库与摆放

建议库对象包含定义和实例两个层次：

- **定义：** 分类、真实尺寸、单位、正面方向、枢轴、落地／挂墙／吸顶锚点、可替换材质槽、二维符号、不同精度模型、可编辑参数与来源。
- **实例：** 所属房间／楼层、位置、旋转、标高、参数覆盖、材质覆盖、锁定与分组。

分类应覆盖座椅沙发、桌几、床及床头柜、收纳柜、厨房、卫浴、家电、灯具和装饰。尺寸可参数化的定义与只能整体缩放的导入模型要区分。

摆放流程：选择／搜索 → 尺寸与朝向预览 → 平面或三维定位 → 吸附墙面／地面／工作台 → 旋转／镜像／对齐 → 检查相交及项目配置的净距 → 保存为实例。门扇、抽屉及活动家具需要运动包络，不能只检查关闭状态。

支持替换同类家具时保留合理的定位关系；不均匀缩放不应默默把厂商模型变为不存在的规格。符号、三维、清单和导出继续指向同一实例身份。

用户已追加量尺助手，实测空间作为建筑输入，设备路径与成果深度见 QA 18–19 及下文第十节。Apple RoomPlan 可提供房间构件的参数信息，并可用详细模型替换识别对象的包围盒。它不自动产生任意家具的真实制造模型。[RoomPlan](https://developer.apple.com/augmented-reality/roomplan/)、[模型替换 API](https://developer.apple.com/documentation/roomplan/capturedroom/modelprovider)。LiDAR 是相应自动采集路径的条件，不是普通建筑建模的前提。

## 五、柜体设计需要独立工作流

建议覆盖橱柜、衣柜、浴室柜、电视柜、书柜及定制收纳。基本流程为：

1. 选择柜型和放置区域，录入实际外形与安装间隙。
2. 设置箱体板、背板、门板、台面、踢脚和填充／收口板。
3. 划分柜格，添加竖隔板、层板、挂衣区、门板和抽屉。
4. 设置材质、板厚、木纹、封边及尺寸约束。
5. 选择有来源的五金定义，检查开合、抽拉、相邻门扇和管线避让。
6. 根据用户选择的成果深度生成视图、板件与五金清单、孔位／封边信息及排板。

“设计可视化”与“生产准备”是两种不同的成果深度。生产准备还需要加工余量、连接方式、锯缝、原板规格、纹理可旋转规则及厂商五金约束。缺少制造规则时保留未验证状态，不补一套通用孔位冒充具体五金。

板件与五金的参数修改应更新同一柜体装配、二维立面、三维和清单。柜体可保存为可复用定义，再放置到不同房间，实例参数与库定义分离。

## 六、自动设计应输出可编辑方案

根据用户的房间用途、人数、收纳／风格／预算偏好与已锁定对象，先形成明确设计任务。候选生成、约束检查、结果比较与可撤销应用分别可见。

建议的约束包括房间边界、门窗和通道、活动包络、家具尺寸、采光或插座等用户条件、柜体可制造参数及不可修改对象。缺少关键输入先提问；失败时解释冲突对象或约束。

常见任务的目标应当具体：

- 重新布置当前客厅的家具，保留锁定的电视墙和门窗。
- 对选定卧室提出两种家具与收纳方案，比较面积占用和可达空间。
- 为厨房生成协调的柜体布局，标出与水电接口或门窗的冲突。
- 按房间用途匹配墙、地、柜门材质，并检查真实尺度及木纹方向。
- 生成可继续编辑的构件和实例；效果图作为该方案的展示成果。

QA 17 已确认整屋室内设计沿用当前建筑平面，不隐式调整房间分隔和门窗。结构／机电结果随相关输入变化标记需更新，不由一张效果图宣称方案已通过专业检查。

## 七、Floe 当前可复用基础与缺口

本轮当前 checkout 为 `fd37a3ca5998dff5800cc5ae76583ba05c203dc2`；以下为实际源码核对，未重新运行其测试或 App 验收。

| 部分 | 已找到的代码 | 尚需补足的建筑语义或工作流 |
| --- | --- | --- |
| PBR 与材质库 | `CADMaterialService`、`MaterialKit`；库、整对象与面材质、贴图及导入导出 | 工程材料、构造层、饰面角色、建筑类型／实例覆盖 |
| 按实际尺寸贴图 | `CADMaterialUVMapping` 提供毫米尺度、旋转、偏移；支持原 UV、平面及盒投影 | 房间／构件面角色识别、铺装原点与方向、弧面和洞口的稳定规则 |
| 面材质身份 | `MaterialFaceBinding`、重新分配及未解析状态 | 建筑重建后的内外墙面、洞口、收口与饰面身份关联 |
| UV 与贴图编辑 | `CADUVService`、`CADUVRecord`、纹理导入／绘制和节点图 | 面向设计人员的自动入口、资产元信息及复杂案例验证 |
| 材质库更新 | 当前应用结果为独立快照，库更新不会隐式改变所有对象；显式重新应用才传播 | 类型联动、项目内批量替换与局部覆盖，保留既有语义 |
| 建筑模型 | 当前构件图、楼层、矩形空间、门窗宿主和部分几何事务 | 完整轴网／空间关系、复杂构造、家具实例、柜体装配、专业连接和关联视图 |
| 出图和专业服务 | 已有 CAD 投影、单梁、几何碰撞、IFC 及有限信息检查 | 成套专业图纸、整楼分析、机电网络、完整明细与规则体系 |

特别注意：当前 UV 编辑对单体三角形有明确预算，并通过源几何摘要拒绝失配；不能直接把任意大型家具资产塞入同一展开路径，或者几何变了还沿用旧 UV。大量家具还需实例化、精度切换和增量更新设计。

源码及现有测试入口：

- [材质服务](../FloeAgent/ThirdParty/FloeCADKit/Sources/FloeCAD/Floe/CADMaterialService.swift)。
- [材质与实际尺度映射](../FloeAgent/ThirdParty/FloeCADKit/Sources/FloeCAD/Kernel/MaterialKit.swift)。
- [面材质身份](../FloeAgent/ThirdParty/FloeCADKit/Sources/FloeCAD/Kernel/MaterialFaceBinding.swift)。
- [UV 数据与失配检查](../FloeAgent/ThirdParty/FloeCADKit/Sources/FloeCAD/Kernel/CADUVRecord.swift)。
- [材质及导出合同测试源码](../FloeAgent/ThirdParty/FloeCADKit/Tests/FloeCADKitTests/CADMaterialCoreTests.swift)。
- [UV、单面和显式重新应用测试源码](../FloeAgent/ThirdParty/FloeCADKit/Tests/FloeCADKitTests/CADMaterialUVConsistencyTests.swift)。

## 八、对界面 Demo 的修订

Demo 采用同一建筑项目下的专业工作区，而不是重复创建相互无关的编辑原件：

- **建筑：** 楼层／轴网／房间／构件树，类型与实例属性，平面、三维和剖切。
- **室内：** 家具库与实例、房间布置、饰面铺装、柜体工作流；仍显示同一空间和建筑上下文。
- **结构：** 物理与分析表达、工况、连接及输入检查、结果与过期状态。
- **机电：** 设备、端口、系统和路由，专业检查、网络结果与碰撞定位。
- **图纸与清单：** 关联视图、标注、图纸集及版本对应的统计；独立导出保持已确认范围。

中间保留主要画布；左侧按任务切换项目树／资产库，右侧显示当前对象属性与助手。常用操作随选择对象变化，不把全部专业按钮堆在同一工具栏。iPad 两侧可收起，小屏按需打开。

演示至少贯穿：选择房间 → 放置家具 → 检查摆放 → 按真实尺寸替换墙地材质 → 调整柜体 → 查看关联平面／三维与清单 → 独立导出。专业计算只以明确标注的样例展示流程，不能把模拟结果宣称为已运行的求解器。

## 九、新增边界的 QA 结果

1. QA 16 已确认柜体设计与生产准备都要：参数化柜体、板件、门抽、五金、开合避让、封边、孔位、拆单和排板；制造数据按明确的材料／五金规则生成。
2. QA 17 已确认自动设计覆盖整屋家具、灯具、材质和柜体，沿用当前建筑平面，不隐式调整房间分隔和门窗。
3. QA 18 已确认 LiDAR 自动扫描，普通摄像头引导点取墙角／门窗并用实测尺寸校准。
4. QA 19 已确认可校正的多房间／整层底稿，保留照片及设备能采集的点云／网格等实测参考。

其他常规设计按成熟工作流与既有项目约定推进，不再逐个按钮询问。界面 Demo 按上述结果制作；模拟的计算、制造规则和输出状态明确标注，不能计为原生 App 的功能验收。

## 十、量尺助手：采集、校正与建筑底稿

### 10.1 成熟流程与硬件边界

Apple RoomPlan 使用摄像头与 LiDAR 识别墙、门窗、开口和部分室内对象，输出带尺寸的参数化表示；系统提供扫描引导与即时识别反馈。[官方概览](https://developer.apple.com/augmented-reality/roomplan/)。多房间合并有官方示例，针对同一物理区域采集并要求有 LiDAR 的设备；这不代表任意独立扫描天然处于同一坐标系。[多扫描合并](https://developer.apple.com/documentation/roomplan/merging-multiple-scans-into-a-single-structure)。

magicplan 将 AR 墙角引导量尺与 LiDAR 墙面采集区分，包含闭合轮廓、设置层高、补录门窗、撤销和照片记录。[引导量尺流程](https://help.magicplan.app/scan-a-room-in-seconds-using-lidar)。其官方 FAQ 说明非 LiDAR 的受支持 iOS 设备可采用 Manual Scan，Auto-Scan 需要 LiDAR。[设备与扫描 FAQ](https://help.magicplan.app/magicplan-floor-plan-editor-faq)。这与 QA 18 的两条采集路径一致，是流程参照，不是调用该商业服务。

Canvas 当前官方文档跳转到 Twindo，说明 Scan To CAD 是将扫描转换为可编辑 CAD 的半自动服务，转换与扫描本身属于不同环节。[官方转换说明](https://www.twindo.com/support/what-is-scan-to-cad/)。因此 Floe 的“采集得到参考”与“生成可编辑建筑构件”也需分别交付和验证。本轮仅查阅官方资料，未操作或复测这些产品。

### 10.2 Floe 工作流建议

1. 从建筑项目打开“量尺助手”，选择已有楼层／房间或创建采集批次；展示设备实际支持的采集方式。
2. LiDAR 路径实时显示识别面和遗漏区域；普通摄像头路径引导设置地面、按顺序点取墙角并闭合、确定层高和门窗。
3. 保存采集来源、单位、坐标、原始尺寸和设备实际提供的照片／几何。可暂停与补扫；追踪丢失、坐标重置和重定位失败分别处理，不把旧坐标套进新会话。
4. 用卷尺或测距仪读数校准关键尺寸，保留采集值与校正值。标记未覆盖、遮挡和待复量项；不捏造统一精度等级或毫米级保证。
5. 对齐多房间，处理公共墙、相邻门洞、重叠及楼层归属。无法自动对齐时提供可检查的控制点与人工校正。
6. 生成可编辑底稿，核对房间轮廓、门窗宿主、标高、面积定义及构件对应。复杂或未识别部分保留参考几何，不强制转成错误构件。
7. 导入新建筑原件，或向当前项目提交有来源的增量修改。已有设计修改不由补扫覆盖；用户可比较、接受局部变化并撤销。

墙厚、复合构造、承重用途、材料强度及遮蔽管线通常不能仅由室内可见表面确定。缺失项作为待补信息，不能用扫描外观替代工程依据。扫描到的家具类别与包围范围也不等于柜体板件、孔位或厂商型号。

### 10.3 当前源码与验收缺口

当前工作树的 [SpatialMeasurementSession](../FloeAgent/Modules/FloeToolbox/Sources/FloeToolboxWorkbenches/SpatialMeasurementSession.swift) 与 [SpatialMeasurementWorkbench](../FloeAgent/Modules/FloeToolbox/Sources/FloeToolboxWorkbenches/SpatialMeasurementWorkbench.swift) 已有 AR 平面选点、长度／共面面积、跟踪状态及测量快照源码，并复用相机占用服务。本轮只做增量源码检查；这些文件有其他任务修改，没有改动或重新构建它们。

上述测量会话退出时释放点集，不是持久的房间项目。新增量尺助手需要独立保存采集批次、校正与坐标对应，并复用相机权限／占用生命周期；不能仅把现有长度测量改名。当前未找到 RoomPlan 采集集成，也没有新增扫描功能的真机证据。

验收需覆盖：两种设备路径、无权限／相机占用、非规则房间及遮挡、尺寸校准、相邻房间对齐、追踪中断及补扫、保存重开、原始参考追溯、建筑构件映射和独立导出读回。Simulator 可查状态和界面，真实采集精度需使用获准的兼容设备另验。

## 十一、项目资料与 AI 建模输入

用户明确要求手绘及零散房间信息可由项目 AI 接收，资料要易找、可持续复用。具体设计见[项目资料与 AI 输入方案](FLOE_BUILDING_EDITOR_PROJECT_INFORMATION_DESIGN_20261112.zh-CN.md)。该设计将扫描、手绘、照片和项目补充说明统一纳入来源登记，保留提取信息与构件的对应，并复用已有作品包、原生编辑和项目助手授权。

当前交互 Demo 展示室内与专业工作区流程，尚未加入真实量尺采集、项目资料入库和检索；新增研究不能视为这些功能已在 Demo 或原生 App 实现。

## 十二、进一步落实复用内核与资源来源

用户已明确继续使用 Floe 自有二维／三维核心，重点寻找建筑语义、视图派生和格式转换的成熟中间层，并增加内部表单／小数据库、家具导入与 AI 创建。新一轮已核对具体源文件、许可、版本和当前适配缺口，见[转换内核、数据库和家具资源蓝图](FLOE_BUILDING_EDITOR_CORE_REUSE_AND_DATA_BLUEPRINT_20261112.zh-CN.md)。其中包含 OpenPlan3D 的实际模块、IfcOpenShell 不同分支的构建限制、已有格式桥，以及 SQLite／8 类表单的设计原型；这些结论以新记录的日期、源码和证据范围为准。

## 十三、室内装修优先与工程图深化

用户明确以室内装修为主要场景，并追加柜体结构图和完整工程图纸需求。已增量核对 Chief Architect 的室内图纸／图纸集、LayOut 的引用与尺寸重连、Blum 的制造图／五金数据，以及 OpenCutList 的部件、爆炸视图和排板导出；具体来源、7 组图纸目录、模型修改联动和当前原生出图缺口见[室内施工图与柜体深化方案](FLOE_INTERIOR_DRAWINGS_AND_CABINET_DETAILING_20261112.zh-CN.md)。该优先级调整不取消原先确认的建筑、结构和机电目标，也不把目录设计当成新增出图功能验收。

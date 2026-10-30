# CAD／三维开源复用与许可证评估（2026-10-31）

目标是为原106项缺口选择可复用的成熟组件和可审计的小范围源码，不引入第二套几何内核、文档模型或执行框架。项目根许可证仍为MPL-2.0；本次不修改许可证、依赖锁或发布方式。

本报告区分“许可允许”“源码可构建线索”“本项目设备／模拟器编译”“功能运行”和“实际分发合规”。新候选本轮没有构建或运行，固定版本及许可证哈希只证明所查源码的来源。

## 复用方式

|方式|适用情况|采用原则|
|---|---|---|
|复用现有组件|已集成OCCT、OpenShape3D来源代码、Euclid、ShapeScript及系统框架|先扩现有桥接和服务；不要为已有功能引入新引擎。已集成不表示所有未暴露API都已验收。|
|链接独立库|边界明确的UV、细分、简化、动画求值或物理算法|优先保持上游独立库边界，固定版本及所选模块，避免复制零散文件后失去更新与依赖信息。|
|挑取小范围源码|独立且许可证清楚的算法、原生控件或适配器|逐文件保留版权／许可证、来源commit、修改记录及所需依赖；不能凭仓库主许可证推断全部子目录相同。|
|独立外部工具|重型桌面CAD、离线渲染、CAE／CFD／CAM|只作为明确的选定外部环境方案；不算纯本地iOS能力，也不因使用子进程就自动免除许可义务。|
|暂不直接引入|强copyleft与当前分发路线不符、许可证或依赖未闭合、桌面编辑器移植成本过大|保留候选和原因，不能改头换面把来源代码标为MPL。|

## 许可证判断边界

1. **MIT／BSD／Apache不是“拿来后删掉许可”。** 保留版权、许可文本与适用声明。Apache-2.0还需标明修改，并保留原有适用NOTICE；各候选的依赖和资产另查。[Apache-2.0原文](https://www.apache.org/licenses/LICENSE-2.0)
2. **MPL按文件保护。** 本项目自身受MPL覆盖文件的义务继续适用。MPL第3.3节在特定条件下允许Secondary License组合，因此不能笼统说“GPL与MPL绝对不能组合”；但那不等于可以维持当前发布方式而随意混入GPL编辑器代码。[MPL-2.0原文](https://www.mozilla.org/en-US/MPL/2.0/)
3. **LGPL可以有条件链接。** 静态链接不是自动禁止，但须按实际库版本和分发组合落实源码、修改声明和重新链接等适用条件。现有OCCT例外针对特定头文件生成的对象代码，不是对整个LGPL的豁免，更不能套用到其他库。[固定OCCT 7.8.1所附LGPL文本](https://github.com/Open-Cascade-SAS/OCCT/blob/bd2a789f15235755ce4d1a3b07379a2e062fdc2e/LICENSE_LGPL_21.txt)、[OCCT例外](https://github.com/Open-Cascade-SAS/OCCT/blob/bd2a789f15235755ce4d1a3b07379a2e062fdc2e/OCCT_LGPL_EXCEPTION.txt)
4. **少量复制和语言翻译也需检查来源许可。** “只拿几段”“改成Swift”或让AI按原实现翻译都不是自动免责条件。优先链接成熟库，必要的源码提取建立逐文件出处及修改记录。
5. **代码、依赖、数据分别核对。** 字体、HDRI、模型、示例动作和标准尺寸表不能从代码仓库许可证直接推断可用。标准名称支持也不等于获准复制某份标准出版物的数据。

现有OCCT已经记录静态库来源、源码和relink路线，见[本仓库记录](../FloeAgent/ThirdParty/FloeCADKit/OCCT_RELINK.md)；该记录也明确未声称完成独立重建或法律认证。本次不将它扩展为对新库／所有发布渠道的合规结论。

## 产品层仍需完成的工作

成熟算法能减少几何与数值实现，但不会自动生成本项目的稳定对象身份、选择、参数UI、AI工具、撤销、格式升级、保存重开和输出一致性。尤其是：

- UV打包库不等于接缝／岛编辑器；细分库不等于完整修改器栈或雕刻系统。
- 骨骼求值库不等于绑定／权重绘制／动作编辑器；物理引擎支持的模拟类别必须分别核实。
- CAD内核不等于孔／螺纹标准表、工程图语义与装配文档。
- 可播放的渲染输出不等于包含全部实体、材质和动画的完整产物。

这些适配继续使用既有FeatureGraph、文档事务、服务、任务和原子保存；不通过引入桌面项目而并行创建另一套产品状态。

## 可复用资产

Poly Haven的可下载HDRI／材质／模型与ambientCG资产可作为后续环境／材质候选，两者官方均说明CC0；本次没有下载或选入产品。Poly Haven网页其他内容、预览图及API使用条款需与资产本身分开核对，不能整站复制。[Poly Haven许可](https://polyhaven.com/license)、[ambientCG许可](https://docs.ambientcg.com/license/)

## 与原计划的关系

每项候选必须映射到[原106项剩余清单](FLOE_CAD_3D_REMAINING_PLAN_20261031.zh-CN.md)。候选被推荐仅表示值得进入独立资格验证，不把任何原缺口标为已完成，也不自动派发后续任务。

本轮审阅39组候选路线，并为全部106项建立[机器可读复用对照](FLOE_CAD_3D_REUSE_LICENSE_MATRIX.json)。每条保留固定源码、许可文本哈希、依赖、平台证据、未覆盖范围及原验收条件。分组内可有多个许可不同的项目，不把“39组”当作39个已经可用的库。

## 优先选择

|功能缺口|复用来源|许可证／方式|当前决定|
|---|---|---|---|
|精确曲线、扫掠／放样、补面、隐藏线和STEP装配|现有OCCT 7.8.1|LGPL-2.1＋OCCT例外；A|继续扩现有shim。HLR／XDE／PipeShell／Filling有现成接口与本地头文件／符号证据；每项新组合仍需运行验收。|
|二维CAD编辑与DWG／DXF保真门|现有acadrust 0.5.5|MPL-2.0；A|先扩现有引擎。ezdxf是MIT外部DXF选项，不能替代DWG；libdxfrw／LibreDWG不是无许可成本的捷径。|
|更多基准面／轴|OpenShape3D新增Swift组件|MIT；C|优先挑取ConstructionPlaneKit及必要Axis／菜单增量，再接Floe既有关联层。|
|自动UV展开／打包|xatlas|MIT；C/B|优先。核心xatlas.cpp／xatlas.h及其包含的xatlas_c.h可独立审计；不带示例查看器依赖。|
|网格简化与属性误差|meshoptimizer|MIT；B|优先验证simplifyWithAttributes和误差读回。边界／接缝／材质保真仍需应用约束及验收。|
|mesh-only稳健布尔|Manifold|Apache-2.0；B|优先候选，保持与精确BRep分级；不默认替换Euclid，更不替代OCCT。|
|装配关节与约束求解|OndselSolver|LGPL-2.1；B|优先独立C++库资格；不搬FreeCAD的Qt／Python文档层。尚无本项目iOS编译证明。|
|骨骼采样／混合／局部IK／skinning|ozz-animation|MIT；B|优先限定骨骼后端资格；权重绘制、rig与时间线编辑另由产品实现。|
|刚体、限定软体／布料|现有RealityKit，必要时Jolt|Apple SDK／MIT；A/B|先验证系统能力覆盖；Jolt为独立候选，同一模拟世界保持一个求值权威。流体／专业CFD不由此覆盖。|
|FBX骨骼／动画资产导入|ufbx|MIT OR Unlicense，选MIT；C/B|两个C源／头文件边界清楚，先比较最小导入闭包；不是FBX exporter或骨骼编辑器。|
|细分曲面求值|OpenSubdiv|Tomorrow Open Source Technology License 1.0；B|条件性候选，先CPU求值；保留实际LICENSE／NOTICE，不能简写成标准Apache-2.0。|
|时间轴、轨道UI、视频设置／音轨|已有Floe动画服务＋AVFoundation／ImageIO|既有源码许可与Apple SDK；A|优先接现有数据与事务。无需为这些UI功能默认引入Godot、Filament或FFmpeg。|

上表许可证对应固定材料：[OpenShape3D](https://github.com/laanlabs/OpenShape3D/blob/fd988cc2743cc38cd0d7f537503ea5b287af3d53/LICENSE)、[acadrust](https://github.com/hakanaktt/acadrust/blob/04916cad827dccf688071c57af5b700dd5b3471c/LICENSE)、[xatlas](https://github.com/jpcy/xatlas/blob/f700c7790aaa030e794b52ba7791a05c085faf0c/LICENSE)、[meshoptimizer](https://github.com/zeux/meshoptimizer/blob/9e1f07b159d3cb777f1c67ed31fc11fd117986f4/LICENSE.md)、[Manifold](https://github.com/elalish/manifold/blob/ce50d78021d64507f89e8c9fc2c2e51018117857/LICENSE)、[OndselSolver](https://github.com/FreeCAD/OndselSolver/blob/4be80eef02a3486cda0d78f3ccbb308d207a9639/LICENSE)、[ozz](https://github.com/guillaumeblanc/ozz-animation/blob/744eb9d99f606eda849acb0b1204f7a3dc20bca1/LICENSE.md)、[Jolt](https://github.com/jrouwe/JoltPhysics/blob/fb915d8a9c68c54159b4b626fb8d3739a410f8f0/LICENSE)、[ufbx](https://github.com/ufbx/ufbx/blob/5955c5c0b042ac2dc6f32955ab206aaec0620cfc/LICENSE)、[OpenSubdiv](https://github.com/PixarAnimationStudios/OpenSubdiv/blob/1d90921ea32b9dcae31d30b907cbacefc0c616bf/LICENSE.txt)。

## 哪些确实适合“取一点”

**第一优先是OpenShape3D的新原生几何工具。** 固定旧pin`30b3c7c`与新pin`fd988cc2`对照后，ConstructionPlaneKit是新增文件（约14KB），包含中面、三点、沿曲线、垂直、绕边倾斜、平行等坐标构造；ConstructionAxisKit和Construct菜单有增量。相反，所查SketchOffset、SketchTrimmer、SketchSolverBridge、FeatureRefs逐字节相同，重抄它们不会补齐原缺口。

取新构造器不代表关联datum完成：它接收世界坐标快照，曲线输入是polyline；Floe仍需保存源身份、表达式、解析和重建关系。只取公用计算及必要枚举／控件适配，不整份覆盖EditorViewModel或Session。[构造器固定源码](https://github.com/laanlabs/OpenShape3D/blob/fd988cc2743cc38cd0d7f537503ea5b287af3d53/openshape3d/Kernel/ConstructionPlaneKit.swift)

其他可以审计挑取的小切片包括xatlas核心文件、ufbx两个文件、libigl里依赖干净的MPL文件，以及MIT的Godot数学／ImGuizmo／ImSequencer部分。后两者的编辑器／控件依赖成本较高：Godot整套轨道编辑器依赖其Resource／Variant／对象和GUI系统，ImSequencer依赖ImGui；并不因此成为可直接嵌入SwiftUI的完整时间线。

OpenMesh／geometry-central可作为临时工作网格或特定算法候选；不让其接管第二份稳定对象、文档与撤销状态。Instant Meshes的BSD代码和SculptGL的MIT代码在许可上允许进一步审计抽取，但前者是桌面应用，后者是已停止维护的WebGL／JS应用；本轮仅作研究／后续移植候选，不因许可证宽松就直接搬入。

## 需保留条件或本轮不选入

|候选|评估结论|
|---|---|
|FreeCAD／SheetMetal|所查PartDesign Hole、PlaneGCS、TechDraw部分、CAM部分可按LGPL边界继续评估；SheetMetalCmd／Text等文件是GPL，NewUnfolder的LGPL头不能消除其GPL导入依赖。根LICENSE不能代表全部工作台。|
|TiGL|Gordon／网络面代码为Apache-2.0，但实际路径涉及LGPL GEOMAlgo及TiXI／Boost／OCCT。先用现有单辅助导轨扫掠；任意多轨后端另做依赖和7.8.1兼容资格。|
|OpenUSD／SwiftUsd|当前OpenUSD实际是Tomorrow许可，SwiftUsd wrapper是Apache-2.0；预构建XCFramework及依赖另审。官方有iOS路线，但iOS与桌面模块覆盖不同，本项目未构建。保留场景／动画交换候选，不替换Floe文档权威。|
|Filament|Apache-2.0及官方iOS路线；是实时渲染器，不是离线路径追踪。仅在现有RealityKit出现具体阻碍时评估，第三方／host工具／格式插件逐项审。|
|Blender／独立Cycles|Blender整体发行与所查编辑器源受GPL约束，本次不抽取时间线／动画／几何节点代码；独立Cycles模块是Apache-2.0，可以另评。其依赖、Metal路径和资源预算未证明适合iOS，不能因使用Metal就当作iPad可用。|
|Chrono／FCL／Bullet／Assimp|分别是动力学、碰撞距离、物理备选、多格式导入候选；核心许可较宽松，但选定模块和依赖尚需闭合。只在对应缺口需要时采用，不同时堆入同类引擎。|
|libigl／CGAL／MeshLab|libigl有MPL核心和GPL模块；CGAL按包分GPL／LGPL。GPL部分本轮未选入，而非宣称与MPL普遍不能组合。MeshLab的桌面Qt／GPL应用代码不作为小库直接搬入。|
|Geogram默认配置|核心BSD不覆盖默认打开的HLBFGS非商业、TetGen AGPL、Triangle商业安排等条件。默认整包不选；若未来采用，应先关闭／替换受限组件并审计实际调用闭包。|
|MeshLib所查版本|实际为非商业评估／教育许可，不能按MIT／Apache自由修改和再分发。没有另行授权时不进入产品；公开仓库不等于开放源代码许可。|
|FFmpeg|默认LGPL路径、GPL开关／组件、version3和nonfree配置分别处理；不能只标LGPL。现有AVFoundation足以优先评估主要音视频需求，FFmpeg不解决ARView后台出帧。|
|CadQuery／build123d／cq_warehouse／ezdxf|所查根许可分别为Apache-2.0／MIT，但Python／OCP／OCCT／wheel闭包和标准数据另审。作为明确选定环境的成熟工具或限定数据／helper来源，不等于已可原生嵌入iOS。|
|Gmsh／CalculiX／OpenFOAM／CAMotics|成熟专业外部工具候选，有相应GPL与依赖条件；Gmsh还有官方iOS历史／构建路线及商业选项，但本次镜像到官方commit身份未完全闭合，不批准直接链接。不能把这些项目一概写成桌面only，也不能声称已满足本地iPad。|
|OpenCAMLib|LGPL成熟刀位算法是有限原生候选；尚未构建。所查3轴刀位／仿真能力不能抵销原计划的多轴车铣目标，FreeCAD CAM完整工作流与后处理器还需另审。|

以上各项的固定源码／许可证URL、SHA256、具体API、依赖条件和证据等级见[候选矩阵](FLOE_CAD_3D_REUSE_LICENSE_MATRIX.json)。对Gmsh镜像来源、历史iOS脚本、仅portable C++声明等限制保留原记录，不将其升级成Floe构建成功。

## 下一步建议与验收

先完成已有源码的集成边界与资格，再按需做独立小批：OpenShape基准几何切片；xatlas／meshoptimizer／Manifold；OndselSolver；骨骼／物理确需时ozz／Jolt／ufbx；之后才是细分、复杂场景交换和专业后端。时间轴与视频设置可先扩既有服务，不依赖这些所有库先完成。

每批固定实际版本、模块／feature flags、源码与通知材料，再验证device＋arm64 simulator、真实API与取消／内存、稳定ID、撤销／重开、格式和独立输出读回。需静态LGPL等额外材料时，跟随实际链接组合交付；许可或平台未闭合的候选继续保持待验证。本次仅评估，不安装／集成／编译／分发这些候选，不为填表预排后续worker。

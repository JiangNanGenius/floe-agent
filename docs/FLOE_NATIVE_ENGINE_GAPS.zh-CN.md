# Floe 现有与在研能力盘点及后续计划

更新：2026-11-08。[English](FLOE_NATIVE_ENGINE_GAPS.md)

本计划按实际源码、原研发表和当前收尾证据重排。范围是需要复杂 iPad 交互的工作台，或在解释执行环境中代价高的计算。简单脚本、普通统计和一次性出图沿用 Python；已有引擎不重复建设。新增源码必须保留自有 MPL-2.0，并满足各第三方的实际许可。

初始调查基于 `60f803afae967905529cbb01e0c8229ae0b92cdb` 与当日共享工作树；现有实现基线更新为主线检查点 `9b016097d7169cdf864ca25ccbc4f280b0d07a6b`。数据分析源码、两份测试及资格包已纳入该检查点，逐文件摘要与原资格结果一致。LaTeX 等独立在研工作尚未全部进入该提交。下表的实现与证据不等同于公开安装包；在研目标也不是完成时间承诺。

同日进展：主线第 25 次本地迭代完成实际 App／Unit／UI 编译，保存了跨批次 84 个不同用例的通过证据；最后两项自动化 UI 夹具失败后，同一 App 的相关界面由实际操作复核，最终定位修改未重编运行，不记作自动化通过。独立数据分析的 18 项不重复计入 84 项。详见[主线验证记录](qualification/next-round-integration-20261108/README.md)。本线程独立重跑许可清单检查已通过，原包锁不同步失败保留；这不等于 L01 的 GPL 组合问题已解决。

## 1 执行路径先分清

| 路径 | 当前例子 | 对后续计划的影响 |
| --- | --- | --- |
| Apple 原生代码／系统框架 | OCCT、Manifold、Rust 加工、Rapier、Netgen、MFEM、Avogadro/UFF、AVFoundation、VideoToolbox、Core Image、Metal、Core ML | 已有服务优先复用；不为同一能力再移植一套引擎。 |
| App 内置 WebKit／JavaScript／WASM／WebGL | Kiri:Moto 切片、部分格式与化学桥、部分离线渲染 | 已是本机执行，但不统称原生 C++；WebGL 的 GPU 工作也不能按 Linux CPU 模拟估算。性能决定是否更换内核。 |
| 本地解释执行 Linux 客体 | 经 `exec.shell` 调用 Python、科学 worker 和命令行 | NumPy 等底层虽有 C／Fortran，放在该客体内仍有 CPU 模拟开销；是重计算对照的重点。 |
| 用户配置的外部环境／服务 | 科学计算、远程命令、模型服务 | 不承受本地客体模拟开销；保留正常配置和调用，不以开发侧没有账号实测为由禁用。 |

依据：[执行路由](../FloeAgent/Sources/FloeTools/CapabilityExecutionRouter.swift)、[ARM64 引擎](../FloeAgent/ThirdParty/ARM64EMU/README.md)、[切片实际宿主](../FloeAgent/FloeApp/Space/Printing/NativePrintBackend.swift)。NumPy 的数组运算大量使用预编译 C，[官方说明](https://numpy.org/doc/stable/user/whatisnumpy.html)；本计划不把“用了 Python”直接等同于慢。

## 2 现有实现与在研完成后的基线

| 领域 | 已有实现 | 正在收尾或原范围内的工作 | 后续定位 |
| --- | --- | --- | --- |
| Office／PDF／手记 | 现有编辑、导出、受保护 PDF、文件与持久化服务 | 复用当前手记／文档和结果回流；保持原编辑状态与权限 | 基础能力，不另建文档引擎。 |
| 图示／混合画布／交互内容 | 原生图示、混合画布、模板／流程、保存及 AI 接口 | 主线修整绘图输入、预览和工具可达性 | 不再把画布、图示或基本矢量编辑列为全新缺口。 |
| 图片／绘画／视频 | 媒体 v2 编辑与时间线；107 条目录中 52 条在本地命令集；通用 `video.interpolate`／`video.superResolution` 已有原生服务，图片已有移背景后端 | N03／N11／N12／N13 的界面、输入、选区／素材／结果和模型接线；55 条目录项仍需逐项区分 | 优先补现有服务的接线，再实施确实缺内核的重功能，见第 4 节。 |
| 音乐／音频／会议 | 原生轨道、键盘／MIDI、合成与混音、录音、WAV／MP3；会议与波形服务 | 会议录音／转写并行、失败恢复和尾段；跨工作台音频观察 | 复用已有音频管线；专业实时多轨／插件深度不是已完成项，也不另起重复音频工程。 |
| CAD／Mesh／建筑／渲染 | OCCT／Manifold、网格布尔与体素重建、二维／三维互转、建筑／IFC、本机离线渲染和动画 | N11／N17 的输入与二维导航、现有视口和 AI 链 | 已有 3D、重建、建筑和渲染进入基线，不再列成全新领域。 |
| 制造／加工 | R11 原生库、车／铣路径、存档、重开与预览；研究参数目录保留真实执行边界 | 现有制造研究会话和模型链适配；不能把所有参数或整机工业能力算作已执行 | 功能继续原计划；GPL 车削依赖必须先解决第 5 节 L01。 |
| 3D 打印 | 现有准备、切片、分层预览、导出、保存；当前执行器为本机 WebKit／Kiri:Moto | 原有切片和项目链继续；大 Mesh 性能尚需同任务测量 | 作为性能候选，不预设必须重做为 C++，也不误报已有原生切片库。 |
| 物理／动画／CAE | 原生 tet4、Rapier、粒子、Netgen、MFEM 静电／声学；现有 CAD 结果视口 | 第四批 Mesh、蒙皮／Morph、布娃娃、相机、GLB／MP4 与历史已纳入本轮；4 项 App 集成检查有通过证据，含骨骼／相机和连续导出 | 上述限定能力进入现有基线。高级结构／非线性、CFD、低频磁场／射频、耦合仍属于原计划未接求解器。 |
| 化学 | 原生编辑／三维、Avogadro/UFF；反应配平／谱图；RDKit、Gemmi、OpenMM、xTB 环境适配 | 空间／手记、作业／取消／结果和工具链已有接线，主线继续验证；xTB 尚非内置原生运行时 | 算法不是全部缺失。后续研究本地重任务加速，复用原 UI 和作业协议。 |
| 生物 | 序列、结构、显微、组学、网络；21 原生方法、32 可选科学方法和 22 工具的组件 | 实际 App 组合与注册已接入；11 项宿主／工具合同通过，实际序列创建、保存重开与分析界面已复核；外部科学后端和真实模型调用未新增验收 | 现有工作台进入基线；重点测重方法，不重复建设五类工作台。 |
| LaTeX | 新模块已含工程／事务／历史、源码与可视化 UI、文献、模板、SyncTeX、模型适配；原生声明为 XeLaTeX／BibTeX | 已见 15 项核心测试、2 项 iPad 宿主原生 PDF／定位／文献／取消恢复通过；编辑交互检查在继续。核查时主 App 工程、AppEnvironment 和空间路由尚未引用该模块 | 组件完成后交主线接入；不把 LaTeX 再列为新立项，也不把 pdfLaTeX／LuaLaTeX／Biber 的环境适配算作原生完成。 |
| 本机模型／OCR／语音 | 已有本机模型资源和推理服务、Vision OCR、语音与转写服务 | 各模型的实际配置、资源和业务接线分别处理 | 重用原有推理，不因为某领域需要模型就复制整套推理引擎。 |
| 工具箱／脚本／轻量统计 | 现有网络／连接／串口助手、文件／任务／环境；本轮 `data.analyze` 的三类固定统计已写入并有 18 项数值检查 | 历史复用与常规串口继续；USB 串口按用户最新方向等待审批、本轮排除 | 轻量统计保留为辅助；不优先新建通用统计或简单数学工作台。 |

在研范围继承 [N01–N17 与 C01–C67](FLOE_NEXT_ROUND_ENGINES_AND_USABILITY_PLAN.zh-CN.md)，以及尚由独立负责人持有的 LaTeX 原功能表 `docs/FLOE_LATEX_PREDEVELOPMENT_PLAN.zh-CN.md`，不替换原身份、负责人和未完成目标。上表按实际源码修正旧交接中“独立组件尚未接 App”的陈述；相关完成证据仍分别归原任务。

关键来源：[当前 App 集成](FLOE_PREDEVELOPMENT_APP_INTEGRATION.zh-CN.md)、[CAD／Mesh／建筑](CAD_MESH_BUILDING_PREDEVELOPMENT_20261106.zh-CN.md)、[仿真实际边界](FLOE_3D_SIMULATION_IMPLEMENTATION_STATUS.zh-CN.md)、[化学本机](../FloeAgent/Modules/FloeChemistryNative/README.md)与[环境后端](../FloeAgent/Modules/FloeChemistryKit/README.md)、[生物组件](../FloeAgent/Modules/FloeBiologyKit/README.md)与[App 组合](../FloeAgent/FloeApp/Space/Biology/BiologyAppComposition.swift)。LaTeX 在研来源为 `FloeAgent/Modules/FloeLaTeXKit/Package.swift`、`Sources/FloeLaTeXEngine/NativeEngine.swift` 及 `Integration/FloeLaTeXHostAdapter/Sources/FloeLaTeXHostAdapter/Tools.swift`；后两条相对于该模块根目录，核查摘要保存在记录中，不把尚未入库的源码作为已提交依赖。

## 3 先收尾当前实现

| 工作 | 本阶段完成条件 |
| --- | --- |
| 物理／生物与 App 集成 | 已有上述限定 App 检查与实际界面复核；复用原组件证据，不重新启动已通过的同范围检查。外部科学后端、真实供应商调用和物理设备行为继续单独记录，不能由 App25 编译或合同测试推定。 |
| LaTeX 组件及主线交接 | 完成当前编辑交互检查，交付共享引擎／队列／资源／工具合同；主线按原所有权接入工程、空间与手记，不复用测试宿主的简化授权。 |
| 媒体与通用工具链 | 按实际能力逐项核对模型目录、参数、选区、原件修订、运行、结果与导出；保留未接命令的明确状态。 |
| 界面与可用性 | 继续原 N03–N17 的布局、历史、会议、批量文件、预览和输入修整；USB 部分保留为明确暂缓。 |

这一步不以新增电路／GIS 或一次全仓性能大审查为交付门槛，也不扩展当前发布授权。

## 4 后续增强按实际缺口排序

### E01 现有媒体工作台中的重型缺口

直接比较实际命令集与目录，仍未进入该本地命令集的共 **55 项：图片 29、视频 26**。这是工作台命令接线结论，不代表整个 App 的 55 个底层算法全部不存在。

- `image.resize`、`image.canvas-size`、`video.transcribe`、`video.caption-style` 已有具体服务／命令指针，优先接线。
- 主体蒙版／边缘优化、图像修复／局部重绘，优先核对现有图片服务和已配置模型；例如移背景后端已经存在，不另写第二套。
- `video.tracking`／`video.stabilize`、`video.noise`／`video.voice-separate` 是值得继续投入的高计算量加交互方向；逐项判定复用服务、模型适配还是新内核。
- 颜色曲线／LUT／示波器／HDR 与音频处理继续既有媒体目录；不因功能已列菜单就宣称支持。
- 插帧与超分已有原生工具，不再列为新内核缺口；若工作台未接，只补相应服务接合。

保持上述原命令 ID。计算、取消、原件修订、撤销及导出走现有事务，不另起图像或视频编辑器。[实际命令集](../FloeAgent/FloeApp/Workbench/MediaV2/MediaV2Commands.swift)／[原目录](../FloeAgent/Sources/FloeWorkbench/PreparedTools/MediaPreparedBundledCatalog.swift)／[原生媒体工具](../FloeAgent/Sources/FloeMedia/MediaEnhancement.swift)。

### E02 现有科学后端的重计算

优先对照生物 PCA／邻域／聚类、比对和显微图像处理，以及化学构象／力场／OpenMM／xTB 工作负载。现有科学方法与文件／作业协议是起点，不整体重写 Python 软件栈。

先确认数据规模、真实执行位置和热点，比较同输入的耗时、峰值内存、数值误差和取消行为。重核可用系统 [Accelerate](https://developer.apple.com/accelerate/)／Metal 或许可合适的已编译领域库；已有 Eigen、MFEM 等也优先复用。有真实跨模块需求后再抽出共享矩阵／稀疏求解／FFT 服务，不预先堆一套通用数学平台。GPL 科学包不默认随原生移植进入主 App。

大 Mesh 切片同样列入测量候选，分别观察输入准备、切片、预览和导出，不能因 WebKit 实现就预设它比新原生库慢。本机 WebKit、解释执行 Linux 和外部原生机器的结果须分开记录；不能把 Mac／Simulator 耗时当作物理 iPad 加速倍率。

### E03 原 CAE 高级求解继续完成

高级结构／谱分析／非线性接触、瞬态热、CFD、低频磁场／射频与多场耦合继续原仿真清单和负责人。保留已有网格、材料、边界、场结果、视口与保存服务；候选库按实际模块、许可、内存和两类 Apple 目标验证后接入。不重复创建第二套物理或 CAE 产品。

### E04 新增独立重型领域

| 顺序 | 新方向 | 第一个完整项目范围 | 可复用基础 |
| --- | --- | --- | --- |
| 1 | 电路设计与仿真 | 原理图／网表、DC／AC／瞬态、参数扫描、节点探针和交互波形；PCB 布线另定范围 | 现有图示／CAD、文件、参数、作业和波形。可评估 [ngspice 库接口](https://ngspice.sourceforge.io/shared.html)，具体固定来源与传递依赖尚待核对。 |
| 2 | GIS 与空间分析 | 离线多图层、坐标系、空间查询、大栅格与地形的分块操作和导出 | 现有地图、文件和三维显示。可评估 [PROJ](https://proj.org/en/stable/about.html)／[GDAL](https://gdal.org/en/stable/)，所选驱动的依赖与资源单独核对。 |

这是下一阶段候选，不表示本次已经开始移植或获准改变发布范围。普通统计、代数、小规模 ODE、Bode／PID 图、数据清洗与报告仍优先使用脚本。

## 5 MPL 2.0 与第三方源码约束

保留自有源码 MPL-2.0，不将第三方文件擅自改标 MPL。MPL 是文件级 copyleft；能与其他代码组合，并不表示组合后的分发可以忽略其他许可证。[Mozilla FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)／[MPL 与 GPL 组合说明](https://www.mozilla.org/en-US/MPL/2.0/combining-mpl-and-gpl/)。本计划不通过修改根许可证或擅自双许可来满足复用目标。

新引入优先选 MIT／BSD／ISC／Apache-2.0 等合适闭包，保留原文、NOTICE、版权、固定版本与本地补丁。双许可证记录实际选择。LGPL／例外按具体链接和源码／重链接义务处理，不一概禁用既有合规路径。GPL／AGPL 或许可不明的源码不默认进入主 App 原生链接；C ABI、动态库、进程名或翻译语言不能单独构成许可结论。字体、模型、数据、宏包和辅助程序也按各自许可管理。

| 编号 | 本次查到的具体事项 | 处理安排 |
| --- | --- | --- |
| L01 | [LibLathe／TurningNative 声明 GPL-2.0](../FloeAgent/Modules/FloeManufacturingKit/THIRD_PARTY.md)；[Core 直接依赖该 target](../FloeAgent/Modules/FloeManufacturingKit/Package.swift)，[生产代码实际导入](../FloeAgent/Modules/FloeManufacturingKit/Sources/FloeManufacturingCore/NativeEngine.swift)，主 App 引用 Core／UI | 已交主线集成负责人核对最终链接及分发方案。保持原功能和来源，确定替代许可、可用授权或独立实现路线；不能继续沿用旧“独立研究宿主”描述作为 App 许可已清的依据。结论未完成前不声称整体已满足本条约束。 |
| L02 | 生物环境依赖清单含 GPL 的 igraph／leidenalg，当前不链接到原生组件 | 科学环境使用与主 App 链接分别记录；未来加速不得机械移植其 GPL 实现为 MPL。优先选许可合适的实现或从公开规范独立实现。 |
| L03 | 既有 OCCT／Netgen 等，以及新 TeX 依赖／字体／资源具有各自条款 | 沿用已有许可评估和源码／重链接材料，按实际选中分片、资源及传递依赖补齐，不只看库根 LICENSE。 |
| L04 | 原 `license_inventory.py --check` 因 FloeCADKit 包锁不同步失败；主线重新解析锁后，本线程独立复查已通过：243 个组件、55 份随包声明、40 条 Swift 包记录 | 原失败及后续通过分别保留。新增 Modules 的原生链接覆盖和双许可选择仍按实际来源核对；自动清单通过不代替 L01 的具体组合分析。 |

[既有 CAD 许可评估](FLOE_CAD_3D_REUSE_LICENSE_EVALUATION_20261031.zh-CN.md)继续有效。新方向不能整包照搬有冲突义务的应用代码；优先复用可满足当前许可目标的引擎或文件切片。GPL 本身不是不可使用的坏许可证，本条限制来自用户选择的项目分发目标。

## 6 完成条件与证据

- 每批保留实际输入、源码／引擎身份、计算结果、取消、保存回读和模型调用；UI 与 AI 使用同一原件和服务。
- 优先复用已有编译和组件证据，只补受影响验证；当前在研项目不等待 E04 新领域。
- 原生性能收益由测量决定，区分组件、主 App、Simulator 与物理设备；不以资源下载或菜单数量计完成度。
- 第三方许可与实际产物一致，按所选依赖补声明与必要源码材料；未解决的具体链接问题保持可见。

本次只更新盘点与计划，没有新增生产引擎、改版本、上传或操作设备。29 个实现／计划来源的摘要、媒体目录逐项差异和本次许可检查事实另存为[核查记录](qualification/native-engine-inventory-20261108/results.json)。较早 `data.analyze` 的[18 项数值及对象编译证据](qualification/native-data-analysis-20261108/results.json)保持原边界，不算作整 App 或重计算加速完成。

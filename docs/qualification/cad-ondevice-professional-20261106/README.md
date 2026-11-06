# CAD 专业计算与离线渲染本机移植

按用户要求，继续完成代码闭环，将专业计算与离线渲染从 Linux 任务迁至 iPad／iPhone 内部服务。本轮不重跑前一阶段的 34 项原生测试、3 条界面流程或专业精度矩阵。原 CAD／Mesh、二维与建筑编辑共用文档的设计保持原有路径。

## 当前代码路径

| 入口 | 本机实现 | 保存及边界 |
| --- | --- | --- |
| IFC 导出 | 固定 web-ifc 0.0.75 WASM，在独立 WK 页面内生成、保存并重读 IFC4 | 实际 CAD 三角面、项目／建筑／楼层／构件身份；网格化 IFC |
| 单梁结构 | 从 PyNiteFEA 3.2.1 移植均布载荷的梁挠度多项式至 Swift | 显式选择矩形等截面梁、简支／悬臂、E、泊松比及载荷；不是整栋有限元或设计规范审批 |
| 机电协调 | 既有原生 Manifold 3.5.4 的真实封闭网格布尔交集 | 报告相交体积及包围范围；AABB 仅筛候选，开放／无效几何列为未计算 |
| 信息要求 | 对重读的 IFC 检查 Name 非空，并导出对应 IDS 1.0 文件 | 固定名称要求子集，不冒充完整 IfcTester 或多国法规引擎 |
| 离线高质量渲染 | 固定 three-gpu-pathtracer 0.0.24、three 0.181.1、three-mesh-bvh 0.9.5 的本机 WebGL2 路径追踪 | 冻结 JSON 输入，16／64／256 samples，PNG 解码、尺寸、采样数及摘要核验 |

入口不再要求 Linux 环境、任务绑定或首次下载计算组件。工作区与会话仅作为可选上下文。建筑服务拥有计算与 WK 实例；关闭面板后计算继续，取消先持久化状态，再停止 worker／WK，晚到结果不能改写已取消状态。重新打开时只恢复输入和产物摘要一致的完整结果；未完成计算显示中断。历史已完成回执仍可读取，旧 Python／pbrt 脚本不再作为新任务的执行路径。

光影、PBR 材质、镜头／构件动画和 MP4 导出沿用已有设备端实现；本轮离线路径追踪交付静帧 PNG，未增加离线路径追踪动画或降噪。渲染需要设备的 WebGL2 浮点能力和前台运行；能力不足或中断会明确失败，不把普通光栅图当作路径追踪结果。

## 必要检查

工具链实查为 `/Applications/Xcode.app` 的 Xcode 27.2（27B52）。旧 Xcode 27.1 路径已不存在；首次检查失败保留，没有修改系统全局选择。

| 检查层级 | 实际结果 |
| --- | --- |
| 新结构／MEP API 的 Swift 6 对象、链接及模块 | 通过；default isolation MainActor，真实 BuildingModel、两新 API、产品 Manifold；仅 UI／持久化接口使用资格绑定 |
| 最小数值／几何样例 | 简支梁 −0.03125 mm，悬臂 −0.3 mm，反力 8,000 N；管墙实际交集 0.0015663143362233843 m³；AABB 重叠但实体不交的样例返回 0 clash；取消抛 CancellationError |
| IFC 小样例 | macOS Node/WASM 使用固定 web-ifc；2 个构件、1 个楼层、4 个三角面，保存后重读并实际生成网格；中文、单引号和反斜杠名称保真 |
| 新建筑 App 服务对象 | Center／View／IFC Host 实际源码通过 arm64 iOS Simulator 的 Swift 6 SIL／对象编译；复用真实 App 依赖模块，App 容器、传输及新 API 签名使用资格绑定，不等于完整 App 运行 |
| 完整 App 集成编译 | 主集成线程 stage11b 的 build-for-testing 通过；首次 stage11 缺少 `import FloeTools` 的失败与局部修复分别保留，不属于新后端的设备运行验收 |
| 渲染交换与资源 | 固定 bundle、语法／摘要检查，以及纯交换 DTO 的对象编译与 JSON 小样例；该静态检查与下行实际运行分别记录 |
| 新路径的实际 iPad 模拟器运行 | stage13 App 中，两项真实 WK 检查通过：64×64 路径追踪累计 16 samples 后输出可解码 PNG；本机 WASM 生成 IFC 并重读几何及 ISO 时间戳 |
| 新 App 契约小检查 | `CADLocalRenderContractTests` 3 项与仅新 device building receipt 1 项通过；连同上述 2 项共 6 项 XCTest，没有重跑原 34+3 |

结构及几何小样例在加入最后的累计输入预算 guard 前运行；随后最终 API 源已重新对象编译与链接，没有机械重跑数值矩阵。App 集成线程统一纳入两个资源文件夹和新 Host；本目录的组件证据、完整 App 构建与后端运行结果分开记录。

固定 web-ifc 的 Emscripten Embind 使用生成的函数包装器，本机专用页面因此允许所需的 `unsafe-eval`；脚本仍来自固定资源目录，输入通过 JSON 参数传入，CSP 和导航继续限制在本机页面。该设置不会将模型内容作为脚本执行。

IFC 文件头补齐设备 UTC 的 ISO 8601 时间戳，保留原 ReferenceView 与其他头字段，并同步更新资源摘要。此前 Node/WASM 小样例的原始结果不改写为该补丁后的设备结果；新增的实际 WebKit 检查已验证头时间戳。构件／楼层沿用源 UUID；建筑及关系的派生 GUID 按项目划分命名空间，避免跨项目导出复用相同标识。

实际运行证据由主集成线程保存：`app-tests-stage13-native-hosts.json` 与 `native-work-stage12-tests.{json,log,xcresult}`。后者为脚本历史命名，实际运行的是 stage13 App。只使用已有 canonical iPad 模拟器，检查结束 `booted=[]`，没有操作物理设备。上述 6 项 XCTest 与同批其他模块的 8 项 Swift Testing 分开计数。

实际 App 检查之后仅对派生 GUID 起点增加项目 UUID 命名空间。最终适配器通过一项有界双项目检查：每项目 5 个根／关系标识，跨项目重复数为 0，文件头含 ISO 时间戳；这是纯 STEP 适配器检查，没有把它改称几何引擎或设备矩阵重验。最终资源和源文件摘要见 [components.json](components.json)。

## 依赖与限制

IFC 的上游固定于 [web-ifc ac5de14](https://github.com/ThatOpen/engine_web-ifc/tree/ac5de14d320dde70515ce1619e48cfb6a5eaf51b)，MPL-2.0 原文和对应源下载入口随 `BuildingNative` 打包；固定 Floe 适配器源码也随包提供。渲染依赖的 MIT 原文、来源与完整性值随 `CADNativeRender` 打包；EXR 解码包含 fflate 0.8.2 的 MIT 声明。PyNite 移植保留 MIT 声明。统一许可证页由仓库现有生成器生成。

正常许可证生成及随后只读 `--check` 均通过：241 个组件、53 份随包声明、40 行 Swift 包记录，新增 6 个组件与 4 份声明。首次生成被新 MediaExchange 独立解析锁与主工程的既有版本冲突正确拒绝；其所有者按真实 App 约束重新解析，共有依赖的 revision 对齐后才生成，没有复制锁或放宽检查。原失败保留。

IFC 名称中的非 BMP 字符（如表情、部分扩展汉字）受固定 web-ifc 版本的保存重读限制，当前明确提示修改名称后重试，避免悄悄损坏名称。空模型不能生成一份“已通过”的信息要求检查。网格、文件、构件对及计算时间均有预算，超限返回可查看的错误，不生成截断成功结果。

本轮没有物理 iPad／iPhone、全面法规、整栋结构／机电设计精度或新路径追踪器的物理设备画质验收；也没有版本升级、归档、上传或发布。前一阶段的历史结果见[原集成记录](../../CAD_MESH_BUILDING_PREDEVELOPMENT_20261106.zh-CN.md)。

任务的五份必要组件产物及摘要已另存，原始失败／成功日志、最小样例、固定源版本和压缩上游包保留。根任务临时编译／npm 缓存与重复解包清理约 211.73 MiB，渲染任务另清理约 74.05 MiB；没有清理其他线程的构建缓存或模拟器数据。

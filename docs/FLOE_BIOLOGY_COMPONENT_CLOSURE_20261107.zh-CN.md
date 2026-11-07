# 生物组件第二轮代码闭环（2026-11-07）

本轮完成五类工作区、21 项原生方法、32 项可配置科学方法和 22 个 AI 工具的组件实现，并补上真实 Floe 工具注册与后台任务适配器。代码检查点为 `cbfcbe30d0bf932810eb56404a9f088651040199`；仅包含生物模块及独立验证宿主，不代表并发修改中的整个 App 已验收。

生物工作台独立于化学工作台，通过显式项目/对象引用关联；复用现有任务、权限、文件、模型和执行环境服务，不共享编辑状态或撤销栈。原始设计与开源资料保留在[研究与设计](FLOE_BIOLOGY_WORKBENCH_RESEARCH_AND_DESIGN.zh-CN.md)，第一轮证据保留在[原始预研记录](FLOE_BIOLOGY_PREDEVELOPMENT_20261107.zh-CN.md)。

## 本轮实际实现

| 范围 | 行为 |
| --- | --- |
| 原生专业视图 | SwiftUI/Canvas/SceneKit/Charts；真实 Cα 坐标 ribbon、来源文件标注的螺旋/折叠、Newick 拓扑/分支长度/分页、MRC 物理轴切片及有上限的等值面；序列/原子/ROI/基因细胞选择 |
| 科学后端 | Biopython、Gemmi、scikit-image/tifffile/Zarr、Scanpy/AnnData、SciPy、libSBML、libRoadRunner/CVODE；一般 SBML 规则/事件及 fresh-model sweep、金字塔区域读取和全局/物理坐标 |
| 数据和状态 | 原件不可变、逐修订 CAS、持久化结果、原子调用回执、并发/重开后的幂等重放、历史恢复、最近删除与恢复、AI 修改实时刷新原生界面 |
| 文件回路 | 授权文件 ID、分块读取、流式原件导入/导出、摘要校验、原生 Files 交接；项目 JSON 可凭 fileID + sourceProjectID 导入，避免大模型参数承载整份文件 |
| 生命周期 | 服务持有计算；宿主取消传播至已提交任务并等待实际停止；无法确认停止的状态持久化并阻止删除/恢复，直到原宿主精确核实 |

## AI 工具与真实宿主适配

| 用途 | 完整工具名（均以 biology. 开头） |
| --- | --- |
| 项目与输入 | projects、create、read、import、importProject |
| 可用能力与参数 | methods、describe |
| 修改与选择 | edit、update、select、derive |
| 计算与进度 | analyze、status、job、stop |
| 历史与恢复 | history、restore、deleteProject、deleted、restoreDeleted |
| 输出 | export、file.read |

所有工具提供可发现 JSON schema、坐标约定、分页及修订号。`describe` 还返回 32 个可选科学方法的参数及经过摘要校验的依赖锁。创建、只读和项目范围来自宿主；模型参数不能增加权限。临时/仅公共网页聊天不获得私有生物工具。大型输出通过不透明文件回执和有上限的分块读取回收。

[宿主适配器](../FloeAgent/Modules/FloeBiologyKit/Integration/FloeBiologyHostAdapter/README.md)实现真实 `ToolRunnerRegistry` 注册、有效目录组合和执行分发；科学任务复用 `BackgroundJobService`、`EnvironmentRegistry` 和已解析 Linux 环境内的 `exec.shell`。实际 probe 后才公布科学方法，缺失包返回真实诊断，安装沿用现有环境工作流。没有新增解释器执行别名、独立安装器或本机 Python 后备执行路径。宿主仍需把其现有项目所有权回调及生物入口接入实际 App。

调用身份包括项目、对象、修订、输入摘要、任务、宿主 run、科学 run、attempt 和环境。持久化 job、处理器停止/退出、输出长度/SHA 及 worker 完整信封均核对后才接受结果。独立宿主的工具控制台是真实服务调用，没有伪造模型回答。组件另外提供有预算/取消限制的 `BiologyAssistant`，供确实注入模型的宿主使用；Floe 可直接使用既有 agent runtime。

## 实际验证

工具链：Xcode 27.2（27B52）、Swift 6.4.2、iPhoneSimulator SDK 27.2；运行在唯一复用的 iPad mini（A17 Pro）iOS 27.0 Simulator。编译使用内部 SSD scratch、6 jobs、共享 native window；运行通过 canonical selector 锁，关闭并行测试。未创建、克隆、抹除 Simulator，也未使用实体 iPhone。

| 层次 | 实际结果与边界 |
| --- | --- |
| Core / Engine | 30 项不同测试通过：13 Core、17 Engine，分批对发生变化的行为验证；包括数值/几何、外来/陈旧输入拒绝、所有领域读改/选择/分页、原子回执、重开恢复、任务取消/未确认停止保护、大文件摘要和项目文件导入 |
| Swift → 科学 worker | 真实 Swift 编码信封调用明确选定的测试 CPython，得到实际 Biopython 翻译 MA。native-10 的这项因未传测试解释器而明确 skip；随后 native-python-11 单独执行通过，不将 skip 记为通过 |
| 科学计算 | 17 项测试通过；最后仅对变更的 SBML/区域读取等 5 项再次定向通过。解析解/守恒、rate/assignment rules、event、金字塔区域/标定/全局坐标及原件摘要/外来项目拒绝均有断言 |
| 真实能力探测 | 32 方法、7 类引擎、无缺失项；只读资源/版本核验通过：10 个工作资源、66 个精确依赖版本 |
| Floe 服务适配器 | 真实编译并链接 Floe 模块，iPad 上 2 项契约测试通过：registry/权限上限、真实迁移数据库/环境登记/后台 job 回读及取消。科学 shell 为明确标记的协议 fixture，不能视作 Linux/Python 执行 |
| 原生界面 | 五类实际计算在历史宿主用例中完成预期结果断言；研究记录独立保存/终止/重开测试通过；ribbon/tree/density 的几何测试与实际截图保留。工具用例最终 ipad-10 通过：读取项目 → 实际序列改写 → 资产修订 2 → 主视图显示 TTGGCT 开头的新序列 |
| 文件 | 不透明文件导出/分块回读/幂等回执测试通过；17 MiB 不透明原件的原生流式导出、摘要拒绝及结束交接后的暂存清理通过。这不是该 17 MiB 字节夹具的 TIFF 读图验收；实际 TIFF 由科学测试生成并单独验证 |

本轮实际运行的核心命令形式如下，精确参数/源文件摘要和原始输出随本地证据保存：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test --package-path FloeAgent/Modules/FloeBiologyKit \
  --scratch-path "$BIOLOGY_SCRATCH" -j 6

# 以下两条在 Backends 目录执行，使用明确指定的测试 CPython；不是产品执行入口
"$BIOLOGY_TEST_PYTHON" -B verify_backend.py --check --runtime
"$BIOLOGY_TEST_PYTHON" -B -m unittest -v test_science test_extensions

# 独立宿主 build-for-testing / test-without-building，实际运行只用 canonical iPad
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project FloeAgent/Qualification/Biology/FloeBiologyQualification.xcodeproj \
  -scheme BiologyQualificationUI -configuration Debug \
  -derivedDataPath "$BIOLOGY_HOST_DERIVED_DATA" -jobs 6 \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -destination 'generic/platform=iOS Simulator' build-for-testing
```

`native-09/10`、`native-python-11`、`native-file-12`、`science/final-01`、`science/extensions-04`、`adapter-tests-08`、`ipad-03`、`ipad-10` 是本轮对应证据阶段。没有在通过后重跑未变更的完整矩阵。原始失败均保留：SIMD/actor 对象编译错误、旧 job 默认行为断言、资源清单未更新、TIFF fd 名称/规范路径、后台协议 fixture 匹配、主模块 C 映射/链接、原生键盘输入/长菜单与屏幕外表单查询等。最新工具 UI 用例保留精确 JSON、真实修订及视图断言；诊断 sample 和现场截图确认屏幕外结果已完成，随后按真实滚动流程验证。

## 产物与截图

已保存 `FloeBiology-closure-verified-iPad-Simulator.zip`（独立 arm64 Simulator 宿主）及源码绑定、命令、SHA sidecar；另保留真实服务适配器的契约宿主。组件宿主 SHA-256 为 `3e90e62dfe3fc8e6638f6c74730a52c5395bf9df7ee694499a686a404b316d4b`。这些是本地验证产物，不是 iphoneos 安装包，也没有发布为 TestFlight。

实际未改写截图：[ribbon](qualification/biology-closure-20261107/protein-ribbon.png)、[Newick](qualification/biology-closure-20261107/newick-tree.png)、[密度切片](qualification/biology-closure-20261107/density-slice.png)、[密度等值面](qualification/biology-closure-20261107/density-surface.png)、[重开记录](qualification/biology-closure-20261107/notes-reopened.png)、[工具实际返回](qualification/biology-closure-20261107/tool-actual-response.png)、[修改后的原生视图](qualification/biology-closure-20261107/tool-edit-live-view.png)。[截图清单](qualification/biology-closure-20261107/screenshots.json)记录原始附件与摘要；历史视图截图来自后来工具输入断言失败的用例，不把整个历史用例宣称为通过。

## 交接边界

主 App 的入口、有效工具目录、真实模型调用和所选 Linux guest 联调由主集成负责人继续；本轮已交付具体适配器实现及接法。实体 iPad/Pencil、Files 提供方最终保存、Linux 平台 wheel/大文件吞吐与全 App 接受度尚未验证。没有改变 App 版本、正式审核中的 Build 315、发布 tag 或任何分发状态。

原生 MRC 上限 2M voxels/16 MiB、30k triangles；TIFF 是有界区域读取，多文件 OME 拼接未实现。一般 SBML 明确拒绝代数/延迟方程及不支持的扩展包。组学细胞比较不代替生物重复/协变量模型。预测、分子动力学、仪器控制及湿实验自动化不在本组件实现范围。文件引用项目 JSON 不是可携带所有大型原件的归档；转移到新宿主需要重新授权原件或宿主打包。

本轮已清理 5 个任务专用构建/科学环境目录及临时适配器工程，移除分配量约 1.74 GiB；同期内部盘可用空间观测增加约 1.75 GiB（有其他任务并发 IO，不视作独立保证回收量）。保留精确宿主/适配器产物、原始失败、测试结果、截图、源码摘要和复现脚本；未触及主 App 共享缓存。本任务启动的 iPad 已关闭，交付前 booted-device 清单为空。

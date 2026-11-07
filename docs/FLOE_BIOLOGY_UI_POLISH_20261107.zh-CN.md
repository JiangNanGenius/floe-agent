# 生物工作台三维抗锯齿与控件设计（2026-11-07）

最新空间利用率调整为 `f00e150cd050b8515398d8c39673c4ff4285a9bb`，见 [横屏取景与紧凑布局记录](FLOE_BIOLOGY_SPACE_UTILIZATION_20261107.zh-CN.md)。此前全工作台整理为 `50e08ec4f89593f409cb31a5545552c2eaa0956a`，见文末“全工作台布局增量”；保留原有独立证据与产物，不用后续截图替换历史结果。

用户确认本轮要求为“三维预览添加抗锯齿”，并要求改善生物组件的界面。此增量基于已完成的 [组件代码闭环](FLOE_BIOLOGY_COMPONENT_CLOSURE_20261107.zh-CN.md)，保持原有 AI 工具、任务、文件和分析契约。

用户随后明确要求处理“只有一个字、没有框住”的点选入口。本轮将这类入口统一为有标题、完整点击区域与明确边界的原生控件，并保留各类操作的层级。

- 原子、Cα 主链、带状模型与密度表面使用同一原生 Metal/SceneKit 观察器，启用 4× MSAA、时域抗锯齿和静态抖动采样；支持旋转、捏合、适合窗口和原子选择。
- 修正逐残基独立方向造成的 ribbon 接缝。共享连续帧通过真实 Cα 位置，保留原件；渲染用面积加权法线与哑光照明，密度体素坐标及分析数值不随显示调整而改变。
- 统一原生间距、字体、观察区域和状态层级；序列提供坐标概览与按内容收缩的预览，热图带行列标签、色标及选中值，系统树/反应网络避免线条穿过文字，结果使用可读名称和清晰数值。
- 深浅色均使用系统语义表面；科学图像保持其原始像素预览。原子/残基数量与选择反馈以当前显示内容为准。
- 记录、基因、细胞、模型、链、阅读框、密码表、执行位置与方法使用同一个选择框；框内空白处可点开原生菜单，实际选项和绑定均保留。
- 项目名、数值参数、序列、注释、网络、记录和工具参数输入有明确边界；次要操作使用统一描边按钮。资料入口、适合窗口、分页、停止与查看结果均有可见操作区域，主要提交操作保留强调样式。
- 分析面板底部固定“运行分析”，长表单可滚动；普通选择框和自绘按钮至少 44 点高。系统工具栏、分段控件和列表继续使用原生外观，普通数据文字保持可读。

## 已完成证据与边界

Xcode 27.2（27B52）、Swift 6、iPhoneSimulator 27.2 SDK；实际运行仅使用 canonical iPad mini（A17 Pro）iOS 27.0，未创建/抹除设备或使用实体 iPhone。

Core 4 项几何测试已通过，新增相邻 ribbon 端点连续性与原始字节保持断言。首轮对象编译通过后，三个实际 UI 用例全部通过（142.5 秒）：中文深色/导出入口、工具改写到主视图、全部专业视图与横竖屏。完整原始截图用于一次集中审阅；发现的问题集中在一个增量内修正，三个确认用例全部通过（141.9 秒）。

点选控件增量首轮中，中文深色/导出、记录保存并重开、工具实际编辑三个用例通过。新用例已验证框内空白处打开菜单、切换记录、选择 GENE_C / Cell_B2 后显示值为 11；之后在尚未滚动到的方法行失败。原始失败及层级保留：iPad 的原生 Form 仅创建可见行。修正用例实际滚动表单，再检查行存在、可点击、尺寸、方法切换和最终结构计算，未删减断言。

最终源码提交为 `71f520f882f6b53ce6bc9b7b2c36b3c938de138d`。Xcode 实际对象编译及 `build-for-testing` 通过，最后四个 UI 用例全部通过，无跳过（161.454 秒）：

| 验证 | 实际结果 |
| --- | --- |
| 框内空白处点击与长表单 | 记录/基因/细胞/方法菜单可用；选择后数值为 11；选择框 ≥44 点且可点击，滚动后固定按钮完成真实结构计算 |
| 中文深色与导出 | 原生热图、显微图像和项目导出入口通过 |
| 保存与重开 | 确认保存后结束进程，重开读取相同研究记录 |
| AI 工具编辑链 | 提交的 JSON、实际 revision 2 与主视图的 `TTGGCT` 前缀均通过 |

构建命令使用独立 `FloeAgent/Qualification/Biology/FloeBiologyQualification.xcodeproj`、`BiologyQualificationUI` scheme、六个编译任务、内部 SSD DerivedData 和 `generic/platform=iOS Simulator`；运行通过原生窗口锁及 canonical iPad 锁调用 `test-without-building`，关闭并行测试。选中的测试为 `testFramedControlsUseTheirFullHitArea`、`testChineseDarkAndExportSurface`、`testNotesSaveAcknowledgedBeforeReopen`、`testToolEditsUpdateLiveView`。

原始日志保留了 Xcode 运行后附加诊断采集的 `simctl` 查找警告（exit 72）；测试本身返回 0、xcresult 为 4 passed / 0 failed / 0 skipped，截图导出成功，显式工具链下关闭模拟器成功，最后 booted 清单为空。未更改全局 Xcode 选择，也未通过重试抹去该警告。

## 产物与原始截图

独立 arm64 iPad Simulator 宿主包：`FloeBiology-ui-controls-final-iPad-Simulator.zip`，SHA-256 为 `45c181f0662b7ee05c9fb22bb82bdf83db5ebdf4b2641e7325643963995c85a2`。产物与 sidecar、构建清单和独立资格记录保存在仓库本地 `Local/Artifacts/FloeBiologyKit/20261107/round2/`。已校验 ZIP、可执行文件与 debug dylib 的哈希、实际 IOSSIMULATOR 平台及源码提交；构建后仅补充 README 文档。自动生成的 self-workspace 元数据单独记录，未冒充已提交源码。

截图均为原始 Simulator 捕获，未改图；来源阶段与 SHA-256 见 [截图清单](qualification/biology-ui-20261107/screenshots.json)。三维、树、网络及结果复用已确认的 `ipad-visual-03`，新增控件截图来自最终通过的 `ipad-controls-03`。

| 表面 | 原始截图 |
| --- | --- |
| 带框点选 | [记录](qualification/biology-ui-20261107/framed-record.png)、[基因/细胞](qualification/biology-ui-20261107/framed-matrix.png) |
| 分析表单 | [模型/链/参数](qualification/biology-ui-20261107/framed-model.png)、[方法与固定运行按钮](qualification/biology-ui-20261107/framed-analysis.png) |
| 中文深色与实际工具返回 | [热图](qualification/biology-ui-20261107/dark-matrix.png)、[诊断工具编辑返回](qualification/biology-ui-20261107/tool-edit.png) |
| 三维与专业图 | [横屏蛋白](qualification/biology-ui-20261107/ribbon-landscape.png)、[密度表面](qualification/biology-ui-20261107/density.png)、[系统树](qualification/biology-ui-20261107/tree.png)、[网络](qualification/biology-ui-20261107/network.png)、[结果](qualification/biology-ui-20261107/result.png) |

此前组件/适配器与 17 项科学计算证据保持有效，相关实现未在本 UI 增量中改变。此轮验收仅覆盖独立组件宿主；完整 App 集成、真实配置下的 Linux/provider、iPhone 与实体设备体验尚未由这些证据验收。本轮没有 App 版本或分发操作，原有 22 个 AI 工具保持可用契约。

导出产物和原始证据后，已删除本任务再次生成的 `swift-tests` 与 `ipad-host` 两个可重建缓存目录（累计已分配约 416.45 MiB）；同卷空闲量实测增加约 421.46 MiB，受并发任务影响，不作为独占回收量。保留产物、源码、原始成功/失败记录、截图、复现文件及模拟器应用数据。

## 全工作台布局增量

用户随后明确要求整理“整个生物工作台，包括图表与工具栏”和“所有能看到的位置”。对应实现提交为 `50e08ec4f89593f409cb31a5545552c2eaa0956a`，没有改动 Core/Engine/HostAdapter 接口或主 App。

- iPad 使用可开合的原生分析检查器，分离资料导航、科学视图和参数操作；小尺寸工具栏将撤销/重做收进更多菜单。编辑、注释和网络操作统一从更多进入，参数按实际方法 schema 显示。
- 统一按钮高度、圆角、输入边界和内容宽度；项目行使用正文色，热图两列均分、窄窗口纵排，序列/矩阵支持滚动。密度参数的标题与控件对齐，三维继续使用已验证的原生抗锯齿路径。
- 结果页与网络页共用有原始单位、图例和坐标轴的时间过程图，最多预览 12 条曲线、约 6,000 个真实采样点，完整数据保持原样供导出；表格字号增大。
- 编辑、历史、重命名、AI 与工具页统一为原生 page 大小和行内标题；记录使用单一文档编辑面，工具响应使用独立有界滚动区域。AI 未连接时明确显示真实状态，不生成示例回答。

检查器采用 [SwiftUI 原生 inspector](https://developer.apple.com/documentation/swiftui/view/inspector%28ispresented%3Acontent%3A%29/)。本次实际修复了旋转后多余键盘避让空间导致运行按钮覆盖参数的问题：面板仅在自身输入获得焦点时启用键盘避让，关闭/运行会清除自身焦点，并提供完成输入操作。最终横屏断言要求科学视图仍可操作、运行和方法均可点击、两者矩形不重叠，全部通过。

| 不同 UI 用例 | 最终通过证据 | 秒 |
| --- | --- | ---: |
| 中文深色/导出 | `ipad-layout-02` | 23.742 |
| 框内点击、选项和真实计算 | `ipad-layout-02` | 56.044 |
| 记录保存并重开 | `ipad-layout-02` | 29.463 |
| 真实工具编辑回到主视图 | `ipad-layout-02` | 40.418 |
| 编辑、撤销重做和横屏 | `ipad-layout-03` | 37.255 |
| 所有专业视图及横屏检查器 | `ipad-layout-04` | 84.298 |
| 八个辅助页面 | `ipad-layout-04-aux` | 68.480 |

上表为 7 个不同用例的最终证据，按变更复用未受影响的结果，不是声称某一轮一次全部通过。`layout-01/02` 的原始失败、截图、层级与视频保留；包括例子初始选中最后导入的数据、容器覆盖控件标识、原生菜单 section 不保留自定义 ID，以及横屏底部避让问题。测试改为先明确选择序列、点击原生可见菜单标签，并保留真实编辑/数值/命中区断言。`layout-03` 的辅助用例另有一次原因未定的 Runner SIGTERM，未算通过；之后单独完整走查 68.480 秒通过，原终止证据仍保留。Xcode 附加诊断的历史 `simctl` 查找警告也保留，未修改全局工具链来掩盖它。

最新精确宿主包为 `FloeBiology-layout-keyboard-iPad-Simulator.zip`，SHA-256：`691714d05729383a3151a04acf0f2bcbf84077ae6859f41c0f23d093bfe15829`；同目录 `layout-qualified.json` 将提交、构建清单、逐用例和 ZIP/代码映像哈希关联。仅两个 README 在构建后补充，生成的 self-workspace 元数据单独核对。原件保存在原有 `Local/Artifacts/FloeBiologyKit/20261107/round2/`，不是设备安装 IPA。

24 张原始截图的来源和哈希见 [新截图清单](qualification/biology-layout-20261107/screenshots.json)。已集中审阅科学视图、全部辅助页面与横竖屏；深色和实际工具返回复用本轮未改变的对应视图证据。

| 页面 | 截图 |
| --- | --- |
| 项目、序列、原生三维 | [项目库](qualification/biology-layout-20261107/library.png)、[序列](qualification/biology-layout-20261107/sequence.png)、[三维与分析侧栏](qualification/biology-layout-20261107/landscape-inspector.png) |
| 图像、矩阵、网络与结果 | [显微](qualification/biology-layout-20261107/microscopy.png)、[热图](qualification/biology-layout-20261107/matrix.png)、[网络](qualification/biology-layout-20261107/network.png)、[结果曲线](qualification/biology-layout-20261107/result.png) |
| 树与密度 | [系统树](qualification/biology-layout-20261107/tree.png)、[密度](qualification/biology-layout-20261107/density.png) |
| 三种编辑器 | [序列](qualification/biology-layout-20261107/sequence-editor.png)、[注释](qualification/biology-layout-20261107/annotation-editor.png)、[网络](qualification/biology-layout-20261107/network-editor.png) |
| 项目辅助页 | [记录](qualification/biology-layout-20261107/notes.png)、[历史](qualification/biology-layout-20261107/history.png)、[重命名](qualification/biology-layout-20261107/rename.png) |
| AI、工具与深色 | [未配置 AI](qualification/biology-layout-20261107/assistant-unconfigured.png)、[工具](qualification/biology-layout-20261107/tools.png)、[实际编辑返回](qualification/biology-layout-20261107/tool-edit.png)、[中文深色](qualification/biology-layout-20261107/matrix-dark.png) |

产物和证据导出后，已再次移除本任务的 `ipad-host` DerivedData（已分配约 230.79 MiB），同卷空闲实测增加约 232.77 MiB，受并发活动影响。任务启动的 canonical 已成功关闭；最后盘点时仿真任务随后正在复用该设备，予以保留。完整 App、真实 Linux/provider、iPhone/iOS 26 运行时及实体设备体验仍是独立边界。正式接入事项见 [App 交接](FLOE_BIOLOGY_APP_HANDOFF_20261107.zh-CN.md)。

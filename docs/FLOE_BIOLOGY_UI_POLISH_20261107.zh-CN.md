# 生物工作台三维抗锯齿与控件设计（2026-11-07）

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

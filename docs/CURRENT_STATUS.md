# 当前版本与验证状态 / Current release and verification status

更新时间 / Updated: 2026-10-06. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

| 项目 / Item | 状态 / State | 证据 / Evidence |
| --- | --- | --- |
| 最近已记录内部交付 / Last recorded internal delivery | 1.7.14 (255), `v1.7.14`; 记录显示 VALID 和 Floe QA 可用；这里未重新核验 Apple 当前状态 / historical VALID and internal availability, not a fresh Apple query | [交付记录](releases/testflight/TESTFLIGHT_1.7.14_BETA.md) |
| 公开测试 / External beta | Build 255 的最后记录为等待审核；不据此推断现在仍在等待或已批准 / last recorded pending review; current approval not inferred | [送审记录](public-beta/build255/README.md) |
| 当前源码候选 / Current source candidate | 1.7.19 (260), `19fce7f49cfae30a8ef270b95502b207b2485d03`; 尚未打标签/上传 / no tag or upload | [完整 CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/37367159743) · [独立手记验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/37367163822) |
| 256–258 候选 / Earlier candidates | 测试受阻，未据此发布 / blocked by verification; not delivered | [稳定性修复](releases/repairs/FLOE_256_STABILITY.md) |
| 原生 Office / Native Office | 编译与部分工具链证据不替代 iPad 连续笔迹、原文件写回、保存重开 / device ink and writeback remain separate | [验收范围](OFFICE_FRONTEND_ACCEPTANCE.md) |

## 候选变更 / Candidate changes

- Linux 首次启动按任务选择性能；成功启动后恢复核心/内存配置；优先复用有效镜像。First-start workload selection, saved launch shape and verified image reuse.
- 工作区本地终端入口与明确的镜像安装提示。Local workspace terminal with visible image installation.
- Office 自由绘制入口默认图形修复。Office freehand entry fix.
- 本地模型提示压缩并保留工具契约。Bounded local prompt retaining required contracts.
- 工程图本地初次连接失败的一次恢复；已交付文档/编辑状态不重载。One initial local-preview recovery without reloading delivered editing state.

Build 259 完整 CI 通过，但发布资格验证发现独立 NativeNotes 源码清单遗漏及一次 iPhone 导入跳转失败；`v1.7.18` 保持不变。Build 260 补齐清单后，原独立 NativeNotes 已通过。其后完整 CI 的手记 UI 检查失败，录像显示工具环已关闭、画面已横屏，而自动化状态判断未同步。现已修正消失等待、窗口坐标与窄屏标签滚动，并提前上传手记诊断产物。受影响的 iPad/iPhone 定向用例在本机通过（复用云端 App，仅重编测试模块）；新完整 CI 和独立验证进行中。尚未打标签、上传或宣布可安装。

Build 259 passed full CI, but release qualification found a missing standalone Notes source dependency and an iPhone import-transition failure; its tag remains immutable. Build 260 corrected the manifest and passed standalone Notes qualification. Its subsequent full CI failed Notes UI checks despite video showing the wheel dismissed and the screen in landscape. Test synchronization, window coordinates and narrow tab-strip scrolling have now been corrected, with earlier diagnostic retention. Focused iPad/iPhone tests passed locally using the retained cloud App and a rebuilt test module. Fresh full CI and standalone qualification are running; no tag, Apple upload or installability is claimed.

兼容 SDK 后续又发现测试辅助函数的亮度表达式类型推断超时；已拆分为显式整数运算，计算与断言未变，本机 Swift 6 对象编译通过，云端重新验证中。The accepted-SDK compiler subsequently hit a type-inference limit in the thumbnail test helper. Explicit integer subexpressions preserve the calculation and assertions; local Swift 6 object compilation passed, with fresh cloud validation pending.

完整 CI 37354218580 已在前一源码通过。独立兼容验证的功能测试通过，但 Xcode 26 结果格式导致诊断误分类：空警告字段被省略、源码位置嵌入失败文本。现已补齐兼容读取，保留警告/异常拦截；34 项分类测试通过，原始结果回放正确。仅验证脚本变更，新源码完整 CI 与独立验证待通过。Full CI passed on the preceding source. Standalone compatibility functional tests passed, but Xcode 26 diagnostic schema differences caused misclassification. The reader now handles omitted warning fields with legacy issue verification and embedded source coordinates; warning/error guards remain. All 34 classifier tests and original-result replay passed. Fresh checks of the script-only revision are pending.

## 阅读顺序 / Reading order

1. [中文操作手册](USER_GUIDE.zh-CN.md) / [English manual](USER_GUIDE.md).
2. [文档索引](README.md) / [本次文档审计](DOCUMENTATION_REFRESH_20261005.md).
3. 专题文档说明实现和限制；其中带日期的构建结果只适用于原版本。Topic documents retain implementation detail; dated evidence applies to its recorded source.
4. [发布档案](releases/README.md)只作为逐版本证据。Release archives preserve original results.

发布完成需分别确认：构建、留存产物、签名上传、Apple VALID、目标测试组可用、外部审核。Build, retained artifact, signed upload, Apple processing, group availability and external approval are distinct gates. 官网文档上线不代表 App 候选发布。Website publication is separate from App release.

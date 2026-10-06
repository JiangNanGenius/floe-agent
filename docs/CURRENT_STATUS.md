# 当前版本与验证状态 / Current release and verification status

更新时间 / Updated: 2026-10-06. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

| 项目 / Item | 状态 / State | 证据 / Evidence |
| --- | --- | --- |
| 最近已记录内部交付 / Last recorded internal delivery | 1.7.14 (255), `v1.7.14`; 记录显示 VALID 和 Floe QA 可用；这里未重新核验 Apple 当前状态 / historical VALID and internal availability, not a fresh Apple query | [交付记录](releases/testflight/TESTFLIGHT_1.7.14_BETA.md) |
| 公开测试 / External beta | Build 255 的最后记录为等待审核；不据此推断现在仍在等待或已批准 / last recorded pending review; current approval not inferred | [送审记录](public-beta/build255/README.md) |
| 当前源码候选 / Current source candidate | 1.7.19 (260), `2e089fa55aae867ef48df2ecf83a58e2d0e9eedc`; 尚未打标签/上传 / no tag or upload | [完整 CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/37404454871) · [独立手记验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/37376267169) |
| 256–258 候选 / Earlier candidates | 测试受阻，未据此发布 / blocked by verification; not delivered | [稳定性修复](releases/repairs/FLOE_256_STABILITY.md) |
| 原生 Office / Native Office | 编译与部分工具链证据不替代 iPad 连续笔迹、原文件写回、保存重开 / device ink and writeback remain separate | [验收范围](OFFICE_FRONTEND_ACCEPTANCE.md) |

## 候选变更 / Candidate changes

- Linux 首次启动按任务选择性能；成功启动后恢复核心/内存配置；优先复用有效镜像。First-start workload selection, saved launch shape and verified image reuse.
- 工作区本地终端入口与明确的镜像安装提示。Local workspace terminal with visible image installation.
- Office 自由绘制入口默认图形修复。Office freehand entry fix.
- 本地模型提示压缩并保留工具契约。Bounded local prompt retaining required contracts.
- 工程图本地初次连接失败的一次恢复；已交付文档/编辑状态不重载。One initial local-preview recovery without reloading delivered editing state.

Build 259 发布资格验证失败，`v1.7.18` 保持不变。Build 260 最近完整 CI 因 iPhone 工程图封面启动失败而未通过；该问题在本地及云端定向测试中未复现，仍保留原失败记录。本地随后定位了另一处测试问题：保留多个文档时，固定六次拖动不足以到达目标标签。修正滚动距离后，本地完整手记用例 4 项通过、原生 Office 1 项按模拟器规则跳过；运行时 367 项测试也已通过。上述为本地定向证据；新提交的完整 CI 正在运行，尚未打标签、上传或宣布可安装。

Build 259 release qualification failed; its tag remains immutable. Build 260's last full CI failed to start an iPhone engineering cover, which isolated local and cloud tests did not reproduce. The original failure remains recorded. Local diagnosis also found that six fixed drags could not reach a distant retained document tab. After correcting travel, all four simulator Notes cases passed, with native Office skipped by its existing simulator rule; 367 runtime tests also passed locally. These are focused local results. Full CI for the new commit is running; no tag, upload or installability is claimed.

## 阅读顺序 / Reading order

1. [中文操作手册](USER_GUIDE.zh-CN.md) / [English manual](USER_GUIDE.md).
2. [文档索引](README.md) / [本次文档审计](DOCUMENTATION_REFRESH_20261005.md).
3. 专题文档说明实现和限制；其中带日期的构建结果只适用于原版本。Topic documents retain implementation detail; dated evidence applies to its recorded source.
4. [发布档案](releases/README.md)只作为逐版本证据。Release archives preserve original results.

发布完成需分别确认：构建、留存产物、签名上传、Apple VALID、目标测试组可用、外部审核。Build, retained artifact, signed upload, Apple processing, group availability and external approval are distinct gates. 官网文档上线不代表 App 候选发布。Website publication is separate from App release.

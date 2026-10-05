# 当前版本与验证状态 / Current release and verification status

更新时间 / Updated: 2026-10-06. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

| 项目 / Item | 状态 / State | 证据 / Evidence |
| --- | --- | --- |
| 最近已记录内部交付 / Last recorded internal delivery | 1.7.14 (255), `v1.7.14`; 记录显示 VALID 和 Floe QA 可用；这里未重新核验 Apple 当前状态 / historical VALID and internal availability, not a fresh Apple query | [交付记录](releases/testflight/TESTFLIGHT_1.7.14_BETA.md) |
| 公开测试 / External beta | Build 255 的最后记录为等待审核；不据此推断现在仍在等待或已批准 / last recorded pending review; current approval not inferred | [送审记录](public-beta/build255/README.md) |
| 当前源码候选 / Current source candidate | 1.7.19 (260), `f7fc7deb44536f19184fc02d2c47b63937775728`; 尚未打标签/上传 / no tag or upload | [完整 CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/37337748395) · [独立手记验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/37337742477) |
| 256–258 候选 / Earlier candidates | 测试受阻，未据此发布 / blocked by verification; not delivered | [稳定性修复](releases/repairs/FLOE_256_STABILITY.md) |
| 原生 Office / Native Office | 编译与部分工具链证据不替代 iPad 连续笔迹、原文件写回、保存重开 / device ink and writeback remain separate | [验收范围](OFFICE_FRONTEND_ACCEPTANCE.md) |

## 候选变更 / Candidate changes

- Linux 首次启动按任务选择性能；成功启动后恢复核心/内存配置；优先复用有效镜像。First-start workload selection, saved launch shape and verified image reuse.
- 工作区本地终端入口与明确的镜像安装提示。Local workspace terminal with visible image installation.
- Office 自由绘制入口默认图形修复。Office freehand entry fix.
- 本地模型提示压缩并保留工具契约。Bounded local prompt retaining required contracts.
- 工程图本地初次连接失败的一次恢复；已交付文档/编辑状态不重载。One initial local-preview recovery without reloading delivered editing state.

Build 259 完整 CI 通过，但发布时独立 NativeNotes 工程漏加预览恢复源码导致编译失败；旧标签 `v1.7.18` 保持不变。Build 260 补齐依赖，独立 NativeNotes 验证已通过，但完整 CI 的手记 UI 检查失败，正在定位；尚未合并候选或打发布标签。Build 259 的发布验证还出现一次 iPhone 工作区导入未跳转；相同 Build 260 程序在本机的定向用例通过，不替代云端失败调查。Build 259 passed full CI but its standalone release target omitted a source dependency; its accepted-SDK iPhone UI run also failed during workspace import. Build 260 passes standalone NativeNotes qualification, but full CI is blocked by a Notes UI failure under investigation. A focused local run of the same Build 260 binary passed; this does not resolve the cloud failure. Neither candidate has uploaded to Apple.

## 阅读顺序 / Reading order

1. [中文操作手册](USER_GUIDE.zh-CN.md) / [English manual](USER_GUIDE.md).
2. [文档索引](README.md) / [本次文档审计](DOCUMENTATION_REFRESH_20261005.md).
3. 专题文档说明实现和限制；其中带日期的构建结果只适用于原版本。Topic documents retain implementation detail; dated evidence applies to its recorded source.
4. [发布档案](releases/README.md)只作为逐版本证据。Release archives preserve original results.

发布完成需分别确认：构建、留存产物、签名上传、Apple VALID、目标测试组可用、外部审核。Build, retained artifact, signed upload, Apple processing, group availability and external approval are distinct gates. 官网文档上线不代表 App 候选发布。Website publication is separate from App release.

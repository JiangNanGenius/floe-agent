# Floe 发布档案 / Release archive

逐版原始记录按用途存放。历史条目说明的是对应源码、构建和当时的核验范围；当前可安装状态以 [文档入口](../README.md) 和实时 Apple／CI 核验为准。保留失败构建与未发布候选的记录，以便追溯，不把它们写成已交付版本。

| 目录 / Directory | 内容 / Contents |
| --- | --- |
| [notes/](notes/) | 双语发布说明与逐 Build 改动 / Bilingual release notes |
| [testflight/](testflight/) | TestFlight 交付记录及中英文测试说明 / Delivery evidence and beta copy |
| [verification/](verification/) | 历史发布核验与代码审计 / Historical verification and audits |
| [beta/](beta/) | 早期 1.7 beta 候选记录 / Earlier beta candidates |
| [builds/](builds/) | 专项构建与交付记录 / Build-specific records |
| [repairs/](repairs/) | 修复、反馈及发布恢复约束 / Repairs, feedback and recovery |
| [android/](android/) | Android 专项发布记录 / Android release records |

渠道版本与核实日期统一见 [CURRENT_STATUS](../CURRENT_STATUS.md)，按所选版本查找对应说明和交付记录。本索引不复制“最近交付”版本号或文件数量；旧记录中的内部可用、外部待审或未交付均保留当时含义。 / Use CURRENT_STATUS for dated channel snapshots and follow the selected build's evidence. Historical availability and review states retain their original dates.

[历史版本导览](HISTORY.md)保留此前文档索引中的逐版状态与原始结论。`docs/evidence/`、`docs/qualification/` 和 `docs/validation/` 继续保存对应证据，不与说明文件混放。

新版本的发布说明写入 `notes/`，TestFlight 中英文说明写入 `testflight/`。当前发布预检按这两个路径校验；较早的冻结标签仍按标签内原有的 `docs/` 路径运行。不要移动已有标签或用新文档替代旧构建的证据。

TestFlight 更新先按用户当轮授权及 [AGENTS.md](../../AGENTS.md) 确认渠道范围；在允许公开测试且内部组确认可安装后，继续现有外部组 `publictest1` 送审：为该构建准备双语 What to Test、Beta 描述和最终审核备注，明确传入该构建的资料路径，先运行只读 `public-testflight.yml` 检查，再提交现有外部组并独立读回 Apple 审核状态。工作流不再默认引用 Build 241 资料。若 API 无写入权限，沿 App Store Connect 网页完成同一提交，保留 API 失败及网页操作证据。审核提交、审核通过与外部可安装分别记录；不据此发布正式 App Store 版本。每个版本的资料和状态放在 `docs/public-beta/buildNNN/` 及对应交付记录。

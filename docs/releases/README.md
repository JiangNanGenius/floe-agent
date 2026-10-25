# Floe 发布档案 / Release archive

逐版原始记录按用途存放。历史条目说明的是对应源码、构建和当时的核验范围；当前可安装状态以 [文档入口](../README.md) 和实时 Apple／CI 核验为准。保留失败构建与未发布候选的记录，以便追溯，不把它们写成已交付版本。

| 目录 | 内容 | 数量 |
| --- | --- | ---: |
| [notes/](notes/) | 双语发布说明与逐 Build 改动 | 148 |
| [testflight/](testflight/) | TestFlight 交付记录及中英文测试说明 JSON | 186 |
| [verification/](verification/) | 历史发布核验与代码审计 | 11 |
| [beta/](beta/) | 早期 1.7 beta 候选记录 | 13 |
| [builds/](builds/) | 专项构建记录 | 2 |
| [repairs/](repairs/) | 按 Build／版本编号的修复与反馈记录 | 53 |

最近交付：[1.7.57（298）修复与交付记录](repairs/FLOE_VOICE_INTERACTION_SEARCH_BUILD298_20261025.md)、[双语发布说明](notes/RELEASE_NOTES_1.7.57_BUILD_298.md)。内部 Floe QA 可用，publictest1 等待审核，稳定无签名 Release／同次 Feather 已独立核验；[297 记录](repairs/FLOE_VOICE_PLAYBACK_BUILD297_20261025.md)及更早文档保留各自的原始状态。

[历史版本导览](HISTORY.md)保留此前文档索引中的逐版状态与原始结论。`docs/evidence/`、`docs/qualification/` 和 `docs/validation/` 继续保存对应证据，不与说明文件混放。

新版本的发布说明写入 `notes/`，TestFlight 中英文说明写入 `testflight/`。当前发布预检按这两个路径校验；较早的冻结标签仍按标签内原有的 `docs/` 路径运行。不要移动已有标签或用新文档替代旧构建的证据。

今后的 TestFlight 更新在内部组确认可安装后，常规继续外部测试组 `publictest1` 送审：为该构建准备双语 What to Test、Beta 描述和最终审核备注，明确传入该构建的资料路径，先运行只读 `public-testflight.yml` 检查，再提交现有外部组并独立读回 Apple 审核状态。工作流不再默认引用 Build 241 资料。若 API 无写入权限，沿 App Store Connect 网页完成同一提交，保留 API 失败及网页操作证据。审核提交、审核通过与外部可安装分别记录；不据此发布正式 App Store 版本。每个版本的资料和状态放在 `docs/public-beta/buildNNN/` 及对应交付记录。

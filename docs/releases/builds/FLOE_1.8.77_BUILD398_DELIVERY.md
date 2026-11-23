# Floe Agent 1.8.77（398）

任务中心合并读取最近运行状态，设计成果入口仅在展示状态变化时通知界面。手记回收站可按标题和正文搜索。本版也包含手记批量移入回收站、新建任务空白页固定居中、复用会话与工作区文件同步连接，以及引导消息顺序修复。 [双语发布说明](../notes/RELEASE_NOTES_1.8.77_BUILD_398.md)

## 构建与验证

`v1.8.77` 固定到 `faa202ea3be60b188661bd55d1b10ac0f6eb3a94`。Xcode 27.2（27B52）的完整 iPhoneOS ARM64 Release、五个目标的版本核对及设备封包均通过。签名 IPA 与本地 App 的 UUID 一致，19 份调试符号对应包内二进制，IPA SHA-256 为 `63a3c4fef137be373dfb974a7ead4e069ba34571a99a1a1e24eb9d836d5a73a7`。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45204203626)

Swift 与 GRDB 使用 2,000 条合成会话、24,000 条运行记录，七轮配对实测的中位读取用时为 789.51 ms → 128.78 ms。结果逐条一致。独立 SQLite 查询实验将 2,000 次查询合为 1 次。两项生产持久层回归在补齐测试模型记录后通过。修正仅在冻结后的测试文件，发布产物对应上述固定标签。手记生产筛选逻辑的五项编译样例全部通过，旧逻辑在回收站查询中失败两项。398 的设备触控与实体设备间文件互传仍待验。

## TestFlight

- **内部 Floe QA**。Apple 独立回读确认 `VALID`、未过期，内部状态 `IN_BETA_TESTING`，可安装。
- **公开 publictest1**。2026-11-24 02:52（悉尼时间）提交同一构建，Apple 回读为 `WAITING_FOR_BETA_REVIEW`，自动通知已开启。 [公开测试入口](https://testflight.apple.com/join/nz6qeT2J)

# Floe Agent 1.8.74（395）

选定会话支持分页同步、中断续传和重复消息去重。本版还改进 Linux 设置进度、任务网页服务恢复、会议纪要收尾、Studio 导出归属和长聊天工具状态更新。 [双语发布说明](../notes/RELEASE_NOTES_1.8.74_BUILD_395.md)

## 构建与验证

冻结标签 `v1.8.74` 指向 `221db11f160a3c3efa2d075896dc8974bdb3b3dd`。Xcode 27.2（27B52）的 iPhoneOS 27.2 arm64 Release 编译、发布预检和设备包校验通过。签名 IPA 与本地封存构建的 App UUID 匹配，19 份调试符号均对应包内二进制。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45147688924)

候选功能已用真实 Iroh 回环及固定 iPad 模拟器的聚焦宿主验证中断后续传和重复拉取。真实 SQLite 测试读回 12,001 条消息。Linux 设置与网页服务、会议纪要和 Studio 导出通过各自的定向验证。真实 iPad 跨设备网络及整包长会话的真机性能待测。

## TestFlight

- **内部 Floe QA**。Apple 独立回读确认构建 `VALID`、未过期，内部状态为 `IN_BETA_TESTING`，可安装。
- **公开 `publictest1`**。2026-11-23 21:01（悉尼时间）提交同一构建。Apple 独立回读为 `WAITING_FOR_BETA_REVIEW`，中英文测试说明已核对，审核通过后自动开放。 [公开测试入口](https://testflight.apple.com/join/nz6qeT2J)

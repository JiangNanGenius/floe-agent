# Floe Agent 1.8.80（401）

长会话加载新消息时，跟随目标随末尾更新。向下箭头直接定位真正的末尾，确认到达后收起。主动浏览历史或查看搜索结果时保留阅读位置。 [双语发布说明](../notes/RELEASE_NOTES_1.8.80_BUILD_401.md)

## 验收

- 在固定 iPad mini 模拟器（iPadOS 27.2）上复现了消息追加后停在旧末尾。修复后复测同样的合成会话场景，延后追加 96 条长短不一的消息，最终一条自动进入视野。连续三次从历史位置点箭头均回到真正的末尾。
- 会话内搜索定位及草稿保留也通过。两项原生界面测试均使用 Floe App 和实际会话存储。验收设备为 iPad 模拟器。
- `v1.8.80` 固定于 `6419044c99dfadf1b4fc7ed15793b9b8ef331568`。Xcode 27.2（27B52）iPhoneOS arm64 Release 构建及严格封包通过，App、四个扩展和 20 套调试符号已核对。

## 发行

- **内部 TestFlight**。2026-11-25 01:36（悉尼时间）独立读回 401 为 `VALID`、未过期，Floe QA 可安装。中英文测试说明匹配冻结源码。签名 IPA 的 SHA-256 为 `0c4b88e618f81fc1fdae4dd6d21986163160e1bbbb014c05eb02fb1c26f760eb`。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45410733751)
- **GitHub 与 Feather**。无签名 IPA 的公开下载和构建证明均通过核验。文件为 736,114,779 字节，SHA-256 为 `5663eb3eb210f3e6cfcb59d4835ca9d30c189f6f908c4e9bf2300bef53540754`。在线 Feather 源匹配相同构建、地址和摘要。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.80) · [发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/45413495155) · [Feather 源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)
- **App Store 正式审核**。393 从原队列撤下后，400 接到可编辑草稿。发现会话末尾滚动问题后暂停送审。2026-11-25 01:30（悉尼时间）回读 400 草稿的审核单为空，当时线上正式版为 1.8.32（353）。 [App Store Connect](https://appstoreconnect.apple.com/apps/6801209053/distribution)

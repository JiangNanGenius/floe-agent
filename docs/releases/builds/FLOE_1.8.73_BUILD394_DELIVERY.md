# Floe Agent 1.8.73（394）

「设置 → 同步」新增默认关闭的「与 Mac 同步会话」。开启后可在「配对与共享」添加设备、管理权限并选择共享的会话。iCloud 保留独立开关。

## 联调与构建

Xcode 27.2（27B52）的 iPadOS 27.2 模拟器 App 与实际 macOS 1.11.15 均收到对方共享的测试会话。重复拉取没有新增消息，未共享的会话没有导入。关闭 Mac 同步后，iPad 停止监听，iCloud 设置值保持原值。已移除测试对端和测试数据并关停模拟器。实体设备之间的网络联调待验证。

冻结标签 `v1.8.73` 指向 `700381f1bc067fcc3b9258ca47f23f2cd76bbb2e`。发布预检、iPhoneOS 27.2 arm64 Release 编译及设备包核验通过，19 份调试符号与二进制匹配。签名 IPA 内容和主 App UUID 与本地构建一致。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45070838233)

## TestFlight

- **内部 Floe QA**。Apple 独立回读确认 `VALID`、未过期，内部状态为 `IN_BETA_TESTING`，可安装。
- **公开 `publictest1`**。2026-11-23 08:41（悉尼时间）提交同一构建。Apple 独立回读为 `WAITING_FOR_BETA_REVIEW`，已核验中英文测试说明和通过后自动开放的设置。 [公开测试入口](https://testflight.apple.com/join/nz6qeT2J)

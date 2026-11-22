## Floe Agent 1.11.15 for Mac

- 「设置 → 设备同步」新增配对和会话共享。核对设备指纹后，可选择共享的会话，并拉取对方分享的文本历史。另一端也需要支持设备同步的 Floe 版本。
- 同步保留会话 ID、消息 ID、时间和文本片段。重试会跳过已收到的消息，同 ID 内容发生冲突时会保留两端记录。
- 设备同步默认关闭。开启后默认直连，可填写自己的 HTTPS 中继。公共中继入口供测试使用。

Floe Bridge 可通过已有更新入口升级。适用于 Apple 芯片和 macOS 15 或更高版本。

### English

- Device Sync in Settings adds pairing and conversation sharing. Verify the device fingerprint, choose which conversations to share, and pull shared text history from the other device. Both devices need a Floe version that supports Device Sync.
- Sync preserves conversation and message IDs, timestamps, and text parts. Retries skip messages already received, and a conflict preserves both copies.
- Device Sync is off by default. Direct connections are the default when enabled. You can configure your own HTTPS relay or try the public relay for testing.

Floe Bridge can upgrade through its existing update command. Requires Apple silicon and macOS 15 or later.

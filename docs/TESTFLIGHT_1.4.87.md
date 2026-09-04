# Floe Agent 1.4.87 (Build 118) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md)

Build 118 is the public-beta readiness candidate for the ordinary-chat Picture in Picture state machine, complete VNC recovery workflow, Infinite Canvas reference generation, Harness continuity, GitHub sign-in, memory organization, and basic network diagnostics.

## Fixes and automated evidence

- **Ordinary-chat Picture in Picture:** the shared custom-player source now uses a real `CMTimebase` and monotonic sample presentation timestamps. Floe keeps the source and controller alive through the foreground-to-background transition without presenting the floating window while the app is active.
- **Complete VNC recovery:** explicit user ordering is authoritative. An SSH repair/update exposes `vnc.connect` immediately when it saved an endpoint; observation and input remain gated until a real connection succeeds. Repeated unchanged failures stop instead of consuming the task budget.
- **Infinite Canvas:** generation follows explicit graph dependencies, carries every accepted reference edge, bounds image inputs by the selected model capability, arranges generated nodes deterministically, and avoids regenerating unrelated ancestors.
- **Harness and timeline:** provider call/result pairing survives checkpoints and long reasoning content, while reasoning rows remain attached to the correct step instead of appearing after the terminal result.
- **GitHub connection:** settings support GitHub's OAuth Device Flow with the official Floe Agent public client ID, account validation, Keychain token storage, and PAT fallback. No client secret is embedded.
- **Memory organization:** users can choose review-first organization or bounded model-managed cleanup. Both modes inspect existing facts for duplication, conflict, ownership, environment, and version drift before mutation.
- **Model clock:** every run receives a non-persisted local timestamp, IANA time-zone identifier, and UTC offset captured at run start.
- **Network diagnostics:** paired hosts expose bounded read-only ping, traceroute/tracepath, DNS lookup, and TCP port probing alongside LAN discovery.
- **Configuration recovery:** incompatible approval/review models are cleared before preferences are saved, preventing text-capability validation failures.

## Physical-iPad acceptance boundary

Automated tests cannot prove iPadOS system-window presentation, App Store processing, or the tester's saved VNC endpoint. On Build 118, verify ordinary-chat PiP only appears after leaving the foreground, survives normal Home/app switching, and closes on force-quit. Then verify `ssh.updateHost` or `ssh.execute` → `vnc.connect` → `vnc.observe` → one input action → `vnc.observe`, including coordinate consistency. Validate multi-reference Canvas generation with the chosen provider's advertised input limit. Never upload credentials with feedback.

## 简体中文

Build 118 是公开 Beta 前的候选版本，集中修复普通对话画中画、VNC 工具链、画布多参考图上下文、Harness 连续性、GitHub 直接登录、记忆整理和基础网络诊断。

- 普通对话画中画改用真实 `CMTimebase` 和单调递增的样本时间戳；前台不主动弹窗，离开应用时才交由 iPadOS 创建系统悬浮窗。
- 用户明确指定的工具顺序优先；SSH 修复并保存端点后直接开放 `vnc.connect`，连接成功前不允许观察或点击，同一失败不会无限重试。
- 画布只沿明确连线传递上下文；多张参考图均保留输入连线，并按模型能力限制数量，生成节点按固定规则排列。
- GitHub 设置支持官方 OAuth Device Flow 和 PAT 备用方式，只嵌入公开 Client ID，不包含 Client Secret。
- 记忆整理新增“规则 + 审核”和“完全交给模型”两种模式，写入前都会检查现有事实、冲突、环境和版本变化。
- 每轮模型运行都会收到启动时的本地时间、IANA 时区和 UTC 偏移；信息不写入长期记忆。
- 新增受限、只读的 ping、traceroute/tracepath、DNS 和 TCP 端口诊断工具。

实体 iPad 的系统悬浮窗、真实 VNC 坐标一致性、Apple 处理状态和测试组可见性仍需分别验收。

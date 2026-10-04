# Floe Agent 1.7.5 — Build 246

## 简体中文

- 当任务要求调整 Linux 虚拟机核心数时，助手会先检查环境状态，再调用对应的启动或重启工具；避免普通命令先自动启动单核虚拟机。
- Linux 虚拟机资源池总计最多 4 核，单台最多 3 核；可按 3+1、2+1+1、2+2 或 1+1+1+1 分配。三核需要经启动验证的新镜像，旧双核镜像仍受双核上限约束。低内存设备继续遵守自身配额。
- 语音输入准备阶段显示加载状态；准备超时或启动失败后会退出并允许重试，过期的录音会话不会覆盖新会话。
- 调整语音波形对实际麦克风音量的响应，改善低音量说话时波形不动的问题。
- 修复手记导图给已有主题添加图片后，图片可能因旧卡片尺寸而不显示的问题。

请在实际 iPad 上验证虚拟机核心数、语音启动与波形。自动化测试和 TestFlight 分发不代表设备体验已验收。

## English

- When a task asks to change a Linux guest's core count, the assistant checks its status and uses the guest start or restart tool before a shell command auto-starts a single-core guest.
- The Linux guest pool allows up to 4 cores in total and 3 per guest, including 3+1, 2+1+1, 2+2 and 1+1+1+1. Three cores require the newly boot-verified image; older dual-core images remain capped at two. Low-memory devices retain their smaller quotas.
- Voice input shows preparation progress and exits a stalled or failed startup so it can be retried. A stale capture session cannot overwrite a newer one.
- The voice waveform responds more clearly to measured microphone levels at lower speaking volume.
- Fixes an illustrated Notes mind map topic sometimes hiding its newly attached image because its prior text-only card size was reused.

Please verify guest core count, voice startup and the waveform on a physical iPad. Automated tests and TestFlight delivery are separate from device acceptance.

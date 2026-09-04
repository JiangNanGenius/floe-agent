# Floe Agent 1.4.85 (Build 116) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md)

Build 116 repairs the two regressions reproduced on Build 115: VNC recovery continuing with a stale checkpoint/cache after SSH repaired the endpoint, and ordinary-conversation Picture in Picture presenting no system window after Floe left the foreground.

## Fixes and automated evidence

- **VNC recovery after SSH:** a successful side effect invalidates older recovered observations, so `vnc.status` really executes again after `ssh.execute` or `ssh.updateHost` instead of replaying the pre-repair result. Host updates now notify the live remote-session center, disconnect stale sessions, clear cached authentication failures, and reload the saved endpoint and credential before the next VNC call.
- **System Picture in Picture:** the custom sample-buffer source now remains live with monotonic presentation timestamps and a one-second frame heartbeat. Playback state is invalidated when media becomes ready and as the source advances, allowing AVKit's supported automatic-inline transition to recognize active playback. Floe no longer invokes custom-source PiP programmatically from a background lifecycle callback.

Focused Swift tests execute the checkpoint invalidation and SSH host-update notification paths. CI additionally compiles the iOS app and runs the repository's non-zero regression suites.

## Physical-iPad acceptance boundary

Automated tests cannot prove iPadOS system-window presentation or reach the saved HK4H4G endpoint from the tester's device state. On Build 116:

1. In ordinary conversation with **System Picture in Picture** selected, start a long task, wait for the toolbar source to become ready, then use Home or app switching. Confirm a real system PiP window appears only after leaving Floe, keeps updating, and retracts when Floe returns to the foreground.
2. Run the VNC task that repairs HK4H4G over SSH. After the successful SSH mutation, confirm the next `vnc.status` is a fresh complete result, then `vnc.connect` → `vnc.observe` → `vnc.click` → `vnc.observe` completes without reusing an old refusal or truncated status.
3. Treat a force-quit as app termination, not supported PiP continuation. Do not upload VNC passwords, API keys, tokens, SSH private keys, certificates, or provisioning profiles with feedback.

## 简体中文

Build 116 修复 Build 115 真机复现的两个问题：SSH 已修好端点后 VNC 仍复用旧检查点/旧鉴权失败，以及普通对话离开 Floe 后没有出现系统画中画窗口。

- SSH 命令或主机配置成功变更后，先前的 `vnc.status` 观察结果会失效；下一次状态调用会真实执行。`ssh.updateHost` 还会立即通知远程会话中心，断开旧会话、清除缓存的鉴权失败并重新加载端点和凭据。
- 画中画源改为持续的实时样本流：每帧使用单调递增时间戳，每秒刷新并通知 AVKit 播放状态变化。Floe 只使用系统支持的内联自动切换，不再从后台生命周期回调主动启动自定义画中画。

自动化测试覆盖代码和状态契约；实体 iPad 上的系统悬浮窗及 HK4H4G 的真实 VNC 连接/点击坐标仍须按上面的步骤验收。

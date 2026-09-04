# Floe Agent 1.4.86 (Build 117) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md)

Build 117 supersedes Build 116 after CI correctly rejected the first candidate because its focused PiP suite no longer met the non-zero per-suite test-count floor. The application fixes are unchanged; this candidate adds a replacement regression contract for the supported system-managed inline-to-background transition and restores the full release gate.

## Fixes and automated evidence

- **VNC recovery after SSH:** a successful side effect invalidates older recovered observations, so `vnc.status` really executes again after `ssh.execute` or `ssh.updateHost`. Host updates notify the live remote-session center, disconnect stale sessions, clear cached authentication failures, and reload the saved endpoint and credential before the next VNC call.
- **System Picture in Picture:** the custom sample-buffer source remains live with monotonic presentation timestamps and a one-second frame heartbeat. Playback state is invalidated as the source advances, and Floe relies on AVKit's supported automatic-inline transition instead of starting custom-source PiP from a background callback.
- **Release-gate integrity:** the PiP policy suite explicitly verifies that a ready source stays armed through inactive and background phases and is classified as a system automatic start. The app-regression gate must execute at least 74 focused tests, including at least 34 in `CrashAndFeedbackRegressionTests`.

## Physical-iPad acceptance boundary

Automated tests cannot prove iPadOS system-window presentation or reach the tester's saved HK4H4G endpoint. On Build 117, verify ordinary-conversation PiP with Home/app switching and verify `vnc.status` → `vnc.connect` → `vnc.observe` → `vnc.click` → `vnc.observe` after SSH repair. Force-quit is app termination, not supported PiP continuation. Never upload credentials with feedback.

## 简体中文

Build 117 取代被 CI 正确拦截的 Build 116。应用修复本身不变；本版补回系统托管画中画切换的回归测试，使每个套件的非零测试数量门禁恢复完整。

- SSH 修复或更新主机后，旧 `vnc.status` 结果会失效，实时会话中心会清理旧会话和旧鉴权失败并重载端点。
- 画中画使用持续样本、单调时间戳和每秒心跳，并交给 AVKit 在离开前台时执行系统内联切换。
- 新回归断言验证媒体已就绪时，从 `active` 经 `inactive` 到 `background` 始终保持系统自动切换资格。

实体 iPad 的真实系统悬浮窗，以及 HK4H4G 的 VNC 连接和坐标一致性，仍需在 Build 117 上完成最终验收。

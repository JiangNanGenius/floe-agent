# Floe Agent 1.4.84 (Build 115) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

Build 115 corrects three regressions still visible in Build 114: unrelated memory maintenance interrupting remote work, an incomplete VNC-to-SSH recovery route, and ordinary-conversation PiP failing to create the real system window after Floe leaves the foreground.

## Focus areas

- **Task-scoped tool catalog:** ordinary operational requests no longer expose agent memory tools. Memory extraction remains automatic, while `memory.*` tools are available only when the current user turn explicitly asks to inspect or change memory. A VNC task exposes only SSH and VNC tools, so `memory.organizePreview`, JavaScript, and Python cannot replace the requested remote workflow.
- **Conditional VNC recovery:** an initial VNC attempt is allowed when requested. After connection or observation fails, a user-requested SSH recovery becomes a hard prerequisite; repeated VNC calls remain blocked until `ssh.execute` and any running SSH task finish successfully.
- **Ordinary-conversation PiP:** AVKit automatic inline promotion remains the primary path. If iPadOS misses that promotion, Floe invokes the PiP controller only after the scene is confirmed in the background and the sample-buffer source is prepared. Active and inactive foreground transitions cannot trigger this fallback, and a late completion after foreground return is retracted.

## Physical-iPad acceptance boundary

Automated tests cover the tool-catalog filters, failed-VNC conditional gate, successful-SSH reopening, PiP background-only start predicate, foreground exclusion, late-start retraction, checkpoint pairing, Canvas graph persistence, and timeline projection. A physical iPad is still required to prove that iPadOS presents and retains the system PiP window and that the repaired remote service produces correct VNC visual-coordinate behavior.

On Build 115:

1. Start an ordinary conversation task and leave Floe. Confirm the real system PiP window appears only after Floe enters the background, stays present while the retained task is running or resumable, and disappears on task teardown. Merely launching or using Floe in the foreground must not create a top-right window.
2. Ask to test VNC and, if it fails, repair it over SSH. After the first VNC refusal, confirm the next operational tools are SSH tools—not another VNC call, JavaScript, or memory organization. Once SSH repair completes, confirm VNC status, connection, observation, and coordinate testing continue in order.
3. Run the same remote task without mentioning memory. Confirm no `memory.organizePreview` step appears. Then separately ask Floe to remember a changed version or environment fact and confirm the older active memory is compared before the new fact is accepted.

## 简体中文

Build 115 修复 Build 114 仍能复现的三个回归：无关的记忆整理打断远程任务、VNC 失败后没有真正切换到用户指定的 SSH 恢复路线，以及普通对话离开前台后没有生成真实系统画中画窗口。

- 普通操作任务不再暴露 Agent 记忆工具；自动记忆提取保持不变，只有当前消息明确要求查看或修改记忆时才开放 `memory.*`。VNC 任务只提供 SSH/VNC，不会再混入记忆整理、JavaScript 或 Python。
- 可以先按用户要求尝试 VNC；一旦连接或观察失败，而用户指定 SSH 修复，Harness 会阻止再次调用任何 VNC 工具，直到 SSH 命令及其后台任务成功结束，然后才重新开放 VNC。
- 普通对话仍优先使用 AVKit 的自动内联切换；如果系统漏掉切换，Floe 只会在场景已确认进入后台、媒体源已准备完成时主动启动。前台和 `inactive` 阶段不会触发，回到前台后的迟到启动会立即收回。

请在实体 iPad 上验证真实系统画中画窗口及 VNC 坐标一致性。反馈请注明 Build 115、设备/系统版本、任务 ID、准确时间和所选工具链；不要上传密码、API Key、Token、SSH 私钥、证书或描述文件。

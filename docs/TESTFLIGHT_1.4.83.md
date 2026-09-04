# Floe Agent 1.4.83 (Build 114) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

Build 114 closes the public-beta blockers found in ordinary-conversation PiP, ordered remote-tool workflows, recovery checkpoints, and long-term-memory organization. It is available only after CI executes non-zero tests, Xcode Cloud uploads the signed build, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **Ordinary conversation PiP lifetime:** the PiP source remains attached to the coordinator-owned active or retained run, including failed/checkpointed tasks that can be continued. Canvas and ordinary chat now use the same durable lifecycle boundary.
- **Ordered tool chains:** stateful VNC tools are exposed progressively. `vnc.status` precedes connection; observation and input appear only after a connected result. When the current user explicitly requires SSH before VNC, the SSH command (and any running-task completion) must finish before any VNC tool is offered. Unrelated JavaScript/Python tools are excluded from that explicit remote route.
- **Recovery call/result pairing:** tool-free forced finalization hides new tool schemas without deleting historical tool calls. Provider checkpoints therefore retain each ordered call/result pair and no longer fail with `checkpoint.dispatchPairingMismatch`.
- **Prior-memory audit:** manual, automatic, and agent memory writes inspect active prior memory first. Exact duplicates are not saved; mutable facts such as environment, address, model, or version are linked to the prior fact slot or held for conflict review.
- **Actionable smart organization:** the Memory screen combines deterministic cleanup with bounded model-assisted comparison for semantic duplicates, changed facts, stale state, and missing ownership. Suggested destructive changes remain reviewable and require explicit confirmation.

## Physical-iPad acceptance boundary

Automated tests cover ordinary-chat PiP ownership, ordered VNC/SSH schema transitions, explicit-route tool filtering, recovery-envelope pairing, prior-memory prompting and duplicate prevention, smart-organization validation, Canvas graph persistence, and timeline projection. A physical iPad is still required to accept system PiP presentation and VNC visual-coordinate behavior.

On Build 114:

1. Start a normal conversation task, switch to system PiP, background Floe, and confirm the real system PiP window survives while the task is active or retained. Confirm no PiP window appears merely from launching Floe in the foreground.
2. Ask explicitly for SSH setup followed by VNC connection and coordinate testing. Confirm no JavaScript step appears, no VNC observation occurs before SSH and connection complete, and Continue resumes without a checkpoint pairing error.
3. Add or automatically extract a fact that replaces an older environment/version fact. Confirm the previous memory is inspected, exact duplicates are skipped, conflicts wait for review, and Smart Organize displays actionable reviewed suggestions.

## 简体中文

Build 114 修复公开 Beta 前最后一组阻塞问题：普通对话画中画生命周期、远程工具链顺序、恢复检查点的调用/结果配对，以及长期记忆智能整理。

- 普通对话的画中画来源现在跟随后台协调器维护的真实任务生命周期；失败或已保存检查点但可继续的任务不会提前丢失画中画来源。
- VNC 工具按状态逐步开放：先查状态、再连接、连上后才能观察或点击。当前请求明确要求先 SSH 时，SSH 命令及其后台任务必须完成后才开放 VNC；这条远程路线不会再混入 JavaScript/Python。
- 强制收尾时仍保留历史工具调用与结果的有序配对，不再触发 `checkpoint.dispatchPairingMismatch`。
- 手动添加、自动提取和 Agent 写入记忆前都会读取当前有效记忆；完全重复的内容不再重复保存，环境、地址、模型、版本等可变事实会关联旧值或进入冲突审核。
- “智能整理”会结合确定性扫描与模型语义比对，给出可审核的重复、替换、过期或归属问题；删除仍需明确确认。

请在实体 iPad 上验证普通对话系统画中画和 VNC 坐标一致性。反馈请注明 Build 114、设备/系统版本、任务 ID、准确时间和所选工具链；不要上传密码、API Key、Token、SSH 私钥、证书或描述文件。

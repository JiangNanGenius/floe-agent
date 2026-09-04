# Floe Agent 1.4.80 (Build 111) TestFlight Notes

> This candidate was cancelled during CI before archive, signing, or TestFlight upload after an additional model-aware Canvas input-limit requirement was identified. It is retained as an immutable source tag only; use Build 112 or later for testing.

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate hardens VNC prerequisite recovery, long-running multi-reference Canvas generation, tool-step presentation, and connector dragging. Build 111 is available only after CI reports a non-zero verified test count, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **VNC route recovery:** provider-visible tool descriptions now carry the compiled `vnc.connected` prerequisite and its explicit `vnc.connect` resolver. When VNC is unconfigured and the user authorized host setup, runtime guidance changes route through saved-host inspection, explicit host-mode SSH setup, secure host-profile update, connection, and only then observation/input.
- **No repeated dead-end tools:** duplicate calls with identical tool and arguments inside one provider batch execute once. After an explicit non-retryable result, the same unchanged route is suppressed before approval or execution and the run exits the loop with preserved evidence.
- **Clean task timeline:** protocol result pairs created for Harness suppression still go back to the provider, but their duplicate request/result cards are omitted from the user timeline. The authoritative execution remains visible.
- **Multi-reference background ownership:** a user-started Canvas image or video request is registered as active workload for its full provider lifetime. Picture-in-Picture mode receives the real media-generation context and the short background lease no longer sees zero active work.
- **No false top-right card:** Canvas media never submits an iOS continued-processing Live Activity. It keeps saved Canvas task state, retains durable recovery for submitted video jobs, and uses the AVKit Picture-in-Picture surface when selected. This keeps the foreground free of the unrelated top-right system card.
- **Connector gesture priority:** dragging a connection port wins gesture arbitration over node movement, so the wire follows the pointer without moving the source card.
- **Existing explicit graph contract retained:** multiple reference images continue to enter generation only through selected or connected source relationships, and generated outputs retain their typed task/result connections and deterministic layout.

## Physical-iPad acceptance boundary

Automated tests prove tool batching, prerequisite descriptions, timeline projection, graph persistence, and PiP lifecycle policies. A physical iPad is still required to prove that iPadOS presents the system PiP window and keeps a long multi-reference request alive while Floe is backgrounded.

On Build 111:

1. Select System Picture in Picture, begin a five-reference-to-one-image Canvas request, wait until the toolbar reports PiP ready, and leave Floe with Home or app switching. Confirm a real system PiP window appears, the foreground never showed an independent top-right task card, and returning to Floe retracts PiP.
2. Ask the agent to configure a saved SSH host for VNC and then test one coordinate. Confirm the visible chain changes from SSH inspection/setup to `vnc.connect`, `vnc.observe`, one input action, and a fresh observation; an unconfigured observation must not repeat.
3. Drag from a node connection port. Confirm only the wire moves, then save and reopen the Canvas and verify every intended source and generated-result connection remains present.

## 简体中文

本候选版重点加固 VNC 前置恢复链、多参考图长时生成、工具步骤显示和画布连线拖拽。只有 CI 确认实际执行了非零测试、App Store Connect 显示构建已有效处理，并且内部 Floe QA 测试组可见 Build 111 后，才算真正可用。

- **VNC 改走正确路径：**模型实际看到的工具说明现在包含 `vnc.connected` 前置状态和 `vnc.connect` 解析器。若端点未配置且用户已授权主机设置，运行时会引导它改用主机列表、SSH 检查与配置、安全保存 VNC 端点，再连接、观察和操作。
- **不再反复撞同一失败工具：**同一模型批次中工具名与参数完全相同的调用只执行一次；明确不可重试的失败出现后，相同路线会在审批和执行前被 Harness 拦截，并携带已有证据结束死循环。
- **任务时间线去重：**Harness 为协议配对生成的抑制结果仍会返回模型，但重复的请求/结果卡不再显示给用户，界面只保留真正执行的那一步。
- **多参考图任务具有真实后台所有权：**用户从画布启动的图片或视频请求在整个服务商调用期间都登记为活跃工作。选择系统画中画后，AVKit 会得到真实的媒体生成上下文，短后台保活也不会再误判为零任务。
- **不再弹出右上角伪画中画卡片：**画布媒体任务永不提交 iOS continued-processing Live Activity；它保留已保存的画布任务状态，已提交视频继续使用持久恢复链，并在用户选择时使用真实 AVKit 画中画。
- **连线优先于拖框：**从连接端口拖动时，线手势优先，来源节点不会再跟着移动。
- **保留明确画布关系：**多张参考图仍只通过明确选择或连接的 `source` 关系进入生成上下文，输出继续保留带类型的任务/结果连线和固定布局。

## 实体 iPad 验收边界

自动化测试能证明工具批次、前置说明、时间线投影、图关系持久化与 PiP 生命周期策略；但 iPadOS 是否真的显示系统 PiP，以及五张参考图长请求在后台是否持续，仍需实体 iPad 验收。

Build 111 上请验证：选择“系统画中画”，用五张参考图生成一张图，等工具栏显示已就绪后再切到桌面；确认出现真实系统 PiP、Floe 前台没有独立右上角任务卡，返回应用后 PiP 收回。随后测试一次“SSH 配置主机 → VNC 连接 → 观察 → 单次输入 → 再观察”，并确认从端口拖线时节点不移动、保存重开后所有关系仍在。

反馈请注明 Build 111、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。

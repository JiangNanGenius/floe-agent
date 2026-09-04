# Floe Agent 1.4.82 (Build 113) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

Build 113 contains the complete VNC recovery, Canvas background/PiP, multi-reference generation, timeline, connector gesture, and model-aware reference-input fixes. It also corrects the full-suite fixture so distinct same-batch calls remain paired while exact duplicates remain suppressed. It is available only after CI executes non-zero tests, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **User-directed VNC order:** an explicitly requested prerequisite route is binding. If the user asks for SSH setup first, the agent must inspect/configure through SSH before `vnc.connect` and may call `vnc.observe` only after connection. SSH remains an example resolver rather than a universal fallback.
- **No repeated dead ends:** identical same-batch tool calls execute once, while distinct calls in the same response still execute and receive exactly one result each. Unchanged retries after explicit non-retryable failures are suppressed before approval or execution.
- **Model-aware reference inputs:** the selected media-only model is resolved directly instead of falling through the chat-model picker. The strictest catalog/adapter reference-image limit is shown in configuration, enforced when a wire is dropped, checked again on save, and enforced before networking. Explicit upstream image ancestry counts toward the limit; references are never silently truncated.
- **Long multi-reference ownership:** Canvas image/video generation remains an active workload for its full provider lifetime. PiP mode gets the real media context, while media work never creates the unrelated top-right continued-processing card.
- **Reliable Canvas interaction:** connection-port dragging wins over node dragging, and generated source/result relationships remain explicit and persist with deterministic layout.

## Physical-iPad acceptance boundary

Automated tests cover capability resolution, prospective source-edge counting, provider wire cardinality, VNC route guidance, loop suppression, timeline projection, graph persistence, and PiP lifecycle policy. A physical iPad is still required for system PiP presentation and VNC visual-coordinate acceptance.

On Build 113:

1. Choose image models with different reference limits. Confirm the configuration sheet displays the correct limit, the last allowed image wire succeeds, and the next wire is rejected without moving either node or changing existing connections.
2. Ask for a specific sequence such as SSH setup followed by VNC connection and coordinate testing. Confirm the visible tool chain follows that order and never repeats an unconfigured `vnc.observe`.
3. In system PiP mode, start a five-reference image request on a compatible model, leave Floe, and confirm a real system PiP window appears without a separate foreground top-right task card.

## 简体中文

Build 113 包含完整的 VNC 恢复、画布后台/画中画、多参考图生成、时间线、拖线手势和按模型限制参考图输入修复，并修正了全量测试中与“同批次精确重复调用只执行一次”新契约冲突的旧用例。

- 用户明确指定的工具顺序是本轮约束；要求先 SSH 时，必须先完成 SSH 检查与配置，再连接 VNC，最后才能观察。
- SSH 只是可选恢复路线之一；用户没有指定时，模型才根据当前工具和证据选择合法解析器。
- 完全相同的同批次调用只执行一次；参数不同的调用仍分别执行，并各自获得且仅获得一个结果。
- 生成节点显示所选模型的参考图上限。拉线时会把该节点的显式上游图片一并计数，超限立即拒绝；保存配置和发送网络请求前还会再次验证。
- 明确选中的纯媒体模型不再按聊天模型查找，也不会悄悄回退到默认模型；多张参考图不会被静默截断。
- 画布媒体任务获得真实后台/PiP 生命周期，同时不会制造右上角 continued-processing 卡片；从连接端口拉线时节点保持不动。

请在实体 iPad 上验证系统 PiP 和 VNC 坐标一致性。反馈请注明 Build 113、设备/系统版本、所选模型、画布/任务 ID 和准确时间；不要上传密码、API Key、Token、SSH 私钥、证书或描述文件。

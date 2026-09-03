# Floe Agent 1.4.78 (Build 109) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate fixes four-output reference-image generation, the real system Picture in Picture transition, Canvas Assistant timeline ordering, and deterministic generation layout. Build 109 is available only after CI passes with a non-zero verified test count, App Store Connect reports a valid processed build, and the internal Floe QA group can see it.

## Focus areas

- **One reference to four results:** a four-image request prepares four independent result nodes before networking. The reference keeps a typed `source` edge into the generation task, and the task keeps one typed `generatedFrom` edge to each result. A provider response with fewer or more than four images fails as a whole instead of being shown as a partial success.
- **Explicit Canvas context:** only selected nodes, saved generation sources, and incoming `source` ancestry become generation context. Reference image bytes and their relevant saved prompt context are preserved; ordinary arrows and older generated-result edges do not silently become inputs.
- **Long image request budget:** non-streaming image generation has a five-minute request timeout so a provider-side four-image sequence is not cut off by the generic 60–75 second networking default. Cancellation and response-size limits remain enforced.
- **Stale completion safety:** editing, refining, or cancelling a generation task replaces its attempt token. A delayed four-image success, provider error, or cancellation from the previous configuration is discarded before it can overwrite the new graph state.
- **Deterministic graph layout:** generation tasks and their result nodes use a fixed grid, clear existing nodes, and form a readable left-to-right source → task → results flow without moving the user's existing canvas content.
- **System Picture in Picture:** the AVKit sample-buffer source is attached to the existing task or Canvas toolbar rather than a separate app window. In Picture in Picture mode, leaving Floe lets the system enter real PiP automatically; the toolbar still provides manual start, stop, and retry. Floe does not create an independent foreground floating preview.
- **No PiP-mode Live Activity lookalike:** Picture in Picture and screen-share modes no longer submit the standard continued-processing task whose system Live Activity can appear at the top right. Standard background mode retains that independent system path.
- **Stable Canvas Assistant timeline:** private final-answer verification reasoning is not rendered after the final answer, stale live animation tails lose to a persisted terminal event, and raw `endTurn` is replaced by the localized terminal row. Real reasoning that leads to a later tool call remains visible.
- **Executed-test release gate:** CI and release verification include the Canvas, Canvas-tool, PiP, and timeline suites and require at least 34 executed tests, zero failures, and `passed == total`.

## Physical-iPad acceptance boundary

Simulator builds and automated state-contract tests cannot prove that iPadOS presents and retains the real system PiP window. On a physical iPad, select System Picture in Picture, start a task, confirm there is no independent top-right Floe card while the app is foregrounded, leave Floe, and confirm that the system PiP window appears and continues updating. Return to Floe, then verify manual stop and retry. Separately, generate four images from one connected reference and confirm one `source` edge plus four `generatedFrom` edges and four aligned result nodes.

## 简体中文

本候选版修复“参考图生成四张”、真实系统画中画切换、画布助手时间线顺序，以及生成节点的固定整齐布局。只有 CI 通过且确认实际执行了非零测试、App Store Connect 显示构建处理有效，并且内部 Floe QA 测试组可见 Build 109 后，才算真正可用。

- **一张参考图生成四个结果：**四图请求会在联网前准备四个独立结果节点。参考图通过一条 `source` 类型连线进入生成任务，生成任务再分别通过四条 `generatedFrom` 类型连线连接四个结果。服务商少返回或多返回图片时整次失败，不再伪装成部分成功。
- **明确的画布上下文：**只有明确选择的节点、配置中保存的来源，以及沿 `source` 类型向上的祖先会进入生成上下文。参考图二进制和相关原始提示词上下文都会保留；普通箭头和旧的生成结果连线不会被偷偷当成输入。
- **四图请求超时修复：**非流式图片生成请求最长等待五分钟，避免服务商按顺序生成四张时被通用的 60–75 秒网络超时提前截断；取消和响应大小限制继续生效。
- **旧请求回写保护：**编辑、AI 修改或取消生成任务时会替换 attempt 标记。旧配置的四图成功、服务商错误或取消即使延迟返回，也会在写入前被丢弃，不再覆盖新配置状态。
- **固定网格布局：**生成任务与结果节点采用确定性的网格避让，形成清楚的“来源 → 任务 → 结果”流程，不移动用户已有画布内容。
- **真实系统画中画：**AVKit 播放源挂在现有任务或画布工具栏内，不再创建 App 自己的悬浮窗口。选择“系统画中画”后，离开 Floe 时由系统自动进入真实 PiP；工具栏仍可手动启动、关闭和重试。Floe 前台不会再创建独立悬浮预览。
- **移除画中画模式的伪窗口来源：**画中画和屏幕共享模式不再提交普通后台的 continued-processing 任务，避免其系统 Live Activity 在右上角看起来像一个未成功的画中画窗口；普通后台模式仍保留该独立链路。
- **画布助手时间线稳定：**最终答复后的私有校验思考不再显示，已经持久化的终态会压过尚未排空的动画尾部，原始 `endTurn` 改为本地化终态行；真正会继续调用工具的思考仍会保留。
- **发布测试门禁：**CI 与发布验证纳入画布、画布工具、画中画和时间线套件，要求至少实际执行 34 条测试、失败数为 0，且通过数等于总数。

## 实体 iPad 验收边界

模拟器构建和自动状态测试不能证明 iPadOS 确实显示并保持真实系统画中画。请在实体 iPad 选择“系统画中画”，启动任务，确认 Floe 在前台时右上角没有独立 Floe 卡片；离开 Floe 后确认系统 PiP 窗口出现并持续更新。返回 Floe 后再验证手动关闭与重试。另请用一张已连接的参考图生成四张，确认一条 `source` 连线、四条 `generatedFrom` 连线，以及四个排列整齐的独立结果节点。

反馈请注明 Build 109、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。

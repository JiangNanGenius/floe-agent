# Floe Agent 1.4.76 (Build 107) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate repairs Plan-mode state, tool lifecycle ordering, Picture in Picture readiness, Infinite Canvas generation semantics, and long-reasoning Harness recovery. Build 107 is available only after App Store Connect reports a valid processed build and the internal Floe QA group can see it.

## Focus areas

- **Plan mode:** a planning turn may inspect read-only state but cannot execute mutating tools. Follow-up messages revise the active plan until the user explicitly changes mode; execution starts only after accepting a complete ready revision.
- **Tool prerequisites:** VNC observation and input require an explicit active connection. Verify the lifecycle `status → connect → observe → one input → observe`, and confirm credentials remain opaque references rather than model-visible text.
- **Picture in Picture:** foreground preparation exposes its exact state and uses a genuinely visible video surface. Verify readiness, background transition, manual dismissal, and recovery on a physical iPad.
- **Infinite Canvas:** saving a generation node creates only that task node. Its own prompt and model configuration remain authoritative, while upstream context enters only through explicit source edges. Artifact nodes appear only after generation succeeds.
- **Generation recovery:** retry a failed image or video task without rebuilding predecessor nodes or duplicating the task graph.
- **Harness:** long reasoning streams and reasoning text containing braces, code fences, XML-like tags, emoji, or other symbols must not become phantom tool calls or be treated as idle prematurely.

## 简体中文

本候选版修复计划模式状态、工具前置顺序、画中画就绪、无限画布生成语义，以及长思考 Harness 恢复。只有 App Store Connect 显示构建处理有效，并且内部 Floe QA 测试组可见 Build 107 后，才算真正可用。

- **计划模式：**规划阶段可以读取信息，但不能执行有副作用工具；后续消息持续修订当前计划，只有用户明确切换模式或接受一份完整且 ready 的计划后才进入执行。
- **工具前置：**VNC 观察和输入必须已有明确连接；重点验证“状态 → 连接 → 观察 → 单次输入 → 再观察”，并确认密码始终使用不向模型暴露明文的引用。
- **画中画：**前台准备会显示准确阶段，并使用真正可见的视频承载面；请在实体 iPad 验证就绪、进入后台、手动关闭和恢复。
- **无限画布：**保存生成节点只创建该任务节点；提示词和模型配置由节点自身持有，上游上下文只沿显式来源连线进入，只有生成成功才创建产物节点。
- **生成恢复：**图片或视频失败后重试，不能重建前置节点或复制任务图。
- **Harness：**超长思考流及其中的花括号、代码围栏、类 XML 标签、Emoji 等符号不能触发幽灵工具调用，也不能被过早判定为空闲卡停。

反馈请注明 Build 107、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。

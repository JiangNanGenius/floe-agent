# Floe Agent 1.4.75 (Build 106) TestFlight Notes

[简体中文](#简体中文) · [User guide](USER_GUIDE.md) · [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)

This candidate stabilizes canvas generation context, Picture in Picture task batches, tool-resource chaining, and very large task timelines. Build 106 is available only after App Store Connect reports a valid processed build and the internal TestFlight group can see it.

## Focus areas

- **Canvas context:** starting or retrying an existing task must reuse its saved prompt, configuration, source node IDs, task card, and artifact card. It must not insert another prompt node. Only explicit source edges contribute context; ordinary links, generated artifacts, cycles, and unconnected notes do not.
- **Inline generation:** Start, Cancel, Retry, and Generate Again run from the task and artifact cards. Execution does not open an empty generation sheet. Configuration and import keep compact sheets and actionable image/video errors.
- **Picture in Picture:** close PiP while several runs belong to the same task batch, switch foreground/background repeatedly, and relaunch while a run is recoverable. PiP must remain closed for that batch; a genuinely new batch may offer it again.
- **Harness chaining:** list/search results expose harness-authored resource bindings. Verify host, task, session, share, workspace, canvas, conversation, and cursor IDs carry into the next tool without guessing or replaying side effects.
- **Recovery:** malformed calls get one correction opportunity without a fabricated call/result pair. Deterministic failures do not retry; loop/budget exits produce a final text handoff with evidence and a recovery action.
- **Large tasks:** page through a long task repeatedly and resume an active run. Equal-timestamp events must not repeat or disappear, and old events must not reappear as active work.

## 简体中文

本候选版重点修复画布生成上下文、画中画任务批次、工具资源 ID 串联和超大任务时间线。只有 App Store Connect 显示构建处理有效，并且内部 TestFlight 测试组可见 Build 106 后，才算真正可用。

- **画布上下文：**启动或重试已有任务必须复用已保存的提示词、配置、来源节点、任务卡和产物卡，不能再补一个提示词节点。只有显式来源连线进入上下文；普通线、历史产物、环和未连线备注都不进入。
- **内联生成：**开始、取消、重试和再次生成都在任务卡或产物卡内进行，执行时不再弹空白生成页；只有配置和导入保留紧凑弹层，图片/视频错误提供可操作恢复入口。
- **画中画：**同一任务批次包含多个 Run 时手动关闭画中画，反复前后台切换并冷启动恢复，均不得重新弹出；真正的新批次才重新获得资格。
- **Harness 串联：**列表和搜索结果返回由 Harness 写入的资源绑定；重点验证主机、远程任务、会话、分享、工作区、画布、对话和游标 ID 能直接交给下一步工具，不能猜测或重放有副作用操作。
- **恢复：**畸形工具调用只允许一次纠正，不制造假的调用/结果对；确定性错误不重试；循环或预算终止后必须给出带证据和恢复入口的文字收尾。
- **超大任务：**连续翻页并恢复运行中任务时，同时间戳事件不能重复或丢失，旧事件不能重新显示为“正在运行”。

反馈请注明 Build 106、设备和系统版本、模型与供应商、画布/任务 ID、准确操作与时间。不要上传 API Key、Token、密码、SSH 私钥、证书或描述文件。

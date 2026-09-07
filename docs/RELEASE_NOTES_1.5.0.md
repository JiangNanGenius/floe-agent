## Floe Agent 1.5.0 (Build 131 candidate)

### 简体中文

- 新增原生 `skill.search`，支持中英文领域关键词，明确区分查找工作流与加载工具定义。工具描述匹配只返回相关工具，不再因为一个词命中而载入整个无关工具组。
- 移除整项任务累计流事件数的硬截断。内存保护按单次模型响应计算；仍保留无进展循环检测、用户预算、取消和恢复边界。
- 补齐 DeepSeek 历史消息与检查点中的推理协议字段。旧版本未保存的推理不伪造，旧助手文本明确作为非授权的历史参考传入。
- `/compact` 在任务空闲时立即执行，显示处理结果并持久化摘要，不删除原始会话和工具记录。压缩后明确通知模型上下文已压缩、沿用最新用户更正、继续未完成任务，不重复已完成操作。
- Goal 使用实际模型请求事件计数；工具和技能搜索不作为任务完成证据，取得新证据后重置重复阻塞计数。
- 优化审批对“例如、等”等非穷举测试范围的理解；不放开无关目标、破坏性操作、秘密访问、付款或发布权限。
- 增加完整任务 JSONL 导出，包含持久化消息、消息分段、工具调用/结果事件、用量、错误和事件水位。敏感字段脱敏；原先未保存或已截断的原始输出无法补造，产物以引用表示。
- 侧边栏和任务列表增加失败、挂起、等待审批、无进展及预算暂停提示。压缩和续跑状态增加轻量过渡，并遵循“减少动态效果”。
- 发布流程可复用同一提交已成功的可信 CI 回归证据，保留稳定 App Store SDK、实际二进制和签名上传检查。

仅内部 TestFlight；发布尚未完成。版本、CI、上传回执、Apple VALID、Floe QA 可见性和实体 iPad 验收分别记录。保留已经真机确认的 VNC 与 PiP 实现。

### English

- Added native `skill.search` with bilingual domain matching and explicit workflow-versus-tool discovery. Description-only matches return relevant tools rather than entire unrelated groups.
- Removed the cumulative per-task stream-event cutoff. Memory protection applies per model response; no-progress detection, user budgets, cancellation and recovery boundaries remain.
- Preserve DeepSeek reasoning protocol fields in assistant history and checkpoints. Missing legacy reasoning is never invented; legacy assistant text is explicitly non-authoritative historical context.
- `/compact` executes immediately while idle, reports its outcome and persists the summary without deleting original conversation or tool records. The model receives an explicit compaction notice, latest-correction precedence and instructions to continue without replaying completed work.
- Goal accounting uses actual model-request events. Tool/skill discovery is not completion evidence, and new evidence resets repeated-blocker tracking.
- Approval guidance recognizes non-exhaustive examples within the requested testing scope without authorizing unrelated targets, destructive operations, secrets, payments or publication.
- Added task JSONL export with persisted messages/parts, tool call/result events, usage, errors and event watermarks. Sensitive fields are redacted; missing or previously truncated raw output cannot be reconstructed and artifacts remain references.
- Sidebar and task-list indicators distinguish failure, interruption, approval waiting, no progress and budget pauses. Compaction and continuation use lightweight transitions respecting Reduce Motion.
- Releases can reuse successful trusted CI evidence for the exact same commit, retaining stable App Store SDK, binary, signing and upload gates.

Internal TestFlight only; delivery is not yet complete. CI, upload receipt, Apple VALID, internal Floe QA visibility and physical-device acceptance remain separate gates. Preserve the existing device-validated VNC and PiP implementations.
